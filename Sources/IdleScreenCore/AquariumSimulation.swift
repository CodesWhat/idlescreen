import CryptoKit
import Foundation

extension IdleScreenAquariumLibrary {
  public mutating func setKeeperMode(_ enabled: Bool) throws {
    let index = try selectedIndex()
    guard tanks[index].keeperMode != enabled else { return }
    var tank = tanks[index]
    tank.keeperMode = enabled
    if enabled {
      let basics: Set<IdleScreenAquariumEquipment> = [.spongeFilter, .feeder, .lightTimer]
      tank.automation.equipment.formUnion(basics)
      tank.automation.inactiveEquipment?.subtract(basics)
      if tank.automation.inactiveEquipment?.isEmpty == true {
        tank.automation.inactiveEquipment = nil
      }
      tank.lighting.preset = .automatic
      tank.lighting.durationHours = min(12, max(6, tank.lighting.durationHours))
      tank.boundHabitatWater()
    }
    try tank.validate()
    tanks[index] = tank
  }

  public mutating func setHabitat(_ habitat: IdleScreenAquariumHabitat) throws {
    let index = try selectedIndex()
    guard tanks[index].habitat != habitat else { return }
    var tank = tanks[index]
    tank.habitat = habitat
    if tank.keeperMode { tank.boundHabitatWater() }
    try tank.validate()
    tanks[index] = tank
  }

  public mutating func buyAnimal(
    _ species: IdleScreenAquariumSpeciesKind,
    variant: IdleScreenAquariumVariant, sex: IdleScreenAquariumSex,
    id: UUID
  ) throws {
    let index = try selectedIndex()
    guard tanks[index].reservedPopulation < tanks[index].capacity,
      tanks.reduce(0, { $0 + $1.reservedPopulation }) < 128
    else { throw IdleScreenAquariumError.capacityReached }
    guard !tanks.flatMap({ $0.animals + $0.nursery }).contains(where: { $0.id == id }) else {
      throw IdleScreenAquariumError.invalidOperation
    }
    if tanks[index].keeperMode, tanks[index].habitat != .fantasy,
      species.habitat != tanks[index].habitat
    {
      throw IdleScreenAquariumError.incompatibleHabitat
    }
    try charge(species.price)
    var animal = IdleScreenAquariumInhabitant(id: id, species: species, variant: variant, sex: sex)
    animal.purchaseValue = economy == .collection ? species.price : 0
    tanks[index].animals.append(animal)
    unlockedVariants.insert(variant)
  }

  public mutating func buyDecoration(_ kind: IdleScreenAquariumDecorationKind) throws {
    guard inventory[kind.rawValue, default: 0] < 99 else {
      throw IdleScreenAquariumError.capacityReached
    }
    try charge(kind.price)
    inventory[kind.rawValue, default: 0] += 1
  }

  public mutating func placeOwnedDecoration(_ item: IdleScreenAquariumDecoration) throws {
    let index = try selectedIndex()
    guard !tanks[index].decorations.contains(where: { $0.id == item.id }),
      inventory[item.kind.rawValue, default: 0] > 0
    else {
      throw IdleScreenAquariumError.missingItem
    }
    try tanks[index].place(item)
    inventory[item.kind.rawValue, default: 0] -= 1
  }

  public mutating func removeDecoration(id: UUID) throws {
    let index = try selectedIndex()
    guard let position = tanks[index].decorations.firstIndex(where: { $0.id == id }) else {
      throw IdleScreenAquariumError.missingItem
    }
    let kind = tanks[index].decorations[position].kind
    guard inventory[kind.rawValue, default: 0] < 99 else {
      throw IdleScreenAquariumError.capacityReached
    }
    tanks[index].decorations.remove(at: position)
    inventory[kind.rawValue, default: 0] += 1
  }

  public mutating func buyEquipment(_ kind: IdleScreenAquariumEquipment) throws {
    let index = try selectedIndex()
    guard !tanks[index].automation.equipment.contains(kind) else {
      throw IdleScreenAquariumError.invalidOperation
    }
    if tanks[index].automation.inactiveEquipment?.contains(kind) != true {
      try charge(kind.price)
    }
    tanks[index].automation.inactiveEquipment?.remove(kind)
    if tanks[index].automation.inactiveEquipment?.isEmpty == true {
      tanks[index].automation.inactiveEquipment = nil
    }
    tanks[index].automation.equipment.insert(kind)
  }

  public mutating func setEquipmentActive(_ kind: IdleScreenAquariumEquipment, active: Bool) throws
  {
    if active {
      try buyEquipment(kind)
      return
    }
    let index = try selectedIndex()
    guard tanks[index].automation.equipment.contains(kind) else {
      throw IdleScreenAquariumError.missingItem
    }
    tanks[index].automation.equipment.remove(kind)
    var inactive = tanks[index].automation.inactiveEquipment ?? []
    inactive.insert(kind)
    tanks[index].automation.inactiveEquipment = inactive
  }

