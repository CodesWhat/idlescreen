import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera agent companion control client")
struct CameraAgentControlClientTests {
    @Test("exact agent requirement and control interface are installed before activation")
    func authenticatesBeforeActivation() throws {
        let harness = try ControlClientHarness()

        _ = harness.client.connect(attempt: 12) { _ in }

        #expect(harness.transport.events == [
            .codeSigningRequirement(harness.configuration.codeSigningRequirement),
            .remoteInterface("IdleScreenCameraXPCProtocol"),
            .interruptionHandler,
            .invalidationHandler,
            .activated
        ])
    }

    @Test("the control session exposes the kernel-observed remote process identifier")
    func exposesRemoteProcessIdentifier() throws {
        let harness = try ControlClientHarness()
        harness.transport.processIdentifier = 4_242

        let session = harness.client.connect(attempt: 13) { _ in }

        #expect(session.remoteProcessIdentifier == 4_242)
    }

    @Test("status, explicit authorization, and diagnostics forward exact DTOs and replies")
    func forwardsControlDTOsExactly() throws {
        let harness = try ControlClientHarness()
        let session = harness.client.connect(attempt: 2) { _ in }
        let statusRequest = try #require(IdleScreenCameraStatusRequest())
        let authorizationRequest = try #require(IdleScreenCameraAuthorizationRequest())
        let diagnosticRequest = try #require(IdleScreenCameraDiagnosticRequest())
        let statusReply = try #require(IdleScreenCameraAuthorizationReply(
            accepted: true,
            status: .authorized,
            errorCode: .none,
            errorMessage: nil
        ))
        let authorizationReply = try #require(IdleScreenCameraAuthorizationReply(
            accepted: false,
            status: .denied,
            errorCode: .notAuthorized,
            errorMessage: "User action required"
        ))
        let diagnosticReply = try #require(IdleScreenCameraDiagnosticSnapshot(
            accepted: true,
            errorCode: .none,
            errorMessage: nil,
            agentIdentity: makeControlAgentIdentity(),
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "idle"
        ))
        harness.remote.statusReply = statusReply
        harness.remote.authorizationReply = authorizationReply
        harness.remote.diagnosticReply = diagnosticReply
        let observedStatus = LockedControlValue<IdleScreenCameraAuthorizationReply?>(nil)
        let observedAuthorization = LockedControlValue<IdleScreenCameraAuthorizationReply?>(nil)
        let observedDiagnostic = LockedControlValue<IdleScreenCameraDiagnosticSnapshot?>(nil)

        session.authorizationStatus(statusRequest) { observedStatus.set($0) }
        session.requestAuthorization(authorizationRequest) { observedAuthorization.set($0) }
        session.diagnosticSnapshot(diagnosticRequest) { observedDiagnostic.set($0) }

        #expect(harness.remote.statusRequests.count == 1)
        #expect(harness.remote.statusRequests[0] === statusRequest)
        #expect(harness.remote.authorizationRequests.count == 1)
        #expect(harness.remote.authorizationRequests[0] === authorizationRequest)
        #expect(harness.remote.diagnosticRequests.count == 1)
        #expect(harness.remote.diagnosticRequests[0] === diagnosticRequest)
        #expect(observedStatus.value === statusReply)
        #expect(observedAuthorization.value === authorizationReply)
        #expect(observedDiagnostic.value === diagnosticReply)
        #expect(harness.remote.beginRequestCount == 0)
    }

    @Test("proxy request errors emit a fenced event and complete with nil exactly once")
    func requestErrorsFailClosed() throws {
        let harness = try ControlClientHarness()
        let events = LockedControlClientEvents()
        let session = harness.client.connect(attempt: 44) { events.append($0) }
        harness.transport.failNextProxyRequest()
        let callbackCount = LockedControlValue(0)
        let observedReply = LockedControlValue<IdleScreenCameraAuthorizationReply?>(nil)

        session.authorizationStatus(try #require(IdleScreenCameraStatusRequest())) {
            callbackCount.mutate { $0 += 1 }
            observedReply.set($0)
        }

        #expect(callbackCount.value == 1)
        #expect(observedReply.value == nil)
        #expect(events.values == [
            .requestFailed(attempt: 44, failure: .transportUnavailable)
        ])
        #expect(harness.remote.statusRequests.isEmpty)
    }

    @Test("a silent connected service times out every control request exactly once")
    func silentServiceTimesOutEveryRequest() throws {
        let harness = try ControlClientHarness()
        let events = LockedControlClientEvents()
        let session = harness.client.connect(attempt: 45) { events.append($0) }
        let statusCallbackCount = LockedControlValue(0)
        let authorizationCallbackCount = LockedControlValue(0)
        let diagnosticCallbackCount = LockedControlValue(0)
        harness.remote.respondsImmediately = false
        harness.remote.statusReply = try #require(IdleScreenCameraAuthorizationReply(
            accepted: true,
            status: .authorized,
            errorCode: .none,
            errorMessage: nil
        ))
        harness.remote.authorizationReply = harness.remote.statusReply
        harness.remote.diagnosticReply = try #require(IdleScreenCameraDiagnosticSnapshot(
            accepted: true,
            errorCode: .none,
            errorMessage: nil,
            agentIdentity: makeControlAgentIdentity(),
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "idle"
        ))

        session.authorizationStatus(
            try #require(IdleScreenCameraStatusRequest())
        ) { reply in
            statusCallbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }
        session.requestAuthorization(
            try #require(IdleScreenCameraAuthorizationRequest())
        ) { reply in
            authorizationCallbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }
        session.diagnosticSnapshot(
            try #require(IdleScreenCameraDiagnosticRequest())
        ) { reply in
            diagnosticCallbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }

        #expect(harness.scheduler.scheduledDelays == [2, 2, 2])
        harness.scheduler.fireAll()
        harness.remote.replyToAllPendingRequests()

        #expect(statusCallbackCount.value == 1)
        #expect(authorizationCallbackCount.value == 1)
        #expect(diagnosticCallbackCount.value == 1)
        #expect(events.values == Array(
            repeating: .requestFailed(attempt: 45, failure: .timeout),
            count: 3
        ))
    }

    @Test("concurrent requests keep independent reply and timeout fences")
    func concurrentRequestsAreIndependentlyFenced() throws {
        let harness = try ControlClientHarness()
        let events = LockedControlClientEvents()
        let session = harness.client.connect(attempt: 47) { events.append($0) }
        let callbackWasNil = LockedControlValue<[Bool]>([])
        harness.remote.respondsImmediately = false
        harness.remote.statusReply = try #require(IdleScreenCameraAuthorizationReply(
            accepted: true,
            status: .authorized,
            errorCode: .none,
            errorMessage: nil
        ))

        session.authorizationStatus(
            try #require(IdleScreenCameraStatusRequest())
        ) { reply in
            callbackWasNil.mutate { $0.append(reply == nil) }
        }
        session.authorizationStatus(
            try #require(IdleScreenCameraStatusRequest())
        ) { reply in
            callbackWasNil.mutate { $0.append(reply == nil) }
        }

        harness.remote.replyToNextStatusRequest()
        harness.scheduler.fire(at: 0)

        #expect(callbackWasNil.value == [false])
        #expect(events.values.isEmpty)

        harness.scheduler.fire(at: 1)
        harness.remote.replyToAllPendingRequests()

        #expect(callbackWasNil.value == [false, true])
        #expect(events.values == [
            .requestFailed(attempt: 47, failure: .timeout)
        ])
        #expect(harness.scheduler.cancelledTaskCount == 2)
    }

    @Test("invalidation resolves pending requests and fences their timeouts and late replies")
    func invalidationResolvesPendingRequests() throws {
        let harness = try ControlClientHarness()
        let events = LockedControlClientEvents()
        let session = harness.client.connect(attempt: 46) { events.append($0) }
        let callbackCount = LockedControlValue(0)
        harness.remote.respondsImmediately = false
        harness.remote.statusReply = try #require(IdleScreenCameraAuthorizationReply(
            accepted: true,
            status: .authorized,
            errorCode: .none,
            errorMessage: nil
        ))
        harness.remote.authorizationReply = harness.remote.statusReply
        harness.remote.diagnosticReply = try #require(IdleScreenCameraDiagnosticSnapshot(
            accepted: true,
            errorCode: .none,
            errorMessage: nil,
            agentIdentity: makeControlAgentIdentity(),
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "idle"
        ))

        session.authorizationStatus(
            try #require(IdleScreenCameraStatusRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }
        session.requestAuthorization(
            try #require(IdleScreenCameraAuthorizationRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }
        session.diagnosticSnapshot(
            try #require(IdleScreenCameraDiagnosticRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }

        session.invalidate()
        #expect(callbackCount.value == 3)
        #expect(harness.scheduler.cancelledTaskCount == 3)

        harness.scheduler.fireAll()
        harness.remote.replyToAllPendingRequests()

        #expect(callbackCount.value == 3)
        #expect(events.values.isEmpty)
    }

    @Test("connection events retain the originating control attempt")
    func forwardsConnectionEvents() throws {
        let harness = try ControlClientHarness()
        let events = LockedControlClientEvents()
        let session = harness.client.connect(attempt: 17) { events.append($0) }

        harness.transport.interruptionHandler?()
        harness.transport.invalidationHandler?()

        #expect(events.values == [
            .interrupted(attempt: 17),
            .invalidated(attempt: 17)
        ])
        withExtendedLifetime(session) {}
    }

    @Test("duplicate transport lifecycle callbacks emit each control event once")
    func lifecycleEventsAreExactlyOnce() throws {
        let harness = try ControlClientHarness()
        let events = LockedControlClientEvents()
        let session = harness.client.connect(attempt: 18) { events.append($0) }

        harness.transport.interruptionHandler?()
        harness.transport.interruptionHandler?()
        harness.transport.invalidationHandler?()
        harness.transport.invalidationHandler?()
        harness.transport.interruptionHandler?()

        #expect(events.values == [
            .interrupted(attempt: 18),
            .invalidated(attempt: 18)
        ])
        withExtendedLifetime(session) {}
    }

    @Test("transport invalidation closes the session and resolves pending requests")
    func transportInvalidationResolvesPendingRequests() throws {
        let harness = try ControlClientHarness()
        let events = LockedControlClientEvents()
        let session = harness.client.connect(attempt: 48) { events.append($0) }
        let callbackCount = LockedControlValue(0)
        harness.remote.respondsImmediately = false

        session.authorizationStatus(
            try #require(IdleScreenCameraStatusRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }
        session.requestAuthorization(
            try #require(IdleScreenCameraAuthorizationRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }
        session.diagnosticSnapshot(
            try #require(IdleScreenCameraDiagnosticRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }

        harness.transport.invalidationHandler?()

        #expect(callbackCount.value == 3)
        #expect(harness.scheduler.cancelledTaskCount == 3)
        #expect(events.values == [.invalidated(attempt: 48)])
        #expect(harness.transport.events.filter { $0 == .invalidated }.isEmpty)

        harness.scheduler.fireAll()
        session.authorizationStatus(
            try #require(IdleScreenCameraStatusRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }

        #expect(callbackCount.value == 4)
        #expect(harness.transport.proxyRequestCount == 3)
        #expect(events.values == [.invalidated(attempt: 48)])
    }

    @Test("invalidation is idempotent and permanently closes the control session")
    func invalidationClosesSession() throws {
        let harness = try ControlClientHarness()
        let session = harness.client.connect(attempt: 1) { _ in }
        session.invalidate()
        session.invalidate()
        let callbackCount = LockedControlValue(0)

        session.authorizationStatus(try #require(IdleScreenCameraStatusRequest())) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }
        session.requestAuthorization(
            try #require(IdleScreenCameraAuthorizationRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }
        session.diagnosticSnapshot(
            try #require(IdleScreenCameraDiagnosticRequest())
        ) { reply in
            callbackCount.mutate { $0 += 1 }
            #expect(reply == nil)
        }

        #expect(harness.transport.events.filter { $0 == .invalidated }.count == 1)
        #expect(callbackCount.value == 3)
        #expect(harness.transport.proxyRequestCount == 0)
        #expect(harness.remote.statusRequests.isEmpty)
        #expect(harness.remote.authorizationRequests.isEmpty)
        #expect(harness.remote.diagnosticRequests.isEmpty)
    }

    @Test("connection handlers do not retain a released control session")
    func handlersDoNotRetainSession() throws {
        let harness = try ControlClientHarness()
        var session: (any CameraAgentControlSession)? = harness.client.connect(
            attempt: 1
        ) { _ in }
        let weakSession = WeakControlClientObject(session as AnyObject)

        session = nil

        #expect(weakSession.value == nil)
    }
}

@Suite("Camera authorization polling policy")
struct CameraAuthorizationPollingPolicyTests {
    @Test("polling cannot start without one explicit permission request action")
    func requiresExplicitPermissionAction() {
        var policy = CameraAuthorizationPollingPolicy()

        #expect(policy.handle(
            .pollDeadlineReached(generation: 1, poll: 1)
        ).isEmpty)
        #expect(policy.handle(
            .authorizationStatusReceived(
                generation: 1,
                poll: 1,
                status: .authorized
            )
        ).isEmpty)
        #expect(policy.handle(
            .timeoutDeadlineReached(generation: 1)
        ).isEmpty)
    }

    @Test("one explicit permission action schedules a bounded nonprompting poll run")
    func explicitActionStartsBoundedPolling() {
        var policy = CameraAuthorizationPollingPolicy()

        #expect(policy.handle(
            .explicitPermissionRequest(generation: 7)
        ) == [
            .scheduleStatusPoll(
                generation: 7,
                poll: 1,
                after: CameraAuthorizationPollingPolicy.pollInterval
            ),
            .scheduleTimeout(
                generation: 7,
                after: CameraAuthorizationPollingPolicy.maximumDuration
            )
        ])
        #expect(policy.handle(
            .explicitPermissionRequest(generation: 7)
        ).isEmpty)
        #expect(policy.handle(
            .pollDeadlineReached(generation: 7, poll: 1)
        ) == [
            .requestAuthorizationStatus(generation: 7, poll: 1)
        ])
        #expect(policy.handle(
            .authorizationStatusReceived(
                generation: 7,
                poll: 1,
                status: .notDetermined
            )
        ) == [
            .scheduleStatusPoll(
                generation: 7,
                poll: 2,
                after: CameraAuthorizationPollingPolicy.pollInterval
            )
        ])
    }

    @Test("authorized denied and restricted statuses finish and fence later callbacks", arguments: [
        (CameraAgentAuthorization.authorized, CameraAuthorizationPollingResult.authorized),
        (.denied, .denied),
        (.restricted, .restricted)
    ])
    func terminalStatusStopsPolling(
        status: CameraAgentAuthorization,
        result: CameraAuthorizationPollingResult
    ) {
        var policy = CameraAuthorizationPollingPolicy()
        _ = policy.handle(.explicitPermissionRequest(generation: 9))
        _ = policy.handle(.pollDeadlineReached(generation: 9, poll: 1))

        #expect(policy.handle(
            .authorizationStatusReceived(
                generation: 9,
                poll: 1,
                status: status
            )
        ) == [.completed(generation: 9, result: result)])
        #expect(policy.handle(
            .pollDeadlineReached(generation: 9, poll: 1)
        ).isEmpty)
        #expect(policy.handle(
            .timeoutDeadlineReached(generation: 9)
        ).isEmpty)
    }

    @Test("a finite overall deadline stops a hung authorization poll")
    func overallTimeoutIsFinite() {
        var policy = CameraAuthorizationPollingPolicy()
        _ = policy.handle(.explicitPermissionRequest(generation: 11))
        _ = policy.handle(.pollDeadlineReached(generation: 11, poll: 1))

        #expect(policy.handle(
            .timeoutDeadlineReached(generation: 11)
        ) == [.completed(generation: 11, result: .timedOut)])
        #expect(policy.handle(
            .authorizationStatusReceived(
                generation: 11,
                poll: 1,
                status: .authorized
            )
        ).isEmpty)
    }

    @Test("the finite poll budget also stops repeated not-determined replies")
    func maximumPollCountIsFinite() {
        var policy = CameraAuthorizationPollingPolicy()
        let generation: UInt64 = 13
        _ = policy.handle(.explicitPermissionRequest(generation: generation))

        for poll in 1...CameraAuthorizationPollingPolicy.maximumPollCount {
            #expect(policy.handle(
                .pollDeadlineReached(generation: generation, poll: poll)
            ) == [
                .requestAuthorizationStatus(generation: generation, poll: poll)
            ])
            let actions = policy.handle(
                .authorizationStatusReceived(
                    generation: generation,
                    poll: poll,
                    status: .notDetermined
                )
            )
            if poll == CameraAuthorizationPollingPolicy.maximumPollCount {
                #expect(actions == [
                    .completed(generation: generation, result: .timedOut)
                ])
            } else {
                #expect(actions == [
                    .scheduleStatusPoll(
                        generation: generation,
                        poll: poll + 1,
                        after: CameraAuthorizationPollingPolicy.pollInterval
                    )
                ])
            }
        }
    }

    @Test("old generations and stale poll replies and deadlines are ignored")
    func generationAndPollFencing() {
        var policy = CameraAuthorizationPollingPolicy()
        _ = policy.handle(.explicitPermissionRequest(generation: 20))
        _ = policy.handle(.pollDeadlineReached(generation: 20, poll: 1))
        _ = policy.handle(.authorizationStatusReceived(
            generation: 20,
            poll: 1,
            status: .notDetermined
        ))

        #expect(policy.handle(
            .pollDeadlineReached(generation: 20, poll: 1)
        ).isEmpty)
        #expect(policy.handle(
            .authorizationStatusReceived(
                generation: 20,
                poll: 1,
                status: .authorized
            )
        ).isEmpty)

        #expect(policy.handle(
            .explicitPermissionRequest(generation: 21)
        ).count == 2)
        #expect(policy.handle(
            .pollDeadlineReached(generation: 20, poll: 2)
        ).isEmpty)
        #expect(policy.handle(
            .authorizationStatusReceived(
                generation: 20,
                poll: 2,
                status: .authorized
            )
        ).isEmpty)
        #expect(policy.handle(
            .timeoutDeadlineReached(generation: 20)
        ).isEmpty)
        #expect(policy.handle(
            .explicitPermissionRequest(generation: 19)
        ).isEmpty)
    }
}

