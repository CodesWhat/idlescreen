import Foundation

@testable import IdleScreenRenderer

/// Shared scene fixtures for the pixel-equivalence goldens and the full-frame
/// benchmark. Both use the same mixed scene so a perf change is judged on the
/// pixels it must preserve.
enum AquariumFrameFixtures {
  static let widths = [384, 768, 1152]

  static let decorationKinds = [
    "rock", "slate", "cave", "driftwood", "hollowLog", "moss", "grass", "fern",
    "purplePlant", "pirateChest", "castle", "shipwreck",
  ]

  /// 12 valid decorations, some foreground, flipped, scaled or tilted.
  static func decorations() -> [IdleScreenAquariumRenderObject] {
    decorationKinds.enumerated().map { index, kind in
      .init(
        kind: kind, x: 0.08 + Double(index) * 0.075, y: 0.80 + Double(index % 3) * 0.06,
        scale: 0.8 + Double(index % 4) * 0.15, flipped: index % 3 == 1,
        foreground: index % 4 == 3, tiltDegrees: index % 5 == 2 ? 12 : 0)
    }
  }

  /// 32 animals across every saved species, shrimp variants and egg states.
  static func animals() -> [IdleScreenAquariumRenderInhabitant] {
    let species = [
      "cherryShrimp", "neonTetra", "corydoras", "snail", "clawedCrab", "neonTetra",
      "cherryShrimp", "mantisShrimp", "lionfish", "codexFish",
    ]
    let variants = ["red", "orange", "yellow", "blue", "dark", "rili"]
    return (0..<32).map { index in
      .init(
        identity: UInt64(index * 7 + 3), species: species[index % species.count],
        variant: variants[index % variants.count], juvenile: index % 6 == 5,
        carryingEggs: index % 4 == 0)
    }
  }

  static func settings(
    width: Int, light: String = "daylight", reduceMotion: Bool = false,
    equipment: Set<String> = ["airStone", "heater", "feeder"], substrate: String = "creamSand",
    fed: Bool = true
  ) -> IdleScreenAquariumRenderSettings {
    var settings = IdleScreenAquariumRenderSettings()
    settings.worldWidth = width
    settings.substrate = substrate
    settings.substrateDepth = 0.16
    settings.light = light
    settings.brightness = 0.85
    settings.cloudiness = 0.1
    settings.objects = decorations()
    settings.inhabitants = animals()
    settings.equipment = equipment
    settings.flow = 0.7
    settings.epoch = 1_700_000_000
    settings.lastFeedingElapsed = fed ? 20 : nil
    settings.hourOffset = 3
    settings.seed = 42
    settings.reduceMotion = reduceMotion
    return settings
  }

  /// 64-bit FNV-1a over the exact float bit patterns of every channel.
  static func hash(_ pixels: [SIMD4<Float>]) -> UInt64 {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for pixel in pixels {
      for lane in 0..<4 {
        value = (value ^ UInt64(pixel[lane].bitPattern)) &* 0x0000_0100_0000_01b3
      }
    }
    return value
  }
}
