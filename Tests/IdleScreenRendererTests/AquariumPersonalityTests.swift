import CoreGraphics
import Foundation
import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium surface navigation and personalities")
struct AquariumPersonalityTests {
  private func scene(_ kinds: [(String, Double)]) -> IdleScreenAquariumRenderSettings {
    var value = IdleScreenAquariumRenderSettings()
    value.objects = kinds.map { .init(kind: $0.0, x: $0.1, y: 0.9) }
    return value
  }

  private var cover: IdleScreenAquariumRenderSettings {
    scene([
      ("rock", 0.15), ("cave", 0.35), ("hollowLog", 0.55), ("skull", 0.72), ("driftwood", 0.88),
    ])
  }

  private func openness(_ shelter: IdleScreenAquariumNavigation.Shelter) -> Double {
    Double(shelter.opening.width * shelter.opening.height)
  }

  @Test func personalitiesAreSeededStableAndBounded() {
    let first = IdleScreenAquariumPersonality(identity: 9, seed: 42)
    #expect(first == IdleScreenAquariumPersonality(identity: 9, seed: 42))
    #expect(first != IdleScreenAquariumPersonality(identity: 10, seed: 42))
    #expect(first != IdleScreenAquariumPersonality(identity: 9, seed: 43))
    let all = (1...400).map { IdleScreenAquariumPersonality(identity: $0, seed: 7) }
    #expect(all.allSatisfy { (0.85...1.2).contains($0.speed) })
    #expect(all.allSatisfy { (0...1).contains($0.boldness) })
    #expect(all.allSatisfy { (0.1...1).contains($0.shelterAffinity) })
    #expect(all.allSatisfy { (0.2...0.9).contains($0.glassAffinity) })
    #expect(Set(all.map(\.speed)).count > 300)
    #expect(all.map(\.boldness).min()! < 0.1 && all.map(\.boldness).max()! > 0.9)
  }

