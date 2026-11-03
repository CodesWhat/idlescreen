import IdleScreenCamera
import IdleScreenSystem

// What the Status page says, as plain values. The page draws three cards (screen saver, camera, agent signals) and one verdict
// line; everything here is a pure function of `StatusInputs`, so tests assert the words and actions without drawing pixels. The
// screen saver card reads its register and choose steps from `SetupProgress` and the camera card takes its permission copy from
// `CameraCardGuidance`, so setup, Studio and Status cannot disagree.

/// The live facts the page reads. Nothing is stored: the view rebuilds it from the model and the camera client.
struct StatusInputs: Equatable {
  var saverStatusKnown = true
  var extensionEmbedded = true
  var macOSCompatible = true
  var registrationLocation: ScreenSaverRegistrationLocation = .currentBuild
  var selectedEverywhere = true
  /// False in a development build that has no signed App Group container.
  var sharedContainerAvailable = true
  var setupCompleted = true
  /// The saver is set to a look that reads the camera.
  var cameraInUse = false
  var cameraAuthorization: CameraAgentAuthorizationObservation = .observed(.authorized)
  /// Runtime, agent, identity, status check or service trouble. Permission is reported separately.
  var cameraHasFault = false
  var codexHooksInstalled = false
  var claudeHooksInstalled = false
}

/// What a button on the page does. The view maps each case to a model or navigation call.
enum StatusAction: Equatable {
  case registerSaver
  case repairSaver
  case openScreenSaverSettings
  case openSetup
  case allowCamera
  case openCameraPrivacy
  case fixCamera
  case openAgents

  var title: String {
    switch self {
    case .registerSaver: "Register IdleScreen"
    case .repairSaver: "Repair IdleScreen"
    case .openScreenSaverSettings: "Open Screen Saver settings"
    case .openSetup: "Open setup"
    case .allowCamera: "Allow camera access"
    case .openCameraPrivacy: "Open camera privacy"
    case .fixCamera: "Fix camera"
    case .openAgents: "Set up in Agents"
    }
  }
}

enum StatusSaverState: Equatable {
  case checking
  case ready
  case notRegistered
  case notSelected
  case outOfDate
  case missing
  case unsupported

  var word: String {
    switch self {
    case .checking: "Checking"
    case .ready: "Ready"
    case .notRegistered: "Not registered"
    case .notSelected: "Not selected"
    case .outOfDate: "Out of date"
    case .missing: "Missing from this copy"
    case .unsupported: "Not supported"
    }
  }

  var sentence: String {
    switch self {
    case .checking: "Checking this Mac…"
    case .ready: "IdleScreen is your screen saver."
    case .notRegistered: "macOS doesn't know about IdleScreen yet."
    case .notSelected: "Pick IdleScreen in Screen Saver settings."
    case .outOfDate: "macOS is using an older copy of IdleScreen."
    case .missing: "This copy of IdleScreen is missing its screen saver. Reinstall IdleScreen."
    case .unsupported: "This version of macOS can't run the IdleScreen screen saver."
    }
  }

  var kind: DesignStatusKind {
    switch self {
    case .checking: .pending
    case .ready: .ok
    case .notRegistered, .notSelected, .outOfDate: .attention
    case .missing, .unsupported: .error
    }
  }

  var action: StatusAction? {
    switch self {
    case .notRegistered: .registerSaver
    case .outOfDate: .repairSaver
    case .notSelected: .openScreenSaverSettings
    case .checking, .ready, .missing, .unsupported: nil
    }
  }

  var isProblem: Bool { self != .ready && self != .checking }

  static func resolve(_ inputs: StatusInputs) -> StatusSaverState {
    guard inputs.saverStatusKnown else { return .checking }
    guard inputs.extensionEmbedded else { return .missing }
    guard inputs.macOSCompatible else { return .unsupported }
    let progress = SetupProgress(
      SetupInputs(
        registrationCurrent: inputs.registrationLocation == .currentBuild,
        selectedEverywhere: inputs.selectedEverywhere,
        cameraAccess: .unknown, cameraSkipped: false))
    if progress.status(.register) != .done {
      return inputs.registrationLocation == .differentCopy ? .outOfDate : .notRegistered
    }
    return progress.status(.choose) == .done ? .ready : .notSelected
  }
}

