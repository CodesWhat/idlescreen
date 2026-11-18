import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Shared AgentSignal paths")
struct SharedContainerAgentPathsTests {
  @Test("the inbox is isolated from durable visual configuration")
  func derivesAgentSignalPaths() {
    let paths = IdleScreenSharedPaths(
      rootURL: URL(fileURLWithPath: "/tmp/group.com.idlescreen.shared")
    )

    #expect(paths.agentSignalsDirectoryURL.lastPathComponent == "AgentSignals")
    #expect(paths.agentSignalsInboxURL.lastPathComponent == "inbox-v1.json")
    #expect(
      paths.agentSignalsInboxURL.deletingLastPathComponent()
        == paths.agentSignalsDirectoryURL)
    #expect(paths.agentSignalsInboxURL != paths.configurationURL)
  }

  @Test("the app-group constants match project.yml and the entitlements wiring")
  func appGroupConstantsMatchProjectConfiguration() throws {
    var root = URL(fileURLWithPath: #filePath)
    while !FileManager.default.fileExists(
      atPath: root.appending(path: "project.yml").path
    ) {
      let parent = root.deletingLastPathComponent()
      try #require(parent != root)
      root = parent
    }
    let projectYAML = try String(
      contentsOf: root.appending(path: "project.yml"),
      encoding: .utf8
    )
    for identifier in [
      IdleScreenSharedContainer.releaseAppGroupIdentifier,
      IdleScreenSharedContainer.debugAppGroupIdentifier,
    ] {
      #expect(
        projectYAML.contains("IDLESCREEN_APP_GROUP_IDENTIFIER: \(identifier)\n")
      )
    }
    #expect(IdleScreenSharedContainer.releaseAppGroupIdentifier == "group.com.idlescreen.shared")
    #expect(IdleScreenSharedContainer.debugAppGroupIdentifier == "group.com.idlescreen.dev.shared")

    for (file, identifier) in [
      ("idlescreenctl.entitlements", IdleScreenSharedContainer.releaseAppGroupIdentifier),
      (
        "idlescreenctl-DeveloperID.entitlements",
        IdleScreenSharedContainer.releaseAppGroupIdentifier
      ),
      ("idlescreenctl-Debug.entitlements", IdleScreenSharedContainer.debugAppGroupIdentifier),
    ] {
      let entitlements = try String(
        contentsOf: root.appending(path: "Products/IdleScreenAgentExecutable/\(file)"),
        encoding: .utf8
      )
      #expect(entitlements.contains("<string>\(identifier)</string>"))
    }
  }
}
