import CoreGraphics
import Foundation
import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium framing and scene clock")
struct AquariumPresentationTests {
  @Test func explicitFrameTimeWinsAndRetainsLongRunningFractions() {
    var settings = IdleScreenAquariumRenderSettings()
    settings.epoch = 0
    let first = IdleScreenAquariumFrameClock.resolve(
      explicit: 30_000_000.125, automatic: 0, settings: settings,
      now: Date(timeIntervalSince1970: 500))
    let second = IdleScreenAquariumFrameClock.resolve(
      explicit: 30_000_000.125, automatic: 99, settings: settings,
      now: Date(timeIntervalSince1970: 1_500))
    #expect(first == second)
    #expect(first.truncatingRemainder(dividingBy: 1) == 0.125)
    #expect(
      IdleScreenAquariumFrameClock.resolve(
        explicit: .nan, automatic: 0, settings: settings, now: Date()) == 0)
    settings.reduceMotion = true
    #expect(
      IdleScreenAquariumFrameClock.resolve(
        explicit: 5, automatic: 0, settings: settings, now: Date()) == 5)
  }

  @Test func reducedMotionFreezesAnimalsButKeepsScheduledLightAndDawnRamp() {
    var settings = IdleScreenAquariumRenderSettings()
    settings.epoch = 0
    settings.light = "automatic"
    settings.reduceMotion = true
    settings.inhabitants = [.init(identity: 7, species: "cherryShrimp")]
    let night = IdleScreenAquarium.frame(at: 3 * 3600, seed: 42, settings: settings)
    let dawn = IdleScreenAquarium.frame(at: 9.25 * 3600, seed: 42, settings: settings)
    let day = IdleScreenAquarium.frame(at: 12 * 3600, seed: 42, settings: settings)
    #expect(night[0].x < dawn[0].x)
    #expect(dawn[0].x < day[0].x)
    #expect(abs(dawn[0].x - (night[0].x + day[0].x) / 2) < 0.00001)
    settings.light = "daylight"
    #expect(
      IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings)
        == IdleScreenAquarium.frame(at: 100, seed: 42, settings: settings))
  }

  @Test(arguments: [
    CGSize(width: 200, height: 400), CGSize(width: 2_000, height: 500),
    CGSize(width: 800, height: 450),
  ])
  func fittedContentPreservesProportions(size: CGSize) {
    let framing = IdleScreenAquariumFraming(logicalSize: size, viewport: .full, worldWidth: 384)
    let rect = framing.contentRect
    #expect(abs((rect.width * size.width) / (rect.height * size.height) - 384.0 / 216) < 0.0001)
    #expect(framing.coordinate(u: 0.5, v: 0.5)?.x == 192)
    #expect(framing.coordinate(u: 0.5, v: 0.5)?.y == 108)
    #expect(framing.columns * framing.rows <= 1152 * 432)
  }

  @Test func wideTankExposesMoreWorldWithoutGrowingSprites() {
    var settings = IdleScreenAquariumRenderSettings()
    settings.worldWidth = 768
    settings.inhabitants = [.init(identity: 5, species: "lionfish")]
    let frame = IdleScreenAquarium.frame(at: 0, seed: 42, settings: settings)
    #expect(frame.count == 768 * 216)
    let framing = IdleScreenAquariumFraming(
      logicalSize: .init(width: 768, height: 216), viewport: .full, worldWidth: 768)
    #expect(framing.contentRect.width == 1)
    #expect(framing.contentRect.height == 1)
    #expect(framing.coordinate(u: 0.75, v: 0.5)?.x == 576)
  }
}