  public mutating func moveToNursery(id: UUID) throws {
    let index = try selectedIndex()
    guard tanks[index].nursery.count < 64 else { throw IdleScreenAquariumError.capacityReached }
    guard let position = tanks[index].animals.firstIndex(where: { $0.id == id }),
      !tanks[index].broods.contains(where: { $0.motherID == id || $0.fatherID == id })
    else { throw IdleScreenAquariumError.invalidOperation }
    tanks[index].nursery.append(tanks[index].animals.remove(at: position))
  }

  public mutating func returnFromNursery(id: UUID) throws {
    let index = try selectedIndex()
    guard tanks[index].reservedPopulation < tanks[index].capacity,
      tanks.reduce(0, { $0 + $1.reservedPopulation }) < 128
    else { throw IdleScreenAquariumError.capacityReached }
    guard let position = tanks[index].nursery.firstIndex(where: { $0.id == id }) else {
      throw IdleScreenAquariumError.missingItem
    }
    let animal = tanks[index].nursery[position]
    if tanks[index].keeperMode, tanks[index].habitat != .fantasy,
      animal.species.habitat != tanks[index].habitat
    {
      throw IdleScreenAquariumError.incompatibleHabitat
    }
    tanks[index].animals.append(tanks[index].nursery.remove(at: position))
  }

  public mutating func rehome(id: UUID, fromNursery: Bool) throws {
    let index = try selectedIndex()
    guard !tanks[index].broods.contains(where: { $0.motherID == id || $0.fatherID == id }) else {
      throw IdleScreenAquariumError.invalidOperation
    }
    let animals = fromNursery ? tanks[index].nursery : tanks[index].animals
    guard let position = animals.firstIndex(where: { $0.id == id }) else {
      throw IdleScreenAquariumError.missingItem
    }
    let animal = animals[position]
    if fromNursery {
      tanks[index].nursery.remove(at: position)
    } else {
      tanks[index].animals.remove(at: position)
    }
    if economy == .collection {
      balance = min(1_000_000, balance + (animal.parents.isEmpty ? animal.purchaseValue / 2 : 3))
    }
  }

  public mutating func feed() throws {
    let index = try selectedIndex()
    tanks[index].water.waste = min(1, tanks[index].water.waste + 0.15)
  }

  public mutating func changeWater(fraction: Double) throws {
    guard fraction.isFinite, (0.1...0.5).contains(fraction) else {
      throw IdleScreenAquariumError.invalidOperation
    }
    let index = try selectedIndex()
    tanks[index].diluteWater(by: fraction)
  }

  /// Game-time care and growth run at minute resolution. A resume advances at
  /// most six hours and records the new checkpoint, so repeating it is inert.
  public mutating func advance(to date: Date) {
    guard date.timeIntervalSince1970.isFinite else { return }
    for index in tanks.indices {
      guard let previous = tanks[index].lastAdvancedAt else {
        tanks[index].lastAdvancedAt = date
        continue
      }
      let elapsed = date.timeIntervalSince(previous)
      guard elapsed.isFinite, elapsed >= 60 else { continue }
      let minutes = Int(min(360, elapsed / 60))
      guard tanks[index].simulationStep <= 1_000_000_000 - minutes else { continue }
      for _ in 0..<minutes {
        let globalSpace = max(0, 128 - tanks.reduce(0) { $0 + $1.reservedPopulation })
        tanks[index].advanceMinute(globalSpace: globalSpace)
      }
      tanks[index].lastAdvancedAt =
        elapsed > 360 * 60 ? date : previous.addingTimeInterval(Double(minutes) * 60)
    }
  }

  private func selectedIndex() throws -> Int {
    guard let index = tanks.firstIndex(where: { $0.id == selectedTankID }) else {
      throw IdleScreenAquariumError.missingItem
    }
    return index
  }

  private mutating func charge(_ price: Int) throws {
    if economy == .collection {
      guard balance >= price else { throw IdleScreenAquariumError.insufficientFunds }
      balance -= price
    }
  }
}

