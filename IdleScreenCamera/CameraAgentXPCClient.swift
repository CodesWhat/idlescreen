import Foundation

public struct CameraAgentXPCClientConfiguration: Equatable, Sendable {
    public static let releaseMachServiceName = "group.com.idlescreen.shared.camera-agent"
    public static let debugMachServiceName = "group.com.idlescreen.dev.shared.camera-agent"

    public let machServiceName: String
    public let expectedTeamIdentifier: String
    public let remoteAgentBundleIdentifier: String
    public let codeSigningRequirement: String

    public init?(
        machServiceName: String,
        expectedTeamIdentifier: String
    ) {
        let remoteAgentBundleIdentifier: String
        switch machServiceName {
        case Self.releaseMachServiceName:
            remoteAgentBundleIdentifier = "com.idlescreen.camera-agent"
        case Self.debugMachServiceName:
            remoteAgentBundleIdentifier = "com.idlescreen.camera-agent.dev"
        default:
            return nil
        }
        guard Self.isValidTeamIdentifier(expectedTeamIdentifier) else {
            return nil
        }
        self.machServiceName = machServiceName
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.remoteAgentBundleIdentifier = remoteAgentBundleIdentifier
        codeSigningRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\" and identifier \"\(remoteAgentBundleIdentifier)\""
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
        }
    }
}

public enum CameraAgentClientConnectionEvent: Equatable, Sendable {
    case interrupted(attempt: UInt64)
    case invalidated(attempt: UInt64)
    case requestFailed(attempt: UInt64)

    public var attempt: UInt64 {
        switch self {
        case let .interrupted(attempt),
             let .invalidated(attempt),
             let .requestFailed(attempt):
            attempt
        }
    }
}

public protocol CameraAgentClientSession: AnyObject, Sendable {
    var attempt: UInt64 { get }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraBeginStreamReply?) -> Void
    )

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        reply: @escaping @Sendable (IdleScreenCameraHeartbeatReply?) -> Void
    )

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraEndStreamReply?) -> Void
    )

    func invalidate()
}

public protocol CameraAgentClientConnecting: AnyObject, Sendable {
    func connect(
        attempt: UInt64,
        eventHandler: @escaping @Sendable (CameraAgentClientConnectionEvent) -> Void
    ) -> any CameraAgentClientSession
}

protocol CameraAgentXPCConnectionTransport: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var remoteObjectInterface: NSXPCInterface? { get set }
    var interruptionHandler: (() -> Void)? { get set }
    var invalidationHandler: (() -> Void)? { get set }

    func setCodeSigningRequirement(_ requirement: String)
    func activate()
    func invalidate()
    func remoteCameraProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> (any IdleScreenCameraXPCProtocol)?
}

extension CameraAgentXPCConnectionTransport {
    var processIdentifier: Int32 { 0 }
}

extension NSXPCConnection: CameraAgentXPCConnectionTransport {
    func remoteCameraProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> (any IdleScreenCameraXPCProtocol)? {
        remoteObjectProxyWithErrorHandler(errorHandler)
            as? IdleScreenCameraXPCProtocol
    }
}

/// Creates one independently fenced NSXPC connection for each controller
/// attempt. This object does not retain sessions after returning them.
public final class CameraAgentXPCClient: CameraAgentClientConnecting, @unchecked Sendable {
    private let configuration: CameraAgentXPCClientConfiguration
    private let connectionFactory: @Sendable (String) -> any CameraAgentXPCConnectionTransport

    public convenience init(configuration: CameraAgentXPCClientConfiguration) {
        self.init(
            configuration: configuration,
            connectionFactory: { machServiceName in
                NSXPCConnection(machServiceName: machServiceName, options: [])
            }
        )
    }

    init(
        configuration: CameraAgentXPCClientConfiguration,
        connectionFactory: @escaping @Sendable (String) -> any CameraAgentXPCConnectionTransport
    ) {
        self.configuration = configuration
        self.connectionFactory = connectionFactory
    }

    public func connect(
        attempt: UInt64,
        eventHandler: @escaping @Sendable (CameraAgentClientConnectionEvent) -> Void
    ) -> any CameraAgentClientSession {
        let connection = connectionFactory(configuration.machServiceName)
        let session = CameraAgentXPCClientSession(
            attempt: attempt,
            connection: connection,
            codeSigningRequirement: configuration.codeSigningRequirement,
            eventHandler: eventHandler
        )
        session.activate()
        return session
    }
}

private final class CameraAgentXPCClientSession: CameraAgentClientSession,
    @unchecked Sendable
{
    let attempt: UInt64

    private let connection: any CameraAgentXPCConnectionTransport
    private let codeSigningRequirement: String
    private let eventHandler: @Sendable (CameraAgentClientConnectionEvent) -> Void

    init(
        attempt: UInt64,
        connection: any CameraAgentXPCConnectionTransport,
        codeSigningRequirement: String,
        eventHandler: @escaping @Sendable (CameraAgentClientConnectionEvent) -> Void
    ) {
        self.attempt = attempt
        self.connection = connection
        self.codeSigningRequirement = codeSigningRequirement
        self.eventHandler = eventHandler
    }

    func activate() {
        connection.setCodeSigningRequirement(codeSigningRequirement)
        connection.remoteObjectInterface = IdleScreenCameraXPCInterface.make()
        connection.interruptionHandler = { [weak self] in
            guard let self else { return }
            eventHandler(.interrupted(attempt: attempt))
        }
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            eventHandler(.invalidated(attempt: attempt))
        }
        connection.activate()
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraBeginStreamReply?) -> Void
    ) {
        withRemoteProxy(reply: reply) { proxy, reply in
            proxy.beginStream(request) { reply($0) }
        }
    }

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        reply: @escaping @Sendable (IdleScreenCameraHeartbeatReply?) -> Void
    ) {
        withRemoteProxy(reply: reply) { proxy, reply in
            proxy.heartbeat(request) { reply($0) }
        }
    }

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraEndStreamReply?) -> Void
    ) {
        withRemoteProxy(reply: reply) { proxy, reply in
            proxy.endStream(request) { reply($0) }
        }
    }

    func invalidate() {
        connection.invalidate()
    }

    private func withRemoteProxy<Reply: Sendable>(
        reply: @escaping @Sendable (Reply?) -> Void,
        operation: ((any IdleScreenCameraXPCProtocol), @escaping @Sendable (Reply?) -> Void) -> Void
    ) {
        let proxy = connection.remoteCameraProxy { [weak self] _ in
            guard let self else { return }
            eventHandler(.requestFailed(attempt: attempt))
        }
        guard let proxy else {
            reply(nil)
            return
        }
        operation(proxy, reply)
    }
}
