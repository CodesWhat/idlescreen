import AppKit
import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import MetalKit
import OSLog
import QuartzCore
import ScreenSaver

private let viewLogger = Logger(subsystem: "com.idlescreen.screensaver", category: "View")

/// Read-only, process-global state from Tahoe's screen-saver controller. This
/// remains diagnostic because Tahoe reports active hosted saver views as
/// inactive in some real full-screen sessions.
enum IdleScreenSaverGlobalHostActivity: String, CaseIterable, Sendable {
    case unavailable
    case inactive
    case runningForeground = "running-foreground"
    case runningBackground = "running-background"
    case inconsistent

    static func classify(
        controllerAvailable: Bool,
        isRunning: Bool?,
        isRunningInBackground: Bool?
    ) -> Self {
        guard controllerAvailable,
              let isRunning,
              let isRunningInBackground else {
            return .unavailable
        }
        switch (isRunning, isRunningInBackground) {
        case (false, false): return .inactive
        case (true, false): return .runningForeground
        case (true, true): return .runningBackground
        case (false, true): return .inconsistent
        }
    }
}

enum IdleScreenSaverGlobalHostActivityReader {
    static func read() -> IdleScreenSaverGlobalHostActivity {
        switch IdleScreenReadGlobalHostActivity() {
        case 1: .inactive
        case 2: .runningForeground
        case 3: .runningBackground
        case 4: .inconsistent
        default: .unavailable
        }
    }
}

struct IdleScreenDisplayGeometry: Equatable {
    let identifier: CGDirectDisplayID
    let bounds: CGRect
}

enum IdleScreenDisplayResolver {
    static func resolve(
        windowFrame: CGRect,
        displays: [IdleScreenDisplayGeometry]
    ) -> CGDirectDisplayID? {
        let origin = windowFrame.origin
        if let exact = displays.first(where: {
            abs($0.bounds.origin.x - origin.x) < 0.5
                && abs($0.bounds.origin.y - origin.y) < 0.5
        }) {
            return exact.identifier
        }

        let midpoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return displays.first(where: { $0.bounds.contains(midpoint) })?.identifier
    }

    static func liveDisplays() -> [IdleScreenDisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let identifier = number.uint32Value
            return IdleScreenDisplayGeometry(
                identifier: identifier,
                bounds: CGDisplayBounds(identifier)
            )
        }
    }
}

/// The Tahoe App Extension host does not expose a documented, trustworthy way
/// to distinguish its chooser surface from a full-screen saver session. In
/// particular, the chooser can supply full-display bounds while `isPreview` is
/// `false`. Camera demand therefore requires positive provenance supplied by a
/// future activation boundary; the shipping host currently remains unverified.
#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
enum IdleScreenSaverCameraHostContext: Equatable, Sendable {
    case unverifiedHostedSurface
    case explicitlyVerifiedFullScreen
}

enum IdleScreenSaverCameraDemandPolicy {
    static func permitsCamera(
        source: IdleScreenSource,
        hostContext: IdleScreenSaverCameraHostContext,
        isPreviewHint: Bool
    ) -> Bool {
        guard !isPreviewHint,
              hostContext == .explicitlyVerifiedFullScreen else {
            return false
        }

        return source == .camera
    }
}
#endif

struct IdleScreenSaverDiagnosticState: Equatable {
    let lifecycle: IdleScreenLifecyclePhase
    let isPreview: Bool
    let instanceIdentifier: String
    let displayIdentifier: UInt32?
    let persistentDisplayIdentifier: String?
    let topologyGeneration: UInt64?
    let sceneRole: String?
    let sceneSeed: UInt64
    let sceneBrightness: Double
    let globalHostActivity: IdleScreenSaverGlobalHostActivity
    let renderedGlyphField: String
    let cameraProducerStreamEpoch: UInt64?
    let cameraFrameSequence: UInt64?
    let cameraFrameChecksum: UInt64?
    let cameraSampledPixelCount: Int?
}

final class IdleScreenSaverView: ScreenSaverView {
    typealias CameraDiagnosticClock = () -> TimeInterval
    typealias CameraDiagnosticSink = (
        _ instanceIdentifier: String,
        _ displayIdentifier: UInt32?,
        _ event: IdleScreenSaverCameraDiagnosticEvent
    ) -> Void
    typealias HostActivityReader = () -> IdleScreenSaverGlobalHostActivity
    typealias HostActivityClock = () -> CFTimeInterval
    typealias AgentClock = () -> Date
    typealias BackingScaleProvider = (NSWindow?) -> CGFloat

    private static let hostActivityObservationInterval: CFTimeInterval = 0.5
    private static let fallbackGlyphRamp = Array(" .:-=+*#%@")

