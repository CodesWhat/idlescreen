import Foundation

/// The observed state of the per-user LaunchAgent that hosts camera capture.
///
/// This domain value deliberately has no dependency on `SMAppService`. The
/// companion maps its ServiceManagement observation into this value.
public enum CameraAgentServiceRegistration: Equatable, Sendable {
    case unknown
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case failed
}

/// Whether the helper embedded in this app, the artifact registered with
/// Service Management, and the running helper all describe the same build.
/// `current` is the only state that permits readiness to advance.
public enum CameraAgentHelperIdentityObservation: Equatable, Sendable {
    case unknown
    case absent
    case stale
    case mismatched
    case current
}

/// Whether the current helper generation returned a live diagnostic snapshot
/// over the authenticated XPC connection.
public enum CameraAgentLiveSnapshotObservation: Equatable, Sendable {
    case unknown
    case unavailable
    case rejected
    case accepted
}

/// The companion must distinguish an authorization value it actually read
/// from the agent from its inert startup state. `unknown` never implies that
/// the user has or has not made a TCC choice.
public enum CameraAgentAuthorizationObservation: Equatable, Sendable {
    case unknown
    case observed(CameraAgentAuthorization)
}

/// Whether a bounded control request can currently reach the camera agent.
public enum CameraAgentControlReachability: Equatable, Sendable {
    case unknown
    case reachable
    case unreachable
    case timedOut
}

/// Whether the consumer has received usable frame evidence from the agent.
public enum CameraAgentFrameReadiness: Equatable, Sendable {
    case unknown
    case awaitingFirstFrame
    case ready
    case unavailable
    case stalled
}

public enum CameraAgentReadinessRefreshTarget: Equatable, Sendable {
    case clientRuntime
    case serviceRegistration
    case identity
    case liveSnapshot
    case authorization
    case control
    case frameReadiness
}

/// A surface the companion may offer to open after a visible user action.
/// The state machine never opens a surface itself.
public enum CameraAgentRepairSurface: Equatable, Sendable {
    case backgroundItemsSettings
    case cameraPrivacySettings
    case cameraAgentDiagnostics
}

/// The single repair that should be visible for the current blocking layer.
public enum CameraAgentReadinessRepair: Equatable, Sendable {
    case registerAgent
    case requestCameraAuthorization
    case refresh(CameraAgentReadinessRefreshTarget)
    case openRepairSurface(CameraAgentRepairSurface)
}

public enum CameraAgentReadinessBlocker: Equatable, Sendable {
    case serviceRegistration(CameraAgentServiceRegistration)
    case identity(CameraAgentHelperIdentityObservation)
    case liveSnapshot(CameraAgentLiveSnapshotObservation)
    case authorization(CameraAgentAuthorizationObservation)
    case control(CameraAgentControlReachability)
    case frame(CameraAgentFrameReadiness)
}

public struct CameraAgentOnboardingSnapshot: Equatable, Sendable {
    public var serviceRegistration: CameraAgentServiceRegistration
    public var authorization: CameraAgentAuthorizationObservation
    public var control: CameraAgentControlReachability
    public var frame: CameraAgentFrameReadiness
    public var identity: CameraAgentHelperIdentityObservation
    public var liveSnapshot: CameraAgentLiveSnapshotObservation

    public init(
        serviceRegistration: CameraAgentServiceRegistration,
        authorization: CameraAgentAuthorizationObservation,
        control: CameraAgentControlReachability,
        frame: CameraAgentFrameReadiness,
        identity: CameraAgentHelperIdentityObservation = .unknown,
        liveSnapshot: CameraAgentLiveSnapshotObservation = .unknown
    ) {
        self.serviceRegistration = serviceRegistration
        self.authorization = authorization
        self.control = control
        self.frame = frame
        self.identity = identity
        self.liveSnapshot = liveSnapshot
    }

    /// Registration gates exact helper identity and a live authenticated agent
    /// snapshot, followed by authorization, control, and frame evidence. A
    /// lower-layer regression invalidates observations that depended on it, so
    /// readiness always requires evidence from the current service epoch.
    public var blocker: CameraAgentReadinessBlocker? {
        if serviceRegistration != .enabled {
            return .serviceRegistration(serviceRegistration)
        }
        if identity != .current {
            return .identity(identity)
        }
        if liveSnapshot != .accepted {
            return .liveSnapshot(liveSnapshot)
        }
        if authorization != .observed(.authorized) {
            return .authorization(authorization)
        }
        if control != .reachable {
            return .control(control)
        }
        if frame != .ready {
            return .frame(frame)
        }
        return nil
    }

