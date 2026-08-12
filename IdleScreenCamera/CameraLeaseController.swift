import Foundation

/// Shared runtime timing used by both the agent lease store and its clients.
/// The agent runtime should reap abandoned leases independently at least once
/// per second; clients renew more than one request-timeout before expiration.
public struct CameraAgentLeasePolicy: Equatable, Sendable {
    public static let production = CameraAgentLeasePolicy(
        leaseTimeToLive: 6,
        heartbeatInterval: 2,
        requestTimeout: 1,
        stopGracePeriod: 0.25
    )!

    public let leaseTimeToLive: TimeInterval
    public let heartbeatInterval: TimeInterval
    public let requestTimeout: TimeInterval
    public let stopGracePeriod: TimeInterval

    public init?(
        leaseTimeToLive: TimeInterval,
        heartbeatInterval: TimeInterval,
        requestTimeout: TimeInterval,
        stopGracePeriod: TimeInterval
    ) {
        guard leaseTimeToLive.isFinite,
              heartbeatInterval.isFinite,
              requestTimeout.isFinite,
              stopGracePeriod.isFinite,
              leaseTimeToLive > 0,
              heartbeatInterval > 0,
              requestTimeout > 0,
              stopGracePeriod > 0,
              heartbeatInterval + requestTimeout < leaseTimeToLive,
              stopGracePeriod < leaseTimeToLive else {
            return nil
        }
        self.leaseTimeToLive = leaseTimeToLive
        self.heartbeatInterval = heartbeatInterval
        self.requestTimeout = requestTimeout
        self.stopGracePeriod = stopGracePeriod
    }
}

public struct CameraLeaseControllerConfiguration: Sendable {
    public let beginStreamRequest: IdleScreenCameraBeginStreamRequest
    public let leasePolicy: CameraAgentLeasePolicy

    public init?(
        maximumWidth: Int,
        maximumHeight: Int,
        maximumFramesPerSecond: Int,
        mailboxSlotCount: Int,
        leasePolicy: CameraAgentLeasePolicy
    ) {
        guard let request = IdleScreenCameraBeginStreamRequest(
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            maximumFramesPerSecond: maximumFramesPerSecond,
            mailboxSlotCount: mailboxSlotCount
        ) else {
            return nil
        }
        beginStreamRequest = request
        self.leasePolicy = leasePolicy
    }
}

public protocol CameraLeaseScheduledTask: AnyObject, Sendable {
    func cancel()
}

public protocol CameraLeaseScheduling: AnyObject, Sendable {
    var now: TimeInterval { get }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraLeaseScheduledTask
}

public final class CameraLeaseDispatchScheduler: CameraLeaseScheduling, @unchecked Sendable {
    private final class Task: CameraLeaseScheduledTask, @unchecked Sendable {
        private let lock = NSLock()
        private var workItem: DispatchWorkItem?

        init(workItem: DispatchWorkItem) {
            self.workItem = workItem
        }

        func cancel() {
            lock.withLock {
                workItem?.cancel()
                workItem = nil
            }
        }
    }

    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(
        label: "com.idlescreen.camera-client.lease-scheduler",
        qos: .userInitiated
    )) {
        self.queue = queue
    }

    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraLeaseScheduledTask {
        let workItem = DispatchWorkItem(block: operation)
        let task = Task(workItem: workItem)
        queue.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
        return task
    }
}

public struct CameraAgentStreamDescriptor: Equatable, Sendable {
    public let producerStreamEpoch: UInt64
    public let transportIdentifier: String

    public init(
        producerStreamEpoch: UInt64,
        transportIdentifier: String
    ) {
        self.producerStreamEpoch = producerStreamEpoch
        self.transportIdentifier = transportIdentifier
    }
}

public enum CameraLeaseControllerUpdate: Equatable, Sendable {
    case available(CameraAgentStreamDescriptor)
    case unavailable
}

