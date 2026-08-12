import Foundation

public enum CameraCaptureRecoveryCause: Equatable, Sendable {
    case noDevice
    case permissionUnavailable
    case firstFrameTimeout
    case frameStall
    case startFailure
    case interruption
    case mediaServicesReset
}

public enum CameraCaptureRecoveryEvent: Equatable, Sendable {
    case activateAttempt(generation: UInt64)
    case failure(generation: UInt64, cause: CameraCaptureRecoveryCause)
    case deviceInventoryChanged(generation: UInt64, hasUsableDevice: Bool)
    case authorizationRefreshed(
        generation: UInt64,
        authorization: CameraAgentAuthorization
    )
    case retryDeadlineReached(generation: UInt64)
    case freshFrame(generation: UInt64)
}

public enum CameraCaptureRecoveryDecision: Equatable, Sendable {
    case none
    case waitForDeviceInventory(generation: UInt64)
    case waitForAuthorizationRefresh(generation: UInt64)
    case scheduleRetry(
        generation: UInt64,
        cause: CameraCaptureRecoveryCause,
        attempt: UInt64,
        after: TimeInterval,
        deadline: TimeInterval
    )
    case retryImmediately(
        generation: UInt64,
        cause: CameraCaptureRecoveryCause
    )
    case healthy(generation: UInt64)
    case ignoredStaleCallback(
        expectedGeneration: UInt64?,
        actualGeneration: UInt64
    )
    case invalidGeneration(UInt64)
    case invalidTime(TimeInterval)
}

