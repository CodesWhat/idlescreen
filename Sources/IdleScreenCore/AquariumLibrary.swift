import Foundation

public protocol IdleScreenAquariumChoice: RawRepresentable, Codable, CaseIterable, Identifiable,
  Sendable
where RawValue == String {}
extension IdleScreenAquariumChoice {
  public var id: String { rawValue }
  public var title: String {
    rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
      .capitalized
  }
}

public enum IdleScreenAquariumHabitat: String, IdleScreenAquariumChoice {
  case fantasy, freshwater, marine
}
public enum IdleScreenAquariumSubstrate: String, IdleScreenAquariumChoice {
  case basalt, riverGravel, creamSand, plantedSoil, neonGravel
}
public enum IdleScreenAquariumVariant: String, IdleScreenAquariumChoice {
  case red, orange, yellow, blue, dark, rili
}
public enum IdleScreenAquariumLight: String, IdleScreenAquariumChoice {
  case daylight, sunset, moonBlue, blacklight, automatic
}
public enum IdleScreenAquariumSex: String, Codable, Sendable { case female, male }
public enum IdleScreenAquariumEconomy: String, IdleScreenAquariumChoice { case sandbox, collection }
public enum IdleScreenAquariumPresentation: String, IdleScreenAquariumChoice {
  case perDisplay, panorama
}

public enum IdleScreenAquariumSpeciesKind: String, IdleScreenAquariumChoice {
  case cherryShrimp, mantisShrimp, lionfish, neonTetra, corydoras, snail

  public var habitat: IdleScreenAquariumHabitat {
    switch self {
    case .mantisShrimp, .lionfish: .marine
    default: .freshwater
    }
  }
  public var price: Int {
    switch self {
    case .cherryShrimp: 12
    case .mantisShrimp: 60
    case .lionfish: 70
    case .neonTetra: 15
    case .corydoras: 25
    case .snail: 8
    }
  }
}

public enum IdleScreenAquariumDecorationKind: String, IdleScreenAquariumChoice {
  case rock, slate, cave, driftwood, hollowLog, moss, grass, fern, purplePlant
  case pirateChest, skull, shipwreck, castle, diver, volcano

  /// World sizes use the original 384 by 216 scene as the authored design space.
  public var size: (width: Double, height: Double) {
    switch self {
    case .rock: (32, 12)
    case .slate: (42, 25)
    case .cave: (48, 30)
    case .driftwood: (72, 46)
    case .hollowLog: (56, 26)
    case .moss: (30, 16)
    case .grass: (22, 34)
    case .fern: (32, 48)
    case .purplePlant: (34, 66)
    case .pirateChest: (34, 26)
    case .skull: (28, 24)
    case .shipwreck: (78, 44)
    case .castle: (48, 58)
    case .diver: (20, 32)
    case .volcano: (42, 34)
    }
  }
  public var price: Int {
    switch self {
    case .rock, .moss, .grass: 5
    case .slate, .fern, .purplePlant: 10
    case .cave, .driftwood, .hollowLog, .skull, .diver: 20
    case .pirateChest, .volcano: 30
    case .shipwreck, .castle: 45
    }
  }
  public var isPlant: Bool { [.moss, .grass, .fern, .purplePlant].contains(self) }
  public var offersShelter: Bool {
    [.cave, .hollowLog, .pirateChest, .skull, .shipwreck, .castle].contains(self)
  }
}

public enum IdleScreenAquariumEquipment: String, IdleScreenAquariumChoice {
  case spongeFilter, externalFilter, airStone, heater, feeder, lightTimer, waterChanger,
    dosingController, uvClarifier
  public var price: Int {
    switch self {
    case .spongeFilter, .airStone, .lightTimer: 10
    case .heater, .feeder: 20
    case .externalFilter: 40
    case .waterChanger, .dosingController, .uvClarifier: 60
    }
  }
}

public struct IdleScreenAquariumDecoration: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var kind: IdleScreenAquariumDecorationKind
  /// Center x and bottom y in the tank's authored design space, normalized to 0...1.
  public var x: Double
  public var y: Double
  public var scale: Double
  public var flipped: Bool
  public var foreground: Bool

  public init(
    id: UUID = UUID(), kind: IdleScreenAquariumDecorationKind, x: Double, y: Double,
    scale: Double = 1, flipped: Bool = false, foreground: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.x = x
    self.y = y
    self.scale = scale
    self.flipped = flipped
    self.foreground = foreground
  }

  public func validate() throws {
    guard x.isFinite, y.isFinite, scale.isFinite, (0.5...1.5).contains(scale),
      (0.55...0.96).contains(y),
      x - kind.size.width * scale / 768 >= 0,
      x + kind.size.width * scale / 768 <= 1,
      y - kind.size.height * scale / 216 >= 0.22
    else {
      throw IdleScreenAquariumError.invalidPlacement
    }
  }
}

