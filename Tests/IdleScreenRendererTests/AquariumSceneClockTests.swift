import Foundation
import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium shared scene clock")
@MainActor
struct AquariumSceneClockTests {
  /// A manually advanced wall clock. Reference-date seconds, so the tick grid
  /// lines up with whole multiples of the cadence.
  final class Wall {
    var seconds: TimeInterval
    init(_ seconds: TimeInterval) { self.seconds = seconds }
    var date: Date { Date(timeIntervalSinceReferenceDate: seconds) }
  }

  private let cadence = 0.25

  private func clock(_ wall: Wall) -> IdleScreenAquariumSceneClock {
    IdleScreenAquariumSceneClock(cadence: cadence, now: { wall.date })
  }

  private func tank(epoch: TimeInterval = 1_000, seed: UInt64 = 42, width: Int = 384)
    -> IdleScreenAquariumRenderSettings
  {
    var settings = AquariumFrameFixtures.settings(width: width)
    settings.epoch = epoch
    settings.seed = seed
    settings.hourOffset = 0
    return settings
  }

  @Test func consumersInOneTickShareOneFrameIDAndDate() {
    let wall = Wall(100.01)
    let clock = clock(wall)
    let first = clock.sample()
    wall.seconds = 100.12
    let second = clock.sample()
    wall.seconds = 100.2499
    let third = clock.sample()
    #expect(first == second && second == third)
    #expect(first.date == Date(timeIntervalSinceReferenceDate: 100))
    #expect(clock.publishedCount == 1)
    wall.seconds = 100.25
    let next = clock.sample()
    #expect(next.frameID == first.frameID + 1)
    #expect(next.date == Date(timeIntervalSinceReferenceDate: 100.25))
    #expect(clock.publishedCount == 2)
  }

  @Test func theClockNeverRunsBackwardsAndSkipsMissedTicks() {
    let wall = Wall(50.3)
    let clock = clock(wall)
    let start = clock.sample()
    wall.seconds = 52.6
    let jumped = clock.sample()
    #expect(jumped.frameID > start.frameID + 1)
    wall.seconds = 10
    #expect(clock.sample() == jumped)
    wall.seconds = .nan
    #expect(clock.sample() == jumped)
  }

  @Test func staggeredConsumersRenderOneWorldRasterPerTick() {
    let wall = Wall(1_000_000)
    let clock = clock(wall)
    let cache = IdleScreenAquariumFrameCache()
    let settings = tank()
    // Three views whose callbacks interleave, some just either side of a boundary.
    let offsets: [[TimeInterval]] = [
      [0.00, 0.2501, 0.5001],
      [0.10, 0.2499, 0.4999],
      [0.24, 0.3000, 0.5100],
    ]
    var seenTimes: [Double: Set<Double>] = [:]
    let schedule = offsets.enumerated().flatMap { view, times in times.map { (view, $0) } }
      .sorted { $0.1 < $1.1 }
    var ticks = Set<UInt64>()
    for (_, offset) in schedule {
      wall.seconds = 1_000_000 + offset
      let sample = clock.sample()
      ticks.insert(sample.frameID)
      let elapsed = clock.elapsed(for: settings, fallback: -1)
      seenTimes[Double(sample.frameID), default: []].insert(elapsed)
      _ = cache.frame(at: elapsed, seed: 42, settings: settings)
    }
    #expect(seenTimes.values.allSatisfy { $0.count == 1 })
    #expect(clock.publishedCount == ticks.count)
    // One raster per distinct tick no matter how many consumers asked.
    #expect(cache.generatedFrameCount == ticks.count)
    #expect(ticks.count == 3)
  }

