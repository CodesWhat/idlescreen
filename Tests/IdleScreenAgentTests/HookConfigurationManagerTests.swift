import Foundation
import Testing

@testable import IdleScreenAgent
@testable import IdleScreenCore

@Suite("Explicit hook configuration management")
struct HookConfigurationManagerTests {
  @Test("previews include only documented lifecycle events and the signed tool path")
  func previewsExactSnippets() throws {
    let executableURL = URL(
      fileURLWithPath: "/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl")

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
        "Stop": [
          [
            "matcher": "",
            "hooks": [
              [
                "type": "command",
                "command": "/usr/local/bin/my-existing-hook",
              ]
            ],
          ]
        ]
      ],
    ]
    try JSONSerialization.data(
      withJSONObject: original,
      options: [.prettyPrinted, .sortedKeys]
    ).write(to: settingsURL)
    let manager = IdleScreenAgentHookConfigurationManager(
      provider: .claude,
      settingsURL: settingsURL,
      executableURL: URL(
        fileURLWithPath: "/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl"),
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
      fileURLWithPath: "/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl"
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
      executableURL: URL(
        fileURLWithPath: "/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl"),
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
      executableURL: URL(
        fileURLWithPath: "/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl"),
      appGroupIdentifier: "group.com.idlescreen.shared"
    )

    #expect(throws: IdleScreenAgentHookConfigurationManager.Error.malformedSettings) {
      try manager.install()
    }
    #expect(try Data(contentsOf: settingsURL) == original)
  }

  private static let downloadsPath =
    "/Users/me/Downloads/IdleScreen.app/Contents/Helpers/idlescreenctl"
  private static let applicationsPath =
    "/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl"

  private static func scratchDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func manager(
    _ provider: IdleScreenAgentProvider, _ settingsURL: URL, _ path: String
  ) -> IdleScreenAgentHookConfigurationManager {
    IdleScreenAgentHookConfigurationManager(
      provider: provider,
      settingsURL: settingsURL,
      executableURL: URL(fileURLWithPath: path),
      appGroupIdentifier: "group.com.idlescreen.shared"
    )
  }

  private static func commands(_ settingsURL: URL) throws -> [String: [String]] {
    let root = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    let hooks = root["hooks"] as? [String: [[String: Any]]] ?? [:]
    return hooks.mapValues { entries in
      entries.flatMap { entry in
        (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
      }
    }
  }

  @Test(
    "reinstall from a new path leaves one current command per event",
    arguments: [
      IdleScreenAgentProvider.codex, .claude,
    ])
  func reinstallReplacesMovedExecutable(provider: IdleScreenAgentProvider) throws {
    let root = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    try Self.manager(provider, settingsURL, Self.downloadsPath).install()
    let current = Self.manager(provider, settingsURL, Self.applicationsPath)
    #expect(!(try current.isInstalled()))

    try current.install()

    #expect(try current.isInstalled())
    let commands = try Self.commands(settingsURL)
    #expect(!commands.isEmpty)
    for (_, list) in commands {
      #expect(list.count == 1)
      #expect(list.allSatisfy { $0.contains(Self.applicationsPath) })
    }
    #expect(!(try String(contentsOf: settingsURL, encoding: .utf8)).contains("Downloads"))
  }

  @Test(
    "uninstall from a new path removes stale managed commands",
    arguments: [
      IdleScreenAgentProvider.codex, .claude,
    ])
  func uninstallRemovesStalePaths(provider: IdleScreenAgentProvider) throws {
    let root = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    try Self.manager(provider, settingsURL, Self.downloadsPath).install()

    try Self.manager(provider, settingsURL, Self.applicationsPath).uninstall()

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(!text.contains("idlescreen-v1"))
    #expect(!text.contains("Downloads"))
  }

  @Test("ownership keeps unrelated handlers and commands without the marker")
  func ownershipKeepsUnrelatedHandlers() throws {
    let root = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    let owned =
      "'\(Self.downloadsPath)' hook --provider codex --app-group 'g' --installation idlescreen-v1"
    let lookalike = "'\(Self.downloadsPath)' hook --provider codex --app-group 'g'"
    let original: [String: Any] = [
      "hooks": [
        "Stop": [
          [
            "hooks": [
              ["type": "command", "command": owned],
              ["type": "command", "command": "/usr/local/bin/mine"],
            ]
          ],
          ["hooks": [["type": "command", "command": lookalike]]],
        ]
      ]
    ]
    try JSONSerialization.data(withJSONObject: original).write(to: settingsURL)

    try Self.manager(.codex, settingsURL, Self.applicationsPath).uninstall()

    let commands = try Self.commands(settingsURL)
    #expect(Set(commands["Stop"] ?? []) == ["/usr/local/bin/mine", lookalike])
  }

  @Test("symlinked settings are edited in place and the link survives")
  func symlinkedSettingsFollowLinks() throws {
    let fm = FileManager.default
    let root = try Self.scratchDirectory()
    defer { try? fm.removeItem(at: root) }
    let real = root.appending(path: "real", directoryHint: .isDirectory)
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    let referent = real.appending(path: "settings.json")
    try Data(#"{"theme":"dark"}"#.utf8).write(to: referent)
    let absolute = root.appending(path: "absolute.json")
    try fm.createSymbolicLink(atPath: absolute.path, withDestinationPath: referent.path)
    let relative = root.appending(path: "relative.json")
    try fm.createSymbolicLink(atPath: relative.path, withDestinationPath: "real/settings.json")
    let chainMid = root.appending(path: "mid.json")
    try fm.createSymbolicLink(atPath: chainMid.path, withDestinationPath: "relative.json")
    let chain = root.appending(path: "chain.json")
    try fm.createSymbolicLink(atPath: chain.path, withDestinationPath: chainMid.path)

    for link in [absolute, relative, chain] {
      let manager = Self.manager(.claude, link, Self.applicationsPath)
      let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
      try manager.install()
      let once = try Data(contentsOf: referent)
      try manager.install()
      #expect(try Data(contentsOf: referent) == once)
      #expect(try manager.isInstalled())
      #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == destination)
      let attributes = try fm.attributesOfItem(atPath: referent.path)
      #expect((attributes[.posixPermissions] as? Int) == 0o600)
      let object = try #require(JSONSerialization.jsonObject(with: once) as? [String: Any])
      #expect(object["theme"] as? String == "dark")

      try manager.uninstall()
      #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == destination)
      let removed = try String(contentsOf: referent, encoding: .utf8)
      #expect(!removed.contains("idlescreen-v1"))
      #expect(removed.contains("dark"))
    }
  }

  @Test("dangling and cyclic settings links fail without replacement")
  func unresolvableLinksFail() throws {
    let fm = FileManager.default
    let root = try Self.scratchDirectory()
    defer { try? fm.removeItem(at: root) }
    let dangling = root.appending(path: "dangling.json")
    try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing/none.json")
    let cycleA = root.appending(path: "a.json")
    let cycleB = root.appending(path: "b.json")
    try fm.createSymbolicLink(atPath: cycleA.path, withDestinationPath: "b.json")
    try fm.createSymbolicLink(atPath: cycleB.path, withDestinationPath: "a.json")

    for link in [dangling, cycleA] {
      let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
      #expect(throws: IdleScreenAgentHookConfigurationManager.Error.unresolvableSettingsLink) {
        try Self.manager(.codex, link, Self.applicationsPath).install()
      }
      #expect(throws: IdleScreenAgentHookConfigurationManager.Error.unresolvableSettingsLink) {
        try Self.manager(.codex, link, Self.applicationsPath).uninstall()
      }
      #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == destination)
    }
    #expect(!fm.fileExists(atPath: root.appending(path: "missing").path))
  }

  @Test("a symlink loop in an ancestor directory is an unresolvable link")
  func ancestorLoopIsUnresolvable() throws {
    let fm = FileManager.default
    let root = try Self.scratchDirectory()
    defer { try? fm.removeItem(at: root) }
    try fm.createSymbolicLink(
      atPath: root.appending(path: "loopA").path, withDestinationPath: "loopB")
    try fm.createSymbolicLink(
      atPath: root.appending(path: "loopB").path, withDestinationPath: "loopA")
    let settingsURL = root.appending(path: "loopA/settings.json")

    #expect(throws: IdleScreenAgentHookConfigurationManager.Error.unresolvableSettingsLink) {
      try Self.manager(.claude, settingsURL, Self.applicationsPath).install()
    }
    #expect(throws: IdleScreenAgentHookConfigurationManager.Error.unresolvableSettingsLink) {
      try Self.manager(.claude, settingsURL, Self.applicationsPath).uninstall()
    }
  }

  @Test("uninstall with no settings file is a no-op")
  func uninstallMissingSettingsIsNoOp() throws {
    let root = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "absent/settings.json")

    try Self.manager(.codex, settingsURL, Self.applicationsPath).uninstall()

    #expect(!FileManager.default.fileExists(atPath: settingsURL.path))
  }

  @Test("ownership needs the exact generated structure, not marker text")
  func ownershipIsAnchored() throws {
    let root = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    let embedded = "/usr/local/bin/other 'x hook --provider codex --installation idlescreen-v1'"
    let longerMarker =
      "'\(Self.downloadsPath)' hook --provider codex --app-group 'g' --installation idlescreen-v10"
    let wrongProvider =
      "'\(Self.downloadsPath)' hook --provider claude --app-group 'g' --installation idlescreen-v1"
    let owned =
      "'\(Self.downloadsPath)' hook --provider codex --app-group 'g' --installation idlescreen-v1"
    let handlers = [embedded, longerMarker, wrongProvider, owned].map {
      ["type": "command", "command": $0]
    }
    let original: [String: Any] = ["hooks": ["Stop": [["hooks": handlers]]]]
    try JSONSerialization.data(withJSONObject: original).write(to: settingsURL)

    try Self.manager(.codex, settingsURL, Self.applicationsPath).uninstall()

    let commands = try Self.commands(settingsURL)
    #expect(Set(commands["Stop"] ?? []) == [embedded, longerMarker, wrongProvider])
  }
}
