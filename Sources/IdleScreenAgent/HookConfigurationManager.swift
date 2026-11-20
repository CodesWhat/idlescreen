import Darwin
import Foundation
import IdleScreenCore

public struct IdleScreenAgentHookConfigurationManager: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable {
    case malformedSettings
    case unresolvableSettingsLink
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
    let targetURL = try resolvedSettingsURL()
    var root = try readRoot(at: targetURL)
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
    try write(root, to: targetURL)
  }

  public func uninstall() throws {
    let targetURL = try resolvedSettingsURL()
    var root = try readRoot(at: targetURL)
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
    try write(root, to: targetURL)
  }

  public func isInstalled() throws -> Bool {
    let root = try readRoot(at: settingsURL)
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
      "hooks": [
        [
          "type": "command",
          "command": managedCommand,
          "timeout": 3,
        ]
      ]
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
      let handlers = entry["hooks"] as? [Any]
    else { return false }
    return handlers.contains { handler in
      guard let handler = handler as? [String: Any],
        let command = handler["command"] as? String
      else { return false }
      return command == managedCommand
    }
  }

  private func removingManagedCommands(_ value: Any) -> Any? {
    guard var entry = value as? [String: Any],
      let handlers = entry["hooks"] as? [Any]
    else { return value }
    let remaining = handlers.filter { handler in
      guard let handler = handler as? [String: Any],
        let command = handler["command"] as? String
      else { return true }
      return !isOwnedManagedCommand(command)
    }
    guard !remaining.isEmpty else { return nil }
    entry["hooks"] = remaining
    return entry
  }

  private func isOwnedManagedCommand(_ command: String) -> Bool {
    // Generated shape: <exe> hook --provider <p> [--app-group <g>] --installation idlescreen-v1.
    // The executable path and app group vary across installs, so neither is pinned.
    guard let words = Self.shellWords(command) else { return false }
    guard words.count == 6 || words.count == 8 else { return false }
    if words.count == 8, words[4] != "--app-group" { return false }
    return words[1] == "hook"
      && words[2] == "--provider" && words[3] == provider.rawValue
      && words[words.count - 2] == "--installation" && words[words.count - 1] == "idlescreen-v1"
  }

  /// Splits a command into POSIX-style words, honoring single quotes,
  /// double quotes and backslashes. Returns nil for unbalanced quoting.
  private static func shellWords(_ command: String) -> [String]? {
    var words: [String] = []
    var current = ""
    var inWord = false
    var quote: Character?
    var escaped = false
    for character in command {
      if escaped {
        current.append(character)
        escaped = false
      } else if let open = quote {
        if character == open {
          quote = nil
        } else if character == "\\", open == "\"" {
          escaped = true
        } else {
          current.append(character)
        }
      } else if character == "'" || character == "\"" {
        quote = character
        inWord = true
      } else if character == "\\" {
        escaped = true
        inWord = true
      } else if character.isWhitespace {
        if inWord { words.append(current) }
        current = ""
        inWord = false
      } else {
        current.append(character)
        inWord = true
      }
    }
    guard quote == nil, !escaped else { return nil }
    if inWord { words.append(current) }
    return words
  }

  private func readRoot(at url: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    guard
      let object = try? JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
      ), let root = object as? [String: Any]
    else {
      throw Error.malformedSettings
    }
    return root
  }

  private func write(_ root: [String: Any], to targetURL: URL) throws {
    try FileManager.default.createDirectory(
      at: targetURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: targetURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: targetURL.path
    )
  }

  /// Follows symlinks so the referent is edited and the link survives.
  /// A dangling or cyclic link fails instead of being replaced.
  private func resolvedSettingsURL() throws -> URL {
    var linkInfo = stat()
    let status = lstat(settingsURL.path, &linkInfo)
    if status != 0, errno == ELOOP {
      throw Error.unresolvableSettingsLink
    }
    if status == 0, (linkInfo.st_mode & S_IFMT) == S_IFLNK {
      var targetInfo = stat()
      guard stat(settingsURL.path, &targetInfo) == 0 else {
        throw Error.unresolvableSettingsLink
      }
    }
    return settingsURL.resolvingSymlinksInPath()
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
