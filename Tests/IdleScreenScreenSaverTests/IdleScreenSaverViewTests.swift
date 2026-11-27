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

  @Test(
    "window attachment starts animation when the App Extension host omits the traditional callback")
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

  @Test("saver views join and leave the shared aquarium scene clock with their animation")
  func aquariumClockRegistration() throws {
    let clock = IdleScreenAquariumSceneClock()
    let views = try (0..<2).map { _ in
      let view = try #require(
        IdleScreenSaverView(
          frame: NSRect(x: 0, y: 0, width: 640, height: 360),
          isPreview: false
        )
      )
      view.aquariumSceneClock = clock
      return view
    }
    views.forEach { $0.startAnimation() }
    #expect(clock.consumerCount == 2)
    views[0].stopAnimation()
    #expect(clock.consumerCount == 1)
    views[1].stopAnimation()
    #expect(clock.consumerCount == 0)
  }

  @Test("aquarium persistence is read once for every display and never for other patterns")
  func aquariumSnapshotIsSharedAndGatedByPattern() throws {
    final class Reads: @unchecked Sendable {
      let lock = NSLock()
      var count = 0
    }
    let reads = Reads()
    let monitor = IdleScreenAquariumSnapshotMonitor(
      observe: { _ in
        .present(
          .init(device: 1, inode: 7, size: 10, modifiedSeconds: 1, modifiedNanoseconds: 1))
      },
      read: { _ in
        reads.lock.withLock { reads.count += 1 }
        return .starter
      })
    func makeView(_ pattern: IdleScreenCreativePattern) throws -> IdleScreenSaverView {
      var configuration = IdleScreenConfiguration.default
      configuration.creative.pattern = pattern
      let view = try #require(
        IdleScreenSaverView(
          frame: NSRect(x: 0, y: 0, width: 640, height: 360),
          isPreview: false,
          cameraClient: nil,
          configuration: configuration
        ))
      view.aquariumSnapshotMonitor = monitor
      view.aquariumStoreURL = { URL(fileURLWithPath: "/tmp/idlescreen-view-aquariums.json") }
      return view
    }
    let plain = try makeView(.plasma)
    plain.startAnimation()
    for _ in 0..<5 { plain.animateOneFrame() }
    #expect(reads.count == 0)
    plain.stopAnimation()

    let displays = try (0..<3).map { _ in try makeView(.aquarium) }
    displays.forEach { $0.startAnimation() }
    for _ in 0..<5 { displays.forEach { $0.animateOneFrame() } }
    #expect(reads.count == 1)
    displays.forEach { $0.stopAnimation() }
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
    let view = try #require(
      IdleScreenSaverView(
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
    let view = try #require(
      IdleScreenSaverView(
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
    let view = try #require(
      IdleScreenSaverView(
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
    let view = try #require(
      IdleScreenSaverView(
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

    view.setFrameSize(NSSize(width: 900, height: 500))
    view.layout()
    #expect(view.agentOverlayApplicationCount == 1)
    view.stopAnimation()
  }

  private func agentSignal(
    _ provider: IdleScreenAgentProvider,
    _ state: IdleScreenAgentSignalState,
    at now: Date,
    expiresIn lifetime: TimeInterval = 120
  ) throws -> IdleScreenAgentSignal {
    try IdleScreenAgentSignal.validated(
      provider: provider,
      sessionID: "\(provider.rawValue)-session",
      eventID: "\(provider.rawValue)-\(state.rawValue)",
      state: state,
      title: nil,
      message: nil,
      temporaryLookID: nil,
      priority: 10,
      createdAt: now,
      expiresAt: now.addingTimeInterval(lifetime),
      acknowledgedAt: nil,
      nonce: "\(provider.rawValue)-nonce",
      validatedAt: now
    )
  }

  @Test("two live agents become two sprites for the shared renderer")
  func agentSignalsBecomeSprites() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let store = IdleScreenAgentSignalStore(
      fileURL: root.appending(path: "AgentSignals/inbox-v1.json")
    )
    _ = try store.apply(.set(try agentSignal(.codex, .needsAttention, at: now)), at: now)
    _ = try store.apply(.set(try agentSignal(.claude, .working, at: now)), at: now)
    var configuration = IdleScreenConfiguration.default
    configuration.agentIntegration.codexEnabled = true
    configuration.agentIntegration.claudeEnabled = true
    let view = try #require(
      IdleScreenSaverView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 360),
        isPreview: false,
        cameraClient: nil,
        configuration: configuration,
        agentSignalStore: store,
        agentClock: { now }
      ))

    let sprites = view.rendererConfiguration.agentSprites
    #expect(sprites.count == 2)
    #expect(Set(sprites.map(\.kind)) == [.codex, .claude])
    #expect(sprites.first?.kind == .codex)
    #expect(sprites.first?.state == .needsAttention)
    #expect(sprites.allSatisfy { $0.startedAt == now })
    #expect(view.agentOverlayPresentation?.provider == .codex)
    #expect(view.isAccessibilityElement())
  }

  @Test("a transient inbox failure clears sprites and they return at the next scheduled poll")
  func agentSpritesRecoverAfterTransientFailure() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let fileURL = root.appending(path: "AgentSignals/inbox-v1.json")
    let store = IdleScreenAgentSignalStore(fileURL: fileURL)
    _ = try store.apply(.set(try agentSignal(.codex, .needsAttention, at: now)), at: now)
    let healthy = try Data(contentsOf: fileURL)
    var configuration = IdleScreenConfiguration.default
    configuration.agentIntegration.codexEnabled = true
    var clock = now
    let view = try #require(
      IdleScreenSaverView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 360),
        isPreview: false,
        cameraClient: nil,
        configuration: configuration,
        agentSignalStore: store,
        agentClock: { clock }
      ))
    view.startAnimation()
    view.animateOneFrame()
    #expect(view.rendererConfiguration.agentSprites.count == 1)

    try Data("not json".utf8).write(to: fileURL)
    clock = now.addingTimeInterval(5)
    view.animateOneFrame()
    #expect(view.rendererConfiguration.agentSprites.isEmpty)

    try healthy.write(to: fileURL)
    clock = now.addingTimeInterval(10)
    view.animateOneFrame()
    #expect(view.rendererConfiguration.agentSprites.count == 1)
    #expect(view.agentOverlayPresentation?.provider == .codex)
    view.stopAnimation()
  }

  @Test("sprites obey the presentation policy gates")
  func agentSpritesObeyPolicy() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let store = IdleScreenAgentSignalStore(
      fileURL: root.appending(path: "AgentSignals/inbox-v1.json")
    )
    _ = try store.apply(.set(try agentSignal(.codex, .done, at: now)), at: now)
    _ = try store.apply(.set(try agentSignal(.claude, .error, at: now)), at: now)
    var configuration = IdleScreenConfiguration.default
    configuration.agentIntegration.codexEnabled = true
    configuration.agentIntegration.claudeEnabled = true
    configuration.agentIntegration.stateVisuals.error = .hidden
    let view = try #require(
      IdleScreenSaverView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 360),
        isPreview: false,
        cameraClient: nil,
        configuration: configuration,
        agentSignalStore: store,
        agentClock: { now }
      ))
    #expect(view.rendererConfiguration.agentSprites.map(\.kind) == [.codex])

    let quiet = IdleScreenConfiguration.default
    let silentView = try #require(
      IdleScreenSaverView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 360),
        isPreview: false,
        cameraClient: nil,
        configuration: quiet,
        agentSignalStore: store,
        agentClock: { now }
      ))
    #expect(silentView.rendererConfiguration.agentSprites.isEmpty)
  }

  @Test("quiet hours suppress the sprites end to end and lift when the window passes")
  func agentSpritesObeyQuietHours() throws {
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
    let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    let signals: (IdleScreenAgentSignalStore, Date) throws -> Void = { store, now in
      _ = try store.apply(.set(try agentSignal(.codex, .working, at: now)), at: now)
    }

    let (inside, insideRoot) = try agentView(
      {
        $0.agentIntegration.codexEnabled = true
        $0.agentIntegration.quietHours = .init(
          startMinute: (minute + 1_440 - 5) % 1_440, endMinute: (minute + 5) % 1_440)
      }, signals: signals)
    defer { try? FileManager.default.removeItem(at: insideRoot) }
    #expect(inside.rendererConfiguration.agentSprites.isEmpty)
    #expect(inside.agentOverlayPresentation == nil)

    let (outside, outsideRoot) = try agentView(
      {
        $0.agentIntegration.codexEnabled = true
        $0.agentIntegration.quietHours = .init(
          startMinute: (minute + 10) % 1_440, endMinute: (minute + 20) % 1_440)
      }, signals: signals)
    defer { try? FileManager.default.removeItem(at: outsideRoot) }
    #expect(outside.rendererConfiguration.agentSprites.count == 1)

    let (everQuiet, everRoot) = try agentView(
      {
        $0.agentIntegration.codexEnabled = true
        $0.agentIntegration.quietHours = .init(startMinute: minute, endMinute: minute)
      }, signals: signals)
    defer { try? FileManager.default.removeItem(at: everRoot) }
    #expect(everQuiet.rendererConfiguration.agentSprites.count == 1)
  }

  private func agentView(
    _ configure: (inout IdleScreenConfiguration) -> Void,
    signals: (IdleScreenAgentSignalStore, Date) throws -> Void
  ) throws -> (view: IdleScreenSaverView, root: URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let store = IdleScreenAgentSignalStore(
      fileURL: root.appending(path: "AgentSignals/inbox-v1.json")
    )
    try signals(store, now)
    var configuration = IdleScreenConfiguration.default
    configure(&configuration)
    let view = try #require(
      IdleScreenSaverView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 360),
        isPreview: false,
        cameraClient: nil,
        configuration: configuration,
        agentSignalStore: store,
        agentClock: { now }
      ))
    return (view, root)
  }

  @Test("VoiceOver hears every live agent, not just the strongest")
  func accessibilityJoinsBothAgents() throws {
    let (view, root) = try agentView(
      {
        $0.agentIntegration.codexEnabled = true
        $0.agentIntegration.claudeEnabled = true
      },
      signals: { store, now in
        _ = try store.apply(.set(try agentSignal(.codex, .needsAttention, at: now)), at: now)
        _ = try store.apply(.set(try agentSignal(.claude, .working, at: now)), at: now)
      })
    defer { try? FileManager.default.removeItem(at: root) }
    let label = try #require(view.accessibilityLabel())
    #expect(label.contains("Codex needs attention"))
    #expect(label.contains("Claude is working"))
  }

  @Test("the temporary look comes from the agent that passed the policy")
  func temporaryLookFollowsThePresentedAgent() throws {
    let claudeLook = UUID()
    let codexLook = UUID()
    var source = IdleScreenConfiguration.default
    source.appearance.palette = "Ocean"
    var withLooks = try source.savingCurrentLook(id: claudeLook, named: "Ocean")
    withLooks.appearance.palette = "Phosphor"
    withLooks = try withLooks.savingCurrentLook(id: codexLook, named: "Phosphor")
    withLooks.appearance.palette = "Ember"
    withLooks.agentIntegration.codexEnabled = false
    withLooks.agentIntegration.claudeEnabled = true
    let durable = withLooks

    let (view, root) = try agentView(
      { $0 = durable },
      signals: { store, now in
        func signal(
          _ provider: IdleScreenAgentProvider, _ state: IdleScreenAgentSignalState,
          look: UUID, priority: Int
        ) throws -> IdleScreenAgentSignal {
          try IdleScreenAgentSignal.validated(
            provider: provider, sessionID: "\(provider.rawValue)-session",
            eventID: "\(provider.rawValue)-\(state.rawValue)", state: state,
            title: nil, message: nil, temporaryLookID: look, priority: priority,
            createdAt: now, expiresAt: now.addingTimeInterval(120), acknowledgedAt: nil,
            nonce: "\(provider.rawValue)-nonce", validatedAt: now)
        }
        _ = try store.apply(
          .set(try signal(.codex, .error, look: codexLook, priority: 90)), at: now)
        _ = try store.apply(
          .set(try signal(.claude, .working, look: claudeLook, priority: 10)), at: now)
      })
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(view.agentOverlayPresentation?.provider == .claude)
    #expect(view.rendererConfiguration.palette == "Ocean")
  }

  @Test("the layer fallback names the agents because the sprites are not presented")
  func layerFallbackShowsAgentStatus() throws {
    let (view, root) = try agentView(
      {
        $0.agentIntegration.codexEnabled = true
        $0.agentIntegration.claudeEnabled = true
      },
      signals: { store, now in
        _ = try store.apply(.set(try agentSignal(.codex, .needsAttention, at: now)), at: now)
        _ = try store.apply(.set(try agentSignal(.claude, .working, at: now)), at: now)
      })
    defer { try? FileManager.default.removeItem(at: root) }
    view.startAnimation()
    view.animateOneFrame()
    defer { view.stopAnimation() }
    let showsFallback = !view.diagnosticState.renderedGlyphField.isEmpty
    if showsFallback {
      let text = try #require(view.agentFallbackText)
      #expect(text == view.accessibilityLabel())
      #expect(text.contains("Codex needs attention") && text.contains("Claude is working"))
    } else {
      #expect(view.agentFallbackText == nil)
    }
  }
}