/// Scheduler-independent capture recovery decisions for one camera-agent
/// process. The runtime supplies monotonic time and schedules returned
/// deadlines; this type performs no I/O and owns no timers.
public struct CameraCaptureRecoveryPolicy: Sendable {
    public static let boundedBackoffDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 5]

    public private(set) var currentGeneration: UInt64?
    public private(set) var backoffAttempt: UInt64 = 0

    private enum PendingRecovery: Sendable {
        case deviceInventory(generation: UInt64)
        case authorizationRefresh(generation: UInt64)
        case scheduled(
            generation: UInt64,
            cause: CameraCaptureRecoveryCause,
            attempt: UInt64,
            deadline: TimeInterval
        )
        case retryIssued(generation: UInt64, cause: CameraCaptureRecoveryCause)
    }

    private var pendingRecovery: PendingRecovery?
    private var usedImmediateMediaServicesRetry = false

    public init() {}

    public mutating func handle(
        _ event: CameraCaptureRecoveryEvent,
        now: TimeInterval
    ) -> CameraCaptureRecoveryDecision {
        guard now.isFinite, now >= 0 else {
            return .invalidTime(now)
        }

        if case let .activateAttempt(generation) = event {
            return activate(generation: generation)
        }

        let eventGeneration = generation(for: event)
        guard eventGeneration > 0 else {
            return .invalidGeneration(eventGeneration)
        }
        guard eventGeneration == currentGeneration else {
            return .ignoredStaleCallback(
                expectedGeneration: currentGeneration,
                actualGeneration: eventGeneration
            )
        }

        switch event {
        case .activateAttempt:
            return .none

        case let .failure(generation, cause):
            return handleFailure(
                generation: generation,
                cause: cause,
                now: now
            )

        case let .deviceInventoryChanged(generation, hasUsableDevice):
            guard hasUsableDevice else {
                if case .deviceInventory(generation) = pendingRecovery {
                    return .waitForDeviceInventory(generation: generation)
                }
                return .none
            }

            let cause: CameraCaptureRecoveryCause
            if case .deviceInventory(generation) = pendingRecovery {
                cause = .noDevice
            } else if case let .scheduled(
                scheduledGeneration,
                scheduledCause,
                _,
                _
            ) = pendingRecovery,
            scheduledGeneration == generation {
                cause = scheduledCause
            } else {
                return .none
            }

            pendingRecovery = .retryIssued(
                generation: generation,
                cause: cause
            )
            return .retryImmediately(generation: generation, cause: cause)

        case let .authorizationRefreshed(generation, authorization):
            guard case .authorizationRefresh(generation) = pendingRecovery else {
                return .none
            }
            guard authorization == .authorized else {
                return .waitForAuthorizationRefresh(generation: generation)
            }
            pendingRecovery = .retryIssued(
                generation: generation,
                cause: .permissionUnavailable
            )
            return .retryImmediately(
                generation: generation,
                cause: .permissionUnavailable
            )

        case let .retryDeadlineReached(generation):
            guard case let .scheduled(
                scheduledGeneration,
                cause,
                _,
                deadline
            ) = pendingRecovery,
            scheduledGeneration == generation else {
                return .none
            }
            guard now >= deadline else { return .none }
            pendingRecovery = .retryIssued(
                generation: generation,
                cause: cause
            )
            return .retryImmediately(generation: generation, cause: cause)

        case let .freshFrame(generation):
            backoffAttempt = 0
            usedImmediateMediaServicesRetry = false
            pendingRecovery = nil
            return .healthy(generation: generation)
        }
    }

    private mutating func activate(
        generation: UInt64
    ) -> CameraCaptureRecoveryDecision {
        guard generation > 0 else {
            return .invalidGeneration(generation)
        }
        if let currentGeneration {
            guard generation >= currentGeneration else {
                return .ignoredStaleCallback(
                    expectedGeneration: currentGeneration,
                    actualGeneration: generation
                )
            }
            guard generation > currentGeneration else { return .none }
        }
        currentGeneration = generation
        pendingRecovery = nil
        return .none
    }

    private mutating func handleFailure(
        generation: UInt64,
        cause: CameraCaptureRecoveryCause,
        now: TimeInterval
    ) -> CameraCaptureRecoveryDecision {
        guard pendingRecovery == nil else { return .none }

        switch cause {
        case .noDevice:
            pendingRecovery = .deviceInventory(generation: generation)
            return .waitForDeviceInventory(generation: generation)

        case .permissionUnavailable:
            pendingRecovery = .authorizationRefresh(generation: generation)
            return .waitForAuthorizationRefresh(generation: generation)

        case .mediaServicesReset where !usedImmediateMediaServicesRetry:
            usedImmediateMediaServicesRetry = true
            pendingRecovery = .retryIssued(
                generation: generation,
                cause: cause
            )
            return .retryImmediately(generation: generation, cause: cause)

        case .firstFrameTimeout,
             .frameStall,
             .startFailure,
             .interruption,
             .mediaServicesReset:
            return scheduleBackoff(
                generation: generation,
                cause: cause,
                now: now
            )
        }
    }

    private mutating func scheduleBackoff(
        generation: UInt64,
        cause: CameraCaptureRecoveryCause,
        now: TimeInterval
    ) -> CameraCaptureRecoveryDecision {
        let delayIndex: Int
        if backoffAttempt >= UInt64(Self.boundedBackoffDelays.count) {
            delayIndex = Self.boundedBackoffDelays.count - 1
        } else {
            delayIndex = Int(backoffAttempt)
        }
        let delay = Self.boundedBackoffDelays[delayIndex]
        let deadline = now + delay
        guard deadline.isFinite else { return .invalidTime(now) }

        if backoffAttempt < UInt64.max {
            backoffAttempt += 1
        }
        let attempt = backoffAttempt
        pendingRecovery = .scheduled(
            generation: generation,
            cause: cause,
            attempt: attempt,
            deadline: deadline
        )
        return .scheduleRetry(
            generation: generation,
            cause: cause,
            attempt: attempt,
            after: delay,
            deadline: deadline
        )
    }

    private func generation(for event: CameraCaptureRecoveryEvent) -> UInt64 {
        switch event {
        case let .activateAttempt(generation),
             let .failure(generation, _),
             let .deviceInventoryChanged(generation, _),
             let .authorizationRefreshed(generation, _),
             let .retryDeadlineReached(generation),
             let .freshFrame(generation):
            return generation
        }
    }
}
