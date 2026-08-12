import Foundation

public enum CameraAgentControlRequestFailure: Equatable, Sendable {
    case timeout
    case transportUnavailable
}

/// Events emitted only by the companion control connection. Lease clients
/// continue to use `CameraAgentClientConnectionEvent`.
public enum CameraAgentControlConnectionEvent: Equatable, Sendable {
    case interrupted(attempt: UInt64)
    case invalidated(attempt: UInt64)
    case requestFailed(
        attempt: UInt64,
        failure: CameraAgentControlRequestFailure
    )

    public var attempt: UInt64 {
        switch self {
        case let .interrupted(attempt),
             let .invalidated(attempt),
             let .requestFailed(attempt, _):
            return attempt
        }
    }
}

/// Companion-only control surface. It intentionally has no stream, heartbeat,
/// lease, or frame APIs.
public protocol CameraAgentControlSession: AnyObject, Sendable {
    var attempt: UInt64 { get }
    var remoteProcessIdentifier: Int32 { get }

    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        reply: @escaping @Sendable (IdleScreenCameraAuthorizationReply?) -> Void
    )

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        reply: @escaping @Sendable (IdleScreenCameraAuthorizationReply?) -> Void
    )

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        reply: @escaping @Sendable (IdleScreenCameraDiagnosticSnapshot?) -> Void
    )

    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        reply: @escaping @Sendable (IdleScreenCameraDeviceSnapshotReply?) -> Void
    )

    func invalidate()
}

public extension CameraAgentControlSession {
    /// The kernel-observed PID of the peer, or zero when a test transport cannot expose it.
    var remoteProcessIdentifier: Int32 { 0 }
}

/// Creates an independently fenced companion control connection. The exact
/// agent signing requirement is installed before activation; the agent applies
/// the reciprocal listener signing requirement, live-code validation, PID, and
/// effective-user policy to authenticate the app. Foundation does not expose a
/// public `NSXPCConnection` audit token here.
public final class CameraAgentControlClient: @unchecked Sendable {
    static let productionRequestTimeout: TimeInterval = 2

    private let configuration: CameraAgentXPCClientConfiguration
    private let connectionFactory:
        @Sendable (String) -> any CameraAgentXPCConnectionTransport
    private let scheduler: any CameraLeaseScheduling
    private let requestTimeout: TimeInterval

    public convenience init(configuration: CameraAgentXPCClientConfiguration) {
        self.init(
            configuration: configuration,
            connectionFactory: { machServiceName in
                NSXPCConnection(machServiceName: machServiceName, options: [])
            },
            scheduler: CameraLeaseDispatchScheduler(),
            requestTimeout: Self.productionRequestTimeout
        )
    }

    init(
        configuration: CameraAgentXPCClientConfiguration,
        connectionFactory: @escaping
            @Sendable (String) -> any CameraAgentXPCConnectionTransport,
        scheduler: any CameraLeaseScheduling = CameraLeaseDispatchScheduler(),
        requestTimeout: TimeInterval = CameraAgentControlClient.productionRequestTimeout
    ) {
        self.configuration = configuration
        self.connectionFactory = connectionFactory
        self.scheduler = scheduler
        self.requestTimeout = requestTimeout
    }

    public func connect(
        attempt: UInt64,
        eventHandler: @escaping
            @Sendable (CameraAgentControlConnectionEvent) -> Void
    ) -> any CameraAgentControlSession {
        let connection = connectionFactory(configuration.machServiceName)
        let session = CameraAgentControlClientSession(
            attempt: attempt,
            connection: connection,
            codeSigningRequirement: configuration.codeSigningRequirement,
            scheduler: scheduler,
            requestTimeout: requestTimeout,
            eventHandler: eventHandler
        )
        session.activate()
        return session
    }
}