extension IdleScreenAquariumTank {
  fileprivate mutating func advanceMinute(globalSpace: Int) {
    simulationStep += 1
    for index in animals.indices {
      animals[index].ageMinutes = min(1_000_000_000, animals[index].ageMinutes + 1)
    }
    for index in nursery.indices {
      nursery[index].ageMinutes = min(1_000_000_000, nursery[index].ageMinutes + 1)
    }
    for brood in broods where brood.dueStep <= simulationStep {
      for index in 0..<brood.count {
        animals.append(
          .init(
            id: Self.childID(brood: brood.id, ordinal: index), variant: brood.variant,
            sex: index % 2 == 0 ? .female : .male, ageMinutes: 0,
            parents: [brood.motherID, brood.fatherID]))
      }
    }
    broods.removeAll { $0.dueStep <= simulationStep }
    if breedingEnabled, simulationStep.isMultiple(of: 20),
      let father = animals.first(where: {
        $0.species == .cherryShrimp && $0.sex == .male && $0.isAdult
      })
    {
      var available = min(globalSpace, capacity - reservedPopulation)
      let mothers = animals.filter {
        $0.species == .cherryShrimp && $0.sex == .female && $0.isAdult
      }
      for mother in mothers
      where available >= 2 && !broods.contains(where: { $0.motherID == mother.id }) {
        let broodID = Self.childID(brood: mother.id, ordinal: simulationStep)
        broods.append(
          .init(
            id: broodID, motherID: mother.id, fatherID: father.id,
            dueStep: simulationStep + 6, count: 2, variant: mother.variant))
        available -= 2
      }
    }
    guard keeperMode else { return }
    boundHabitatWater()
    let equipment = automation.equipment
    let load = Double(animals.count) / Double(capacity)
    if equipment.contains(.feeder), simulationStep.isMultiple(of: automation.feedEveryMinutes) {
      water.waste = min(1, water.waste + 0.06)
    }
    let decay = min(water.waste, 0.012 + load * 0.008)
    water.waste = min(1, max(0, water.waste - decay + load * 0.003))
    water.ammonia = min(1, water.ammonia + decay * 0.5)
    let filtered = equipment.contains(.spongeFilter) || equipment.contains(.externalFilter)
    if filtered {
      water.filterMaturity = min(1, water.filterMaturity + 0.002)
      let capacity =
        (equipment.contains(.externalFilter) ? 0.03 : 0.016) * water.filterMaturity
        * (0.25 + automation.flow * 1.5)
      let first = min(water.ammonia, capacity)
      water.ammonia -= first
      water.nitrite = min(1, water.nitrite + first)
      let second = min(water.nitrite, capacity * 0.9)
      water.nitrite -= second
      water.nitrate = min(1, water.nitrate + second * 0.6)
    }
    let plants = Double(decorations.filter { $0.kind.isPlant }.count)
    water.nitrate = max(0, water.nitrate - plants * 0.0008)
    let oxygenTarget =
      equipment.contains(.airStone) || filtered ? 0.95 : max(0.35, 0.85 - load * 0.4)
    water.oxygen += (oxygenTarget - water.oxygen) * 0.1
    let algaeChange = lighting.durationHours > 12 ? 0.0015 : -0.0005
    water.algae = min(1, max(0, water.algae + algaeChange + water.nitrate * 0.0004))
    if equipment.contains(.uvClarifier) { water.algae = max(0, water.algae - 0.001) }
    if equipment.contains(.heater) {
      water.temperature += (automation.heaterTemperature - water.temperature) * 0.03
    }
    if equipment.contains(.waterChanger),
      simulationStep.isMultiple(of: automation.changeEveryMinutes)
    {
      diluteWater(by: automation.waterChangeFraction)
    }
    // The dosing module has a named, bounded nitrate-management function. It
    // never replaces a filter or resets ammonia, oxygen, temperature and pH.
    if equipment.contains(.dosingController), water.nitrate > automation.nitrateSetPoint {
      water.nitrate = max(automation.nitrateSetPoint, water.nitrate - 0.005)
    }
  }

  fileprivate mutating func diluteWater(by fraction: Double) {
    water.waste *= 1 - fraction
    water.ammonia *= 1 - fraction
    water.nitrite *= 1 - fraction
    water.nitrate *= 1 - fraction
    water.oxygen = min(1, water.oxygen + fraction * 0.1)
  }

  fileprivate mutating func boundHabitatWater() {
    let temperature = habitat.temperatureRange
    water.temperature = min(temperature.upperBound, max(temperature.lowerBound, water.temperature))
    automation.heaterTemperature = min(
      temperature.upperBound, max(temperature.lowerBound, automation.heaterTemperature))
    water.ph = min(habitat.phRange.upperBound, max(habitat.phRange.lowerBound, water.ph))
    water.salinity = min(
      habitat.salinityRange.upperBound, max(habitat.salinityRange.lowerBound, water.salinity))
  }

  private static func childID(brood: UUID, ordinal: Int) -> UUID {
    var input = withUnsafeBytes(of: brood.uuid) { Data($0) }
    var value = UInt64(ordinal).bigEndian
    withUnsafeBytes(of: &value) { input.append(contentsOf: $0) }
    var bytes = Array(SHA256.hash(data: input).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
