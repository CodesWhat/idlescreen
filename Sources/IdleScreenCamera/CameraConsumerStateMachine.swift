import Foundation

public protocol CameraConsumerClock: Sendable {
    var now: TimeInterval { get }
}

public enum CameraConsumerState: Equatable, Sendable {
    case disconnected
    case connecting(attempt: UInt64)
    case streaming(attempt: UInt64, streamEpoch: UInt64)
    case fallback(reason: CameraConsumerFallbackReason)
}

public enum CameraConsumerFallbackReason: Equatable, Sendable {
    case interrupted
    case invalidated
    case connectionFailed
    case authorizationDenied
    case unavailable
}

public enum CameraConsumerEvent: Equatable, Sendable {
    case start
    case stop
    case connectionEstablished(attempt: UInt64, streamEpoch: UInt64)
    case connectionFailed(attempt: UInt64)
    case frame(attempt: UInt64, streamEpoch: UInt64, sequence: UInt64)
    case interrupted(attempt: UInt64)
    case invalidated(attempt: UInt64)
    case reconnectDue(attempt: UInt64)
    case authorizationDenied(attempt: UInt64)
    case unavailable(attempt: UInt64)
    case externalRetry
}

public enum CameraConsumerAction: Equatable, Sendable {
    case connect(attempt: UInt64)
    case beginStreaming(attempt: UInt64, streamEpoch: UInt64)
    case acceptFrame(attempt: UInt64, streamEpoch: UInt64, sequence: UInt64)
    case scheduleReconnect(attempt: UInt64, after: TimeInterval, deadline: TimeInterval)
    case cancelReconnect(attempt: UInt64)
    case disconnect(attempt: UInt64)
}

public struct CameraConsumerStateMachine<Clock: CameraConsumerClock>: Sendable {
    public private(set) var state: CameraConsumerState = .disconnected

    private let clock: Clock
    private var latestAttempt: UInt64 = 0
    private var lastAcceptedFrameSequence: UInt64?
    private var retryIndex = 0
    private var scheduledReconnect: (attempt: UInt64, deadline: TimeInterval)?

    public init(clock: Clock) {
        self.clock = clock
    }

    public mutating func handle(_ event: CameraConsumerEvent) -> [CameraConsumerAction] {
        switch event {
        case .start:
            guard state == .disconnected else { return [] }
            latestAttempt += 1
            state = .connecting(attempt: latestAttempt)
            return [.connect(attempt: latestAttempt)]

        case .stop:
            guard state != .disconnected else { return [] }
            let action: CameraConsumerAction?
            if isActive(attempt: latestAttempt) {
                action = .disconnect(attempt: latestAttempt)
            } else if scheduledReconnect?.attempt == latestAttempt {
                action = .cancelReconnect(attempt: latestAttempt)
            } else {
                action = nil
            }
            scheduledReconnect = nil
            lastAcceptedFrameSequence = nil
            state = .disconnected
            return action.map { [$0] } ?? []

        case let .connectionEstablished(attempt, streamEpoch):
            guard state == .connecting(attempt: attempt),
                  attempt == latestAttempt,
                  streamEpoch > 0 else {
                return []
            }
            lastAcceptedFrameSequence = nil
            retryIndex = 0
            state = .streaming(attempt: attempt, streamEpoch: streamEpoch)
            return [.beginStreaming(attempt: attempt, streamEpoch: streamEpoch)]

        case let .connectionFailed(attempt):
            guard state == .connecting(attempt: attempt), attempt == latestAttempt else { return [] }
            state = .fallback(reason: .connectionFailed)
            return scheduleReconnect(for: attempt)

        case let .frame(attempt, streamEpoch, sequence):
            guard state == .streaming(attempt: attempt, streamEpoch: streamEpoch),
                  attempt == latestAttempt else {
                return []
            }
            guard lastAcceptedFrameSequence.map({ sequence > $0 }) ?? true else { return [] }
            lastAcceptedFrameSequence = sequence
            return [.acceptFrame(
                attempt: attempt,
                streamEpoch: streamEpoch,
                sequence: sequence
            )]

        case let .interrupted(attempt):
            guard attempt == latestAttempt, isActive(attempt: attempt) else { return [] }
            state = .fallback(reason: .interrupted)
            return scheduleReconnect(for: attempt)

        case let .invalidated(attempt):
            guard attempt == latestAttempt, isActive(attempt: attempt) else { return [] }
            state = .fallback(reason: .invalidated)
            return scheduleReconnect(for: attempt)

        case let .reconnectDue(attempt):
            guard let scheduledReconnect,
                  scheduledReconnect.attempt == attempt,
                  clock.now >= scheduledReconnect.deadline else {
                return []
            }
            self.scheduledReconnect = nil
            latestAttempt += 1
            state = .connecting(attempt: latestAttempt)
            return [.connect(attempt: latestAttempt)]

        case let .authorizationDenied(attempt):
            return enterFallbackAndScheduleReconnect(
                reason: .authorizationDenied,
                attempt: attempt
            )

        case let .unavailable(attempt):
            return enterFallbackAndScheduleReconnect(
                reason: .unavailable,
                attempt: attempt
            )

        case .externalRetry:
            guard state == .fallback(reason: .authorizationDenied)
                    || state == .fallback(reason: .unavailable) else {
                return []
            }
            scheduledReconnect = nil
            lastAcceptedFrameSequence = nil
            retryIndex = 0
            latestAttempt += 1
            state = .connecting(attempt: latestAttempt)
            return [.connect(attempt: latestAttempt)]
        }
    }

    private func isActive(attempt: UInt64) -> Bool {
        if state == .connecting(attempt: attempt) {
            return true
        }
        if case let .streaming(activeAttempt, _) = state {
            return activeAttempt == attempt
        }
        return false
    }

    private mutating func enterFallbackAndScheduleReconnect(
        reason: CameraConsumerFallbackReason,
        attempt: UInt64
    ) -> [CameraConsumerAction] {
        guard attempt == latestAttempt, state != .disconnected else { return [] }
        if state == .fallback(reason: reason),
           scheduledReconnect?.attempt == attempt {
            return []
        }

        let disconnect: CameraConsumerAction?
        if isActive(attempt: attempt) {
            disconnect = .disconnect(attempt: attempt)
        } else if scheduledReconnect?.attempt == attempt {
            disconnect = .cancelReconnect(attempt: attempt)
        } else {
            disconnect = nil
        }

        scheduledReconnect = nil
        state = .fallback(reason: reason)
        let reconnect = scheduleReconnect(for: attempt)
        return disconnect.map { [$0] + reconnect } ?? reconnect
    }

    private mutating func scheduleReconnect(for attempt: UInt64) -> [CameraConsumerAction] {
        let delay = reconnectDelay
        let deadline = clock.now + delay
        scheduledReconnect = (attempt, deadline)
        retryIndex += 1
        return [.scheduleReconnect(attempt: attempt, after: delay, deadline: deadline)]
    }

    private var reconnectDelay: TimeInterval {
        let delays: [TimeInterval] = [0.25, 0.5, 1, 2, 5]
        return delays[min(retryIndex, delays.count - 1)]
    }
}
