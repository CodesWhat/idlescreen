import Foundation
import OSLog
import ScreenSaver

private let extensionLogger = Logger(subsystem: "com.idlescreen.screensaver", category: "Extension")

@objc(IdleScreenScreenSaverExtension)
final class IdleScreenScreenSaverExtension: ScreenSaverExtension {
    @objc override init() {
        super.init()
        let missingClasses = ScreenSaverCompatibility.check()
        extensionLogger.info(
            "Extension initialized pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) compatible=\(missingClasses.isEmpty, privacy: .public)"
        )
    }
}
