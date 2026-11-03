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
    let current: SetupStep?
    let primary: String
    var offersSkip = false
  }

  private static func inputs(
    registered: Bool, selected: Bool, camera: SetupCameraAccess
  ) -> SetupInputs {
    SetupInputs(
      registrationCurrent: registered, selectedEverywhere: selected, cameraAccess: camera,
      cameraSkipped: false)
  }

  private static let scenes: [Scene] = [
    Scene(
      name: "1-register", inputs: inputs(registered: false, selected: false, camera: .unknown),
      current: .register, primary: "Register IdleScreen"),
    Scene(
      name: "2-choose", inputs: inputs(registered: true, selected: false, camera: .unknown),
      status:
        "The extension is registered. Setup is complete once idlescreen is selected in Screen Saver Settings.",
      current: .choose, primary: "Open Screen Saver settings"),
    Scene(
      name: "3-camera", inputs: inputs(registered: true, selected: true, camera: .notDetermined),
      current: .camera, primary: "Allow camera", offersSkip: true),
    Scene(
      name: "3-camera-blocked", inputs: inputs(registered: true, selected: true, camera: .blocked),
      current: .camera, primary: "Open camera privacy", offersSkip: true),
    Scene(
      name: "4-done", inputs: inputs(registered: true, selected: true, camera: .authorized),
      current: nil, primary: "Open Studio"),
    Scene(
      name: "error", inputs: inputs(registered: false, selected: false, camera: .unknown),
      error: "The embedded screen saver extension is missing from this app build.",
      current: .register, primary: "Register IdleScreen"),
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

  @Test("each scene lands on the right step with the right actions")
  func cardModelMatchesScene() {
    for scene in Self.scenes {
      let progress = SetupProgress(scene.inputs)
      let card = SetupCardModel(
        progress: progress, cameraAccess: scene.inputs.cameraAccess, isRegistering: false)
      #expect(progress.current == scene.current, "\(scene.name) current step")
      #expect(card.primaryTitle == scene.primary, "\(scene.name) primary action")
      #expect(card.primaryEnabled, "\(scene.name) primary enabled")
      #expect(card.offersSkip == scene.offersSkip, "\(scene.name) skip")
      #expect(card.offersLater == (scene.current != nil), "\(scene.name) later")
    }
  }

  @Test("the camera step waits for macOS to report access before offering Allow")
  func cameraUnknownDisablesAllow() {
    let progress = SetupProgress(Self.inputs(registered: true, selected: true, camera: .unknown))
    let card = SetupCardModel(progress: progress, cameraAccess: .unknown, isRegistering: false)
    #expect(progress.current == .camera)
    #expect(card.primaryTitle == "Checking camera…")
    #expect(!card.primaryEnabled)
  }

  @Test("denied camera is fixable in Privacy, restricted is a policy block with no primary action")
  func deniedVersusRestricted() {
    #expect(SetupFlowView.cameraAccess(.observed(.denied)) == .blocked)
    #expect(SetupFlowView.cameraAccess(.observed(.restricted)) == .restricted)
    let progress = SetupProgress(Self.inputs(registered: true, selected: true, camera: .restricted))
    let denied = SetupCardModel(progress: progress, cameraAccess: .blocked, isRegistering: false)
    let restricted = SetupCardModel(
      progress: progress, cameraAccess: .restricted, isRegistering: false)
    #expect(progress.current == .camera)
    #expect(denied.primaryTitle == "Open camera privacy" && denied.primaryEnabled)
    #expect(!restricted.primaryEnabled)
    #expect(restricted.primaryTitle != "Open camera privacy")
    #expect(restricted.offersSkip)
  }

  @Test("registering disables the register action and says so")
  func registeringState() {
    let progress = SetupProgress(Self.inputs(registered: false, selected: false, camera: .unknown))
    let card = SetupCardModel(progress: progress, cameraAccess: .unknown, isRegistering: true)
    #expect(card.primaryTitle == "Registering…")
    #expect(!card.primaryEnabled)
  }

  @Test("light and dark renders differ")
  func appearanceChangesPixels() throws {
    let scene = Self.scenes[0]
    let light = try Self.render(scene, dark: false)
    let dark = try Self.render(scene, dark: true)
    #expect(Self.averageLuma(light) > Self.averageLuma(dark) + 0.25)
  }

  /// The main window's content area at 1900x950 (minus the 81 pt rail) and at the 900x600 minimum.
  private static let windowSizes: [(name: String, size: NSSize)] = [
    ("1900x950", NSSize(width: 1_819, height: 950)),
    ("min", NSSize(width: 819, height: 600)),
  ]

  @Test("each step renders at the default and minimum window sizes, one or two columns")
  func stepsRenderAtWindowSizes() throws {
    for scene in Self.scenes {
      for (sizeName, size) in Self.windowSizes {
        let bitmap = try Self.render(scene, dark: false, size: size)
        #expect(Self.hasVisibleContent(bitmap), "\(scene.name) \(sizeName) rendered a blank image")
        try Self.save(bitmap, name: "setup-\(scene.name)-\(sizeName)")
      }
    }
  }

  @Test("the left column is 38% of the window, held between 420 and 560 pt")
  func leadingColumnWidthIsClamped() {
    #expect(SetupFlowContent.leadingColumnWidth(in: 900) == 420)
    #expect(SetupFlowContent.leadingColumnWidth(in: 1_300) == 494)
    #expect(SetupFlowContent.leadingColumnWidth(in: 1_819) == 560)
  }

  private static func render(
    _ scene: Scene, dark: Bool, size: NSSize = NSSize(width: 980, height: 760)
  ) throws -> NSBitmapImageRep {
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
