import CoreGraphics
import Foundation
import IdleScreenCamera
import IdleScreenCore
import IdleScreenRenderer
import Observation
import OSLog

struct IdleScreenCompanionCameraDiagnosticSnapshot: Equatable {
    let authorizationStatus: IdleScreenCameraAuthorizationStatus
    let captureActive: Bool
    let activeLeaseCount: Int
    let producerStreamEpoch: UInt64
    let summary: String
}

struct IdleScreenCompanionCameraIdentityAssessment: Equatable, Sendable {
    let observation: CameraAgentHelperIdentityObservation
    let generationIdentifier: String
    let serviceRegistration: CameraAgentServiceRegistration
    let runningBundleVersion: String?
    let runningSourceAppPath: String?
    let runningProcessIdentifier: Int32?
    let runningProcessEpoch: UInt64?
    let runningCodeDirectoryHash: String?

    init(
        observation: CameraAgentHelperIdentityObservation,
        generationIdentifier: String,
        serviceRegistration: CameraAgentServiceRegistration = .enabled,
        runningBundleVersion: String? = nil,
        runningSourceAppPath: String? = nil,
        runningProcessIdentifier: Int32? = nil,
        runningProcessEpoch: UInt64? = nil,
        runningCodeDirectoryHash: String? = nil
    ) {
        self.observation = observation
        self.generationIdentifier = generationIdentifier
        self.serviceRegistration = serviceRegistration
        self.runningBundleVersion = runningBundleVersion
        self.runningSourceAppPath = runningSourceAppPath
        self.runningProcessIdentifier = runningProcessIdentifier
        self.runningProcessEpoch = runningProcessEpoch
        self.runningCodeDirectoryHash = runningCodeDirectoryHash
    }
}

struct IdleScreenCompanionCameraAgentRebindReceipt: Equatable, Sendable {
    let previousProcessIdentifier: Int32?
    let processIdentifier: Int32
    let processEpoch: UInt64
    let bundleVersion: String
    let sourceAppPath: String
    let codeDirectoryHash: String
}

struct IdleScreenCompanionCameraAgentReplacementOutcome: Equatable, Sendable {
    let serviceRegistration: CameraAgentServiceRegistration
    let failureMessage: String?

    static func succeeded(
        _ serviceRegistration: CameraAgentServiceRegistration
    ) -> Self {
        Self(serviceRegistration: serviceRegistration, failureMessage: nil)
    }

    static func failed(
        _ message: String,
        serviceRegistration: CameraAgentServiceRegistration = .failed
    ) -> Self {
        Self(
            serviceRegistration: serviceRegistration,
            failureMessage: message
        )
    }
}

enum IdleScreenCompanionCameraAgentRepairState: Equatable, Sendable {
    case idle
    case replacing
    case verifying
    case verified(bundleVersion: String, sourceAppPath: String, processIdentifier: Int32)
    case failed(String)

    var isInProgress: Bool {
        switch self {
        case .replacing, .verifying: true
        case .idle, .verified, .failed: false
        }
    }
}

enum IdleScreenCompanionCameraDiagnosticFailure: Equatable {
    case serviceRegistration
    case clientRuntime(CameraClientBootstrapStatus)
    case control
    case rejected
}

enum IdleScreenCompanionCameraDiagnosticState: Equatable {
    case notRequested
    case loading
    case live(IdleScreenCompanionCameraDiagnosticSnapshot)
    case unavailable(IdleScreenCompanionCameraDiagnosticFailure)
}

struct IdleScreenCompanionCameraDevice: Equatable, Identifiable, Sendable {
    let deviceIdentifier: String
    let displayName: String
    let kind: IdleScreenCameraDeviceKind

    var id: String { deviceIdentifier }
}

struct IdleScreenCompanionCameraDeviceSnapshot: Equatable, Sendable {
    let inventoryGeneration: UInt64
    let connectedDevices: [IdleScreenCompanionCameraDevice]
    let configuredSelection: IdleScreenCameraSelection
    let preferredDeviceIdentifier: String?
    let resolvedDeviceIdentifier: String?
    let activeDeviceIdentifier: String?
    let reconfigurationPending: Bool
}

enum IdleScreenCompanionCameraDeviceFailure: Equatable, Sendable {
    case control
    case rejected(String?)
}

enum IdleScreenCompanionCameraDeviceState: Equatable, Sendable {
    case notRequested
    case loading
    case live(IdleScreenCompanionCameraDeviceSnapshot)
    case unavailable(IdleScreenCompanionCameraDeviceFailure)
}

/// Immutable products from one scoped mailbox read. `CGImage` is retained only
/// through its copied data provider, and the renderer frame owns its samples,
/// so neither value retains mailbox memory when this crosses back to MainActor.
struct IdleScreenCompanionCameraFrameRefresh: @unchecked Sendable {
    let availability: CameraFrameSourceAvailability
    let consumedFrame: IdleScreenCameraFrameDescriptor?
    let previewImage: CGImage?
    let rendererFrame: IdleScreenRendererCameraFrame?

    init(
        availability: CameraFrameSourceAvailability,
        consumedFrame: IdleScreenCameraFrameDescriptor?,
        previewImage: CGImage? = nil,
        rendererFrame: IdleScreenRendererCameraFrame? = nil
    ) {
        self.availability = availability
        self.consumedFrame = consumedFrame
        self.previewImage = previewImage
        self.rendererFrame = rendererFrame
    }
}

/// Narrow app-facing surface over the process runtime. Keeping this boundary
/// small lets companion tests prove lifecycle without camera, TCC, or XPC.
@MainActor
protocol IdleScreenCompanionCameraRuntime: AnyObject {
    var frameAvailability: CameraFrameSourceAvailability { get }

    /// Performs one scoped mailbox read so frame freshness can advance. The
    /// returned snapshot may contain an immutable image backed by a copied
    /// provider; the scoped mailbox pixel buffer never escapes the callback.
    func refreshFrameAvailability() -> IdleScreenCompanionCameraFrameRefresh

    /// Allows the high-frequency Studio path to skip the diagnostic-only
    /// full-frame copy while retaining the same bounded renderer sample.
    func refreshFrameAvailability(
        includePreviewImage: Bool
    ) -> IdleScreenCompanionCameraFrameRefresh

    /// Production performs the mailbox snapshot and image/sample conversion on
    /// a serial worker. The default keeps lightweight test runtimes source
    /// compatible and preserves their deterministic synchronous behavior.
    func requestFrameRefresh(
        includePreviewImage: Bool,
        completion: @escaping @MainActor @Sendable (
            IdleScreenCompanionCameraFrameRefresh
        ) -> Void
    )

    @discardableResult
    func attach(consumerIdentifier: String) -> Bool

    @discardableResult
    func detach(consumerIdentifier: String) -> Bool
}

extension IdleScreenCompanionCameraRuntime {
    func refreshFrameAvailability(
        includePreviewImage: Bool
    ) -> IdleScreenCompanionCameraFrameRefresh {
        refreshFrameAvailability()
    }

    func requestFrameRefresh(
        includePreviewImage: Bool,
        completion: @escaping @MainActor @Sendable (
            IdleScreenCompanionCameraFrameRefresh
        ) -> Void
    ) {
        completion(refreshFrameAvailability(
            includePreviewImage: includePreviewImage
        ))
    }
}

private enum IdleScreenCompanionCameraFrameReader {
    static func refresh(
        runtime: CameraClientRuntime,
        includePreviewImage: Bool
    ) -> IdleScreenCompanionCameraFrameRefresh {
        let read = runtime.frameSource.withFrame { descriptor, pixels in
            makeFrameProducts(
                descriptor: descriptor,
                pixels: pixels,
                includePreviewImage: includePreviewImage
            )
        }
        let consumedFrame: IdleScreenCameraFrameDescriptor?
        let previewImage: CGImage?
        let rendererFrame: IdleScreenRendererCameraFrame?
        if case let .frame(descriptor, products) = read {
            consumedFrame = descriptor
            previewImage = products.previewImage
            rendererFrame = products.rendererFrame
        } else {
            consumedFrame = nil
            previewImage = nil
            rendererFrame = nil
        }
        return IdleScreenCompanionCameraFrameRefresh(
            availability: runtime.frameSource.availability,
            consumedFrame: consumedFrame,
            previewImage: previewImage,
            rendererFrame: rendererFrame
        )
    }

    private static func makeFrameProducts(
        descriptor: IdleScreenCameraFrameDescriptor,
        pixels: UnsafeRawBufferPointer,
        includePreviewImage: Bool
    ) -> (
        previewImage: CGImage?,
        rendererFrame: IdleScreenRendererCameraFrame?
    ) {
        guard (try? descriptor.validated()) != nil,
              descriptor.pixelFormat == .bgra8Unorm,
              let width = Int(exactly: descriptor.width),
              let height = Int(exactly: descriptor.height),
              let bytesPerRow = Int(exactly: descriptor.bytesPerRow) else {
            return (nil, nil)
        }
        return (
            includePreviewImage
                ? makePreviewImage(descriptor: descriptor, pixels: pixels)
                : nil,
            IdleScreenRendererCameraFrame.samplingBGRA(
                producerStreamEpoch: descriptor.streamEpoch,
                sequence: descriptor.sequence,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixels: pixels,
                columns: IdleScreenRendererCameraFrame.productionColumns,
                rows: IdleScreenRendererCameraFrame.productionRows
            )
        )
    }

