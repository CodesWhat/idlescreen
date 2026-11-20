import Testing

@testable import IdleScreenRenderer

@Suite("Shared aquarium frame cache")
@MainActor
struct AquariumFrameCacheTests {
  @Test func reducedMotionRastersReuseStillFramesAndMinuteLightingSamples() {
    let cache = IdleScreenAquariumFrameCache()
    var settings = IdleScreenAquariumRenderSettings()
    settings.reduceMotion = true
    _ = cache.frame(at: 12, seed: 42, settings: settings)
    _ = cache.frame(at: 100, seed: 42, settings: settings)
    #expect(cache.generatedFrameCount == 1)
    settings.light = "automatic"
    _ = cache.frame(at: 62, seed: 42, settings: settings)
    _ = cache.frame(at: 90, seed: 42, settings: settings)
    #expect(cache.generatedFrameCount == 2)
    _ = cache.frame(at: 122, seed: 42, settings: settings)
    #expect(cache.generatedFrameCount == 3)
  }

  @Test func matchingViewportConsumersReuseOneRasterAndEditsInvalidateIt() {
    let cache = IdleScreenAquariumFrameCache()
    var settings = IdleScreenAquariumRenderSettings()
    let first = cache.frame(at: 12, seed: 42, settings: settings)
    #expect(first == cache.frame(at: 12, seed: 42, settings: settings))
    #expect(cache.generatedFrameCount == 1)
    settings.light = "blacklight"
    #expect(first != cache.frame(at: 12, seed: 42, settings: settings))
    #expect(cache.generatedFrameCount == 2)
    for time in 0..<10 { _ = cache.frame(at: Double(time), seed: 42, settings: settings) }
    #expect(cache.cachedFrameCount <= 8)
    cache.clear()
    #expect(cache.cachedFrameCount == 0)
  }

  private func address(_ pixels: [SIMD4<Float>]) -> UnsafeRawPointer? {
    pixels.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
  }

  @Test func oneAnimatedSceneKeepsOnlyItsLatestRaster() {
    let cache = IdleScreenAquariumFrameCache()
    let settings = AquariumFrameFixtures.settings(width: 384)
    for step in 0..<40 { _ = cache.frame(at: Double(step) * 0.5, seed: 42, settings: settings) }
    #expect(cache.cachedFrameCount == 1)
    #expect(cache.generatedFrameCount == 40)
    #expect(cache.cachedByteCount == 384 * 216 * MemoryLayout<SIMD4<Float>>.stride)
    // Only the current time is retained.
    _ = cache.frame(at: 19.5, seed: 42, settings: settings)
    #expect(cache.generatedFrameCount == 40)
    _ = cache.frame(at: 0, seed: 42, settings: settings)
    #expect(cache.generatedFrameCount == 41)
  }

  @Test func interleavedDistinctScenesStillReuseTheirCurrentFrames() {
    let cache = IdleScreenAquariumFrameCache()
    let first = AquariumFrameFixtures.settings(width: 384)
    var second = AquariumFrameFixtures.settings(width: 768)
    second.seed = 7
    for step in 0..<6 {
      let time = Double(step)
      let a = cache.frame(at: time, seed: 42, settings: first)
      let b = cache.frame(at: time, seed: 7, settings: second)
      // A second pass at the same instant is two cache hits.
      #expect(a == cache.frame(at: time, seed: 42, settings: first))
      #expect(b == cache.frame(at: time, seed: 7, settings: second))
    }
    #expect(cache.generatedFrameCount == 12)
    #expect(cache.cachedFrameCount == 2)
  }

