import Foundation

public enum CameraAgentAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public enum CameraAgentFallbackReason: Equatable, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case deviceUnavailable
    case interrupted
    case sleeping
}

public struct CameraAgentRuntimeError: Equatable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

public enum CameraAgentStatus: Equatable, Sendable {
    case idle
    case permissionRequired
    case requestingPermission
    case starting
    case awaitingFirstFrame
    case streaming
    case stopping
    case fallback(CameraAgentFallbackReason)
    case failed(CameraAgentRuntimeError)
}

public struct CameraAgentSnapshot: Equatable, Sendable {
    public var status: CameraAgentStatus
    public var authorization: CameraAgentAuthorization
    public var activeLeaseDemand: Int
    public var generation: UInt64
    public var sequence: UInt64

    public init(
        status: CameraAgentStatus,
        authorization: CameraAgentAuthorization,
        activeLeaseDemand: Int,
        generation: UInt64,
        sequence: UInt64
    ) {
        self.status = status
        self.authorization = authorization
        self.activeLeaseDemand = activeLeaseDemand
        self.generation = generation
        self.sequence = sequence
    }
}

public enum CameraAgentEvent: Equatable, Sendable {
    case visiblePermissionAction
    case permissionResult(CameraAgentAuthorization)
    case leaseDemandChanged(count: Int)
    case captureStarted(generation: UInt64)
    case captureStopped(generation: UInt64)
    case firstFrame(generation: UInt64, sequence: UInt64)
    case nextFrame(generation: UInt64, sequence: UInt64)
    case runtimeInterrupted(generation: UInt64)
    case runtimeError(generation: UInt64, failure: CameraAgentRuntimeError)
    case recoveryRetryReady(generation: UInt64)
    case deviceUnavailable
    case deviceAvailable
    case sleep
    case wake
}

public enum CameraAgentAction: Equatable, Sendable {
    case requestPermission
    case configureCapture(generation: UInt64)
    case startCapture(generation: UInt64)
    case stopCapture(generation: UInt64, within: TimeInterval)
    case scheduleRecovery(generation: UInt64, after: TimeInterval)
    case publish(CameraAgentSnapshot)
}

/// A pure reducer for a camera agent's serialized control queue.
///
/// The caller owns serialization and enforces the deadline carried by a stop
/// action. This type performs no I/O, schedules no timers, and accesses no
/// process-global state.
public struct CameraAgentStateMachine: Sendable {
    public static let maximumStopLatency: TimeInterval = 2

    public private(set) var authorization: CameraAgentAuthorization
    public private(set) var activeLeaseDemand = 0
    public private(set) var generation: UInt64 = 0
    public private(set) var sequence: UInt64 = 0
    public private(set) var status: CameraAgentStatus = .idle

    private enum CaptureLifecycle: Sendable {
        case idle
        case starting
        case running
        case stopping
    }

    private var captureLifecycle: CaptureLifecycle = .idle
    private var captureGeneration: UInt64?
    private var permissionRequestOutstanding = false
    private var deviceIsAvailable: Bool
    private var isSleeping = false
    private var recoveryPendingGeneration: UInt64?

    public init(
        authorization: CameraAgentAuthorization,
        deviceIsAvailable: Bool = true
    ) {
        self.authorization = authorization
        self.deviceIsAvailable = deviceIsAvailable
    }