    private var lifecycle = IdleScreenLifecycleMachine()
    private var animationStartedAt: CFTimeInterval?
    private let rendererView = MTKView(frame: .zero)
    private var renderer: IdleScreenRenderer?
    private var hasSubmittedRendererFrame = false
    private var renderAttemptGeneration: UInt64 = 0
#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
    private(set) var rendererFrameConfigurationResolutionCount = 0
#endif
    private var hasScheduledInitialLayoutRecoveryDraw = false
    private let gradientLayer = CAGradientLayer()
    private let glyphLayer = CATextLayer()
    private let titleLayer = CATextLayer()
    private let agentOverlayLayer = CATextLayer()
    private let isPreviewMode: Bool
#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
    private let syntheticCameraHostContext: IdleScreenSaverCameraHostContext
#endif
    private let instanceIdentifier = UUID().uuidString.lowercased()
    private var cameraConsumer: IdleScreenSaverCameraConsumer?
    private var lastCameraSample: IdleScreenCameraGlyphSample?
    private var cameraFrameChecksum: UInt64?
    private var cameraDiagnosticPolicy = IdleScreenSaverCameraDiagnosticPolicy()
    private let cameraDiagnosticClock: CameraDiagnosticClock
    private let cameraDiagnosticSink: CameraDiagnosticSink
    private let hostActivityReader: HostActivityReader
    private let hostActivityClock: HostActivityClock
    private let agentClock: AgentClock
    private let backingScaleProvider: BackingScaleProvider
    private var globalHostActivity: IdleScreenSaverGlobalHostActivity
    private var lastHostActivityObservationAt: CFTimeInterval?
    private var displayIdentifier: UInt32?
    private var persistentDisplayIdentifier: DisplayTopology.PersistentDisplayIdentifier?
    private var agentOverlayTopologyGeneration: UInt64?
    private let displayCoordinator: DisplaySceneCoordinator?
    private let pixelMaterialsCoordinator: IdleScreenPixelMaterialsSceneCoordinator
    private var displayHostToken: DisplaySceneHostToken?
    private let injectedDisplayHostFrame: DisplayTopology.Rect?
    private var displayResolutionWorkItem: DispatchWorkItem?
    private var sharedPaths: IdleScreenSharedPaths?
    private var configurationMonitor: IdleScreenConfigurationMonitor?
    private var agentSignalMonitor: IdleScreenAgentSignalMonitor?
    private var activeAgentSignal: IdleScreenAgentSignal?
    private var configuration: IdleScreenConfiguration

    private(set) var agentOverlayPresentation: IdleScreenAgentOverlayPresentation?
    private(set) var agentOverlayApplicationCount = 0
    var agentOverlayFrame: CGRect { agentOverlayLayer.frame }
    var agentOverlayContentsScale: CGFloat { agentOverlayLayer.contentsScale }

    override func isAccessibilityElement() -> Bool {
        agentOverlayPresentation != nil
    }

    override func accessibilityLabel() -> String? {
        agentOverlayPresentation?.accessibilityLabel
    }

    var diagnosticState: IdleScreenSaverDiagnosticState {
        IdleScreenSaverDiagnosticState(
            lifecycle: lifecycle.phase,
            isPreview: isPreviewMode,
            instanceIdentifier: instanceIdentifier,
            displayIdentifier: displayIdentifier,
            persistentDisplayIdentifier: persistentDisplayIdentifier?.rawValue,
            topologyGeneration: displayCoordinator?.latestPlan?.topologyGeneration,
            sceneRole: displayAssignment.map(Self.sceneRoleLabel),
            sceneSeed: rendererConfiguration.sceneSeed,
            sceneBrightness: rendererConfiguration.sceneBrightness,
            globalHostActivity: globalHostActivity,
            renderedGlyphField: glyphLayer.string as? String ?? "",
            cameraProducerStreamEpoch: lastCameraSample?.producerStreamEpoch,
            cameraFrameSequence: lastCameraSample?.sequence,
            cameraFrameChecksum: cameraFrameChecksum,
            cameraSampledPixelCount: lastCameraSample?.sampledPixelCount
        )
    }