/// Owns exactly one connection attempt and at most one lease for a screen-saver
/// process. All asynchronous callbacks are fenced by both local lifecycle
/// generation and connection attempt; producer epochs are never inferred from
/// either value.
public final class CameraLeaseController: @unchecked Sendable {
    private struct OperationFence: Equatable {
        let generation: UInt64
        let attempt: UInt64
    }

    private struct ActiveLease {
        let fence: OperationFence
        let leaseIdentifier: String
        let producerStreamEpoch: UInt64
        let transportIdentifier: String
    }

    private struct Retirement {
        let session: any CameraAgentClientSession
        let cleanupTask: any CameraLeaseScheduledTask
    }

    private let client: any CameraAgentClientConnecting
    private let scheduler: any CameraLeaseScheduling
    private let configuration: CameraLeaseControllerConfiguration
    private let updateHandler: @Sendable (CameraLeaseControllerUpdate) -> Void
    private let lock = NSRecursiveLock()
    private let clock: CameraLeaseSchedulerClock

    private var stateMachine: CameraConsumerStateMachine<CameraLeaseSchedulerClock>
    private var lifecycleGeneration: UInt64 = 0
    private var desiredRunning = false
    private var publishedAvailable = false
    private var currentSession: (any CameraAgentClientSession)?
    private var currentFence: OperationFence?
    private var beginInFlight: OperationFence?
    private var heartbeatInFlight: OperationFence?
    private var activeLease: ActiveLease?
    private var beginTimeoutTask: (any CameraLeaseScheduledTask)?
    private var heartbeatTask: (any CameraLeaseScheduledTask)?
    private var heartbeatTimeoutTask: (any CameraLeaseScheduledTask)?
    private var reconnectTask: (any CameraLeaseScheduledTask)?
    private var retirements: [UInt64: Retirement] = [:]

    public init(
        client: any CameraAgentClientConnecting,
        scheduler: any CameraLeaseScheduling,
        configuration: CameraLeaseControllerConfiguration,
        updateHandler: @escaping @Sendable (CameraLeaseControllerUpdate) -> Void
    ) {
        self.client = client
        self.scheduler = scheduler
        self.configuration = configuration
        self.updateHandler = updateHandler
        let clock = CameraLeaseSchedulerClock(scheduler: scheduler)
        self.clock = clock
        stateMachine = CameraConsumerStateMachine(clock: clock)
    }

    deinit {
        beginTimeoutTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatTimeoutTask?.cancel()
        reconnectTask?.cancel()
        for retirement in retirements.values {
            retirement.cleanupTask.cancel()
            retirement.session.invalidate()
        }
        currentSession?.invalidate()
    }

    public var state: CameraConsumerState {
        lock.withLock { stateMachine.state }
    }

    public func start() {
        lock.withLock {
            guard !desiredRunning else { return }
            desiredRunning = true
            lifecycleGeneration = nextGeneration(after: lifecycleGeneration)
            perform(
                stateMachine.handle(.start),
                generation: lifecycleGeneration
            )
        }
    }

    public func stop() {
        lock.withLock {
            guard desiredRunning || stateMachine.state != .disconnected else { return }
            desiredRunning = false
            lifecycleGeneration = nextGeneration(after: lifecycleGeneration)
            cancelOperationTasks()
            reconnectTask?.cancel()
            reconnectTask = nil
            _ = stateMachine.handle(.stop)

            let session = currentSession
            let leaseIdentifier = activeLease?.leaseIdentifier
            currentSession = nil
            currentFence = nil
            beginInFlight = nil
            heartbeatInFlight = nil
            activeLease = nil
            publishUnavailableIfNeeded()

            if let session {
                retire(
                    session: session,
                    leaseIdentifier: leaseIdentifier
                )
            }
        }
    }

    public func retryAfterExternalChange() {
        lock.withLock {
            guard desiredRunning else { return }
            reconnectTask?.cancel()
            reconnectTask = nil
            perform(
                stateMachine.handle(.externalRetry),
                generation: lifecycleGeneration
            )
        }
    }

