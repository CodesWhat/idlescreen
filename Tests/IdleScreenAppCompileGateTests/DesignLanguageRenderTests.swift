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
    case system

    var collapsedHeight: CGFloat {
      switch self {
      case .displays: 900
      case .integrations: 1_500
      case .system: 1_300
      }
    }
  }

  private static let width: CGFloat = 980

  @Test("each page renders non-empty in light and dark, collapsed and with details open")
  func pagesRender() throws {
    let harness = try RenderHarness()
    defer { harness.removeScratchDirectory() }

    for page in Page.allCases {
      for dark in [false, true] {
        for expanded in [false, true] {
          let height = page.collapsedHeight + (expanded ? 700 : 0)
          let bitmap = try harness.render(
            page: page,
            dark: dark,
            detailsExpanded: expanded,
            size: NSSize(width: Self.width, height: height)
          )
          #expect(bitmap.pixelsWide > 0)
          #expect(bitmap.pixelsHigh > 0)
          #expect(
            Self.hasVisibleContent(bitmap),
            "\(page.rawValue) rendered a blank image"
          )
          try Self.save(
            bitmap,
            name: "\(page.rawValue)-\(dark ? "dark" : "light")\(expanded ? "-details" : "")"
          )
        }
      }
    }
  }

  @Test("light and dark renders differ, so the pages follow the appearance")
  func appearanceChangesPixels() throws {
    let harness = try RenderHarness()
    defer { harness.removeScratchDirectory() }
    let size = NSSize(width: Self.width, height: Page.system.collapsedHeight)
    let light = try harness.render(page: .system, dark: false, detailsExpanded: false, size: size)
    let dark = try harness.render(page: .system, dark: true, detailsExpanded: false, size: size)
    #expect(Self.averageLuma(light) > Self.averageLuma(dark) + 0.25)
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
      case .system: content = AnyView(SystemView(detailsInitiallyExpanded: detailsExpanded))
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
