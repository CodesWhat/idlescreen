import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Camera selection and configuration")
struct CameraConfigurationTests {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
  }

  @Test("device identifiers are validated for emptiness, size, and controls")
  func identifierValidation() {
    #expect(
      IdleScreenCameraSelection.deviceIfValid(uniqueID: "cam-1") == .device(uniqueID: "cam-1"))
    #expect(IdleScreenCameraSelection.deviceIfValid(uniqueID: "") == nil)
    #expect(IdleScreenCameraSelection.deviceIfValid(uniqueID: "a\nb") == nil)
    let atLimit = String(
      repeating: "a", count: IdleScreenCameraSelection.maximumDeviceIdentifierUTF8ByteCount)
    #expect(IdleScreenCameraSelection.deviceIfValid(uniqueID: atLimit) != nil)
    #expect(IdleScreenCameraSelection.deviceIfValid(uniqueID: atLimit + "a") == nil)
    #expect(IdleScreenCameraSelection.automatic.deviceIdentifier == nil)
    #expect(IdleScreenCameraSelection.device(uniqueID: "x").deviceIdentifier == "x")
  }

  @Test("selection round-trips and rejects invalid persisted identifiers")
  func selectionCoding() throws {
    for selection in [IdleScreenCameraSelection.automatic, .device(uniqueID: "cam-1")] {
      let data = try JSONEncoder().encode(selection)
      #expect(try JSONDecoder().decode(IdleScreenCameraSelection.self, from: data) == selection)
    }
    #expect(throws: DecodingError.self) {
      try decode(IdleScreenCameraSelection.self, #"{"mode":"device","deviceIdentifier":""}"#)
    }
    #expect(throws: DecodingError.self) {
      try decode(IdleScreenCameraSelection.self, #"{"mode":"device"}"#)
    }
    #expect(throws: DecodingError.self) {
      try decode(IdleScreenCameraSelection.self, #"{"mode":"teleport"}"#)
    }
    #expect(try decode(IdleScreenCameraSelection.self, #"{"mode":"automatic"}"#) == .automatic)
  }

  @Test("encoding an invalid device selection fails instead of persisting it")
  func selectionEncodeFailure() {
    #expect(throws: EncodingError.self) {
      try JSONEncoder().encode(IdleScreenCameraSelection.device(uniqueID: ""))
    }
  }

  @Test("configuration defaults to automatic and mirrored")
  func defaults() {
    let configuration = IdleScreenCameraConfiguration.default
    #expect(configuration.selection == .automatic)
    #expect(configuration.isMirrored)
    #expect(configuration.preferredDeviceIdentifier == nil)
  }

  @Test("an invalid preferred identifier is dropped at construction")
  func preferredNormalization() {
    let invalid = IdleScreenCameraConfiguration(
      selection: .automatic, preferredDeviceIdentifier: "")
    #expect(invalid.preferredDeviceIdentifier == nil)
    let valid = IdleScreenCameraConfiguration(
      selection: .automatic, preferredDeviceIdentifier: "cam")
    #expect(valid.preferredDeviceIdentifier == "cam")
    #expect(IdleScreenCameraConfiguration.validatedPreferredIdentifier(nil) == nil)
    #expect(IdleScreenCameraConfiguration.validatedPreferredIdentifier("a\u{0}b") == nil)
  }

  @Test("configuration round-trips including the preferred device and mirror flag")
  func roundTrip() throws {
    let original = IdleScreenCameraConfiguration(
      selection: .device(uniqueID: "cam-9"),
      preferredDeviceIdentifier: "cam-2",
      isMirrored: false
    )
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(IdleScreenCameraConfiguration.self, from: data) == original)
  }

  @Test("older documents without a mirror flag decode as mirrored")
  func legacyMirrorDefault() throws {
    let decoded = try decode(
      IdleScreenCameraConfiguration.self,
      #"{"selection":{"mode":"automatic"}}"#
    )
    #expect(decoded.isMirrored)
    #expect(decoded.preferredDeviceIdentifier == nil)
  }

  @Test("decoding rejects an invalid preferred identifier")
  func decodeRejectsInvalidPreferred() {
    #expect(throws: DecodingError.self) {
      try decode(
        IdleScreenCameraConfiguration.self,
        #"{"selection":{"mode":"automatic"},"preferredDeviceIdentifier":""}"#
      )
    }
  }

  @Test("encoding rejects a preferred identifier mutated into an invalid value")
  func encodeRejectsInvalidPreferred() {
    var configuration = IdleScreenCameraConfiguration.default
    configuration.preferredDeviceIdentifier = "bad\nid"
    #expect(throws: EncodingError.self) {
      try JSONEncoder().encode(configuration)
    }
  }
}