    override init?(frame: NSRect, isPreview: Bool) {
        isPreviewMode = isPreview
        displayCoordinator = .shared
        pixelMaterialsCoordinator = .shared
        injectedDisplayHostFrame = nil
#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
        syntheticCameraHostContext = .unverifiedHostedSurface
#endif
        configuration = .default
        cameraDiagnosticClock = { CACurrentMediaTime() }
        cameraDiagnosticSink = Self.logCameraDiagnostic
        hostActivityReader = IdleScreenSaverGlobalHostActivityReader.read
        hostActivityClock = { CACurrentMediaTime() }
        agentClock = Date.init
        backingScaleProvider = { $0?.backingScaleFactor ?? 2 }
        globalHostActivity = hostActivityReader()
        let cameraClient = IdleScreenSaverCameraProcess.shared.client
        super.init(frame: frame, isPreview: isPreview)
        cameraConsumer = cameraClient.map {
            IdleScreenSaverCameraConsumer(
                client: $0,
                identifier: instanceIdentifier
            )
        }
        animationTimeInterval = 1 / 30
        wantsLayer = true
        configureLayers()
        connectSharedState()
        refreshAgentSignal(at: agentClock())
        attachDisplayCoordinationIfNeeded()
        lifecycle.apply(.attach)
        publishHealth()
        renderFrame(elapsed: 0)
        logGlobalHostActivity(source: "initialize", changed: false)
    }

#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
    init?(
        frame: NSRect,
        isPreview: Bool,
        cameraClient: IdleScreenSaverCameraClient?,
        configuration: IdleScreenConfiguration = .default,
        cameraHostContext: IdleScreenSaverCameraHostContext =
            .unverifiedHostedSurface,
        displayCoordinator: DisplaySceneCoordinator? = nil,
        displayHostFrame: DisplayTopology.Rect? = nil,
        pixelMaterialsCoordinator: IdleScreenPixelMaterialsSceneCoordinator = .shared,
        agentSignalStore: IdleScreenAgentSignalStore? = nil,
        agentClock: @escaping AgentClock = Date.init,
        backingScaleProvider: @escaping BackingScaleProvider = {
            $0?.backingScaleFactor ?? 2
        },
        hostActivityReader: @escaping HostActivityReader =
            IdleScreenSaverGlobalHostActivityReader.read,
        hostActivityClock: @escaping HostActivityClock = {
            CACurrentMediaTime()
        },
        cameraDiagnosticClock: @escaping CameraDiagnosticClock = {
            CACurrentMediaTime()
        },
        cameraDiagnosticSink: @escaping CameraDiagnosticSink =
            IdleScreenSaverView.logCameraDiagnostic
    ) {
        isPreviewMode = isPreview
        syntheticCameraHostContext = cameraHostContext
        self.displayCoordinator = displayCoordinator
        self.pixelMaterialsCoordinator = pixelMaterialsCoordinator
        injectedDisplayHostFrame = displayHostFrame
        self.configuration = configuration
        self.hostActivityReader = hostActivityReader
        self.hostActivityClock = hostActivityClock
        self.agentClock = agentClock
        self.backingScaleProvider = backingScaleProvider
        agentSignalMonitor = agentSignalStore.map {
            IdleScreenAgentSignalMonitor(store: $0)
        }
        globalHostActivity = hostActivityReader()
        self.cameraDiagnosticClock = cameraDiagnosticClock
        self.cameraDiagnosticSink = cameraDiagnosticSink
        super.init(frame: frame, isPreview: isPreview)
        cameraConsumer = cameraClient.map {
            IdleScreenSaverCameraConsumer(
                client: $0,
                identifier: instanceIdentifier
            )
        }
        animationTimeInterval = 1 / 30
        wantsLayer = true
        configureLayers()
        connectSharedState()
        refreshAgentSignal(at: agentClock())
        attachDisplayCoordinationIfNeeded()
        lifecycle.apply(.attach)
        publishHealth()
        renderFrame(elapsed: 0)
        logGlobalHostActivity(source: "initialize", changed: false)
    }
#endif

    required init?(coder: NSCoder) {
        isPreviewMode = false
        displayCoordinator = .shared
        pixelMaterialsCoordinator = .shared
        injectedDisplayHostFrame = nil
#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
        syntheticCameraHostContext = .unverifiedHostedSurface
#endif
        configuration = .default
        cameraDiagnosticClock = { CACurrentMediaTime() }
        cameraDiagnosticSink = Self.logCameraDiagnostic
        hostActivityReader = IdleScreenSaverGlobalHostActivityReader.read
        hostActivityClock = { CACurrentMediaTime() }
        agentClock = Date.init
        backingScaleProvider = { $0?.backingScaleFactor ?? 2 }
        globalHostActivity = hostActivityReader()
        let cameraClient = IdleScreenSaverCameraProcess.shared.client
        super.init(coder: coder)
        cameraConsumer = cameraClient.map {
            IdleScreenSaverCameraConsumer(
                client: $0,
                identifier: instanceIdentifier
            )
        }
        animationTimeInterval = 1 / 30
        wantsLayer = true
        configureLayers()
        connectSharedState()
        refreshAgentSignal(at: agentClock())
        attachDisplayCoordinationIfNeeded()
        lifecycle.apply(.attach)
        publishHealth()
        renderFrame(elapsed: 0)
        logGlobalHostActivity(source: "initialize", changed: false)
    }

    deinit {
        guard let displayCoordinator, let displayHostToken else { return }
        MainActor.assumeIsolated {
            displayCoordinator.detach(displayHostToken)
        }
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        return layer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refreshLayerContentsScale()
        layoutAgentOverlay()
        CATransaction.commit()
    }

    override func startAnimation() {
        guard lifecycle.phase != .animating else { return }
        super.startAnimation()
        attachDisplayCoordinationIfNeeded()
        ensureRenderer()
        if lifecycle.phase == .detached {
            lifecycle.apply(.attach)
        }
        refreshConfiguration(at: CACurrentMediaTime())
        refreshAgentSignal(at: agentClock())
        refreshGlobalHostActivity(
            source: "start-animation",
            observedAt: hostActivityClock()
        )
        lifecycle.apply(.startAnimating)
        reconcileCameraDemand()
        animationStartedAt = CACurrentMediaTime()
        publishHealth()
        viewLogger.info(
            "Animation started preview=\(self.isPreviewMode, privacy: .public) instance=\(self.instanceIdentifier, privacy: .public) display=\(self.displayLogValue, privacy: .public)"
        )
    }

