import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera capture recovery policy")
struct CameraCaptureRecoveryPolicyTests {
    @Test("a post-first-frame stall consumes bounded backoff")
    func frameStallUsesBoundedBackoff() {
        var policy = CameraCaptureRecoveryPolicy()
        _ = policy.handle(.activateAttempt(generation: 7), now: 10)

        #expect(policy.handle(
            .failure(generation: 7, cause: .frameStall),
            now: 10
        ) == .scheduleRetry(
            generation: 7,
            cause: .frameStall,
            attempt: 1,
            after: 0.25,
            deadline: 10.25
        ))
    }

    @Test("capture failures use bounded quarter-second through five-second backoff")
    func boundedBackoff() {
        var policy = CameraCaptureRecoveryPolicy()
        let causes: [CameraCaptureRecoveryCause] = [
            .startFailure,
            .firstFrameTimeout,
            .interruption,
            .startFailure,
            .firstFrameTimeout,
            .interruption
        ]
        let expectedDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 5, 5]

        for index in causes.indices {
            let generation = UInt64(index + 1)
            let now = TimeInterval(index * 10)
            #expect(policy.handle(
                .activateAttempt(generation: generation),
                now: now
            ) == .none)

            let decision = policy.handle(
                .failure(generation: generation, cause: causes[index]),
                now: now
            )
            #expect(decision == .scheduleRetry(
                generation: generation,
                cause: causes[index],
                attempt: UInt64(index + 1),
                after: expectedDelays[index],
                deadline: now + expectedDelays[index]
            ))
            #expect(policy.handle(
                .retryDeadlineReached(generation: generation),
                now: now + expectedDelays[index] - 0.001
            ) == .none)
            #expect(policy.handle(
                .retryDeadlineReached(generation: generation),
                now: now + expectedDelays[index]
            ) == .retryImmediately(
                generation: generation,
                cause: causes[index]
            ))
        }
        #expect(policy.backoffAttempt == 6)
    }

    @Test("no-device recovery waits for usable inventory without consuming backoff")
    func noDeviceWaitsForInventory() {
        var policy = CameraCaptureRecoveryPolicy()
        _ = policy.handle(.activateAttempt(generation: 4), now: 1)

        #expect(policy.handle(
            .failure(generation: 4, cause: .noDevice),
            now: 1
        ) == .waitForDeviceInventory(generation: 4))
        #expect(policy.handle(
            .deviceInventoryChanged(generation: 4, hasUsableDevice: false),
            now: 2
        ) == .waitForDeviceInventory(generation: 4))
        #expect(policy.handle(
            .deviceInventoryChanged(generation: 4, hasUsableDevice: true),
            now: 3
        ) == .retryImmediately(generation: 4, cause: .noDevice))
        #expect(policy.backoffAttempt == 0)
    }

    @Test("permission recovery waits for nonprompting authorization refresh")
    func permissionWaitsForRefresh() {
        var policy = CameraCaptureRecoveryPolicy()
        _ = policy.handle(.activateAttempt(generation: 8), now: 1)

        #expect(policy.handle(
            .failure(generation: 8, cause: .permissionUnavailable),
            now: 1
        ) == .waitForAuthorizationRefresh(generation: 8))
        #expect(policy.handle(
            .authorizationRefreshed(generation: 8, authorization: .denied),
            now: 2
        ) == .waitForAuthorizationRefresh(generation: 8))
        #expect(policy.handle(
            .authorizationRefreshed(generation: 8, authorization: .authorized),
            now: 3
        ) == .retryImmediately(
            generation: 8,
            cause: .permissionUnavailable
        ))
        #expect(policy.backoffAttempt == 0)
    }

    @Test("media-services reset receives at most one immediate retry per healthy run")
    func oneImmediateMediaServicesRetry() {
        var policy = CameraCaptureRecoveryPolicy()
        _ = policy.handle(.activateAttempt(generation: 1), now: 0)

        #expect(policy.handle(
            .failure(generation: 1, cause: .mediaServicesReset),
            now: 0
        ) == .retryImmediately(generation: 1, cause: .mediaServicesReset))

        _ = policy.handle(.activateAttempt(generation: 2), now: 1)
        #expect(policy.handle(
            .failure(generation: 2, cause: .mediaServicesReset),
            now: 1
        ) == .scheduleRetry(
            generation: 2,
            cause: .mediaServicesReset,
            attempt: 1,
            after: 0.25,
            deadline: 1.25
        ))

        #expect(policy.handle(.freshFrame(generation: 2), now: 1.1) == .healthy(
            generation: 2
        ))
        #expect(policy.handle(
            .failure(generation: 2, cause: .mediaServicesReset),
            now: 1.2
        ) == .retryImmediately(generation: 2, cause: .mediaServicesReset))
    }

    @Test("a fresh frame resets the bounded retry budget")
    func freshFrameResetsAttempts() {
        var policy = CameraCaptureRecoveryPolicy()
        _ = policy.handle(.activateAttempt(generation: 1), now: 0)
        _ = policy.handle(
            .failure(generation: 1, cause: .startFailure),
            now: 0
        )
        _ = policy.handle(.retryDeadlineReached(generation: 1), now: 0.25)
        _ = policy.handle(.activateAttempt(generation: 2), now: 1)
        _ = policy.handle(
            .failure(generation: 2, cause: .firstFrameTimeout),
            now: 1
        )
        #expect(policy.backoffAttempt == 2)

        #expect(policy.handle(.freshFrame(generation: 2), now: 1.1)
            == .healthy(generation: 2))
        #expect(policy.backoffAttempt == 0)
        #expect(policy.handle(
            .failure(generation: 2, cause: .interruption),
            now: 2
        ) == .scheduleRetry(
            generation: 2,
            cause: .interruption,
            attempt: 1,
            after: 0.25,
            deadline: 2.25
        ))
    }

    @Test("duplicate failures cannot schedule twice or consume another attempt")
    func duplicateFailureIsIdempotent() {
        var policy = CameraCaptureRecoveryPolicy()
        _ = policy.handle(.activateAttempt(generation: 3), now: 5)
        let expected = CameraCaptureRecoveryDecision.scheduleRetry(
            generation: 3,
            cause: .startFailure,
            attempt: 1,
            after: 0.25,
            deadline: 5.25
        )

        #expect(policy.handle(
            .failure(generation: 3, cause: .startFailure),
            now: 5
        ) == expected)
        #expect(policy.handle(
            .failure(generation: 3, cause: .startFailure),
            now: 5.1
        ) == .none)
        #expect(policy.backoffAttempt == 1)
    }

    @Test("old generation callbacks and retry deadlines are fenced")
    func staleGenerationFencing() {
        var policy = CameraCaptureRecoveryPolicy()
        _ = policy.handle(.activateAttempt(generation: 10), now: 0)
        _ = policy.handle(
            .failure(generation: 10, cause: .startFailure),
            now: 0
        )
        _ = policy.handle(.activateAttempt(generation: 11), now: 1)
        let stale = CameraCaptureRecoveryDecision.ignoredStaleCallback(
            expectedGeneration: 11,
            actualGeneration: 10
        )

        #expect(policy.handle(
            .retryDeadlineReached(generation: 10),
            now: 5
        ) == stale)
        #expect(policy.handle(
            .failure(generation: 10, cause: .interruption),
            now: 5
        ) == stale)
        #expect(policy.handle(
            .deviceInventoryChanged(generation: 10, hasUsableDevice: true),
            now: 5
        ) == stale)
        #expect(policy.handle(
            .authorizationRefreshed(generation: 10, authorization: .authorized),
            now: 5
        ) == stale)
        #expect(policy.handle(.freshFrame(generation: 10), now: 5) == stale)
        #expect(policy.currentGeneration == 11)
        #expect(policy.backoffAttempt == 1)
    }
}
