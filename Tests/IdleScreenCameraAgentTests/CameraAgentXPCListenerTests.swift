import Foundation
import IdleScreenCamera
import Testing
@testable import IdleScreenCameraAgentCore

@Suite("Camera agent XPC listener")
struct CameraAgentXPCListenerTests {
    @Test("diagnostic log namespace is stable for physical evidence capture")
    func stableDiagnosticLogNamespace() {
        #expect(CameraAgentDiagnosticLog.subsystem == "com.idlescreen.camera-agent")
        #expect(CameraAgentDiagnosticLog.identityCategory == "identity")
        #expect(CameraAgentDiagnosticLog.lifecycleCategory == "lifecycle")
    }

    @Test("each signing configuration admits only its matching product clients")
    func exactSigningRequirement() throws {
        let release = try #require(CameraAgentXPCListenerConfiguration(
            machServiceName: "group.com.idlescreen.shared.camera-agent",
            expectedTeamIdentifier: "3524374A2S"
        ))
        let debug = try #require(CameraAgentXPCListenerConfiguration(
            machServiceName: "group.com.idlescreen.dev.shared.camera-agent",
            expectedTeamIdentifier: "3524374A2S"
        ))

        #expect(release.codeSigningRequirement == "anchor apple generic and certificate leaf[subject.OU] = \"3524374A2S\" and (identifier \"com.idlescreen.app\" or identifier \"com.idlescreen.app.screensaver\")")
        #expect(release.allowedBundleIdentifiers == [
            "com.idlescreen.app",
            "com.idlescreen.app.screensaver",
        ])
        #expect(debug.codeSigningRequirement == "anchor apple generic and certificate leaf[subject.OU] = \"3524374A2S\" and (identifier \"com.idlescreen.app.dev\" or identifier \"com.idlescreen.app.dev.screensaver\")")
        #expect(debug.allowedBundleIdentifiers == [
            "com.idlescreen.app.dev",
            "com.idlescreen.app.dev.screensaver",
        ])
    }

    @Test("malformed signing inputs fail closed before Foundation sees a requirement")
    func malformedSigningConfiguration() {
        #expect(CameraAgentXPCListenerConfiguration(
            machServiceName: "group.com.idlescreen.shared.camera-agent",
            expectedTeamIdentifier: "bad\" or true"
        ) == nil)
        #expect(CameraAgentXPCListenerConfiguration(
            machServiceName: "not-the-advertised-service",
            expectedTeamIdentifier: "3524374A2S"
        ) == nil)
    }

    @Test("the listener installs its signing requirement before activation")
    func signingRequirementPrecedesActivation() throws {
        let harness = try ListenerHarness()

        harness.listener.activate()

        #expect(harness.transport.events == [
            .requirement(harness.configuration.codeSigningRequirement),
            .delegateInstalled,
            .activated,
        ])
    }

    @Test("identity resolution failure rejects without exporting or activating")
    func rejectsIdentityResolutionFailure() throws {
        let harness = try ListenerHarness(
            resolution: .failure(TestIdentityError.unavailable)
        )
        let connection = makeConnection()

        let accepted = harness.listener.listener(
            NSXPCListener.anonymous(),
            shouldAcceptNewConnection: connection
        )

        #expect(!accepted)
        #expect(connection.exportedObject == nil)
        #expect(connection.exportedInterface == nil)
        #expect(harness.activatedConnections.isEmpty)
        #expect(harness.diagnostics.events == [
            .peerIdentityResolutionRejected(
                processIdentifier: connection.processIdentifier,
                reason: .identityUnavailable
            ),
        ])
    }

    @Test("a resolved but unauthorized signed identity is rejected")
    func rejectsUnauthorizedIdentity() throws {
        let harness = try ListenerHarness(resolution: .success(
            CameraAgentAuthenticatedPeer(
                processIdentifier: 55,
                teamIdentifier: "OTHERTEAM1",
                bundleIdentifier: "com.idlescreen.app"
            )
        ))
        let connection = makeConnection()

        let accepted = harness.listener.listener(
            NSXPCListener.anonymous(),
            shouldAcceptNewConnection: connection
        )

        #expect(!accepted)
        #expect(connection.exportedObject == nil)
        #expect(harness.activatedConnections.isEmpty)
        #expect(harness.diagnostics.events == [
            .peerAdmissionRejected(
                peer: CameraAgentDiagnosticPeerIdentity(
                    processIdentifier: 55,
                    teamIdentifier: "OTHERTEAM1",
                    bundleIdentifier: "com.idlescreen.app",
                    role: .companion
                ),
                reason: .policy
            ),
        ])
    }

    @Test("admission and invalidation record exact authenticated peer metadata once")
    func recordsAuthenticatedPeerLifecycle() throws {
        let harness = try ListenerHarness()
        let connection = makeConnection()

        #expect(harness.accept(connection))
        connection.invalidationHandler?()
        connection.invalidationHandler?()

        let peer = CameraAgentDiagnosticPeerIdentity(
            processIdentifier: 55,
            teamIdentifier: "3524374A2S",
            bundleIdentifier: "com.idlescreen.app.screensaver",
            role: .screenSaver
        )
        #expect(harness.diagnostics.events == [
            .peerAdmissionAccepted(
                connectionIdentifier: "connection-00000000-0000-0000-0000-000000000055-1",
                peer: peer
            ),
            .connectionInvalidated(
                connectionIdentifier: "connection-00000000-0000-0000-0000-000000000055-1",
                peer: peer
            ),
        ])
    }

    @Test("an accepted connection gets the exact XPC interface and its own exported object")
    func configuresExactInterfacePerConnection() throws {
        let harness = try ListenerHarness()
        let first = makeConnection()
        let second = makeConnection()

        #expect(harness.accept(first))
        #expect(harness.accept(second))

        let firstObject = try #require(first.exportedObject as? NSObject)
        let secondObject = try #require(second.exportedObject as? NSObject)
        #expect(firstObject !== secondObject)
        #expect(NSStringFromProtocol(try #require(first.exportedInterface).protocol) == "IdleScreenCameraXPCProtocol")
        #expect(NSStringFromProtocol(try #require(second.exportedInterface).protocol) == "IdleScreenCameraXPCProtocol")
        #expect(harness.activatedConnections.count == 2)
    }

    @Test("stream DTOs are forwarded exactly on the serialized executor")
    func forwardsStreamDTOs() throws {
        let harness = try ListenerHarness()
        let connection = makeConnection()
        #expect(harness.accept(connection))
        let endpoint = try #require(connection.exportedObject as? IdleScreenCameraXPCProtocol)
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 1_111,
            maximumHeight: 777,
            maximumFramesPerSecond: 27,
            mailboxSlotCount: 2
        ))
        var beginReply: IdleScreenCameraBeginStreamReply?

        endpoint.beginStream(request) { beginReply = $0 }

        let configuration = try #require(harness.driver.invocations.first {
            if case .configureCapture = $0.action { return true }
            return false
        }?.configuration)
        #expect(configuration == CameraAgentStreamConfiguration(
            maximumWidth: 1_111,
            maximumHeight: 777,
            maximumFramesPerSecond: 27,
            mailboxSlotCount: 2
        ))
        let leaseIdentifier = try #require(beginReply?.leaseIdentifier)
        let heartbeatRequest = try #require(IdleScreenCameraHeartbeatRequest(
            leaseIdentifier: leaseIdentifier
        ))
        var heartbeatReply: IdleScreenCameraHeartbeatReply?

        endpoint.heartbeat(heartbeatRequest) { heartbeatReply = $0 }

        let endRequest = try #require(IdleScreenCameraEndStreamRequest(
            leaseIdentifier: leaseIdentifier
        ))
        var endReply: IdleScreenCameraEndStreamReply?

        endpoint.endStream(endRequest) { endReply = $0 }

        #expect(beginReply?.accepted == true)
        #expect(heartbeatReply?.accepted == true)
        #expect(endReply?.accepted == true)
        #expect(harness.executor.executedOperationCount == 3)
    }

    @Test("only a companion connection reaches the explicit permission path")
    func forwardsPermissionPath() throws {
        let harness = try ListenerHarness(
            authorization: .notDetermined,
            resolution: .success(CameraAgentAuthenticatedPeer(
                processIdentifier: 55,
                teamIdentifier: "3524374A2S",
                bundleIdentifier: "com.idlescreen.app"
            ))
        )
        let connection = makeConnection()
        #expect(harness.accept(connection))
        let endpoint = try #require(connection.exportedObject as? IdleScreenCameraXPCProtocol)
        let request = try #require(IdleScreenCameraAuthorizationRequest())
        var reply: IdleScreenCameraAuthorizationReply?

        endpoint.requestAuthorization(request) { reply = $0 }

        #expect(reply?.accepted == true)
        #expect(harness.driver.invocations.contains {
            if case .requestPermission = $0.action { return true }
            return false
        })
        #expect(harness.executor.executedOperationCount == 1)
    }

    @Test("connection invalidation reclaims only that connection and is idempotent")
    func invalidationIsConnectionScoped() throws {
        let harness = try ListenerHarness()
        let firstConnection = makeConnection()
        let secondConnection = makeConnection()
        #expect(harness.accept(firstConnection))
        #expect(harness.accept(secondConnection))
        let first = try #require(firstConnection.exportedObject as? IdleScreenCameraXPCProtocol)
        let second = try #require(secondConnection.exportedObject as? IdleScreenCameraXPCProtocol)
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        first.beginStream(request) { _ in }
        second.beginStream(request) { _ in }

        firstConnection.invalidationHandler?()
        firstConnection.invalidationHandler?()

        var remainingSnapshot: IdleScreenCameraDiagnosticSnapshot?
        let diagnosticRequest = try #require(IdleScreenCameraDiagnosticRequest())
        second.diagnosticSnapshot(diagnosticRequest) { remainingSnapshot = $0 }
        #expect(remainingSnapshot?.activeLeaseCount == 1)
        #expect(stopActionCount(harness.driver.invocations) == 0)

        secondConnection.invalidationHandler?()
        #expect(stopActionCount(harness.driver.invocations) == 1)
    }
}

