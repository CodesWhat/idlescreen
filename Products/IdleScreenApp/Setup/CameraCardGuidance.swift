import IdleScreenCamera

/// What the Studio camera card says and offers, keyed on the camera authorization so the title, detail and button agree.
struct CameraCardGuidance: Equatable {
  enum Action: Equatable {
    case openSetup
    case allowAccess
    case openCameraPrivacy
    case openStatus
    /// Nothing the user can do from here (a managed Mac), so no button.
    case none
  }

  let title: String
  let detail: String
  let action: Action

  var actionTitle: String? {
    switch action {
    case .openSetup: "Open setup"
    case .allowAccess: "Allow camera access"
    case .openCameraPrivacy: "Open camera privacy"
    case .openStatus: "Open status"
    case .none: nil
    }
  }

  static func make(
    authorization: CameraAgentAuthorizationObservation, setupCompleted: Bool
  ) -> CameraCardGuidance {
    let finishSetup = "Finish setup to turn the camera on."
    switch authorization {
    case .observed(.notDetermined):
      return CameraCardGuidance(
        title: "Allow camera access",
        detail: setupCompleted ? "IdleScreen needs your OK to use the camera." : finishSetup,
        action: setupCompleted ? .allowAccess : .openSetup)
    case .observed(.denied):
      return CameraCardGuidance(
        title: "Camera access is off",
        detail: setupCompleted ? "Turn it on in Camera privacy settings." : finishSetup,
        action: setupCompleted ? .openCameraPrivacy : .openSetup)
    case .observed(.restricted):
      return CameraCardGuidance(
        title: "Camera access is restricted",
        detail: "A policy on this Mac blocks the camera. Ask whoever manages it.",
        action: .none)
    case .unknown, .observed(.authorized):
      return CameraCardGuidance(
        title: "The camera isn't working",
        detail: setupCompleted ? "Open Status to check it." : finishSetup,
        action: setupCompleted ? .openStatus : .openSetup)
    }
  }
}
