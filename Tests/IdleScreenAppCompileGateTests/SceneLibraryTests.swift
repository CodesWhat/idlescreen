import Foundation
import IdleScreenCore
import Testing

@Suite("Camera-first scene library")
struct SceneLibraryTests {
  @Test("Camera leads distinct Aquarium and Pixel Materials entries")
  func primaryFamilies() {
    #expect(
      IdleScreenSceneLibrary.families == [
        .camera, .pattern(.aquarium), .pattern(.pixelMaterials),
      ])
    #expect(
      IdleScreenSceneLibrary.families.map(\.title) == ["Camera", "Aquarium", "Pixel Materials"])
  }

  @Test("the curated glyph collection retains its existing patterns")
  func featuredGlyphs() {
    #expect(
      IdleScreenSceneLibrary.featuredGlyphs == [
        .pattern(.topograph), .pattern(.perlin), .pattern(.matrixRain),
      ])
    #expect(
      IdleScreenSceneLibrary.featuredGlyphs.map(\.title) == ["Topograph", "Perlin Noise", "Rain"])
  }

  @Test("all existing scenes remain discoverable exactly once with stable identities")
  func completeLibrary() {
    let entries =
      IdleScreenSceneLibrary.families + IdleScreenSceneLibrary.featuredGlyphs
      + IdleScreenSceneLibrary.moreGlyphs
    let expected = ["camera"] + IdleScreenCreativePattern.allCases.map(\.rawValue)
    #expect(Set(entries.map(\.id)) == Set(expected))
    #expect(entries.count == expected.count)
    #expect(Set(entries.map(\.id)).count == entries.count)
    #expect(IdleScreenSceneLibrary.moreGlyphs.contains(.pattern(.autoCycle)))
    #expect(!IdleScreenSceneLibrary.moreGlyphs.contains(.pattern(.aquarium)))
    #expect(!IdleScreenSceneLibrary.moreGlyphs.contains(.pattern(.pixelMaterials)))
  }

  @Test(
    "a persisted procedural selection maps to its original library entry",
    arguments: IdleScreenCreativePattern.allCases)
  func selectedPattern(_ pattern: IdleScreenCreativePattern) throws {
    let encoded = try JSONEncoder().encode(pattern)
    let restored = try JSONDecoder().decode(IdleScreenCreativePattern.self, from: encoded)
    let selection = IdleScreenSceneLibrary.selection(source: .generative, pattern: restored)
    #expect(selection == .pattern(pattern))
    #expect(selection.id == pattern.rawValue)
    let featured = IdleScreenSceneLibrary.families + IdleScreenSceneLibrary.featuredGlyphs
    #expect(featured.contains(selection) || IdleScreenSceneLibrary.moreGlyphs.contains(selection))
  }

  @Test(
    "camera selection takes precedence over every remembered procedural pattern",
    arguments: IdleScreenCreativePattern.allCases)
  func cameraSelection(_ pattern: IdleScreenCreativePattern) {
    #expect(IdleScreenSceneLibrary.selection(source: .camera, pattern: pattern) == .camera)
  }

  @Test("existing raw IDs and the default source remain unchanged")
  func persistenceCompatibility() throws {
    let expectedIDs = [
      "autoCycle", "topograph", "perlin", "plasma", "sweep", "matrixRain", "rainbowCycle",
      "fireEffect", "ripple", "voronoi", "warp", "staticNoise", "pulse", "dvdBounce",
      "metaballs", "starfield", "spiral", "terrain", "rainOnGlass", "aurora",
      "pixelMaterials", "aquarium",
    ]
    #expect(IdleScreenCreativePattern.allCases.map(\.rawValue) == expectedIDs)
    for rawID in expectedIDs {
      let pattern = try JSONDecoder().decode(
        IdleScreenCreativePattern.self, from: JSONEncoder().encode(rawID))
      #expect(IdleScreenSceneLibraryEntry.pattern(pattern).id == rawID)
    }
    #expect(IdleScreenConfiguration.default.source == .generative)
    #expect(IdleScreenConfiguration.default.creative.pattern == .topograph)
  }

  @Test("the More collection can reveal every saved secondary selection")
  func secondarySelection() {
    for entry in IdleScreenSceneLibrary.moreGlyphs {
      guard case .pattern(let pattern) = entry else {
        Issue.record("Only existing procedural patterns belong in More glyph scenes")
        continue
      }
      let selection = IdleScreenSceneLibrary.selection(source: .generative, pattern: pattern)
      #expect(IdleScreenSceneLibrary.moreGlyphs.contains(selection))
      #expect(!IdleScreenSceneLibrary.moreGlyphs.contains(.camera))
    }
  }
}
