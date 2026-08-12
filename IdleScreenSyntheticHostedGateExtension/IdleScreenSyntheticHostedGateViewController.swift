import AppKit
import IdleScreenCamera
import IdleScreenCore
import OSLog
import ScreenSaver

private let syntheticHostedGateLogger = Logger(
    subsystem: "com.idlescreen.screensaver",
    category: "SyntheticHostedGate"
)

struct IdleScreenSyntheticHostedGatePreflightObservation: Equatable, Sendable {
    let helperProcessIdentifier: Int32
    let accepted: Bool
    let activeLeaseCount: Int
    let captureActive: Bool

    var logMessage: String {
        "Synthetic hosted gate preflight helper_pid=\(helperProcessIdentifier) accepted=true active_lease_count=0 capture_active=false"
    }
}

/// Gate-only authenticated control probe. The production saver does not use
/// this seam: it exists solely to prove that the installed synthetic helper is
/// idle before the hosted saver creates its independent streaming connection.
struct IdleScreenSyntheticHostedGatePreflightProbe: Sendable {
    typealias Reply = @Sendable (
        IdleScreenCameraDiagnosticSnapshot?,
        Int32,
        @escaping @Sendable () -> Void
    ) -> Void
    typealias Request = @Sendable (@escaping Reply) -> Void

    private static let responseDeadline: DispatchTimeInterval = .milliseconds(2_100)
    private static let invalidationSettleInterval: TimeInterval = 0.1

    private let request: Request

    init(_ request: @escaping Request) {
        self.request = request
    }

    static func live(infoDictionary: [String: Any]) -> Self? {
        guard let machServiceName =
                infoDictionary[CameraClientBootstrap.machServiceInfoKey] as? String,
              let teamIdentifier =
                infoDictionary[CameraClientBootstrap.teamIdentifierInfoKey] as? String,
              let configuration = CameraAgentXPCClientConfiguration(
                machServiceName: machServiceName,
                expectedTeamIdentifier: teamIdentifier
              ) else {
            return nil
        }
        let client = CameraAgentControlClient(configuration: configuration)
        return Self { reply in
            IdleScreenSyntheticHostedGateLivePreflight(
                client: client,
                reply: reply
            ).start()
        }
    }

    static func assess(
        snapshot: IdleScreenCameraDiagnosticSnapshot?,
        remoteProcessIdentifier: Int32
    ) -> IdleScreenSyntheticHostedGatePreflightObservation? {
        guard remoteProcessIdentifier > 0,
              let snapshot,
              snapshot.accepted,
              let identity = snapshot.agentIdentity,
              identity.matches(remoteProcessIdentifier: remoteProcessIdentifier),
              snapshot.activeLeaseCount == 0,
              !snapshot.captureActive else {
            return nil
        }
        return IdleScreenSyntheticHostedGatePreflightObservation(
            helperProcessIdentifier: identity.processIdentifier,
            accepted: snapshot.accepted,
            activeLeaseCount: snapshot.activeLeaseCount,
            captureActive: snapshot.captureActive
        )
    }

    func perform(
        accepted: (IdleScreenSyntheticHostedGatePreflightObservation) -> Void
    ) -> IdleScreenSyntheticHostedGatePreflightObservation? {
        let response = IdleScreenSyntheticHostedGatePreflightResponse()
        request { snapshot, remoteProcessIdentifier, invalidate in
            response.deliver(
                snapshot: snapshot,
                remoteProcessIdentifier: remoteProcessIdentifier,
                invalidate: invalidate
            )
        }
        guard let result = response.wait(deadline: Self.responseDeadline) else {
            return nil
        }
        guard let observation = Self.assess(
            snapshot: result.snapshot,
            remoteProcessIdentifier: result.remoteProcessIdentifier
        ) else {
            result.invalidate()
            return nil
        }

        accepted(observation)
        result.invalidate()
        Thread.sleep(forTimeInterval: Self.invalidationSettleInterval)
        return observation
    }

    func run(
        completion: @escaping @MainActor @Sendable (
            IdleScreenSyntheticHostedGatePreflightObservation?
        ) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let observation = perform { _ in }
            Task { @MainActor in
                completion(observation)
            }
        }
    }
}

