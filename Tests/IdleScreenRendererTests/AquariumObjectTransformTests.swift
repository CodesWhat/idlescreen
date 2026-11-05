import CoreGraphics
import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium object transforms")
struct AquariumObjectTransformTests {
  @Test func everySolidDecorationUsesThePaintedMaskAtBothScaleLimits() {
    let kinds = [
      "rock", "slate", "cave", "driftwood", "hollowLog", "moss", "pirateChest", "skull",
      "shipwreck", "castle", "diver", "volcano",
    ]
    for kind in kinds {
      for scale in [0.5, 1.5] {
        for degrees in [-15.0, 0, 15] {
          for flipped in [false, true] {
            var settings = IdleScreenAquariumRenderSettings()
            settings.objects = [
              .init(
                kind: kind, x: 0.5, y: 0.9, scale: scale, flipped: flipped, tiltDegrees: degrees)
            ]
            let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
            var canvas = IdleScreenAquarium.Canvas()
            canvas.object(settings.objects[0], time: 0)
            let painted = Set(canvas.pixels.indices.filter { canvas.pixels[$0].w > 0 })
            let solid = Set(
              canvas.pixels.indices.filter {
                navigation.masks(x: $0 % 384, y: $0 / 384, shelterIndex: nil)
              })
            #expect(
              !painted.isEmpty && painted == solid,
              "\(kind) scale\(scale), tilt\(degrees), flipped\(flipped)")
          }
        }
      }
    }
  }

  @Test func overlappingForegroundAndBackgroundObjectsKeepTheirCombinedOpaqueMask() {
    let kinds = [
      "rock", "slate", "cave", "driftwood", "hollowLog", "moss", "pirateChest", "skull",
      "shipwreck", "castle", "diver", "volcano",
    ]
    for width in [384, 768, 1152] {
      var settings = IdleScreenAquariumRenderSettings()
      settings.objects = []
      for index in 0..<24 {
        let x = 0.18 + Double(index % 8) * 0.09
        let y = 0.88 + Double(index / 8) * 0.025
        let item = IdleScreenAquariumRenderObject(
          kind: kinds[index % kinds.count], x: x,
          y: y, scale: 1.5, flipped: index % 2 == 0, foreground: index % 3 == 0,
          tiltDegrees: index % 2 == 0 ? 15 : -15)
        settings.objects.append(item)
      }
      let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: width)
      var canvas = IdleScreenAquarium.Canvas(width: width)
      for foreground in [false, true] {
        for item in settings.objects where item.foreground == foreground {
          canvas.object(item, time: 0)
        }
      }
      #expect(
        canvas.pixels.indices.allSatisfy {
          (canvas.pixels[$0].w > 0)
            == navigation.masks(x: $0 % width, y: $0 / width, shelterIndex: nil)
        })
    }
  }

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
