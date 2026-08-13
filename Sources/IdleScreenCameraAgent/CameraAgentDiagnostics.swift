import Foundation
import IdleScreenCamera
import OSLog

/// Stable Unified Logging namespace used by the physical camera decision gate.
public enum CameraAgentDiagnosticLog {
    public static let subsystem = "com.idlescreen.camera-agent"
    public static let identityCategory = "identity"
    public static let lifecycleCategory = "lifecycle"
}

public enum CameraAgentDiagnosticPeerRole: String, Equatable, Sendable {
    case companion
    case screenSaver = "screen-saver"
    case unrecognized
}

/// The only peer fields diagnostics may retain. Connection objects, request
/// objects, and private kernel credentials are deliberately not representable.
public struct CameraAgentDiagnosticPeerIdentity: Equatable, Sendable {
    public let processIdentifier: Int32
    public let teamIdentifier: String
    public let bundleIdentifier: String
    public let role: CameraAgentDiagnosticPeerRole

    public init(
        processIdentifier: Int32,
        teamIdentifier: String,
        bundleIdentifier: String,
        role: CameraAgentDiagnosticPeerRole
    ) {
        self.processIdentifier = processIdentifier
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.role = role
    }
}

public enum CameraAgentDiagnosticIdentityRejectionReason: String, Equatable, Sendable {
    case identityUnavailable = "identity-unavailable"
    case policy
    case identifierExhausted = "identifier-exhausted"
}

public enum CameraAgentDiagnosticAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined = "not-determined"
    case restricted
    case denied
    case authorized
}

public enum CameraAgentDiagnosticAuthorizationSource: String, Equatable, Sendable {
    case startup
    case statusRefresh = "status-refresh"
    case explicitRequestCompletion = "explicit-request-completion"
    case runtimeObservation = "runtime-observation"
}

/// Privacy-safe evidence events. The payload surface is intentionally limited
/// to identity, control-plane counters, generations, epochs, and sequences.
/// Image bytes, request DTOs, rendered content, and content-derived values
/// cannot cross this boundary.
public enum CameraAgentDiagnosticEvent: Equatable, Sendable {
    case authorizationStatus(
        status: CameraAgentDiagnosticAuthorizationStatus,
        source: CameraAgentDiagnosticAuthorizationSource
    )
    case peerIdentityResolutionRejected(
        processIdentifier: Int32,
        reason: CameraAgentDiagnosticIdentityRejectionReason
    )
    case peerAdmissionRejected(
        peer: CameraAgentDiagnosticPeerIdentity,
        reason: CameraAgentDiagnosticIdentityRejectionReason
    )
    case peerAdmissionAccepted(
        connectionIdentifier: String,
        peer: CameraAgentDiagnosticPeerIdentity
    )
    case connectionInvalidated(
        connectionIdentifier: String,
        peer: CameraAgentDiagnosticPeerIdentity
    )

    case leaseCountChanged(
        previous: Int,
        current: Int,
        producerStreamEpoch: UInt64
    )
    case captureStartRequested(generation: UInt64, producerStreamEpoch: UInt64)
    case captureStarted(generation: UInt64, producerStreamEpoch: UInt64)
    case firstFramePublished(
        generation: UInt64,
        producerStreamEpoch: UInt64,
        sequence: UInt64
    )
    case captureStopRequested(generation: UInt64, producerStreamEpoch: UInt64)
    case captureStopped(generation: UInt64, producerStreamEpoch: UInt64)
    case captureInterrupted(generation: UInt64, producerStreamEpoch: UInt64)
    case captureRuntimeError(generation: UInt64, producerStreamEpoch: UInt64)
    case recoveryFailure(
        generation: UInt64,
        producerStreamEpoch: UInt64,
        cause: CameraCaptureRecoveryCause
    )
    case recoveryRetryScheduled(generation: UInt64, producerStreamEpoch: UInt64)
    case recoveryRetryStarted(generation: UInt64, producerStreamEpoch: UInt64)
}

public protocol CameraAgentDiagnosticEventSink: Sendable {
    func record(_ event: CameraAgentDiagnosticEvent)
}

public struct NoopCameraAgentDiagnosticSink: CameraAgentDiagnosticEventSink {
    public static let shared = NoopCameraAgentDiagnosticSink()

    public init() {}

    public func record(_ event: CameraAgentDiagnosticEvent) {
        _ = event
    }
}

