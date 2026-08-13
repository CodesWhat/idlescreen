import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera connection lease contract")
struct CameraLeaseContractTests {
    private let start = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("capture remains desired until every independent lease is released")
    func independentConnectionsAndLeases() {
        var coordinator = CameraLeaseCoordinator()

        #expect(coordinator.desiredCaptureState == .stopped)
        let acquiredFirst = coordinator.acquireLease(
            connection: "display-one",
            lease: "primary",
            now: start,
            ttl: 30
        )
        let acquiredSecond = coordinator.acquireLease(
            connection: "display-one",
            lease: "secondary",
            now: start,
            ttl: 30
        )
        let acquiredThird = coordinator.acquireLease(
            connection: "display-two",
            lease: "primary",
            now: start,
            ttl: 30
        )
        #expect(acquiredFirst)
        #expect(acquiredSecond)
        #expect(acquiredThird)
        #expect(coordinator.activeLeaseCount == 3)
        #expect(coordinator.activeLeaseCount(for: "display-one") == 2)
        #expect(coordinator.desiredCaptureState == .running)

        let releasedFirst = coordinator.releaseLease(
            connection: "display-one",
            lease: "primary",
            now: start
        )
        #expect(releasedFirst)
        #expect(coordinator.activeLeaseCount == 2)
        #expect(coordinator.desiredCaptureState == .running)

        let releasedSecond = coordinator.releaseLease(
            connection: "display-one",
            lease: "secondary",
            now: start
        )
        #expect(releasedSecond)
        #expect(coordinator.activeLeaseCount == 1)
        #expect(coordinator.desiredCaptureState == .running)

        let releasedThird = coordinator.releaseLease(
            connection: "display-two",
            lease: "primary",
            now: start
        )
        #expect(releasedThird)
        #expect(coordinator.activeLeaseCount == 0)
        #expect(coordinator.desiredCaptureState == .stopped)
    }

    @Test("connection invalidation reclaims only leases owned by that connection")
    func connectionInvalidationIsScoped() {
        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "display-one", lease: "one", now: start, ttl: 30)
        coordinator.acquireLease(connection: "display-one", lease: "two", now: start, ttl: 30)
        coordinator.acquireLease(connection: "display-two", lease: "one", now: start, ttl: 30)

        let reclaimed = coordinator.invalidateConnection("display-one", now: start)
        #expect(reclaimed == 2)
        #expect(coordinator.activeLeaseCount(for: "display-one") == 0)
        #expect(coordinator.activeLeaseCount(for: "display-two") == 1)
        #expect(coordinator.desiredCaptureState == .running)

