import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera consumer reconnect state machine")
struct CameraConsumerStateMachineTests {
    @Test("starting requests the first connection generation")
    func startRequestsConnection() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)

        let actions = machine.handle(.start)

        #expect(machine.state == .connecting(attempt: 1))
        #expect(actions == [.connect(attempt: 1)])
    }

    @Test("the current connection enters streaming and accepts increasing frames")
    func connectionSuccessAndFrames() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)

        #expect(machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 10)) == [
            .beginStreaming(attempt: 1, streamEpoch: 10)
        ])
        #expect(machine.state == .streaming(attempt: 1, streamEpoch: 10))
        #expect(machine.handle(.frame(attempt: 1, streamEpoch: 10, sequence: 8)) == [
            .acceptFrame(attempt: 1, streamEpoch: 10, sequence: 8)
        ])
        #expect(machine.handle(.frame(attempt: 1, streamEpoch: 10, sequence: 9)) == [
            .acceptFrame(attempt: 1, streamEpoch: 10, sequence: 9)
        ])
    }

    @Test("an interruption immediately falls back and schedules the first reconnect")
    func interruptionSchedulesReconnect() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)
        _ = machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 10))

        let actions = machine.handle(.interrupted(attempt: 1))

        #expect(machine.state == .fallback(reason: .interrupted))
        #expect(actions == [
            .scheduleReconnect(attempt: 1, after: 0.25, deadline: 100.25)
        ])
    }

    @Test("repeated invalidations back off to five seconds and stay capped")
    func reconnectBackoffIsCapped() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)

        for (offset, delay) in [0.25, 0.5, 1.0, 2.0, 5.0, 5.0].enumerated() {
            let attempt = UInt64(offset + 1)
            #expect(machine.handle(.invalidated(attempt: attempt)) == [
                .scheduleReconnect(
                    attempt: attempt,
                    after: delay,
                    deadline: clock.now + delay
                )
            ])
            #expect(machine.state == .fallback(reason: .invalidated))

            clock.now += delay
            #expect(machine.handle(.reconnectDue(attempt: attempt)) == [
                .connect(attempt: attempt + 1)
            ])
            #expect(machine.state == .connecting(attempt: attempt + 1))
        }
    }

    @Test("a successful stream resets the reconnect delay")
    func successfulStreamResetsBackoff() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)
        _ = machine.handle(.invalidated(attempt: 1))
        clock.now = 100.25
        _ = machine.handle(.reconnectDue(attempt: 1))
        _ = machine.handle(.connectionEstablished(attempt: 2, streamEpoch: 20))

        #expect(machine.handle(.interrupted(attempt: 2)) == [
            .scheduleReconnect(attempt: 2, after: 0.25, deadline: 100.5)
        ])
    }

    @Test("authorization denial falls back and retries with bounded backoff")
    func authorizationDenialRetriesWithBackoff() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)

        #expect(machine.handle(.authorizationDenied(attempt: 1)) == [
            .disconnect(attempt: 1),
            .scheduleReconnect(attempt: 1, after: 0.25, deadline: 100.25),
        ])
        #expect(machine.state == .fallback(reason: .authorizationDenied))
        #expect(machine.handle(.invalidated(attempt: 1)) == [])
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [])
        #expect(machine.state == .fallback(reason: .authorizationDenied))

        clock.now = 100.25
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [.connect(attempt: 2)])
        #expect(machine.state == .connecting(attempt: 2))
        #expect(machine.handle(.authorizationDenied(attempt: 2)) == [
            .disconnect(attempt: 2),
            .scheduleReconnect(attempt: 2, after: 0.5, deadline: 100.75),
        ])

        #expect(machine.handle(.externalRetry) == [.connect(attempt: 3)])
        #expect(machine.state == .connecting(attempt: 3))
        #expect(machine.handle(.externalRetry) == [])
    }

    @Test("camera unavailability falls back and retries automatically")
    func cameraUnavailableRetriesAutomatically() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)

        #expect(machine.handle(.unavailable(attempt: 1)) == [
            .disconnect(attempt: 1),
            .scheduleReconnect(attempt: 1, after: 0.25, deadline: 100.25),
        ])
        #expect(machine.state == .fallback(reason: .unavailable))
        clock.now = 100.25
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [.connect(attempt: 2)])
        #expect(machine.state == .connecting(attempt: 2))
    }

    @Test("invalidation of a streaming connection immediately schedules reconnect")
    func streamingInvalidationSchedulesReconnect() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)
        _ = machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 10))

        #expect(machine.handle(.invalidated(attempt: 1)) == [
            .scheduleReconnect(attempt: 1, after: 0.25, deadline: 100.25)
        ])
        #expect(machine.state == .fallback(reason: .invalidated))
    }

    @Test("interruption while connecting immediately schedules reconnect")
    func connectingInterruptionSchedulesReconnect() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)

        #expect(machine.handle(.interrupted(attempt: 1)) == [
            .scheduleReconnect(attempt: 1, after: 0.25, deadline: 100.25)
        ])
        #expect(machine.state == .fallback(reason: .interrupted))
    }

    @Test("a connection failure enters fallback and schedules reconnect")
    func connectionFailureSchedulesReconnect() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)

        #expect(machine.handle(.connectionFailed(attempt: 1)) == [
            .scheduleReconnect(attempt: 1, after: 0.25, deadline: 100.25)
        ])
        #expect(machine.state == .fallback(reason: .connectionFailed))
    }

    @Test("stopping invalidates the old epoch and is idempotent")
    func stopInvalidatesOldEpoch() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)
        _ = machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 10))

        #expect(machine.handle(.stop) == [.disconnect(attempt: 1)])
        #expect(machine.state == .disconnected)
        #expect(machine.handle(.stop) == [])

        #expect(machine.handle(.start) == [.connect(attempt: 2)])
        #expect(machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 11)) == [])
        #expect(machine.handle(.frame(attempt: 1, streamEpoch: 10, sequence: 100)) == [])
        #expect(machine.state == .connecting(attempt: 2))
    }

    @Test("authorization denial replaces a pending reconnect with its fallback retry")
    func authorizationDenialReplacesPendingReconnect() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)
        _ = machine.handle(.invalidated(attempt: 1))

        #expect(machine.handle(.authorizationDenied(attempt: 1)) == [
            .cancelReconnect(attempt: 1),
            .scheduleReconnect(attempt: 1, after: 0.5, deadline: 100.5),
        ])
        #expect(machine.state == .fallback(reason: .authorizationDenied))
        clock.now = 100.25
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [])
        clock.now = 100.5
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [.connect(attempt: 2)])
    }

    @Test("duplicate and stale callbacks cannot repeat actions or revive an old epoch")
    func duplicateAndStaleCallbacksAreIgnored() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)
        #expect(machine.handle(.start) == [])
        _ = machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 10))
        #expect(machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 10)) == [])
        _ = machine.handle(.frame(attempt: 1, streamEpoch: 10, sequence: 8))
        #expect(machine.handle(.frame(attempt: 1, streamEpoch: 10, sequence: 8)) == [])
        #expect(machine.handle(.frame(attempt: 1, streamEpoch: 10, sequence: 7)) == [])

        _ = machine.handle(.interrupted(attempt: 1))
        #expect(machine.handle(.interrupted(attempt: 1)) == [])
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [])
        clock.now = 100.25
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [.connect(attempt: 2)])
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [])
        #expect(machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 11)) == [])
        #expect(machine.handle(.frame(attempt: 1, streamEpoch: 10, sequence: 9)) == [])
        #expect(machine.handle(.invalidated(attempt: 1)) == [])
        #expect(machine.state == .connecting(attempt: 2))
    }

    @Test("connection attempts and producer stream epochs are independent")
    func connectionAttemptsDoNotDefineStreamEpochs() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        #expect(machine.handle(.start) == [.connect(attempt: 1)])
        #expect(machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 41)) == [
            .beginStreaming(attempt: 1, streamEpoch: 41)
        ])

        _ = machine.handle(.invalidated(attempt: 1))
        clock.now = 100.25
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [.connect(attempt: 2)])
        #expect(machine.handle(.connectionEstablished(attempt: 2, streamEpoch: 9_001)) == [
            .beginStreaming(attempt: 2, streamEpoch: 9_001)
        ])
        #expect(machine.state == .streaming(attempt: 2, streamEpoch: 9_001))

        #expect(machine.handle(.frame(attempt: 1, streamEpoch: 9_001, sequence: 1)) == [])
        #expect(machine.handle(.frame(attempt: 2, streamEpoch: 41, sequence: 2)) == [])
        #expect(machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 9_002)) == [])
        #expect(machine.handle(.frame(attempt: 2, streamEpoch: 9_001, sequence: 3)) == [
            .acceptFrame(attempt: 2, streamEpoch: 9_001, sequence: 3)
        ])
        #expect(machine.state == .streaming(attempt: 2, streamEpoch: 9_001))
    }

    @Test("stopping fallback cancels its pending reconnect")
    func stopCancelsPendingReconnect() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)
        _ = machine.handle(.invalidated(attempt: 1))

        #expect(machine.handle(.stop) == [.cancelReconnect(attempt: 1)])
        #expect(machine.state == .disconnected)
        clock.now = 500
        #expect(machine.handle(.reconnectDue(attempt: 1)) == [])
    }

    @Test("a zero producer stream epoch cannot begin streaming")
    func zeroStreamEpochIsRejected() {
        let clock = TestCameraConsumerClock(now: 100)
        var machine = CameraConsumerStateMachine(clock: clock)
        _ = machine.handle(.start)

        #expect(machine.handle(.connectionEstablished(attempt: 1, streamEpoch: 0)) == [])
        #expect(machine.state == .connecting(attempt: 1))
    }
}

private final class TestCameraConsumerClock: CameraConsumerClock, @unchecked Sendable {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}
