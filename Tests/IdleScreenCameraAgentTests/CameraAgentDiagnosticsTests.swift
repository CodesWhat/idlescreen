import Foundation
import IdleScreenCamera
import Testing
@testable import IdleScreenCameraAgentCore

@Suite("Camera agent evidence diagnostics")
struct CameraAgentDiagnosticsTests {
    @Test("authorization evidence records startup refresh and explicit completion exactly")
    func authorizationEvidence() throws {
        let diagnostics = CameraAgentDiagnosticRecorder()
        let authorization = DiagnosticsAuthorizationChecker(status: .notDetermined)
        let harness = try DiagnosticsServiceHarness(
            authorization: .notDetermined,
            authorizationChecker: authorization,
            diagnostics: diagnostics
        )
        let companion = try harness.service.admit(peer: harness.companionPeer)
        let statusRequest = try #require(IdleScreenCameraStatusRequest())
        let authorizationRequest = try #require(IdleScreenCameraAuthorizationRequest())

        _ = companion.authorizationStatus(statusRequest)
        _ = companion.requestAuthorization(authorizationRequest)
        harness.service.receiveAuthorizationResult(.authorized)

        #expect(diagnostics.events == [
            .authorizationStatus(status: .notDetermined, source: .startup),
            .authorizationStatus(status: .notDetermined, source: .statusRefresh),
            .authorizationStatus(status: .authorized, source: .explicitRequestCompletion),
        ])
    }

    @Test("lease capture first-frame and stop evidence is exact and first-frame bounded")
    func lifecycleEvidence() throws {
        let diagnostics = CameraAgentDiagnosticRecorder()
        let harness = try DiagnosticsServiceHarness(
            authorization: .authorized,
            producerStreamEpochSeed: 41,
            diagnostics: diagnostics
        )
        let connection = try harness.service.admit(peer: harness.screenSaverPeer)
        let begin = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let reply = connection.beginStream(begin)
        let lease = try #require(reply.leaseIdentifier)

        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.firstFrame(generation: 1, sequence: 7))
        harness.service.receiveCaptureDriverEvent(.firstFrame(generation: 1, sequence: 8))
        harness.service.receiveCaptureDriverEvent(.nextFrame(generation: 1, sequence: 9))
        _ = connection.endStream(try #require(
            IdleScreenCameraEndStreamRequest(leaseIdentifier: lease)
        ))
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))

        #expect(diagnostics.events == [
            .authorizationStatus(status: .authorized, source: .startup),
            .leaseCountChanged(previous: 0, current: 1, producerStreamEpoch: 41),
            .captureStartRequested(generation: 1, producerStreamEpoch: 41),
            .captureStarted(generation: 1, producerStreamEpoch: 41),
            .firstFramePublished(generation: 1, producerStreamEpoch: 41, sequence: 7),
            .leaseCountChanged(previous: 1, current: 0, producerStreamEpoch: 41),
            .captureStopRequested(generation: 1, producerStreamEpoch: 41),
            .captureStopped(generation: 1, producerStreamEpoch: 41),
        ])
    }

    @Test("runtime error evidence discards the raw failure code")
    func runtimeErrorEvidenceIsContentFree() throws {
        let diagnostics = CameraAgentDiagnosticRecorder()
        let harness = try DiagnosticsServiceHarness(
            authorization: .authorized,
            producerStreamEpochSeed: 51,
            diagnostics: diagnostics
        )
        let connection = try harness.service.admit(peer: harness.screenSaverPeer)
        _ = connection.beginStream(try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        )))
        diagnostics.reset()

        harness.service.receiveCaptureDriverEvent(.runtimeError(
            generation: 1,
            code: "raw-pixels request-payload glyph screenshot content-checksum"
        ))

        #expect(diagnostics.events == [
            .captureRuntimeError(generation: 1, producerStreamEpoch: 51),
            .recoveryFailure(
                generation: 1,
                producerStreamEpoch: 51,
                cause: .startFailure
            ),
            .captureStopRequested(generation: 1, producerStreamEpoch: 51),
            .recoveryRetryScheduled(generation: 1, producerStreamEpoch: 51),
        ])
    }

    @Test("interruption stop and recovery retry evidence is exact")
    func interruptionRecoveryEvidence() throws {
        let diagnostics = CameraAgentDiagnosticRecorder()
        let harness = try DiagnosticsServiceHarness(
            authorization: .authorized,
            producerStreamEpochSeed: 61,
            diagnostics: diagnostics
        )
        let connection = try harness.service.admit(peer: harness.screenSaverPeer)
        _ = connection.beginStream(try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        )))
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.firstFrame(generation: 1, sequence: 1))
        diagnostics.reset()

        harness.service.receiveCaptureDriverEvent(.interrupted(generation: 1))

        #expect(diagnostics.events == [
            .captureInterrupted(generation: 1, producerStreamEpoch: 61),
            .recoveryFailure(
                generation: 1,
                producerStreamEpoch: 61,
                cause: .interruption
            ),
            .captureStopRequested(generation: 1, producerStreamEpoch: 61),
            .recoveryRetryScheduled(generation: 1, producerStreamEpoch: 61),
        ])

        diagnostics.reset()
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))
        harness.recoveryClock.now = 0.25
        harness.service.receiveCaptureDriverEvent(.recoveryRetryDeadlineReached(generation: 1))

        #expect(diagnostics.events == [
            .captureStopped(generation: 1, producerStreamEpoch: 61),
            .recoveryRetryStarted(generation: 2, producerStreamEpoch: 61),
            .captureStartRequested(generation: 2, producerStreamEpoch: 61),
        ])
    }
}

