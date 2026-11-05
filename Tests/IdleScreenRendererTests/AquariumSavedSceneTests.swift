import Testing

@testable import IdleScreenRenderer

@Suite("Saved aquarium scene rendering")
struct AquariumSavedSceneTests {
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

  @Test func savedLivestockAndVariantsAreVisibleAndDeterministic() {
    var settings = IdleScreenAquariumRenderSettings()
    let empty = IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings)
    settings.inhabitants = [.init(identity: 77, species: "cherryShrimp", variant: "blue")]
    let blue = IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings)
    #expect(empty != blue)
    #expect(blue == IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings))
    settings.inhabitants[0].variant = "yellow"
    #expect(blue != IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings))
    for species in ["mantisShrimp", "lionfish", "neonTetra", "corydoras", "snail"] {
      settings.inhabitants[0].species = species
      #expect(empty != IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings))
    }
  }
}
