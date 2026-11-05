import CoreGraphics
import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium object transforms")
struct AquariumObjectTransformTests {
  @Test func tiltedDrawingAndNavigationUseTheSamePixels() {
    for degrees in [-15.0, 0, 15] {
      for flipped in [false, true] {
        var settings = IdleScreenAquariumRenderSettings()
        settings.objects = [
          .init(
            kind: "cave", x: 0.5, y: 0.9, scale: 1.2,
            flipped: flipped, tiltDegrees: degrees)
        ]
        let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
        var canvas = IdleScreenAquarium.Canvas()
        canvas.object(settings.objects[0], time: 0)
        let painted = Set(canvas.pixels.indices.filter { canvas.pixels[$0].w > 0 })
        let solid = Set(
          canvas.pixels.indices.filter {
            navigation.masks(x: $0 % 384, y: $0 / 384, shelterIndex: nil)
          })
        #expect(!painted.isEmpty)
        #expect(painted == solid)
      }
    }
  }

  @Test func rotatedShelterOpeningDoesNotMakeItsBoundingBoxTransparent() throws {
    var settings = IdleScreenAquariumRenderSettings()
    settings.objects = [.init(kind: "cave", x: 0.5, y: 0.9, tiltDegrees: 15)]
    let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    let shelter = try #require(navigation.shelters.first)
    var open = 0
    var closed = 0
    for y in Int(shelter.opening.minY)..<Int(shelter.opening.maxY) {
      for x in Int(shelter.opening.minX)..<Int(shelter.opening.maxX) {
        if navigation.masks(x: x, y: y, shelterIndex: shelter.objectIndex, hiding: true) {
          closed += 1
        } else {
          open += 1
        }
      }
    }
    #expect(open > 20)
    #expect(closed > 10)
    var upright = settings
    upright.objects[0].tiltDegrees = 0
    #expect(
      IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings)
        != IdleScreenAquarium.frame(at: 0, seed: 42, settings: upright))
  }
}