    private static func makePreviewImage(
        descriptor: IdleScreenCameraFrameDescriptor,
        pixels: UnsafeRawBufferPointer
    ) -> CGImage? {
        guard descriptor.pixelFormat == .bgra8Unorm,
              let width = Int(exactly: descriptor.width),
              let height = Int(exactly: descriptor.height),
              let bytesPerRow = Int(exactly: descriptor.bytesPerRow),
              let byteCount = Int(exactly: descriptor.bytesPerRow * descriptor.height),
              byteCount == pixels.count,
              let baseAddress = pixels.baseAddress else {
            return nil
        }
        let copiedPixels = Data(bytes: baseAddress, count: byteCount)
        guard let provider = CGDataProvider(data: copiedPixels as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// Exactly one production mailbox read executes on this queue at a time. The
/// MainActor client below coalesces timer ticks before enqueueing, so this
/// worker never accumulates stale frame requests behind an active read.
private final class IdleScreenCompanionCameraFrameWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.idlescreen.app.camera-frame-reader",
        qos: .userInteractive
    )

    func request(
        runtime: CameraClientRuntime,
        includePreviewImage: Bool,
        completion: @escaping @MainActor @Sendable (
            IdleScreenCompanionCameraFrameRefresh
        ) -> Void
    ) {
        queue.async {
            let refresh = IdleScreenCompanionCameraFrameReader.refresh(
                runtime: runtime,
                includePreviewImage: includePreviewImage
            )
            Task { @MainActor in
                completion(refresh)
            }
        }
    }
}

private let idleScreenCompanionCameraFrameWorker =
    IdleScreenCompanionCameraFrameWorker()

extension CameraClientRuntime: IdleScreenCompanionCameraRuntime {
    var frameAvailability: CameraFrameSourceAvailability {
        frameSource.availability
    }

    func refreshFrameAvailability() -> IdleScreenCompanionCameraFrameRefresh {
        refreshFrameAvailability(includePreviewImage: true)
    }

    func refreshFrameAvailability(
        includePreviewImage: Bool
    ) -> IdleScreenCompanionCameraFrameRefresh {
        IdleScreenCompanionCameraFrameReader.refresh(
            runtime: self,
            includePreviewImage: includePreviewImage
        )
    }

    func requestFrameRefresh(
        includePreviewImage: Bool,
        completion: @escaping @MainActor @Sendable (
            IdleScreenCompanionCameraFrameRefresh
        ) -> Void
    ) {
        idleScreenCompanionCameraFrameWorker.request(
            runtime: self,
            includePreviewImage: includePreviewImage,
            completion: completion
        )
    }
}

@MainActor
struct IdleScreenCompanionCameraBootstrap {
    let status: CameraClientBootstrapStatus
    let runtime: (any IdleScreenCompanionCameraRuntime)?
}

@MainActor
protocol IdleScreenCompanionCameraScheduledWork: AnyObject {
    func cancel()
}

@MainActor
protocol IdleScreenCompanionCameraScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any IdleScreenCompanionCameraScheduledWork
}

@MainActor
final class IdleScreenCompanionCameraTaskScheduler:
    IdleScreenCompanionCameraScheduling
{
    private final class ScheduledWork: IdleScreenCompanionCameraScheduledWork {
        private var operation: (@MainActor () -> Void)?
        private var task: Task<Void, Never>?

        init(operation: @escaping @MainActor () -> Void) {
            self.operation = operation
        }

        func start(after delay: TimeInterval) {
            task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.fire()
            }
        }

        func cancel() {
            operation = nil
            task?.cancel()
            task = nil
        }

        private func fire() {
            let operation = operation
            self.operation = nil
            task = nil
            operation?()
        }
    }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any IdleScreenCompanionCameraScheduledWork {
        let work = ScheduledWork(operation: operation)
        work.start(after: delay)
        return work
    }
}

@MainActor
struct IdleScreenCompanionCameraEffects {
    typealias ReadServiceRegistration = () -> CameraAgentServiceRegistration
    typealias RegisterAgent = () -> CameraAgentServiceRegistration
    typealias ReplaceAgent = (
        @escaping @MainActor (IdleScreenCompanionCameraAgentReplacementOutcome) -> Void
    ) -> Void
    typealias OpenRepairSurface = (CameraAgentRepairSurface) -> Bool
    typealias BootstrapPreview = ([String: Any]) -> IdleScreenCompanionCameraBootstrap
    typealias AssessAgentIdentity = (
        IdleScreenCameraAgentIdentity,
        Int32
    ) -> IdleScreenCompanionCameraIdentityAssessment?
    typealias ConnectControl = (
        UInt64,
        @escaping @Sendable (CameraAgentControlConnectionEvent) -> Void
    ) -> (any CameraAgentControlSession)?

    let readServiceRegistration: ReadServiceRegistration
    let registerAgent: RegisterAgent
    let replaceAgent: ReplaceAgent
    let openRepairSurface: OpenRepairSurface
    let bootstrapPreview: BootstrapPreview
    let assessAgentIdentity: AssessAgentIdentity
    let connectControl: ConnectControl

    init(
        readServiceRegistration: @escaping ReadServiceRegistration,
        registerAgent: @escaping RegisterAgent,
        replaceAgent: ReplaceAgent? = nil,
        openRepairSurface: @escaping OpenRepairSurface,
        bootstrapPreview: @escaping BootstrapPreview,
        assessAgentIdentity: @escaping AssessAgentIdentity = { _, _ in nil },
        connectControl: @escaping ConnectControl
    ) {
        self.readServiceRegistration = readServiceRegistration
        self.registerAgent = registerAgent
        self.replaceAgent = replaceAgent ?? { completion in
            completion(.succeeded(registerAgent()))
        }
        self.openRepairSurface = openRepairSurface
        self.bootstrapPreview = bootstrapPreview
        self.assessAgentIdentity = assessAgentIdentity
        self.connectControl = connectControl
    }
}

/// Process-wide companion coordinator. Construction performs exactly one
/// read-only service-status observation. Preview bootstrap, XPC connection,
/// authorization status, registration, permission, and Settings effects are
/// all deferred to visible lifecycle or explicit repair actions.
@MainActor
final class IdleScreenRendererCameraFrameRelay {
    typealias Subscription = UUID

    private(set) var latestFrame: IdleScreenRendererCameraFrame?
    private var subscribers: [
        Subscription: @MainActor (IdleScreenRendererCameraFrame?) -> Void
    ] = [:]

    @discardableResult
    func subscribe(
        _ subscriber: @escaping @MainActor (
            IdleScreenRendererCameraFrame?
        ) -> Void
    ) -> Subscription {
        let subscription = Subscription()
        subscribers[subscription] = subscriber
        subscriber(latestFrame)
        return subscription
    }

    func unsubscribe(_ subscription: Subscription) {
        subscribers[subscription] = nil
    }

    func publish(_ frame: IdleScreenRendererCameraFrame?) {
        latestFrame = frame
        let currentSubscribers = Array(subscribers.values)
        for subscriber in currentSubscribers {
            subscriber(frame)
        }
    }
}

@MainActor
@Observable
final class IdleScreenCompanionCameraClient {
    static let framePollInterval: TimeInterval = 1 / 30
    private static let repairVerificationRetryInterval: TimeInterval = 0.25
    private static let repairReplacementTimeout: TimeInterval = 12
    private static let repairVerificationTimeout: TimeInterval = 12
    private static let cameraDevicePollInterval: TimeInterval = 2
    static let authorizationRefreshInterval: TimeInterval = 2
    private static let stalledFrameConfirmationCount = 2

    private static let frameEvidenceLogger = Logger(
        subsystem: "com.idlescreen.app",
        category: "CameraEvidence"
    )

    private static let cameraAgentRepairLogger = Logger(
        subsystem: "com.idlescreen.app",
        category: "CameraAgentRepair"
    )

    private static let previewConsumerIdentifier =
        "companion-camera-page-preview"

    private enum AuthorizationRequestPurpose {
        case initialStatus
        case explicitRefresh
        case explicitPermission
        case permissionPoll(generation: UInt64, poll: UInt64)
    }

    @ObservationIgnored private let infoDictionary: [String: Any]
    @ObservationIgnored private let effects: IdleScreenCompanionCameraEffects
    @ObservationIgnored private let scheduler: any IdleScreenCompanionCameraScheduling

    private var stateMachine: CameraAgentOnboardingStateMachine
    private(set) var bootstrapStatus: CameraClientBootstrapStatus?
    private(set) var controlReachability: CameraAgentControlReachability = .unknown
    private(set) var cameraAgentDiagnosticState:
        IdleScreenCompanionCameraDiagnosticState = .notRequested
    private(set) var cameraDeviceState:
        IdleScreenCompanionCameraDeviceState = .notRequested
    private(set) var cameraAgentRepairState:
        IdleScreenCompanionCameraAgentRepairState = .idle {
            didSet { cameraAgentRepairStateDidChange() }
        }
    private(set) var isPreviewLeaseRequested = false
    private(set) var isPreviewLeaseAttached = false
    private(set) var previewImage: CGImage?
    private(set) var previewFrameDescriptor: IdleScreenCameraFrameDescriptor?
    @ObservationIgnored private(set) var rendererCameraFrame:
        IdleScreenRendererCameraFrame?
    @ObservationIgnored let rendererFrameRelay =
        IdleScreenRendererCameraFrameRelay()

