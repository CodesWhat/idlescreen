import AppKit
import Foundation
import IdleScreenCore

/// A process-local publication wrapper. Generations describe accepted topology
/// changes and are deliberately not persisted inside `DisplayTopology`.
public struct DisplayTopologySnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let topology: DisplayTopology

    public init(generation: UInt64, topology: DisplayTopology) {
        self.generation = generation
        self.topology = topology
    }

    public func isNewer(than acceptedGeneration: UInt64?) -> Bool {
        guard let acceptedGeneration else { return true }
        return generation > acceptedGeneration
    }
}

public struct DisplayTopologyPublicationFailure: Equatable, Sendable {
    public let attempt: UInt64
    public let message: String

    public init(attempt: UInt64, message: String) {
        self.attempt = attempt
        self.message = message
    }
}

public struct DisplayTopologyObserverToken: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

private final class DisplayTopologyNotificationRegistration:
    @unchecked Sendable
{
    private let notificationCenter: NotificationCenter
    private let token: any NSObjectProtocol

    init(
        notificationCenter: NotificationCenter,
        token: any NSObjectProtocol
    ) {
        self.notificationCenter = notificationCenter
        self.token = token
    }

    func cancel() {
        notificationCenter.removeObserver(token)
    }

    deinit {
        notificationCenter.removeObserver(token)
    }
}

/// Main-actor publication keeps AppKit observation, generation assignment, and
/// listener delivery in one serialized domain. Equal snapshots are suppressed;
/// a failed read never replaces or advances the last accepted generation.
@MainActor
public final class DisplayTopologyPublisher {
    public typealias Reader = @MainActor () throws -> DisplayTopology
    public typealias Observer = @MainActor (DisplayTopologySnapshot) -> Void

    public private(set) var latestSnapshot: DisplayTopologySnapshot?
    public private(set) var lastFailure: DisplayTopologyPublicationFailure?

    private let notificationCenter: NotificationCenter
    private let notificationName: Notification.Name
    private let readTopology: Reader
    private var notificationRegistration: DisplayTopologyNotificationRegistration?
    private var observers: [DisplayTopologyObserverToken: Observer] = [:]
    private var readAttempt: UInt64 = 0

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
        readTopology: @escaping Reader
    ) {
        self.notificationCenter = notificationCenter
        self.notificationName = notificationName
        self.readTopology = readTopology
    }

    public func start() {
        guard notificationRegistration == nil else { return }
        let token = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        notificationRegistration = .init(
            notificationCenter: notificationCenter,
            token: token
        )
        refresh()
    }

    public func stop() {
        notificationRegistration?.cancel()
        notificationRegistration = nil
    }

    public func refresh() {
        if readAttempt < UInt64.max {
            readAttempt += 1
        }

        do {
            let topology = try readTopology()
            lastFailure = nil
            guard topology != latestSnapshot?.topology else { return }

            let nextGeneration: UInt64
            if let generation = latestSnapshot?.generation {
                let increment = generation.addingReportingOverflow(1)
                guard !increment.overflow else {
                    lastFailure = .init(
                        attempt: readAttempt,
                        message: "Display topology generation is exhausted."
                    )
                    return
                }
                nextGeneration = increment.partialValue
            } else {
                nextGeneration = 1
            }

            let snapshot = DisplayTopologySnapshot(
                generation: nextGeneration,
                topology: topology
            )
            latestSnapshot = snapshot
            let currentObservers = Array(observers.values)
            for observer in currentObservers {
                observer(snapshot)
            }
        } catch {
            lastFailure = .init(
                attempt: readAttempt,
                message: String(reflecting: error)
            )
        }
    }

    @discardableResult
    public func addObserver(
        _ observer: @escaping Observer
    ) -> DisplayTopologyObserverToken {
        let token = DisplayTopologyObserverToken(rawValue: UUID())
        observers[token] = observer
        if let latestSnapshot {
            observer(latestSnapshot)
        }
        return token
    }

    public func removeObserver(_ token: DisplayTopologyObserverToken) {
        observers.removeValue(forKey: token)
    }
}
