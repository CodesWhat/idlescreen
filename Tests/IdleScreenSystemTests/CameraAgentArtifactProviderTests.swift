import Foundation
import Testing

@testable import IdleScreenSystem

@Suite("Security camera agent artifact provider")
struct CameraAgentArtifactProviderTests {
  private final class Bundle {
    let root: URL
    let applicationURL: URL
    let helperURL: URL
    let launchAgentURL: URL
    let serviceIdentity: CameraAgentServiceIdentity

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath()
      applicationURL = root.appendingPathComponent("IdleScreen.app", isDirectory: true)
      helperURL = applicationURL.appendingPathComponent(
        "Contents/Helpers/IdleScreenCameraAgent.app",
        isDirectory: true
      )
      serviceIdentity = try CameraAgentServiceIdentity(
        appGroupIdentifier: "group.com.idlescreen.shared"
      )
      launchAgentURL = applicationURL.appendingPathComponent(
        "Contents/Library/LaunchAgents/\(serviceIdentity.plistName)"
      )
      try FileManager.default.createDirectory(
        at: helperURL.appendingPathComponent("Contents/MacOS"),
        withIntermediateDirectories: true
      )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var request: CameraAgentEmbeddedArtifactRequest {
      CameraAgentEmbeddedArtifactRequest(
        containingApplicationURL: applicationURL,
        helperBundleURL: helperURL,
        launchAgentURL: launchAgentURL,
        serviceIdentity: serviceIdentity
      )
    }

    func writeLaunchAgent(
      label: String? = nil,
      program: String =
        "Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
    ) throws {
      try FileManager.default.createDirectory(
        at: launchAgentURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let plist: [String: Any] = [
        "Label": label ?? serviceIdentity.serviceIdentifier,
        "BundleProgram": program,
      ]
      try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: launchAgentURL)
    }

    func writeInfoPlist(includeExecutable: Bool = true) throws {
      var plist: [String: Any] = [
        "CFBundleIdentifier": "com.idlescreen.camera-agent",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "0.1",
        "CFBundlePackageType": "APPL",
      ]
      if includeExecutable { plist["CFBundleExecutable"] = "IdleScreenCameraAgent" }
      try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: helperURL.appendingPathComponent("Contents/Info.plist"))
    }

    func installExecutable() throws {
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "/usr/bin/true"),
        to: helperURL.appendingPathComponent("Contents/MacOS/IdleScreenCameraAgent")
      )
    }

    func writeProfile() throws {
      try Data("profile".utf8).write(
        to: helperURL.appendingPathComponent("Contents/embedded.provisionprofile")
      )
    }

    func adHocSign() throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      process.arguments = ["--force", "--sign", "-", helperURL.path]
      process.standardError = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
  }

  private func fingerprintError(
    _ bundle: Bundle
  ) -> CameraAgentArtifactProviderError? {
    do {
      _ = try SecurityCameraAgentEmbeddedArtifactProvider().fingerprint(for: bundle.request)
      return nil
    } catch let error as CameraAgentArtifactProviderError {
      return error
    } catch {
      return nil
    }
  }

  @Test("a helper directory without a launch agent plist is reported")
  func launchAgentMissing() throws {
    let bundle = try Bundle()
    #expect(fingerprintError(bundle) == .launchAgentMissing(bundle.launchAgentURL.path))
  }

  @Test("a helper without bundle metadata is malformed")
  func malformedBundle() throws {
    let bundle = try Bundle()
    try bundle.writeLaunchAgent()
    #expect(fingerprintError(bundle) == .malformedBundle(bundle.helperURL.path))
  }

  @Test("a bundle that names no executable is reported")
  func executableMissing() throws {
    let bundle = try Bundle()
    try bundle.writeLaunchAgent()
    try bundle.writeInfoPlist(includeExecutable: false)
    #expect(fingerprintError(bundle) == .executableMissing(bundle.helperURL.path))
  }

  @Test("an executable symlinked outside the helper bundle is refused")
  func executableEscapesBundle() throws {
    let bundle = try Bundle()
    try bundle.writeLaunchAgent()
    try bundle.writeInfoPlist()
    try FileManager.default.createSymbolicLink(
      at: bundle.helperURL.appendingPathComponent("Contents/MacOS/IdleScreenCameraAgent"),
      withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
    )

    #expect(fingerprintError(bundle) == .containedArtifactEscapesBundle("/usr/bin/true"))
  }

  @Test("a missing provisioning profile is reported with its path")
  func provisioningProfileMissing() throws {
    let bundle = try Bundle()
    try bundle.writeLaunchAgent()
    try bundle.writeInfoPlist()
    try bundle.installExecutable()

    #expect(
      fingerprintError(bundle)
        == .provisioningProfileMissing(
          bundle.helperURL.appendingPathComponent("Contents/embedded.provisionprofile").path
        )
    )
  }

  @Test("a provisioning profile symlinked outside the bundle is refused")
  func profileEscapesBundle() throws {
    let bundle = try Bundle()
    try bundle.writeLaunchAgent()
    try bundle.writeInfoPlist()
    try bundle.installExecutable()
    let outside = bundle.root.appendingPathComponent("outside.provisionprofile")
    try Data("p".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: bundle.helperURL.appendingPathComponent("Contents/embedded.provisionprofile"),
      withDestinationURL: outside
    )

    #expect(fingerprintError(bundle) == .containedArtifactEscapesBundle(outside.path))
  }

  @Test("a launch agent with the wrong label or program is invalid")
  func invalidLaunchAgent() throws {
    for (label, program) in [
      ("com.example.other", nil),
      (nil, "Contents/MacOS/Other"),
    ] as [(String?, String?)] {
      let bundle = try Bundle()
      if let program {
        try bundle.writeLaunchAgent(label: label, program: program)
      } else {
        try bundle.writeLaunchAgent(label: label)
      }
      try bundle.writeInfoPlist()
      try bundle.installExecutable()
      try bundle.writeProfile()

      #expect(fingerprintError(bundle) == .invalidLaunchAgent(bundle.launchAgentURL.path))
    }
  }

  @Test("an unreadable launch agent is not mistaken for a valid one")
  func garbageLaunchAgent() throws {
    let bundle = try Bundle()
    try FileManager.default.createDirectory(
      at: bundle.launchAgentURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("not a plist".utf8).write(to: bundle.launchAgentURL)
    try bundle.writeInfoPlist()
    try bundle.installExecutable()
    try bundle.writeProfile()

    #expect(fingerprintError(bundle) == .invalidLaunchAgent(bundle.launchAgentURL.path))
  }

  @Test("an unsigned helper fails static code validation")
  func unsignedHelper() throws {
    let bundle = try Bundle()
    try bundle.writeLaunchAgent()
    try bundle.writeInfoPlist()
    try bundle.installExecutable()
    try bundle.writeProfile()

    guard case .invalidStaticCode? = fingerprintError(bundle) else {
      Issue.record(
        "expected invalidStaticCode, got \(String(describing: fingerprintError(bundle)))")
      return
    }
  }

  @Test("an ad-hoc signed helper has no team identifier and is refused")
  func adHocSignedHelperHasNoTeam() throws {
    let bundle = try Bundle()
    try bundle.writeLaunchAgent()
    try bundle.writeInfoPlist()
    try bundle.installExecutable()
    try bundle.writeProfile()
    try bundle.adHocSign()

    #expect(fingerprintError(bundle) == .missingTeamIdentifier)
  }
}