    @ObservationIgnored private var runtime: (any IdleScreenCompanionCameraRuntime)?
    @ObservationIgnored private var controlSession: (any CameraAgentControlSession)?
    @ObservationIgnored private var authorizationStatusPollWork:
        (any IdleScreenCompanionCameraScheduledWork)?
    @ObservationIgnored private var authorizationTimeoutWork:
        (any IdleScreenCompanionCameraScheduledWork)?
    @ObservationIgnored private var authorizationRefreshWork:
        (any IdleScreenCompanionCameraScheduledWork)?
    @ObservationIgnored private var framePollWork:
        (any IdleScreenCompanionCameraScheduledWork)?
    @ObservationIgnored private var cameraDevicePollWork:
        (any IdleScreenCompanionCameraScheduledWork)?
    @ObservationIgnored private var repairVerificationRetryWork:
        (any IdleScreenCompanionCameraScheduledWork)?
    @ObservationIgnored private var repairReplacementTimeoutWork:
        (any IdleScreenCompanionCameraScheduledWork)?
    @ObservationIgnored private var repairVerificationTimeoutWork:
        (any IdleScreenCompanionCameraScheduledWork)?
    @ObservationIgnored private var backgroundRebindCompletion: ((
        IdleScreenCompanionCameraAgentRebindReceipt?,
        String?
    ) -> Void)?
    @ObservationIgnored private var frameRefreshIsInFlight = false
    @ObservationIgnored private var frameRefreshIsPending = false
    @ObservationIgnored private var frameRefreshRequestGeneration: UInt64 = 0

    private var isMainWindowOpen = false
    private var mainWindowPresentationIsActive = false
    private var isCameraPageSelected = false
    private var isStudioCameraPreviewSelected = false
    private var isCameraDiagnosticsSelected = false
    private var isBackgroundCameraAgentRebindActive = false
    private var cameraPrivacyRoundTripPending = false
    private var preservesPreviewRequestDuringAgentReplacement = false
    private var repairPreviousProcessIdentifier: Int32?
    private var repairReceipt: IdleScreenCompanionCameraAgentRebindReceipt?
    private var nextRepairReplacementOperation: UInt64 = 0
    private var currentRepairReplacementOperation: UInt64?
    private var lastObservedCameraAgentProcessIdentifier: Int32?
    private var nextControlAttempt: UInt64 = 0
    private var currentControlAttempt: UInt64?
    private var controlRequestIsPending = false
    private var diagnosticRequestIsPending = false
    private var nextDiagnosticFailureGeneration: UInt64 = 0
    private var liveDiagnosticGeneration: UInt64 = 0
    private var authorizationEvidenceGeneration: UInt64 = 0
    private var nextCameraDeviceRequest: UInt64 = 0
    private var currentCameraDeviceRequest: UInt64?
    private var authorizationPollingPolicy = CameraAuthorizationPollingPolicy()
    private var nextAuthorizationPollingGeneration: UInt64 = 0
    private var currentAuthorizationPollingGeneration: UInt64?
    private var frameConsumptionGeneration: UInt64 = 0
    private var frameConsumptionEpoch: UInt64?
    private var lastConsumedFrameSequence: UInt64?
    private var consecutiveStalledFrameObservations = 0

    init(
        infoDictionary: [String: Any],
        effects: IdleScreenCompanionCameraEffects,
        scheduler: any IdleScreenCompanionCameraScheduling
    ) {
        self.infoDictionary = infoDictionary
        self.effects = effects
        self.scheduler = scheduler

        var stateMachine = CameraAgentOnboardingStateMachine()
        _ = stateMachine.handle(.serviceRegistrationObserved(
            effects.readServiceRegistration()
        ))
        self.stateMachine = stateMachine
    }

    var readinessSnapshot: CameraAgentOnboardingSnapshot {
        stateMachine.snapshot
    }

    var frameReadiness: CameraAgentFrameReadiness {
        stateMachine.snapshot.frame
    }

    var recommendedRepair: CameraAgentReadinessRepair? {
        guard stateMachine.snapshot.serviceRegistration == .enabled else {
            return stateMachine.snapshot.recommendedRepair
        }
        if let bootstrapStatus, bootstrapStatus != .ready {
            return .refresh(.clientRuntime)
        }
        if stateMachine.snapshot.identity != .current
            || stateMachine.snapshot.liveSnapshot != .accepted {
            return stateMachine.snapshot.recommendedRepair
        }
        if controlReachability == .timedOut
            || controlReachability == .unreachable {
            return .refresh(.control)
        }
        if !isPreviewLeaseRequested,
           stateMachine.snapshot.identity == .current,
           stateMachine.snapshot.liveSnapshot == .accepted,
           stateMachine.snapshot.authorization == .observed(.authorized),
           controlReachability == .reachable {
            // Permission and transport readiness are complete. Frame evidence
            // belongs to the separate, explicit preview action below; merely
            // opening this page or granting TCC must not start capture.
            return nil
        }
        return stateMachine.snapshot.recommendedRepair
    }

    var isCameraAgentReplacementRecommended: Bool {
        guard stateMachine.snapshot.serviceRegistration == .enabled else {
            return false
        }
        if case .failed = cameraAgentRepairState {
            return true
        }
        switch stateMachine.snapshot.identity {
        case .absent, .stale, .mismatched:
            return true
        case .unknown:
            return controlReachability == .unreachable
                || controlReachability == .timedOut
        case .current:
            return false
        }
    }

    var canStartCameraPreview: Bool {
        isVisible
            && isPreviewSurfaceSelected
            && !isPreviewLeaseRequested
            && stateMachine.snapshot.identity == .current
            && stateMachine.snapshot.liveSnapshot == .accepted
            && stateMachine.snapshot.authorization == .observed(.authorized)
            && stateMachine.snapshot.control == .reachable
            && controlReachability == .reachable
            && runtime != nil
    }

    var isMainWindowPresentationActive: Bool {
        isMainWindowOpen && mainWindowPresentationIsActive
    }

    var frameAvailability: CameraFrameSourceAvailability {
        runtime?.frameAvailability ?? .unavailable(.leaseUnavailable)
    }

    var isUsingProceduralFallback: Bool {
        if case .available = frameAvailability,
           isPreviewLeaseAttached,
           rendererCameraFrame != nil {
            return false
        }
        return true
    }

    func mainWindowDidOpen() {
        guard !isMainWindowOpen else { return }
        isMainWindowOpen = true
        beginVisibleSessionIfNeeded()
    }

    func mainWindowWillClose() {
        guard isMainWindowOpen else { return }
        isMainWindowOpen = false
        mainWindowPresentationIsActive = false
        endVisibleSession()
    }

    func mainWindowPresentationDidChange(isActive: Bool) {
        let nextState = isMainWindowOpen && isActive
        guard mainWindowPresentationIsActive != nextState else { return }
        mainWindowPresentationIsActive = nextState
        if nextState {
            if cameraPrivacyRoundTripPending {
                cameraPrivacyRoundTripPending = false
                replaceCameraAgent(preservingPreviewRequest: true)
            } else {
                beginVisibleSessionIfNeeded()
            }
        } else {
            // Moving to System Settings must release the live lease, but it is
            // not the same lifecycle boundary as closing the window. Preserve
            // the user's requested preview so returning to Studio can observe
            // the new TCC state and recover without another Camera selection.
            endVisibleSession(preservingPreviewRequest: true)
        }
    }

    func cameraPageDidAppear() {
        guard !isCameraPageSelected else { return }
        isCameraPageSelected = true
        beginVisibleSessionIfNeeded()
    }

    func cameraPageDidDisappear() {
        // A retained NSWindow may report disappearance after AppKit has begun
        // closing. Preserve the selected page so reopen can re-establish its
        // fresh, independently fenced control attempt.
        guard isMainWindowOpen, isCameraPageSelected else { return }
        isCameraPageSelected = false
        stopCameraDeviceObservation()
        endVisibleSessionIfNeeded()
    }

    /// Refreshes the helper-owned inventory without changing selection,
    /// acquiring a preview lease, or prompting for camera authorization.
    func refreshCameraDeviceInventory() {
        guard isCameraPageVisible else { return }
        requestCameraDeviceSnapshot(showLoading: true)
    }

    /// Makes the main Studio canvas a first-class preview consumer without
    /// starting capture. The separate Start action below remains the privacy
    /// boundary that acquires the companion lease.
    func studioCameraPreviewDidAppear() {
        guard !isStudioCameraPreviewSelected else { return }
        isStudioCameraPreviewSelected = true
        beginVisibleSessionIfNeeded()
    }

    func studioCameraPreviewDidDisappear() {
        guard isMainWindowOpen, isStudioCameraPreviewSelected else { return }
        isStudioCameraPreviewSelected = false
        endVisibleSessionIfNeeded()
    }

    func cameraDiagnosticsDidAppear() {
        guard !isCameraDiagnosticsSelected else { return }
        isCameraDiagnosticsSelected = true
        beginVisibleSessionIfNeeded()
    }

    func cameraDiagnosticsDidDisappear() {
        // Match Camera-page retention semantics across window close/reopen.
        guard isMainWindowOpen, isCameraDiagnosticsSelected else { return }
        isCameraDiagnosticsSelected = false
        endVisibleSessionIfNeeded()
    }

    /// The Camera page exposes exactly this one effectful entry point. The
    /// pure reducer rejects stale or non-recommended repair intents.
    func performRecommendedRepair() {
        let repair = recommendedRepair
        Self.cameraAgentRepairLogger.notice(
            "Repair requested visible=\(self.isVisible, privacy: .public) recommendation=\(String(describing: repair), privacy: .public)"
        )
        guard let repair else {
            return
        }
        if repair == .refresh(.clientRuntime) {
            retryClientRuntimeBootstrap()
            return
        }
        if isCameraAgentReplacementRecommended {
            replaceCameraAgent()
            return
        }
        if repair == .refresh(.identity),
           stateMachine.snapshot.serviceRegistration == .enabled,
           controlReachability == .unreachable
                || controlReachability == .timedOut {
            replaceCameraAgent()
            return
        }
        if repair == .refresh(.control),
           repair != stateMachine.snapshot.recommendedRepair {
            // Transport failures can precede an authorization observation, so
            // this app-level failure is intentionally allowed to retry the
            // nonprompting control read even though the pure reducer still
            // reports authorization as its lower-layer blocker.
            refresh(.control)
            return
        }
        let actions = stateMachine.handle(.visibleRepair(repair))
        for action in actions {
            perform(action)
        }
    }