private final class ControlClientHarness {
    let configuration: CameraAgentXPCClientConfiguration
    let transport = RecordingControlXPCTransport()
    let remote = RecordingControlCameraRemote()
    let scheduler = ManualControlScheduler()
    let client: CameraAgentControlClient

    init() throws {
        configuration = try #require(CameraAgentXPCClientConfiguration(
            machServiceName: CameraAgentXPCClientConfiguration.releaseMachServiceName,
            expectedTeamIdentifier: "3524374A2S"
        ))
        transport.remote = remote
        let transport = transport
        client = CameraAgentControlClient(
            configuration: configuration,
            connectionFactory: { serviceName in
                #expect(serviceName == CameraAgentXPCClientConfiguration.releaseMachServiceName)
                return transport
            },
            scheduler: scheduler,
            requestTimeout: 2
        )
    }
}

private final class ManualControlScheduler:
    CameraLeaseScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var tasks: [ManualControlScheduledTask] = []

    var now: TimeInterval { 0 }

    var scheduledDelays: [TimeInterval] {
        lock.withLock { tasks.map(\.delay) }
    }

    var cancelledTaskCount: Int {
        lock.withLock { tasks.filter(\.isCancelled).count }
    }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraLeaseScheduledTask {
        let task = ManualControlScheduledTask(
            delay: delay,
            operation: operation
        )
        lock.withLock { tasks.append(task) }
        return task
    }

    func fireAll() {
        let scheduledTasks = lock.withLock { self.tasks }
        for task in scheduledTasks {
            task.fire()
        }
    }

    func fire(at index: Int) {
        let task = lock.withLock { tasks[index] }
        task.fire()
    }
}

