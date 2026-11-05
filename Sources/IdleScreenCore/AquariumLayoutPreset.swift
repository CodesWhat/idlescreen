import Foundation

public struct IdleScreenAquariumLayout: Codable, Equatable, Sendable {
  public var seed: UInt64
  public var worldSize: IdleScreenAquariumWorldSize?
  public var substrate: IdleScreenAquariumSubstrate
  public var substrateDepth: Double
  public var lighting: IdleScreenAquariumLighting
  public var decorations: [IdleScreenAquariumDecoration]

  public init(tank: IdleScreenAquariumTank) {
    seed = tank.seed
    worldSize = tank.worldSize
    substrate = tank.substrate
    substrateDepth = tank.substrateDepth
    lighting = tank.lighting
    decorations = tank.decorations
  }

  fileprivate func apply(to tank: inout IdleScreenAquariumTank) {
    tank.seed = seed
    tank.worldSize = worldSize
    tank.substrate = substrate
    tank.substrateDepth = substrateDepth
    tank.lighting = lighting
    tank.decorations = decorations
  }

  public func validate() throws {
    var tank = IdleScreenAquariumTank()
    apply(to: &tank)
    try tank.validate()
  }
}

public struct IdleScreenAquariumLayoutPreset: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var layout: IdleScreenAquariumLayout

  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64 else {
      throw IdleScreenAquariumError.invalidTank
    }
    try layout.validate()
  }
}

extension IdleScreenAquariumLibrary {
  public mutating func saveLayoutPreset(id: UUID, name: String) throws {
    var presets = layoutPresets ?? []
    guard presets.count < 16 else { throw IdleScreenAquariumError.capacityReached }
    guard !presets.contains(where: { $0.id == id }), let tank = selectedTank else {
      throw IdleScreenAquariumError.invalidOperation
    }
    let preset = IdleScreenAquariumLayoutPreset(
      id: id,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines), layout: .init(tank: tank))
    try preset.validate()
    presets.append(preset)
    layoutPresets = presets
  }

  public mutating func deleteLayoutPreset(id: UUID) throws {
    guard var presets = layoutPresets, let index = presets.firstIndex(where: { $0.id == id }) else {
      throw IdleScreenAquariumError.missingItem
    }
    presets.remove(at: index)
    layoutPresets = presets.isEmpty ? nil : presets
  }

  public func costToApplyLayout(_ layout: IdleScreenAquariumLayout) throws -> Int {
    try replacement(layout).cost
  }

  public mutating func applyLayoutPreset(id: UUID) throws {
    guard let preset = layoutPresets?.first(where: { $0.id == id }) else {
      throw IdleScreenAquariumError.missingItem
    }
    try applyLayout(preset.layout)
  }

  public mutating func resetLayout() throws {
    try applyLayout(.init(tank: Self.starter.tanks[0]))
  }

  private mutating func applyLayout(_ layout: IdleScreenAquariumLayout) throws {
    let quote = try replacement(layout)
    guard balance >= quote.cost else { throw IdleScreenAquariumError.insufficientFunds }
    guard let index = tanks.firstIndex(where: { $0.id == selectedTankID }) else {
      throw IdleScreenAquariumError.missingItem
    }
    var proposed = tanks[index]
    layout.apply(to: &proposed)
    proposed.decorations = proposed.decorations.map {
      var copy = $0
      copy.id = UUID()
      return copy
    }
    try proposed.validate()
    tanks[index] = proposed
    inventory = quote.inventory
    balance -= quote.cost
  }

  private func replacement(_ layout: IdleScreenAquariumLayout) throws
    -> (inventory: [String: Int], cost: Int)
  {
    try layout.validate()
    guard let tank = selectedTank,
      inventory.values.allSatisfy({ (0...99).contains($0) })
    else { throw IdleScreenAquariumError.invalidTank }
    var supplies = inventory
    for item in tank.decorations { supplies[item.kind.rawValue, default: 0] += 1 }
    var cost = 0
    for item in layout.decorations {
      if supplies[item.kind.rawValue, default: 0] > 0 {
        supplies[item.kind.rawValue, default: 0] -= 1
      } else if economy == .collection {
        cost += item.kind.price
      }
    }
    guard supplies.values.allSatisfy({ (0...99).contains($0) }) else {
      throw IdleScreenAquariumError.capacityReached
    }
    return (supplies, cost)
  }
}