    /// Opens the only macOS surface that can change Camera authorization and
    /// marks the next foreground transition as a permission boundary. Tahoe
    /// deliberately lets an already-running camera process retain its former
    /// decision when the user chooses Later, so returning from Privacy replaces
    /// only the helper and preserves the user's selected preview demand.
    func openCameraPrivacySettings() {
        guard isMainWindowOpen else { return }
        cameraPrivacyRoundTripPending = effects.openRepairSurface(
            .cameraPrivacySettings
        )
    }

    /// Installer-only maintenance entry point. It never requests a preview
    /// lease or camera authorization; the app stays hidden while the enabled
    /// LaunchAgent is replaced and its new authenticated identity is checked.
    func rebindCameraAgentForInstalledUpgrade(
        previousProcessIdentifier: Int32?,
        completion: @escaping (
            IdleScreenCompanionCameraAgentRebindReceipt?,
            String?
        ) -> Void
    ) {
        guard backgroundRebindCompletion == nil,
              !cameraAgentRepairState.isInProgress else {
            completion(nil, "A camera-agent replacement is already in progress.")
            return
        }
        isBackgroundCameraAgentRebindActive = true
        backgroundRebindCompletion = completion
        replaceCameraAgent(
            previousProcessIdentifier: previousProcessIdentifier
        )
    }

    /// Retries the authenticated diagnostic handshake without starting
    /// capture. Health only exposes this after identity is current so a
    /// snapshot retry cannot silently mutate Service Management state.
    func retryCameraDiagnostics() {
        guard isVisible,
              bootstrapStatus == .ready,
              stateMachine.snapshot.identity == .current,
              stateMachine.snapshot.liveSnapshot != .accepted else { return }
        refresh(.liveSnapshot)
    }

    /// Replaces an enabled-but-stale Service Management submission, then
    /// reports success only after the new PID returns authenticated identity
    /// evidence that exactly matches the helper embedded in this app.
    private func replaceCameraAgent(
        previousProcessIdentifier: Int32? = nil,
        preservingPreviewRequest: Bool = false
    ) {
        guard !cameraAgentRepairState.isInProgress else { return }
        Self.cameraAgentRepairLogger.notice("Replacement starting")
        preservesPreviewRequestDuringAgentReplacement =
            preservingPreviewRequest && isPreviewLeaseRequested
        repairPreviousProcessIdentifier = previousProcessIdentifier
            ?? lastObservedCameraAgentProcessIdentifier
        repairReceipt = nil
        cameraAgentRepairState = .replacing
        retireControlAndPreview(
            preservingPreviewRequest: preservingPreviewRequest
        )
        nextRepairReplacementOperation &+= 1
        let replacementOperation = nextRepairReplacementOperation
        currentRepairReplacementOperation = replacementOperation
        startRepairReplacementDeadline(operation: replacementOperation)
        effects.replaceAgent { [weak self] outcome in
            guard let self,
                  self.currentRepairReplacementOperation
                    == replacementOperation,
                  self.cameraAgentRepairState == .replacing else { return }
            self.currentRepairReplacementOperation = nil
            self.repairReplacementTimeoutWork?.cancel()
            self.repairReplacementTimeoutWork = nil
            let registration = String(describing: outcome.serviceRegistration)
            if let failureMessage = outcome.failureMessage {
                Self.cameraAgentRepairLogger.error(
                    "Replacement outcome registration=\(registration, privacy: .public) failure=\(failureMessage, privacy: .public)"
                )
            } else {
                Self.cameraAgentRepairLogger.notice(
                    "Replacement outcome registration=\(registration, privacy: .public)"
                )
            }
            _ = stateMachine.handle(.serviceRegistrationBoundaryObserved(
                outcome.serviceRegistration
            ))
            if let failureMessage = outcome.failureMessage {
                preservesPreviewRequestDuringAgentReplacement = false
                cameraAgentRepairState = .failed(failureMessage)
                return
            }
            guard stateMachine.snapshot.serviceRegistration == .enabled else {
                preservesPreviewRequestDuringAgentReplacement = false
                cameraAgentRepairState = .failed(
                    "The replacement did not become enabled."
                )
                return
            }
            cameraAgentRepairState = .verifying
            startRepairVerificationDeadline()
            bootstrapPreviewIfNeeded()
            connectControlIfNeeded()
            requestAuthorizationStatus(purpose: .explicitRefresh)
            requestDiagnosticSnapshotIfNeeded()
        }
    }

    /// Starts companion-only camera demand after a separate visible action.
    /// Authorization success itself intentionally leaves capture stopped so
    /// Gate A0 can prove TCC attribution without conflating it with frames.
    func startCameraPreview() {
        guard canStartCameraPreview else { return }
        isPreviewLeaseRequested = true
        reconcilePreviewDemand()
        scheduleAuthorizationRefresh()
    }

    func stopCameraPreview() {
        isPreviewLeaseRequested = false
        cancelAuthorizationRefresh()
        detachPreview()
        observeFrameReadiness(.unknown)
    }

    private var isVisible: Bool {
        isBackgroundCameraAgentRebindActive
            || (isMainWindowPresentationActive
            && (isPreviewSurfaceSelected || isCameraDiagnosticsSelected)
            )
    }

    private var isPreviewSurfaceSelected: Bool {
        isCameraPageSelected || isStudioCameraPreviewSelected
    }

    private var isCameraDiagnosticsVisible: Bool {
        isMainWindowPresentationActive && isCameraDiagnosticsSelected
    }

    private var isCameraPageVisible: Bool {
        isMainWindowPresentationActive && isCameraPageSelected
    }

    private func beginVisibleSessionIfNeeded() {
        guard isVisible else { return }

        let previousEpoch = stateMachine.serviceEpoch
        _ = stateMachine.handle(.serviceRegistrationObserved(
            effects.readServiceRegistration()
        ))
        if stateMachine.serviceEpoch != previousEpoch {
            retireControlAndPreview()
        }

        guard stateMachine.snapshot.serviceRegistration == .enabled else {
            retireControlAndPreview()
            if isCameraDiagnosticsVisible {
                cameraAgentDiagnosticState = .unavailable(.serviceRegistration)
            }
            return
        }

        bootstrapPreviewIfNeeded()
        guard bootstrapStatus == .ready, runtime != nil else {
            controlReachability = .unreachable
            _ = stateMachine.handle(.controlObserved(
                .unreachable,
                serviceEpoch: stateMachine.serviceEpoch
            ))
            if isCameraDiagnosticsVisible, let bootstrapStatus {
                cameraAgentDiagnosticState = .unavailable(
                    .clientRuntime(bootstrapStatus)
                )
            }
            return
        }
        connectControlIfNeeded()
        requestAuthorizationStatus(purpose: .initialStatus)
        requestDiagnosticSnapshotIfNeeded()
    }

    private func endVisibleSession(
        preservingPreviewRequest: Bool = false
    ) {
        retireControlAndPreview(
            preservingPreviewRequest: preservingPreviewRequest
        )
    }

    private func endVisibleSessionIfNeeded() {
        if isVisible {
            reconcilePreviewDemand()
        } else {
            endVisibleSession()
        }
    }

    private func bootstrapPreviewIfNeeded() {
        guard bootstrapStatus == nil else { return }
        let result = effects.bootstrapPreview(infoDictionary)
        bootstrapStatus = result.status
        runtime = result.runtime
    }

    private func retryClientRuntimeBootstrap() {
        guard isVisible,
              stateMachine.snapshot.serviceRegistration == .enabled else {
            return
        }
        detachPreview()
        runtime = nil
        bootstrapStatus = nil
        bootstrapPreviewIfNeeded()
        guard bootstrapStatus == .ready, runtime != nil else {
            controlReachability = .unreachable
            _ = stateMachine.handle(.controlObserved(
                .unreachable,
                serviceEpoch: stateMachine.serviceEpoch
            ))
            return
        }
        controlReachability = .unknown
        connectControlIfNeeded()
        requestAuthorizationStatus(purpose: .explicitRefresh)
        requestDiagnosticSnapshotIfNeeded()
    }

