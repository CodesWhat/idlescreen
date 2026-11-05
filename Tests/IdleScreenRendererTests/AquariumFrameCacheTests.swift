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
}
