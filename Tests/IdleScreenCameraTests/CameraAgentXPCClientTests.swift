import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera agent XPC client")
struct CameraAgentXPCClientTests {
    @Test("configuration binds each advertised service to its exact signed agent")
    func validatesSigningConfiguration() throws {
        let release = try #require(CameraAgentXPCClientConfiguration(
            machServiceName: "group.com.idlescreen.shared.camera-agent",
            expectedTeamIdentifier: "3524374A2S"
        ))
        let debug = try #require(CameraAgentXPCClientConfiguration(
            machServiceName: "group.com.idlescreen.dev.shared.camera-agent",
            expectedTeamIdentifier: "3524374A2S"
        ))

        #expect(release.codeSigningRequirement == "anchor apple generic and certificate leaf[subject.OU] = \"3524374A2S\" and identifier \"com.idlescreen.camera-agent\"")
        #expect(debug.codeSigningRequirement == "anchor apple generic and certificate leaf[subject.OU] = \"3524374A2S\" and identifier \"com.idlescreen.camera-agent.dev\"")
        #expect(CameraAgentXPCClientConfiguration(
            machServiceName: "com.example.untrusted",
            expectedTeamIdentifier: "3524374A2S"
        ) == nil)
        #expect(CameraAgentXPCClientConfiguration(
            machServiceName: "group.com.idlescreen.shared.camera-agent",
            expectedTeamIdentifier: "bad\" or true"
        ) == nil)
    }

    @Test("connection installs the exact remote interface before activation")
    func configuresInterfaceBeforeActivation() throws {
        let harness = try XPCClientHarness()

        _ = harness.client.connect(attempt: 7) { _ in }

        #expect(harness.transport.events == [
            .codeSigningRequirement(harness.configuration.codeSigningRequirement),
            .remoteInterface("IdleScreenCameraXPCProtocol"),
            .interruptionHandler,
            .invalidationHandler,
            .activated,
        ])
    }

    @Test("connection events are fenced with the originating attempt")
    func forwardsConnectionEvents() throws {
        let harness = try XPCClientHarness()
        let events = LockedClientEvents()
        let session = harness.client.connect(attempt: 7) { events.append($0) }

        harness.transport.interruptionHandler?()
        harness.transport.invalidationHandler?()
        harness.transport.failNextProxyRequest()
        session.beginStream(try #require(beginRequest())) { _ in }

        #expect(events.values == [
            .interrupted(attempt: 7),
            .invalidated(attempt: 7),
            .requestFailed(attempt: 7),
        ])
    }

    @Test("wire DTOs are forwarded unchanged to the exact remote protocol")
    func forwardsDTOsUnchanged() throws {
        let harness = try XPCClientHarness()
        let session = harness.client.connect(attempt: 3) { _ in }
        let begin = try #require(beginRequest())
        let heartbeat = try #require(IdleScreenCameraHeartbeatRequest(
            leaseIdentifier: "lease_test-3"
        ))
        let end = try #require(IdleScreenCameraEndStreamRequest(
            leaseIdentifier: "lease_test-3"
        ))

        session.beginStream(begin) { _ in }
        session.heartbeat(heartbeat) { _ in }
        session.endStream(end) { _ in }

        #expect(harness.remote.beginRequests.count == 1)
        #expect(harness.remote.beginRequests[0] === begin)
        #expect(harness.remote.heartbeatRequests.count == 1)
        #expect(harness.remote.heartbeatRequests[0] === heartbeat)
        #expect(harness.remote.endRequests.count == 1)
        #expect(harness.remote.endRequests[0] === end)
    }

    @Test("connection handlers do not retain a released client session")
    func handlersDoNotRetainSession() throws {
        let harness = try XPCClientHarness()
        var session: (any CameraAgentClientSession)? = harness.client.connect(attempt: 1) { _ in }
        let weakSession = WeakClientObject(session as AnyObject)

        session = nil

        #expect(weakSession.value == nil)
    }
}

private final class XPCClientHarness {
    let configuration: CameraAgentXPCClientConfiguration
    let transport = RecordingXPCConnectionTransport()
    let remote = RecordingCameraRemote()
    let client: CameraAgentXPCClient