    private func connectControlIfNeeded() {
        guard isVisible,
              stateMachine.snapshot.serviceRegistration == .enabled,
              bootstrapStatus == .ready,
              runtime != nil,
              controlSession == nil else {
            return
        }

        nextControlAttempt &+= 1
        let attempt = nextControlAttempt
        observeIdentity(
            .unknown,
            generationIdentifier: "control-attempt-\(attempt)"
        )
        currentControlAttempt = attempt
        let session = effects.connectControl(attempt) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receiveControlEvent(event)
            }
        }
        guard let session else {
            currentControlAttempt = nil
            controlReachability = .unreachable
            if isCameraDiagnosticsVisible {
                cameraAgentDiagnosticState = .unavailable(.control)
            }
            return
        }
        controlSession = session
        controlReachability = .unknown
    }

    private func requestAuthorizationStatus(
        purpose: AuthorizationRequestPurpose
    ) {
        guard isVisible, !controlRequestIsPending else { return }
        connectControlIfNeeded()
        guard let session = controlSession,
              let attempt = currentControlAttempt,
              let request = IdleScreenCameraStatusRequest() else {
            controlReachability = .unreachable
            return
        }

        controlRequestIsPending = true
        let serviceEpoch = stateMachine.serviceEpoch
        let evidenceGeneration = authorizationEvidenceGeneration
        session.authorizationStatus(request) { [weak self] reply in
            Task { @MainActor [weak self] in
                self?.receiveAuthorizationReply(
                    reply,
                    purpose: purpose,
                    attempt: attempt,
                    serviceEpoch: serviceEpoch,
                    evidenceGeneration: evidenceGeneration
                )
            }
        }
    }

    private func requestDiagnosticSnapshotIfNeeded() {
        guard isVisible, !diagnosticRequestIsPending else {
            return
        }
        guard let session = controlSession,
              let attempt = currentControlAttempt,
              let request = IdleScreenCameraDiagnosticRequest() else {
            if isCameraDiagnosticsVisible {
                cameraAgentDiagnosticState = .unavailable(.control)
            }
            return
        }

        diagnosticRequestIsPending = true
        if isCameraDiagnosticsVisible {
            cameraAgentDiagnosticState = .loading
        }
        let serviceEpoch = stateMachine.serviceEpoch
        session.diagnosticSnapshot(request) { [weak self] reply in
            Task { @MainActor [weak self] in
                self?.receiveDiagnosticSnapshot(
                    reply,
                    attempt: attempt,
                    serviceEpoch: serviceEpoch
                )
            }
        }
    }

    private func receiveDiagnosticSnapshot(
        _ reply: IdleScreenCameraDiagnosticSnapshot?,
        attempt: UInt64,
        serviceEpoch: UInt64
    ) {
        guard isVisible,
              currentControlAttempt == attempt,
              stateMachine.serviceEpoch == serviceEpoch,
              let session = controlSession else {
            return
        }
        diagnosticRequestIsPending = false

        guard let reply else {
            if failKnownLiveDiagnosticEvidence(
                .unavailable,
                failure: .control
            ) {
                return
            }
            failDiagnosticHandshake(
                observation: .unknown,
                attempt: attempt,
                failure: .control
            )
            return
        }
        guard reply.accepted else {
            if failKnownLiveDiagnosticEvidence(
                .rejected,
                failure: .rejected
            ) {
                return
            }
            failDiagnosticHandshake(
                observation: .unknown,
                attempt: attempt,
                failure: .rejected
            )
            return
        }

        let remoteProcessIdentifier = session.remoteProcessIdentifier
        guard let identity = reply.agentIdentity else {
            if failKnownLiveDiagnosticEvidence(
                .rejected,
                failure: .rejected
            ) {
                return
            }
            failDiagnosticHandshake(
                observation: .unknown,
                attempt: attempt,
                failure: .rejected
            )
            return
        }
        guard identity.matches(
            remoteProcessIdentifier: remoteProcessIdentifier
        ) else {
            failDiagnosticHandshake(
                observation: .mismatched,
                attempt: attempt,
                failure: .rejected
            )
            return
        }
        guard let assessment = effects.assessAgentIdentity(
            identity,
            remoteProcessIdentifier
        ) else {
            if failKnownLiveDiagnosticEvidence(
                .rejected,
                failure: .rejected
            ) {
                return
            }
            failDiagnosticHandshake(
                observation: .unknown,
                attempt: attempt,
                failure: .rejected
            )
            return
        }

        let registrationEpoch = stateMachine.serviceEpoch
        _ = stateMachine.handle(.serviceRegistrationObserved(
            assessment.serviceRegistration
        ))
        if stateMachine.serviceEpoch != registrationEpoch {
            retireControlAndPreview()
        }
        guard stateMachine.snapshot.serviceRegistration == .enabled else {
            if isCameraDiagnosticsVisible {
                cameraAgentDiagnosticState = .unavailable(
                    .serviceRegistration
                )
            }
            return
        }

        lastObservedCameraAgentProcessIdentifier =
            assessment.runningProcessIdentifier
        if cameraAgentRepairState == .verifying,
           let previousProcessIdentifier = repairPreviousProcessIdentifier,
           assessment.runningProcessIdentifier == previousProcessIdentifier {
            Self.cameraAgentRepairLogger.notice(
                "Old helper PID (previousProcessIdentifier, privacy: .public) still answered during replacement verification; retrying"
            )
            observeIdentity(
                .unknown,
                generationIdentifier: "replacement-awaiting-new-pid-\(previousProcessIdentifier)"
            )
            failCurrentDiagnosticEvidence(.control)
            retireCurrentControlSession()
            scheduleRepairVerificationRetry()
            return
        }

        observeIdentity(
            assessment.observation,
            generationIdentifier: assessment.generationIdentifier
        )
        guard assessment.observation == .current else {
            if cameraAgentRepairState == .verifying {
                failCurrentDiagnosticEvidence(.rejected)
                retireCurrentControlSession()
                scheduleRepairVerificationRetry()
                return
            }
            failCurrentDiagnosticEvidence(.rejected)
            return
        }

        if let bundleVersion = assessment.runningBundleVersion,
           let sourceAppPath = assessment.runningSourceAppPath,
           let processIdentifier = assessment.runningProcessIdentifier,
           let processEpoch = assessment.runningProcessEpoch,
           let codeDirectoryHash = assessment.runningCodeDirectoryHash {
            if cameraAgentRepairState == .verifying {
                repairReceipt = IdleScreenCompanionCameraAgentRebindReceipt(
                    previousProcessIdentifier: repairPreviousProcessIdentifier,
                    processIdentifier: processIdentifier,
                    processEpoch: processEpoch,
                    bundleVersion: bundleVersion,
                    sourceAppPath: sourceAppPath,
                    codeDirectoryHash: codeDirectoryHash.lowercased()
                )
            }
            cameraAgentRepairState = .verified(
                bundleVersion: bundleVersion,
                sourceAppPath: sourceAppPath,
                processIdentifier: processIdentifier
            )
        } else if cameraAgentRepairState == .verifying {
            failCurrentDiagnosticEvidence(.rejected)
            retireCurrentControlSession()
            scheduleRepairVerificationRetry()
            return
        }

        let currentEpoch = stateMachine.serviceEpoch
        let authorization = Self.authorization(
            from: reply.authorizationStatus
        )
        if authorization == nil {
            invalidateAuthorizationEvidence()
            _ = stateMachine.handle(.liveSnapshotObserved(
                .unavailable,
                serviceEpoch: currentEpoch
            ))
        }
        _ = stateMachine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: currentEpoch
        ))
        controlReachability = .reachable
        if let authorization {
            _ = stateMachine.handle(.authorizationObserved(
                authorization,
                serviceEpoch: currentEpoch
            ))
            if authorization == .authorized {
                _ = stateMachine.handle(.controlObserved(
                    .reachable,
                    serviceEpoch: currentEpoch
                ))
            }
        }

        if isCameraDiagnosticsVisible {
            cameraAgentDiagnosticState = .live(
                IdleScreenCompanionCameraDiagnosticSnapshot(
                    authorizationStatus: reply.authorizationStatus,
                    captureActive: reply.captureActive,
                    activeLeaseCount: reply.activeLeaseCount,
                    producerStreamEpoch: reply.producerStreamEpoch,
                    summary: reply.summary
                )
            )
        }
        acceptLiveDiagnosticForCameraDevices()
        requestCameraDeviceSnapshot(showLoading: true)
        reconcilePreviewDemand()
        if preservesPreviewRequestDuringAgentReplacement {
            preservesPreviewRequestDuringAgentReplacement = false
            scheduleAuthorizationRefresh()
        }
    }

    private func requestCameraDeviceSnapshot(showLoading: Bool) {
        cancelCameraDevicePolling()
        guard isCameraPageVisible,
              stateMachine.snapshot.identity == .current,
              stateMachine.snapshot.liveSnapshot == .accepted,
              let session = controlSession,
              let attempt = currentControlAttempt,
              let request = IdleScreenCameraStatusRequest() else {
            return
        }

        nextCameraDeviceRequest &+= 1
        let requestGeneration = nextCameraDeviceRequest
        currentCameraDeviceRequest = requestGeneration
        if showLoading {
            cameraDeviceState = .loading
        }
        let serviceEpoch = stateMachine.serviceEpoch
        let diagnosticGeneration = liveDiagnosticGeneration
        let authorizationGeneration = authorizationEvidenceGeneration
        session.cameraDeviceSnapshot(request) { [weak self] reply in
            Task { @MainActor [weak self] in
                self?.receiveCameraDeviceSnapshot(
                    reply,
                    requestGeneration: requestGeneration,
                    attempt: attempt,
                    serviceEpoch: serviceEpoch,
                    diagnosticGeneration: diagnosticGeneration,
                    authorizationGeneration: authorizationGeneration
                )
            }
        }
    }

    private func receiveCameraDeviceSnapshot(
        _ reply: IdleScreenCameraDeviceSnapshotReply?,
        requestGeneration: UInt64,
        attempt: UInt64,
        serviceEpoch: UInt64,
        diagnosticGeneration: UInt64,
        authorizationGeneration: UInt64
    ) {
        guard isCameraPageVisible,
              currentCameraDeviceRequest == requestGeneration,
              currentControlAttempt == attempt,
              stateMachine.serviceEpoch == serviceEpoch,
              liveDiagnosticGeneration == diagnosticGeneration,
              authorizationEvidenceGeneration == authorizationGeneration,
              stateMachine.snapshot.identity == .current,
              stateMachine.snapshot.liveSnapshot == .accepted else {
            return
        }
        currentCameraDeviceRequest = nil

        guard let reply else {
            cameraDeviceState = .unavailable(.control)
            scheduleCameraDevicePoll()
            return
        }
        guard reply.accepted else {
            cameraDeviceState = .unavailable(.rejected(reply.errorMessage))
            scheduleCameraDevicePoll()
            return
        }
        guard let selection = Self.cameraSelection(
            from: reply.configuredSelection
        ) else {
            cameraDeviceState = .unavailable(.rejected(
                "The helper returned an invalid configured selection."
            ))
            scheduleCameraDevicePoll()
            return
        }

        cameraDeviceState = .live(
            IdleScreenCompanionCameraDeviceSnapshot(
                inventoryGeneration: reply.inventoryGeneration,
                connectedDevices: reply.connectedDevices.map {
                    IdleScreenCompanionCameraDevice(
                        deviceIdentifier: $0.deviceIdentifier,
                        displayName: $0.displayName,
                        kind: $0.kind
                    )
                },
                configuredSelection: selection,
                preferredDeviceIdentifier: reply.preferredDeviceIdentifier,
                resolvedDeviceIdentifier: reply.resolvedDeviceIdentifier,
                activeDeviceIdentifier: reply.activeDeviceIdentifier,
                reconfigurationPending: reply.reconfigurationPending
            )
        )
        scheduleCameraDevicePoll()
    }

    private func scheduleCameraDevicePoll() {
        cancelCameraDevicePolling()
        guard isCameraPageVisible else { return }
        cameraDevicePollWork = scheduler.schedule(
            after: Self.cameraDevicePollInterval
        ) { [weak self] in
            guard let self, isCameraPageVisible else { return }
            cameraDevicePollWork = nil
            requestCameraDeviceSnapshot(showLoading: false)
        }
    }

    private func acceptLiveDiagnosticForCameraDevices() {
        liveDiagnosticGeneration &+= 1
        currentCameraDeviceRequest = nil
        cancelCameraDevicePolling()
    }

    private func invalidateCameraDeviceEvidence(
        failure: IdleScreenCompanionCameraDeviceFailure? = nil
    ) {
        liveDiagnosticGeneration &+= 1
        currentCameraDeviceRequest = nil
        cancelCameraDevicePolling()
        if let failure, isCameraPageVisible {
            cameraDeviceState = .unavailable(failure)
        } else {
            cameraDeviceState = .notRequested
        }
    }

    private func stopCameraDeviceObservation() {
        currentCameraDeviceRequest = nil
        cancelCameraDevicePolling()
        cameraDeviceState = .notRequested
    }

    @discardableResult
    private func failKnownLiveDiagnosticEvidence(
        _ observation: CameraAgentLiveSnapshotObservation,
        failure: IdleScreenCompanionCameraDiagnosticFailure
    ) -> Bool {
        guard stateMachine.snapshot.identity == .current else { return false }
        invalidateAuthorizationEvidence()
        _ = stateMachine.handle(.liveSnapshotObserved(
            observation,
            serviceEpoch: stateMachine.serviceEpoch
        ))
        failCurrentDiagnosticEvidence(failure)
        return true
    }

    private func observeIdentity(
        _ observation: CameraAgentHelperIdentityObservation,
        generationIdentifier: String
    ) {
        let previousEpoch = stateMachine.serviceEpoch
        _ = stateMachine.handle(.identityObserved(
            observation,
            generationIdentifier: generationIdentifier
        ))
        guard stateMachine.serviceEpoch != previousEpoch else { return }

        // Identity generations fence every downstream observation. The
        // current control transport remains available long enough to consume
        // the identity-bearing reply that established the new epoch, but no
        // preview or authorization callback from the old epoch may survive.
        cancelAuthorizationPolling()
        cancelAuthorizationRefresh()
        invalidateCameraDeviceEvidence()
        controlRequestIsPending = false
        if !preservesPreviewRequestDuringAgentReplacement {
            isPreviewLeaseRequested = false
        }
        detachPreview()
        controlReachability = .unknown
    }

    private func failDiagnosticHandshake(
        observation: CameraAgentHelperIdentityObservation,
        attempt: UInt64,
        failure: IdleScreenCompanionCameraDiagnosticFailure
    ) {
        nextDiagnosticFailureGeneration &+= 1
        observeIdentity(
            observation,
            generationIdentifier:
                "untrusted-control-attempt-\(attempt)-\(nextDiagnosticFailureGeneration)"
        )
        if cameraAgentRepairState == .verifying {
            failCurrentDiagnosticEvidence(failure)
            retireCurrentControlSession()
            scheduleRepairVerificationRetry()
            return
        }
        failCurrentDiagnosticEvidence(failure)
    }

    private func failCurrentDiagnosticEvidence(
        _ failure: IdleScreenCompanionCameraDiagnosticFailure
    ) {
        let deviceFailure: IdleScreenCompanionCameraDeviceFailure =
            failure == .rejected ? .rejected(nil) : .control
        invalidateCameraDeviceEvidence(failure: deviceFailure)
        controlReachability = .unreachable
        cancelAuthorizationPolling()
        cancelAuthorizationRefresh()
        controlRequestIsPending = false
        if !preservesPreviewRequestDuringAgentReplacement {
            isPreviewLeaseRequested = false
        }
        detachPreview()
        if isCameraDiagnosticsVisible {
            cameraAgentDiagnosticState = .unavailable(failure)
        }
    }

    private func invalidateAuthorizationEvidence() {
        authorizationEvidenceGeneration &+= 1
        invalidateCameraDeviceEvidence()
        controlRequestIsPending = false
        cancelAuthorizationPolling()
    }

    private func requestCameraAuthorization() {
        guard isVisible, !controlRequestIsPending,
              let session = controlSession,
              let attempt = currentControlAttempt,
              let request = IdleScreenCameraAuthorizationRequest() else {
            controlReachability = .unreachable
            return
        }

        controlRequestIsPending = true
        startAuthorizationPolling()
        let serviceEpoch = stateMachine.serviceEpoch
        let evidenceGeneration = authorizationEvidenceGeneration
        session.requestAuthorization(request) { [weak self] reply in
            Task { @MainActor [weak self] in
                self?.receiveAuthorizationReply(
                    reply,
                    purpose: .explicitPermission,
                    attempt: attempt,
                    serviceEpoch: serviceEpoch,
                    evidenceGeneration: evidenceGeneration
                )
            }
        }
    }

    private func receiveAuthorizationReply(
        _ reply: IdleScreenCameraAuthorizationReply?,
        purpose: AuthorizationRequestPurpose,
        attempt: UInt64,
        serviceEpoch: UInt64,
        evidenceGeneration: UInt64
    ) {
        guard isVisible,
              currentControlAttempt == attempt,
              stateMachine.serviceEpoch == serviceEpoch,
              authorizationEvidenceGeneration == evidenceGeneration else {
            return
        }
        if case let .permissionPoll(generation, _) = purpose,
           currentAuthorizationPollingGeneration != generation {
            return
        }
        controlRequestIsPending = false

        guard let reply, reply.accepted,
              let authorization = Self.authorization(from: reply.status) else {
            // The control client completes a failed request with `nil` and
            // emits its typed failure event separately. Preserve a timeout if
            // those main-actor callbacks arrive in the opposite order.
            if controlReachability != .timedOut {
                controlReachability = .unreachable
            }
            _ = stateMachine.handle(.controlObserved(
                controlReachability,
                serviceEpoch: serviceEpoch
            ))
            cancelAuthorizationPolling()
            detachPreview()
            return
        }

        controlReachability = .reachable
        _ = stateMachine.handle(.authorizationObserved(
            authorization,
            serviceEpoch: serviceEpoch
        ))
        if authorization == .authorized {
            _ = stateMachine.handle(.controlObserved(
                .reachable,
                serviceEpoch: serviceEpoch
            ))
            cancelAuthorizationPolling()
            reconcilePreviewDemand()
        } else {
            detachPreview()
        }

        switch purpose {
        case .explicitPermission where authorization != .notDetermined:
            cancelAuthorizationPolling()
        case let .permissionPoll(generation, poll):
            handleAuthorizationPolling(.authorizationStatusReceived(
                generation: generation,
                poll: poll,
                status: authorization
            ))
        case .initialStatus, .explicitRefresh, .explicitPermission:
            break
        }
    }

    private func receiveControlEvent(_ event: CameraAgentControlConnectionEvent) {
        guard isVisible, currentControlAttempt == event.attempt else { return }

        invalidateCameraDeviceEvidence(failure: .control)

        if cameraAgentRepairState == .verifying {
            switch event {
            case .requestFailed(_, .timeout):
                controlReachability = .timedOut
            case .interrupted, .invalidated,
                 .requestFailed(_, .transportUnavailable):
                controlReachability = .unreachable
            }
            _ = stateMachine.handle(.controlObserved(
                controlReachability,
                serviceEpoch: stateMachine.serviceEpoch
            ))
            retireCurrentControlSession()
            cancelAuthorizationPolling()
            detachPreview()
            scheduleRepairVerificationRetry()
            return
        }

        switch event {
        case .interrupted:
            _ = failKnownLiveDiagnosticEvidence(
                .unavailable,
                failure: .control
            )
            controlReachability = .unreachable
            _ = stateMachine.handle(.controlObserved(
                .unreachable,
                serviceEpoch: stateMachine.serviceEpoch
            ))
            retireCurrentControlSession()
            cancelAuthorizationPolling()
            detachPreview()
            if isCameraDiagnosticsVisible {
                cameraAgentDiagnosticState = .unavailable(.control)
            }

        case .invalidated:
            _ = failKnownLiveDiagnosticEvidence(
                .unavailable,
                failure: .control
            )
            controlReachability = .unreachable
            _ = stateMachine.handle(.controlObserved(
                .unreachable,
                serviceEpoch: stateMachine.serviceEpoch
            ))
            controlSession = nil
            currentControlAttempt = nil
            controlRequestIsPending = false
            diagnosticRequestIsPending = false
            cancelAuthorizationPolling()
            detachPreview()
            if isCameraDiagnosticsVisible {
                cameraAgentDiagnosticState = .unavailable(.control)
            }

        case let .requestFailed(_, failure):
            _ = failKnownLiveDiagnosticEvidence(
                .unavailable,
                failure: .control
            )
            controlRequestIsPending = false
            diagnosticRequestIsPending = false
            cancelAuthorizationPolling()
            controlReachability = failure == .timeout ? .timedOut : .unreachable
            let epoch = stateMachine.serviceEpoch
            _ = stateMachine.handle(.controlObserved(
                controlReachability,
                serviceEpoch: epoch
            ))
            detachPreview()
            if isCameraDiagnosticsVisible {
                cameraAgentDiagnosticState = .unavailable(.control)
            }
        }
    }

    private func startRepairReplacementDeadline(operation: UInt64) {
        repairReplacementTimeoutWork?.cancel()
        repairReplacementTimeoutWork = scheduler.schedule(
            after: Self.repairReplacementTimeout
        ) { [weak self] in
            guard let self,
                  self.currentRepairReplacementOperation == operation,
                  self.cameraAgentRepairState == .replacing else { return }
            self.currentRepairReplacementOperation = nil
            self.repairReplacementTimeoutWork = nil
            self.preservesPreviewRequestDuringAgentReplacement = false
            self.cameraAgentRepairState = .failed(
                "The camera-agent replacement did not finish within 12 seconds."
            )
        }
    }

    private func startRepairVerificationDeadline() {
        repairVerificationRetryWork?.cancel()
        repairVerificationRetryWork = nil
        repairVerificationTimeoutWork?.cancel()
        repairVerificationTimeoutWork = scheduler.schedule(
            after: Self.repairVerificationTimeout
        ) { [weak self] in
            guard let self,
                  self.cameraAgentRepairState == .verifying else { return }
            self.cameraAgentRepairState = .failed(
                "The replacement did not return a new verified helper identity within 12 seconds."
            )
        }
    }

    private func scheduleRepairVerificationRetry() {
        guard cameraAgentRepairState == .verifying,
              repairVerificationRetryWork == nil else { return }
        repairVerificationRetryWork = scheduler.schedule(
            after: Self.repairVerificationRetryInterval
        ) { [weak self] in
            guard let self else { return }
            self.repairVerificationRetryWork = nil
            guard self.cameraAgentRepairState == .verifying else { return }
            self.bootstrapPreviewIfNeeded()
            self.connectControlIfNeeded()
            self.requestDiagnosticSnapshotIfNeeded()
        }
    }

    private func cameraAgentRepairStateDidChange() {
        guard !cameraAgentRepairState.isInProgress else { return }
        currentRepairReplacementOperation = nil
        repairReplacementTimeoutWork?.cancel()
        repairReplacementTimeoutWork = nil
        repairVerificationRetryWork?.cancel()
        repairVerificationRetryWork = nil
        repairVerificationTimeoutWork?.cancel()
        repairVerificationTimeoutWork = nil

        guard let completion = backgroundRebindCompletion else { return }
        backgroundRebindCompletion = nil
        isBackgroundCameraAgentRebindActive = false
        let receipt = repairReceipt
        let failureMessage: String?
        switch cameraAgentRepairState {
        case .verified where receipt != nil:
            failureMessage = nil
        case let .failed(message):
            failureMessage = message
        default:
            failureMessage = "The camera-agent replacement ended without verified identity."
        }
        retireControlAndPreview()
        completion(receipt, failureMessage)
    }

    private func startAuthorizationPolling() {
        cancelAuthorizationPolling()
        nextAuthorizationPollingGeneration &+= 1
        let generation = nextAuthorizationPollingGeneration
        currentAuthorizationPollingGeneration = generation
        authorizationPollingPolicy = CameraAuthorizationPollingPolicy()
        handleAuthorizationPolling(.explicitPermissionRequest(
            generation: generation
        ))
    }

    private func handleAuthorizationPolling(
        _ event: CameraAuthorizationPollingEvent
    ) {
        let actions = authorizationPollingPolicy.handle(event)
        for action in actions {
            performAuthorizationPolling(action)
        }
    }

    private func performAuthorizationPolling(
        _ action: CameraAuthorizationPollingAction
    ) {
        switch action {
        case let .scheduleStatusPoll(generation, poll, delay):
            guard currentAuthorizationPollingGeneration == generation else {
                return
            }
            authorizationStatusPollWork?.cancel()
            authorizationStatusPollWork = scheduler.schedule(after: delay) {
                [weak self] in
                guard let self,
                      currentAuthorizationPollingGeneration == generation else {
                    return
                }
                authorizationStatusPollWork = nil
                handleAuthorizationPolling(.pollDeadlineReached(
                    generation: generation,
                    poll: poll
                ))
            }

        case let .scheduleTimeout(generation, delay):
            guard currentAuthorizationPollingGeneration == generation else {
                return
            }
            authorizationTimeoutWork?.cancel()
            authorizationTimeoutWork = scheduler.schedule(after: delay) {
                [weak self] in
                guard let self,
                      currentAuthorizationPollingGeneration == generation else {
                    return
                }
                authorizationTimeoutWork = nil
                handleAuthorizationPolling(.timeoutDeadlineReached(
                    generation: generation
                ))
            }

        case let .requestAuthorizationStatus(generation, poll):
            guard currentAuthorizationPollingGeneration == generation else {
                return
            }
            if controlRequestIsPending {
                // The explicit TCC request may still be waiting on the user
                // when the first policy deadline arrives. Keep the policy's
                // finite overall timeout, but defer this nonprompting read
                // instead of dropping it in the waiting-for-reply phase.
                authorizationStatusPollWork?.cancel()
                authorizationStatusPollWork = scheduler.schedule(
                    after: CameraAuthorizationPollingPolicy.pollInterval
                ) { [weak self] in
                    guard let self,
                          currentAuthorizationPollingGeneration == generation else {
                        return
                    }
                    authorizationStatusPollWork = nil
                    performAuthorizationPolling(.requestAuthorizationStatus(
                        generation: generation,
                        poll: poll
                    ))
                }
                return
            }
            requestAuthorizationStatus(purpose: .permissionPoll(
                generation: generation,
                poll: poll
            ))

        case let .completed(generation, result):
            guard currentAuthorizationPollingGeneration == generation else {
                return
            }
            cancelAuthorizationPolling()
            if result == .timedOut {
                controlReachability = .timedOut
                _ = stateMachine.handle(.controlObserved(
                    .timedOut,
                    serviceEpoch: stateMachine.serviceEpoch
                ))
                detachPreview()
            }
        }
    }

    private func scheduleFramePoll() {
        cancelFramePolling()
        guard isVisible, isPreviewLeaseAttached else { return }
        framePollWork = scheduler.schedule(after: Self.framePollInterval) {
            [weak self] in
            guard let self else { return }
            framePollWork = nil
            refreshFrameReadiness()
            scheduleFramePoll()
        }
    }

    private func refreshFrameReadiness() {
        guard isPreviewLeaseAttached, let runtime else { return }
        guard !frameRefreshIsInFlight else {
            // A timer tick represents demand for the newest frame, not another
            // mailbox job. One pending bit coalesces every tick during a read.
            frameRefreshIsPending = true
            return
        }
        frameRefreshIsInFlight = true
        let requestGeneration = frameRefreshRequestGeneration
        runtime.requestFrameRefresh(
            includePreviewImage: false
        ) { [weak self] refresh in
            self?.receiveFrameRefresh(
                refresh,
                requestGeneration: requestGeneration
            )
        }
    }

    private func receiveFrameRefresh(
        _ refresh: IdleScreenCompanionCameraFrameRefresh,
        requestGeneration: UInt64
    ) {
        frameRefreshIsInFlight = false
        if requestGeneration == frameRefreshRequestGeneration,
           isPreviewLeaseAttached {
            processFrameRefresh(refresh)
        }

        let shouldRefreshNewestFrame = frameRefreshIsPending
        frameRefreshIsPending = false
        if shouldRefreshNewestFrame, isPreviewLeaseAttached {
            refreshFrameReadiness()
        }
    }

    private func processFrameRefresh(
        _ refresh: IdleScreenCompanionCameraFrameRefresh
    ) {
        let shouldRetainFrame = shouldRetainPreviewFrame(
            during: refresh.availability
        )
        if shouldRetainFrame {
            consecutiveStalledFrameObservations = min(
                Self.stalledFrameConfirmationCount,
                consecutiveStalledFrameObservations + 1
            )
        } else {
            consecutiveStalledFrameObservations = 0
        }
        if let descriptor = refresh.consumedFrame {
            if recordFrameConsumption(descriptor) {
                if let previewImage = refresh.previewImage {
                    self.previewImage = previewImage
                }
                publishRendererCameraFrame(refresh.rendererFrame)
                previewFrameDescriptor = refresh.rendererFrame == nil
                    ? nil
                    : descriptor
            }
        } else if case .available = refresh.availability {
            // No newer frame: keep the last accepted image for this stream.
        } else if !shouldRetainFrame {
            clearPreviewFrame()
        }
        let readinessAvailability: CameraFrameSourceAvailability
        if shouldRetainFrame,
           consecutiveStalledFrameObservations
                < Self.stalledFrameConfirmationCount,
           let previewFrameDescriptor {
            readinessAvailability = .available(
                epoch: previewFrameDescriptor.streamEpoch,
                sequence: previewFrameDescriptor.sequence
            )
        } else {
            readinessAvailability = refresh.availability
        }
        let readiness = Self.frameReadiness(
            from: readinessAvailability
        )
        observeFrameReadiness(readiness)
    }

    @discardableResult
    private func recordFrameConsumption(
        _ descriptor: IdleScreenCameraFrameDescriptor
    ) -> Bool {
        guard descriptor.streamEpoch > 0, descriptor.sequence > 0 else {
            return false
        }
        if frameConsumptionEpoch != descriptor.streamEpoch {
            frameConsumptionGeneration = frameConsumptionGeneration == UInt64.max
                ? 1
                : frameConsumptionGeneration + 1
            frameConsumptionEpoch = descriptor.streamEpoch
            lastConsumedFrameSequence = nil
        }
        guard lastConsumedFrameSequence.map({ descriptor.sequence > $0 }) ?? true else {
            return false
        }
        lastConsumedFrameSequence = descriptor.sequence
        Self.frameEvidenceLogger.notice(
            "companion_frame_consumed generation=\(self.frameConsumptionGeneration, privacy: .public) epoch=\(descriptor.streamEpoch, privacy: .public) sequence=\(descriptor.sequence, privacy: .public)"
        )
        return true
    }

    private func shouldRetainPreviewFrame(
        during availability: CameraFrameSourceAvailability
    ) -> Bool {
        let unavailableEpoch: UInt64
        switch availability {
        case let .unavailable(.firstFrameTimedOut(epoch)),
             let .unavailable(.staleFrame(epoch, _)):
            unavailableEpoch = epoch
        case .waitingForFrame, .available, .unavailable:
            return false
        }
        return isPreviewLeaseAttached
            && previewFrameDescriptor?.streamEpoch == unavailableEpoch
            && rendererCameraFrame?.producerStreamEpoch == unavailableEpoch
    }

    private func reconcilePreviewDemand() {
        let shouldAttach = isPreviewLeaseRequested
            && isVisible
            && isPreviewSurfaceSelected
            && stateMachine.snapshot.identity == .current
            && stateMachine.snapshot.liveSnapshot == .accepted
            && stateMachine.snapshot.authorization == .observed(.authorized)
            && stateMachine.snapshot.control == .reachable
            && controlReachability == .reachable
            && controlSession != nil

        if shouldAttach, !isPreviewLeaseAttached, let runtime {
            isPreviewLeaseAttached = runtime.attach(
                consumerIdentifier: Self.previewConsumerIdentifier
            )
            if isPreviewLeaseAttached {
                refreshFrameReadiness()
                scheduleFramePoll()
            }
        } else if !shouldAttach {
            detachPreview()
        }
    }

    private func detachPreview() {
        cancelFramePolling()
        invalidateFrameRefreshRequests()
        if isPreviewLeaseAttached, let runtime {
            _ = runtime.detach(
                consumerIdentifier: Self.previewConsumerIdentifier
            )
        }
        isPreviewLeaseAttached = false
        clearPreviewFrame()
    }

    private func invalidateFrameRefreshRequests() {
        frameRefreshRequestGeneration = frameRefreshRequestGeneration == UInt64.max
            ? 0
            : frameRefreshRequestGeneration + 1
        frameRefreshIsPending = false
        // An executing mailbox snapshot cannot be cancelled safely. Leave the
        // in-flight fence set until its completion arrives; a subsequent attach
        // records one latest-only pending read behind it.
    }

    private func clearPreviewFrame() {
        previewImage = nil
        previewFrameDescriptor = nil
        publishRendererCameraFrame(nil)
        frameConsumptionEpoch = nil
        lastConsumedFrameSequence = nil
        consecutiveStalledFrameObservations = 0
    }

    private func publishRendererCameraFrame(
        _ frame: IdleScreenRendererCameraFrame?
    ) {
        rendererCameraFrame = frame
        rendererFrameRelay.publish(frame)
    }

    private func observeFrameReadiness(
        _ readiness: CameraAgentFrameReadiness
    ) {
        guard stateMachine.snapshot.frame != readiness else { return }
        _ = stateMachine.handle(.frameObserved(
            readiness,
            serviceEpoch: stateMachine.serviceEpoch
        ))
    }

    private func retireControlAndPreview(
        preservingPreviewRequest: Bool = false
    ) {
        cancelAuthorizationPolling()
        cancelAuthorizationRefresh()
        invalidateCameraDeviceEvidence()
        if !preservingPreviewRequest
            && !preservesPreviewRequestDuringAgentReplacement {
            isPreviewLeaseRequested = false
        }
        let serviceEpoch = stateMachine.serviceEpoch
        observeFrameReadiness(.unknown)
        _ = stateMachine.handle(.controlObserved(
            .unknown,
            serviceEpoch: serviceEpoch
        ))
        detachPreview()
        retireCurrentControlSession()
        controlReachability = .unknown
        cameraAgentDiagnosticState = .notRequested
    }

    private func retireCurrentControlSession() {
        let session = controlSession
        controlSession = nil
        currentControlAttempt = nil
        controlRequestIsPending = false
        diagnosticRequestIsPending = false
        session?.invalidate()
    }

    private func cancelAuthorizationPolling() {
        authorizationStatusPollWork?.cancel()
        authorizationStatusPollWork = nil
        authorizationTimeoutWork?.cancel()
        authorizationTimeoutWork = nil
        currentAuthorizationPollingGeneration = nil
        authorizationPollingPolicy = CameraAuthorizationPollingPolicy()
    }

    /// AVFoundation does not publish a camera-authorization-change event.
    /// Keep a nonprompting observation alive for every requested preview,
    /// including Studio after a denied reply has detached its lease. That
    /// lets a Settings change remove stale frames and later reattach without
    /// requiring a page switch or app restart.
    private func scheduleAuthorizationRefresh() {
        cancelAuthorizationRefresh()
        guard isVisible,
              isPreviewSurfaceSelected,
              isPreviewLeaseRequested else { return }
        authorizationRefreshWork = scheduler.schedule(
            after: Self.authorizationRefreshInterval
        ) { [weak self] in
            guard let self,
                  isVisible,
                  isPreviewSurfaceSelected,
                  isPreviewLeaseRequested else { return }
            authorizationRefreshWork = nil
            requestAuthorizationStatus(purpose: .explicitRefresh)
            scheduleAuthorizationRefresh()
        }
    }

    private func cancelAuthorizationRefresh() {
        authorizationRefreshWork?.cancel()
        authorizationRefreshWork = nil
    }

    private func cancelFramePolling() {
        framePollWork?.cancel()
        framePollWork = nil
    }

    private func cancelCameraDevicePolling() {
        cameraDevicePollWork?.cancel()
        cameraDevicePollWork = nil
    }

    private func perform(_ action: CameraAgentOnboardingAction) {
        switch action {
        case .registerAgent:
            retireControlAndPreview()
            _ = stateMachine.handle(.serviceRegistrationBoundaryObserved(
                effects.registerAgent()
            ))
            if stateMachine.snapshot.serviceRegistration == .enabled {
                bootstrapPreviewIfNeeded()
                connectControlIfNeeded()
                requestAuthorizationStatus(purpose: .initialStatus)
                requestDiagnosticSnapshotIfNeeded()
            }

        case .requestCameraAuthorization:
            requestCameraAuthorization()

        case let .refresh(target, _):
            refresh(target)

        case let .openRepairSurface(surface):
            if surface == .cameraPrivacySettings {
                openCameraPrivacySettings()
            } else {
                _ = effects.openRepairSurface(surface)
            }
        }
    }

    private func refresh(_ target: CameraAgentReadinessRefreshTarget) {
        switch target {
        case .clientRuntime:
            retryClientRuntimeBootstrap()

        case .serviceRegistration:
            let previousEpoch = stateMachine.serviceEpoch
            _ = stateMachine.handle(.serviceRegistrationObserved(
                effects.readServiceRegistration()
            ))
            if stateMachine.serviceEpoch != previousEpoch {
                retireControlAndPreview()
            }
            if stateMachine.snapshot.serviceRegistration == .enabled {
                bootstrapPreviewIfNeeded()
                connectControlIfNeeded()
                requestAuthorizationStatus(purpose: .explicitRefresh)
                requestDiagnosticSnapshotIfNeeded()
            }

        case .identity:
            // Verification itself is read-only. A stale or mismatched enabled
            // helper reaches replaceCameraAgent() through the explicit repair
            // action; a normal retry only establishes a fresh XPC handshake.
            retireControlAndPreview()
            bootstrapPreviewIfNeeded()
            connectControlIfNeeded()
            requestDiagnosticSnapshotIfNeeded()

        case .liveSnapshot:
            connectControlIfNeeded()
            requestDiagnosticSnapshotIfNeeded()

        case .authorization:
            connectControlIfNeeded()
            requestAuthorizationStatus(purpose: .explicitRefresh)
            requestDiagnosticSnapshotIfNeeded()

        case .control:
            controlReachability = .unknown
            _ = stateMachine.handle(.controlObserved(
                .unknown,
                serviceEpoch: stateMachine.serviceEpoch
            ))
            connectControlIfNeeded()
            requestAuthorizationStatus(purpose: .explicitRefresh)
            requestDiagnosticSnapshotIfNeeded()

        case .frameReadiness:
            refreshFrameReadiness()
            scheduleFramePoll()
        }
    }

    private static func authorization(
        from status: IdleScreenCameraAuthorizationStatus
    ) -> CameraAgentAuthorization? {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .unavailable: nil
        }
    }

    private static func cameraSelection(
        from state: IdleScreenCameraDeviceSelectionState?
    ) -> IdleScreenCameraSelection? {
        guard let state else { return nil }
        switch state.mode {
        case .automatic:
            return .automatic
        case .explicitDevice:
            guard let identifier = state.deviceIdentifier else { return nil }
            return .deviceIfValid(uniqueID: identifier)
        @unknown default:
            return nil
        }
    }

    private static func frameReadiness(
        from availability: CameraFrameSourceAvailability
    ) -> CameraAgentFrameReadiness {
        switch availability {
        case .waitingForFrame:
            .awaitingFirstFrame
        case .available:
            .ready
        case .unavailable(.firstFrameTimedOut),
             .unavailable(.staleFrame):
            .stalled
        case .unavailable:
            .unavailable
        }
    }
}
