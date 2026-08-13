import AppKit

extension NSImage {
    static let ditherMenuBarIcon: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(
            systemSymbolName: "square.grid.3x3.fill",
            accessibilityDescription: "idlescreen"
        )?.withSymbolConfiguration(configuration) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()
}
