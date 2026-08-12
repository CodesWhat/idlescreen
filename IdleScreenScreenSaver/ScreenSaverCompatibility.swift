import Foundation
import ObjectiveC.runtime
import OSLog

enum ScreenSaverCompatibility {
    private static let logger = Logger(subsystem: "com.idlescreen.screensaver", category: "Compatibility")
    private static let requiredClassNames = ["ScreenSaverExtension", "ScreenSaverViewController"]
    private static let requiredInstanceSelectors = [
        (className: "ScreenSaverViewController", selectorName: "startAnimation"),
        (className: "ScreenSaverViewController", selectorName: "stopAnimation")
    ]

    static func check() -> [String] {
        let missingClasses = requiredClassNames.filter { NSClassFromString($0) == nil }
        let missingSelectors = requiredInstanceSelectors.compactMap { requirement -> String? in
            guard let runtimeClass = NSClassFromString(requirement.className) else {
                return nil
            }
            let selector = NSSelectorFromString(requirement.selectorName)
            return class_getInstanceMethod(runtimeClass, selector) == nil
                ? "\(requirement.className).\(requirement.selectorName)"
                : nil
        }
        let missing = missingClasses + missingSelectors
        if missing.isEmpty {
            logger.info("Modern ScreenSaver extension runtime is compatible")
        } else {
            logger.fault("Missing ScreenSaver runtime symbols: \(missing.joined(separator: ", "), privacy: .public)")
        }
        return missing
    }
}
