import Foundation
import Testing
@testable import IdleScreenAgent
@testable import IdleScreenCore

@Suite("Explicit hook configuration management")
struct HookConfigurationManagerTests {
    @Test("previews include only documented lifecycle events and the signed tool path")
    func previewsExactSnippets() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/idlescreen.app/Contents/Helpers/idlescreenctl")

        let codex = try IdleScreenAgentHookConfigurationManager.preview(
            provider: .codex,
            executableURL: executableURL,
            appGroupIdentifier: "group.com.idlescreen.shared"
        )
        let claude = try IdleScreenAgentHookConfigurationManager.preview(
            provider: .claude,
            executableURL: executableURL,
            appGroupIdentifier: "group.com.idlescreen.shared"
        )

        #expect(codex.contains("SessionStart"))
        #expect(codex.contains("PermissionRequest"))
        #expect(codex.contains("SessionEnd"))
        #expect(!codex.contains("Notification"))
        #expect(claude.contains("Notification"))
        #expect(claude.contains("StopFailure"))
        #expect(claude.contains(executableURL.path))
        #expect(!codex.contains("prompt"))
        #expect(!claude.contains("transcript"))
    }

    @Test("install and uninstall preserve unrelated settings and hooks")
    func roundTripsWithoutOwningTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settingsURL = root.appending(path: "settings.json")
        let original: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "Stop": [[
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": "/usr/local/bin/my-existing-hook",
                    ]],
                ]],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: original,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: settingsURL)
        let manager = IdleScreenAgentHookConfigurationManager(
            provider: .claude,
            settingsURL: settingsURL,
            executableURL: URL(fileURLWithPath: "/Applications/idlescreen.app/Contents/Helpers/idlescreenctl"),
            appGroupIdentifier: "group.com.idlescreen.shared"
        )

        try manager.install()
        let once = try Data(contentsOf: settingsURL)
        try manager.install()
        let twice = try Data(contentsOf: settingsURL)
        #expect(once == twice)
        #expect(try manager.isInstalled())
        let installed = try #require(
            JSONSerialization.jsonObject(with: once) as? [String: Any]
        )
        #expect(installed["theme"] as? String == "dark")
        #expect(String(decoding: once, as: UTF8.self).contains("my-existing-hook"))

        try manager.uninstall()
        #expect(!(try manager.isInstalled()))
        let removed = try Data(contentsOf: settingsURL)
        let removedText = String(decoding: removed, as: UTF8.self)
        #expect(removedText.contains("my-existing-hook"))
        #expect(!removedText.contains("--installation idlescreen-v1"))
        #expect(removedText.contains("\"theme\" : \"dark\""))
    }

    @Test("install replaces a stale managed hook for the wrong App Group")
    func repairsWrongAppGroup() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appending(path: "hooks.json")
        let executableURL = URL(
            fileURLWithPath: "/Applications/idlescreen.app/Contents/Helpers/idlescreenctl"
        )
        let stale = IdleScreenAgentHookConfigurationManager(
            provider: .codex,
            settingsURL: settingsURL,
            executableURL: executableURL,
            appGroupIdentifier: "group.com.idlescreen.stale"
        )
        let current = IdleScreenAgentHookConfigurationManager(
            provider: .codex,
            settingsURL: settingsURL,
            executableURL: executableURL,
            appGroupIdentifier: "group.com.idlescreen.shared"
        )
        try stale.install()

        #expect(!(try current.isInstalled()))
        try current.install()

        let installed = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(try current.isInstalled())
        #expect(installed.contains("group.com.idlescreen.shared"))
        #expect(!installed.contains("group.com.idlescreen.stale"))
    }

    @Test("malformed settings fail closed without replacing user data")
    func malformedSettingsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settingsURL = root.appending(path: "hooks.json")
        let original = Data("{not-json".utf8)
        try original.write(to: settingsURL)
        let manager = IdleScreenAgentHookConfigurationManager(
            provider: .codex,
            settingsURL: settingsURL,
            executableURL: URL(fileURLWithPath: "/Applications/idlescreen.app/Contents/Helpers/idlescreenctl"),
            appGroupIdentifier: "group.com.idlescreen.shared"
        )

        #expect(throws: IdleScreenAgentHookConfigurationManager.Error.malformedSettings) {
            try manager.install()
        }
        #expect(try Data(contentsOf: settingsURL) == original)
    }

    @Test("valid JSON with an incompatible hook shape also fails closed")
    func incompatibleHookShapeFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settingsURL = root.appending(path: "hooks.json")
        let original = Data(#"{"hooks":"owned by another format","theme":"dark"}"#.utf8)
        try original.write(to: settingsURL)
        let manager = IdleScreenAgentHookConfigurationManager(
            provider: .codex,
            settingsURL: settingsURL,
            executableURL: URL(fileURLWithPath: "/Applications/idlescreen.app/Contents/Helpers/idlescreenctl"),
            appGroupIdentifier: "group.com.idlescreen.shared"
        )

        #expect(throws: IdleScreenAgentHookConfigurationManager.Error.malformedSettings) {
            try manager.install()
        }
        #expect(try Data(contentsOf: settingsURL) == original)
    }
}
