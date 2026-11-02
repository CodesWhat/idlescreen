import AppKit
import SwiftUI
import Testing

/// Offscreen renders of each setup step in light and dark. Set `IDLESCREEN_RENDER_DIR` to write the PNGs for review; without it
/// nothing touches the disk.
@MainActor
@Suite("Setup flow renders")
struct SetupFlowRenderTests {
  private struct Scene {
    let name: String
    let inputs: SetupInputs
    var status: String?
    var error: String?
  }

  private static let scenes: [Scene] = [
    Scene(
      name: "1-register",
      inputs: SetupInputs(
        registrationCurrent: false, selectedEverywhere: false, cameraAccess: .unknown,
        cameraSkipped: false)),
    Scene(
      name: "2-choose",
      inputs: SetupInputs(
        registrationCurrent: true, selectedEverywhere: false, cameraAccess: .unknown,
        cameraSkipped: false),
      status:
        "The extension is registered. Setup is complete once idlescreen is selected in Screen Saver Settings."
    ),
    Scene(
      name: "3-camera",
      inputs: SetupInputs(
        registrationCurrent: true, selectedEverywhere: true, cameraAccess: .notDetermined,
        cameraSkipped: false)),
    Scene(
      name: "3-camera-blocked",
      inputs: SetupInputs(
        registrationCurrent: true, selectedEverywhere: true, cameraAccess: .blocked,
        cameraSkipped: false)),
    Scene(
      name: "4-done",
      inputs: SetupInputs(
        registrationCurrent: true, selectedEverywhere: true, cameraAccess: .authorized,
        cameraSkipped: false)),
    Scene(
      name: "error",
      inputs: SetupInputs(
        registrationCurrent: false, selectedEverywhere: false, cameraAccess: .unknown,
        cameraSkipped: false),
      error: "The embedded screen saver extension is missing from this app build."),
  ]

  @Test("each step renders non-empty in light and dark")
  func stepsRender() throws {
    for scene in Self.scenes {
      for dark in [false, true] {
        let bitmap = try Self.render(scene, dark: dark)
        #expect(bitmap.pixelsWide > 0)
        #expect(Self.hasVisibleContent(bitmap), "\(scene.name) rendered a blank image")
        try Self.save(bitmap, name: "\(scene.name)-\(dark ? "dark" : "light")")
      }
    }
  }

  @Test("light and dark renders differ")
  func appearanceChangesPixels() throws {
    let scene = Self.scenes[0]
    let light = try Self.render(scene, dark: false)
    let dark = try Self.render(scene, dark: true)
    #expect(Self.averageLuma(light) > Self.averageLuma(dark) + 0.25)
  }

  private static func render(_ scene: Scene, dark: Bool) throws -> NSBitmapImageRep {
    let size = NSSize(width: 980, height: 760)
    let view = NSHostingView(
      rootView: AnyView(
        SetupFlowContent(
          progress: SetupProgress(scene.inputs),
          cameraAccess: scene.inputs.cameraAccess,
          statusMessage: scene.status,
          errorMessage: scene.error
        )
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
}
