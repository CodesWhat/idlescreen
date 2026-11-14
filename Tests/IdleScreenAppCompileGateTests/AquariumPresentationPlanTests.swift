import AppKit
import Foundation
import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import MetalKit
import SwiftUI
import Testing

@Suite("Aquarium display presentation planning")
@MainActor
struct AquariumPresentationPlanTests {
  @Test(arguments: [
    "com.idlescreen.aquarium-qa.dev", "com.idlescreen.aquarium-qa.review-one",
    "com.idlescreen.aquarium-qa", "com.idlescreen.app.dev", "com.idlescreen.app",
  ])
  func isolatedQAStoreProfileAppliesOnlyToTheDebugQABundle(bundleID: String) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let contents = directory.appending(path: "Review.bundle/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let expected = directory.appending(path: "private-tanks/aquariums-v1.json")
    let info: [String: Any] = [
      "CFBundleIdentifier": bundleID, "CFBundlePackageType": "BNDL",
      "IdleScreenSharedContainerEnabled": "NO", "IdleScreenAquariumQAStorePath": expected.path,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appending(path: "Info.plist"))
    let bundle = try #require(Bundle(url: contents.deletingLastPathComponent()))
    let result = IdleScreenAquariumProduct.storeURL(bundle: bundle)
    #expect((result == expected) == bundleID.hasPrefix("com.idlescreen.aquarium-qa."))
    #expect(!FileManager.default.fileExists(atPath: expected.path))
  }

