import Foundation

public struct ScreenSaverSelectionReport: Equatable, Sendable {
    public let expectedBundleIdentifier: String
    public let providers: [String]

    public init(expectedBundleIdentifier: String, providers: [String]) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.providers = Array(Set(providers)).sorted()
    }

    public var isSelectedAnywhere: Bool {
        providers.contains(expectedBundleIdentifier)
    }

    public var isSelectedEverywhere: Bool {
        providers == [expectedBundleIdentifier]
    }
}

enum ScreenSaverSelectionParser {
    private static let thirdPartyProvider = "com.apple.wallpaper.choice.screen-saver"

    static func providers(in propertyList: [String: Any]) -> [String] {
        if let provider = provider(in: propertyList["AllSpacesAndDisplays"] as? [String: Any]) {
            return [provider]
        }

        if let spaces = propertyList["Spaces"] as? [String: Any] {
            let providers = spaces.values.compactMap { value -> String? in
                guard let space = value as? [String: Any] else { return nil }
                return provider(in: space["Default"] as? [String: Any])
            }
            if !providers.isEmpty {
                return Array(Set(providers)).sorted()
            }
        }

        return provider(in: propertyList["SystemDefault"] as? [String: Any]).map { [$0] } ?? []
    }

    private static func provider(in section: [String: Any]?) -> String? {
        guard let idle = section?["Idle"] as? [String: Any],
              let content = idle["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              let provider = choice["Provider"] as? String else {
            return nil
        }

        guard provider == thirdPartyProvider else {
            return provider
        }

        return extensionBundleIdentifier(in: choice) ?? provider
    }

    private static func extensionBundleIdentifier(in choice: [String: Any]) -> String? {
        guard let configuration = choice["Configuration"] as? Data,
              let value = try? PropertyListSerialization.propertyList(
                  from: configuration,
                  options: [],
                  format: nil
              ),
              let propertyList = value as? [String: Any],
              let module = propertyList["module"] as? [String: Any],
              let relative = module["relative"] as? String,
              let extensionURL = URL(string: relative),
              extensionURL.isFileURL else {
            return nil
        }

        return Bundle(url: extensionURL)?.bundleIdentifier
    }
}

public struct ScreenSaverSelectionClient: Sendable {
    public enum Error: LocalizedError {
        case invalidPropertyList

        public var errorDescription: String? {
            "The macOS wallpaper store has an unexpected root value."
        }
    }

    public static let defaultIndexURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    private let expectedBundleIdentifier: String
    private let indexURL: URL

    public init(
        expectedBundleIdentifier: String,
        indexURL: URL = defaultIndexURL
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.indexURL = indexURL
    }

    public func status() throws -> ScreenSaverSelectionReport {
        let data = try Data(contentsOf: indexURL)
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let propertyList = value as? [String: Any] else {
            throw Error.invalidPropertyList
        }
        return ScreenSaverSelectionReport(
            expectedBundleIdentifier: expectedBundleIdentifier,
            providers: ScreenSaverSelectionParser.providers(in: propertyList)
        )
    }
}
