import AppKit
import OSLog
import ScreenSaver

private let controllerLogger = Logger(subsystem: "com.idlescreen.screensaver", category: "ViewController")

@objc(IdleScreenScreenSaverViewController)
final class IdleScreenScreenSaverViewController: ScreenSaverViewController {
    private var saverView: IdleScreenSaverView?

    override func loadView() {
        let frame = NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        // The private app-extension host exposes only loadView() on macOS 26.
        // Tahoe's chooser can provide the full display frame for its scaled
        // preview, so this value is a rendering hint rather than proof of the
        // host surface. Keep drawing responsive to bounds in either mode.
        let isPreview = frame.width < 480 || frame.height < 320
        controllerLogger.info(
            "Loading view width=\(frame.width, privacy: .public) height=\(frame.height, privacy: .public) preview=\(isPreview, privacy: .public) source=frame-heuristic"
        )

        let saverView = IdleScreenSaverView(frame: frame, isPreview: isPreview)
        self.saverView = saverView
        view = saverView ?? NSView(frame: frame)
    }

    override func startAnimation() {
        super.startAnimation()
        saverView?.startAnimation()
        controllerLogger.info("Forwarded host animation start to the saver view")
    }

    override func stopAnimation() {
        saverView?.stopAnimation()
        super.stopAnimation()
        controllerLogger.info("Forwarded host animation stop to the saver view")
    }
}
