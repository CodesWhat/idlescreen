import Foundation
import Testing
@testable import IdleScreenSystem

@Suite("Read-only screen saver selection diagnostics")
struct ScreenSaverSelectionTests {
    private let expectedBundleIdentifier = "com.idlescreen.app.dev.screensaver"

    @Test("the global screen saver choice takes precedence over per-Space fallbacks")
    func globalPrecedence() {
        let plist: [String: Any] = [
            "AllSpacesAndDisplays": section(provider: expectedBundleIdentifier),
            "Spaces": [
                "space-a": ["Default": section(provider: "com.example.other")]
            ],
            "SystemDefault": section(provider: "com.example.fallback")
        ]

        #expect(ScreenSaverSelectionParser.providers(in: plist) == [expectedBundleIdentifier])
    }

    @Test("per-Space choices report every distinct provider deterministically")
    func perSpaceProviders() {
        let plist: [String: Any] = [
            "Spaces": [
                "space-b": ["Default": section(provider: "com.example.zeta")],
                "space-a": ["Default": section(provider: expectedBundleIdentifier)],
                "space-c": ["Default": section(provider: expectedBundleIdentifier)]
            ],
            "SystemDefault": section(provider: "com.example.fallback")
        ]

        #expect(
            ScreenSaverSelectionParser.providers(in: plist)
                == ["com.example.zeta", expectedBundleIdentifier]
        )
    }

    @Test("a generic third-party choice resolves the selected extension bundle identifier")
    func resolvesThirdPartyExtension() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let extensionURL = directory.appending(
            path: "idlescreen.appex",
            directoryHint: .isDirectory
        )
        let contentsURL = extensionURL.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        try write(
            [
                "CFBundleIdentifier": expectedBundleIdentifier,
                "CFBundlePackageType": "XPC!"
            ],
            to: contentsURL.appending(path: "Info.plist")
        )

        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["module": ["relative": extensionURL.absoluteString]],
            format: .binary,
            options: 0
        )
        let plist: [String: Any] = [
            "AllSpacesAndDisplays": section(
                provider: "com.apple.wallpaper.choice.screen-saver",
                configuration: configuration
            )
        ]

        #expect(ScreenSaverSelectionParser.providers(in: plist) == [expectedBundleIdentifier])
    }

    @Test("the client distinguishes selected everywhere, partially selected, and unavailable")
    func selectionReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appending(path: "Index.plist")
        let client = ScreenSaverSelectionClient(
            expectedBundleIdentifier: expectedBundleIdentifier,
            indexURL: storeURL
        )

        try write(
            ["AllSpacesAndDisplays": section(provider: expectedBundleIdentifier)],
            to: storeURL
        )
        let selected = try client.status()
        #expect(selected.isSelectedEverywhere)
        #expect(selected.isSelectedAnywhere)

        try write(
            [
                "Spaces": [
                    "space-a": ["Default": section(provider: expectedBundleIdentifier)],
                    "space-b": ["Default": section(provider: "com.example.other")]
                ]
            ],
            to: storeURL
        )
        let partial = try client.status()
        #expect(partial.isSelectedEverywhere == false)
        #expect(partial.isSelectedAnywhere)

        try write(["Spaces": [:]], to: storeURL)
        let unavailable = try client.status()
        #expect(unavailable.providers.isEmpty)
        #expect(unavailable.isSelectedAnywhere == false)
    }

    private func section(provider: String, configuration: Data? = nil) -> [String: Any] {
        var choice: [String: Any] = ["Provider": provider]
        choice["Configuration"] = configuration
        return [
            "Idle": [
                "Content": [
                    "Choices": [choice]
                ]
            ]
        ]
    }

    private func write(_ propertyList: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }
}
