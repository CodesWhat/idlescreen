import Foundation

/// What the menu bar glyph shows. Resolved from the app's live state with a
/// fixed precedence: a failure outranks any phase.
enum IdleScreenMenuBarState: CaseIterable, Equatable {
  case idle
  case running
  case camera
  case attention
  case setup

  /// The facts the glyph depends on, already reduced to booleans so the
  /// precedence stays a pure function.
  struct Inputs: Equatable {
    /// The extension is not registered or embedded, the saver is not selected,
    /// or the camera service failed.
    var needsSetup = false
    /// An agent signal is waiting on the user.
    var needsAttention = false
    /// The companion camera client has a live preview stream.
    var cameraStreaming = false
    /// The screen saver is running or starting.
    var running = false
  }

  /// setup > attention > camera > running > idle.
  static func resolve(_ inputs: Inputs) -> IdleScreenMenuBarState {
    if inputs.needsSetup { return .setup }
    if inputs.needsAttention { return .attention }
    if inputs.cameraStreaming { return .camera }
    if inputs.running { return .running }
    return .idle
  }

  /// Seconds between the two frames of an animated state.
  static let frameInterval: TimeInterval = 0.7

  /// Only running and camera move, and never under Reduce Motion.
  func animates(reduceMotion: Bool) -> Bool {
    switch self {
    case .running, .camera: !reduceMotion
    case .idle, .attention, .setup: false
    }
  }

  /// The glyph asset for a frame. Reduce Motion pins frame 0.
  func assetName(frame: Int, reduceMotion: Bool) -> String {
    let second = frame % 2 != 0 && !reduceMotion
    switch self {
    case .idle: return "MenuBarCRTIdle"
    case .running: return second ? "MenuBarCRTRunning1" : "MenuBarCRTRunning0"
    case .camera: return second ? "MenuBarCRTCamera1" : "MenuBarCRTCamera0"
    case .attention: return "MenuBarCRTAttention"
    case .setup: return "MenuBarCRTSetup"
    }
  }

  var accessibilityDescription: String {
    switch self {
    case .idle: "IdleScreen, ready"
    case .running: "IdleScreen, screen saver running"
    case .camera: "IdleScreen, camera on"
    case .attention: "IdleScreen, needs attention"
    case .setup: "IdleScreen needs setup"
    }
  }
}