    override func stopAnimation() {
        guard lifecycle.phase == .animating else { return }
        lifecycle.apply(.stopAnimating)
        detachCameraIfNeeded()
        shutdownRenderer()
        animationStartedAt = nil
        publishHealth()
        super.stopAnimation()
        viewLogger.info(
            "Animation stopped preview=\(self.isPreviewMode, privacy: .public) instance=\(self.instanceIdentifier, privacy: .public) display=\(self.displayLogValue, privacy: .public)"
        )
    }

    override func animateOneFrame() {
        guard lifecycle.phase == .animating, let animationStartedAt else { return }
        let now = CACurrentMediaTime()
        refreshConfiguration(at: now)
        refreshAgentSignal(at: agentClock())
        resolvePersistentDisplayIdentity(
            frame: injectedDisplayHostFrame
                ?? window.map { Self.topologyFrame($0.screen?.frame ?? $0.frame) }
        )
        refreshGlobalHostActivityIfDue(at: hostActivityClock())
        reconcileCameraDemand()
        if cameraDemandEnabled {
            let cameraRead = cameraConsumer?.sample(
                columns: isPreviewMode ? 24 : 54,
                rows: isPreviewMode ? 9 : 18
            ) ?? .unavailable
            switch cameraRead {
            case let .frame(sample):
                lastCameraSample = sample
            case .noNewFrame:
                break
            case .unavailable:
                // CameraFrameSource already applies the bounded freshness
                // threshold. Once it reports unavailable, the retained sample
                // is confirmed stale and must not survive another render.
                lastCameraSample = nil
                renderer?.clearCameraFrame()
            }
            emitCameraDiagnosticIfDue()
        }
        renderFrame(
            elapsed: now - animationStartedAt,
            cameraSample: lastCameraSample
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayResolutionWorkItem?.cancel()
        displayResolutionWorkItem = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        if window == nil {
            if lifecycle.phase == .animating {
                stopAnimation()
            }
            detachCameraIfNeeded()
            detachDisplayCoordinationIfNeeded()
            lifecycle.apply(.detach)
            publishHealth()
        } else if lifecycle.phase == .detached {
            lifecycle.apply(.attach)
        }

        if let window {
            attachDisplayCoordinationIfNeeded()
            displayIdentifier = nil
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            scheduleDisplayResolution()
        }

        if window != nil, lifecycle.phase != .animating {
            startAnimation()
        }
        viewLogger.info(
            "View attachment changed attached=\(self.window != nil, privacy: .public) instance=\(self.instanceIdentifier, privacy: .public) display=\(self.displayLogValue, privacy: .public)"
        )
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        resolveDisplayIdentity(source: "window-screen-change")
    }

    private func scheduleDisplayResolution() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.resolveDisplayIdentity(source: "settled-fallback")
        }
        displayResolutionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func resolveDisplayIdentity(source: String) {
        guard let window else { return }
        resolvePersistentDisplayIdentity(frame: Self.topologyFrame(window.screen?.frame ?? window.frame))
        guard let resolvedIdentifier = IdleScreenDisplayResolver.resolve(
            windowFrame: window.frame,
            displays: IdleScreenDisplayResolver.liveDisplays()
        ) else {
            viewLogger.error(
                "Display resolution failed instance=\(self.instanceIdentifier, privacy: .public) originX=\(window.frame.origin.x, privacy: .public) originY=\(window.frame.origin.y, privacy: .public) source=\(source, privacy: .public)"
            )
            return
        }

        displayResolutionWorkItem?.cancel()
        displayResolutionWorkItem = nil
        guard displayIdentifier != resolvedIdentifier else { return }
        displayIdentifier = resolvedIdentifier
        publishHealth()
        viewLogger.info(
            "Display resolved instance=\(self.instanceIdentifier, privacy: .public) display=\(resolvedIdentifier, privacy: .public) originX=\(window.frame.origin.x, privacy: .public) originY=\(window.frame.origin.y, privacy: .public) source=\(source, privacy: .public)"
        )
    }

    private func resolvePersistentDisplayIdentity(
        frame: DisplayTopology.Rect?
    ) {
        let resolvedIdentifier = frame.flatMap {
            displayCoordinator?.representativeIdentifier(for: $0)
        }
        let resolvedGeneration = displayCoordinator?.latestPlan?.topologyGeneration
        let overlayGeometryChanged = resolvedIdentifier != persistentDisplayIdentifier
            || resolvedGeneration != agentOverlayTopologyGeneration
        persistentDisplayIdentifier = resolvedIdentifier
        agentOverlayTopologyGeneration = resolvedGeneration
        if overlayGeometryChanged {
            layoutAgentOverlay()
        }
    }

