import AppKit
import IdleScreenCamera
import IdleScreenCore
import IdleScreenDisplay
import SwiftUI
import Testing

/// Offscreen renders of the three settings pages in light and dark. Glass and sheets cannot draw offscreen, so these pages stay
/// on opaque surfaces. Set `IDLESCREEN_RENDER_DIR` to write the PNGs for review; without it nothing touches the disk.
@MainActor
@Suite("Design language renders")
struct DesignLanguageRenderTests {
  private enum Page: String, CaseIterable {
    case displays
    case integrations
    case status

    var collapsedHeight: CGFloat {
      switch self {
      case .displays: 900
      case .integrations: 1_500
      case .status: 1_300
      }
    }
  }

  private static let width: CGFloat = 980

  @Test(
    "each page renders in light and dark, and opening Details adds content below the collapsed page"
  )
  func pagesRender() throws {
    let harness = try RenderHarness()
    defer { harness.removeScratchDirectory() }

    for page in Page.allCases {
      for dark in [false, true] {
        // Same tall canvas for both, so the only difference is what Details adds.
        let size = NSSize(width: Self.width, height: page.collapsedHeight + 900)
        let collapsed = try harness.render(
          page: page, dark: dark, detailsExpanded: false, size: size)
        let expanded = try harness.render(page: page, dark: dark, detailsExpanded: true, size: size)
        let name = "\(page.rawValue)-\(dark ? "dark" : "light")"
        #expect(Self.hasVisibleContent(collapsed), "\(name) rendered a blank image")
        #expect(
          Self.contentBottom(expanded) > Self.contentBottom(collapsed) + 40,
          "\(name): expanded Details should be taller than collapsed"
        )
        #expect(
          Self.differingFraction(collapsed, expanded) > 0.005,
          "\(name): detailsInitiallyExpanded changed nothing"
        )
        try Self.save(collapsed, name: name)
        try Self.save(expanded, name: "\(name)-details")
      }
    }
  }

  @Test("light and dark renders differ, so the pages follow the appearance")
  func appearanceChangesPixels() throws {
    let harness = try RenderHarness()
    defer { harness.removeScratchDirectory() }
    let size = NSSize(width: Self.width, height: Page.status.collapsedHeight)
    let light = try harness.render(page: .status, dark: false, detailsExpanded: false, size: size)
    let dark = try harness.render(page: .status, dark: true, detailsExpanded: false, size: size)
    #expect(Self.averageLuma(light) > Self.averageLuma(dark) + 0.25)
  }

  @Test("an action failure shows a notice outside Details")
  func integrationsFailureNoticeIsVisible() throws {
    let harness = try RenderHarness()
    defer { harness.removeScratchDirectory() }
    let size = NSSize(width: Self.width, height: Page.integrations.collapsedHeight)
    let plain = try harness.render(
      page: .integrations, dark: false, detailsExpanded: false, size: size)
    harness.model.agentIntegrationStatus = "Hook installation failed: permission denied"
    let failed = try harness.render(
      page: .integrations, dark: false, detailsExpanded: false, size: size)
    #expect(Self.differingFraction(plain, failed) > 0.005)
    #expect(IntegrationsView.statusKind("Hook installation failed: x") == .error)
    #expect(IntegrationsView.statusKind("Agent signal inbox unavailable: x") == .error)
    #expect(IntegrationsView.statusKind("Test signal sent.") == .ok)
    try Self.save(failed, name: "integrations-failure-light")
  }

  @Test("Studio forces a dark window under a light system appearance; the pages follow the system")
  func studioWindowIsDark() throws {
    #expect(ContentView.windowAppearance(for: .studio)?.isDarkAqua == true)
    #expect(ContentView.windowAppearance(for: .studio, showsSetup: true) == nil)
    for destination in [Destination.displays, .integrations, .status] {
      #expect(ContentView.windowAppearance(for: destination) == nil)
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: .aqua)
    #expect(window.effectiveAppearance.isDarkAqua == false)
    let host = NSHostingView(
      rootView: Color.clear.windowAppearance(ContentView.windowAppearance(for: .studio)))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    #expect(window.effectiveAppearance.isDarkAqua)
    #expect(host.effectiveAppearance.isDarkAqua)

  }

  @Test("Studio rendered under a light system window comes out dark")
  func studioRendersDarkUnderLightSystem() throws {
    let harness = try RenderHarness()
    defer { harness.removeScratchDirectory() }
    harness.navigation.destination = .studio
    harness.navigation.isSetupDeferred = true  // otherwise Studio's place shows setup, which follows the system
    let size = NSSize(width: 1_200, height: 800)
    let view = NSHostingView(
      rootView: AnyView(
        ContentView()
          .environment(harness.model)
          .environment(harness.cameraClient)
          .environment(harness.navigation)
          .environment(harness.coordinator)
          .frame(width: size.width, height: size.height)
      )
    )
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = view
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()
    #expect(window.effectiveAppearance.isDarkAqua)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(Self.averageLuma(bitmap) < 0.5)
    try Self.save(bitmap, name: "studio-under-light-system")

    harness.navigation.destination = .status
    view.layoutSubtreeIfNeeded()
    let deadline = Date().addingTimeInterval(2)
    while window.appearance != nil && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    #expect(window.appearance == nil)  // the window follows the system again; the host's own appearance is not ours to assert
  }

  /// The Studio controls: the compact dock, the expanded dock for each saver kind, and the Pixel Materials dock with Advanced open.
  private enum StudioScene: String, CaseIterable {
    case compact
    case expandedProcedural = "expanded-procedural"
    case expandedCamera = "expanded-camera"
    case expandedPixelMaterials = "expanded-pixel-materials"
    case expandedPixelMaterialsAdvanced = "expanded-pixel-materials-advanced"
  }

  @Test(
    "the Studio controls render on the dark canvas in every dock state, and each state changes the panel"
  )
  func studioControlsRender() throws {
    var bitmaps: [StudioScene: NSBitmapImageRep] = [:]
    for scene in StudioScene.allCases {
      let harness = try RenderHarness()
      defer { harness.removeScratchDirectory() }
      let bitmap = try harness.renderStudio(
        scene: scene.rawValue, size: NSSize(width: 1_200, height: 820))
      #expect(Self.hasVisibleContent(bitmap), "\(scene.rawValue) rendered a blank image")
      #expect(Self.averageLuma(bitmap) < 0.5, "\(scene.rawValue): Studio must stay dark")
      bitmaps[scene] = bitmap
      try Self.save(bitmap, name: "studio-\(scene.rawValue)")
    }
    let compact = try #require(bitmaps[.compact])
    let procedural = try #require(bitmaps[.expandedProcedural])
    let camera = try #require(bitmaps[.expandedCamera])
    let materials = try #require(bitmaps[.expandedPixelMaterials])
    let advanced = try #require(bitmaps[.expandedPixelMaterialsAdvanced])
    #expect(Self.differingFraction(compact, procedural) > 0.005)
    #expect(Self.differingFraction(procedural, camera) > 0.005)
    #expect(Self.differingFraction(procedural, materials) > 0.005)
    #expect(Self.differingFraction(materials, advanced) > 0.005, "opening Advanced changed nothing")
  }

  @Test("the Studio controls render the same dark canvas under a light system appearance")
  func studioControlsIgnoreSystemAppearance() throws {
    let harness = try RenderHarness()
    defer { harness.removeScratchDirectory() }
    let size = NSSize(width: 1_200, height: 820)
    let dark = try harness.renderStudio(scene: "expanded-pixel-materials-advanced", size: size)
    let underLight = try harness.renderStudio(
      scene: "expanded-pixel-materials-advanced", size: size, systemLight: true)
    #expect(Self.averageLuma(underLight) < 0.5)
    #expect(Self.differingFraction(dark, underLight) < 0.02)
  }

  @Test("the palette resolves from the appearance it is given, with no workspace state")
  func paletteFollowsAppearance() {
    let light = NSAppearance(named: .aqua)!
    let dark = NSAppearance(named: .darkAqua)!
    #expect(!light.isDarkAqua && !light.isHighContrast)
    #expect(dark.isDarkAqua && !dark.isHighContrast)
    func resolve(_ color: NSColor, _ appearance: NSAppearance) -> NSColor {
      var out = color
      appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
      return out
    }
    #expect(resolve(DesignPalette.NS.ink2, light) != resolve(DesignPalette.NS.ink2, dark))
  }

  @Test("every Aqua variant resolves through bestMatch, never by name alone")
  func appearanceVariantsResolveThroughBestMatch() {
    #expect(NSAppearance(named: .aqua)!.variant == .aqua)
    #expect(NSAppearance(named: .darkAqua)!.variant == .darkAqua)
    for name in NSAppearance.variants {
      let appearance = NSAppearance(named: name)!
      let variant = appearance.variant
      #expect(variant == appearance.bestMatch(from: NSAppearance.variants))
      #expect(variant != nil)
      let high =
        variant == .accessibilityHighContrastAqua || variant == .accessibilityHighContrastDarkAqua
      #expect(appearance.isHighContrast == high)
      let dark = variant == .darkAqua || variant == .accessibilityHighContrastDarkAqua
      #expect(appearance.isDarkAqua == dark)
    }
  }

  private static func hasVisibleContent(_ bitmap: NSBitmapImageRep) -> Bool {
    guard let first = bitmap.colorAt(x: 0, y: 0) else { return false }
    let stepX = max(1, bitmap.pixelsWide / 40)
    let stepY = max(1, bitmap.pixelsHigh / 40)
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
        if let color = bitmap.colorAt(x: x, y: y), color != first { return true }
      }
    }
    return false
  }

  /// Fraction of sampled pixels that differ between two same-sized renders.
  private static func differingFraction(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
    var different = 0.0
    var total = 0.0
    for y in stride(from: 0, to: min(a.pixelsHigh, b.pixelsHigh), by: 3) {
      for x in stride(from: 0, to: min(a.pixelsWide, b.pixelsWide), by: 3) {
        total += 1
        if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { different += 1 }
      }
    }
    return total == 0 ? 0 : different / total
  }

  /// The lowest row holding anything other than the page ground.
  private static func contentBottom(_ bitmap: NSBitmapImageRep) -> Int {
    guard let ground = bitmap.colorAt(x: 2, y: 2) else { return 0 }
    for y in stride(from: bitmap.pixelsHigh - 1, through: 0, by: -1) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 4)
      where bitmap.colorAt(x: x, y: y) != ground {
        return y
      }
    }
    return 0
  }

  private static func averageLuma(_ bitmap: NSBitmapImageRep) -> Double {
    var total = 0.0
    var count = 0.0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 30)) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 30)) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        total +=
          0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        count += 1
      }
    }
    return count == 0 ? 0 : total / count
  }

  private static func save(_ bitmap: NSBitmapImageRep, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["IDLESCREEN_RENDER_DIR"],
      !directory.isEmpty
    else { return }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: url.appending(path: "\(name).png"))
  }

  /// Everything a page needs, built over a scratch directory so no render reads or writes the real hook or shared files.
  @MainActor
  private struct RenderHarness {
    let root: URL
    let model: IdleScreenAppModel
    let navigation: IdleScreenCompanionNavigation
    let coordinator: DisplaySceneCoordinator
    let cameraClient: IdleScreenCompanionCameraClient

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(path: "idlescreen-render-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      model = IdleScreenAppModel(
        bundle: Bundle(for: RenderBundleMarker.self),
        agentIntegrationDependencies: .init(
          sharedPaths: nil,
          appGroupIdentifier: nil,
          legacyConfigurationURLs: [],
          codexHookSettingsURL: root.appending(path: "Home/.codex/hooks.json"),
          claudeHookSettingsURL: root.appending(path: "Home/.claude/settings.json"),
          agentControlExecutableURL: root.appending(path: "Helpers/idlescreenctl"),
          clock: { Date(timeIntervalSince1970: 1_800_000_000) },
          loadAgentSignals: { store, date in try store.read(at: date) }
        )
      )
      navigation = IdleScreenCompanionNavigation()

      let topology = try DisplayTopology(displays: [
        Self.display("primary", x: 0, width: 2_560, height: 1_440, isPrimary: true),
        Self.display("right", x: 2_560, width: 1_920, height: 1_080, isPrimary: false),
      ])
      coordinator = DisplaySceneCoordinator(
        notificationCenter: NotificationCenter(),
        notificationName: .init("idlescreen-render-test"),
        readTopology: { topology }
      )
      _ = coordinator.attach(settings: model.configuration.display, configurationRevision: 1)
      navigation.previewDisplayIdentifier = topology.displays.first?.persistentIdentifier

      cameraClient = IdleScreenCompanionCameraClient(
        infoDictionary: [:],
        effects: IdleScreenCompanionCameraEffects(
          readServiceRegistration: { .enabled },
          registerAgent: { .enabled },
          openRepairSurface: { _ in true },
          bootstrapPreview: { _ in
            IdleScreenCompanionCameraBootstrap(status: .missingConfiguration, runtime: nil)
          },
          connectControl: { _, _ in nil }
        ),
        scheduler: IdleScreenCompanionCameraTaskScheduler()
      )
    }

    func removeScratchDirectory() {
      try? FileManager.default.removeItem(at: root)
    }

    func render(
      page: Page,
      dark: Bool,
      detailsExpanded: Bool,
      size: NSSize
    ) throws -> NSBitmapImageRep {
      let content: AnyView
      switch page {
      case .displays: content = AnyView(DisplaysView(detailsInitiallyExpanded: detailsExpanded))
      case .integrations:
        content = AnyView(IntegrationsView(detailsInitiallyExpanded: detailsExpanded))
      case .status: content = AnyView(StatusView(detailsInitiallyExpanded: detailsExpanded))
      }
      let view = NSHostingView(
        rootView: AnyView(
          content
            .environment(model)
            .environment(cameraClient)
            .environment(navigation)
            .environment(coordinator)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        )
      )
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
        defer: false)
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.contentView = view
      view.setFrameSize(size)
      view.layoutSubtreeIfNeeded()
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      #expect(!window.isVisible)
      return bitmap
    }

    func renderStudio(scene: String, size: NSSize, systemLight: Bool = false) throws
      -> NSBitmapImageRep
    {
      navigation.isSetupDeferred = true
      model.updateSource(scene == "expanded-camera" ? .camera : .generative)
      model.updateCreativePattern(
        scene.contains("pixel-materials") ? .pixelMaterials : .perlin)
      let content = StudioView(
        initiallyMoreExpanded: scene != "compact",
        pixelAdvancedInitiallyExpanded: scene.hasSuffix("advanced"))
      let view = NSHostingView(
        rootView: AnyView(
          content
            .environment(model)
            .environment(cameraClient)
            .environment(navigation)
            .environment(coordinator)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .windowAppearance(ContentView.windowAppearance(for: .studio))
        )
      )
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
        defer: false)
      window.appearance = NSAppearance(named: systemLight ? .aqua : .darkAqua)
      window.contentView = view
      view.setFrameSize(size)
      view.layoutSubtreeIfNeeded()
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      return bitmap
    }

    private static func display(
      _ identifier: String,
      x: Double,
      width: Double,
      height: Double,
      isPrimary: Bool
    ) -> DisplayTopology.Display {
      .init(
        persistentIdentifier: .init(rawValue: identifier),
        logicalFrame: .init(x: x, y: 0, width: width, height: height),
        nativePixelSize: .init(width: Int(width), height: Int(height)),
        backingScale: 1,
        rotationDegrees: 0,
        refreshRateRange: .init(minimumHz: 60, maximumHz: 60, currentHz: 60),
        safeAreaInsets: .zero,
        isPrimary: isPrimary,
        mirrorTargetIdentifier: nil
      )
    }
  }
}

private final class RenderBundleMarker {}
