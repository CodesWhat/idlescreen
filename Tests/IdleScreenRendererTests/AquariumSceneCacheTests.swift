import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium prepared scene and sprite caches")
@MainActor
struct AquariumSceneCacheTests {
  private func pose(
    _ species: IdleScreenAquariumSpecies, phase: Int = 0, facingRight: Bool = false,
    activity: IdleScreenAquariumActivity = .walking, strike: Double = 0
  ) -> IdleScreenAquariumAnimal {
    .init(
      species: species, x: 50, y: 150, scale: 1, horizontalScale: 1, facingRight: facingRight,
      activity: activity, animationPhase: phase, strikeProgress: strike)
  }

  @Test func preparedNavigationAndBaseSurviveTimestampsAndUnrelatedEdits() {
    let cache = IdleScreenAquariumFrameCache()
    var settings = AquariumFrameFixtures.settings(width: 768)
    for time in stride(from: 0.0, to: 30, by: 3) {
      _ = cache.frame(at: time, seed: 42, settings: settings)
    }
    #expect(cache.preparation.navigationBuildCount == 1)
    #expect(cache.preparation.baseBuildCount == 1)
    settings.brightness = 0.5
    settings.light = "sunset"
    settings.lastFeedingElapsed = 5
    settings.equipment = []
    _ = cache.frame(at: 3, seed: 42, settings: settings)
    settings.inhabitants[1].variant = "blue"
    _ = cache.frame(at: 3, seed: 42, settings: settings)
    #expect(cache.preparation.navigationBuildCount == 1)
    #expect(cache.preparation.baseBuildCount == 1)
  }

  @Test func relevantEditsRebuildOnlyWhatTheyChange() {
    let cache = IdleScreenAquariumFrameCache()
    var settings = AquariumFrameFixtures.settings(width: 384)
    _ = cache.frame(at: 1, seed: 42, settings: settings)
    settings.objects[0].x += 0.05
    _ = cache.frame(at: 1, seed: 42, settings: settings)
    #expect(cache.preparation.navigationBuildCount == 2)
    #expect(cache.preparation.baseBuildCount == 1)
    settings.substrate = "riverGravel"
    _ = cache.frame(at: 1, seed: 42, settings: settings)
    #expect(cache.preparation.navigationBuildCount == 2)
    #expect(cache.preparation.baseBuildCount == 2)
    settings.substrateDepth = 0.2
    _ = cache.frame(at: 1, seed: 42, settings: settings)
    #expect(cache.preparation.navigationBuildCount == 3)
    #expect(cache.preparation.baseBuildCount == 3)
    settings.inhabitants[0].species = "neonTetra"
    _ = cache.frame(at: 1, seed: 42, settings: settings)
    #expect(cache.preparation.navigationBuildCount == 4)
    #expect(cache.preparation.baseBuildCount == 3)
    settings.worldWidth = 768
    _ = cache.frame(at: 1, seed: 42, settings: settings)
    #expect(cache.preparation.navigationBuildCount == 5)
    #expect(cache.preparation.baseBuildCount == 4)
    settings.seed = 77
    _ = cache.frame(at: 1, seed: 77, settings: settings)
    #expect(cache.preparation.navigationBuildCount == 6)
    #expect(cache.preparation.baseBuildCount == 5)
  }

