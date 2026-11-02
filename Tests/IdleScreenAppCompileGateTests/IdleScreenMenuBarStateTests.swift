import AppKit
import Testing

@Suite("Menu bar glyph state")
struct IdleScreenMenuBarStateTests {
  private func resolve(
    setup: Bool = false, attention: Bool = false, camera: Bool = false, running: Bool = false
  ) -> IdleScreenMenuBarState {
    IdleScreenMenuBarState.resolve(
      .init(
        needsSetup: setup, needsAttention: attention, cameraStreaming: camera, running: running))
  }

  @Test("nothing active is idle")
  func idle() {
    #expect(resolve() == .idle)
  }

  @Test("each fact alone selects its own state")
  func singleFacts() {
    #expect(resolve(setup: true) == .setup)
    #expect(resolve(attention: true) == .attention)
    #expect(resolve(camera: true) == .camera)
    #expect(resolve(running: true) == .running)
  }

  @Test("precedence is setup, attention, camera, running, idle across every combination")
  func precedenceTable() {
    for bits in 0..<16 {
      let setup = bits & 1 != 0
      let attention = bits & 2 != 0
      let camera = bits & 4 != 0
      let running = bits & 8 != 0
      let expected: IdleScreenMenuBarState =
        setup
        ? .setup
        : attention ? .attention : camera ? .camera : running ? .running : .idle
      #expect(
        resolve(setup: setup, attention: attention, camera: camera, running: running) == expected)
    }
  }

  private func setup(
    _ previous: Bool? = nil, embedded: Bool = true, refreshing: Bool = false, fresh: Bool = false,
    current: Bool = false, selected: Bool = false, failed: Bool = false
  ) -> Bool {
    IdleScreenMenuBarState.needsSetup(
      .init(
        isExtensionEmbedded: embedded, isRefreshing: refreshing, hasFreshSaverStatus: fresh,
        isCurrentBuild: current, isSelectedEverywhere: selected, refreshFailed: failed),
      previous: previous)
  }

  @Test("fresh status decides setup on its own")
  func freshSetup() {
    #expect(!setup(true, fresh: true, current: true, selected: true))
    #expect(setup(false, fresh: true, current: true, selected: false))
    #expect(setup(false, fresh: true, current: false, selected: true))
    #expect(setup(false, embedded: false, fresh: true, current: true, selected: true))
  }

  @Test("a refresh in flight keeps the prior verdict, and launch follows isReady")
  func refreshInFlight() {
    #expect(!setup(false, refreshing: true))
    #expect(setup(true, refreshing: true))
    #expect(setup(nil, refreshing: true))
  }

  @Test("a failed refresh is setup")
  func failedRefresh() {
    #expect(setup(false, failed: true))
    #expect(setup(nil, failed: true))
  }

  @Test("a camera diagnostic is not a setup input, so a ready app stays out of setup")
  func cameraDiagnosticIgnored() {
    #expect(!setup(false, fresh: true, current: true, selected: true))
  }

  @Test("a stale non-live animating report is not running")
  func staleReportNotRunning() {
    #expect(
      !IdleScreenMenuBarState.isRunning(
        starting: false, reportIsLive: false, reportIsAnimating: true))
    #expect(
      IdleScreenMenuBarState.isRunning(starting: false, reportIsLive: true, reportIsAnimating: true)
    )
    #expect(
      !IdleScreenMenuBarState.isRunning(
        starting: false, reportIsLive: true, reportIsAnimating: false))
    #expect(
      IdleScreenMenuBarState.isRunning(
        starting: true, reportIsLive: false, reportIsAnimating: false))
  }

  @Test("only running and camera animate, and never under Reduce Motion")
  func animation() {
    for state in IdleScreenMenuBarState.allCases {
      let moves = state == .running || state == .camera
      #expect(state.animates(reduceMotion: false) == moves)
      #expect(!state.animates(reduceMotion: true))
    }
  }

  @Test("frames alternate while moving and pin to the first frame under Reduce Motion")
  func frames() {
    #expect(
      IdleScreenMenuBarState.running.assetName(frame: 0, reduceMotion: false)
        == "MenuBarCRTRunning0")
    #expect(
      IdleScreenMenuBarState.running.assetName(frame: 1, reduceMotion: false)
        == "MenuBarCRTRunning1")
    #expect(
      IdleScreenMenuBarState.camera.assetName(frame: 0, reduceMotion: false) == "MenuBarCRTCamera0")
    #expect(
      IdleScreenMenuBarState.camera.assetName(frame: 1, reduceMotion: false) == "MenuBarCRTCamera1")
    #expect(
      IdleScreenMenuBarState.running.assetName(frame: 1, reduceMotion: true) == "MenuBarCRTRunning0"
    )
    #expect(
      IdleScreenMenuBarState.camera.assetName(frame: 1, reduceMotion: true) == "MenuBarCRTCamera0")
    #expect(
      IdleScreenMenuBarState.idle.assetName(frame: 1, reduceMotion: false) == "MenuBarCRTIdle")
  }

  @Test("each state has its accessibility description")
  func descriptions() {
    #expect(IdleScreenMenuBarState.idle.accessibilityDescription == "IdleScreen, ready")
    #expect(
      IdleScreenMenuBarState.running.accessibilityDescription == "IdleScreen, screen saver running")
    #expect(
      IdleScreenMenuBarState.camera.accessibilityDescription == "IdleScreen, camera preview on")
    #expect(
      IdleScreenMenuBarState.attention.accessibilityDescription == "IdleScreen, needs attention")
    #expect(IdleScreenMenuBarState.setup.accessibilityDescription == "IdleScreen, needs setup")
  }

  @Test("every glyph asset is a checked-in template imageset with both scales")
  func assetsAreTemplateImagesets() throws {
    let catalog = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Products/IdleScreenApp/Assets.xcassets")
    for state in IdleScreenMenuBarState.allCases {
      for frame in 0...1 {
        let name = state.assetName(frame: frame, reduceMotion: false)
        let contents = catalog.appendingPathComponent("\(name).imageset/Contents.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: contents))
        let root = try #require(json as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        #expect(properties["template-rendering-intent"] as? String == "template", "\(name)")
        let images = try #require(root["images"] as? [[String: Any]])
        #expect(Set(images.compactMap { $0["scale"] as? String }) == ["1x", "2x"], "\(name)")
        for image in images {
          let file = try #require(image["filename"] as? String)
          let png = catalog.appendingPathComponent("\(name).imageset/\(file)")
          #expect(FileManager.default.fileExists(atPath: png.path), "\(name)/\(file)")
        }
      }
    }
  }
}