    private func perform(
        _ actions: [CameraConsumerAction],
        generation: UInt64
    ) {
        for action in actions {
            switch action {
            case let .connect(attempt):
                connect(attempt: attempt, generation: generation)

            case let .beginStreaming(attempt, streamEpoch):
                guard let activeLease,
                      activeLease.fence == OperationFence(
                        generation: generation,
                        attempt: attempt
                      ),
                      activeLease.producerStreamEpoch == streamEpoch else {
                    continue
                }
                publishedAvailable = true
                updateHandler(.available(CameraAgentStreamDescriptor(
                    producerStreamEpoch: streamEpoch,
                    transportIdentifier: activeLease.transportIdentifier
                )))

            case let .scheduleReconnect(attempt, after, _):
                reconnectTask?.cancel()
                reconnectTask = scheduler.schedule(after: after) { [weak self] in
                    self?.reconnectDue(attempt: attempt, generation: generation)
                }

            case .cancelReconnect:
                reconnectTask?.cancel()
                reconnectTask = nil

            case .disconnect:
                disconnectCurrentSession()

            case .acceptFrame:
                break
            }
        }
    }

    private func connect(attempt: UInt64, generation: UInt64) {
        guard desiredRunning,
              generation == lifecycleGeneration,
              stateMachine.state == .connecting(attempt: attempt),
              beginInFlight == nil else {
            return
        }

        let fence = OperationFence(generation: generation, attempt: attempt)
        let session = client.connect(attempt: attempt) { [weak self] event in
            self?.receiveConnectionEvent(event, generation: generation)
        }

        guard desiredRunning,
              generation == lifecycleGeneration,
              stateMachine.state == .connecting(attempt: attempt),
              currentSession == nil else {
            session.invalidate()
            return
        }

        currentSession = session
        currentFence = fence
        beginInFlight = fence
        beginTimeoutTask = scheduler.schedule(
            after: configuration.leasePolicy.requestTimeout
        ) { [weak self] in
            self?.beginTimedOut(fence: fence)
        }
        session.beginStream(configuration.beginStreamRequest) { [weak self] reply in
            self?.receiveBeginReply(reply, fence: fence)
        }
    }

    private func receiveBeginReply(
        _ reply: IdleScreenCameraBeginStreamReply?,
        fence: OperationFence
    ) {
        lock.withLock {
            guard beginInFlight == fence else {
                reclaimAcceptedStaleBegin(reply, attempt: fence.attempt)
                return
            }
            beginTimeoutTask?.cancel()
            beginTimeoutTask = nil
            beginInFlight = nil

            guard desiredRunning,
                  fence.generation == lifecycleGeneration,
                  currentFence == fence,
                  let currentSession else {
                reclaimAcceptedStaleBegin(reply, attempt: fence.attempt)
                return
            }

            guard let reply, reply.accepted,
                  let leaseIdentifier = reply.leaseIdentifier,
                  let transportIdentifier = reply.transportIdentifier,
                  reply.producerStreamEpoch > 0 else {
                failCurrentBegin(reply: reply, fence: fence)
                return
            }

            activeLease = ActiveLease(
                fence: fence,
                leaseIdentifier: leaseIdentifier,
                producerStreamEpoch: reply.producerStreamEpoch,
                transportIdentifier: transportIdentifier
            )
            scheduleHeartbeat(for: activeLease!, session: currentSession)
            perform(
                stateMachine.handle(.connectionEstablished(
                    attempt: fence.attempt,
                    streamEpoch: reply.producerStreamEpoch
                )),
                generation: fence.generation
            )
        }
    }

    private func failCurrentBegin(
        reply: IdleScreenCameraBeginStreamReply?,
        fence: OperationFence
    ) {
        let event: CameraConsumerEvent
        switch reply?.errorCode {
        case .notAuthorized:
            event = .authorizationDenied(attempt: fence.attempt)
        case .cameraUnavailable:
            event = .unavailable(attempt: fence.attempt)
        default:
            event = .connectionFailed(attempt: fence.attempt)
        }

        if case .connectionFailed = event {
            disconnectCurrentSession()
        }
        perform(stateMachine.handle(event), generation: fence.generation)
    }

