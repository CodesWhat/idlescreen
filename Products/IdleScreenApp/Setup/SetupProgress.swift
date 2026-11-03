import Foundation

/// The first-run setup steps, in order.
enum SetupStep: Int, CaseIterable, Identifiable {
  case register
  case choose
  case camera

  var id: Int { rawValue }

  /// The camera is the one step a user can leave for later.
  var isOptional: Bool { self == .camera }
}

/// Where the camera permission stands, reduced to what setup needs.
enum SetupCameraAccess: Equatable {
  case unknown
  case notDetermined
  case authorized
  case blocked
  /// A policy on this Mac blocks the camera. Privacy & Security cannot fix it.
  case restricted
}

enum SetupStepStatus: Equatable {
  case done
  case current
  case upcoming
  case skipped
}

/// The live facts setup reads. Nothing here is stored: it is rebuilt from the model on every change.
struct SetupInputs: Equatable {
  var registrationCurrent: Bool
  var selectedEverywhere: Bool
  var cameraAccess: SetupCameraAccess
  var cameraSkipped: Bool
}

/// Step statuses and the current step, derived from `SetupInputs`. A step is done when its live state says so. The current step is
/// the first one that is neither done nor skipped, so steps advance on their own when the state flips.
struct SetupProgress: Equatable {
  let statuses: [SetupStep: SetupStepStatus]
  let current: SetupStep?

  init(_ inputs: SetupInputs) {
    var done: Set<SetupStep> = []
    if inputs.registrationCurrent { done.insert(.register) }
    if inputs.selectedEverywhere { done.insert(.choose) }
    if inputs.cameraAccess == .authorized { done.insert(.camera) }

    let settled = done.union(inputs.cameraSkipped ? [.camera] : [])
    current = SetupStep.allCases.first { !settled.contains($0) }

    var statuses: [SetupStep: SetupStepStatus] = [:]
    for step in SetupStep.allCases {
      if done.contains(step) {
        statuses[step] = .done
      } else if step == current {
        statuses[step] = .current
      } else if settled.contains(step) {
        statuses[step] = .skipped
      } else {
        statuses[step] = .upcoming
      }
    }
    self.statuses = statuses
  }

  var isComplete: Bool { current == nil }

  /// True once both required steps are done, whatever the camera is doing.
  var requiredStepsDone: Bool {
    statuses[.register] == .done && statuses[.choose] == .done
  }

  func status(_ step: SetupStep) -> SetupStepStatus { statuses[step] ?? .upcoming }
}

/// Where the "setup is finished" decision lives.
enum IdleScreenSetupStore {
  static let completedKey = "IdleScreenSetupCompleted"
}

extension SetupInputs {
  /// The inputs setup should draw from. Registration and selection come from a refresh that can fail or be in flight; while the
  /// status is not fresh, the last fresh answer stands, so a failed refresh cannot push a finished step back. Camera facts are
  /// observed separately and always pass through.
  static func settled(live: SetupInputs, lastFresh: SetupInputs?, isFresh: Bool) -> SetupInputs {
    guard !isFresh, let lastFresh else { return live }
    var result = live
    result.registrationCurrent = lastFresh.registrationCurrent
    result.selectedEverywhere = lastFresh.selectedEverywhere
    return result
  }
}

/// What the main window should do about setup right now, decided from the session and what macOS has reported.
struct SetupGateDecision: Equatable {
  /// Draw the steps (otherwise the "Checking your Mac" placeholder).
  var showsFlow: Bool
  /// This pass is the one upgrade auto-skip judgement; it must be recorded so it never runs again.
  var evaluatesAutoSkip: Bool
  /// A Mac that already has the required steps done: store completion without showing setup.
  var finishesSetup: Bool
}

enum SetupGate {
  /// The upgrade auto-skip judges once, on the first fresh status. A stale error shows the flow (so the error is visible) but
  /// never consumes the judgement, and nothing else ever finishes setup without the user. A refresh that is over without a
  /// fresh status (the model had nothing to ask) also shows the flow, so the window never sits on "Checking your Mac".
  static func decide(
    session: SetupSession,
    hasFreshStatus: Bool,
    hasError: Bool,
    requiredStepsDone: Bool,
    isRefreshing: Bool = true
  ) -> SetupGateDecision {
    if !session.autoSkipEvaluated, hasFreshStatus {
      return SetupGateDecision(
        showsFlow: !requiredStepsDone, evaluatesAutoSkip: true, finishesSetup: requiredStepsDone)
    }
    return SetupGateDecision(
      showsFlow: session.autoSkipEvaluated || hasError || !isRefreshing, evaluatesAutoSkip: false,
      finishesSetup: false)
  }

  /// The quiet Studio row that leads back into setup after "Set up later".
  static func showsStudioBanner(setupCompleted: Bool, requiredStepsDone: Bool) -> Bool {
    !setupCompleted && !requiredStepsDone
  }
}

/// Setup state that has to outlive the setup view, because the view is rebuilt whenever the user navigates away and back.
struct SetupSession: Equatable {
  var cameraSkipped = false
  var isDeferred = false
  var autoSkipEvaluated = false
  var lastFreshInputs: SetupInputs?

  mutating func skipCamera() { cameraSkipped = true }

  mutating func deferSetup() { isDeferred = true }

  /// "Continue setup" from the Studio banner.
  mutating func continueSetup() { isDeferred = false }

  /// "Open setup" from the Studio camera card: land on the camera step and never auto-finish.
  mutating func reopenFromCameraCard() {
    isDeferred = false
    cameraSkipped = false
    autoSkipEvaluated = true
  }

  mutating func apply(_ decision: SetupGateDecision) {
    if decision.evaluatesAutoSkip { autoSkipEvaluated = true }
  }

  mutating func record(live: SetupInputs, isFresh: Bool) {
    if isFresh { lastFreshInputs = live }
  }
}