  @Test func nonAquariumMappingAndClocksIgnoreSavedTankEpoch() {
    let library = IdleScreenAquariumLibrary.starter
    let mapped = IdleScreenRendererConfigurationBridge.configuration(
      for: .default, assignment: nil, aquarium: library)
    #expect(mapped.aquariumSettings == nil)
    var frame = IdleScreenAquariumProduct.configuration(for: library.tanks[0])
    let now = library.tanks[0].presentationEpoch.addingTimeInterval(200 * 86_400)
    #expect(
      IdleScreenAquariumProduct.sceneElapsed(
        configuration: frame, mode: .generative, sessionElapsed: 12, at: now) == 200 * 86_400)
    #expect(
      IdleScreenAquariumProduct.sceneElapsed(
        configuration: frame, mode: .camera, sessionElapsed: 12, at: now) == 12)
    frame.patternRawValue = IdleScreenConfiguration.default.creative.pattern.rawValue
    #expect(
      IdleScreenAquariumProduct.sceneElapsed(
        configuration: frame, mode: .generative, sessionElapsed: 12, at: now) == 12)
  }

  @Test func savedTankMappingIsCachedUntilItsInputsChange() throws {
    var calls = 0
    var cache = IdleScreenAquariumPresentationCache { tank, aspect in
      calls += 1
      return IdleScreenAquariumProduct.settings(for: tank, worldAspect: aspect)
    }
    var configuration = IdleScreenConfiguration.default
    var library = IdleScreenAquariumLibrary.starter
    func resolve(_ reduceMotion: Bool = false, hourOffset: Int = 0)
      -> IdleScreenAquariumRenderSettings?
    {
      cache.settings(
        for: configuration, assignment: nil, library: library,
        reduceMotion: reduceMotion, hourOffset: hourOffset)
    }
    #expect(resolve() == nil && calls == 0)
    configuration.creative.pattern = .aquarium
    let first = resolve()
    for _ in 0..<30 { #expect(resolve() == first) }
    #expect(calls == 1)
    library.tanks[0].seed = 999
    library.revision += 1
    #expect(resolve()?.seed == 999 && calls == 2)
    let other = IdleScreenAquariumTank(name: "Other")
    library.tanks.append(other)
    library.selectedTankID = other.id
    #expect(resolve()?.seed == other.seed && calls == 3)
    #expect(resolve(true)?.reduceMotion == true && calls == 4)
    #expect(resolve(true, hourOffset: 3_600)?.hourOffset == 3_600 && calls == 5)
    library.presentation = .panorama
    library.revision += 1
    let topology = try DisplayTopology(displays: [
      display("left", x: 0, primary: true), display("right", x: 1_000),
    ])
    let assignment = try DisplayScenePlanner().makePlan(
      for: .init(generation: 1, topology: topology), settings: .init(policy: .panorama),
      sceneEpoch: 1
    ).assignments[0]
    let panorama = cache.settings(
      for: configuration, assignment: assignment, library: library,
      reduceMotion: true, hourOffset: 3_600)
    #expect(panorama?.worldWidth == 720 && calls == 6)
    #expect(
      cache.settings(
        for: configuration, assignment: assignment, library: library,
        reduceMotion: true, hourOffset: 3_600) == panorama && calls == 6)
  }

  @Test func previewRenderingFollowsWindowNotificationsAndStopsAfterDismantling() {
    let view = AquariumPreviewTestSurface(frame: .zero)
    let window = AquariumVisibilityWindow(
      contentRect: .zero, styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    let coordinator = IdleScreenAquariumMetalPreview.Coordinator()
    coordinator.configure(view: view, reduceMotion: false, rendererAvailable: true)
    #expect(!view.isPaused)
    window.testMiniaturized = true
    NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
    #expect(view.isPaused)
    window.testMiniaturized = false
    NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
    #expect(!view.isPaused)
    window.testVisible = false
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
    #expect(view.isPaused)
    window.testVisible = true
    window.testOcclusion = []
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
    #expect(view.isPaused)
    window.testOcclusion = .visible
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
    #expect(!view.isPaused)
    coordinator.configure(view: view, reduceMotion: true, rendererAvailable: true)
    #expect(view.isPaused && view.enableSetNeedsDisplay)
    coordinator.configure(view: view, reduceMotion: false, rendererAvailable: false)
    #expect(view.isPaused)
    coordinator.configure(view: view, reduceMotion: false, rendererAvailable: true)
    let replacement = AquariumVisibilityWindow(
      contentRect: .zero, styleMask: .borderless,
      backing: .buffered, defer: false)
    replacement.isReleasedWhenClosed = false
    defer { replacement.close() }
    window.contentView = nil
    #expect(view.isPaused)
    replacement.contentView = view
    #expect(!view.isPaused)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    #expect(!view.isPaused)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: replacement)
    #expect(view.isPaused)
    coordinator.shutdown()
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: replacement)
    #expect(view.isPaused)
  }

  @Test func panoramaResolvesAttachedMossAtItsRenderedWorldWidth() throws {
    var library = IdleScreenAquariumLibrary.starter
    let wood = IdleScreenAquariumDecoration(kind: .driftwood, x: 0.5, y: 0.9)
    let moss = IdleScreenAquariumDecoration(kind: .moss, x: 0.3, y: 0.9)
    library.tanks[0].decorations = [wood, moss]
    try library.tanks[0].attachMoss(id: moss.id, to: wood.id)
    library.presentation = .panorama
    let topology = try DisplayTopology(displays: [
      display("left", x: 0, primary: true), display("right", x: 1_000),
    ])
    let plans = try IdleScreenAquariumPresentationPlanner.surfaces(
      library: library, topology: topology)
    let expected = IdleScreenAquariumProduct.settings(
      for: library.tanks[0], worldAspect: 2_000.0 / 600)
    for plan in plans {
      #expect(plan.configuration.aquariumSettings == expected)
    }
  }

  @Test func feedingEventUsesTheSameEpochInEveryPresentation() throws {
    var library = IdleScreenAquariumLibrary.starter
    let fedAt = library.tanks[0].presentationEpoch.addingTimeInterval(90_000)
    try library.feed(at: fedAt)
    #expect(IdleScreenAquariumProduct.settings(for: library.tanks[0]).lastFeedingElapsed == 90_000)
    let topology = try DisplayTopology(displays: [display("main", x: 0, primary: true)])
    for presentation in [IdleScreenAquariumPresentation.perDisplay, .panorama] {
      library.presentation = presentation
      let surfaces = try IdleScreenAquariumPresentationPlanner.surfaces(
        library: library, topology: topology)
      #expect(surfaces[0].configuration.aquariumSettings?.lastFeedingElapsed == 90_000)
    }
    var configuration = IdleScreenConfiguration.default
    configuration.creative.pattern = .aquarium
    let saver = IdleScreenRendererConfigurationBridge.configuration(
      for: configuration, assignment: nil, aquarium: library, reduceMotion: false)
    #expect(saver.aquariumSettings?.lastFeedingElapsed == 90_000)
  }

  @Test func catalogPreviewUsesTankScaleWithoutPurchasingOrChangingSavedStock() {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].worldSize = .wide
    library.tanks[0].lighting.preset = .blacklight
    library.tanks[0].nursery = [.init(species: .snail)]
    let original = library
    for species in IdleScreenAquariumSpeciesKind.allCases {
      let preview = IdleScreenAquariumProduct.previewTank(
        for: species, variant: .red, sex: .male, in: library.tanks[0])
      #expect(preview.animals.count == 1)
      #expect(preview.animals[0].species == species)
      #expect(preview.animals[0].sex == .male)
      #expect(preview.animals[0].isAdult)
      #expect(preview.broods.isEmpty)
      #expect(preview.nursery.isEmpty)
      #expect(preview.decorations == original.tanks[0].decorations)
      #expect(preview.lighting == original.tanks[0].lighting)
      #expect(preview.automation == original.tanks[0].automation)
      let settings = IdleScreenAquariumProduct.settings(for: preview)
      #expect(settings.worldWidth == 768)
      #expect(settings.inhabitants.count == 1)
      #expect(
        settings
          == IdleScreenAquariumProduct.settings(
            for: IdleScreenAquariumProduct.previewTank(
              for: species, variant: .red, sex: .male, in: library.tanks[0])))
    }
    #expect(library == original)
  }

  @Test func mirrorsDoNotCreateExtraWindowsAndAssignmentsSurviveReorder() throws {
    var library = IdleScreenAquariumLibrary.starter
    let secondID = UUID()
    try library.duplicateLayout(of: library.selectedTankID, id: secondID, name: "Other tank")
    try library.assign(tankID: library.tanks[0].id, to: "left")
    try library.assign(tankID: secondID, to: "right")
    let topology = try DisplayTopology(displays: [
      display("right", x: 1_000), display("mirror", x: 0, mirror: "left"),
      display("left", x: 0, primary: true),
    ])
    let plan = try IdleScreenAquariumPresentationPlanner.surfaces(
      library: library, topology: topology)
    #expect(plan.count == 2)
    #expect(plan.first { $0.displayID == "left" }?.tank.id == library.tanks[0].id)
    #expect(plan.first { $0.displayID == "right" }?.tank.id == secondID)
    #expect(plan.allSatisfy { $0.configuration.viewport == .full })
    library.presentation = .panorama
    let panorama = try IdleScreenAquariumPresentationPlanner.surfaces(
      library: library, topology: topology)
    #expect(panorama.allSatisfy { $0.tank.id == secondID })
    #expect(panorama[0].configuration.aquariumSettings?.worldWidth ?? 0 > 384)
    #expect(
      panorama[0].configuration.aquariumSettings?.epoch
        == panorama[1].configuration.aquariumSettings?.epoch)
    #expect(panorama[0].configuration.viewport.width == 0.5)
  }

  @Test func savedLayoutPolicyAndWorldAreSharedByEveryHost() {
    var configuration = IdleScreenConfiguration.default
    configuration.creative.pattern = .aquarium
    configuration.revision = 7
    var library = IdleScreenAquariumLibrary.starter
    library.revision = 9
    library.presentation = .perDisplay
    #expect(
      IdleScreenAquariumProduct.displaySettings(configuration: configuration, library: library)
        .policy == .perDisplay)
    #expect(
      IdleScreenAquariumProduct.presentationRevision(configuration: configuration, library: library)
        == 16)
    configuration.creative.pattern = .plasma
    #expect(
      IdleScreenAquariumProduct.displaySettings(configuration: configuration, library: library)
        == configuration.display)
    #expect(
      IdleScreenAquariumProduct.presentationRevision(configuration: configuration, library: library)
        == 16)
    let settings = IdleScreenAquariumProduct.settings(for: library.tanks[0], worldAspect: 3.5)
    #expect(settings.worldWidth == 756)
  }

  @Test func savedWorldLengthReachesEachHostWithoutScalingAnimals() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].worldSize = .wide
    let settings = IdleScreenAquariumProduct.settings(for: library.tanks[0], worldAspect: 2)
    #expect(settings.worldWidth == 768)
    let topology = try DisplayTopology(displays: [display("main", x: 0, primary: true)])
    for presentation in [IdleScreenAquariumPresentation.perDisplay, .panorama] {
      library.presentation = presentation
      let surfaces = try IdleScreenAquariumPresentationPlanner.surfaces(
        library: library, topology: topology)
      #expect(surfaces[0].configuration.aquariumSettings?.worldWidth == 768)
    }
  }

  @Test func productMappingPropagatesReducedMotionForStudioAndSaver() {
    let library = IdleScreenAquariumLibrary.starter
    var configuration = IdleScreenConfiguration.default
    configuration.creative.pattern = .aquarium
    let mapped = IdleScreenRendererConfigurationBridge.configuration(
      for: configuration, assignment: nil, aquarium: library, reduceMotion: true)
    #expect(mapped.aquariumSettings?.reduceMotion == true)
  }

  @Test func lifecycleAndEnergyPolicyHaveExplicitStopConditions() {
    var policy = IdleScreenAquariumPresentationPolicy()
    #expect(policy.framesPerSecond == 60)
    policy.lowPower = true
    #expect(policy.framesPerSecond == 12)
    policy.lowPower = false
    policy.renderCost = 0.1
    #expect(policy.framesPerSecond == 8)
    policy.renderCost = 0
    policy.reduceMotion = true
    #expect(policy.framesPerSecond == 0)
    policy.reduceMotion = false
    policy.sessionActive = false
    #expect(policy.framesPerSecond == 0)
    policy.sessionActive = true
    policy.screensAwake = false
    #expect(policy.framesPerSecond == 0)
  }

  @Test func powerSourceAndLowPowerModeSelectTheCeilingAndDrawBudget() {
    var policy = IdleScreenAquariumPresentationPolicy()
    #expect(policy.framesPerSecond == 60)
    policy.powerSource = .battery
    #expect(policy.framesPerSecond == 30)
    // Budget over cost: AC 0.8, battery 0.4 with a 30 fps cap, Low Power Mode 0.08 with 12 fps.
    policy.renderCost = 0.1
    #expect(policy.framesPerSecond == 4)
    policy.powerSource = .ac
    #expect(policy.framesPerSecond == 8)
    policy.renderCost = 0.001
    #expect(policy.framesPerSecond == 60)
    policy.powerSource = .battery
    #expect(policy.framesPerSecond == 30)
    policy.lowPower = true
    #expect(policy.framesPerSecond == 12)
    policy.renderCost = 0.02
    #expect(policy.framesPerSecond == 4)
    policy.powerSource = .ac
    #expect(policy.framesPerSecond == 4)
    policy.lowPower = false
    #expect(policy.framesPerSecond == 40)
    policy.renderCost = .nan
    #expect(policy.framesPerSecond == 0)
    policy.renderCost = 0
    policy.screensAwake = false
    #expect(policy.framesPerSecond == 0)
  }

  @Test func injectedPowerSourceTransitionsRetuneTheHostTimerAndStopAtShutdown() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    let power = PowerSourceStub()
    let host = IdleScreenAquariumPresentationHost(
      controller: controller, reducedMotion: { false }, powerSource: power.provider)
    host.start()
    #expect(power.observerCount == 1)
    #expect(host.policy.powerSource == .ac)
    host.showWindowed()
    defer { host.shutdown() }
    power.source = .battery
    await Task.detached { power.fire() }.value
    try await waitUntil { host.policy.powerSource == .battery }
    if host.isAnimating { #expect(host.timerRate <= 30) }
    power.source = .ac
    await Task.detached { power.fire() }.value
    try await waitUntil { host.policy.powerSource == .ac }
    if host.isAnimating { #expect(host.timerRate > 30) }
    host.shutdown()
    #expect(power.observerCount == 0)
    power.source = .battery
    power.fire()
    for _ in 0..<20 { await Task.yield() }
    #expect(host.policy.powerSource == .ac)
    #expect(host.timerRate == 0 && !host.isAnimating)
  }

  @Test func reducedMotionPreviewDoesNotRunAContinuousMetalClock() throws {
    let tank = try #require(IdleScreenAquariumLibrary.starter.selectedTank)
    let host = NSHostingView(
      rootView: IdleScreenAquariumMetalPreview(tank: tank, reduceMotion: true)
        .frame(width: 384, height: 216))
    host.frame = .init(x: 0, y: 0, width: 384, height: 216)
    host.layoutSubtreeIfNeeded()
    func metalView(in view: NSView) -> MTKView? {
      if let view = view as? MTKView { return view }
      return view.subviews.compactMap { metalView(in: $0) }.first
    }
    let metal = try #require(metalView(in: host))
    #expect(metal.device != nil)
    #expect(metal.isPaused)
  }

  @Test func studioAquariumAlsoStopsItsContinuousClockForReducedMotion() throws {
    var configuration = IdleScreenAquariumProduct.configuration(
      for: try #require(IdleScreenAquariumLibrary.starter.selectedTank))
    configuration.aquariumSettings?.reduceMotion = true
    let host = NSHostingView(
      rootView: IdleScreenMetalPreview(
        configuration: configuration, mode: .generative, cameraFrame: nil))
    host.frame = .init(x: 0, y: 0, width: 384, height: 216)
    host.layoutSubtreeIfNeeded()
    func metalView(in view: NSView) -> MTKView? {
      if let view = view as? MTKView { return view }
      return view.subviews.compactMap { metalView(in: $0) }.first
    }
    let metal = try #require(metalView(in: host))
    #expect(metal.device != nil)
    #expect(metal.isPaused)
  }

  @Test func windowHostReceivesTheActualAppKitResizeCallback() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    let host = IdleScreenAquariumPresentationHost(controller: controller)
    #expect(host.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
    host.shutdown()
  }

  @Test func hostHandlesLocalLifecycleEventsAndUnsubscribesAtShutdown() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    let host = IdleScreenAquariumPresentationHost(controller: controller, reducedMotion: { true })
    host.start()
    #expect(host.policy.reduceMotion)
    #expect(!host.isAnimating)
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    #expect(!host.policy.screensAwake)
    workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    #expect(host.policy.screensAwake)
    workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    #expect(!host.policy.sessionActive)
    workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    #expect(host.policy.sessionActive)
    host.shutdown()
    workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    #expect(host.policy.screensAwake)
    #expect(host.policy.sessionActive)
    #expect(host.desktopWindowCount == 0)
    #expect(!host.isAnimating)
  }

  @Test func powerStateNotificationFromABackgroundQueueUpdatesPolicyOnTheMainThread() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    let probe = ReducedMotionProbe()
    let host = IdleScreenAquariumPresentationHost(
      controller: controller, reducedMotion: { probe.read() })
    host.start()
    defer { host.shutdown() }
    #expect(!host.policy.reduceMotion)
    let initialReads = probe.reads
    probe.value = true
    await Task.detached {
      NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    }.value
    try await waitUntil { probe.reads > initialReads }
    #expect(probe.reads == initialReads + 1)
    #expect(probe.readsOnMainThread == probe.reads)
    #expect(host.policy.reduceMotion)
    #expect(!host.isAnimating)
  }

  @Test func shutdownDropsQueuedAndLaterPowerNotifications() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    let probe = ReducedMotionProbe()
    let host = IdleScreenAquariumPresentationHost(
      controller: controller, reducedMotion: { probe.read() })
    host.start()
    let reads = probe.reads
    probe.value = true
    // Delivery on the main thread queues the hop; shutdown runs before it can.
    NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    host.shutdown()
    await Task.detached {
      NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    }.value
    for _ in 0..<20 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(probe.reads == reads)
    #expect(!host.policy.reduceMotion)
    #expect(!host.isAnimating)
    #expect(host.desktopWindowCount == 0)
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not reached")
  }

  @Test func desktopWindowCannotStealKeyboardOrDesktopMouseInput() {
    let window = IdleScreenAquariumBackgroundWindow(
      frame: .init(x: 0, y: 0, width: 300, height: 200))
    defer { window.close() }
    #expect(!window.canBecomeKey)
    #expect(!window.canBecomeMain)
    #expect(window.ignoresMouseEvents)
    #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(window.collectionBehavior.contains(.ignoresCycle))
  }

  private func display(_ name: String, x: Double, primary: Bool = false, mirror: String? = nil)
    -> DisplayTopology.Display
  {
    .init(
      persistentIdentifier: .init(rawValue: name),
      logicalFrame: .init(x: x, y: 0, width: 1_000, height: 600),
      nativePixelSize: .init(width: 1_000, height: 600), backingScale: 1, rotationDegrees: 0,
      refreshRateRange: nil, safeAreaInsets: .zero, isPrimary: primary,
      mirrorTargetIdentifier: mirror.map { .init(rawValue: $0) })
  }
}