    private func beginTimedOut(fence: OperationFence) {
        lock.withLock {
            guard desiredRunning,
                  lifecycleGeneration == fence.generation,
                  beginInFlight == fence else {
                return
            }
            beginInFlight = nil
            beginTimeoutTask = nil
            disconnectCurrentSession()
            perform(
                stateMachine.handle(.connectionFailed(attempt: fence.attempt)),
                generation: fence.generation
            )
        }
    }

    private func scheduleHeartbeat(
        for lease: ActiveLease,
        session: any CameraAgentClientSession
    ) {
        heartbeatTask?.cancel()
        heartbeatTask = scheduler.schedule(
            after: configuration.leasePolicy.heartbeatInterval
        ) { [weak self, weak session] in
            guard let session else { return }
            self?.sendHeartbeat(lease: lease, session: session)
        }
    }

    private func sendHeartbeat(
        lease: ActiveLease,
        session: any CameraAgentClientSession
    ) {
        lock.withLock {
            guard desiredRunning,
                  lifecycleGeneration == lease.fence.generation,
                  activeLease?.fence == lease.fence,
                  activeLease?.producerStreamEpoch == lease.producerStreamEpoch,
                  heartbeatInFlight == nil,
                  currentSession === session,
                  let request = IdleScreenCameraHeartbeatRequest(
                    leaseIdentifier: lease.leaseIdentifier
                  ) else {
                return
            }
            heartbeatTask = nil
            heartbeatInFlight = lease.fence
            heartbeatTimeoutTask = scheduler.schedule(
                after: configuration.leasePolicy.requestTimeout
            ) { [weak self] in
                self?.heartbeatTimedOut(
                    fence: lease.fence,
                    streamEpoch: lease.producerStreamEpoch
                )
            }
            session.heartbeat(request) { [weak self] reply in
                self?.receiveHeartbeatReply(
                    reply,
                    fence: lease.fence,
                    streamEpoch: lease.producerStreamEpoch
                )
            }
        }
    }

    private func receiveHeartbeatReply(
        _ reply: IdleScreenCameraHeartbeatReply?,
        fence: OperationFence,
        streamEpoch: UInt64
    ) {
        lock.withLock {
            guard desiredRunning,
                  lifecycleGeneration == fence.generation,
                  heartbeatInFlight == fence,
                  activeLease?.fence == fence,
                  activeLease?.producerStreamEpoch == streamEpoch,
                  let session = currentSession else {
                return
            }
            heartbeatTimeoutTask?.cancel()
            heartbeatTimeoutTask = nil
            heartbeatInFlight = nil

            guard let reply, reply.accepted else {
                failCurrentConnection(
                    event: .invalidated(attempt: fence.attempt),
                    generation: fence.generation
                )
                return
            }
            scheduleHeartbeat(for: activeLease!, session: session)
        }
    }

    private func heartbeatTimedOut(
        fence: OperationFence,
        streamEpoch: UInt64
    ) {
        lock.withLock {
            guard desiredRunning,
                  lifecycleGeneration == fence.generation,
                  heartbeatInFlight == fence,
                  activeLease?.producerStreamEpoch == streamEpoch else {
                return
            }
            heartbeatInFlight = nil
            heartbeatTimeoutTask = nil
            failCurrentConnection(
                event: .invalidated(attempt: fence.attempt),
                generation: fence.generation
            )
        }
    }

    private func receiveConnectionEvent(
        _ event: CameraAgentClientConnectionEvent,
        generation: UInt64
    ) {
        lock.withLock {
            guard desiredRunning,
                  generation == lifecycleGeneration,
                  currentFence == OperationFence(
                    generation: generation,
                    attempt: event.attempt
                  ) else {
                return
            }

            let consumerEvent: CameraConsumerEvent
            switch event {
            case let .interrupted(attempt):
                consumerEvent = .interrupted(attempt: attempt)
                if let session = takeCurrentSession() {
                    retire(session: session, leaseIdentifier: nil)
                }
            case let .invalidated(attempt):
                consumerEvent = .invalidated(attempt: attempt)
                _ = takeCurrentSession()
            case let .requestFailed(attempt):
                consumerEvent = .invalidated(attempt: attempt)
                disconnectCurrentSession()
            }

            cancelOperationTasks()
            activeLease = nil
            publishUnavailableIfNeeded()
            perform(stateMachine.handle(consumerEvent), generation: generation)
        }
    }

