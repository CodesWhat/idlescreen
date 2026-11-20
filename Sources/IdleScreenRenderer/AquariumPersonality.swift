import Foundation

/// Seeded temperament for one individual. Every value derives from the
/// identity and scene seed, so a saved tank replays the same animals and two
/// animals with different identities settle into different routines.
struct IdleScreenAquariumPersonality: Equatable {
  /// Scales how quickly the animal crosses between stops (0.85...1.2).
  let speed: Double
  /// Timid animals stay near cover and retreat often; bold ones range wide (0...1).
  let boldness: Double
  /// Below `IdleScreenAquariumPersonality.minimumShelterAffinity` the animal
  /// never uses a shelter and rests in the open.
  let shelterAffinity: Double
  /// Share of grazing trips a glass-grazing species spends on the tank wall.
  let glassAffinity: Double

  static let minimumShelterAffinity = 0.18

  init(identity: UInt64, seed: UInt64) {
    speed = 0.85 + 0.35 * Self.unit(identity, seed, 1)
    boldness = Self.unit(identity, seed, 2)
    shelterAffinity = 0.1 + 0.9 * Self.unit(identity, seed, 3)
    glassAffinity = 0.2 + 0.7 * Self.unit(identity, seed, 4)
  }

  /// Chance that a grazing trip ends early with a dash back to cover.
  var retreatChance: Double { 0.08 + 0.4 * (1 - boldness) * shelterAffinity }

  /// Stateless, order-independent noise in [0, 1) (splitmix64 finalizer).
  static func unit(_ a: UInt64, _ b: UInt64, _ c: UInt64 = 0) -> Double {
    Double(mix(mix(mix(a) ^ b) ^ c) >> 11) / 9_007_199_254_740_992
  }

  private static func mix(_ value: UInt64) -> UInt64 {
    var z = value &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