    public var recommendedRepair: CameraAgentReadinessRepair? {
        switch blocker {
        case .serviceRegistration(.unknown):
            return .refresh(.serviceRegistration)
        case .serviceRegistration(.notRegistered),
             .serviceRegistration(.notFound):
            return .registerAgent
        case .serviceRegistration(.requiresApproval):
            return .openRepairSurface(.backgroundItemsSettings)
        case .serviceRegistration(.failed):
            return .openRepairSurface(.cameraAgentDiagnostics)
        case .serviceRegistration(.enabled):
            return nil

        case .identity(.unknown):
            return .refresh(.identity)
        case .identity(.absent), .identity(.stale), .identity(.mismatched):
            return .openRepairSurface(.cameraAgentDiagnostics)
        case .identity(.current):
            return nil

        case .liveSnapshot(.unknown), .liveSnapshot(.unavailable):
            return .refresh(.liveSnapshot)
        case .liveSnapshot(.rejected):
            return .openRepairSurface(.cameraAgentDiagnostics)
        case .liveSnapshot(.accepted):
            return nil

        case .authorization(.unknown):
            return .refresh(.authorization)
        case .authorization(.observed(.notDetermined)):
            return .requestCameraAuthorization
        case .authorization(.observed(.denied)),
             .authorization(.observed(.restricted)):
            return .openRepairSurface(.cameraPrivacySettings)
        case .authorization(.observed(.authorized)):
            return nil

        case .control(.unknown), .control(.unreachable), .control(.timedOut):
            return .refresh(.control)
        case .control(.reachable):
            return nil

        case .frame(.unknown), .frame(.awaitingFirstFrame),
             .frame(.unavailable), .frame(.stalled):
            return .refresh(.frameReadiness)
        case .frame(.ready):
            return nil

        case nil:
            return nil
        }
    }

    public var isReady: Bool {
        blocker == nil
    }
}

public enum CameraAgentOnboardingEvent: Equatable, Sendable {
    /// A routine status read. Crossing into or out of `.enabled` establishes
    /// a new service epoch; repeated `.enabled` reads preserve readiness.
    case serviceRegistrationObserved(CameraAgentServiceRegistration)

    /// An observed helper replacement or explicit re-registration boundary,
    /// including when both the old and new status are `.enabled`.
    case serviceRegistrationBoundaryObserved(CameraAgentServiceRegistration)
    case identityObserved(
        CameraAgentHelperIdentityObservation,
        generationIdentifier: String
    )
    case liveSnapshotObserved(
        CameraAgentLiveSnapshotObservation,
        serviceEpoch: UInt64
    )
    case authorizationObserved(
        CameraAgentAuthorization,
        serviceEpoch: UInt64
    )
    case controlObserved(
        CameraAgentControlReachability,
        serviceEpoch: UInt64
    )
    case frameObserved(
        CameraAgentFrameReadiness,
        serviceEpoch: UInt64
    )

    /// A click or equivalent interaction on the currently visible repair.
    case visibleRepair(CameraAgentReadinessRepair)
}

/// Commands for an outer companion layer to interpret after visible intent.
/// This module never registers a service, requests TCC, launches a process, or
/// opens a settings surface.
public enum CameraAgentOnboardingAction: Equatable, Sendable {
    case registerAgent(within: TimeInterval)
    case requestCameraAuthorization
    case refresh(CameraAgentReadinessRefreshTarget, within: TimeInterval)
    case openRepairSurface(CameraAgentRepairSurface)
}

/// A pure aggregate reducer for companion onboarding and camera readiness.
public struct CameraAgentOnboardingStateMachine: Sendable {
    public static let maximumRepairLatency: TimeInterval = 2

    public private(set) var serviceRegistration: CameraAgentServiceRegistration
    public private(set) var serviceEpoch: UInt64
    public private(set) var authorization: CameraAgentAuthorizationObservation
    public private(set) var control: CameraAgentControlReachability
    public private(set) var frame: CameraAgentFrameReadiness
    public private(set) var identity: CameraAgentHelperIdentityObservation
    public private(set) var identityGenerationIdentifier: String?
    public private(set) var liveSnapshot: CameraAgentLiveSnapshotObservation