public struct IdleScreenAquariumInhabitant: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var species: IdleScreenAquariumSpeciesKind
  public var variant: IdleScreenAquariumVariant
  public var sex: IdleScreenAquariumSex
  public var ageMinutes: Int
  public var parents: [UUID]
  public var purchaseValue: Int = 0

  public init(
    id: UUID = UUID(), species: IdleScreenAquariumSpeciesKind = .cherryShrimp,
    variant: IdleScreenAquariumVariant = .red, sex: IdleScreenAquariumSex = .female,
    ageMinutes: Int = 120, parents: [UUID] = []
  ) {
    self.id = id
    self.species = species
    self.variant = variant
    self.sex = sex
    self.ageMinutes = ageMinutes
    self.parents = parents
  }
  public var isAdult: Bool { ageMinutes >= 20 }
}

public struct IdleScreenAquariumBrood: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var motherID: UUID
  public var fatherID: UUID
  public var dueStep: Int
  public var count: Int
  public var variant: IdleScreenAquariumVariant
}

public struct IdleScreenAquariumWater: Codable, Equatable, Sendable {
  public var waste: Double = 0.15
  public var ammonia: Double = 0.02
  public var nitrite: Double = 0.02
  public var nitrate: Double = 0.1
  public var oxygen: Double = 0.9
  public var filterMaturity: Double = 0.8
  public var algae: Double = 0.1
  public var temperature: Double = 24
  public var ph: Double = 7
  public var salinity: Double = 0

  public init() {}
  public var summary: String {
    if oxygen < 0.4 { return "More aeration would help" }
    if ammonia > 0.4 || nitrite > 0.4 { return "Filter is catching up with waste" }
    if nitrate > 0.6 { return "A water change would help" }
    if algae > 0.6 { return "Try a shorter light schedule" }
    return "Water is stable"
  }
}

public struct IdleScreenAquariumLighting: Codable, Equatable, Sendable {
  public var preset: IdleScreenAquariumLight = .daylight
  public var brightness: Double = 0.9
  public var startsAtHour: Int = 9
  public var durationHours: Int = 10
  public init() {}
}

public struct IdleScreenAquariumAutomation: Codable, Equatable, Sendable {
  public var equipment: Set<IdleScreenAquariumEquipment> = [.spongeFilter, .feeder, .lightTimer]
  public var inactiveEquipment: Set<IdleScreenAquariumEquipment>?
  public var flow: Double = 0.5
  public var heaterTemperature: Double = 24
  public var feedEveryMinutes: Int = 30
  public var changeEveryMinutes: Int = 60
  public var waterChangeFraction: Double = 0.25
  public var nitrateSetPoint: Double = 0.45
  public init() {}
}

