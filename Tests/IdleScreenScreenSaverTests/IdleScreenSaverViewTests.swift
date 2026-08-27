import AppKit
import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import QuartzCore
import Testing

@MainActor
@Suite("Production screen saver view")
struct IdleScreenSaverViewTests {
    @Test("post-migration window geometry resolves identical displays independently")
    func migratedDisplayResolution() {
        let displays = [
            IdleScreenDisplayGeometry(
                identifier: 2,
                bounds: CGRect(x: 0, y: 0, width: 3360, height: 1890)
            ),
            IdleScreenDisplayGeometry(
                identifier: 3,
                bounds: CGRect(x: 3360, y: 0, width: 3360, height: 1890)
            ),
        ]

        #expect(
            IdleScreenDisplayResolver.resolve(
                windowFrame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
                displays: displays
            ) == 2
        )
        #expect(
            IdleScreenDisplayResolver.resolve(
                windowFrame: CGRect(x: 3360, y: 0, width: 3360, height: 1890),
                displays: displays
            ) == 3
        )
    }

    @Test("concurrent hosted views have independent diagnostic identities")
    func concurrentViewIdentity() throws {
        let first = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                isPreview: false
            )
        )
        let second = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                isPreview: false
            )
        )

        #expect(first.diagnosticState.instanceIdentifier != second.diagnosticState.instanceIdentifier)
    }

    @Test("window attachment starts animation when the App Extension host omits the traditional callback")
    func windowAttachmentStartsAnimation() throws {
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 360),
                isPreview: false
            )
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.contentView = view
        view.viewDidMoveToWindow()

        #expect(view.diagnosticState.lifecycle == .animating)
    }

    @Test("initialization produces a visible attached preview frame")
    func initialPreviewFrame() throws {
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 428, height: 260),
                isPreview: true
            )
        )

        #expect(view.diagnosticState.lifecycle == .attached)
        #expect(view.diagnosticState.isPreview)
        #expect(view.diagnosticState.renderedGlyphField.isEmpty)
        let gradient = try #require(
            view.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
        )
        let colors = try #require(gradient.colors as? [CGColor])
        #expect(colors.count == 3)
        #expect(colors[0] == colors[2])
        #expect(colors[1] == NSColor.black.cgColor)
        #expect(gradient.startPoint == CGPoint(x: 0, y: 0))
        #expect(gradient.endPoint == CGPoint(x: 1, y: 1))
    }

    @Test("host lifecycle stops cleanly and can restart after detachment")
    func lifecycleRestart() throws {
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                isPreview: false
            )
        )

        view.startAnimation()
        #expect(view.diagnosticState.lifecycle == .animating)

        view.stopAnimation()
        #expect(view.diagnosticState.lifecycle == .attached)

        view.viewDidMoveToWindow()
        #expect(view.diagnosticState.lifecycle == .detached)

        view.startAnimation()
        #expect(view.diagnosticState.lifecycle == .animating)
    }

    @Test("layout fills the host bounds without implicit layer animation")
    func layoutMatchesHostBounds() throws {
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 360),
                isPreview: true
            )
        )

        view.layout()

        let gradient = try #require(view.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
        #expect(gradient.frame == view.bounds)
        #expect(gradient.animationKeys()?.isEmpty != false)
    }

    @Test("Pixel Materials configuration is identical and stop releases its scene")
    func pixelMaterialsLifecycle() throws {
        var configuration = IdleScreenConfiguration.default
        configuration.creative.pattern = .pixelMaterials
        configuration.materials = .init(
            material: .mixed,
            terrainFamily: .terraces,
            seed: 808,
            basinCount: 4,
            cellScale: 2
        )
        let coordinator = IdleScreenPixelMaterialsSceneCoordinator()
        let view = try #require(IdleScreenSaverView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360),
            isPreview: false,
            cameraClient: nil,
            configuration: configuration,
            pixelMaterialsCoordinator: coordinator
        ))

        #expect(view.rendererConfiguration.patternRawValue == "pixelMaterials")
        #expect(view.rendererConfiguration.pixelMaterialsSettings.material == .mixed)
        #expect(view.rendererConfiguration.pixelMaterialsSettings.terrainStyle == .terraces)
        #expect(view.rendererConfiguration.pixelMaterialsSettings.seed == 808)
        #expect(view.rendererConfiguration.pixelMaterialsSettings.basinCount == 4)
        #expect(coordinator.consumerCount == 1)

        view.startAnimation()
        view.animateOneFrame()
        view.stopAnimation()

        #expect(coordinator.consumerCount == 0)
        #expect(coordinator.activeSceneCount == 0)
    }

    @Test("a render frame resolves its effective configuration once")
    func rendererConfigurationResolvedOncePerFrame() throws {
        let view = try #require(IdleScreenSaverView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360),
            isPreview: false,
            cameraClient: nil,
            configuration: .default
        ))
        #expect(view.rendererConfigurationResolutionCountForOneTestFrame() == 1)
    }

    @Test("AgentSignal presentation expires independently of renderer and camera lifetimes")
    func agentSignalPresentationExpires() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "AgentSignals/inbox-v1.json")
        )
        let signal = try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: "session-1",
            eventID: "event-1",
            state: .needsAttention,
            title: "Codex needs attention",
            message: "Approve the next step",
            temporaryLookID: nil,
            priority: 50,
            createdAt: now,
            expiresAt: now.addingTimeInterval(2),
            acknowledgedAt: nil,
            nonce: "nonce-1",
            validatedAt: now
        )
        _ = try store.apply(.set(signal), at: now)
        var configuration = IdleScreenConfiguration.default
        configuration.agentIntegration.codexEnabled = true
        var clock = now
        let view = try #require(IdleScreenSaverView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360),
            isPreview: false,
            cameraClient: nil,
            configuration: configuration,
            agentSignalStore: store,
            agentClock: { clock }
        ))

        view.startAnimation()
        view.animateOneFrame()
        #expect(view.agentOverlayPresentation?.title == "Codex needs attention")
        #expect(view.agentOverlayApplicationCount == 1)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityLabel()?.contains("Codex needs attention") == true)

        clock = now.addingTimeInterval(2)
        view.animateOneFrame()
        #expect(view.agentOverlayPresentation == nil)
        #expect(view.agentOverlayApplicationCount == 2)
        #expect(!view.isAccessibilityElement())
        #expect(view.accessibilityLabel() == nil)
        view.animateOneFrame()
        #expect(view.agentOverlayApplicationCount == 2)
        #expect(view.diagnosticState.lifecycle == .animating)
        view.stopAnimation()
    }

    @Test("backing-scale changes relayout the cached AgentSignal overlay without reapplying it")
    func agentSignalOverlayTracksBackingScale() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "AgentSignals/inbox-v1.json")
        )
        let signal = try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: "scale-session",
            eventID: "scale-event",
            state: .working,
            title: "Codex is working",
            message: nil,
            temporaryLookID: nil,
            priority: 10,
            createdAt: now,
            expiresAt: now.addingTimeInterval(120),
            acknowledgedAt: nil,
            nonce: "scale-nonce",
            validatedAt: now
        )
        _ = try store.apply(.set(signal), at: now)
        var configuration = IdleScreenConfiguration.default
        configuration.agentIntegration.codexEnabled = true
        var backingScale: CGFloat = 1
        let view = try #require(IdleScreenSaverView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360),
            isPreview: false,
            cameraClient: nil,
            configuration: configuration,
            agentSignalStore: store,
            agentClock: { now },
            backingScaleProvider: { _ in backingScale }
        ))

        #expect(view.agentOverlayContentsScale == 1)
        #expect(view.agentOverlayApplicationCount == 1)
        backingScale = 2
        view.viewDidChangeBackingProperties()
        #expect(view.agentOverlayContentsScale == 2)
        #expect(view.agentOverlayApplicationCount == 1)
    }

    @Test("unchanged AgentSignal presentation is applied once while layout remains live")
    func unchangedAgentSignalPresentationIsNotReappliedPerFrame() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "AgentSignals/inbox-v1.json")
        )
        let signal = try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: "stable-session",
            eventID: "stable-event",
            state: .needsAttention,
            title: "Codex needs attention",
            message: "Approve the next step",
            temporaryLookID: nil,
            priority: 50,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            acknowledgedAt: nil,
            nonce: "stable-nonce",
            validatedAt: now
        )
        _ = try store.apply(.set(signal), at: now)
        var configuration = IdleScreenConfiguration.default
        configuration.agentIntegration.codexEnabled = true
        let view = try #require(IdleScreenSaverView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360),
            isPreview: false,
            cameraClient: nil,
            configuration: configuration,
            agentSignalStore: store,
            agentClock: { now }
        ))

        #expect(view.agentOverlayApplicationCount == 1)
        view.startAnimation()
        for _ in 0..<90 {
            view.animateOneFrame()
        }
        #expect(view.agentOverlayApplicationCount == 1)

        let initialFrame = view.agentOverlayFrame
        view.setFrameSize(NSSize(width: 900, height: 500))
        view.layout()
        #expect(view.agentOverlayFrame != initialFrame)
        #expect(view.agentOverlayApplicationCount == 1)
        view.stopAnimation()
    }

    @Test("AgentSignal overlay respects the assigned display safe area")
    func agentSignalOverlayRespectsSafeArea() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "AgentSignals/inbox-v1.json")
        )
        let signal = try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: "safe-area-session",
            eventID: "safe-area-event",
            state: .needsAttention,
            title: "Approval needed",
            message: nil,
            temporaryLookID: nil,
            priority: 50,
            createdAt: now,
            expiresAt: now.addingTimeInterval(120),
            acknowledgedAt: nil,
            nonce: "safe-area-nonce",
            validatedAt: now
        )
        _ = try store.apply(.set(signal), at: now)
        let topology = try DisplayTopology(displays: [
            .init(
                persistentIdentifier: .init(rawValue: "primary"),
                logicalFrame: .init(x: 0, y: 0, width: 640, height: 360),
                nativePixelSize: .init(width: 1_280, height: 720),
                backingScale: 2,
                rotationDegrees: 0,
                refreshRateRange: nil,
                safeAreaInsets: .init(top: 40, left: 30, bottom: 20, right: 10),
                isPrimary: true,
                mirrorTargetIdentifier: nil
            ),
        ])
        let topologyReader = LockedAgentOverlayTopologyReader(topology)
        let coordinator = DisplaySceneCoordinator(
            notificationCenter: NotificationCenter(),
            notificationName: .init("agent-safe-area"),
            readTopology: { topologyReader.read() }
        )
        var configuration = IdleScreenConfiguration.default
        configuration.agentIntegration.codexEnabled = true
        configuration.agentIntegration.overlayPosition = .topLeading
        let view = try #require(IdleScreenSaverView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360),
            isPreview: false,
            cameraClient: nil,
            configuration: configuration,
            displayCoordinator: coordinator,
            displayHostFrame: .init(x: 0, y: 0, width: 640, height: 360),
            agentSignalStore: store,
            agentClock: { now }
        ))

        view.startAnimation()
        view.animateOneFrame()

        #expect(view.agentOverlayFrame == CGRect(x: 58, y: 234, width: 380, height: 58))
        #expect(view.agentOverlayApplicationCount == 1)

        topologyReader.replace(try DisplayTopology(displays: [
            .init(
                persistentIdentifier: .init(rawValue: "primary"),
                logicalFrame: .init(x: 0, y: 0, width: 640, height: 360),
                nativePixelSize: .init(width: 1_280, height: 720),
                backingScale: 2,
                rotationDegrees: 0,
                refreshRateRange: nil,
                safeAreaInsets: .init(top: 10, left: 50, bottom: 30, right: 10),
                isPrimary: true,
                mirrorTargetIdentifier: nil
            ),
        ]))
        coordinator.refreshTopology()
        view.layout()

        #expect(view.agentOverlayFrame == CGRect(x: 78, y: 264, width: 380, height: 58))
        #expect(view.agentOverlayApplicationCount == 1)
        view.stopAnimation()
    }
}

private final class LockedAgentOverlayTopologyReader: @unchecked Sendable {
    private let lock = NSLock()
    private var topology: DisplayTopology

    init(_ topology: DisplayTopology) {
        self.topology = topology
    }

    func read() -> DisplayTopology {
        lock.withLock { topology }
    }

    func replace(_ topology: DisplayTopology) {
        lock.withLock { self.topology = topology }
    }
}