private final class CameraAgentControlClientSession:
    CameraAgentControlSession,
    @unchecked Sendable
{
    let attempt: UInt64
    var remoteProcessIdentifier: Int32 { connection.processIdentifier }

    private let connection: any CameraAgentXPCConnectionTransport
    private let codeSigningRequirement: String
    private let scheduler: any CameraLeaseScheduling
    private let requestTimeout: TimeInterval
    private let eventHandler:
        @Sendable (CameraAgentControlConnectionEvent) -> Void
    private let lock = NSLock()
    private var isInvalidated = false
    private var didEmitInterruption = false
    private var pendingRequests: [UUID: any CameraAgentControlPendingRequest] = [:]

    init(
        attempt: UInt64,
        connection: any CameraAgentXPCConnectionTransport,
        codeSigningRequirement: String,
        scheduler: any CameraLeaseScheduling,
        requestTimeout: TimeInterval,
        eventHandler: @escaping
            @Sendable (CameraAgentControlConnectionEvent) -> Void
    ) {
        self.attempt = attempt
        self.connection = connection
        self.codeSigningRequirement = codeSigningRequirement
        self.scheduler = scheduler
        self.requestTimeout = requestTimeout
        self.eventHandler = eventHandler
    }

    func activate() {
        connection.setCodeSigningRequirement(codeSigningRequirement)
        connection.remoteObjectInterface = IdleScreenCameraXPCInterface.make()
        connection.interruptionHandler = { [weak self] in
            guard let self else { return }
            if transitionToInterrupted() {
                eventHandler(.interrupted(attempt: attempt))
            }
        }
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            let invalidation = transitionToInvalidated()
            completeWithNil(invalidation.1)
            if invalidation.0 {
                eventHandler(.invalidated(attempt: attempt))
            }
        }
        connection.activate()
    }

    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        reply: @escaping @Sendable (IdleScreenCameraAuthorizationReply?) -> Void
    ) {
        withRemoteProxy(reply: reply) { proxy, complete in
            proxy.authorizationStatus(request) { complete($0) }
        }
    }

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        reply: @escaping @Sendable (IdleScreenCameraAuthorizationReply?) -> Void
    ) {
        withRemoteProxy(reply: reply) { proxy, complete in
            proxy.requestAuthorization(request) { complete($0) }
        }
    }

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        reply: @escaping @Sendable (IdleScreenCameraDiagnosticSnapshot?) -> Void
    ) {
        withRemoteProxy(reply: reply) { proxy, complete in
            proxy.diagnosticSnapshot(request) { complete($0) }
        }
    }

    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        reply: @escaping @Sendable (IdleScreenCameraDeviceSnapshotReply?) -> Void
    ) {
        withRemoteProxy(reply: reply) { proxy, complete in
            proxy.cameraDeviceSnapshot(request) { complete($0) }
        }
    }

    func invalidate() {
        let invalidation = transitionToInvalidated()
        guard invalidation.0 else { return }
        completeWithNil(invalidation.1)
        connection.invalidate()
    }

    private func transitionToInvalidated() -> (
        Bool,
        [any CameraAgentControlPendingRequest]
    ) {
        let invalidation = lock.withLock {
            guard !isInvalidated else {
                return (false, [any CameraAgentControlPendingRequest]())
            }
            isInvalidated = true
            let requests = Array(pendingRequests.values)
            pendingRequests.removeAll()
            return (true, requests)
        }
        return invalidation
    }

    private func transitionToInterrupted() -> Bool {
        lock.withLock {
            guard !isInvalidated, !didEmitInterruption else { return false }
            didEmitInterruption = true
            return true
        }
    }

    private func completeWithNil(
        _ pendingRequests: [any CameraAgentControlPendingRequest]
    ) {
        for request in pendingRequests {
            request.completeWithNil()
        }
    }

    private func withRemoteProxy<Reply: Sendable>(
        reply: @escaping @Sendable (Reply?) -> Void,
        operation: (
            (any IdleScreenCameraXPCProtocol),
            @escaping @Sendable (Reply?) -> Void
        ) -> Void
    ) {
        let gate = CameraAgentControlReplyGate(reply: reply)
        let requestIdentifier = UUID()
        let didRegister = lock.withLock {
            guard !isInvalidated else { return false }
            pendingRequests[requestIdentifier] = gate
            return true
        }
        guard didRegister else {
            gate.complete(nil)
            return
        }

        let timeoutTask = scheduler.schedule(after: requestTimeout) {
            [weak self, weak gate] in
            guard let self, let gate else { return }
            completeRequest(
                requestIdentifier,
                gate: gate,
                value: nil,
                failure: .timeout
            )
        }
        gate.install(timeoutTask: timeoutTask)

        guard isPending(requestIdentifier, gate: gate) else { return }
        let proxy = connection.remoteCameraProxy { [weak self, weak gate] _ in
            guard let self, let gate else { return }
            completeRequest(
                requestIdentifier,
                gate: gate,
                value: nil,
                failure: .transportUnavailable
            )
        }
        guard let proxy else {
            completeRequest(
                requestIdentifier,
                gate: gate,
                value: nil,
                failure: .transportUnavailable
            )
            return
        }
        operation(proxy) { [weak self, weak gate] response in
            guard let self, let gate else { return }
            completeRequest(
                requestIdentifier,
                gate: gate,
                value: response,
                failure: nil
            )
        }
    }

    private func isPending<Reply: Sendable>(
        _ requestIdentifier: UUID,
        gate: CameraAgentControlReplyGate<Reply>
    ) -> Bool {
        lock.withLock {
            guard let request = pendingRequests[requestIdentifier] else {
                return false
            }
            return request === gate
        }
    }

    private func completeRequest<Reply: Sendable>(
        _ requestIdentifier: UUID,
        gate: CameraAgentControlReplyGate<Reply>,
        value: Reply?,
        failure: CameraAgentControlRequestFailure?
    ) {
        let didRemove = lock.withLock {
            guard let request = pendingRequests[requestIdentifier],
                  request === gate else {
                return false
            }
            pendingRequests.removeValue(forKey: requestIdentifier)
            return true
        }
        guard didRemove, gate.complete(value) else { return }
        if let failure {
            eventHandler(.requestFailed(attempt: attempt, failure: failure))
        }
    }
}