public struct IdleScreenAquariumTank: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var seed: UInt64
  public var habitat: IdleScreenAquariumHabitat = .fantasy
  public var substrate: IdleScreenAquariumSubstrate = .basalt
  public var substrateDepth: Double = 0.14
  public var capacity: Int = 24
  public var keeperMode: Bool = false
  public var breedingEnabled: Bool = false
  public var lighting = IdleScreenAquariumLighting()
  public var automation = IdleScreenAquariumAutomation()
  public var water = IdleScreenAquariumWater()
  public var decorations: [IdleScreenAquariumDecoration] = []
  public var animals: [IdleScreenAquariumInhabitant] = []
  public var broods: [IdleScreenAquariumBrood] = []
  public var nursery: [IdleScreenAquariumInhabitant] = []
  public var simulationStep: Int = 0
  public var lastAdvancedAt: Date?
  public var presentationEpoch = Date(timeIntervalSince1970: 1_767_225_600)

  public init(id: UUID = UUID(), name: String = "My Aquarium", seed: UInt64 = 42) {
    self.id = id
    self.name = name
    self.seed = seed
  }

  public var reservedPopulation: Int { animals.count + broods.reduce(0) { $0 + $1.count } }

  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
      (4...32).contains(capacity), reservedPopulation <= capacity, nursery.count <= 64,
      substrateDepth.isFinite, (0.08...0.24).contains(substrateDepth),
      (0...1_000_000_000).contains(simulationStep),
      Set(animals.map(\.id)).count == animals.count,
      Set(nursery.map(\.id)).count == nursery.count,
      Set(animals.map(\.id)).isDisjoint(with: nursery.map(\.id)),
      Set(broods.map(\.id)).count == broods.count,
      Set(decorations.map(\.id)).count == decorations.count, decorations.count <= 24,
      lighting.brightness.isFinite, (0.15...1).contains(lighting.brightness),
      (0...23).contains(lighting.startsAtHour), (1...18).contains(lighting.durationHours),
      automation.equipment.isDisjoint(with: automation.inactiveEquipment ?? []),
      automation.flow.isFinite, (0...1).contains(automation.flow),
      automation.heaterTemperature.isFinite, (18...30).contains(automation.heaterTemperature),
      (5...240).contains(automation.feedEveryMinutes),
      (10...360).contains(automation.changeEveryMinutes),
      automation.waterChangeFraction.isFinite, (0.1...0.5).contains(automation.waterChangeFraction),
      automation.nitrateSetPoint.isFinite, (0.1...0.8).contains(automation.nitrateSetPoint),
      presentationEpoch.timeIntervalSince1970.isFinite,
      lastAdvancedAt?.timeIntervalSince1970.isFinite != false
    else {
      throw IdleScreenAquariumError.invalidTank
    }
    for item in decorations { try item.validate() }
    for animal in animals + nursery {
      guard (0...1_000_000_000).contains(animal.ageMinutes), animal.parents.count <= 2,
        (0...100).contains(animal.purchaseValue)
      else {
        throw IdleScreenAquariumError.invalidTank
      }
    }
    if keeperMode, habitat != .fantasy,
      animals.contains(where: { $0.species.habitat != habitat })
    {
      throw IdleScreenAquariumError.incompatibleHabitat
    }
    for brood in broods {
      guard (1...4).contains(brood.count), brood.dueStep >= simulationStep,
        brood.dueStep <= simulationStep + 100,
        animals.contains(where: {
          $0.id == brood.motherID && $0.species == .cherryShrimp && $0.sex == .female
        }),
        animals.contains(where: {
          $0.id == brood.fatherID && $0.species == .cherryShrimp && $0.sex == .male
        })
      else {
        throw IdleScreenAquariumError.invalidTank
      }
    }
    let concentrations = [
      water.waste, water.ammonia, water.nitrite, water.nitrate, water.oxygen, water.filterMaturity,
      water.algae,
    ]
    guard concentrations.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
      water.temperature.isFinite, (15...35).contains(water.temperature),
      water.ph.isFinite, (5...9).contains(water.ph), water.salinity.isFinite,
      (0...40).contains(water.salinity)
    else {
      throw IdleScreenAquariumError.invalidTank
    }
  }

  public mutating func place(_ decoration: IdleScreenAquariumDecoration) throws {
    try decoration.validate()
    if let index = decorations.firstIndex(where: { $0.id == decoration.id }) {
      decorations[index] = decoration
    } else {
      guard decorations.count < 24 else { throw IdleScreenAquariumError.capacityReached }
      decorations.append(decoration)
    }
  }
}

public struct IdleScreenAquariumLibrary: Codable, Equatable, Sendable {
  public static let maximumTankCount = 8
  public var schemaVersion: Int = 1
  public var revision: UInt64 = 0
  public var selectedTankID: UUID
  public var tanks: [IdleScreenAquariumTank]
  public var displayAssignments: [String: UUID] = [:]
  public var presentation: IdleScreenAquariumPresentation = .perDisplay
  public var desktopEnabled = false
  public var economy: IdleScreenAquariumEconomy = .sandbox
  public var balance = 100
  public var inventory: [String: Int] = [:]
  public var unlockedVariants: Set<IdleScreenAquariumVariant> = [.red]
  public var appliedCommands: [UUID] = []

  public init(tanks: [IdleScreenAquariumTank], selectedTankID: UUID) {
    self.tanks = tanks
    self.selectedTankID = selectedTankID
  }

  public static let starter: Self = {
    var tank = IdleScreenAquariumTank(id: identity(1), name: "Shrimp Tank")
    for index in 0..<10 {
      let species: IdleScreenAquariumSpeciesKind =
        index < 8 ? .cherryShrimp : index == 8 ? .mantisShrimp : .lionfish
      tank.animals.append(
        .init(id: identity(index + 100), species: species, sex: index % 2 == 0 ? .female : .male))
    }
    for (index, x) in [0.10, 0.29, 0.51, 0.72, 0.90].enumerated() {
      tank.decorations.append(.init(id: identity(200 + index), kind: .rock, x: x, y: 0.91))
    }
    for (index, x) in [0.04, 0.18, 0.32, 0.46, 0.60, 0.74, 0.88, 0.97].enumerated() {
      tank.decorations.append(
        .init(
          id: identity(300 + index), kind: .purplePlant,
          x: min(0.95, max(0.05, x)), y: 0.92, scale: 0.8))
    }
    return Self(tanks: [tank], selectedTankID: tank.id)
  }()