private final class CameraAgentDiagnosticRecorder: CameraAgentDiagnosticEventSink,
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

    func reset() {
        lock.withLock { storage.removeAll() }
    }
}

private final class DiagnosticsAuthorizationChecker: CameraCaptureAuthorizationChecking,
    @unchecked Sendable
{
    var status: CameraCaptureAuthorization

    init(status: CameraCaptureAuthorization) {
        self.status = status
    }

    func authorizationStatus() -> CameraCaptureAuthorization {
        status
    }
}

private final class DiagnosticsServiceDriver: CameraAgentServiceDriver,
    @unchecked Sendable
{
    func transportIdentifier(for configuration: CameraAgentStreamConfiguration) -> String? {
        _ = configuration
        return "camera-frames-v1.mailbox"
    }

    func perform(
        _ action: CameraAgentAction,
        configuration: CameraAgentStreamConfiguration?
    ) {
        _ = action
        _ = configuration
    }
}

private struct DiagnosticsServiceHarness {
    let service: CameraAgentService
    let recoveryClock: DiagnosticsRecoveryClock

    let companionPeer = CameraAgentAuthenticatedPeer(
        processIdentifier: 40,
        teamIdentifier: "TEAM123456",
        bundleIdentifier: "com.idlescreen.app"
    )
    let screenSaverPeer = CameraAgentAuthenticatedPeer(
        processIdentifier: 41,
        teamIdentifier: "TEAM123456",
        bundleIdentifier: "com.idlescreen.app.screensaver"
    )

    init(
        authorization: CameraAgentAuthorization,
        producerStreamEpochSeed: UInt64 = 1,
        authorizationChecker: (any CameraCaptureAuthorizationChecking)? = nil,
        diagnostics: any CameraAgentDiagnosticEventSink
    ) throws {
        let recoveryClock = DiagnosticsRecoveryClock()
        self.recoveryClock = recoveryClock
        let policy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123456",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))
        let limits = try #require(CameraAgentCaptureLimits(
            maximumWidth: 1_280,
            maximumHeight: 720,
            maximumFramesPerSecond: 30,
            maximumMailboxSlotCount: 2
        ))
        guard let service = CameraAgentService(
            peerPolicy: policy,
            captureLimits: limits,
            leaseTimeToLive: 5,
            initialAuthorization: authorization,
            producerStreamEpochSeed: producerStreamEpochSeed,
            agentIdentity: makeTestAgentIdentity(
                processIncarnationEpoch: producerStreamEpochSeed
            )!,
            authorizationChecker: authorizationChecker,
            recoveryClock: { [recoveryClock] in recoveryClock.now },
            clock: { Date(timeIntervalSince1970: 100) },
            identifierGenerator: {
                UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
            },
            driver: DiagnosticsServiceDriver(),
            diagnosticSink: diagnostics
        ) else {
            throw DiagnosticsServiceHarnessError.assemblyFailed
        }
        self.service = service
    }
}

private enum DiagnosticsServiceHarnessError: Error {
    case assemblyFailed
}

private final class DiagnosticsRecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval = 0

    var now: TimeInterval {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