private enum TestIdentityError: Error {
    case unavailable
}

private final class ListenerHarness {
    let configuration: CameraAgentXPCListenerConfiguration
    let transport = RecordingListenerTransport()
    let executor = SynchronousCameraAgentExecutor()
    let driver = ListenerTestDriver()
    let activatedConnections = LockedConnections()
    let diagnostics = RecordingCameraAgentDiagnosticSink()
    let listener: CameraAgentXPCListener

    init(
        authorization: CameraAgentAuthorization = .authorized,
        resolution: Result<CameraAgentAuthenticatedPeer, Error> = .success(
            CameraAgentAuthenticatedPeer(
                processIdentifier: 55,
                teamIdentifier: "3524374A2S",
                bundleIdentifier: "com.idlescreen.app.screensaver"
            )
        )
    ) throws {
        configuration = try #require(CameraAgentXPCListenerConfiguration(
            machServiceName: "group.com.idlescreen.shared.camera-agent",
            expectedTeamIdentifier: "3524374A2S"
        ))
        let policy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "3524374A2S",
            companionBundleIdentifiers: ["com.idlescreen.app", "com.idlescreen.app.dev"],
            screenSaverBundleIdentifiers: [
                "com.idlescreen.app.screensaver",
                "com.idlescreen.app.dev.screensaver",
            ]
        ))
        let limits = try #require(CameraAgentCaptureLimits(
            maximumWidth: IdleScreenCameraWire.maximumWidth,
            maximumHeight: IdleScreenCameraWire.maximumHeight,
            maximumFramesPerSecond: IdleScreenCameraWire.maximumFramesPerSecond,
            maximumMailboxSlotCount: IdleScreenCameraWire.maximumMailboxSlotCount
        ))
        let service = try #require(CameraAgentService(
            peerPolicy: policy,
            captureLimits: limits,
            leaseTimeToLive: 5,
            initialAuthorization: authorization,
            agentIdentity: makeTestAgentIdentity()!,
            clock: { Date(timeIntervalSince1970: 10) },
            identifierGenerator: { UUID(uuidString: "00000000-0000-0000-0000-000000000055")! },
            driver: driver
        ))
        let resolver = StubIdentityResolver(result: resolution)
        let connections = activatedConnections
        listener = CameraAgentXPCListener(
            listenerTransport: transport,
            configuration: configuration,
            service: service,
            identityResolver: resolver,
            executor: executor,
            diagnosticSink: diagnostics,
            connectionActivator: { connections.append($0) }
        )
    }

    func accept(_ connection: NSXPCConnection) -> Bool {
        listener.listener(
            NSXPCListener.anonymous(),
            shouldAcceptNewConnection: connection
        )
    }
}

