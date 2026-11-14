import AppKit
import SwiftUI

@MainActor
final class IdleScreenWorkbenchHostingController<Content: View>: NSViewController {
  private let content: NSHostingController<Content>

  init(rootView: Content) {
    content = NSHostingController(rootView: rootView)
    content.sizingOptions = []
    super.init(nibName: nil, bundle: nil)
    addChild(content)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

  override func loadView() {
    // The AppKit root owns window limits; SwiftUI sizes only its contained surface.
    view = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 780))
    content.view.frame = view.bounds
    content.view.autoresizingMask = [.width, .height]
    view.addSubview(content.view)
  }
}
