import IdleScreenCore
import IdleScreenDisplay

/// Resolves whether the Studio preview should hold a live camera capture lease.
///
/// The preview stops drawing camera frames as soon as the previewed display's
/// scene role turns quiet, so the lease has to end on exactly that condition.
/// Deriving both from one value lets the view observe the decision itself
/// rather than enumerating every input that feeds it.
enum StudioCameraPreviewReconciliation {
  static func usesCamera(
    source: IdleScreenSource,
    previewRole: DisplaySceneRole?
  ) -> Bool {
    guard source == .camera else { return false }
    if case .quiet = previewRole { return false }
    return true
  }
}
