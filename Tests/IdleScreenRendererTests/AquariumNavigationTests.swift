import Foundation
import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium hardscape navigation")
struct AquariumNavigationTests {
  private var settings: IdleScreenAquariumRenderSettings {
    var value = IdleScreenAquariumRenderSettings()
    value.objects = [
      .init(kind: "rock", x: 0.25, y: 0.9),
      .init(kind: "hollowLog", x: 0.72, y: 0.9),
      .init(kind: "fern", x: 0.5, y: 0.9),
    ]
    return value
  }

  @Test func neonsTravelAsABoundedSchoolWithStableSlotsAndCoordinatedTurns() {
    var settings = settings
    settings.inhabitants = (1...32).map { .init(identity: UInt64($0), species: "neonTetra") }
    for width in [384, 768, 1152] {
      let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: width)
      var reversed = settings
      reversed.inhabitants.reverse()
      let reordered = IdleScreenAquariumNavigation(settings: reversed, worldWidth: width)
      for time in stride(from: 0.0, through: 300, by: 5) {
        let poses = settings.inhabitants.map {
          IdleScreenAquarium.savedAnimal(
            $0, at: time, seed: 42, settings: settings, worldWidth: width, navigation: geometry)
        }
        #expect(
          poses.allSatisfy { $0.activity == .swimming && $0.facingRight == poses[0].facingRight })
        #expect((poses.map(\.x).max()! - poses.map(\.x).min()!) <= 130)
        #expect((poses.map(\.y).max()! - poses.map(\.y).min()!) <= 45)
        #expect(Set(poses.map { "\(Int($0.x)),\(Int($0.y))" }).count == 32)
        for (item, pose) in zip(settings.inhabitants, poses) {
          #expect(pose.x >= 10 && pose.x <= Double(width - 10))
          #expect((65...145).contains(pose.y))
          let next = IdleScreenAquarium.savedAnimal(
            item, at: time + 0.1, seed: 42, settings: settings, worldWidth: width,
            navigation: geometry)
          #expect(abs(next.x - pose.x) < 2 && abs(next.y - pose.y) < 2)
          #expect(
            pose
              == IdleScreenAquarium.savedAnimal(
                item, at: time, seed: 42, settings: reversed, worldWidth: width,
                navigation: reordered))
        }
      }
    }
  }

  @Test func hardscapeProvidesPhysicalSurfacesAndUsableShelterOpenings() throws {
    let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    #expect(geometry.grazingAnchors.contains { abs($0.x - 96) < 2 })
    let shelter = try #require(geometry.shelters.first)
    #expect(shelter.opening.width > 0)
    #expect(shelter.opening.height > 0)
    #expect(geometry.surface(at: 96, radius: 0) < geometry.floor)
    #expect(abs(geometry.surface(at: 192, radius: 0) - geometry.floor) <= 4)
    #expect(abs(geometry.surface(at: 10, radius: 0) - geometry.floor) <= 4)
  }

  @Test func shelterMasksKeepWallsOpaqueAndRespectFlippedOpenings() throws {
    let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    let shelter = try #require(geometry.shelters.first)
    let x = Int(shelter.opening.midX)
    let y = Int(shelter.opening.midY)
    #expect(geometry.masks(x: x, y: y, shelterIndex: nil))
    #expect(!geometry.masks(x: x, y: y, shelterIndex: shelter.objectIndex))
    #expect(
      geometry.masks(x: Int(shelter.opening.minX) - 2, y: y, shelterIndex: shelter.objectIndex))
    var flipped = settings
    flipped.objects[1].flipped = true
    let mirrored = IdleScreenAquariumNavigation(settings: flipped, worldWidth: 384)
    let opening = try #require(mirrored.shelters.first?.opening)
    #expect(opening.midX > shelter.opening.midX)
    #expect(opening.size == shelter.opening.size)
  }

  @Test func shrimpVisitGrazingAndShelterWithRealPausesAndContinuousRoutes() {
    let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    let item = IdleScreenAquariumRenderInhabitant(identity: 4, species: "cherryShrimp")
    var previous = IdleScreenAquarium.savedAnimal(
      item, at: 0, seed: 42, settings: settings, navigation: geometry)
    var grazes = 0
    var hides = 0
    var pauses = 0
    for tick in 1...1_600 {
      let pose = IdleScreenAquarium.savedAnimal(
        item, at: Double(tick) / 10, seed: 42, settings: settings, navigation: geometry)
      #expect(abs(pose.x - previous.x) < 4)
      #expect(abs(pose.y - previous.y) < 5)
      #expect(pose.x >= 16 && pose.x <= 368)
      if pose.activity == .grazing { grazes += 1 }
      if pose.activity == .hiding { hides += 1 }
      if pose.activity == previous.activity,
        pose.activity == .grazing || pose.activity == .hiding,
        pose.x == previous.x, pose.y == previous.y
      {
        pauses += 1
      }
      previous = pose
    }
    #expect(grazes > 100)
    #expect(hides > 100)
    #expect(pauses > 100)
  }

  @Test func hidingPoseTurnsTowardTheOpeningBeforeItRests() throws {
    let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    let item = IdleScreenAquariumRenderInhabitant(identity: 4, species: "cherryShrimp")
    let pose = IdleScreenAquarium.savedAnimal(
      item, at: 62.18, seed: 42, settings: settings, navigation: geometry)
    let opening = try #require(geometry.shelters.first?.opening)
    #expect(pose.activity == .hiding)
    #expect(!pose.facingRight)
    #expect(pose.x > opening.midX)
  }

  @Test func aRestingHiddenShrimpOnlyShowsThroughItsShelterOpening() throws {
    var settings = settings
    let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    let opening = try #require(geometry.shelters.first?.opening)
    let empty = IdleScreenAquarium.frame(at: 62.18, seed: 42, settings: settings)
    settings.inhabitants = [.init(identity: 4, species: "cherryShrimp")]
    let occupied = IdleScreenAquarium.frame(at: 62.18, seed: 42, settings: settings)
    let changed = empty.indices.filter { empty[$0] != occupied[$0] }
    #expect(!changed.isEmpty)
    #expect(changed.allSatisfy { opening.contains(CGPoint(x: $0 % 384, y: $0 / 384)) })
  }

  @Test func crabScuttlesInTheFrontFloorLaneInsteadOfFloatingOverBranches() {
    var settings = settings
    settings.objects.append(.init(kind: "driftwood", x: 0.5, y: 0.9))
    let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    let crab = IdleScreenAquariumRenderInhabitant(identity: 77, species: "clawedCrab")
    for time in stride(from: 0.0, through: 160, by: 0.5) {
      let pose = IdleScreenAquarium.savedAnimal(
        crab, at: time, seed: 42, settings: settings, navigation: geometry)
      #expect(pose.y >= geometry.floor - 2)
      #expect(pose.activity != .swimming)
      #expect(pose.shelterIndex == nil)
    }
  }

  @Test func largeGroundAnimalsKeepTheirWholeBodyInsideTheWorldAtEdgeObjects() {
    var settings = settings
    settings.objects = [.init(kind: "rock", x: 0.045, y: 0.9)]
    let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    for species in ["mantisShrimp", "clawedCrab", "snail"] {
      let item = IdleScreenAquariumRenderInhabitant(identity: 77, species: species)
      for time in stride(from: 0.0, through: 400, by: 1) {
        let pose = IdleScreenAquarium.savedAnimal(
          item, at: time, seed: 42, settings: settings, navigation: geometry)
        let sprite = pose.species.sprite(phase: pose.animationPhase, facingRight: pose.facingRight)
        let half = Double(sprite.width) * pose.scale * pose.horizontalScale / 2
        #expect(pose.x - half >= 0)
        #expect(pose.x + half <= 384)
      }
    }
  }

  @Test func wideWorldRoutesRemainBoundedAndClockSamplesRepeat() {
    var settings = settings
    settings.worldWidth = 768
    let geometry = IdleScreenAquariumNavigation(settings: settings, worldWidth: 768)
    for species in ["cherryShrimp", "mantisShrimp", "corydoras", "snail", "clawedCrab"] {
      let item = IdleScreenAquariumRenderInhabitant(identity: 77, species: species)
      for time in stride(from: 0.0, through: 400, by: 2) {
        let first = IdleScreenAquarium.savedAnimal(
          item, at: time, seed: 42, settings: settings, worldWidth: 768, navigation: geometry)
        #expect(first.x >= 24 && first.x <= 744)
        #expect(first.y >= 24 && first.y <= 216)
        #expect(
          first
            == IdleScreenAquarium.savedAnimal(
              item, at: time, seed: 42, settings: settings, worldWidth: 768, navigation: geometry))
      }
    }
  }
}
