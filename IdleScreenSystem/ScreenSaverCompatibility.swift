import Darwin
import Foundation
import ObjectiveC.runtime

public struct ScreenSaverCompatibilityStatus: Equatable, Sendable {
    public var frameworkLoaded: Bool
    public var missingClassNames: [String]
    public var missingSelectorNames: [String]

    public init(
        frameworkLoaded: Bool,
        missingClassNames: [String],
        missingSelectorNames: [String] = []
    ) {
        self.frameworkLoaded = frameworkLoaded
        self.missingClassNames = missingClassNames
        self.missingSelectorNames = missingSelectorNames
    }

    public var isCompatible: Bool {
        frameworkLoaded && missingClassNames.isEmpty && missingSelectorNames.isEmpty
    }
}

public enum ScreenSaverCompatibilityProbe {
    private static let frameworkPath = "/System/Library/Frameworks/ScreenSaver.framework/ScreenSaver"
    private static let requiredClassNames = ["ScreenSaverExtension", "ScreenSaverViewController"]
    private static let requiredInstanceSelectors = [
        (className: "ScreenSaverViewController", selectorName: "startAnimation"),
        (className: "ScreenSaverViewController", selectorName: "stopAnimation")
    ]

    public static func check() -> ScreenSaverCompatibilityStatus {
        let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL)
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
        return ScreenSaverCompatibilityStatus(
            frameworkLoaded: handle != nil,
            missingClassNames: missingClasses,
            missingSelectorNames: missingSelectors
        )
    }
}