enum StatusCameraState: Equatable {
  case checking
  case off
  case ready
  case needsPermission
  case blockedByPolicy
  case notWorking

  var word: String {
    switch self {
    case .checking: "Checking"
    case .off: "Off"
    case .ready: "Ready"
    case .needsPermission: "Needs permission"
    case .blockedByPolicy: "Blocked by policy"
    case .notWorking: "Not working"
    }
  }

  var kind: DesignStatusKind {
    switch self {
    case .checking: .pending
    case .off: .neutral
    case .ready: .ok
    case .needsPermission: .attention
    case .blockedByPolicy, .notWorking: .error
    }
  }

  var isProblem: Bool {
    switch self {
    case .needsPermission, .blockedByPolicy, .notWorking: true
    case .checking, .off, .ready: false
    }
  }

  /// A camera nobody uses is Off, whatever its permission or agent is doing. Only a camera the saver reads can be a problem.
  static func resolve(_ inputs: StatusInputs) -> StatusCameraState {
    let authorization = inputs.cameraAuthorization
    guard inputs.cameraInUse else {
      let working =
        authorization == .observed(.authorized) && !inputs.cameraHasFault
        && inputs.sharedContainerAvailable
      return working ? .ready : .off
    }
    if authorization == .observed(.restricted) { return .blockedByPolicy }
    if !inputs.sharedContainerAvailable || inputs.cameraHasFault { return .notWorking }
    switch authorization {
    case .observed(.notDetermined), .observed(.denied): return .needsPermission
    case .observed(.authorized): return .ready
    case .observed(.restricted): return .blockedByPolicy
    case .unknown: return .checking
    }
  }
}

enum StatusAgentState: Equatable {
  case installed
  case notInstalled
  case unavailable

  var word: String {
    switch self {
    case .installed: "Installed"
    case .notInstalled: "Not installed"
    case .unavailable: "Unavailable in this build"
    }
  }

  var kind: DesignStatusKind {
    switch self {
    case .installed: .ok
    case .notInstalled, .unavailable: .neutral
    }
  }

  static func resolve(installed: Bool, sharedContainerAvailable: Bool) -> StatusAgentState {
    if installed { return .installed }
    return sharedContainerAvailable ? .notInstalled : .unavailable
  }
}

/// One card: a word, a symbol kind, one short sentence and at most one button.
struct StatusCard: Equatable {
  let title: String
  let word: String
  let kind: DesignStatusKind
  let sentence: String
  let action: StatusAction?
}

struct StatusAgentRow: Equatable {
  let name: String
  let state: StatusAgentState
}

struct StatusSummary: Equatable {
  static let developmentBuildNotice =
    "This is a development build. Camera and agent signals need a signed copy of IdleScreen."

  let saverState: StatusSaverState
  let cameraState: StatusCameraState
  let saver: StatusCard
  let camera: StatusCard
  let agents: [StatusAgentRow]
  let agentsSentence: String
  let agentsAction: StatusAction
  let isDevelopmentBuild: Bool

  init(_ inputs: StatusInputs) {
    saverState = StatusSaverState.resolve(inputs)
    cameraState = StatusCameraState.resolve(inputs)
    isDevelopmentBuild = !inputs.sharedContainerAvailable

    saver = StatusCard(
      title: "Screen saver", word: saverState.word, kind: saverState.kind,
      sentence: saverState.sentence, action: saverState.action)
    camera = Self.cameraCard(state: cameraState, inputs: inputs)

    agents = [
      StatusAgentRow(
        name: "Codex",
        state: .resolve(
          installed: inputs.codexHooksInstalled,
          sharedContainerAvailable: inputs.sharedContainerAvailable)),
      StatusAgentRow(
        name: "Claude",
        state: .resolve(
          installed: inputs.claudeHooksInstalled,
          sharedContainerAvailable: inputs.sharedContainerAvailable)),
    ]
    agentsSentence =
      inputs.sharedContainerAvailable
      ? "Show what Codex and Claude are doing on your screen saver."
      : "Agent signals aren't available in this build."
    agentsAction = .openAgents
  }

