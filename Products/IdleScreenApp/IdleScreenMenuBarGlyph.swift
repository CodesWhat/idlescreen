import AppKit
import IdleScreenCore
import IdleScreenDisplay
import Observation

/// Drives the menu bar glyph: resolves the state from the model, the companion
/// camera client and the display coordinator, and alternates frames only while
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
  @ObservationIgnored private let displayCoordinator: DisplaySceneCoordinator
  @ObservationIgnored private var frameTimer: Timer?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  init(
    model: IdleScreenAppModel,
    cameraClient: IdleScreenCompanionCameraClient,
    displayCoordinator: DisplaySceneCoordinator
  ) {
    self.model = model
    self.cameraClient = cameraClient
    self.displayCoordinator = displayCoordinator
    reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  static let pointSize = NSSize(width: 16, height: 15)

  var image: NSImage {
    let name = state.assetName(frame: frame, reduceMotion: reduceMotion)
    let image = NSImage(named: name) ?? NSImage(size: Self.pointSize)
    image.size = Self.pointSize
    image.isTemplate = true
    image.accessibilityDescription = state.accessibilityDescription
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
      running: model.isStartingScreenSaver
        || model.extensionHealth?.lifecycle == .animating
        || displayCoordinator.latestPlan != nil
    )
  }

  /// Not registered or embedded, not selected once the status is fresh, or a
  /// camera service failure. A refresh in flight is not a failure.
  private var needsSetup: Bool {
    if !model.isExtensionEmbedded { return true }
    if model.hasFreshSaverStatus {
      let ready =
        model.registrationAssessment.isCurrentBuild
        && model.selection?.isSelectedEverywhere == true
      if !ready { return true }
    }
    if case .unavailable = cameraClient.cameraAgentDiagnosticState { return true }
    return false
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
