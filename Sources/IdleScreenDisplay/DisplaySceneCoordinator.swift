import AppKit
import Foundation
import IdleScreenCore
import Observation

public enum DisplaySceneCoordinationFailure: Equatable, Sendable {
    case staleConfigurationRevision(received: UInt64, accepted: UInt64)
    case conflictingConfigurationRevision(UInt64)
    case planning(String)
}

public struct DisplaySceneHostToken: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

/// The process-wide owner of display observation and scene planning.
///
/// A single coordinator is shared by every host in a process. Observation
/// begins with the first host and all topology state is released with the
/// final host, so saver preview churn cannot leave observers or stale plans
/// behind. Configuration revisions fence updates independently from topology
/// generations: either input can replan without pretending the other changed.
@MainActor
@Observable
public final class DisplaySceneCoordinator {
    public typealias TopologyReader = DisplayTopologyPublisher.Reader

    public static let shared = DisplaySceneCoordinator()

    public private(set) var latestSnapshot: DisplayTopologySnapshot?
    public private(set) var latestPlan: DisplayScenePlan?
    public private(set) var settings: DisplaySceneSettings?
    public private(set) var configurationRevision: UInt64?
    public private(set) var lastFailure: DisplaySceneCoordinationFailure?
    public private(set) var topologyFailure: DisplayTopologyPublicationFailure?

    public var activeHostCount: Int { hostTokens.count }

    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let notificationName: Notification.Name
    @ObservationIgnored private let readTopology: TopologyReader
    @ObservationIgnored private let planner = DisplayScenePlanner()
    @ObservationIgnored private var publisher: DisplayTopologyPublisher?
    @ObservationIgnored private var publisherToken: DisplayTopologyObserverToken?
    @ObservationIgnored private var hostTokens: Set<DisplaySceneHostToken> = []

    public convenience init() {
        let reader = MacDisplayTopologyReader()
        self.init(
            notificationCenter: .default,
            notificationName: NSApplication.didChangeScreenParametersNotification,
            readTopology: { try reader.readTopology() }
        )
    }

    public init(
        notificationCenter: NotificationCenter,
        notificationName: Notification.Name,
        readTopology: @escaping TopologyReader
    ) {
        self.notificationCenter = notificationCenter
        self.notificationName = notificationName
        self.readTopology = readTopology
    }

    @discardableResult
    public func attach(
        settings: DisplaySceneSettings,
        configurationRevision: UInt64
    ) -> DisplaySceneHostToken {
        let token = DisplaySceneHostToken(rawValue: UUID())
        let isFirstHost = hostTokens.isEmpty
        hostTokens.insert(token)

        if isFirstHost {
            self.settings = settings
            self.configurationRevision = configurationRevision
            lastFailure = nil
            startObservation()
        } else {
            _ = update(
                settings: settings,
                configurationRevision: configurationRevision
            )
        }
        return token
    }

    public func detach(_ token: DisplaySceneHostToken) {
        guard hostTokens.remove(token) != nil, hostTokens.isEmpty else {
            return
        }

        if let publisherToken {
            publisher?.removeObserver(publisherToken)
        }
        publisher?.stop()
        publisherToken = nil
        publisher = nil
        latestSnapshot = nil
        latestPlan = nil
        settings = nil
        configurationRevision = nil
        lastFailure = nil
        topologyFailure = nil
    }

    @discardableResult
    public func update(
        settings: DisplaySceneSettings,
        configurationRevision: UInt64
    ) -> Bool {
        guard !hostTokens.isEmpty else { return false }
        guard let acceptedRevision = self.configurationRevision else {
            self.settings = settings
            self.configurationRevision = configurationRevision
            lastFailure = nil
            replanForConfigurationChange()
            return true
        }

        if configurationRevision < acceptedRevision {
            lastFailure = .staleConfigurationRevision(
                received: configurationRevision,
                accepted: acceptedRevision
            )
            return false
        }
        if configurationRevision == acceptedRevision {
            guard settings == self.settings else {
                lastFailure = .conflictingConfigurationRevision(
                    configurationRevision
                )
                return false
            }
            lastFailure = nil
            return true
        }

        self.settings = settings
        self.configurationRevision = configurationRevision
        lastFailure = nil
        replanForConfigurationChange()
        return true
    }

    public func refreshTopology() {
        guard !hostTokens.isEmpty else { return }
        publisher?.refresh()
        topologyFailure = publisher?.lastFailure
    }

    /// Resolves an AppKit host frame to a rendering representative. Exact
    /// matches win; otherwise the host midpoint must fall inside one logical
    /// representative frame. Mirror followers are never returned.
    public func representativeIdentifier(
        for hostFrame: DisplayTopology.Rect
    ) -> DisplayTopology.PersistentDisplayIdentifier? {
        guard let topology = latestSnapshot?.topology else { return nil }
        let representatives = topology.displays.filter {
            $0.mirrorTargetIdentifier == nil
        }
        if let exact = representatives.first(where: {
            $0.logicalFrame == hostFrame
        }) {
            return exact.persistentIdentifier
        }

        let midpointX = hostFrame.minX + (hostFrame.width / 2)
        let midpointY = hostFrame.minY + (hostFrame.height / 2)
        return representatives.first(where: { display in
            let frame = display.logicalFrame
            return midpointX >= frame.minX && midpointX < frame.maxX
                && midpointY >= frame.minY && midpointY < frame.maxY
        })?.persistentIdentifier
    }
}

private extension DisplaySceneCoordinator {
    func startObservation() {
        let publisher = DisplayTopologyPublisher(
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            readTopology: readTopology
        )
        publisherToken = publisher.addObserver { [weak self] snapshot in
            self?.accept(snapshot)
        }
        self.publisher = publisher
        publisher.start()
        topologyFailure = publisher.lastFailure
    }

    func accept(_ snapshot: DisplayTopologySnapshot) {
        guard let settings, let configurationRevision else { return }
        do {
            let plan = try planner.makePlan(
                for: snapshot,
                settings: settings,
                sceneEpoch: configurationRevision,
                after: latestPlan?.topologyGeneration
            )
            latestSnapshot = snapshot
            latestPlan = plan
            lastFailure = nil
            topologyFailure = nil
        } catch {
            lastFailure = .planning(String(reflecting: error))
        }
    }

    func replanForConfigurationChange() {
        guard
            let snapshot = latestSnapshot,
            let settings,
            let configurationRevision
        else { return }

        do {
            latestPlan = try planner.makePlan(
                for: snapshot,
                settings: settings,
                sceneEpoch: configurationRevision
            )
            lastFailure = nil
        } catch {
            lastFailure = .planning(String(reflecting: error))
        }
    }
}