    public mutating func handle(_ event: CameraAgentEvent) -> [CameraAgentAction] {
        switch event {
        case .visiblePermissionAction:
            return handleVisiblePermissionAction()

        case let .permissionResult(result):
            return handlePermissionResult(result)

        case let .leaseDemandChanged(count):
            return handleLeaseDemandChanged(count)

        case let .captureStarted(eventGeneration):
            guard eventGeneration == captureGeneration,
                  captureLifecycle == .starting else {
                return []
            }
            captureLifecycle = .running
            status = .awaitingFirstFrame
            return publish()

        case let .captureStopped(eventGeneration):
            return handleCaptureStopped(generation: eventGeneration)

        case let .firstFrame(eventGeneration, eventSequence):
            guard eventGeneration == captureGeneration,
                  captureLifecycle == .running,
                  status == .awaitingFirstFrame,
                  eventSequence > 0 else {
                return []
            }
            sequence = eventSequence
            status = .streaming
            return publish()

        case let .nextFrame(eventGeneration, eventSequence):
            guard eventGeneration == captureGeneration,
                  captureLifecycle == .running,
                  status == .streaming,
                  eventSequence > sequence else {
                return []
            }
            sequence = eventSequence
            return publish()

        case let .runtimeInterrupted(eventGeneration):
            guard isCurrentActiveGeneration(eventGeneration) else { return [] }
            recoveryPendingGeneration = eventGeneration
            return stopCurrentCapture(
                status: .fallback(.interrupted),
                publishBeforeStop: true
            )

        case let .runtimeError(eventGeneration, failure):
            guard isCurrentActiveGeneration(eventGeneration) else { return [] }
            recoveryPendingGeneration = eventGeneration
            return stopCurrentCapture(status: .failed(failure), publishBeforeStop: true)

        case let .recoveryRetryReady(eventGeneration):
            guard recoveryPendingGeneration == eventGeneration else { return [] }
            recoveryPendingGeneration = nil
            guard captureLifecycle == .idle else { return [] }
            return reconcileDemand()

        case .deviceUnavailable:
            guard deviceIsAvailable else { return [] }
            deviceIsAvailable = false
            if captureLifecycle != .idle {
                recoveryPendingGeneration = captureGeneration
                return stopCurrentCapture(
                    status: .fallback(.deviceUnavailable),
                    publishBeforeStop: true
                )
            }
            guard activeLeaseDemand > 0 else { return [] }
            status = .fallback(.deviceUnavailable)
            return publish()

        case .deviceAvailable:
            guard !deviceIsAvailable else { return [] }
            deviceIsAvailable = true
            guard captureLifecycle == .idle else { return [] }
            return reconcileDemand()

        case .sleep:
            guard !isSleeping else { return [] }
            isSleeping = true
            if captureLifecycle != .idle {
                return stopCurrentCapture(
                    status: .fallback(.sleeping),
                    publishBeforeStop: true
                )
            }
            guard activeLeaseDemand > 0 else { return [] }
            status = .fallback(.sleeping)
            return publish()

        case .wake:
            guard isSleeping else { return [] }
            isSleeping = false
            guard captureLifecycle == .idle else { return [] }
            return reconcileDemand()
        }
    }

    private mutating func handleVisiblePermissionAction() -> [CameraAgentAction] {
        guard authorization == .notDetermined,
              !permissionRequestOutstanding else {
            return []
        }
        permissionRequestOutstanding = true
        status = .requestingPermission
        return [.requestPermission] + publish()
    }

    private mutating func handlePermissionResult(
        _ result: CameraAgentAuthorization
    ) -> [CameraAgentAction] {
        let changed = result != authorization
        guard changed || permissionRequestOutstanding else { return [] }

        authorization = result
        permissionRequestOutstanding = false

        if result != .authorized, captureLifecycle != .idle {
            recoveryPendingGeneration = captureGeneration
            return stopCurrentCapture(
                status: unavailableAuthorizationStatus(for: result),
                publishBeforeStop: true
            )
        }
        guard captureLifecycle == .idle else { return publish() }
        return reconcileDemand()
    }

    private mutating func handleLeaseDemandChanged(_ count: Int) -> [CameraAgentAction] {
        guard count >= 0, count != activeLeaseDemand else { return [] }
        let previouslyDemanded = activeLeaseDemand > 0
        activeLeaseDemand = count

        if count == 0 {
            recoveryPendingGeneration = nil
            if captureLifecycle == .stopping {
                status = .stopping
                return publish()
            }
            if captureLifecycle != .idle {
                return stopCurrentCapture(status: .stopping, publishBeforeStop: false)
            }
            status = .idle
            sequence = 0
            return publish()
        }

        if previouslyDemanded || captureLifecycle != .idle {
            return publish()
        }
        return reconcileDemand()
    }

