import Foundation
import IdleScreenCamera
import Security

/// Fail-closed listener inputs. Client bundle identifiers are not configurable:
/// they are the four signed products built by this repository.
public struct CameraAgentXPCListenerConfiguration: Equatable, Sendable {
    public static let releaseMachServiceName = "group.com.idlescreen.shared.camera-agent"
    public static let debugMachServiceName = "group.com.idlescreen.dev.shared.camera-agent"

    public static let releaseCompanionBundleIdentifier = "com.idlescreen.app"
    public static let debugCompanionBundleIdentifier = "com.idlescreen.app.dev"
    public static let releaseScreenSaverBundleIdentifier = "com.idlescreen.app.screensaver"
    public static let debugScreenSaverBundleIdentifier = "com.idlescreen.app.dev.screensaver"

    public let machServiceName: String
    public let expectedTeamIdentifier: String
    public let companionBundleIdentifier: String
    public let screenSaverBundleIdentifier: String
    public let allowedBundleIdentifiers: [String]
    public let codeSigningRequirement: String

    public init?(
        machServiceName: String,
        expectedTeamIdentifier: String
    ) {
        guard Self.isValidTeamIdentifier(expectedTeamIdentifier) else {
            return nil
        }

        let companionBundleIdentifier: String
        let screenSaverBundleIdentifier: String
        switch machServiceName {
        case Self.releaseMachServiceName:
            companionBundleIdentifier = Self.releaseCompanionBundleIdentifier
            screenSaverBundleIdentifier = Self.releaseScreenSaverBundleIdentifier
        case Self.debugMachServiceName:
            companionBundleIdentifier = Self.debugCompanionBundleIdentifier
            screenSaverBundleIdentifier = Self.debugScreenSaverBundleIdentifier
        default:
            return nil
        }
        let bundleIdentifiers = [
            companionBundleIdentifier,
            screenSaverBundleIdentifier,
        ]
        let identifierClause = bundleIdentifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")

        self.machServiceName = machServiceName
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.companionBundleIdentifier = companionBundleIdentifier
        self.screenSaverBundleIdentifier = screenSaverBundleIdentifier
        allowedBundleIdentifiers = bundleIdentifiers
        codeSigningRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\" and (\(identifierClause))"
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
        }
    }
}

public enum CameraAgentPeerIdentityResolutionError: Error, Equatable, Sendable {
    case invalidProcessIdentifier
    case wrongUser
    case liveCodeUnavailable(OSStatus)
    case invalidLiveCode(OSStatus)
    case staticCodeUnavailable(OSStatus)
    case signingInformationUnavailable(OSStatus)
    case missingSigningIdentity
}

protocol CameraAgentPeerIdentityResolving: AnyObject, Sendable {
    func authenticatedPeer(for connection: NSXPCConnection) throws -> CameraAgentAuthenticatedPeer
}

/// Resolves the process that is live at the PID supplied by Foundation and
/// extracts its signing identity from Security.framework. The listener's code
/// signing requirement remains the primary admission gate.
///
/// Foundation does not publicly expose an NSXPCConnection audit token. This
/// resolver therefore uses its public PID and effective UID after the listener
/// has enforced the exact Team ID and bundle-identifier requirement.
final class CameraAgentLivePeerIdentityResolver: CameraAgentPeerIdentityResolving {
    func authenticatedPeer(for connection: NSXPCConnection) throws -> CameraAgentAuthenticatedPeer {
        let processIdentifier = connection.processIdentifier
        guard processIdentifier > 0 else {
            throw CameraAgentPeerIdentityResolutionError.invalidProcessIdentifier
        }
        guard connection.effectiveUserIdentifier == geteuid() else {
            throw CameraAgentPeerIdentityResolutionError.wrongUser
        }

        var dynamicCode: SecCode?
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: processIdentifier),
        ] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &dynamicCode
        )
        guard guestStatus == errSecSuccess, let dynamicCode else {
            throw CameraAgentPeerIdentityResolutionError.liveCodeUnavailable(guestStatus)
        }

        let validityStatus = SecCodeCheckValidity(dynamicCode, [], nil)
        guard validityStatus == errSecSuccess else {
            throw CameraAgentPeerIdentityResolutionError.invalidLiveCode(validityStatus)
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw CameraAgentPeerIdentityResolutionError.staticCodeUnavailable(staticStatus)
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [CFString: Any],
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
              let bundleIdentifier = information[kSecCodeInfoIdentifier] as? String,
              !teamIdentifier.isEmpty,
              !bundleIdentifier.isEmpty else {
            if informationStatus != errSecSuccess {
                throw CameraAgentPeerIdentityResolutionError.signingInformationUnavailable(
                    informationStatus
                )
            }
            throw CameraAgentPeerIdentityResolutionError.missingSigningIdentity
        }

        return CameraAgentAuthenticatedPeer(
            processIdentifier: processIdentifier,
            teamIdentifier: teamIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }
}

