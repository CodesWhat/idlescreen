import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Saved looks")
struct SavedLookTests {
  private func makeConfiguration() -> IdleScreenConfiguration {
    var configuration = IdleScreenConfiguration.default
    configuration.source = .camera
    configuration.appearance = .init(glyphScale: 0.7, contrast: 0.2, palette: "Ember")
    configuration.creative = IdleScreenCreativeConfiguration(pattern: .plasma)
    return configuration
  }

  @Test("saving captures only the visual state under the supplied ID")
  func saveCurrent() throws {
    let id = UUID()
    let saved = try makeConfiguration().savingCurrentLook(id: id, named: "  My\tLook \n")

    let look = try #require(saved.savedLooks.first)
    #expect(look.id == id)
    #expect(look.name == "My Look")
    #expect(look.snapshot.source == .camera)
    #expect(look.snapshot.appearance.palette == "Ember")
    #expect(look.snapshot.creative.pattern == .plasma)
  }

  @Test("saving rejects blank names, duplicate IDs, and a full collection")
  func saveErrors() throws {
    let configuration = makeConfiguration()
    #expect(throws: IdleScreenSavedLookError.invalidName) {
      try configuration.savingCurrentLook(id: UUID(), named: " \n\t ")
    }

    let id = UUID()
    let one = try configuration.savingCurrentLook(id: id, named: "One")
    #expect(throws: IdleScreenSavedLookError.duplicateID(id)) {
      try one.savingCurrentLook(id: id, named: "Again")
    }

    var full = configuration
    for index in 0..<IdleScreenSavedLook.maximumCount {
      full = try full.savingCurrentLook(id: UUID(), named: "Look \(index)")
    }
    #expect(full.savedLooks.count == IdleScreenSavedLook.maximumCount)
    #expect(
      throws: IdleScreenSavedLookError.collectionFull(
        maximumCount: IdleScreenSavedLook.maximumCount
      )
    ) {
      try full.savingCurrentLook(id: UUID(), named: "Overflow")
    }
  }

  @Test("replacing swaps the snapshot but keeps ID, name, and position")
  func replace() throws {
    let firstID = UUID()
    let secondID = UUID()
    var configuration = try makeConfiguration()
      .savingCurrentLook(id: firstID, named: "First")
      .savingCurrentLook(id: secondID, named: "Second")
    configuration.source = .generative
    configuration.creative = IdleScreenCreativeConfiguration(pattern: .aurora)

    let replaced = try configuration.replacingSavedLook(id: firstID)

    #expect(replaced.savedLooks.map(\.id) == [firstID, secondID])
    #expect(replaced.savedLooks[0].name == "First")
    #expect(replaced.savedLooks[0].snapshot.creative.pattern == .aurora)
    #expect(replaced.savedLooks[0].snapshot.source == .generative)
    #expect(replaced.savedLooks[1].snapshot.creative.pattern == .plasma)
    #expect(
      throws: IdleScreenSavedLookError.notFound(
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    ) {
      try configuration.replacingSavedLook(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    }
  }

  @Test("applying restores visuals without touching revision or the library")
  func apply() throws {
    let id = UUID()
    var configuration = try makeConfiguration().savingCurrentLook(id: id, named: "Look")
    configuration.revision = 9
    configuration.source = .generative
    configuration.appearance = .init(glyphScale: 0.1, contrast: 0.9, palette: "Ivory")
    configuration.creative = IdleScreenCreativeConfiguration(pattern: .warp)

    let applied = try configuration.applyingSavedLook(id: id)

    #expect(applied.source == .camera)
    #expect(applied.appearance.palette == "Ember")
    #expect(applied.creative.pattern == .plasma)
    #expect(applied.revision == 9)
    #expect(applied.savedLooks == configuration.savedLooks)
    let missing = UUID()
    #expect(throws: IdleScreenSavedLookError.notFound(missing)) {
      try configuration.applyingSavedLook(id: missing)
    }
  }

  @Test("renaming normalizes the name and validates it")
  func rename() throws {
    let id = UUID()
    let configuration = try makeConfiguration().savingCurrentLook(id: id, named: "Old")

    let renamed = try configuration.renamingSavedLook(id: id, to: " New\nName ")
    #expect(renamed.savedLooks[0].name == "New Name")
    #expect(renamed.savedLooks[0].snapshot == configuration.savedLooks[0].snapshot)
    #expect(throws: IdleScreenSavedLookError.invalidName) {
      try configuration.renamingSavedLook(id: id, to: "   ")
    }
    let missing = UUID()
    #expect(throws: IdleScreenSavedLookError.notFound(missing)) {
      try configuration.renamingSavedLook(id: missing, to: "X")
    }
  }

  @Test("removing deletes only the matching look")
  func remove() throws {
    let keep = UUID()
    let drop = UUID()
    let configuration = try makeConfiguration()
      .savingCurrentLook(id: keep, named: "Keep")
      .savingCurrentLook(id: drop, named: "Drop")

    let removed = try configuration.removingSavedLook(id: drop)

    #expect(removed.savedLooks.map(\.id) == [keep])
    let missing = UUID()
    #expect(throws: IdleScreenSavedLookError.notFound(missing)) {
      try removed.removingSavedLook(id: missing)
    }
  }

  @Test("name validation bounds length and byte size and strips controls")
  func nameValidation() {
    #expect(IdleScreenSavedLook.validatedName("") == nil)
    #expect(IdleScreenSavedLook.validatedName("\u{7}\u{8}") == nil)
    #expect(IdleScreenSavedLook.validatedName("a\u{7}b") == "a b")

    let long = String(repeating: "x", count: 200)
    #expect(
      IdleScreenSavedLook.validatedName(long)?.count
        == IdleScreenSavedLook.maximumNameLength
    )

    // 4-byte characters hit the 256 byte cap before the 64 character cap.
    let wide = String(repeating: "\u{1F41F}", count: 100)
    let bounded = IdleScreenSavedLook.validatedName(wide)
    #expect(bounded?.utf8.count == IdleScreenSavedLook.maximumNameUTF8ByteCount)
    #expect(bounded?.count == 64)
  }

  @Test("an unnamed look falls back to the default name")
  func defaultName() {
    let snapshot = IdleScreenLookSnapshot(
      source: .generative,
      appearance: .init(glyphScale: 0.5, contrast: 0.5, palette: "Ember"),
      creative: .default
    )
    let look = IdleScreenSavedLook(id: UUID(), name: " ", snapshot: snapshot)
    #expect(look.name == IdleScreenSavedLook.defaultName)
  }

  @Test("normalized collections drop duplicates and cap the count")
  func normalizedCollection() {
    let snapshot = IdleScreenLookSnapshot(
      source: .generative,
      appearance: .init(glyphScale: 0.5, contrast: 0.5, palette: "Ember"),
      creative: .default
    )
    let duplicateID = UUID()
    let first = IdleScreenSavedLook(id: duplicateID, name: "First", snapshot: snapshot)
    let second = IdleScreenSavedLook(id: duplicateID, name: "Second", snapshot: snapshot)
    var looks = [first, second]
    for index in 0..<40 {
      looks.append(IdleScreenSavedLook(id: UUID(), name: "L\(index)", snapshot: snapshot))
    }

    let normalized = IdleScreenSavedLook.normalizedCollection(looks)

    #expect(normalized.count == IdleScreenSavedLook.maximumCount)
    #expect(normalized[0].name == "First")
    #expect(Set(normalized.map(\.id)).count == normalized.count)
  }

  @Test("snapshots and looks round-trip, and malformed names are repaired on decode")
  func codableRepair() throws {
    let id = UUID()
    let configuration = try makeConfiguration().savingCurrentLook(id: id, named: "Round")
    let encoded = try JSONEncoder().encode(configuration.savedLooks[0])
    #expect(
      try JSONDecoder().decode(IdleScreenSavedLook.self, from: encoded)
        == configuration.savedLooks[0])

    let snapshotJSON = String(
      decoding: try JSONEncoder().encode(configuration.savedLooks[0].snapshot),
      as: UTF8.self
    )
    let damaged = Data(
      """
      {"id":"\(id.uuidString)","name":"\\n\\n","snapshot":\(snapshotJSON)}
      """.utf8)
    let repaired = try JSONDecoder().decode(IdleScreenSavedLook.self, from: damaged)
    #expect(repaired.name == IdleScreenSavedLook.defaultName)
    #expect(repaired.snapshot == configuration.savedLooks[0].snapshot)
  }

  @Test("a snapshot without materials decodes with the default materials")
  func snapshotWithoutMaterials() throws {
    let encoded = try JSONEncoder().encode(
      makeConfiguration().savingCurrentLook(id: UUID(), named: "A").savedLooks[0].snapshot)
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "materials")
    let stripped = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(IdleScreenLookSnapshot.self, from: stripped)

    #expect(decoded.materials == IdleScreenPixelMaterialsConfiguration.default.normalized)
  }
}