    init() throws {
        configuration = try #require(CameraAgentXPCClientConfiguration(
            machServiceName: "group.com.idlescreen.shared.camera-agent",
            expectedTeamIdentifier: "3524374A2S"
        ))
        transport.remote = remote
        let transport = transport
        client = CameraAgentXPCClient(
            configuration: configuration,
            connectionFactory: { serviceName in
                #expect(serviceName == "group.com.idlescreen.shared.camera-agent")
                return transport
            }
        )
    }
}

private final class RecordingXPCConnectionTransport: CameraAgentXPCConnectionTransport,
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
    var remote: RecordingCameraRemote?
    var shouldFailProxyRequest = false

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
        if shouldFailProxyRequest {
            shouldFailProxyRequest = false
            errorHandler(TestClientError.proxyUnavailable)
            return nil
        }
        return remote
    }

    func failNextProxyRequest() {
        shouldFailProxyRequest = true
    }
}

private enum TestClientError: Error {
    case proxyUnavailable
}

private final class LockedClientEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CameraAgentClientConnectionEvent] = []

    var values: [CameraAgentClientConnectionEvent] {
        lock.withLock { storage }
    }

    func append(_ event: CameraAgentClientConnectionEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class WeakClientObject {
    weak var value: AnyObject?

    init(_ value: AnyObject?) {
        self.value = value
    }
}

private final class RecordingCameraRemote: NSObject,
    IdleScreenCameraXPCProtocol,
    @unchecked Sendable
{
    var beginRequests: [IdleScreenCameraBeginStreamRequest] = []
    var heartbeatRequests: [IdleScreenCameraHeartbeatRequest] = []
    var endRequests: [IdleScreenCameraEndStreamRequest] = []

    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        _ = request
        reply(IdleScreenCameraAuthorizationReply(
            accepted: true,
            status: .authorized,
            errorCode: .none,
            errorMessage: nil
        )!)
    }

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        _ = request
        reply(IdleScreenCameraAuthorizationReply(
            accepted: false,
            status: .authorized,
            errorCode: .notAuthorized,
            errorMessage: "Not available to this client"
        )!)
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        withReply reply: @escaping (IdleScreenCameraBeginStreamReply) -> Void
    ) {
        beginRequests.append(request)
        reply(IdleScreenCameraBeginStreamReply(
            accepted: true,
            errorCode: .none,
            errorMessage: nil,
            leaseIdentifier: "lease_test-3",
            producerStreamEpoch: 8,
            transportIdentifier: "camera/frame-mailbox.bin"
        )!)
    }

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        withReply reply: @escaping (IdleScreenCameraHeartbeatReply) -> Void
    ) {
        heartbeatRequests.append(request)
        reply(IdleScreenCameraHeartbeatReply(
            accepted: true,
            errorCode: .none,
            errorMessage: nil
        )!)
    }

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        withReply reply: @escaping (IdleScreenCameraEndStreamReply) -> Void
    ) {
        endRequests.append(request)
        reply(IdleScreenCameraEndStreamReply(
            accepted: true,
            errorCode: .none,
            errorMessage: nil
        )!)
    }

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        withReply reply: @escaping (IdleScreenCameraDiagnosticSnapshot) -> Void
    ) {
        _ = request
        reply(IdleScreenCameraDiagnosticSnapshot(
            accepted: true,
            errorCode: .none,
            errorMessage: nil,
            agentIdentity: makeXPCClientAgentIdentity(),
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "idle"
        )!)
    }

    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraDeviceSnapshotReply) -> Void
    ) {
        _ = request
        _ = reply
    }
}

private func makeXPCClientAgentIdentity() -> IdleScreenCameraAgentIdentity? {
    IdleScreenCameraAgentIdentity(
        processIdentifier: 4_242,
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

private func beginRequest() -> IdleScreenCameraBeginStreamRequest? {
    IdleScreenCameraBeginStreamRequest(
        maximumWidth: 640,
        maximumHeight: 480,
        maximumFramesPerSecond: 30,
        mailboxSlotCount: 2
    )
}