private final class RecordingCameraAgentDiagnosticSink: CameraAgentDiagnosticEventSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [CameraAgentDiagnosticEvent] = []

    var events: [CameraAgentDiagnosticEvent] {
        lock.withLock { storage }
    }

    func record(_ event: CameraAgentDiagnosticEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class RecordingListenerTransport: CameraAgentXPCListenerTransport {
    enum Event: Equatable {
        case requirement(String)
        case delegateInstalled
        case activated
        case invalidated
    }

    var events: [Event] = []
    var delegate: (any NSXPCListenerDelegate)? {
        didSet {
            if delegate != nil { events.append(.delegateInstalled) }
        }
    }

    func setConnectionCodeSigningRequirement(_ requirement: String) {
        events.append(.requirement(requirement))
    }

    func activate() {
        events.append(.activated)
    }

    func invalidate() {
        events.append(.invalidated)
    }
}

private final class StubIdentityResolver: CameraAgentPeerIdentityResolving, @unchecked Sendable {
    private let result: Result<CameraAgentAuthenticatedPeer, Error>

    init(result: Result<CameraAgentAuthenticatedPeer, Error>) {
        self.result = result
    }

    func authenticatedPeer(for connection: NSXPCConnection) throws -> CameraAgentAuthenticatedPeer {
        _ = connection
        return try result.get()
    }
}

private final class SynchronousCameraAgentExecutor: CameraAgentSerialExecuting, @unchecked Sendable {
    private(set) var executedOperationCount = 0

    func execute(_ operation: @escaping @Sendable () -> Void) {
        executedOperationCount += 1
        operation()
    }
}

private final class ListenerTestDriver: CameraAgentServiceDriver, @unchecked Sendable {
    struct Invocation {
        let action: CameraAgentAction
        let configuration: CameraAgentStreamConfiguration?
    }

    private(set) var invocations: [Invocation] = []

    func transportIdentifier(for configuration: CameraAgentStreamConfiguration) -> String? {
        _ = configuration
        return "camera/frame-mailbox.bin"
    }

    func perform(
        _ action: CameraAgentAction,
        configuration: CameraAgentStreamConfiguration?
    ) {
        invocations.append(Invocation(action: action, configuration: configuration))
    }
}

private final class LockedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NSXPCConnection] = []

    var count: Int {
        lock.withLock { storage.count }
    }

    var isEmpty: Bool {
        count == 0
    }

    func append(_ connection: NSXPCConnection) {
        lock.withLock { storage.append(connection) }
    }
}

private func makeConnection() -> NSXPCConnection {
    NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
}

private func stopActionCount(_ invocations: [ListenerTestDriver.Invocation]) -> Int {
    invocations.filter {
        if case .stopCapture = $0.action { return true }
        return false
    }.count
}
