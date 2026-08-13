import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera lease controller")
struct CameraLeaseControllerTests {
    @Test("production lease policy heartbeats safely before its shared TTL")
    func productionLeasePolicy() {
        let policy = CameraAgentLeasePolicy.production

        #expect(policy.leaseTimeToLive == 6)
        #expect(policy.heartbeatInterval == 2)
        #expect(policy.requestTimeout == 1)
        #expect(policy.heartbeatInterval + policy.requestTimeout < policy.leaseTimeToLive)
        #expect(CameraAgentLeasePolicy(
            leaseTimeToLive: 3,
            heartbeatInterval: 2,
            requestTimeout: 1,
            stopGracePeriod: 0.25
        ) == nil)
    }

    @Test("repeated start calls create only one connection and one in-flight begin")
    func oneInFlightBegin() throws {
        let harness = try LeaseControllerHarness()

        harness.controller.start()
        harness.controller.start()
        harness.controller.start()

        #expect(harness.connector.attempts == [1])
        #expect(harness.connector.sessions[0].beginRequests.count == 1)
        #expect(harness.controller.state == .connecting(attempt: 1))
    }

    @Test("an accepted begin publishes only the server epoch and transport")
    func acceptedBeginPublishesStream() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()
        let session = harness.connector.sessions[0]

        session.completeBegin(with: acceptedBeginReply(
            lease: "lease_private-1",
            epoch: 41
        ))

        #expect(harness.controller.state == .streaming(attempt: 1, streamEpoch: 41))
        #expect(harness.updates.values == [
            .available(CameraAgentStreamDescriptor(
                producerStreamEpoch: 41,
                transportIdentifier: "camera/frame-mailbox.bin"
            )),
        ])
        #expect(!String(describing: harness.updates.values).contains("lease_private-1"))
    }

    @Test("heartbeat fires periodically before TTL and waits for each reply")
    func periodicHeartbeat() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()
        let session = harness.connector.sessions[0]
        session.completeBegin(with: acceptedBeginReply())

        harness.scheduler.advance(by: 1.999)
        #expect(session.heartbeatRequests.isEmpty)
        harness.scheduler.advance(by: 0.001)
        #expect(session.heartbeatRequests.map(\.leaseIdentifier) == ["lease_private-1"])

        harness.scheduler.advance(by: 0.5)
        #expect(session.heartbeatRequests.count == 1)
        session.completeHeartbeat(with: acceptedHeartbeatReply())
        harness.scheduler.advance(by: 1.999)
        #expect(session.heartbeatRequests.count == 1)
        harness.scheduler.advance(by: 0.001)
        #expect(session.heartbeatRequests.count == 2)
        #expect(harness.scheduler.now < CameraAgentLeasePolicy.production.leaseTimeToLive)
    }

    @Test("stop sends an explicit end and cancels every heartbeat")
    func explicitEndOnStop() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()
        let session = harness.connector.sessions[0]
        session.completeBegin(with: acceptedBeginReply())

        harness.controller.stop()

        #expect(harness.controller.state == .disconnected)
        #expect(session.endRequests.map(\.leaseIdentifier) == ["lease_private-1"])
        #expect(harness.updates.values.last == .unavailable)
        harness.scheduler.advance(by: 20)
        #expect(session.heartbeatRequests.isEmpty)
    }

    @Test("a begin reply after stop is ended but cannot revive the stopped generation")
    func staleBeginAfterStopIsReclaimed() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()
        let session = harness.connector.sessions[0]

        harness.controller.stop()
        session.completeBegin(with: acceptedBeginReply(
            lease: "lease_stale-1",
            epoch: 99
        ))

        #expect(session.endRequests.map(\.leaseIdentifier) == ["lease_stale-1"])
        #expect(harness.controller.state == .disconnected)
        #expect(!harness.updates.values.contains {
            if case .available = $0 { return true }
            return false
        })
    }

    @Test("interruption reconnects with bounded exponential delays capped at five seconds")
    func boundedReconnect() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()

        let delays: [TimeInterval] = [0.25, 0.5, 1, 2, 5, 5]
        for (index, delay) in delays.enumerated() {
            harness.connector.emit(.invalidated(attempt: UInt64(index + 1)))
            #expect(harness.scheduler.nextPendingDelay == delay)

            harness.scheduler.advance(by: delay)

            #expect(harness.connector.attempts.last == UInt64(index + 2))
            #expect(harness.connector.sessions.last?.beginRequests.count == 1)
        }
    }

    @Test("late callbacks from an interrupted attempt cannot replace the new epoch")
    func attemptAndEpochFencing() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()
        let first = harness.connector.sessions[0]

        harness.connector.emit(.interrupted(attempt: 1))
        first.completeBegin(with: acceptedBeginReply(
            lease: "lease_stale-1",
            epoch: 41
        ))
        #expect(first.endRequests.map(\.leaseIdentifier) == ["lease_stale-1"])
        harness.scheduler.advance(by: 0.25)
        let second = harness.connector.sessions[1]
        second.completeBegin(with: acceptedBeginReply(
            lease: "lease_current-2",
            epoch: 9_001
        ))

        #expect(harness.controller.state == .streaming(
            attempt: 2,
            streamEpoch: 9_001
        ))
        #expect(harness.updates.values.filter {
            if case .available = $0 { return true }
            return false
        } == [
            .available(CameraAgentStreamDescriptor(
                producerStreamEpoch: 9_001,
                transportIdentifier: "camera/frame-mailbox.bin"
            )),
        ])
    }

    @Test("a missing begin reply times out before retrying and never overlaps begins")
    func beginTimeoutDoesNotOverlap() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()
        let first = harness.connector.sessions[0]

        harness.scheduler.advance(by: 1)

        #expect(first.invalidationCount == 1)
        #expect(harness.connector.sessions.count == 1)
        #expect(harness.scheduler.nextPendingDelay == 0.25)
        harness.scheduler.advance(by: 0.25)
        #expect(harness.connector.sessions.count == 2)
        #expect(harness.connector.sessions[1].beginRequests.count == 1)
    }

    @Test("heartbeat failure falls back and starts a fresh connection attempt")
    func heartbeatFailureReconnects() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()
        let first = harness.connector.sessions[0]
        first.completeBegin(with: acceptedBeginReply())
        harness.scheduler.advance(by: 2)

        first.completeHeartbeat(with: IdleScreenCameraHeartbeatReply(
            accepted: false,
            errorCode: .invalidRequest,
            errorMessage: "Lease expired"
        )!)

        #expect(first.invalidationCount == 1)
        #expect(harness.scheduler.nextPendingDelay == 0.25)
        harness.scheduler.advance(by: 0.25)
        #expect(harness.connector.attempts == [1, 2])
    }

    @Test("authorization rejection falls back and retries without an app restart")
    func authorizationRejectionRetriesAutomatically() throws {
        let harness = try LeaseControllerHarness()
        harness.controller.start()
        let session = harness.connector.sessions[0]

        session.completeBegin(with: IdleScreenCameraBeginStreamReply(
            accepted: false,
            errorCode: .notAuthorized,
            errorMessage: "Permission required",
            leaseIdentifier: nil,
            producerStreamEpoch: 0,
            transportIdentifier: nil
        )!)

        #expect(harness.controller.state == .fallback(reason: .authorizationDenied))
        #expect(harness.scheduler.nextPendingDelay == 0.25)
        harness.scheduler.advance(by: 0.25)
        #expect(harness.connector.attempts == [1, 2])

        harness.connector.sessions[1].completeBegin(with: acceptedBeginReply())
        #expect(harness.controller.state == .streaming(attempt: 2, streamEpoch: 41))
        #expect(harness.updates.values.last == .available(CameraAgentStreamDescriptor(
            producerStreamEpoch: 41,
            transportIdentifier: "camera/frame-mailbox.bin"
        )))
    }

    @Test("scheduled work and connection callbacks do not retain the controller")
    func callbacksDoNotRetainController() throws {
        let scheduler = DeterministicCameraLeaseScheduler()
        let connector = RecordingCameraAgentConnector()
        var controller: CameraLeaseController? = try makeController(
            scheduler: scheduler,
            connector: connector,
            updates: LockedLeaseUpdates()
        )
        controller?.start()
        let weakController = WeakLeaseController(controller)

        controller = nil

        #expect(weakController.value == nil)
    }
}