  @Test func advancingTicksInvalidateAndSettingsEditsReuseTheClock() {
    let wall = Wall(2_000_000)
    let clock = clock(wall)
    let cache = IdleScreenAquariumFrameCache()
    var settings = tank()
    func render() -> [SIMD4<Float>] {
      cache.frame(at: clock.elapsed(for: settings, fallback: 0), seed: 42, settings: settings)
    }
    let first = render()
    wall.seconds += 0.1
    #expect(render() == first)
    #expect(cache.generatedFrameCount == 1)
    wall.seconds += 0.2
    #expect(render() != first)
    #expect(cache.generatedFrameCount == 2)
    settings.light = "blacklight"
    _ = render()
    #expect(cache.generatedFrameCount == 3)
  }

  @Test func distinctTanksKeepSeparateIdentitiesOnTheSameTick() {
    let wall = Wall(3_000_000)
    let clock = clock(wall)
    let cache = IdleScreenAquariumFrameCache()
    let first = tank(epoch: 1_000, seed: 42)
    let second = tank(epoch: 2_500, seed: 43)
    let firstElapsed = clock.elapsed(for: first, fallback: 0)
    let secondElapsed = clock.elapsed(for: second, fallback: 0)
    #expect(firstElapsed != secondElapsed)
    _ = cache.frame(at: firstElapsed, seed: 42, settings: first)
    _ = cache.frame(at: secondElapsed, seed: 43, settings: second)
    _ = cache.frame(at: firstElapsed, seed: 42, settings: first)
    _ = cache.frame(at: secondElapsed, seed: 43, settings: second)
    #expect(cache.generatedFrameCount == 2)
    #expect(cache.cachedFrameCount == 2)
    #expect(clock.publishedCount == 1)
  }

  @Test func reduceMotionNormalizesTheSharedSampleAndDifferentCropsShareTheRaster() {
    let wall = Wall(4_000_000)
    let clock = clock(wall)
    let cache = IdleScreenAquariumFrameCache()
    var settings = tank()
    settings.reduceMotion = true
    var rasters: [[SIMD4<Float>]] = []
    for _ in 0..<5 {
      wall.seconds += 0.25
      rasters.append(
        cache.frame(
          at: clock.elapsed(for: settings, fallback: 0), seed: 42, settings: settings))
    }
    #expect(cache.generatedFrameCount == 1)
    #expect(rasters.dropFirst().allSatisfy { $0 == rasters[0] })
    // Crops are chosen after the world raster, so they never enter its identity.
    let framing = { (x: Double) in
      IdleScreenAquariumFraming(
        logicalSize: .init(width: 3_000, height: 600),
        viewport: .init(x: x, y: 0, width: 0.5, height: 1), worldWidth: 384)
    }
    #expect(framing(0).columns > 0 && framing(0.5).columns > 0)
    _ = cache.frame(at: clock.elapsed(for: settings, fallback: 0), seed: 42, settings: settings)
    #expect(cache.generatedFrameCount == 1)
  }

  @Test func tanksWithoutAnEpochFallBackToTheCallersSessionClock() {
    let wall = Wall(5_000_000)
    let clock = clock(wall)
    var settings = tank()
    settings.epoch = nil
    #expect(clock.elapsed(for: settings, fallback: 12.5) == 12.5)
    #expect(clock.elapsed(for: nil, fallback: 3) == 3)
  }

  @Test func theLastConsumerLeavingResetsTheClock() {
    let wall = Wall(6_000_000)
    let clock = clock(wall)
    let first = clock.register()
    let second = clock.register()
    #expect(clock.consumerCount == 2)
    let before = clock.sample()
    clock.unregister(first)
    wall.seconds -= 100
    #expect(clock.sample() == before)
    clock.unregister(second)
    #expect(clock.consumerCount == 0)
    #expect(clock.sample().frameID < before.frameID)
  }

  @Test func explicitTimeStaysExactForDeterministicCaptures() {
    let settings = tank()
    #expect(
      IdleScreenAquariumFrameClock.resolve(
        explicit: 123.456, automatic: 9, settings: settings, now: Date()) == 123.456)
  }
}
