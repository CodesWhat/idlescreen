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