private final class ManualControlScheduledTask:
    CameraLeaseScheduledTask,
    @unchecked Sendable
{
    let delay: TimeInterval

    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?

    init(
        delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) {
        self.delay = delay
        self.operation = operation
    }

    var isCancelled: Bool {
        lock.withLock { operation == nil }
    }

    func cancel() {
        lock.withLock { operation = nil }
    }

    func fire() {
        let pendingOperation = lock.withLock {
            let currentOperation = self.operation
            self.operation = nil
            return currentOperation
        }
        pendingOperation?()
    }
}

private final class RecordingControlXPCTransport:
    CameraAgentXPCConnectionTransport,
    @unchecked Sendable
{
    enum Event: Equatable {
        case codeSigningRequirement(String)
        case remoteInterface(String)
        case interruptionHandler
        case invalidationHandler
        case activated
        case invalidated
    }

    var events: [Event] = []
    var processIdentifier: Int32 = 0
    var remote: RecordingControlCameraRemote?
    var shouldFailProxyRequest = false
    private(set) var proxyRequestCount = 0

    func setCodeSigningRequirement(_ requirement: String) {
        events.append(.codeSigningRequirement(requirement))
    }

    var remoteObjectInterface: NSXPCInterface? {
        didSet {
            if let remoteObjectInterface {
                events.append(.remoteInterface(
                    NSStringFromProtocol(remoteObjectInterface.protocol)
                ))
            }
        }
    }

    var interruptionHandler: (() -> Void)? {
        didSet {
            if interruptionHandler != nil { events.append(.interruptionHandler) }
        }
    }

    var invalidationHandler: (() -> Void)? {
        didSet {
            if invalidationHandler != nil { events.append(.invalidationHandler) }
        }
    }

    func activate() {
        events.append(.activated)
    }

    func invalidate() {
        events.append(.invalidated)
    }

    func remoteCameraProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> (any IdleScreenCameraXPCProtocol)? {
        proxyRequestCount += 1
        if shouldFailProxyRequest {
            shouldFailProxyRequest = false
            errorHandler(ControlClientTestError.proxyUnavailable)
            return nil
        }
        return remote
    }

    func failNextProxyRequest() {
        shouldFailProxyRequest = true
    }
}

