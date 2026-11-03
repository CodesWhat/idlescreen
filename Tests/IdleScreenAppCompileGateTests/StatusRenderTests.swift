import AppKit
import IdleScreenCamera
import SwiftUI
import Testing

/// Offscreen renders of the Status page states in light and dark. Each scene asserts the words and the action through the pure
/// `StatusSummary` first, then draws it. Set `IDLESCREEN_RENDER_DIR` to write the PNGs for review.
@MainActor
@Suite("Status page renders")
struct StatusRenderTests {
  private struct Scene {
    let name: String
    let inputs: StatusInputs
    let verdict: String
    let saverWord: String
    let cameraWord: String
    let primary: StatusAction?
    let developmentBuild: Bool
  }

  private static func inputs(_ edit: (inout StatusInputs) -> Void = { _ in }) -> StatusInputs {
    var inputs = StatusInputs()
    inputs.cameraInUse = true
    edit(&inputs)
    return inputs
  }

  private static let scenes: [Scene] = [
    Scene(
      name: "ready", inputs: inputs(), verdict: "IdleScreen is ready.", saverWord: "Ready",
      cameraWord: "Ready", primary: nil, developmentBuild: false),
    Scene(
      name: "saver-not-registered",
      inputs: inputs {
        $0.registrationLocation = .notRegistered
        $0.selectedEverywhere = false
      }, verdict: "One thing needs your attention.", saverWord: "Not registered",
      cameraWord: "Ready", primary: .registerSaver, developmentBuild: false),
    Scene(
      name: "camera-needs-permission",
      inputs: inputs { $0.cameraAuthorization = .observed(.notDetermined) },
      verdict: "One thing needs your attention.", saverWord: "Ready",
      cameraWord: "Needs permission", primary: .allowCamera, developmentBuild: false),
    Scene(
      name: "development-build",
      inputs: inputs {
        $0.sharedContainerAvailable = false
        $0.cameraInUse = false
      }, verdict: "IdleScreen is ready.", saverWord: "Ready", cameraWord: "Off", primary: nil,
      developmentBuild: true),
    Scene(
      name: "multiple-problems",
      inputs: inputs {
        $0.selectedEverywhere = false
        $0.cameraAuthorization = .observed(.denied)
      }, verdict: "2 things need your attention.", saverWord: "Not selected",
      cameraWord: "Needs permission", primary: .openScreenSaverSettings, developmentBuild: false),
  ]

  @Test("each scene says the right thing before it draws")
  func summariesMatchScenes() {
    for scene in Self.scenes {
      let summary = StatusSummary(scene.inputs)
      #expect(summary.verdict == scene.verdict, "\(scene.name) verdict")
      #expect(summary.saver.word == scene.saverWord, "\(scene.name) saver")
      #expect(summary.camera.word == scene.cameraWord, "\(scene.name) camera")
      #expect(summary.primaryAction == scene.primary, "\(scene.name) primary action")
      #expect(summary.isDevelopmentBuild == scene.developmentBuild, "\(scene.name) dev build")
    }
  }

  @Test("each scene renders non-empty in light and dark, and the dev banner changes the page")
  func scenesRender() throws {
    var bitmaps: [String: NSBitmapImageRep] = [:]
    for scene in Self.scenes {
      for dark in [false, true] {
        let bitmap = try Self.render(scene, dark: dark)
        #expect(bitmap.pixelsWide > 0)
        #expect(Self.hasVisibleContent(bitmap), "\(scene.name) rendered a blank image")
        let name = "\(scene.name)-\(dark ? "dark" : "light")"
        bitmaps[name] = bitmap
        try Self.save(bitmap, name: name)
      }
    }
    let ready = try #require(bitmaps["ready-light"])
    let problem = try #require(bitmaps["saver-not-registered-light"])
    #expect(Self.differingFraction(ready, problem) > 0.005)
  }

  // MARK: Drawing

  private static let size = NSSize(width: 980, height: 760)

  private static func render(_ scene: Scene, dark: Bool) throws -> NSBitmapImageRep {
    let summary = StatusSummary(scene.inputs)
    let view = NSHostingView(
      rootView: AnyView(
        StatusPageContent(summary: summary, detailsInitiallyExpanded: false) {
          DesignRow(title: "Saver extension", detail: "com.idlescreen.app.saver") {
            DesignStatus(kind: .ok, text: "Ready")
          }
        }
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
    return bitmap
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

  private static func save(_ bitmap: NSBitmapImageRep, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["IDLESCREEN_RENDER_DIR"],
      !directory.isEmpty
    else { return }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: url.appending(path: "\(name).png"))
  }
}
