import Darwin
import Foundation
import IdleScreenCore

public struct IdleScreenAgentHookConfigurationManager: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case malformedSettings
    }

    public let provider: IdleScreenAgentProvider
    public let settingsURL: URL
    public let executableURL: URL
    public let appGroupIdentifier: String

    public init(
        provider: IdleScreenAgentProvider,
        settingsURL: URL,
        executableURL: URL,
        appGroupIdentifier: String
    ) {
        self.provider = provider
        self.settingsURL = settingsURL
        self.executableURL = executableURL
        self.appGroupIdentifier = appGroupIdentifier
    }

    public static func preview(
        provider: IdleScreenAgentProvider,
        executableURL: URL,
        appGroupIdentifier: String
    ) throws -> String {
        let manager = Self(
            provider: provider,
            settingsURL: URL(fileURLWithPath: "/dev/null"),
            executableURL: executableURL,
            appGroupIdentifier: appGroupIdentifier
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["hooks": manager.managedHooks],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    public func install() throws {
        var root = try readRoot()
        var hooks: [String: Any]
        if let existingHooks = root["hooks"] {
            guard let decodedHooks = existingHooks as? [String: Any] else {
                throw Error.malformedSettings
            }
            hooks = decodedHooks
        } else {
            hooks = [:]
        }
        for event in events {
            var entries: [Any]
            if let existingEntries = hooks[event] {
                guard let decodedEntries = existingEntries as? [Any] else {
                    throw Error.malformedSettings
                }
                entries = decodedEntries
            } else {
                entries = []
            }
            entries = entries.compactMap(removingManagedCommands)
            entries.append(managedEntry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try write(root)
    }

    public func uninstall() throws {
        var root = try readRoot()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, rawEntries) in hooks {
            guard let entries = rawEntries as? [Any] else { continue }
            let filtered = entries.compactMap(removingManagedCommands)
            if filtered.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filtered
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try write(root)
    }

    public func isInstalled() throws -> Bool {
        let root = try readRoot()
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            let entries = hooks[event] as? [Any] ?? []
            return entries.contains(where: containsCurrentManagedCommand)
        }
    }

    private var events: [String] {
        switch provider {
        case .codex:
            ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"]
        case .claude:
            [
                "SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification",
                "Stop", "StopFailure", "SessionEnd",
            ]
        }
    }

    private var managedHooks: [String: Any] {
        Dictionary(uniqueKeysWithValues: events.map { ($0, [managedEntry]) })
    }

    private var managedEntry: [String: Any] {
        [
            "hooks": [[
                "type": "command",
                "command": managedCommand,
                "timeout": 3,
            ]],
        ]
    }

    private var managedCommand: String {
        [
            shellQuote(executableURL.path),
            "hook",
            "--provider", provider.rawValue,
            "--app-group", shellQuote(appGroupIdentifier),
            "--installation", "idlescreen-v1",
        ].joined(separator: " ")
    }

    private func containsCurrentManagedCommand(_ value: Any) -> Bool {
        guard let entry = value as? [String: Any],
              let handlers = entry["hooks"] as? [Any] else { return false }
        return handlers.contains { handler in
            guard let handler = handler as? [String: Any],
                  let command = handler["command"] as? String else { return false }
            return command == managedCommand
        }
    }

    private func removingManagedCommands(_ value: Any) -> Any? {
        guard var entry = value as? [String: Any],
              let handlers = entry["hooks"] as? [Any] else { return value }
        let remaining = handlers.filter { handler in
            guard let handler = handler as? [String: Any],
                  let command = handler["command"] as? String else { return true }
            return !isOwnedManagedCommand(command)
        }
        guard !remaining.isEmpty else { return nil }
        entry["hooks"] = remaining
        return entry
    }

    private func isOwnedManagedCommand(_ command: String) -> Bool {
        command.contains(" hook ")
            && command.contains("--provider \(provider.rawValue)")
            && command.contains("--installation idlescreen-v1")
            && command.contains(executableURL.path)
    }

    private func readRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)
        ), let root = object as? [String: Any] else {
            throw Error.malformedSettings
        }
        return root
    }

    private func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: settingsURL.path
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
