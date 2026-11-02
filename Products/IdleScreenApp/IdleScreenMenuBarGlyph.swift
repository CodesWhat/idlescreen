import AppKit
import IdleScreenCore
import Observation

/// Drives the menu bar glyph: resolves the state from the model and the companion
/// camera client, and alternates frames only while
/// the state animates. There is no timer in idle, setup or attention, or under
/// Reduce Motion.
@MainActor
@Observable
final class IdleScreenMenuBarGlyph {
  private(set) var state: IdleScreenMenuBarState = .idle
  private(set) var frame = 0
  private(set) var reduceMotion: Bool

  @ObservationIgnored private let model: IdleScreenAppModel
  @ObservationIgnored private let cameraClient: IdleScreenCompanionCameraClient
  @ObservationIgnored private var frameTimer: Timer?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  init(
    model: IdleScreenAppModel,
    cameraClient: IdleScreenCompanionCameraClient
  ) {
    self.model = model
    self.cameraClient = cameraClient
    reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  static let pointSize = NSSize(width: 16, height: 15)

  @ObservationIgnored private var imageCache: [String: NSImage] = [:]
  @ObservationIgnored private var lastSetupVerdict: Bool?

  var assetName: String {
    state.assetName(frame: frame, reduceMotion: reduceMotion)
  }

  /// One configured copy per asset, so the shared `NSImage(named:)` instance
  /// is never mutated.
  var image: NSImage {
    let name = assetName
    if let cached = imageCache[name] { return cached }
    let image =
      (NSImage(named: name)?.copy() as? NSImage) ?? NSImage(size: Self.pointSize)
    image.size = Self.pointSize
    image.isTemplate = true
    image.accessibilityDescription = state.accessibilityDescription
    imageCache[name] = image
    return image
  }

  func start() {
    guard !started else { return }
    started = true
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reduceMotionChanged() }
      }
    )
    // The saver runs in another process, so its start and stop arrive as
    // distributed notifications. Each one re-reads the health reports.
    for name in ["com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
      observers.append(
        DistributedNotificationCenter.default().addObserver(
          forName: Notification.Name(name),
          object: nil,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.saverLifecycleChanged() }
        }
      )
    }
    track()
  }

  private var inputs: IdleScreenMenuBarState.Inputs {
    IdleScreenMenuBarState.Inputs(
      needsSetup: needsSetup,
      needsAttention: model.activeAgentSignal?.state == .needsAttention,
      cameraStreaming: cameraClient.isPreviewLeaseAttached && cameraClient.previewImage != nil,
      running: isRunning
    )
  }

  /// Only a live report counts. `extensionHealth` falls back to the newest
  /// report when none is live, which would keep a crashed saver animating.
  private var isRunning: Bool {
    let report = model.extensionHealth
    return IdleScreenMenuBarState.isRunning(
      starting: model.isStartingScreenSaver,
      reportIsLive: report.map(model.isProcessReportLive) ?? false,
      reportIsAnimating: report?.lifecycle == .animating
    )
  }

  /// Same facts as the menu's `isReady`, plus the embed check. A refresh in
  /// flight keeps the last verdict.
  private var needsSetup: Bool {
    let facts = IdleScreenMenuBarState.SetupFacts(
      isExtensionEmbedded: model.isExtensionEmbedded,
      isRefreshing: model.isRefreshing,
      hasFreshSaverStatus: model.hasFreshSaverStatus,
      isCurrentBuild: model.registrationAssessment.isCurrentBuild,
      isSelectedEverywhere: model.selection?.isSelectedEverywhere == true,
      refreshFailed: model.selection == nil && model.lastError != nil
    )
    let verdict = IdleScreenMenuBarState.needsSetup(facts, previous: lastSetupVerdict)
    if facts.isExtensionEmbedded, facts.hasFreshSaverStatus || facts.refreshFailed {
      lastSetupVerdict = verdict
    }
    return verdict
  }

  /// Re-evaluates whenever anything read by `inputs` changes.
  private func track() {
    let resolved = withObservationTracking {
      IdleScreenMenuBarState.resolve(inputs)
    } onChange: { [weak self] in
      Task { @MainActor in self?.track() }
    }
    apply(resolved)
  }

  private func apply(_ resolved: IdleScreenMenuBarState) {
    if resolved != state {
      state = resolved
      frame = 0
    }
    updateTimer()
  }

  private func updateTimer() {
    guard state.animates(reduceMotion: reduceMotion) else {
      frameTimer?.invalidate()
      frameTimer = nil
      return
    }
    guard frameTimer == nil else { return }
    let timer = Timer(timeInterval: IdleScreenMenuBarState.frameInterval, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.advanceFrame() }
    }
    RunLoop.main.add(timer, forMode: .common)
    frameTimer = timer
  }

  private func advanceFrame() {
    frame = (frame + 1) % 2
  }

  private func reduceMotionChanged() {
    reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    frame = 0
    updateTimer()
  }

  private func saverLifecycleChanged() {
    model.refreshProcessHealth()
    // The extension writes its health report just after the notification.
    Task { @MainActor [weak model] in
      try? await Task.sleep(for: .seconds(1.5))
      model?.refreshProcessHealth()
    }
  }
}
