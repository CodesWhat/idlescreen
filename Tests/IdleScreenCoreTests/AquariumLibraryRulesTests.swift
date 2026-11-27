import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Aquarium library rules")
struct AquariumLibraryRulesTests {
  @Test func choiceTitlesSplitCamelCase() {
    #expect(IdleScreenAquariumSpeciesKind.cherryShrimp.title == "Cherry Shrimp")
    #expect(IdleScreenAquariumLight.moonBlue.title == "Moon Blue")
    #expect(IdleScreenAquariumHabitat.marine.id == "marine")
  }

  @Test func everySpeciesDescribesItself() {
    for species in IdleScreenAquariumSpeciesKind.allCases {
      #expect(!species.sizeDescription.isEmpty)
      #expect(!species.behaviorDescription.isEmpty)
    }
    #expect(IdleScreenAquariumSpeciesKind.snail.sizeDescription == "Tiny")
    #expect(IdleScreenAquariumSpeciesKind.lionfish.sizeDescription == "Large")
    #expect(IdleScreenAquariumSpeciesKind.clawedCrab.sizeDescription == "Medium")
  }

  @Test func habitatRangesAreOrderedAndFreshwaterIsSaltFree() {
    for habitat in IdleScreenAquariumHabitat.allCases {
      #expect(habitat.temperatureRange.lowerBound < habitat.temperatureRange.upperBound)
      #expect(habitat.phRange.lowerBound < habitat.phRange.upperBound)
    }
    #expect(IdleScreenAquariumHabitat.freshwater.salinityRange == 0...0)
    #expect(IdleScreenAquariumHabitat.marine.salinityRange.contains(33))
    #expect(!IdleScreenAquariumHabitat.marine.temperatureRange.contains(18))
  }

  @Test func worldWidthsGrowWithSize() {
    #expect(IdleScreenAquariumWorldSize.standard.width < IdleScreenAquariumWorldSize.long.width)
    #expect(IdleScreenAquariumWorldSize.long.width < IdleScreenAquariumWorldSize.wide.width)
  }

  @Test func decorationShelterFollowsTheKind() {
    #expect(IdleScreenAquariumDecorationKind.cave.offersShelter)
    #expect(IdleScreenAquariumDecorationKind.castle.offersShelter)
    #expect(!IdleScreenAquariumDecorationKind.rock.offersShelter)
    #expect(!IdleScreenAquariumDecorationKind.fern.offersShelter)
    #expect(IdleScreenAquariumDecorationKind.fern.isPlant)
    #expect(!IdleScreenAquariumDecorationKind.volcano.isPlant)
  }

  @Test func waterSummaryReportsTheMostUrgentProblemFirst() {
    var water = IdleScreenAquariumWater()
    #expect(water.summary == "Water is stable")

    water.filterLoad = 0.9
    #expect(water.summary == "Filter media could use a rinse")
    water.algae = 0.9
    #expect(water.summary == "Try a shorter light schedule")
    water.nitrate = 0.9
    #expect(water.summary == "A water change would help")
    water.ammonia = 0.9
    #expect(water.summary == "Filter is catching up with waste")
    water.oxygen = 0.1
    #expect(water.summary == "More aeration would help")
  }