  @Test func storageIsReusedOnlyWhenNoSnapshotStillSharesIt() {
    let cache = IdleScreenAquariumFrameCache()
    let settings = AquariumFrameFixtures.settings(width: 384)
    var previous: UnsafeRawPointer?
    func renderAndDrop(_ time: Double) -> UnsafeRawPointer? {
      address(cache.frame(at: time, seed: 42, settings: settings))
    }
    previous = renderAndDrop(1)
    #expect(previous != nil)
    #expect(renderAndDrop(2) == previous)
    #expect(renderAndDrop(3) == previous)

    let retained = cache.frame(at: 4, seed: 42, settings: settings)
    let retainedHash = AquariumFrameFixtures.hash(retained)
    let retainedAddress = address(retained)
    let next = cache.frame(at: 5, seed: 42, settings: settings)
    #expect(address(next) != retainedAddress)
    #expect(AquariumFrameFixtures.hash(retained) == retainedHash)
    #expect(retained == IdleScreenAquarium.frame(at: 4, seed: 42, settings: settings))
    #expect(next == IdleScreenAquarium.frame(at: 5, seed: 42, settings: settings))
  }

  @Test func reusedRastersAreIdenticalToFreshRenders() {
    let cache = IdleScreenAquariumFrameCache()
    let small = AquariumFrameFixtures.settings(width: 384)
    let large = AquariumFrameFixtures.settings(width: 1152)
    for (time, settings) in [(1.0, small), (2, large), (3, small), (4, large)] {
      #expect(
        cache.frame(at: time, seed: 42, settings: settings)
          == IdleScreenAquarium.frame(at: time, seed: 42, settings: settings))
    }
  }

  @Test func aggregateBytesStayWithinTheLimitAcrossScenes() {
    let wide = 1152 * 216 * MemoryLayout<SIMD4<Float>>.stride
    let cache = IdleScreenAquariumFrameCache(byteLimit: 2 * wide)
    var scenes: [IdleScreenAquariumRenderSettings] = []
    for seed in 0..<5 {
      var settings = AquariumFrameFixtures.settings(width: 1152)
      settings.seed = UInt64(seed)
      scenes.append(settings)
    }
    for (index, settings) in scenes.enumerated() {
      _ = cache.frame(at: 1, seed: UInt64(index), settings: settings)
      #expect(cache.cachedByteCount <= 2 * wide)
    }
    #expect(cache.cachedFrameCount == 2)
    // The two newest survive; the oldest was evicted and must re-render.
    let generated = cache.generatedFrameCount
    _ = cache.frame(at: 1, seed: 4, settings: scenes[4])
    _ = cache.frame(at: 1, seed: 3, settings: scenes[3])
    #expect(cache.generatedFrameCount == generated)
    _ = cache.frame(at: 1, seed: 0, settings: scenes[0])
    #expect(cache.generatedFrameCount == generated + 1)
    // One scene larger than the limit is still kept so it can be reused.
    let tiny = IdleScreenAquariumFrameCache(byteLimit: 1)
    _ = tiny.frame(at: 1, seed: 0, settings: scenes[0])
    _ = tiny.frame(at: 1, seed: 0, settings: scenes[0])
    #expect(tiny.generatedFrameCount == 1)
  }

  @Test func aLongWideAnimationHoldsOneFrameOfMemory() {
    let cache = IdleScreenAquariumFrameCache()
    let settings = AquariumFrameFixtures.settings(width: 1152)
    for step in 0..<90 {
      _ = cache.frame(at: Double(step) / 60, seed: 42, settings: settings)
      #expect(cache.cachedByteCount <= 1152 * 216 * MemoryLayout<SIMD4<Float>>.stride)
    }
    #expect(cache.cachedFrameCount == 1)
  }

  @Test func settingsEditsInvalidateAndTeardownClears() {
    let cache = IdleScreenAquariumFrameCache()
    var settings = AquariumFrameFixtures.settings(width: 384)
    let before = cache.frame(at: 5, seed: 42, settings: settings)
    settings.light = "blacklight"
    let after = cache.frame(at: 5, seed: 42, settings: settings)
    #expect(before != after)
    #expect(cache.generatedFrameCount == 2)
    cache.clear()
    #expect(cache.cachedFrameCount == 0 && cache.cachedByteCount == 0)
    #expect(cache.preparation.cachedBaseCount == 0)
  }
}