private final class LeaseControllerHarness {
    let scheduler = DeterministicCameraLeaseScheduler()
    let connector = RecordingCameraAgentConnector()
    let updates = LockedLeaseUpdates()
    let controller: CameraLeaseController

    init() throws {
        controller = try makeController(
            scheduler: scheduler,
            connector: connector,
            updates: updates
        )
    }
}

private func makeController(
    scheduler: DeterministicCameraLeaseScheduler,
    connector: RecordingCameraAgentConnector,
    updates: LockedLeaseUpdates
) throws -> CameraLeaseController {
    let configuration = try #require(CameraLeaseControllerConfiguration(
        maximumWidth: 640,
        maximumHeight: 480,
        maximumFramesPerSecond: 30,
        mailboxSlotCount: 2,
        leasePolicy: .production
    ))
    return CameraLeaseController(
        client: connector,
        scheduler: scheduler,
        configuration: configuration,
        updateHandler: { updates.append($0) }
    )
}

private final class RecordingCameraAgentConnector: CameraAgentClientConnecting,
    @unchecked Sendable
{
    private(set) var attempts: [UInt64] = []
    private(set) var sessions: [RecordingCameraAgentSession] = []
    private var handlers: [UInt64: @Sendable (CameraAgentClientConnectionEvent) -> Void] = [:]

    func connect(
        attempt: UInt64,
        eventHandler: @escaping @Sendable (CameraAgentClientConnectionEvent) -> Void
    ) -> any CameraAgentClientSession {
        attempts.append(attempt)
        let session = RecordingCameraAgentSession(attempt: attempt)
        sessions.append(session)
        handlers[attempt] = eventHandler
        return session
    }

    func emit(_ event: CameraAgentClientConnectionEvent) {
        handlers[event.attempt]?(event)
    }
}