/// Production adapter for privacy-safe, predicate-friendly Unified Logging.
/// Every interpolated field is control-plane metadata explicitly marked public
/// so the physical runner can collect it without enabling private log data.
public final class CameraAgentOSLogDiagnosticSink: CameraAgentDiagnosticEventSink,
    @unchecked Sendable
{
    public static let shared = CameraAgentOSLogDiagnosticSink()

    private let identity = Logger(
        subsystem: CameraAgentDiagnosticLog.subsystem,
        category: CameraAgentDiagnosticLog.identityCategory
    )
    private let lifecycle = Logger(
        subsystem: CameraAgentDiagnosticLog.subsystem,
        category: CameraAgentDiagnosticLog.lifecycleCategory
    )

    public init() {}

    public func record(_ event: CameraAgentDiagnosticEvent) {
        switch event {
        case let .authorizationStatus(status, source):
            lifecycle.notice("authorization_status status=\(status.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public)")

        case let .peerIdentityResolutionRejected(processIdentifier, reason):
            identity.error("peer_identity_rejected pid=\(processIdentifier, privacy: .public) reason=\(reason.rawValue, privacy: .public)")

        case let .peerAdmissionRejected(peer, reason):
            identity.error("peer_admission_rejected pid=\(peer.processIdentifier, privacy: .public) team_id=\(peer.teamIdentifier, privacy: .public) bundle_id=\(peer.bundleIdentifier, privacy: .public) role=\(peer.role.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")

        case let .peerAdmissionAccepted(connectionIdentifier, peer):
            identity.notice("peer_admission_accepted connection_id=\(connectionIdentifier, privacy: .public) pid=\(peer.processIdentifier, privacy: .public) team_id=\(peer.teamIdentifier, privacy: .public) bundle_id=\(peer.bundleIdentifier, privacy: .public) role=\(peer.role.rawValue, privacy: .public)")

        case let .connectionInvalidated(connectionIdentifier, peer):
            identity.notice("connection_invalidated connection_id=\(connectionIdentifier, privacy: .public) pid=\(peer.processIdentifier, privacy: .public) team_id=\(peer.teamIdentifier, privacy: .public) bundle_id=\(peer.bundleIdentifier, privacy: .public) role=\(peer.role.rawValue, privacy: .public)")

        case let .leaseCountChanged(previous, current, producerStreamEpoch):
            lifecycle.notice("lease_count_changed previous=\(previous, privacy: .public) current=\(current, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")

        case let .captureStartRequested(generation, producerStreamEpoch):
            lifecycle.notice("capture_start_requested generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")

        case let .captureStarted(generation, producerStreamEpoch):
            lifecycle.notice("capture_started generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")

        case let .firstFramePublished(generation, producerStreamEpoch, sequence):
            lifecycle.notice("first_frame_published generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public) sequence=\(sequence, privacy: .public)")

        case let .captureStopRequested(generation, producerStreamEpoch):
            lifecycle.notice("capture_stop_requested generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")

        case let .captureStopped(generation, producerStreamEpoch):
            lifecycle.notice("capture_stopped generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")

        case let .captureInterrupted(generation, producerStreamEpoch):
            lifecycle.error("capture_interrupted generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")

        case let .captureRuntimeError(generation, producerStreamEpoch):
            lifecycle.error("capture_runtime_error generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")

        case let .recoveryFailure(generation, producerStreamEpoch, cause):
            lifecycle.error("recovery_failure generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public) cause=\(Self.recoveryCauseToken(cause), privacy: .public)")

        case let .recoveryRetryScheduled(generation, producerStreamEpoch):
            lifecycle.notice("recovery_retry_scheduled generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")

        case let .recoveryRetryStarted(generation, producerStreamEpoch):
            lifecycle.notice("recovery_retry_started generation=\(generation, privacy: .public) epoch=\(producerStreamEpoch, privacy: .public)")
        }
    }

    private static func recoveryCauseToken(_ cause: CameraCaptureRecoveryCause) -> String {
        switch cause {
        case .noDevice: "no-device"
        case .permissionUnavailable: "permission-unavailable"
        case .firstFrameTimeout: "first-frame-timeout"
        case .frameStall: "frame-stall"
        case .startFailure: "start-failure"
        case .interruption: "interruption"
        case .mediaServicesReset: "media-services-reset"
        }
    }
}