private func makeControlAgentIdentity(
    processIdentifier: Int32 = 4_242
) -> IdleScreenCameraAgentIdentity? {
    IdleScreenCameraAgentIdentity(
        processIdentifier: processIdentifier,
        processIncarnationEpoch: 70_001,
        bundleIdentifier: "com.idlescreen.camera-agent",
        serviceIdentifier: "group.com.idlescreen.shared.camera-agent",
        bundleVersion: "1",
        marketingVersion: "0.1",
        signingIdentifier: "com.idlescreen.camera-agent",
        teamIdentifier: "3524374A2S",
        codeDirectoryHash: String(repeating: "1", count: 40),
        executableSHA256: String(repeating: "a", count: 64),
        launchAgentSHA256: String(repeating: "b", count: 64),
        provisioningProfileSHA256: String(repeating: "c", count: 64),
        sourceAppPath: "/Applications/idlescreen.app"
    )
}

private enum ControlClientTestError: Error {
    case proxyUnavailable
}

private final class LockedControlClientEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CameraAgentControlConnectionEvent] = []

    var values: [CameraAgentControlConnectionEvent] {
        lock.withLock { storage }
    }

    func append(_ event: CameraAgentControlConnectionEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class LockedControlValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}

private final class WeakControlClientObject {
    weak var value: AnyObject?