  @Test func displayAssignmentValidatesTankAndDisplayName() throws {
    var library = IdleScreenAquariumLibrary.starter
    let tankID = library.tanks[0].id

    try library.assign(tankID: tankID, to: "display-1")
    #expect(library.displayAssignments["display-1"] == tankID)
    #expect(throws: IdleScreenAquariumError.invalidTank) {
      try library.assign(tankID: tankID, to: "")
    }
    #expect(throws: IdleScreenAquariumError.invalidTank) {
      try library.assign(tankID: tankID, to: String(repeating: "d", count: 257))
    }
    #expect(throws: IdleScreenAquariumError.invalidTank) {
      try library.assign(tankID: UUID(), to: "display-2")
    }
    #expect(library.displayAssignments.count == 1)
  }

  @Test func libraryValidationRejectsStructuralCorruption() throws {
    let starter = IdleScreenAquariumLibrary.starter
    try starter.validate()

    var future = starter
    future.schemaVersion = 2
    #expect(throws: IdleScreenAquariumError.unsupportedSchema) { try future.validate() }

    var negativeBalance = starter
    negativeBalance.balance = -1
    #expect(throws: IdleScreenAquariumError.invalidTank) { try negativeBalance.validate() }

    var richBalance = starter
    richBalance.balance = 1_000_001
    #expect(throws: IdleScreenAquariumError.invalidTank) { try richBalance.validate() }

    var unknownInventory = starter
    unknownInventory.inventory = ["notADecoration": 1]
    #expect(throws: IdleScreenAquariumError.invalidTank) { try unknownInventory.validate() }

    var outOfRangeInventory = starter
    outOfRangeInventory.inventory = [IdleScreenAquariumDecorationKind.rock.rawValue: 100]
    #expect(throws: IdleScreenAquariumError.invalidTank) { try outOfRangeInventory.validate() }

    var orphanSelection = starter
    orphanSelection.selectedTankID = UUID()
    #expect(throws: IdleScreenAquariumError.invalidTank) { try orphanSelection.validate() }

    var duplicateTanks = starter
    duplicateTanks.tanks.append(starter.tanks[0])
    #expect(throws: IdleScreenAquariumError.invalidTank) { try duplicateTanks.validate() }

    var dangling = starter
    dangling.displayAssignments = ["display": UUID()]
    #expect(throws: IdleScreenAquariumError.invalidTank) { try dangling.validate() }

    var duplicateCommands = starter
    let command = UUID()
    duplicateCommands.appliedCommands = [command, command]
    #expect(throws: IdleScreenAquariumError.invalidTank) { try duplicateCommands.validate() }
  }

  @Test func tankValidationRejectsImplausibleAnimalsAndBroods() throws {
    let starter = IdleScreenAquariumLibrary.starter

    var ancient = starter
    ancient.tanks[0].animals[0].ageMinutes = 1_000_000_001
    #expect(throws: IdleScreenAquariumError.invalidTank) { try ancient.validate() }

    var overpriced = starter
    overpriced.tanks[0].animals[0].purchaseValue = 101
    #expect(throws: IdleScreenAquariumError.invalidTank) { try overpriced.validate() }

    var lateBrood = starter
    let animals = lateBrood.tanks[0].animals
    let female = try #require(animals.first { $0.species == .cherryShrimp && $0.sex == .female })
    let male = try #require(animals.first { $0.species == .cherryShrimp && $0.sex == .male })
    lateBrood.tanks[0].broods = [
      .init(
        id: UUID(), motherID: female.id, fatherID: male.id,
        dueStep: lateBrood.tanks[0].simulationStep + 101, count: 1, variant: .red)
    ]
    #expect(throws: IdleScreenAquariumError.invalidTank) { try lateBrood.validate() }

    var swapped = starter
    swapped.tanks[0].broods = [
      .init(
        id: UUID(), motherID: male.id, fatherID: female.id,
        dueStep: swapped.tanks[0].simulationStep, count: 1, variant: .red)
    ]
    #expect(throws: IdleScreenAquariumError.invalidTank) { try swapped.validate() }

    var valid = starter
    valid.tanks[0].broods = [
      .init(
        id: UUID(), motherID: female.id, fatherID: male.id,
        dueStep: valid.tanks[0].simulationStep + 5, count: 2, variant: .red)
    ]
    try valid.validate()
  }

  @Test func keeperModeRequiresAnimalsToMatchTheHabitat() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.tanks[0].keeperMode = true
    library.tanks[0].habitat = .marine

    #expect(throws: IdleScreenAquariumError.incompatibleHabitat) { try library.validate() }

    library.tanks[0].habitat = .fantasy
    try library.validate()
  }

  @Test func duplicatingALayoutIsBoundedByCapacityAndFunds() throws {
    var library = IdleScreenAquariumLibrary.starter
    let source = library.tanks[0].id
    library.balance = 1_000
    try library.duplicateLayout(of: source, id: UUID(), name: "Copy")
    #expect(library.tanks.count == 2)
    #expect(library.tanks[1].animals.isEmpty)
    #expect(library.selectedTankID == library.tanks[1].id)

    #expect(throws: IdleScreenAquariumError.capacityReached) {
      try library.duplicateLayout(of: UUID(), id: UUID(), name: "Missing")
    }
    #expect(throws: IdleScreenAquariumError.capacityReached) {
      try library.duplicateLayout(of: source, id: library.tanks[1].id, name: "Same id")
    }

    while library.tanks.count < IdleScreenAquariumLibrary.maximumTankCount {
      try library.duplicateLayout(of: source, id: UUID(), name: "More")
    }
    #expect(throws: IdleScreenAquariumError.capacityReached) {
      try library.duplicateLayout(of: source, id: UUID(), name: "Overflow")
    }
  }

  @Test func errorsDescribeThemselves() {
    #expect(
      IdleScreenAquariumError.capacityReached.errorDescription
        == "This tank or collection has reached its capacity.")
    #expect(IdleScreenAquariumError.invalidTank.errorDescription?.isEmpty == false)
  }
}
