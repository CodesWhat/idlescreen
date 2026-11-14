import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Aquarium layout presets")
struct AquariumLayoutPresetTests {
  @Test func applyingAPresetRebindsMossToTheCopiedSupport() throws {
    var library = IdleScreenAquariumLibrary.starter
    let wood = IdleScreenAquariumDecoration(kind: .driftwood, x: 0.5, y: 0.9)
    let moss = IdleScreenAquariumDecoration(kind: .moss, x: 0.3, y: 0.9)
    library.tanks[0].decorations = [wood, moss]
    try library.tanks[0].attachMoss(id: moss.id, to: wood.id)
    let preset = UUID()
    try library.saveLayoutPreset(id: preset, name: "Mossy wood")
    try library.applyLayoutPreset(id: preset)
    let copiedWood = try #require(library.tanks[0].decorations.first { $0.kind == .driftwood })
    let copiedMoss = try #require(library.tanks[0].decorations.first { $0.kind == .moss })
    #expect(copiedWood.id != wood.id && copiedMoss.id != moss.id)
    #expect(copiedMoss.attachment?.parentID == copiedWood.id)
    try library.validate()
  }

  @Test func savedDesignRoundTripsWithoutLivestockOrEquipment() throws {
    var library = IdleScreenAquariumLibrary.starter
    let id = UUID()
    try library.saveLayoutPreset(id: id, name: "River wood")
    let preset = try #require(library.layoutPresets?.first)
    #expect(preset.name == "River wood")
    #expect(preset.layout.decorations == library.tanks[0].decorations)
    let data = try JSONEncoder().encode(preset)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let layout = try #require(object["layout"] as? [String: Any])
    #expect(layout["animals"] == nil)
    #expect(layout["automation"] == nil)
    let reopened = try JSONDecoder().decode(
      IdleScreenAquariumLibrary.self, from: JSONEncoder().encode(library))
    #expect(reopened == library)
    try reopened.validate()
  }

  @Test func applyingADesignUsesOwnedDecorAndBuysOnlyMissingPieces() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].decorations = [.init(kind: .pirateChest, x: 0.5, y: 0.9)]
    let id = UUID()
    try library.saveLayoutPreset(id: id, name: "Treasure")
    library.tanks[0].decorations = []
    library.economy = .collection
    let balance = library.balance
    let animals = library.tanks[0].animals
    try library.applyLayoutPreset(id: id)
    #expect(library.balance == balance - 30)
    #expect(library.tanks[0].decorations.map(\.kind) == [.pirateChest])
    try library.applyLayoutPreset(id: id)
    #expect(library.balance == balance - 30)
    #expect(library.tanks[0].animals == animals)
    #expect(library.inventory["pirateChest", default: 0] == 0)
    try library.validate()
  }

  @Test func unaffordableDesignDoesNotChangeTheTankOrInventory() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].decorations = [.init(kind: .pirateChest, x: 0.5, y: 0.9)]
    let id = UUID()
    try library.saveLayoutPreset(id: id, name: "Treasure")
    library.tanks[0].decorations = [.init(kind: .rock, x: 0.5, y: 0.9)]
    library.economy = .collection
    library.balance = 0
    let before = library
    #expect(throws: IdleScreenAquariumError.insufficientFunds) {
      try library.applyLayoutPreset(id: id)
    }
    #expect(library == before)
  }

  @Test func resetAndPresetLimitsPreservePopulationAndOldSaves() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].substrate = .neonGravel
    library.tanks[0].worldSize = .wide
    let animals = library.tanks[0].animals
    try library.resetLayout()
    #expect(library.tanks[0].substrate == .basalt)
    #expect(library.tanks[0].worldWidth == 384)
    #expect(library.tanks[0].animals == animals)
    for index in 0..<16 { try library.saveLayoutPreset(id: UUID(), name: "Layout \(index)") }
    #expect(throws: IdleScreenAquariumError.capacityReached) {
      try library.saveLayoutPreset(id: UUID(), name: "Overflow")
    }
    let id = try #require(library.layoutPresets?.first?.id)
    try library.deleteLayoutPreset(id: id)
    #expect(library.layoutPresets?.count == 15)
    let old = try JSONDecoder().decode(
      IdleScreenAquariumLibrary.self,
      from: JSONEncoder().encode(IdleScreenAquariumLibrary.starter))
    #expect(old.layoutPresets == nil)
  }
}