private protocol CameraAgentControlPendingRequest: AnyObject, Sendable {
    func completeWithNil()
}

private final class CameraAgentControlReplyGate<Reply: Sendable>:
    CameraAgentControlPendingRequest,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var reply: (@Sendable (Reply?) -> Void)?
    private var timeoutTask: (any CameraLeaseScheduledTask)?

    init(reply: @escaping @Sendable (Reply?) -> Void) {
        self.reply = reply
    }

    func completeWithNil() {
        complete(nil)
    }

    func install(timeoutTask: any CameraLeaseScheduledTask) {
        let shouldCancel = lock.withLock {
            guard reply != nil else { return true }
            self.timeoutTask = timeoutTask
            return false
        }
        if shouldCancel {
            timeoutTask.cancel()
        }
    }

    @discardableResult
    func complete(_ value: Reply?) -> Bool {
        let result = lock.withLock {
            let callback = reply
            reply = nil
            let timeoutTask = timeoutTask
            self.timeoutTask = nil
            return (callback, timeoutTask)
        }
        result.1?.cancel()
        result.0?(value)
        return result.0 != nil
    }
}

public enum CameraAuthorizationPollingResult: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case timedOut
}

public enum CameraAuthorizationPollingEvent: Equatable, Sendable {
    case explicitPermissionRequest(generation: UInt64)
    case pollDeadlineReached(generation: UInt64, poll: UInt64)
    case authorizationStatusReceived(
        generation: UInt64,
        poll: UInt64,
        status: CameraAgentAuthorization
    )
    case timeoutDeadlineReached(generation: UInt64)
}

