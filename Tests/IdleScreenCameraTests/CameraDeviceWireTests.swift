import Foundation
import Testing

@testable import IdleScreenCamera

@Suite("Camera device wire contract")
struct CameraDeviceWireTests {
  private func roundTrip<Value: NSObject & NSSecureCoding>(_ value: Value) throws -> Value {
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: value,
      requiringSecureCoding: true
    )
    return try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: Value.self, from: data))
  }

  private func descriptor(
    _ identifier: String,
    name: String = "FaceTime HD Camera",
    kind: IdleScreenCameraDeviceKind = .builtIn
  ) throws -> IdleScreenCameraDeviceDescriptor {
    try #require(
      IdleScreenCameraDeviceDescriptor(
        deviceIdentifier: identifier,
        displayName: name,
        kind: kind
      )
    )
  }

  private func identity(
    processIdentifier: Int32 = 4_242,
    epoch: UInt64 = 7,
    sourceAppPath: String = "/Applications/IdleScreen.app"
  ) throws -> IdleScreenCameraAgentIdentity {
    try #require(
      IdleScreenCameraAgentIdentity(
        processIdentifier: processIdentifier,
        processIncarnationEpoch: epoch,
        bundleIdentifier: "com.idlescreen.camera-agent",
        serviceIdentifier: "group.com.idlescreen.shared.camera-agent",
        bundleVersion: "1",
        marketingVersion: "0.1",
        signingIdentifier: "com.idlescreen.camera-agent",
        teamIdentifier: "3524374A2S",
        codeDirectoryHash: String(repeating: "1", count: 40),
        executableSHA256: String(repeating: "a", count: 64),
        launchAgentSHA256: String(repeating: "b", count: 64),
        provisioningProfileSHA256: String(repeating: "c", count: 64),
        sourceAppPath: sourceAppPath
      )
    )
  }

  @Test("descriptors round trip and reject empty or control-character fields")
  func descriptorValidation() throws {
    let original = try descriptor("device-1", name: "Studio Display Camera", kind: .external)
    let decoded = try roundTrip(original)
    #expect(decoded.deviceIdentifier == "device-1")
    #expect(decoded.displayName == "Studio Display Camera")
    #expect(decoded.kind == .external)

    #expect(
      IdleScreenCameraDeviceDescriptor(deviceIdentifier: "", displayName: "n", kind: .builtIn)
        == nil)
    #expect(
      IdleScreenCameraDeviceDescriptor(deviceIdentifier: "id", displayName: "", kind: .builtIn)
        == nil)
    #expect(
      IdleScreenCameraDeviceDescriptor(deviceIdentifier: "i\nd", displayName: "n", kind: .builtIn)
        == nil)
    #expect(
      IdleScreenCameraDeviceDescriptor(
        deviceIdentifier: "id", displayName: "n\u{7}", kind: .builtIn) == nil)
    let tooLongName = String(
      repeating: "n", count: IdleScreenCameraWire.maximumCameraDeviceNameUTF8ByteCount + 1)
    #expect(
      IdleScreenCameraDeviceDescriptor(
        deviceIdentifier: "id", displayName: tooLongName, kind: .builtIn) == nil)
    let tooLongID = String(
      repeating: "i", count: IdleScreenCameraWire.maximumCameraDeviceIdentifierUTF8ByteCount + 1)
    #expect(
      IdleScreenCameraDeviceDescriptor(
        deviceIdentifier: tooLongID, displayName: "n", kind: .builtIn) == nil)
  }

  @Test("a descriptor archive missing its kind or carrying an unknown kind is refused")
  func descriptorDecodeFailures() throws {
    let missingKind = NSKeyedArchiver(requiringSecureCoding: true)
    missingKind.encode("id" as NSString, forKey: "cameraDeviceIdentifier")
    missingKind.encode("name" as NSString, forKey: "cameraDeviceName")
    missingKind.finishEncoding()
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: missingKind.encodedData)
    unarchiver.requiresSecureCoding = true
    #expect(IdleScreenCameraDeviceDescriptor(coder: unarchiver) == nil)

    let unknownKind = NSKeyedArchiver(requiringSecureCoding: true)
    unknownKind.encode("id" as NSString, forKey: "cameraDeviceIdentifier")
    unknownKind.encode("name" as NSString, forKey: "cameraDeviceName")
    unknownKind.encode(99, forKey: "cameraDeviceKind")
    unknownKind.finishEncoding()
    let second = try NSKeyedUnarchiver(forReadingFrom: unknownKind.encodedData)
    second.requiresSecureCoding = true
    #expect(IdleScreenCameraDeviceDescriptor(coder: second) == nil)
  }

  @Test("selection state enforces the mode and identifier pairing")
  func selectionStateValidation() throws {
    let automatic = try #require(
      IdleScreenCameraDeviceSelectionState(mode: .automatic, deviceIdentifier: nil)
    )
    let explicit = try #require(
      IdleScreenCameraDeviceSelectionState(mode: .explicitDevice, deviceIdentifier: "cam-1")
    )
    #expect(
      IdleScreenCameraDeviceSelectionState(mode: .automatic, deviceIdentifier: "cam-1") == nil)
    #expect(
      IdleScreenCameraDeviceSelectionState(mode: .explicitDevice, deviceIdentifier: nil) == nil)
    #expect(
      IdleScreenCameraDeviceSelectionState(mode: .explicitDevice, deviceIdentifier: "") == nil)

    let decodedAutomatic = try roundTrip(automatic)
    #expect(decodedAutomatic.mode == .automatic)
    #expect(decodedAutomatic.deviceIdentifier == nil)
    let decodedExplicit = try roundTrip(explicit)
    #expect(decodedExplicit.mode == .explicitDevice)
    #expect(decodedExplicit.deviceIdentifier == "cam-1")
  }

  @Test("an accepted snapshot round trips with every optional field")
  func acceptedSnapshotRoundTrip() throws {
    let selection = try #require(
      IdleScreenCameraDeviceSelectionState(mode: .explicitDevice, deviceIdentifier: "cam-2")
    )
    let reply = try #require(
      IdleScreenCameraDeviceSnapshotReply(
        accepted: true,
        errorCode: .none,
        errorMessage: nil,
        inventoryGeneration: 12,
        connectedDevices: [try descriptor("cam-1"), try descriptor("cam-2", kind: .external)],
        configuredSelection: selection,
        preferredDeviceIdentifier: "cam-1",
        resolvedDeviceIdentifier: "cam-2",
        activeDeviceIdentifier: "cam-2",
        reconfigurationPending: true
      )
    )

    let decoded = try roundTrip(reply)

    #expect(decoded.accepted)
    #expect(decoded.inventoryGeneration == 12)
    #expect(decoded.connectedDevices.map(\.deviceIdentifier) == ["cam-1", "cam-2"])
    #expect(decoded.configuredSelection?.deviceIdentifier == "cam-2")
    #expect(decoded.preferredDeviceIdentifier == "cam-1")
    #expect(decoded.resolvedDeviceIdentifier == "cam-2")
    #expect(decoded.activeDeviceIdentifier == "cam-2")
    #expect(decoded.reconfigurationPending)
  }

  @Test("a rejected snapshot must be empty and carries its error")
  func rejectedSnapshot() throws {
    let rejected = try #require(
      IdleScreenCameraDeviceSnapshotReply(
        accepted: false,
        errorCode: .notAuthorized,
        errorMessage: "Camera permission has not been granted.",
        inventoryGeneration: 0,
        connectedDevices: [],
        configuredSelection: nil,
        resolvedDeviceIdentifier: nil,
        activeDeviceIdentifier: nil,
        reconfigurationPending: false
      )
    )
    let decoded = try roundTrip(rejected)
    #expect(!decoded.accepted)
    #expect(decoded.errorCode == .notAuthorized)
    #expect(decoded.configuredSelection == nil)
    #expect(decoded.connectedDevices.isEmpty)

    // A rejection that still reports inventory is internally inconsistent.
    #expect(
      IdleScreenCameraDeviceSnapshotReply(
        accepted: false,
        errorCode: .notAuthorized,
        errorMessage: nil,
        inventoryGeneration: 3,
        connectedDevices: [],
        configuredSelection: nil,
        resolvedDeviceIdentifier: nil,
        activeDeviceIdentifier: nil,
        reconfigurationPending: false
      ) == nil
    )
    #expect(
      IdleScreenCameraDeviceSnapshotReply(
        accepted: false,
        errorCode: .notAuthorized,
        errorMessage: nil,
        inventoryGeneration: 0,
        connectedDevices: [],
        configuredSelection: nil,
        resolvedDeviceIdentifier: "cam",
        activeDeviceIdentifier: nil,
        reconfigurationPending: false
      ) == nil
    )
  }

  @Test("an accepted snapshot needs a selection, unique devices, and bounded inventory")
  func acceptedSnapshotValidation() throws {
    let selection = try #require(
      IdleScreenCameraDeviceSelectionState(mode: .automatic, deviceIdentifier: nil)
    )
    func make(
      generation: UInt64 = 1,
      devices: [IdleScreenCameraDeviceDescriptor] = [],
      selection: IdleScreenCameraDeviceSelectionState?,
      active: String? = nil
    ) -> IdleScreenCameraDeviceSnapshotReply? {
      IdleScreenCameraDeviceSnapshotReply(
        accepted: true,
        errorCode: .none,
        errorMessage: nil,
        inventoryGeneration: generation,
        connectedDevices: devices,
        configuredSelection: selection,
        resolvedDeviceIdentifier: nil,
        activeDeviceIdentifier: active,
        reconfigurationPending: false
      )
    }

    #expect(make(selection: selection) != nil)
    #expect(make(selection: nil) == nil)
    #expect(
      make(devices: [try descriptor("dup"), try descriptor("dup")], selection: selection) == nil)
    #expect(make(generation: UInt64(Int64.max) + 1, selection: selection) == nil)
    #expect(make(selection: selection, active: "") == nil)
    let many = try (0...IdleScreenCameraWire.maximumCameraDeviceCount).map {
      try descriptor("cam-\($0)")
    }
    #expect(make(devices: many, selection: selection) == nil)
  }

  @Test("a snapshot archive with a negative generation or missing fields is refused")
  func snapshotDecodeFailures() throws {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    archiver.encode(IdleScreenCameraWire.currentSchemaVersion, forKey: "schemaVersion")
    archiver.encode(true, forKey: "accepted")
    archiver.finishEncoding()
    let sparse = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
    sparse.requiresSecureCoding = true
    #expect(IdleScreenCameraDeviceSnapshotReply(coder: sparse) == nil)
  }

  @Test("agent identities compare and hash by every identifying field")
  func identityEquality() throws {
    let base = try identity()
    let same = try identity()
    let otherPID = try identity(processIdentifier: 4_243)
    let otherEpoch = try identity(epoch: 8)
    let otherPath = try identity(sourceAppPath: "/Applications/Other.app")

    #expect(base.isEqual(same))
    #expect(base.hash == same.hash)
    #expect(!base.isEqual(otherPID))
    #expect(!base.isEqual(otherEpoch))
    #expect(!base.isEqual(otherPath))
    #expect(!base.isEqual("not an identity"))
    #expect(!base.isEqual(nil))
    #expect(Set([base, same, otherPID]).count == 2)
  }

  @Test("an identity matches only its own positive process identifier")
  func identityProcessMatch() throws {
    let base = try identity()
    #expect(base.matches(remoteProcessIdentifier: 4_242))
    #expect(!base.matches(remoteProcessIdentifier: 4_243))
    #expect(!base.matches(remoteProcessIdentifier: 0))
    #expect(!base.matches(remoteProcessIdentifier: -4_242))
  }
}