        let reclaimedAgain = coordinator.invalidateConnection("display-one", now: start)
        #expect(reclaimedAgain == 0)
        #expect(coordinator.activeLeaseCount == 1)
        #expect(coordinator.desiredCaptureState == .running)
    }

    @Test("heartbeat extends a lease from an explicitly supplied time")
    func heartbeatExtendsTimeToLive() {
        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "display-one", lease: "camera", now: start, ttl: 10)

        let renewed = coordinator.heartbeat(
            connection: "display-one",
            lease: "camera",
            now: start.addingTimeInterval(8),
            ttl: 10
        )
        let expiredAtOriginalDeadline = coordinator.expireLeases(
            now: start.addingTimeInterval(10)
        )
        #expect(renewed)
        #expect(expiredAtOriginalDeadline == 0)
        #expect(coordinator.desiredCaptureState == .running)

        let expiredAtRenewedDeadline = coordinator.expireLeases(
            now: start.addingTimeInterval(18)
        )
        #expect(expiredAtRenewedDeadline == 1)
        #expect(coordinator.desiredCaptureState == .stopped)
    }

    @Test("expired leases cannot be revived by a late heartbeat")
    func lateHeartbeatDoesNotReviveLease() {
        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "display-one", lease: "camera", now: start, ttl: 5)

        let renewed = coordinator.heartbeat(
            connection: "display-one",
            lease: "camera",
            now: start.addingTimeInterval(5),
            ttl: 10
        )
        #expect(renewed == false)
        #expect(coordinator.activeLeaseCount == 0)
        #expect(coordinator.desiredCaptureState == .stopped)
    }

    @Test("a nonpositive TTL cannot create a capture demand")
    func nonpositiveTimeToLiveIsRejected() {
        var coordinator = CameraLeaseCoordinator()

        let acquired = coordinator.acquireLease(
            connection: "display-one",
            lease: "camera",
            now: start,
            ttl: 0
        )

        #expect(acquired == false)
        #expect(coordinator.activeLeaseCount == 0)
        #expect(coordinator.desiredCaptureState == .stopped)
        #expect(coordinator.streamEpoch == 0)
    }

    @Test("a nonpositive heartbeat TTL does not poison an active lease")
    func nonpositiveHeartbeatTimeToLiveIsRejected() {
        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "display-one", lease: "camera", now: start, ttl: 10)

        let renewed = coordinator.heartbeat(
            connection: "display-one",
            lease: "camera",
            now: start.addingTimeInterval(1),
            ttl: 0
        )
        let expiredEarly = coordinator.expireLeases(now: start.addingTimeInterval(5))

        #expect(renewed == false)
        #expect(expiredEarly == 0)
        #expect(coordinator.activeLeaseCount == 1)
        #expect(coordinator.desiredCaptureState == .running)
    }

    @Test("empty connection and lease identities are rejected without processing expiry")
    func emptyIdentitiesAreRejected() {
        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "existing", lease: "camera", now: start, ttl: 1)

        let emptyConnection = coordinator.acquireLease(
            connection: "",
            lease: "new",
            now: start.addingTimeInterval(2),
            ttl: 10
        )
        let emptyLease = coordinator.acquireLease(
            connection: "new",
            lease: "",
            now: start.addingTimeInterval(2),
            ttl: 10
        )

        #expect(emptyConnection == false)
        #expect(emptyLease == false)
        #expect(coordinator.activeLeaseCount == 1)
        #expect(coordinator.activeLeaseCount(for: "existing") == 1)
        #expect(coordinator.desiredCaptureState == .running)
        #expect(coordinator.streamEpoch == 1)
    }

    @Test("non-finite acquisition time inputs are rejected without processing expiry")
    func nonfiniteAcquisitionInputsAreRejected() {
        let invalidDates = [
            Date(timeIntervalSinceReferenceDate: .nan),
            Date(timeIntervalSinceReferenceDate: .infinity),
            Date(timeIntervalSinceReferenceDate: -.infinity),
        ]
        let invalidTTLs = [TimeInterval.nan, .infinity, -.infinity]

        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "existing", lease: "camera", now: start, ttl: 1)

        for invalidDate in invalidDates {
            let acquired = coordinator.acquireLease(
                connection: "new",
                lease: "date",
                now: invalidDate,
                ttl: 10
            )
            #expect(acquired == false)
        }
        for invalidTTL in invalidTTLs {
            let acquired = coordinator.acquireLease(
                connection: "new",
                lease: "ttl",
                now: start.addingTimeInterval(2),
                ttl: invalidTTL
            )
            #expect(acquired == false)
        }

        #expect(coordinator.activeLeaseCount == 1)
        #expect(coordinator.activeLeaseCount(for: "existing") == 1)
        #expect(coordinator.desiredCaptureState == .running)
        #expect(coordinator.streamEpoch == 1)
    }

    @Test("invalid heartbeat time inputs do not mutate or expire any lease")
    func invalidHeartbeatInputsDoNotMutate() {
        let invalidDates = [
            Date(timeIntervalSinceReferenceDate: .nan),
            Date(timeIntervalSinceReferenceDate: .infinity),
            Date(timeIntervalSinceReferenceDate: -.infinity),
        ]
        let invalidTTLs = [TimeInterval.nan, .infinity, -.infinity]

        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "target", lease: "camera", now: start, ttl: 10)
        coordinator.acquireLease(connection: "unrelated", lease: "camera", now: start, ttl: 1)

        for invalidDate in invalidDates {
            let renewed = coordinator.heartbeat(
                connection: "target",
                lease: "camera",
                now: invalidDate,
                ttl: 10
            )
            #expect(renewed == false)
        }
        for invalidTTL in invalidTTLs {
            let renewed = coordinator.heartbeat(
                connection: "target",
                lease: "camera",
                now: start.addingTimeInterval(2),
                ttl: invalidTTL
            )
            #expect(renewed == false)
        }

        #expect(coordinator.activeLeaseCount == 2)
        #expect(coordinator.activeLeaseCount(for: "target") == 1)
        #expect(coordinator.activeLeaseCount(for: "unrelated") == 1)
        #expect(coordinator.desiredCaptureState == .running)
        #expect(coordinator.streamEpoch == 1)
    }

    @Test("a finite time pair that overflows its deadline is rejected before mutation")
    func overflowingDeadlineIsRejected() {
        let distantFiniteNow = Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)

        var acquisitionCoordinator = CameraLeaseCoordinator()
        let acquired = acquisitionCoordinator.acquireLease(
            connection: "display-one",
            lease: "camera",
            now: distantFiniteNow,
            ttl: .greatestFiniteMagnitude
        )
        #expect(acquired == false)
        #expect(acquisitionCoordinator.activeLeaseCount == 0)
        #expect(acquisitionCoordinator.desiredCaptureState == .stopped)

        var heartbeatCoordinator = CameraLeaseCoordinator()
        heartbeatCoordinator.acquireLease(
            connection: "existing",
            lease: "camera",
            now: start,
            ttl: 10
        )
        let renewed = heartbeatCoordinator.heartbeat(
            connection: "existing",
            lease: "camera",
            now: distantFiniteNow,
            ttl: .greatestFiniteMagnitude
        )
        #expect(renewed == false)
        #expect(heartbeatCoordinator.activeLeaseCount == 1)
        #expect(heartbeatCoordinator.desiredCaptureState == .running)
        #expect(heartbeatCoordinator.streamEpoch == 1)
    }

    @Test("cleanup operations reject non-finite time without mutating leases")
    func cleanupRejectsNonfiniteTime() {
        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "display-one", lease: "camera", now: start, ttl: 10)
        coordinator.acquireLease(connection: "display-two", lease: "camera", now: start, ttl: 10)

        let released = coordinator.releaseLease(
            connection: "display-one",
            lease: "camera",
            now: Date(timeIntervalSinceReferenceDate: .nan)
        )
        let invalidated = coordinator.invalidateConnection(
            "display-two",
            now: Date(timeIntervalSinceReferenceDate: .infinity)
        )
        let expired = coordinator.expireLeases(
            now: Date(timeIntervalSinceReferenceDate: -.infinity)
        )

        #expect(released == false)
        #expect(invalidated == 0)
        #expect(expired == 0)
        #expect(coordinator.activeLeaseCount == 2)
        #expect(coordinator.desiredCaptureState == .running)
        #expect(coordinator.streamEpoch == 1)
    }

    @Test("stream epoch advances only when a stopped coordinator becomes active")
    func streamEpochTracksCaptureGenerations() {
        var coordinator = CameraLeaseCoordinator()
        #expect(coordinator.streamEpoch == 0)

        coordinator.acquireLease(connection: "display-one", lease: "one", now: start, ttl: 30)
        #expect(coordinator.streamEpoch == 1)

        coordinator.acquireLease(connection: "display-two", lease: "one", now: start, ttl: 30)
        #expect(coordinator.streamEpoch == 1)

        coordinator.releaseLease(connection: "display-one", lease: "one", now: start)
        #expect(coordinator.streamEpoch == 1)
        coordinator.releaseLease(connection: "display-two", lease: "one", now: start)
        #expect(coordinator.desiredCaptureState == .stopped)
        #expect(coordinator.streamEpoch == 1)

        coordinator.acquireLease(connection: "display-three", lease: "one", now: start, ttl: 30)
        #expect(coordinator.desiredCaptureState == .running)
        #expect(coordinator.streamEpoch == 2)
    }

    @Test("an injected process seed becomes the first epoch and later epochs increase")
    func processSeedStartsStrictlyIncreasingEpochs() throws {
        var coordinator = try #require(CameraLeaseCoordinator(
            streamEpochSeed: 41_000
        ))
        #expect(coordinator.streamEpoch == 0)
        #expect(coordinator.streamEpochForNextLease == 41_000)

        let acquiredFirst = coordinator.acquireLease(
            connection: "display-one",
            lease: "first",
            now: start,
            ttl: 30
        )
        #expect(acquiredFirst)
        #expect(coordinator.streamEpoch == 41_000)
        #expect(coordinator.streamEpochForNextLease == 41_000)

        let releasedFirst = coordinator.releaseLease(
            connection: "display-one",
            lease: "first",
            now: start
        )
        #expect(releasedFirst)
        #expect(coordinator.streamEpochForNextLease == 41_001)
        let acquiredSecond = coordinator.acquireLease(
            connection: "display-two",
            lease: "second",
            now: start,
            ttl: 30
        )
        #expect(acquiredSecond)
        #expect(coordinator.streamEpoch == 41_001)
    }

    @Test("epoch exhaustion fails closed instead of wrapping to zero")
    func streamEpochDoesNotOverflow() throws {
        #expect(CameraLeaseCoordinator(streamEpochSeed: 0) == nil)
        var coordinator = try #require(CameraLeaseCoordinator(
            streamEpochSeed: .max
        ))

        let acquiredLast = coordinator.acquireLease(
            connection: "display-one",
            lease: "last",
            now: start,
            ttl: 30
        )
        #expect(acquiredLast)
        #expect(coordinator.streamEpoch == .max)
        let releasedLast = coordinator.releaseLease(
            connection: "display-one",
            lease: "last",
            now: start
        )
        #expect(releasedLast)
        #expect(coordinator.streamEpochForNextLease == nil)

        let acquiredAfterExhaustion = coordinator.acquireLease(
            connection: "display-two",
            lease: "must-not-wrap",
            now: start,
            ttl: 30
        )
        #expect(!acquiredAfterExhaustion)
        #expect(coordinator.streamEpoch == .max)
        #expect(coordinator.activeLeaseCount == 0)
        #expect(coordinator.desiredCaptureState == .stopped)
    }

    @Test("release and heartbeat operations are idempotent")
    func idempotentOperations() {
        var coordinator = CameraLeaseCoordinator()
        coordinator.acquireLease(connection: "display-one", lease: "camera", now: start, ttl: 30)

        let firstHeartbeat = coordinator.heartbeat(
            connection: "display-one",
            lease: "camera",
            now: start.addingTimeInterval(1),
            ttl: 30
        )
        let repeatedHeartbeat = coordinator.heartbeat(
            connection: "display-one",
            lease: "camera",
            now: start.addingTimeInterval(1),
            ttl: 30
        )
        #expect(firstHeartbeat)
        #expect(repeatedHeartbeat)
        #expect(coordinator.activeLeaseCount == 1)

        let firstRelease = coordinator.releaseLease(
            connection: "display-one",
            lease: "camera",
            now: start.addingTimeInterval(2)
        )
        let repeatedRelease = coordinator.releaseLease(
            connection: "display-one",
            lease: "camera",
            now: start.addingTimeInterval(2)
        )
        let missingHeartbeat = coordinator.heartbeat(
            connection: "display-one",
            lease: "camera",
            now: start.addingTimeInterval(2),
            ttl: 30
        )
        #expect(firstRelease)
        #expect(repeatedRelease == false)
        #expect(missingHeartbeat == false)
        #expect(coordinator.activeLeaseCount == 0)
        #expect(coordinator.desiredCaptureState == .stopped)
    }
}
