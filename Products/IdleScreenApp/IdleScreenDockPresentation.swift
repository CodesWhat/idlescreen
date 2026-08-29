import AppKit

/// Decides whether the companion appears in the Dock.
///
/// idlescreen lives in the menu bar, so the Dock tile is only meaningful while
/// the main window is on screen. Deriving the policy from window presence keeps
/// a tile from outliving the window it belongs to, and keeps the hidden probe
/// launches from flashing one at all.
enum IdleScreenDockPresentation {
  static func activationPolicy(
    showsMainWindow: Bool
  ) -> NSApplication.ActivationPolicy {
    showsMainWindow ? .regular : .accessory
  }
}