  @Test func preparedFramesMatchFreshRendersAcrossSceneEdits() {
    let cache = IdleScreenAquariumFrameCache()
    var settings = AquariumFrameFixtures.settings(width: 384)
    for time in [3.0, 40, 71] {
      #expect(
        cache.frame(at: time, seed: 42, settings: settings)
          == IdleScreenAquarium.frame(at: time, seed: 42, settings: settings))
    }
    settings.objects.removeLast()
    settings.substrate = "plantedSoil"
    settings.substrateDepth = 0.21
    #expect(
      cache.frame(at: 71, seed: 42, settings: settings)
        == IdleScreenAquarium.frame(at: 71, seed: 42, settings: settings))
  }

  @Test func animalSpritesAreSharedByTheirRenderedInputs() {
    let sprites = IdleScreenAquariumSpriteCache()
    let first = sprites.sprite(for: pose(.neonTetra, phase: 1), variant: "red", eggs: false)
    let again = sprites.sprite(for: pose(.neonTetra, phase: 5), variant: "blue", eggs: true)
    #expect(first.pixels == again.pixels)
    #expect(sprites.generatedCount == 1)
    _ = sprites.sprite(for: pose(.neonTetra, phase: 2), variant: "red", eggs: false)
    _ = sprites.sprite(for: pose(.neonTetra, phase: 1, facingRight: true), variant: "", eggs: false)
    #expect(sprites.generatedCount == 3)
  }

  @Test func mantisReachCollapsesToFiveRenderedValues() {
    let sprites = IdleScreenAquariumSpriteCache()
    for step in 0...100 {
      let strike = Double(step) / 100
      let cached = sprites.sprite(
        for: pose(.mantisShrimp, activity: .striking, strike: strike), variant: "", eggs: false)
      let fresh = IdleScreenAquariumSpecies.mantisShrimp.sprite(
        phase: 0, facingRight: false, activity: .striking, strikeProgress: strike)
      #expect(cached.pixels == fresh.pixels)
    }
    #expect(sprites.generatedCount == 5)
    _ = sprites.sprite(
      for: pose(.mantisShrimp, activity: .resting, strike: 0.9), variant: "", eggs: false)
    _ = sprites.sprite(
      for: pose(.mantisShrimp, activity: .striking, strike: .nan), variant: "", eggs: false)
    #expect(sprites.generatedCount == 6)
  }

  @Test func shrimpVariantAndEggStateKeyTheColoredSprite() {
    let sprites = IdleScreenAquariumSpriteCache()
    let shrimp = pose(.cherryShrimp, phase: 2, facingRight: true, activity: .grazing)
    for variant in ["red", "orange", "yellow", "blue", "dark", "rili", "mystery"] {
      for eggs in [false, true] {
        let cached = sprites.sprite(for: shrimp, variant: variant, eggs: eggs)
        let fresh = IdleScreenAquarium.coloredShrimp(
          IdleScreenAquariumSpecies.cherryShrimp.sprite(
            phase: 2, facingRight: true, activity: .grazing, strikeProgress: 0),
          variant: variant, eggs: eggs)
        #expect(cached.pixels == fresh.pixels, "\(variant) eggs=\(eggs)")
      }
    }
    // "mystery" renders as red, so only six variants times two egg states.
    #expect(sprites.generatedCount == 12)
  }

  @Test func ornamentsCacheStaticArtButKeepChestAndPlantMotion() {
    let still = IdleScreenAquarium.objectSprite(kind: "castle", time: 0)
    #expect(still.pixels == IdleScreenAquarium.objectSprite(kind: "castle", time: 500).pixels)
    #expect(still.pixels == IdleScreenAquarium.buildObjectSprite(kind: "castle", time: 500).pixels)
    #expect(
      IdleScreenAquarium.objectSprite(kind: "mystery", time: 3).pixels
        == IdleScreenAquarium.buildObjectSprite(kind: "mystery", time: 3).pixels)
    let closed = IdleScreenAquarium.objectSprite(kind: "pirateChest", time: 1)
    let open = IdleScreenAquarium.objectSprite(kind: "pirateChest", time: 7)
    #expect(closed.pixels != open.pixels)
    #expect(closed.pixels == IdleScreenAquarium.objectSprite(kind: "pirateChest", time: 13).pixels)
    #expect(open.pixels == IdleScreenAquarium.objectSprite(kind: "pirateChest", time: 19).pixels)
    for kind in ["moss", "grass", "fern", "purplePlant"] {
      for time in [0.0, 9.5, 31.2] {
        #expect(
          IdleScreenAquarium.objectSprite(kind: kind, time: time, flow: 0.9).pixels
            == IdleScreenAquarium.buildObjectSprite(kind: kind, time: time, flow: 0.9).pixels)
      }
    }
  }

  @Test func tallPlantsKeepSwaying() {
    for kind in ["fern", "purplePlant"] {
      let frames = [0.0, 25, 50, 75].map {
        IdleScreenAquarium.objectSprite(kind: kind, time: $0, flow: 0.9).pixels
      }
      #expect(frames.contains { $0 != frames[0] }, "\(kind) never swayed")
    }
  }
}