    init(_ value: AnyObject?) {
        self.value = value
    }
}

private final class RecordingControlCameraRemote: NSObject,
    IdleScreenCameraXPCProtocol,
    @unchecked Sendable
{
    var statusRequests: [IdleScreenCameraStatusRequest] = []
    var authorizationRequests: [IdleScreenCameraAuthorizationRequest] = []
    var diagnosticRequests: [IdleScreenCameraDiagnosticRequest] = []
    var beginRequestCount = 0
    var statusReply: IdleScreenCameraAuthorizationReply?
    var authorizationReply: IdleScreenCameraAuthorizationReply?
    var diagnosticReply: IdleScreenCameraDiagnosticSnapshot?
    var respondsImmediately = true
    var pendingStatusReplies: [(IdleScreenCameraAuthorizationReply) -> Void] = []
    var pendingAuthorizationReplies: [(IdleScreenCameraAuthorizationReply) -> Void] = []
    var pendingDiagnosticReplies: [(IdleScreenCameraDiagnosticSnapshot) -> Void] = []

    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        statusRequests.append(request)
        pendingStatusReplies.append(reply)
        if respondsImmediately, let statusReply { reply(statusReply) }
    }

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        authorizationRequests.append(request)
        pendingAuthorizationReplies.append(reply)
        if respondsImmediately, let authorizationReply { reply(authorizationReply) }
    }

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        withReply reply: @escaping (IdleScreenCameraDiagnosticSnapshot) -> Void
    ) {
        diagnosticRequests.append(request)
        pendingDiagnosticReplies.append(reply)
        if respondsImmediately, let diagnosticReply { reply(diagnosticReply) }
    }

    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraDeviceSnapshotReply) -> Void
    ) {
        _ = request
        _ = reply
    }

    func replyToAllPendingRequests() {
        let statusReplies = pendingStatusReplies
        let authorizationReplies = pendingAuthorizationReplies
        let diagnosticReplies = pendingDiagnosticReplies
        pendingStatusReplies.removeAll()
        pendingAuthorizationReplies.removeAll()
        pendingDiagnosticReplies.removeAll()

        if let statusReply {
            statusReplies.forEach { $0(statusReply) }
        }
        if let authorizationReply {
            authorizationReplies.forEach { $0(authorizationReply) }
        }
        if let diagnosticReply {
            diagnosticReplies.forEach { $0(diagnosticReply) }
        }
    }

    func replyToNextStatusRequest() {
        guard !pendingStatusReplies.isEmpty, let statusReply else { return }
        let reply = pendingStatusReplies.removeFirst()
        reply(statusReply)
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        withReply reply: @escaping (IdleScreenCameraBeginStreamReply) -> Void
    ) {
        beginRequestCount += 1
    }

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        withReply reply: @escaping (IdleScreenCameraHeartbeatReply) -> Void
    ) {}

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        withReply reply: @escaping (IdleScreenCameraEndStreamReply) -> Void
    ) {}
}