  public var selectedTank: IdleScreenAquariumTank? { tanks.first { $0.id == selectedTankID } }

  public func tank(for display: String?) -> IdleScreenAquariumTank {
    if presentation == .perDisplay, let display, let id = displayAssignments[display],
      let tank = tanks.first(where: { $0.id == id })
    {
      return tank
    }
    return selectedTank ?? tanks[0]
  }

  public mutating func duplicateLayout(of tankID: UUID, id: UUID, name: String) throws {
    guard tanks.count < Self.maximumTankCount, !tanks.contains(where: { $0.id == id }),
      let original = tanks.first(where: { $0.id == tankID })
    else { throw IdleScreenAquariumError.capacityReached }
    var copy = original
    copy.id = id
    copy.name = name
    copy.animals = []
    copy.broods = []
    copy.nursery = []
    copy.simulationStep = 0
    copy.lastAdvancedAt = nil
    copy.water = .init()
    try copy.validate()
    if economy == .collection {
      let cost =
        copy.decorations.reduce(0) { $0 + $1.kind.price }
        + copy.automation.equipment.union(copy.automation.inactiveEquipment ?? []).reduce(0) {
          $0 + $1.price
        }
      guard balance >= cost else { throw IdleScreenAquariumError.insufficientFunds }
      balance -= cost
    }
    tanks.append(copy)
    selectedTankID = id
  }

  public mutating func assign(tankID: UUID, to display: String) throws {
    guard !display.isEmpty, display.count <= 256, tanks.contains(where: { $0.id == tankID }) else {
      throw IdleScreenAquariumError.invalidTank
    }
    displayAssignments[display] = tankID
  }

  public func validate() throws {
    guard schemaVersion == 1 else { throw IdleScreenAquariumError.unsupportedSchema }
    guard (1...Self.maximumTankCount).contains(tanks.count),
      Set(tanks.map(\.id)).count == tanks.count, selectedTank != nil,
      balance >= 0, balance <= 1_000_000, inventory.count <= 32,
      inventory.allSatisfy({
        IdleScreenAquariumDecorationKind(rawValue: $0.key) != nil && (0...99).contains($0.value)
      }),
      appliedCommands.count <= 512,
      Set(appliedCommands).count == appliedCommands.count, displayAssignments.count <= 64,
      displayAssignments.allSatisfy({ assignment in
        !assignment.key.isEmpty && assignment.key.count <= 256
          && tanks.contains(where: { $0.id == assignment.value })
      }),
      tanks.reduce(0, { $0 + $1.reservedPopulation }) <= 128
    else { throw IdleScreenAquariumError.invalidTank }
    for tank in tanks { try tank.validate() }
    let inhabitants = tanks.flatMap { $0.animals + $0.nursery }
    guard Set(inhabitants.map(\.id)).count == inhabitants.count else {
      throw IdleScreenAquariumError.invalidTank
    }
  }

  private static func identity(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "A0A00000-0000-4000-8000-%012X", value))!
  }
}

public enum IdleScreenAquariumError: Error, LocalizedError, Equatable {
  case invalidTank, invalidPlacement, capacityReached, incompatibleHabitat, unsupportedSchema,
    staleRevision, insufficientFunds, missingItem, invalidOperation

  public var errorDescription: String? {
    switch self {
    case .invalidTank:
      "The aquarium contains invalid or duplicate state. The saved file was left unchanged."
    case .invalidPlacement: "Keep decorations inside the tank, below the open swimming corridor."
    case .capacityReached: "This tank or collection has reached its capacity."
    case .incompatibleHabitat:
      "This animal needs a different habitat. Use a fantasy display tank to mix habitats."
    case .unsupportedSchema: "This aquarium save needs a newer version of IdleScreen."
    case .staleRevision: "The aquarium changed in another window. Reload it before trying again."
    case .insufficientFunds: "There aren't enough aquarium coins for this item."
    case .missingItem: "That aquarium item is no longer available."
    case .invalidOperation: "That change can't be applied to this aquarium."
    }
  }
}