private final class IdleScreenSyntheticHostedGatePreflightResponse:
    @unchecked Sendable
{
    struct Result: Sendable {
        let snapshot: IdleScreenCameraDiagnosticSnapshot?
        let remoteProcessIdentifier: Int32
        let invalidate: @Sendable () -> Void
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result?
    private var expired = false

    func deliver(
        snapshot: IdleScreenCameraDiagnosticSnapshot?,
        remoteProcessIdentifier: Int32,
        invalidate: @escaping @Sendable () -> Void
    ) {
        let result = Result(
            snapshot: snapshot,
            remoteProcessIdentifier: remoteProcessIdentifier,
            invalidate: invalidate
        )
        let shouldInvalidate = lock.withLock {
            guard self.result == nil, !expired else { return true }
            self.result = result
            return false
        }
        if shouldInvalidate {
            invalidate()
        } else {
            semaphore.signal()
        }
    }

    func wait(deadline: DispatchTimeInterval) -> Result? {
        guard semaphore.wait(timeout: .now() + deadline) == .success else {
            let lateResult = lock.withLock {
                expired = true
                let result = result
                self.result = nil
                return result
            }
            lateResult?.invalidate()
            return nil
        }
        return lock.withLock {
            let result = result
            self.result = nil
            return result
        }
    }
}

private final class IdleScreenSyntheticHostedGateLivePreflight:
    @unchecked Sendable
{
    private let client: CameraAgentControlClient
    private let lock = NSLock()
    private var reply: IdleScreenSyntheticHostedGatePreflightProbe.Reply?
    private var session: (any CameraAgentControlSession)?

    init(
        client: CameraAgentControlClient,
        reply: @escaping IdleScreenSyntheticHostedGatePreflightProbe.Reply
    ) {
        self.client = client
        self.reply = reply
    }

    func start() {
        let session = client.connect(attempt: 1) { [self] event in
            switch event {
            case .interrupted, .invalidated, .requestFailed:
                finish(snapshot: nil, remoteProcessIdentifier: 0)
            }
        }
        let didFinishBeforeSessionWasStored = lock.withLock {
            self.session = session
            return reply == nil
        }
        if didFinishBeforeSessionWasStored {
            invalidate()
            return
        }
        guard let request = IdleScreenCameraDiagnosticRequest() else {
            finish(snapshot: nil, remoteProcessIdentifier: 0)
            return
        }
        session.diagnosticSnapshot(request) { [self, session] snapshot in
            finish(
                snapshot: snapshot,
                remoteProcessIdentifier: session.remoteProcessIdentifier
            )
        }
    }

    private func finish(
        snapshot: IdleScreenCameraDiagnosticSnapshot?,
        remoteProcessIdentifier: Int32
    ) {
        let pendingReply = lock.withLock {
            let pendingReply = self.reply
            self.reply = nil
            return pendingReply
        }
        pendingReply?(snapshot, remoteProcessIdentifier) { [self] in
            invalidate()
        }
    }

    private func invalidate() {
        let activeSession = lock.withLock {
            let activeSession = self.session
            self.session = nil
            return activeSession
        }
        activeSession?.invalidate()
    }
}

/// Gate-only composition used to prove the hosted XPC/mailbox topology with a
/// camera-free producer. This source is not compiled by the shipping extension.
@MainActor
enum IdleScreenSyntheticHostedGateViewFactory {
    static func make(
        frame: NSRect,
        isPreview: Bool,
        cameraClient: IdleScreenSaverCameraClient?,
        configuration: IdleScreenConfiguration = .default
    ) -> IdleScreenSaverView? {
        IdleScreenSaverView(
            frame: frame,
            isPreview: isPreview,
            cameraClient: cameraClient,
            configuration: configuration,
            cameraHostContext: .explicitlyVerifiedFullScreen
        )
    }
}

@objc(IdleScreenSyntheticHostedGateViewController)
final class IdleScreenSyntheticHostedGateViewController: ScreenSaverViewController {
    private var saverView: IdleScreenSaverView?

    override func loadView() {
        let frame = NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let isPreview = frame.width < 480 || frame.height < 320
        view = NSView(frame: frame)
        guard !isPreview,
              let probe = IdleScreenSyntheticHostedGatePreflightProbe.live(
                infoDictionary: Bundle(
                    for: IdleScreenSyntheticHostedGateViewController.self
                ).infoDictionary ?? [:]
              ),
              probe.perform(accepted: { observation in
                syntheticHostedGateLogger.info(
                    "\(observation.logMessage, privacy: .public)"
                )
              }) != nil else {
            return
        }

        let saverView = IdleScreenSyntheticHostedGateViewFactory.make(
            frame: frame,
            isPreview: isPreview,
            cameraClient: IdleScreenSaverCameraProcess.shared.client
        )
        if let saverView {
            let instanceIdentifier = saverView.diagnosticState.instanceIdentifier
            syntheticHostedGateLogger.info(
                "Synthetic hosted gate loaded topology-equivalent=true trusted-for-production=false pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) instance=\(instanceIdentifier, privacy: .public) preview=\(isPreview, privacy: .public)"
            )
        }
        self.saverView = saverView
        view = saverView ?? NSView(frame: frame)
    }
}
