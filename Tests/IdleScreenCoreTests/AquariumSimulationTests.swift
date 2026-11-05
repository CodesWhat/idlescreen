import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Aquarium collection and care")
struct AquariumSimulationTests {
  @Test func purchasesRespectPricesHabitatAndOwnedInventory() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.economy = .collection
    let balance = library.balance
    try library.buyDecoration(.pirateChest)
    #expect(library.balance == balance - 30)
    #expect(library.inventory["pirateChest"] == 1)
    let item = IdleScreenAquariumDecoration(kind: .pirateChest, x: 0.5, y: 0.9)
    try library.placeOwnedDecoration(item)
    #expect(library.inventory["pirateChest", default: 0] == 0)
    try library.removeDecoration(id: item.id)
    #expect(library.inventory["pirateChest"] == 1)
    library.tanks[0].animals.removeAll()
    library.tanks[0].keeperMode = true
    library.tanks[0].habitat = .freshwater
    #expect(throws: IdleScreenAquariumError.self) {
      try library.buyAnimal(.lionfish, variant: .red, sex: .female, id: UUID())
    }
    #expect(library.balance == balance - 30)
    try library.buyAnimal(.cherryShrimp, variant: .blue, sex: .female, id: UUID())
    #expect(library.unlockedVariants.contains(.blue))
    #expect(library.balance == balance - 42)
  }

  @Test func disabledEquipmentRemainsOwnedAcrossSavesAndReactivationIsFree() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.economy = .collection
    let originalBalance = library.balance
    try library.buyEquipment(.heater)
    let paidBalance = library.balance
    #expect(paidBalance == originalBalance - IdleScreenAquariumEquipment.heater.price)
    try library.setEquipmentActive(.heater, active: false)
    #expect(!library.selectedTank!.automation.equipment.contains(.heater))
    library = try JSONDecoder().decode(
      IdleScreenAquariumLibrary.self, from: JSONEncoder().encode(library))
    try library.buyEquipment(.heater)
    #expect(library.balance == paidBalance)
    #expect(library.selectedTank!.automation.equipment.contains(.heater))
    try library.validate()
  }

  @Test func existingSavesWithoutInactiveEquipmentStillDecode() throws {
    let data = try JSONEncoder().encode(IdleScreenAquariumLibrary.starter)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var tanks = try #require(object["tanks"] as? [[String: Any]])
    var automation = try #require(tanks[0]["automation"] as? [String: Any])
    automation.removeValue(forKey: "inactiveEquipment")
    tanks[0]["automation"] = automation
    object["tanks"] = tanks
    let decoded = try JSONDecoder().decode(
      IdleScreenAquariumLibrary.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded == .starter)
  }

  @Test func nurseryCanHoldIncompatibleAnimalsWhileTankHabitatChanges() throws {
    var library = IdleScreenAquariumLibrary.starter
    let mantis = try #require(library.tanks[0].animals.first { $0.species == .mantisShrimp })
    library.tanks[0].animals = [mantis]
    try library.moveToNursery(id: mantis.id)
    library.tanks[0].habitat = .freshwater
    library.tanks[0].keeperMode = true
    try library.validate()
    #expect(throws: IdleScreenAquariumError.incompatibleHabitat) {
      try library.returnFromNursery(id: mantis.id)
    }
    #expect(library.tanks[0].nursery == [mantis])
    library.tanks[0].habitat = .marine
    try library.returnFromNursery(id: mantis.id)
    #expect(library.tanks[0].animals == [mantis])
  }

  @Test func crabAndCodexFishArePurchasablePersistentCatalogSpecies() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.economy = .collection
    let balance = library.balance
    try library.buyAnimal(.clawedCrab, variant: .orange, sex: .female, id: UUID())
    try library.buyAnimal(.codexFish, variant: .blue, sex: .male, id: UUID())
    #expect(
      library.balance == balance - IdleScreenAquariumSpeciesKind.clawedCrab.price
        - IdleScreenAquariumSpeciesKind.codexFish.price)
    let reopened = try JSONDecoder().decode(
      IdleScreenAquariumLibrary.self, from: JSONEncoder().encode(library))
    #expect(reopened.tanks[0].animals.contains { $0.species == .clawedCrab })
    #expect(reopened.tanks[0].animals.contains { $0.species == .codexFish })
    #expect(IdleScreenAquariumSpeciesKind.clawedCrab.habitat == .marine)
    #expect(IdleScreenAquariumSpeciesKind.codexFish.habitat == .fantasy)
    try reopened.validate()
  }

  @Test func breedingIsBoundedAndRepeatedResumeCannotDuplicateBirths() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].breedingEnabled = true
    library.tanks[0].capacity = 14
    let start = Date(timeIntervalSince1970: 1_000)
    library.advance(to: start)
    library.advance(to: start.addingTimeInterval(40 * 60))
    let after = library
    #expect(library.tanks[0].animals.contains { !$0.parents.isEmpty })
    #expect(library.tanks[0].reservedPopulation <= 14)
    library.advance(to: start.addingTimeInterval(40 * 60))
    #expect(library == after)
    library.advance(to: start.addingTimeInterval(-100))
    #expect(library == after)
    library.advance(to: start.addingTimeInterval(365 * 86_400))
    #expect(library.tanks[0].simulationStep == 400)
    #expect(library.tanks[0].animals.count <= 14)
    #expect(Set(library.tanks[0].animals.map(\.id)).count == library.tanks[0].animals.count)
    try library.validate()
  }

  @Test func capacityIncludesPendingBroodsAndNurseryTransfers() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].breedingEnabled = true
    library.tanks[0].capacity = 12
    let start = Date(timeIntervalSince1970: 10_000)
    library.advance(to: start)
    library.advance(to: start.addingTimeInterval(20 * 60))
    #expect(library.tanks[0].reservedPopulation == 12)
    #expect(throws: IdleScreenAquariumError.self) {
      try library.buyAnimal(.cherryShrimp, variant: .red, sex: .male, id: UUID())
    }
    let mantis = try #require(library.tanks[0].animals.first { $0.species == .mantisShrimp })
    try library.moveToNursery(id: mantis.id)
    #expect(library.tanks[0].nursery.contains { $0.id == mantis.id })
    try library.returnFromNursery(id: mantis.id)
    #expect(library.tanks[0].animals.contains { $0.id == mantis.id })
  }

  @Test func filterFlowChangesTurnoverWithoutBypassingTheCareModel() throws {
    var slow = IdleScreenAquariumLibrary.starter
    slow.tanks[0].keeperMode = true
    slow.tanks[0].automation.flow = 0
    slow.tanks[0].water.ammonia = 0.6
    slow.tanks[0].water.filterMaturity = 1
    let start = Date(timeIntervalSince1970: 10_000)
    slow.advance(to: start)
    var fast = slow
    fast.tanks[0].automation.flow = 1
    slow.advance(to: start.addingTimeInterval(10 * 60))
    fast.advance(to: start.addingTimeInterval(10 * 60))
    #expect(fast.tanks[0].water.ammonia < slow.tanks[0].water.ammonia)
    #expect(fast.tanks[0].water.nitrate > slow.tanks[0].water.nitrate)
    try slow.validate()
    try fast.validate()
  }

  @Test func waterRespondsToFoodFilteringAndWaterChangesWithoutOfflineDeaths() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].keeperMode = true
    library.tanks[0].automation.equipment = []
    try library.feed()
    #expect(library.tanks[0].water.waste > 0.15)
    let start = Date(timeIntervalSince1970: 10_000)
    library.advance(to: start)
    library.advance(to: start.addingTimeInterval(30 * 60))
    let dirty = library.tanks[0].water
    #expect(dirty.ammonia > 0.02)
    try library.changeWater(fraction: 0.5)
    #expect(library.tanks[0].water.ammonia < dirty.ammonia)
    try library.buyEquipment(.externalFilter)
    try library.buyEquipment(.airStone)
    let before = library.tanks[0].water
    library.advance(to: start.addingTimeInterval(60 * 60))
    #expect(library.tanks[0].water.filterMaturity >= before.filterMaturity)
    #expect(library.tanks[0].water.oxygen > before.oxygen)
    library.advance(to: start.addingTimeInterval(100 * 86_400))
    #expect(library.tanks[0].animals.count == 10)
    try library.validate()
  }

  @Test func offspringIdentityCannotAliasAnExistingAnimal() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].breedingEnabled = true
    library.tanks[0].animals.append(
      .init(
        id: UUID(uuidString: "A0A00000-0000-4000-8000-000000000070")!, species: .corydoras))
    let start = Date(timeIntervalSince1970: 0)
    library.advance(to: start)
    library.advance(to: start.addingTimeInterval(30 * 60))
    try library.validate()
    #expect(Set(library.tanks[0].animals.map(\.id)).count == library.tanks[0].animals.count)
  }

  @Test func displayModeDoesNotRequireWaterMaintenance() {
    var library = IdleScreenAquariumLibrary.starter
    let water = library.tanks[0].water
    library.advance(to: Date(timeIntervalSince1970: 0))
    library.advance(to: Date(timeIntervalSince1970: 86_400))
    #expect(library.tanks[0].water == water)
  }
}