private final class RecordingCameraAgentSession: CameraAgentClientSession,
    @unchecked Sendable
{
    let attempt: UInt64
    private(set) var beginRequests: [IdleScreenCameraBeginStreamRequest] = []
    private(set) var heartbeatRequests: [IdleScreenCameraHeartbeatRequest] = []
    private(set) var endRequests: [IdleScreenCameraEndStreamRequest] = []
    private(set) var invalidationCount = 0
    private var beginReplies: [@Sendable (IdleScreenCameraBeginStreamReply?) -> Void] = []
    private var heartbeatReplies: [@Sendable (IdleScreenCameraHeartbeatReply?) -> Void] = []
    private var endReplies: [@Sendable (IdleScreenCameraEndStreamReply?) -> Void] = []

    init(attempt: UInt64) {
        self.attempt = attempt
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraBeginStreamReply?) -> Void
    ) {
        beginRequests.append(request)
        beginReplies.append(reply)
    }

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        reply: @escaping @Sendable (IdleScreenCameraHeartbeatReply?) -> Void
    ) {
        heartbeatRequests.append(request)
        heartbeatReplies.append(reply)
    }

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraEndStreamReply?) -> Void
    ) {
        endRequests.append(request)
        endReplies.append(reply)
    }

    func invalidate() {
        invalidationCount += 1
    }

    func completeBegin(with reply: IdleScreenCameraBeginStreamReply?) {
        beginReplies.removeFirst()(reply)
    }

    func completeHeartbeat(with reply: IdleScreenCameraHeartbeatReply?) {
        heartbeatReplies.removeFirst()(reply)
    }
}

private final class DeterministicCameraLeaseScheduler: CameraLeaseScheduling,
    @unchecked Sendable
{
    private final class Token: CameraLeaseScheduledTask, @unchecked Sendable {
        private(set) var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private struct Job {
        let serial: UInt64
        let deadline: TimeInterval
        let token: Token
        let operation: @Sendable () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var serial: UInt64 = 0
    private var jobs: [Job] = []

    var nextPendingDelay: TimeInterval? {
        jobs
            .filter { !$0.token.isCancelled }
            .map { max(0, $0.deadline - now) }
            .min()
    }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraLeaseScheduledTask {
        serial += 1
        let token = Token()
        jobs.append(Job(
            serial: serial,
            deadline: now + delay,
            token: token,
            operation: operation
        ))
        return token
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = jobs
            .filter({ !$0.token.isCancelled && $0.deadline <= target })
            .min(by: {
                ($0.deadline, $0.serial) < ($1.deadline, $1.serial)
            }) {
            jobs.removeAll { $0.serial == next.serial }
            now = next.deadline
            next.operation()
        }
        now = target
    }
}

private final class LockedLeaseUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CameraLeaseControllerUpdate] = []

    var values: [CameraLeaseControllerUpdate] {
        lock.withLock { storage }
    }

    func append(_ update: CameraLeaseControllerUpdate) {
        lock.withLock { storage.append(update) }
    }
}

private final class WeakLeaseController {
    weak var value: CameraLeaseController?

    init(_ value: CameraLeaseController?) {
        self.value = value
    }
}

private func acceptedBeginReply(
    lease: String = "lease_private-1",
    epoch: UInt64 = 41
) -> IdleScreenCameraBeginStreamReply {
    IdleScreenCameraBeginStreamReply(
        accepted: true,
        errorCode: .none,
        errorMessage: nil,
        leaseIdentifier: lease,
        producerStreamEpoch: epoch,
        transportIdentifier: "camera/frame-mailbox.bin"
    )!
}

private func acceptedHeartbeatReply() -> IdleScreenCameraHeartbeatReply {
    IdleScreenCameraHeartbeatReply(
        accepted: true,
        errorCode: .none,
        errorMessage: nil
    )!
}