protocol CameraAgentSerialExecuting: AnyObject, Sendable {
    func execute(_ operation: @escaping @Sendable () -> Void)
}

final class CameraAgentDispatchSerialExecutor: CameraAgentSerialExecuting, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String = "com.idlescreen.camera-agent.xpc-core") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func execute(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

protocol CameraAgentXPCListenerTransport: AnyObject {
    var delegate: (any NSXPCListenerDelegate)? { get set }
    func setConnectionCodeSigningRequirement(_ requirement: String)
    func activate()
    func invalidate()
}

extension NSXPCListener: CameraAgentXPCListenerTransport {}

/// Authenticated Mach-service front door for the camera-agent core.
public final class CameraAgentXPCListener: NSObject, NSXPCListenerDelegate {
    private let listenerTransport: any CameraAgentXPCListenerTransport
    private let service: CameraAgentService
    private let configuration: CameraAgentXPCListenerConfiguration
    private let identityResolver: any CameraAgentPeerIdentityResolving
    private let executor: any CameraAgentSerialExecuting
    private let diagnosticSink: any CameraAgentDiagnosticEventSink
    private let connectionActivator: @Sendable (NSXPCConnection) -> Void

    /// Production path. This always constructs a real launchd-advertised Mach
    /// service listener and installs the signing requirement while suspended.
    public convenience init(
        configuration: CameraAgentXPCListenerConfiguration,
        service: CameraAgentService,
        diagnosticSink: any CameraAgentDiagnosticEventSink = CameraAgentOSLogDiagnosticSink.shared
    ) {
        self.init(
            listenerTransport: NSXPCListener(
                machServiceName: configuration.machServiceName
            ),
            configuration: configuration,
            service: service,
            identityResolver: CameraAgentLivePeerIdentityResolver(),
            executor: CameraAgentDispatchSerialExecutor(),
            diagnosticSink: diagnosticSink,
            connectionActivator: { $0.activate() }
        )
    }

    init(
        listenerTransport: any CameraAgentXPCListenerTransport,
        configuration: CameraAgentXPCListenerConfiguration,
        service: CameraAgentService,
        identityResolver: any CameraAgentPeerIdentityResolving,
        executor: any CameraAgentSerialExecuting,
        diagnosticSink: any CameraAgentDiagnosticEventSink,
        connectionActivator: @escaping @Sendable (NSXPCConnection) -> Void
    ) {
        self.listenerTransport = listenerTransport
        self.service = service
        self.configuration = configuration
        self.identityResolver = identityResolver
        self.executor = executor
        self.diagnosticSink = diagnosticSink
        self.connectionActivator = connectionActivator
        super.init()

        // Must precede activation. A malformed caller-supplied requirement can
        // raise an Objective-C exception, so configuration only emits a fixed,
        // locally validated requirement grammar.
        listenerTransport.setConnectionCodeSigningRequirement(
            configuration.codeSigningRequirement
        )
        listenerTransport.delegate = self
    }

    public func activate() {
        listenerTransport.activate()
    }

    public func invalidate() {
        listenerTransport.invalidate()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener

        let peer: CameraAgentAuthenticatedPeer
        do {
            peer = try identityResolver.authenticatedPeer(for: newConnection)
        } catch {
            diagnosticSink.record(.peerIdentityResolutionRejected(
                processIdentifier: newConnection.processIdentifier,
                reason: .identityUnavailable
            ))
            return false
        }

        let connectionService: CameraAgentConnectionService
        do {
            connectionService = try service.admit(peer: peer)
        } catch {
            diagnosticSink.record(.peerAdmissionRejected(
                peer: diagnosticIdentity(
                    peer: peer,
                    role: diagnosticRole(for: peer.bundleIdentifier)
                ),
                reason: diagnosticRejectionReason(for: error)
            ))
            return false
        }

        let diagnosticPeer = diagnosticIdentity(
            peer: peer,
            role: diagnosticRole(for: connectionService.role)
        )
        let diagnosticConnectionIdentifier = connectionService.diagnosticConnectionIdentifier
        diagnosticSink.record(.peerAdmissionAccepted(
            connectionIdentifier: diagnosticConnectionIdentifier,
            peer: diagnosticPeer
        ))

        let exportedObject = CameraAgentXPCConnectionEndpoint(
            connectionService: connectionService,
            executor: executor,
            diagnosticConnectionIdentifier: diagnosticConnectionIdentifier,
            diagnosticPeer: diagnosticPeer,
            diagnosticSink: diagnosticSink
        )
        newConnection.exportedInterface = IdleScreenCameraXPCInterface.make()
        newConnection.exportedObject = exportedObject
        newConnection.invalidationHandler = { [exportedObject] in
            exportedObject.invalidate()
        }
        connectionActivator(newConnection)
        return true
    }

    private func diagnosticRole(
        for bundleIdentifier: String
    ) -> CameraAgentDiagnosticPeerRole {
        if bundleIdentifier == configuration.companionBundleIdentifier {
            return .companion
        }
        if bundleIdentifier == configuration.screenSaverBundleIdentifier {
            return .screenSaver
        }
        return .unrecognized
    }

    private func diagnosticRole(
        for role: CameraAgentPeerRole
    ) -> CameraAgentDiagnosticPeerRole {
        switch role {
        case .companion: .companion
        case .screenSaver: .screenSaver
        }
    }

    private func diagnosticIdentity(
        peer: CameraAgentAuthenticatedPeer,
        role: CameraAgentDiagnosticPeerRole
    ) -> CameraAgentDiagnosticPeerIdentity {
        CameraAgentDiagnosticPeerIdentity(
            processIdentifier: peer.processIdentifier,
            teamIdentifier: peer.teamIdentifier,
            bundleIdentifier: peer.bundleIdentifier,
            role: role
        )
    }

    private func diagnosticRejectionReason(
        for error: any Error
    ) -> CameraAgentDiagnosticIdentityRejectionReason {
        if let error = error as? CameraAgentAdmissionError,
           error == .identifierExhausted {
            return .identifierExhausted
        }
        return .policy
    }
}

private final class CameraAgentXPCConnectionEndpoint: NSObject,
    IdleScreenCameraXPCProtocol,
    @unchecked Sendable
{
    private let connectionService: CameraAgentConnectionService
    private let executor: any CameraAgentSerialExecuting
    private let diagnosticConnectionIdentifier: String
    private let diagnosticPeer: CameraAgentDiagnosticPeerIdentity
    private let diagnosticSink: any CameraAgentDiagnosticEventSink
    private let invalidationLock = NSLock()
    private var invalidationWasScheduled = false

    init(
        connectionService: CameraAgentConnectionService,
        executor: any CameraAgentSerialExecuting,
        diagnosticConnectionIdentifier: String,
        diagnosticPeer: CameraAgentDiagnosticPeerIdentity,
        diagnosticSink: any CameraAgentDiagnosticEventSink
    ) {
        self.connectionService = connectionService
        self.executor = executor
        self.diagnosticConnectionIdentifier = diagnosticConnectionIdentifier
        self.diagnosticPeer = diagnosticPeer
        self.diagnosticSink = diagnosticSink
        super.init()
    }

    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        let reply = CameraAgentReplyBox(reply)
        executor.execute { [connectionService] in
            reply.send(connectionService.authorizationStatus(request))
        }
    }

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        let reply = CameraAgentReplyBox(reply)
        executor.execute { [connectionService] in
            reply.send(connectionService.requestAuthorization(request))
        }
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        withReply reply: @escaping (IdleScreenCameraBeginStreamReply) -> Void
    ) {
        let reply = CameraAgentReplyBox(reply)
        executor.execute { [connectionService] in
            reply.send(connectionService.beginStream(request))
        }
    }

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        withReply reply: @escaping (IdleScreenCameraHeartbeatReply) -> Void
    ) {
        let reply = CameraAgentReplyBox(reply)
        executor.execute { [connectionService] in
            reply.send(connectionService.heartbeat(request))
        }
    }

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        withReply reply: @escaping (IdleScreenCameraEndStreamReply) -> Void
    ) {
        let reply = CameraAgentReplyBox(reply)
        executor.execute { [connectionService] in
            reply.send(connectionService.endStream(request))
        }
    }

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        withReply reply: @escaping (IdleScreenCameraDiagnosticSnapshot) -> Void
    ) {
        let reply = CameraAgentReplyBox(reply)
        executor.execute { [connectionService] in
            reply.send(connectionService.diagnosticSnapshot(request))
        }
    }

    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraDeviceSnapshotReply) -> Void
    ) {
        let reply = CameraAgentReplyBox(reply)
        executor.execute { [connectionService] in
            reply.send(connectionService.cameraDeviceSnapshot(request))
        }
    }

    func invalidate() {
        let shouldSchedule = invalidationLock.withLock {
            guard !invalidationWasScheduled else { return false }
            invalidationWasScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        diagnosticSink.record(.connectionInvalidated(
            connectionIdentifier: diagnosticConnectionIdentifier,
            peer: diagnosticPeer
        ))

        executor.execute { [connectionService] in
            _ = connectionService.invalidate()
        }
    }
}

private final class CameraAgentReplyBox<Value>: @unchecked Sendable {
    private let reply: (Value) -> Void

    init(_ reply: @escaping (Value) -> Void) {
        self.reply = reply
    }

    func send(_ value: Value) {
        reply(value)
    }
}