@MainActor
private final class AquariumVisibilityWindow: NSWindow {
  var testVisible = true
  var testMiniaturized = false
  var testOcclusion: NSWindow.OcclusionState = .visible
  override var isVisible: Bool { testVisible }
  override var isMiniaturized: Bool { testMiniaturized }
  override var occlusionState: NSWindow.OcclusionState { testOcclusion }
}

@MainActor
private final class AquariumPreviewTestSurface: NSView, IdleScreenAquariumPreviewSurface {
  var isPaused = true
  var enableSetNeedsDisplay = false
  var onWindowChange: (() -> Void)?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChange?()
  }
}

@MainActor
private final class ReducedMotionProbe {
  var value = false
  private(set) var reads = 0
  private(set) var readsOnMainThread = 0
  func read() -> Bool {
    reads += 1
    if Thread.isMainThread { readsOnMainThread += 1 }
    return value
  }
}

/// A power source whose AC/battery state and change notifications the test drives.
private final class PowerSourceStub: @unchecked Sendable {
  private let lock = NSLock()
  private var _source = IdleScreenPowerSource.ac
  private var handlers: [Int: @Sendable () -> Void] = [:]
  private var next = 0
  var source: IdleScreenPowerSource {
    get { lock.withLock { _source } }
    set { lock.withLock { _source = newValue } }
  }
  var observerCount: Int { lock.withLock { handlers.count } }
  func fire() {
    let current = lock.withLock { Array(handlers.values) }
    for handler in current { handler() }
  }
  var provider: IdleScreenPowerSourceProvider {
    .init(
      current: { self.source },
      observe: { handler in
        let id = self.lock.withLock { () -> Int in
          self.next += 1
          self.handlers[self.next] = handler
          return self.next
        }
        return { self.lock.withLock { _ = self.handlers.removeValue(forKey: id) } }
      })
  }
}
