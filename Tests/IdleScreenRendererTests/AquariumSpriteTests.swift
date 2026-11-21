import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium sprite silhouettes")
struct AquariumSpriteTests {
  @Test func everyAppendageStaysAttachedThroughoutAnimation() {
    for species in IdleScreenAquariumSpecies.allCases {
      for pose in 0..<24 {
        let activity: IdleScreenAquariumActivity =
          pose < 4
          ? .walking : pose < 8 ? .grazing : pose < 12 ? .resting : pose < 20 ? .striking : .hiding
        let sprite = species.sprite(
          phase: pose % 4, facingRight: false, activity: activity,
          strikeProgress: Double(pose % 5) / 4)
        let occupied = sprite.pixels.indices.filter { sprite.pixels[$0].w > 0 }
        #expect(!occupied.isEmpty)
        guard let first = occupied.first else { continue }
        var reached: Set<Int> = [first]
        var pending = [first]
        while let pixel = pending.popLast() {
          let x = pixel % sprite.width
          let y = pixel / sprite.width
          for dy in -1...1 {
            for dx in -1...1 {
              let nx = x + dx
              let ny = y + dy
              guard nx >= 0, nx < sprite.width, ny >= 0, ny < sprite.height else { continue }
              let neighbor = ny * sprite.width + nx
              if sprite.pixels[neighbor].w > 0, reached.insert(neighbor).inserted {
                pending.append(neighbor)
              }
            }
          }
        }
        #expect(reached.count == occupied.count, "Detached pixels in \(species), pose \(pose)")
      }
    }
  }

  @Test func turningMirrorsTheEntireAnimalIncludingLegs() {
    for species in IdleScreenAquariumSpecies.allCases {
      for phase in 0..<4 {
        let left = species.sprite(phase: phase, facingRight: false)
        let right = species.sprite(phase: phase, facingRight: true)
        for y in 0..<left.height {
          for x in 0..<left.width {
            #expect(
              left.pixels[y * left.width + x] == right.pixels[y * left.width + left.width - 1 - x])
          }
        }
      }
    }
  }

  @Test func crabClawsAndCodexFishReadAsDifferentSpecies() {
    let crab = IdleScreenAquariumSpecies.clawedCrab.sprite(phase: 0, facingRight: false)
    let fish = IdleScreenAquariumSpecies.codexFish.sprite(phase: 0, facingRight: false)
    #expect(crab.width >= 40)
    #expect(crab.height >= 28)
    #expect(
      crab.pixels.indices.contains {
        $0 % crab.width < 10 && $0 / crab.width < 12 && crab.pixels[$0].w > 0
      })
    #expect(
      crab.pixels.indices.contains {
        $0 % crab.width > crab.width - 10 && $0 / crab.width < 12 && crab.pixels[$0].w > 0
      })
    #expect(fish.pixels.contains { $0.x > 0.7 && $0.y > 0.7 && $0.z > 0.7 && $0.w > 0 })
    #expect(fish.pixels.contains { $0.z > $0.x * 1.5 && $0.z > 0.5 && $0.w > 0 })
    #expect(crab.pixels != fish.pixels)
  }

  @Test func crabArmJointsHaveReadableWidth() {
    let crab = IdleScreenAquariumSpecies.clawedCrab.sprite(phase: 0, facingRight: false)
    let joint = crab.pixels.indices.filter {
      (7..<12).contains($0 % crab.width) && (13..<18).contains($0 / crab.width)
        && crab.pixels[$0].w > 0
    }
    #expect(joint.count >= 16)
  }

  @Test func scaleAndAnimationDistinguishSpecies() {
    let shrimp = IdleScreenAquariumSpecies.cherryShrimp.sprite(phase: 0, facingRight: false)
    let mantis = IdleScreenAquariumSpecies.mantisShrimp.sprite(phase: 0, facingRight: false)
    let fish = IdleScreenAquariumSpecies.lionfish.sprite(phase: 0, facingRight: false)
    #expect(mantis.width >= shrimp.width * 17 / 10)
    #expect(fish.height >= shrimp.height * 2)
    for species in IdleScreenAquariumSpecies.allCases {
      #expect(
        species.sprite(phase: 0, facingRight: false).pixels
          != species.sprite(phase: 1, facingRight: false).pixels)
    }
  }
}