    private static func topologyFrame(_ frame: CGRect) -> DisplayTopology.Rect {
        .init(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }

    private func attachDisplayCoordinationIfNeeded() {
        guard let displayCoordinator, displayHostToken == nil else { return }
        displayHostToken = displayCoordinator.attach(
            settings: configuration.display,
            configurationRevision: configuration.revision
        )
        resolvePersistentDisplayIdentity(
            frame: injectedDisplayHostFrame
                ?? window.map { Self.topologyFrame($0.screen?.frame ?? $0.frame) }
        )
    }

    private func detachDisplayCoordinationIfNeeded() {
        guard let displayCoordinator, let displayHostToken else { return }
        displayCoordinator.detach(displayHostToken)
        self.displayHostToken = nil
        persistentDisplayIdentifier = nil
        agentOverlayTopologyGeneration = nil
    }

    private var displayAssignment: DisplaySceneAssignment? {
        guard let persistentDisplayIdentifier else { return nil }
        return displayCoordinator?.latestPlan?.assignment(
            for: persistentDisplayIdentifier
        )
    }

    private static func sceneRoleLabel(
        _ assignment: DisplaySceneAssignment
    ) -> String {
        switch assignment.role {
        case .panorama: "panorama"
        case .independent: "independent"
        case .focus: "focus"
        case .quiet(.black): "quiet-black"
        case .quiet(.subdued): "quiet-subdued"
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rendererView.frame = bounds
        gradientLayer.frame = bounds
        glyphLayer.frame = bounds.insetBy(
            dx: bounds.width * 0.06,
            dy: bounds.height * 0.08
        )
        titleLayer.frame = NSRect(
            x: 24,
            y: 20,
            width: max(0, bounds.width - 48),
            height: 28
        )
        layoutAgentOverlay()
        CATransaction.commit()

        scheduleInitialLayoutRecoveryDrawIfNeeded()
    }

    private func configureLayers() {
        rendererView.frame = bounds
        rendererView.autoresizingMask = [.width, .height]
        rendererView.wantsLayer = true
        addSubview(rendererView)
        rendererView.layer?.zPosition = 0

        ensureRenderer()

        guard let layer else { return }
        gradientLayer.type = .axial
        gradientLayer.zPosition = 10
        layer.addSublayer(gradientLayer)

        glyphLayer.alignmentMode = .center
        updateTypography()
        glyphLayer.isWrapped = true
        glyphLayer.truncationMode = .none
        glyphLayer.opacity = 0.72
        glyphLayer.zPosition = 11
        layer.addSublayer(glyphLayer)

        titleLayer.string = "idlescreen  /  modern extension"
        titleLayer.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLayer.fontSize = 12
        titleLayer.foregroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        titleLayer.alignmentMode = .left
        titleLayer.zPosition = 12
        layer.addSublayer(titleLayer)

        agentOverlayLayer.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        agentOverlayLayer.fontSize = 13
        agentOverlayLayer.alignmentMode = .left
        agentOverlayLayer.isWrapped = true
        agentOverlayLayer.truncationMode = .end
        agentOverlayLayer.cornerRadius = 14
        agentOverlayLayer.borderWidth = 1
        agentOverlayLayer.zPosition = 30
        agentOverlayLayer.isHidden = true
        layer.addSublayer(agentOverlayLayer)
        needsLayout = true
    }

    private func renderFrame(
        elapsed: TimeInterval,
        cameraSample: IdleScreenCameraGlyphSample? = nil
    ) {
        renderAttemptGeneration &+= 1
        let frameConfiguration = rendererConfiguration
        let frame = IdleScreenAnimationFrame.sample(at: elapsed)
        let sceneBrightness = frameConfiguration.sceneBrightness
        let dark = NSColor(
            calibratedHue: frame.backgroundHue,
            saturation: 0.76,
            brightness: 0.12 * sceneBrightness,
            alpha: 1
        )
        let glow = NSColor(
            calibratedHue: frame.accentHue,
            saturation: 0.72,
            brightness: 0.76 * sceneBrightness,
            alpha: 1
        )
        if let renderer {
            renderer.update(configuration: frameConfiguration)
            renderer.update(mode: rendererMode(hasCameraFrame: cameraSample != nil))
            if let rendererFrame = cameraSample?.rendererFrame {
                renderer.submit(cameraFrame: rendererFrame)
            } else {
                renderer.clearCameraFrame()
            }
            if renderer.draw(at: elapsed) {
                hasSubmittedRendererFrame = true
            }
        }
        let showsLayerFallback = !hasSubmittedRendererFrame

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.isHidden = !showsLayerFallback
        glyphLayer.isHidden = !showsLayerFallback
        gradientLayer.colors = [dark.cgColor, NSColor.black.cgColor, dark.cgColor]
        gradientLayer.startPoint = CGPoint(x: frame.progress, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1 - frame.progress, y: 1)
        glyphLayer.foregroundColor = glow.cgColor
        // The layer fallback is procedural-only. Do not rebuild its CPU glyph
        // string while the Metal renderer is presenting successfully.
        if showsLayerFallback {
            glyphLayer.string = proceduralFallbackGlyphField(
                elapsed: elapsed,
                rendererConfiguration: frameConfiguration
            )
        }
        cameraFrameChecksum = cameraSample?.checksum
        refreshLayerContentsScale()
        CATransaction.commit()
    }

    /// Tahoe can lay out the chooser after the eager initialization draw was
    /// discarded with a zero-sized drawable. Schedule exactly one recovery
    /// attempt after the first real layout. If an animation tick renders first,
    /// its generation change coalesces this attempt instead of issuing a second
    /// draw on the main thread. Later layouts and resizes never trigger draws.
    private func scheduleInitialLayoutRecoveryDrawIfNeeded() {
        guard !hasScheduledInitialLayoutRecoveryDraw,
              bounds.width >= 1,
              bounds.height >= 1 else {
            return
        }
        hasScheduledInitialLayoutRecoveryDraw = true
        let scheduledGeneration = renderAttemptGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.renderAttemptGeneration == scheduledGeneration else {
                return
            }
            let elapsed = self.animationStartedAt.map {
                max(0, CACurrentMediaTime() - $0)
            } ?? 0
            self.renderFrame(
                elapsed: elapsed,
                cameraSample: self.lastCameraSample
            )
        }
    }

    var rendererConfiguration: IdleScreenRendererConfiguration {
#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
        rendererFrameConfigurationResolutionCount += 1
#endif
        let presentedConfiguration = agentOverlayPresentation == nil
            ? configuration
            : IdleScreenAgentPresentationPolicy.configuration(
                configuration,
                applyingTemporaryLookFrom: activeAgentSignal
            )
        return IdleScreenRendererConfigurationBridge.configuration(
            for: presentedConfiguration,
            assignment: displayAssignment
        )
    }

#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
    func rendererConfigurationResolutionCountForOneTestFrame() -> Int {
        let before = rendererFrameConfigurationResolutionCount
        renderFrame(elapsed: 0)
        return rendererFrameConfigurationResolutionCount - before
    }
#endif

    private func rendererMode(hasCameraFrame: Bool) -> IdleScreenRendererMode {
        if case .quiet = displayAssignment?.role {
            return .generative
        }
        return switch configuration.source {
        case .generative: .generative
        case .camera: hasCameraFrame ? .camera : .generative
        }
    }

    private func ensureRenderer() {
        guard renderer == nil else { return }
        do {
            renderer = try IdleScreenRenderer(
                metalView: rendererView,
                configuration: rendererConfiguration,
                mode: rendererMode(hasCameraFrame: lastCameraSample != nil),
                automaticallyDraws: false,
                pixelMaterialsCoordinator: pixelMaterialsCoordinator
            )
        } catch {
            viewLogger.error(
                "Metal renderer unavailable; retaining procedural layer fallback: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func shutdownRenderer() {
        renderer?.shutdown()
        renderer = nil
        hasSubmittedRendererFrame = false
    }

    private var cameraDemandEnabled: Bool {
        if case .quiet = displayAssignment?.role {
            return false
        }
#if IDLESCREEN_SYNTHETIC_HOSTED_GATE
        return IdleScreenSaverCameraDemandPolicy.permitsCamera(
            source: configuration.source,
            hostContext: syntheticCameraHostContext,
            isPreviewHint: isPreviewMode
        )
#else
        return configuration.source == .camera
#endif
    }

    private func reconcileCameraDemand() {
        if cameraDemandEnabled {
            cameraConsumer?.attach()
        } else {
            detachCameraIfNeeded()
            cameraDiagnosticPolicy = IdleScreenSaverCameraDiagnosticPolicy()
        }
    }

    private func detachCameraIfNeeded() {
        cameraConsumer?.detach()
        lastCameraSample = nil
        cameraFrameChecksum = nil
        renderer?.clearCameraFrame()
    }

    private func refreshGlobalHostActivity(
        source: String,
        observedAt: CFTimeInterval? = nil,
        logWhenUnchanged: Bool = true
    ) {
        let observation = hostActivityReader()
        let changed = observation != globalHostActivity
        globalHostActivity = observation
        if let observedAt {
            lastHostActivityObservationAt = observedAt
        }
        if changed || logWhenUnchanged {
            logGlobalHostActivity(source: source, changed: changed)
        }
    }

    private func refreshGlobalHostActivityIfDue(at now: CFTimeInterval) {
        if let lastHostActivityObservationAt {
            let elapsed = now - lastHostActivityObservationAt
            if elapsed >= 0,
               elapsed < Self.hostActivityObservationInterval {
                return
            }
        }
        refreshGlobalHostActivity(
            source: "animation-frame",
            observedAt: now,
            logWhenUnchanged: false
        )
    }

    private func logGlobalHostActivity(source: String, changed: Bool) {
        viewLogger.info(
            "Global host activity state=\(self.globalHostActivity.rawValue, privacy: .public) source=\(source, privacy: .public) changed=\(changed, privacy: .public) cameraDemand=\(self.cameraDemandEnabled, privacy: .public)"
        )
    }

    private func emitCameraDiagnosticIfDue() {
        let observedEvent = lastCameraSample?.diagnosticEvent
            ?? .fallbackUnavailable
        guard let event = cameraDiagnosticPolicy.emission(
            for: observedEvent,
            at: cameraDiagnosticClock()
        ) else {
            return
        }
        cameraDiagnosticSink(instanceIdentifier, displayIdentifier, event)
    }

    nonisolated private static func logCameraDiagnostic(
        instanceIdentifier: String,
        displayIdentifier: UInt32?,
        event: IdleScreenSaverCameraDiagnosticEvent
    ) {
        let display = displayIdentifier.map(String.init) ?? "unknown"
        viewLogger.info(
            "\(event.logMessage, privacy: .public) instance=\(instanceIdentifier, privacy: .public) display=\(display, privacy: .public)"
        )
    }

    private func connectSharedState() {
        let bundle = Bundle(for: IdleScreenSaverView.self)
        guard Self.boolInfoValue(bundle.object(forInfoDictionaryKey: "IdleScreenSharedContainerEnabled")) else {
            viewLogger.info("Shared container access is disabled for this build configuration")
            return
        }
        guard let identifier = bundle.object(forInfoDictionaryKey: "IdleScreenAppGroupIdentifier") as? String else {
            viewLogger.error("Extension bundle is missing IdleScreenAppGroupIdentifier")
            return
        }
        sharedPaths = IdleScreenSharedContainer.locate(appGroupIdentifier: identifier)
        if sharedPaths == nil {
            viewLogger.error("Shared container is unavailable for \(identifier, privacy: .public)")
        }
        if let sharedPaths {
            configurationMonitor = IdleScreenConfigurationMonitor(
                store: IdleScreenConfigurationStore(fileURL: sharedPaths.configurationURL)
            )
            if agentSignalMonitor == nil {
                agentSignalMonitor = IdleScreenAgentSignalMonitor(
                    store: IdleScreenAgentSignalStore(
                        fileURL: sharedPaths.agentSignalsInboxURL
                    )
                )
            }
            refreshConfiguration(at: CACurrentMediaTime())
        }
    }

    private static func boolInfoValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return ["YES", "TRUE", "1"].contains(value.uppercased())
        }
        return false
    }

    private func refreshConfiguration(at monotonicTime: TimeInterval) {
        guard configurationMonitor != nil else { return }
        do {
            guard let updated = try configurationMonitor?.readChange(at: monotonicTime) else {
                return
            }
            if updated.source != configuration.source {
                detachCameraIfNeeded()
                cameraDiagnosticPolicy = IdleScreenSaverCameraDiagnosticPolicy()
            }
            configuration = updated
            _ = displayCoordinator?.update(
                settings: updated.display,
                configurationRevision: updated.revision
            )
            updateTypography()
            publishHealth()
            viewLogger.info("Configuration loaded revision=\(updated.revision, privacy: .public)")
        } catch {
            viewLogger.error("Unable to read configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshAgentSignal(at date: Date) {
        guard var monitor = agentSignalMonitor else {
            applyAgentPresentation(nil)
            return
        }
        do {
            if let change = try monitor.poll(at: date) {
                activeAgentSignal = change.signal
            }
            agentSignalMonitor = monitor
            guard let signal = activeAgentSignal else {
                applyAgentPresentation(nil)
                return
            }
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            let presentation = IdleScreenAgentPresentationPolicy.presentation(
                for: signal,
                configuration: configuration.agentIntegration,
                at: date,
                minuteOfDay: minute
            )
            guard IdleScreenAgentPresentationPolicy.isVisible(
                destination: configuration.agentIntegration.displayDestination,
                display: agentDisplayContext
            ) else {
                applyAgentPresentation(nil)
                return
            }
            applyAgentPresentation(presentation)
        } catch {
            activeAgentSignal = nil
            applyAgentPresentation(nil)
            viewLogger.error(
                "Unable to read AgentSignal inbox: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private var currentAgentDisplay: DisplayTopology.Display? {
        persistentDisplayIdentifier.flatMap { identifier in
            displayCoordinator?.latestSnapshot?.topology.displays.first {
                $0.persistentIdentifier == identifier
            }
        }
    }

    private var agentDisplayContext: IdleScreenAgentDisplayContext {
        let display = currentAgentDisplay
        let isFocus = displayAssignment?.ownsFocalElement == true || {
            guard let role = displayAssignment?.role else { return false }
            if case .focus = role { return true }
            return false
        }()
        return IdleScreenAgentDisplayContext(
            isPrimary: display?.isPrimary ?? true,
            isFocus: isFocus || displayCoordinator?.latestSnapshot == nil
        )
    }

    private func applyAgentPresentation(
        _ presentation: IdleScreenAgentOverlayPresentation?
    ) {
        guard presentation != agentOverlayPresentation else { return }
        agentOverlayPresentation = presentation
        agentOverlayApplicationCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let presentation else {
            agentOverlayLayer.isHidden = true
            agentOverlayLayer.string = nil
            CATransaction.commit()
            setAccessibilityElement(false)
            setAccessibilityLabel(nil)
            return
        }
        let lines = [presentation.providerLabel, presentation.title, presentation.message]
            .compactMap { $0 }
        agentOverlayLayer.string = lines.joined(separator: "\n")
        agentOverlayLayer.foregroundColor = NSColor.white.cgColor
        agentOverlayLayer.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        agentOverlayLayer.borderColor = agentColor(for: presentation.style)
            .withAlphaComponent(0.72).cgColor
        agentOverlayLayer.isHidden = false
        layoutAgentOverlay()
        CATransaction.commit()
        setAccessibilityElement(true)
        setAccessibilityLabel(presentation.accessibilityLabel)
    }

    private func layoutAgentOverlay() {
        guard let presentation = agentOverlayPresentation else { return }
        agentOverlayLayer.contentsScale = backingScaleProvider(window)
        let inset: CGFloat = isPreviewMode ? 14 : 28
        let safeArea = currentAgentDisplay?.safeAreaInsets ?? .zero
        let leadingInset = inset + CGFloat(safeArea.left)
        let trailingInset = inset + CGFloat(safeArea.right)
        let topInset = inset + CGFloat(safeArea.top)
        let bottomInset = inset + CGFloat(safeArea.bottom)
        let width = min(
            isPreviewMode ? 260 : 380,
            max(0, bounds.width - leadingInset - trailingInset)
        )
        let height: CGFloat = presentation.message == nil ? 58 : 86
        let x: CGFloat
        let y: CGFloat
        switch presentation.position {
        case .topLeading:
            x = leadingInset
            y = max(bottomInset, bounds.height - topInset - height)
        case .topTrailing:
            x = max(leadingInset, bounds.width - trailingInset - width)
            y = max(bottomInset, bounds.height - topInset - height)
        case .bottomLeading:
            x = leadingInset
            y = bottomInset
        case .bottomTrailing:
            x = max(leadingInset, bounds.width - trailingInset - width)
            y = bottomInset
        }
        agentOverlayLayer.frame = CGRect(x: x, y: y, width: width, height: height)
    }

    private func refreshLayerContentsScale() {
        let scale = backingScaleProvider(window)
        glyphLayer.contentsScale = scale
        titleLayer.contentsScale = scale
        agentOverlayLayer.contentsScale = scale
    }

    private func agentColor(for style: IdleScreenAgentVisualStyle) -> NSColor {
        switch style {
        case .subtle: .secondaryLabelColor
        case .active: .systemCyan
        case .attention: .systemOrange
        case .success: .systemGreen
        case .failure: .systemRed
        case .hidden: .clear
        }
    }

    private func updateTypography() {
        let baseSize = isPreviewMode ? 14.0 : 26.0
        let fontSize = baseSize * (0.65 + configuration.appearance.glyphScale)
        glyphLayer.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        glyphLayer.fontSize = fontSize
        glyphLayer.opacity = Float(0.42 + configuration.appearance.contrast * 0.5)
    }

    private func publishHealth() {
        guard let sharedPaths else { return }
        let bundle = Bundle(for: IdleScreenSaverView.self)
        let report = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            instanceIdentifier: instanceIdentifier,
            displayIdentifier: displayIdentifier,
            lifecycle: diagnosticState.lifecycle,
            build: IdleScreenBuildIdentity(
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                bundleIdentifier: bundle.bundleIdentifier ?? "unknown"
            ),
            updatedAt: Date(),
            configurationRevision: configuration.revision,
            issue: nil
        )
        do {
            try IdleScreenHealthStore(directoryURL: sharedPaths.healthDirectoryURL).write(report)
        } catch {
            viewLogger.error("Unable to publish health: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var displayLogValue: String {
        displayIdentifier.map(String.init) ?? "unknown"
    }

    /// Keeps the emergency non-Metal layer truthful to the selected creative
    /// pattern. Camera bytes still never enter this fallback path, but the
    /// configured procedural fallback no longer collapses to an unrelated
    /// single-glyph animation when Metal initialization fails.
    private func proceduralFallbackGlyphField(
        elapsed: TimeInterval,
        rendererConfiguration: IdleScreenRendererConfiguration
    ) -> String {
        let columns = isPreviewMode ? 24 : 54
        let rows = isPreviewMode ? 9 : 18
        let settings = rendererConfiguration.proceduralSettings

        return (0..<rows).map { row in
            (0..<columns).map { column in
                let sample = IdleScreenProceduralPatterns.cellSample(
                    patternRawValue: rendererConfiguration.patternRawValue,
                    settings: settings,
                    column: column,
                    row: row,
                    columns: columns,
                    rows: rows,
                    glyphCount: Self.fallbackGlyphRamp.count,
                    time: elapsed,
                    viewport: rendererConfiguration.viewport,
                    sceneSeed: rendererConfiguration.sceneSeed,
                    sceneBrightness: rendererConfiguration.sceneBrightness
                )
                return String(Self.fallbackGlyphRamp[sample.glyphIndex])
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}