    private mutating func handleCaptureStopped(
        generation eventGeneration: UInt64
    ) -> [CameraAgentAction] {
        guard eventGeneration == captureGeneration,
              captureLifecycle != .idle else {
            return []
        }

        let stoppedUnexpectedly = captureLifecycle != .stopping
        var actions: [CameraAgentAction] = []
        if stoppedUnexpectedly, activeLeaseDemand > 0 {
            status = .fallback(.interrupted)
            actions += publish()
        }

        captureLifecycle = .idle
        captureGeneration = nil
        sequence = 0
        actions += reconcileDemand()
        return actions
    }

    private mutating func reconcileDemand() -> [CameraAgentAction] {
        guard activeLeaseDemand > 0 else {
            let shouldPublish = status != .idle || sequence != 0
            status = .idle
            sequence = 0
            return shouldPublish ? publish() : []
        }
        guard captureLifecycle == .idle else { return [] }

        if recoveryPendingGeneration != nil {
            return publish()
        }

        if isSleeping {
            status = .fallback(.sleeping)
            return publish()
        }
        if !deviceIsAvailable {
            status = .fallback(.deviceUnavailable)
            return publish()
        }

        switch authorization {
        case .authorized:
            return beginCapture()
        case .notDetermined:
            status = permissionRequestOutstanding ? .requestingPermission : .permissionRequired
        case .denied:
            status = .fallback(.authorizationDenied)
        case .restricted:
            status = .fallback(.authorizationRestricted)
        }
        return publish()
    }

    private mutating func beginCapture() -> [CameraAgentAction] {
        guard captureLifecycle == .idle,
              activeLeaseDemand > 0,
              authorization == .authorized,
              deviceIsAvailable,
              !isSleeping else {
            return []
        }

        guard generation < .max else {
            status = .failed(CameraAgentRuntimeError(code: "generation-exhausted"))
            return publish()
        }

        generation += 1
        sequence = 0
        captureGeneration = generation
        captureLifecycle = .starting
        recoveryPendingGeneration = nil
        status = .starting
        return [
            .configureCapture(generation: generation),
            .startCapture(generation: generation),
        ] + publish()
    }

    private mutating func stopCurrentCapture(
        status nextStatus: CameraAgentStatus,
        publishBeforeStop: Bool
    ) -> [CameraAgentAction] {
        guard captureLifecycle != .idle,
              captureLifecycle != .stopping,
              let captureGeneration else {
            return []
        }

        status = nextStatus
        captureLifecycle = .stopping
        let stop = CameraAgentAction.stopCapture(
            generation: captureGeneration,
            within: Self.maximumStopLatency
        )
        return publishBeforeStop ? publish() + [stop] : [stop] + publish()
    }

    private func isCurrentActiveGeneration(_ eventGeneration: UInt64) -> Bool {
        eventGeneration == captureGeneration
            && captureLifecycle != .idle
            && captureLifecycle != .stopping
    }

    private func unavailableAuthorizationStatus(
        for authorization: CameraAgentAuthorization
    ) -> CameraAgentStatus {
        switch authorization {
        case .notDetermined:
            return .permissionRequired
        case .denied:
            return .fallback(.authorizationDenied)
        case .restricted:
            return .fallback(.authorizationRestricted)
        case .authorized:
            return status
        }
    }

    private func publish() -> [CameraAgentAction] {
        [.publish(CameraAgentSnapshot(
            status: status,
            authorization: authorization,
            activeLeaseDemand: activeLeaseDemand,
            generation: generation,
            sequence: sequence
        ))]
    }
}