  @Test func shelterChoiceIsStableForASeedAndFollowsPersonality() throws {
    let navigation = IdleScreenAquariumNavigation(settings: cover, worldWidth: 384)
    #expect(navigation.shelters.count == 3)
    var bold: [Double] = []
    var timid: [Double] = []
    var chosen = Set<Int>()
    for identity in UInt64(1)...300 {
      let personality = IdleScreenAquariumPersonality(identity: identity, seed: 42)
      let pick = navigation.shelter(for: personality, identity: identity, seed: 42)
      #expect(
        pick?.objectIndex
          == navigation.shelter(for: personality, identity: identity, seed: 42)?.objectIndex)
      guard let pick else {
        #expect(personality.shelterAffinity < IdleScreenAquariumPersonality.minimumShelterAffinity)
        continue
      }
      chosen.insert(pick.objectIndex)
      if personality.boldness > 0.85 { bold.append(openness(pick)) }
      if personality.boldness < 0.15 { timid.append(openness(pick)) }
    }
    #expect(chosen.count == 3)
    #expect(bold.count > 5 && timid.count > 5)
    #expect(bold.reduce(0, +) / Double(bold.count) > timid.reduce(0, +) / Double(timid.count) * 2)
  }

  @Test func shelterIsNeverChosenWithoutOne() {
    let navigation = IdleScreenAquariumNavigation(settings: scene([("rock", 0.3)]), worldWidth: 384)
    let personality = IdleScreenAquariumPersonality(identity: 3, seed: 1)
    #expect(navigation.shelter(for: personality, identity: 3, seed: 1) == nil)
  }

  @Test func timidAnimalsRetreatMoreOftenThanBoldOnes() {
    let people = (1...400).map { IdleScreenAquariumPersonality(identity: UInt64($0), seed: 5) }
    let timid = people.filter { $0.boldness < 0.2 && $0.shelterAffinity > 0.8 }
    let bold = people.filter { $0.boldness > 0.8 && $0.shelterAffinity < 0.5 }
    #expect(!timid.isEmpty && !bold.isEmpty)
    #expect(timid.map(\.retreatChance).min()! > bold.map(\.retreatChance).max()!)
  }

  @Test func grazingTrailsVisitSeveralSupportedStopsAndStayOnTheSurface() {
    let settings = scene([
      ("rock", 0.1), ("rock", 0.22), ("cave", 0.42), ("slate", 0.62), ("driftwood", 0.82),
    ])
    let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    #expect(navigation.grazingAnchors.count == 4)
    let boldIdentity = (1...UInt64(400)).first {
      IdleScreenAquariumPersonality(identity: $0, seed: 42).boldness > 0.9
    }!
    for identity in [boldIdentity, 4] {
      let bold = identity == boldIdentity
      let item = IdleScreenAquariumRenderInhabitant(identity: identity, species: "cherryShrimp")
      var stops = Set<Int>()
      var grazing = 0
      for tick in 0..<8_000 {
        let pose = IdleScreenAquarium.savedAnimal(
          item, at: Double(tick) / 10, seed: 42, settings: settings, navigation: navigation)
        guard pose.activity == .grazing else { continue }
        grazing += 1
        stops.insert(
          navigation.grazingAnchors.indices.min { lhs, rhs in
            abs(navigation.grazingAnchors[lhs].x - pose.x)
              < abs(navigation.grazingAnchors[rhs].x - pose.x)
          }!)
        let ground = navigation.surface(at: pose.x, radius: 8)
        #expect(abs(pose.y - 2 * pose.scale - ground) <= 3.5, "x\(pose.x) y\(pose.y)")
      }
      #expect(grazing > 500)
      #expect(stops.count >= (bold ? 2 : 1), "identity \(identity)")
    }
  }

  @Test func grazingCreepMovesAlongTheSurfaceWithoutHopping() {
    let settings = scene([("rock", 0.18), ("driftwood", 0.5), ("slate", 0.82)])
    let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    var crept = false
    for identity in UInt64(1)...12 {
      let item = IdleScreenAquariumRenderInhabitant(identity: identity, species: "corydoras")
      var previous = IdleScreenAquarium.savedAnimal(
        item, at: 0, seed: 42, settings: settings, navigation: navigation)
      for tick in 1..<4_000 {
        let pose = IdleScreenAquarium.savedAnimal(
          item, at: Double(tick) / 10, seed: 42, settings: settings, navigation: navigation)
        #expect(abs(pose.x - previous.x) < 4 && abs(pose.y - previous.y) < 5)
        if pose.activity == .grazing, previous.activity == .grazing, pose.x != previous.x {
          crept = true
        }
        previous = pose
      }
    }
    #expect(crept)
  }

  @Test func snailsMoveBetweenFloorAndGlassInsideTheTank() throws {
    let settings = scene([])
    for width in [384, 768] {
      let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: width)
      let identity = try #require(
        (1...UInt64(400)).first {
          IdleScreenAquariumPersonality(identity: $0, seed: 42).glassAffinity > 0.85
        })
      let item = IdleScreenAquariumRenderInhabitant(identity: identity, species: "snail")
      var onGlass = 0
      var onFloor = 0
      var previous = IdleScreenAquarium.savedAnimal(
        item, at: 0, seed: 42, settings: settings, worldWidth: width, navigation: navigation)
      for tick in 1..<24_000 {
        let pose = IdleScreenAquarium.savedAnimal(
          item, at: Double(tick) / 4, seed: 42, settings: settings, worldWidth: width,
          navigation: navigation)
        #expect(abs(pose.x - previous.x) < 2 && abs(pose.y - previous.y) < 2)
        let sprite = pose.species.sprite(phase: pose.animationPhase, facingRight: pose.facingRight)
        let half = Double(sprite.width) * pose.scale * pose.horizontalScale / 2
        #expect(pose.x - half >= 0 && pose.x + half <= Double(width))
        #expect(pose.y - Double(sprite.height) * pose.scale >= 0 && pose.y <= 216)
        let wall = min(pose.x, Double(width) - pose.x) < 16
        if wall, pose.y < navigation.floor - 12 { onGlass += 1 }
        if pose.y >= navigation.floor - 6 { onFloor += 1 }
        if pose.y < navigation.floor - 12 { #expect(wall, "climbing away from the glass") }
        previous = pose
      }
      #expect(onGlass > 300)
      #expect(onFloor > 300)
    }
  }

  @Test func onlySnailsLeaveTheFloorForTheGlass() {
    let settings = scene([])
    let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    for species in ["cherryShrimp", "corydoras", "clawedCrab", "mantisShrimp"] {
      let item = IdleScreenAquariumRenderInhabitant(identity: 5, species: species)
      for tick in 0..<8_000 {
        let pose = IdleScreenAquarium.savedAnimal(
          item, at: Double(tick) / 4, seed: 42, settings: settings, navigation: navigation)
        #expect(pose.y > navigation.floor - 8, "\(species)")
      }
    }
  }

  @Test func retreatsAndGlassTripsStayContinuousAndDeterministicAcrossManyTrips() {
    let settings = cover
    let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    for species in ["cherryShrimp", "mantisShrimp", "corydoras", "clawedCrab"] {
      for identity in UInt64(1)...8 {
        let item = IdleScreenAquariumRenderInhabitant(identity: identity, species: species)
        var previous = IdleScreenAquarium.savedAnimal(
          item, at: 0, seed: 42, settings: settings, navigation: navigation)
        for tick in 1..<3_200 {
          let time = Double(tick) / 10
          let pose = IdleScreenAquarium.savedAnimal(
            item, at: time, seed: 42, settings: settings, navigation: navigation)
          #expect(
            abs(pose.x - previous.x) < 4 && abs(pose.y - previous.y) < 5,
            "\(species) \(identity) \(time) \(previous) \(pose)")
          #expect(pose.x >= 16 && pose.x <= 368)
          #expect(
            pose
              == IdleScreenAquarium.savedAnimal(
                item, at: time, seed: 42, settings: settings, navigation: navigation))
          previous = pose
        }
      }
    }
  }

  @Test func poseStepStaysInsideTheSixtyFramesPerSecondBudget() {
    var settings = cover
    settings.objects += (0..<19).map {
      .init(
        kind: ["rock", "slate", "driftwood", "cave"][$0 % 4], x: 0.1 + Double($0) * 0.045, y: 0.9)
    }
    let species = ["cherryShrimp", "corydoras", "snail", "clawedCrab", "mantisShrimp"]
    settings.inhabitants = (0..<32).map {
      .init(identity: UInt64($0 + 1), species: species[$0 % species.count])
    }
    let navigation = IdleScreenAquariumNavigation(settings: settings, worldWidth: 384)
    let frames = 600
    var checksum = 0.0
    let clock = ContinuousClock()
    // Best of three passes keeps scheduler noise out of the budget check.
    var perFrame = Double.infinity
    for pass in 0..<3 {
      let elapsed = clock.measure {
        for frame in 0..<frames {
          for item in settings.inhabitants {
            checksum +=
              IdleScreenAquarium.savedAnimal(
                item, at: Double(frame + pass * frames) / 60, seed: 42, settings: settings,
                navigation: navigation
              ).x
          }
        }
      }
      let milliseconds =
        Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
      perFrame = min(perFrame, milliseconds / Double(frames))
    }
    print("aquarium pose step: \(perFrame) ms/frame for 32 animals")
    #expect(checksum > 0)
    #expect(perFrame < 0.8)
  }
}
