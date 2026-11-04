import Foundation

public struct IdleScreenAquariumRenderObject: Equatable, Sendable {
  public var kind: String
  public var x: Double
  public var y: Double
  public var scale: Double
  public var flipped: Bool
  public var foreground: Bool
  public init(
    kind: String, x: Double, y: Double, scale: Double = 1,
    flipped: Bool = false, foreground: Bool = false
  ) {
    self.kind = kind
    self.x = x
    self.y = y
    self.scale = scale
    self.flipped = flipped
    self.foreground = foreground
  }
}

public struct IdleScreenAquariumRenderInhabitant: Equatable, Sendable {
  public var identity: UInt64
  public var species: String
  public var variant: String
  public var juvenile: Bool
  public var carryingEggs: Bool
  public init(
    identity: UInt64, species: String, variant: String = "red",
    juvenile: Bool = false, carryingEggs: Bool = false
  ) {
    self.identity = identity
    self.species = species
    self.variant = variant
    self.juvenile = juvenile
    self.carryingEggs = carryingEggs
  }
}

/// Product-edge snapshot kept independent from Core's persistence schema.
public struct IdleScreenAquariumRenderSettings: Equatable, Sendable {
  public var substrate = "basalt"
  public var substrateDepth = 0.14
  public var light = "daylight"
  public var brightness = 0.9
  public var lightStartHour = 9
  public var lightDurationHours = 10
  public var objects: [IdleScreenAquariumRenderObject] = []
  public var inhabitants: [IdleScreenAquariumRenderInhabitant] = []
  public var equipment: Set<String> = []
  public var flow = 0.5
  public var cloudiness = 0.0
  public var epoch: TimeInterval?
  public var hourOffset = 0
  public var seed: UInt64 = 42
  public var reduceMotion = false
  public init() {}

  public func elapsed(at date: Date) -> TimeInterval? {
    guard let epoch, epoch.isFinite else { return nil }
    let seconds = date.timeIntervalSince1970 - epoch
    return seconds.isFinite ? max(0, seconds) : 0
  }
}
