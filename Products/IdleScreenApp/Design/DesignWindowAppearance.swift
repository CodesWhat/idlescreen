import AppKit
import SwiftUI

/// Sets the hosting window's `NSAppearance`. `.environment(\.colorScheme)` only recolours SwiftUI content; alerts, menus, pickers,
/// the divider and the window background are drawn by AppKit and follow the window. `nil` follows the system.
private struct WindowAppearanceSetter: NSViewRepresentable {
  let appearance: NSAppearance?

  final class Host: NSView {
    var appearanceToApply: NSAppearance?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }
    func apply() {
      guard let window, window.appearance?.name != appearanceToApply?.name else { return }
      window.appearance = appearanceToApply
    }
  }

  func makeNSView(context: Context) -> Host {
    let host = Host()
    host.appearanceToApply = appearance
    return host
  }

  func updateNSView(_ host: Host, context: Context) {
    host.appearanceToApply = appearance
    host.apply()
  }
}

extension View {
  /// Forces the hosting window's appearance, or follows the system when `nil`.
  func windowAppearance(_ appearance: NSAppearance?) -> some View {
    background(WindowAppearanceSetter(appearance: appearance))
  }
}