    private func failCurrentConnection(
        event: CameraConsumerEvent,
        generation: UInt64
    ) {
        cancelOperationTasks()
        activeLease = nil
        publishUnavailableIfNeeded()
        disconnectCurrentSession()
        perform(stateMachine.handle(event), generation: generation)
    }

    private func reconnectDue(attempt: UInt64, generation: UInt64) {
        lock.withLock {
            guard desiredRunning, generation == lifecycleGeneration else { return }
            reconnectTask = nil
            perform(
                stateMachine.handle(.reconnectDue(attempt: attempt)),
                generation: generation
            )
        }
    }

    private func disconnectCurrentSession() {
        let session = takeCurrentSession()
        session?.invalidate()
    }

    private func takeCurrentSession() -> (any CameraAgentClientSession)? {
        cancelOperationTasks()
        let session = currentSession
        currentSession = nil
        currentFence = nil
        beginInFlight = nil
        heartbeatInFlight = nil
        activeLease = nil
        return session
    }

    private func cancelOperationTasks() {
        beginTimeoutTask?.cancel()
        beginTimeoutTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = nil
    }

    private func retire(
        session: any CameraAgentClientSession,
        leaseIdentifier: String?
    ) {
        let attempt = session.attempt
        retirements[attempt]?.cleanupTask.cancel()
        let cleanupTask = scheduler.schedule(
            after: configuration.leasePolicy.stopGracePeriod
        ) { [weak self, weak session] in
            guard let session else { return }
            self?.finishRetirement(attempt: attempt, session: session)
        }
        retirements[attempt] = Retirement(
            session: session,
            cleanupTask: cleanupTask
        )

        if let leaseIdentifier {
            sendEnd(
                leaseIdentifier: leaseIdentifier,
                attempt: attempt,
                session: session
            )
        }
    }

    private func reclaimAcceptedStaleBegin(
        _ reply: IdleScreenCameraBeginStreamReply?,
        attempt: UInt64
    ) {
        guard let reply, reply.accepted,
              let leaseIdentifier = reply.leaseIdentifier,
              let retirement = retirements[attempt] else {
            return
        }
        sendEnd(
            leaseIdentifier: leaseIdentifier,
            attempt: attempt,
            session: retirement.session
        )
    }

    private func sendEnd(
        leaseIdentifier: String,
        attempt: UInt64,
        session: any CameraAgentClientSession
    ) {
        guard let request = IdleScreenCameraEndStreamRequest(
            leaseIdentifier: leaseIdentifier
        ) else {
            finishRetirement(attempt: attempt, session: session)
            return
        }
        session.endStream(request) { [weak self, weak session] _ in
            guard let session else { return }
            self?.finishRetirement(attempt: attempt, session: session)
        }
    }

    private func finishRetirement(
        attempt: UInt64,
        session: any CameraAgentClientSession
    ) {
        lock.withLock {
            guard let retirement = retirements[attempt],
                  retirement.session === session else {
                return
            }
            retirement.cleanupTask.cancel()
            retirements.removeValue(forKey: attempt)
            session.invalidate()
        }
    }

    private func publishUnavailableIfNeeded() {
        guard publishedAvailable else { return }
        publishedAvailable = false
        updateHandler(.unavailable)
    }

    private func nextGeneration(after value: UInt64) -> UInt64 {
        value == .max ? 1 : value + 1
    }
}

private final class CameraLeaseSchedulerClock: CameraConsumerClock, @unchecked Sendable {
    private let scheduler: any CameraLeaseScheduling

    init(scheduler: any CameraLeaseScheduling) {
        self.scheduler = scheduler
    }

    var now: TimeInterval {
        scheduler.now
    }
}