    public init(
        serviceRegistration: CameraAgentServiceRegistration = .unknown,
        serviceEpoch: UInt64 = 0,
        authorization: CameraAgentAuthorizationObservation = .unknown,
        control: CameraAgentControlReachability = .unknown,
        frame: CameraAgentFrameReadiness = .unknown,
        identity: CameraAgentHelperIdentityObservation = .unknown,
        identityGenerationIdentifier: String? = nil,
        liveSnapshot: CameraAgentLiveSnapshotObservation = .unknown
    ) {
        self.serviceRegistration = serviceRegistration
        self.serviceEpoch = serviceEpoch
        self.authorization = authorization
        self.control = control
        self.frame = frame
        self.identity = identity
        self.identityGenerationIdentifier = identityGenerationIdentifier
        self.liveSnapshot = liveSnapshot
    }

    public var snapshot: CameraAgentOnboardingSnapshot {
        CameraAgentOnboardingSnapshot(
            serviceRegistration: serviceRegistration,
            authorization: authorization,
            control: control,
            frame: frame,
            identity: identity,
            liveSnapshot: liveSnapshot
        )
    }

    public mutating func handle(
        _ event: CameraAgentOnboardingEvent
    ) -> [CameraAgentOnboardingAction] {
        switch event {
        case let .serviceRegistrationObserved(observation):
            observeServiceRegistration(
                observation,
                establishesNewBoundary: false
            )
            return []

        case let .serviceRegistrationBoundaryObserved(observation):
            observeServiceRegistration(
                observation,
                establishesNewBoundary: true
            )
            return []

        case let .identityObserved(observation, generationIdentifier):
            guard serviceRegistration == .enabled else { return [] }
            let establishesNewBoundary = identityGenerationIdentifier
                != generationIdentifier || identity != observation
            if establishesNewBoundary {
                serviceEpoch &+= 1
                invalidateLiveSnapshotAndDependents()
            }
            identity = observation
            identityGenerationIdentifier = generationIdentifier
            if observation != .current {
                invalidateLiveSnapshotAndDependents()
            }
            return []

        case let .liveSnapshotObserved(observation, observedServiceEpoch):
            guard serviceRegistration == .enabled,
                  identity == .current,
                  observedServiceEpoch == serviceEpoch else {
                return []
            }
            liveSnapshot = observation
            if observation != .accepted {
                authorization = .unknown
                invalidateControlAndFrame()
            }
            return []

        case let .authorizationObserved(observation, observedServiceEpoch):
            guard serviceRegistration == .enabled,
                  observedServiceEpoch == serviceEpoch else {
                return []
            }
            authorization = .observed(observation)
            if observation != .authorized {
                invalidateControlAndFrame()
            }
            return []

        case let .controlObserved(observation, observedServiceEpoch):
            guard serviceRegistration == .enabled,
                  authorization == .observed(.authorized),
                  observedServiceEpoch == serviceEpoch else {
                return []
            }
            control = observation
            if observation != .reachable {
                frame = .unknown
            }
            return []

        case let .frameObserved(observation, observedServiceEpoch):
            guard serviceRegistration == .enabled,
                  authorization == .observed(.authorized),
                  control == .reachable,
                  observedServiceEpoch == serviceEpoch else {
                return []
            }
            frame = observation
            return []

        case let .visibleRepair(repair):
            guard repair == snapshot.recommendedRepair else { return [] }
            return [action(for: repair)]
        }
    }

    private mutating func observeServiceRegistration(
        _ observation: CameraAgentServiceRegistration,
        establishesNewBoundary: Bool
    ) {
        let crossesEnabledBoundary = (serviceRegistration == .enabled)
            != (observation == .enabled)
        if establishesNewBoundary || crossesEnabledBoundary {
            serviceEpoch &+= 1
            invalidateIdentityAndDependents()
        } else if observation != .enabled {
            invalidateIdentityAndDependents()
        }
        serviceRegistration = observation
    }

    private mutating func invalidateIdentityAndDependents() {
        identity = .unknown
        identityGenerationIdentifier = nil
        invalidateLiveSnapshotAndDependents()
    }

    private mutating func invalidateLiveSnapshotAndDependents() {
        liveSnapshot = .unknown
        authorization = .unknown
        invalidateControlAndFrame()
    }

    private mutating func invalidateControlAndFrame() {
        control = .unknown
        frame = .unknown
    }

    private func action(
        for repair: CameraAgentReadinessRepair
    ) -> CameraAgentOnboardingAction {
        switch repair {
        case .registerAgent:
            return .registerAgent(within: Self.maximumRepairLatency)
        case .requestCameraAuthorization:
            return .requestCameraAuthorization
        case let .refresh(target):
            return .refresh(target, within: Self.maximumRepairLatency)
        case let .openRepairSurface(surface):
            return .openRepairSurface(surface)
        }
    }
}