  /// The problems, most important first. Agent signals are optional, so they never count.
  var problems: [StatusCard] {
    var result: [StatusCard] = []
    if saverState.isProblem { result.append(saver) }
    if cameraState.isProblem { result.append(camera) }
    return result
  }

  var isChecking: Bool { saverState == .checking || cameraState == .checking }

  var verdict: String {
    Self.verdict(problemCount: problems.count, isChecking: isChecking)
  }

  /// The short form of the verdict for Studio's status pill: sentence case, no full stop. A saver that isn't registered or
  /// selected yet is "Needs setup"; any other trouble is "Needs attention".
  var pillLabel: String {
    if problems.isEmpty { return isChecking ? "Checking IdleScreen" : "IdleScreen is ready" }
    if saverState.isProblem, saverState.action != nil { return "Needs setup" }
    return "Needs attention"
  }

  var pillKind: DesignStatusKind {
    if problems.isEmpty { return isChecking ? .pending : .ok }
    return problems.contains { $0.kind == .error } ? .error : .attention
  }

  /// The one button at the top: the first problem that has something to press.
  var primaryAction: StatusAction? {
    problems.lazy.compactMap(\.action).first
  }

  static func verdict(problemCount: Int, isChecking: Bool) -> String {
    switch problemCount {
    case 0: isChecking ? "Checking IdleScreen…" : "IdleScreen is ready."
    case 1: "One thing needs your attention."
    default: "\(problemCount) things need your attention."
    }
  }

  private static func cameraCard(state: StatusCameraState, inputs: StatusInputs) -> StatusCard {
    let guidance = CameraCardGuidance.make(
      authorization: inputs.cameraAuthorization, setupCompleted: inputs.setupCompleted)
    let sentence: String
    let action: StatusAction?
    switch state {
    case .checking:
      sentence = "Checking the camera…"
      action = nil
    case .off:
      sentence = "Nothing you've chosen uses the camera."
      action = nil
    case .ready:
      sentence = "The camera is ready."
      action = nil
    case .needsPermission:
      sentence = guidance.detail
      action = guidance.action.statusAction
    case .blockedByPolicy:
      sentence = guidance.detail
      action = nil
    case .notWorking:
      if !inputs.sharedContainerAvailable {
        sentence = "The camera needs a signed copy of IdleScreen."
        action = nil
      } else {
        sentence = "The camera isn't working."
        action = inputs.setupCompleted ? .fixCamera : .openSetup
      }
    }
    return StatusCard(
      title: "Camera", word: state.word, kind: state.kind, sentence: sentence, action: action)
  }
}

extension CameraCardGuidance.Action {
  /// Studio's "Open status" has nothing to open on the Status page itself, so it becomes the camera fix.
  fileprivate var statusAction: StatusAction? {
    switch self {
    case .openSetup: .openSetup
    case .allowAccess: .allowCamera
    case .openCameraPrivacy: .openCameraPrivacy
    case .openStatus: .fixCamera
    case .none: nil
    }
  }
}

/// Camera trouble other than permission, in the terms Studio uses to decide the camera stopped working.
enum StatusCameraFault {
  static func hasFault(
    snapshot: CameraAgentOnboardingSnapshot, bootstrap: CameraClientBootstrapStatus?,
    control: CameraAgentControlReachability
  ) -> Bool {
    if let bootstrap, bootstrap != .ready { return true }
    switch snapshot.serviceRegistration {
    case .notRegistered, .notFound, .requiresApproval, .failed: return true
    case .unknown, .enabled: break
    }
    switch snapshot.identity {
    case .absent, .stale, .mismatched: return true
    case .unknown, .current: break
    }
    switch snapshot.liveSnapshot {
    case .unavailable, .rejected: return true
    case .unknown, .accepted: break
    }
    switch control {
    case .unreachable, .timedOut: return true
    case .unknown, .reachable: return false
    }
  }
}
