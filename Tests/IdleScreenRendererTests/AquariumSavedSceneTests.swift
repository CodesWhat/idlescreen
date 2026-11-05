import Testing

@testable import IdleScreenRenderer

@Suite("Saved aquarium scene rendering")
struct AquariumSavedSceneTests {
  @Test(arguments: [384, 768, 1152])
  func feedingFlakesAreBoundedTemporaryAndNeverReplayDaily(width: Int) {
    var settings = IdleScreenAquariumRenderSettings()
    settings.worldWidth = width
    settings.lastFeedingElapsed = 90_000
    for age in [2.0, 12, 20] {
      let time = 90_000 + age
      let fed = IdleScreenAquarium.frame(at: time, seed: 42, settings: settings)
      var unfed = settings
      unfed.lastFeedingElapsed = nil
      let baseline = IdleScreenAquarium.frame(at: time, seed: 42, settings: unfed)
      let changed = zip(fed, baseline).filter { $0 != $1 }.count
      #expect(changed > 0 && changed <= 48)
      #expect(fed == IdleScreenAquarium.frame(at: time, seed: 42, settings: settings))
    }
    let inactiveTimes: [Double] = [89_999, 90_030, 90_002 + 86_400]
    for time in inactiveTimes {
      var unfed = settings
      unfed.lastFeedingElapsed = nil
      #expect(
        IdleScreenAquarium.frame(at: time, seed: 42, settings: settings)
          == IdleScreenAquarium.frame(at: time, seed: 42, settings: unfed))
    }
    settings.reduceMotion = true
    #expect(
      IdleScreenAquarium.frame(at: 90_002, seed: 42, settings: settings)
        == IdleScreenAquarium.frame(at: 90_020, seed: 42, settings: settings))
  }

  @Test func savedSubstrateLightingAndDecorationsChangeTheFrame() {
    let base = IdleScreenAquariumRenderSettings()
    let first = IdleScreenAquarium.frame(at: 2, seed: 42, settings: base)
    var settings = base
    settings.substrate = "creamSand"
    #expect(first != IdleScreenAquarium.frame(at: 2, seed: 42, settings: settings))
    settings = base
    settings.light = "blacklight"
    #expect(first != IdleScreenAquarium.frame(at: 2, seed: 42, settings: settings))
    for kind in [
      "rock", "slate", "cave", "driftwood", "hollowLog", "moss", "grass", "fern", "purplePlant",
      "pirateChest", "skull", "shipwreck", "castle", "diver", "volcano",
    ] {
      settings = base
      settings.objects = [.init(kind: kind, x: 0.5, y: 0.9)]
      #expect(
        first != IdleScreenAquarium.frame(at: 2, seed: 42, settings: settings),
        "Missing art: \(kind)")
    }
  }

  @Test func currentChangesWaterAndPlantMotionButReducedMotionStaysStill() {
    var calm = IdleScreenAquariumRenderSettings()
    calm.flow = 0
    calm.objects = [.init(kind: "fern", x: 0.5, y: 0.9)]
    var flowing = calm
    flowing.flow = 1
    let first = IdleScreenAquarium.frame(at: 7, seed: 42, settings: calm)
    let second = IdleScreenAquarium.frame(at: 7, seed: 42, settings: flowing)
    #expect(first != second)
    #expect(second == IdleScreenAquarium.frame(at: 7, seed: 42, settings: flowing))
    flowing.reduceMotion = true
    #expect(
      IdleScreenAquarium.frame(at: 7, seed: 42, settings: flowing)
        == IdleScreenAquarium.frame(at: 70, seed: 42, settings: flowing))
  }

  @Test func savedLivestockAndVariantsAreVisibleAndDeterministic() {
    var settings = IdleScreenAquariumRenderSettings()
    let empty = IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings)
    settings.inhabitants = [.init(identity: 77, species: "cherryShrimp", variant: "blue")]
    let blue = IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings)
    #expect(empty != blue)
    #expect(blue == IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings))
    settings.inhabitants[0].variant = "yellow"
    #expect(blue != IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings))
    for species in [
      "mantisShrimp", "lionfish", "neonTetra", "corydoras", "snail", "clawedCrab", "codexFish",
    ] {
      settings.inhabitants[0].species = species
      #expect(empty != IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings))
    }
  }
}
