import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium animal behavior")
struct AquariumBehaviorTests {
  @Test func behaviorIsDeterministicAndClocksFailSafely() {
    let first = IdleScreenAquariumBehavior.animals(at: 16, seed: 42)
    #expect(first == IdleScreenAquariumBehavior.animals(at: 16, seed: 42))
    #expect(first != IdleScreenAquariumBehavior.animals(at: 16, seed: 43))
    #expect(
      IdleScreenAquariumBehavior.animals(at: .nan, seed: 42)
        == IdleScreenAquariumBehavior.animals(at: 0, seed: 42))
    #expect(
      IdleScreenAquariumBehavior.animals(at: -5, seed: 42)
        == IdleScreenAquariumBehavior.animals(at: 0, seed: 42))
    #expect(IdleScreenAquariumBehavior.animals(at: .greatestFiniteMagnitude, seed: 42).count == 10)
  }

  @Test func speciesHaveDistinctActivitiesAndRealPauses() {
    let samples = (0..<400).map { IdleScreenAquariumBehavior.animals(at: Double($0) / 2, seed: 0) }
    let cherry = samples.map { $0[0] }
    #expect(cherry.contains { $0.activity == .walking })
    #expect(cherry.contains { $0.activity == .grazing })
    #expect(samples.contains { $0[8].activity == .striking })
    #expect(samples.allSatisfy { $0[9].activity == .hovering || $0[9].activity == .turning })
    for pair in zip(cherry, cherry.dropFirst())
    where pair.0.activity == .grazing && pair.1.activity == .grazing {
      #expect(pair.0.x == pair.1.x)
      #expect(pair.0.y == pair.1.y)
    }
  }

  @Test func motionAndTurnsStayContinuousAndInsideTheTank() {
    var previous = IdleScreenAquariumBehavior.animals(at: 0, seed: 77)
    for tick in 1...4_000 {
      let current = IdleScreenAquariumBehavior.animals(at: Double(tick) / 20, seed: 77)
      for (old, new) in zip(previous, current) {
        #expect(abs(old.x - new.x) < 1)
        #expect(abs(old.y - new.y) < 1)
        #expect(abs(old.horizontalScale - new.horizontalScale) < 0.2)
        #expect(new.x >= 32 && new.x <= 352)
        #expect(new.y >= 50 && new.y <= 196)
        #expect(new.scale >= 0.7 && new.scale <= 1)
        if old.facingRight != new.facingRight {
          #expect(new.horizontalScale < 0.3)
        }
      }
      previous = current
    }
  }

  @Test func swimmingChangesDepthAndPunchesRecover() {
    let samples = (0..<800).map { IdleScreenAquariumBehavior.animals(at: Double($0) / 10, seed: 0) }
    #expect(Set(samples.map { $0[9].scale }).count > 10)
    let striking = samples.map { $0[8] }.filter { $0.activity == .striking }
    #expect(striking.contains { $0.strikeProgress > 0.8 })
    #expect(striking.contains { $0.strikeProgress < 0.2 })
    for (current, later) in zip(samples, samples.dropFirst(20))
    where current[8].activity == .striking {
      #expect(later[8].activity != .striking)
    }
  }
}