public enum CameraAuthorizationPollingAction: Equatable, Sendable {
    case scheduleStatusPoll(
        generation: UInt64,
        poll: UInt64,
        after: TimeInterval
    )
    case scheduleTimeout(generation: UInt64, after: TimeInterval)
    case requestAuthorizationStatus(generation: UInt64, poll: UInt64)
    case completed(
        generation: UInt64,
        result: CameraAuthorizationPollingResult
    )
}

/// Scheduler-independent polling after one explicit permission action. This
/// reducer cannot request permission; it can only ask its caller to perform a
/// nonprompting authorization-status read.
public struct CameraAuthorizationPollingPolicy: Sendable {
    public static let pollInterval: TimeInterval = 0.25
    public static let maximumDuration: TimeInterval = 5
    public static let maximumPollCount: UInt64 = 8

    public private(set) var currentGeneration: UInt64?

    private enum Phase: Sendable {
        case waitingForPollDeadline(poll: UInt64)
        case waitingForStatusReply(poll: UInt64)
        case completed
    }

    private var phase: Phase?

    public init() {}

    public mutating func handle(
        _ event: CameraAuthorizationPollingEvent
    ) -> [CameraAuthorizationPollingAction] {
        if case let .explicitPermissionRequest(generation) = event {
            return start(generation: generation)
        }

        let generation = generation(for: event)
        guard generation == currentGeneration, let phase else { return [] }

        switch (phase, event) {
        case let (
            .waitingForPollDeadline(expectedPoll),
            .pollDeadlineReached(_, poll)
        ) where poll == expectedPoll:
            self.phase = .waitingForStatusReply(poll: poll)
            return [.requestAuthorizationStatus(
                generation: generation,
                poll: poll
            )]

        case let (
            .waitingForStatusReply(expectedPoll),
            .authorizationStatusReceived(_, poll, status)
        ) where poll == expectedPoll:
            return receive(
                status: status,
                generation: generation,
                poll: poll
            )

        case (.waitingForPollDeadline, .timeoutDeadlineReached),
             (.waitingForStatusReply, .timeoutDeadlineReached):
            self.phase = .completed
            return [.completed(generation: generation, result: .timedOut)]

        case (.completed, _),
             (_, .pollDeadlineReached),
             (_, .authorizationStatusReceived),
             (_, .explicitPermissionRequest):
            return []
        }
    }

    private mutating func start(
        generation: UInt64
    ) -> [CameraAuthorizationPollingAction] {
        guard generation > 0 else { return [] }
        if let currentGeneration {
            guard generation > currentGeneration else { return [] }
        }

        currentGeneration = generation
        phase = .waitingForPollDeadline(poll: 1)
        return [
            .scheduleStatusPoll(
                generation: generation,
                poll: 1,
                after: Self.pollInterval
            ),
            .scheduleTimeout(
                generation: generation,
                after: Self.maximumDuration
            )
        ]
    }

    private mutating func receive(
        status: CameraAgentAuthorization,
        generation: UInt64,
        poll: UInt64
    ) -> [CameraAuthorizationPollingAction] {
        switch status {
        case .authorized:
            phase = .completed
            return [.completed(generation: generation, result: .authorized)]
        case .denied:
            phase = .completed
            return [.completed(generation: generation, result: .denied)]
        case .restricted:
            phase = .completed
            return [.completed(generation: generation, result: .restricted)]
        case .notDetermined where poll >= Self.maximumPollCount:
            phase = .completed
            return [.completed(generation: generation, result: .timedOut)]
        case .notDetermined:
            let nextPoll = poll + 1
            phase = .waitingForPollDeadline(poll: nextPoll)
            return [.scheduleStatusPoll(
                generation: generation,
                poll: nextPoll,
                after: Self.pollInterval
            )]
        }
    }

    private func generation(
        for event: CameraAuthorizationPollingEvent
    ) -> UInt64 {
        switch event {
        case let .explicitPermissionRequest(generation),
             let .pollDeadlineReached(generation, _),
             let .authorizationStatusReceived(generation, _, _),
             let .timeoutDeadlineReached(generation):
            return generation
        }
    }
}
