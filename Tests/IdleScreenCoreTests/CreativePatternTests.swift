import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Creative pattern presentation and resolution")
struct CreativePatternTests {
  @Test("every pattern has a unique display name and symbol")
  func presentation() {
    let patterns = IdleScreenCreativePattern.allCases
    #expect(Set(patterns.map(\.displayName)).count == patterns.count)
    #expect(Set(patterns.map(\.symbolName)).count == patterns.count)
    #expect(patterns.allSatisfy { !$0.displayName.isEmpty && !$0.symbolName.isEmpty })
    #expect(IdleScreenCreativePattern.aquarium.displayName == "Shrimp Tank")
    #expect(IdleScreenCreativePattern.plasma.id == "plasma")
  }

  @Test("concrete patterns resolve to themselves at any time")
  func concreteResolution() {
    #expect(IdleScreenCreativePattern.plasma.resolved(at: 9_999, autoCycleInterval: 5) == .plasma)
  }

  @Test("auto cycle steps through the stable pattern order and wraps")
  func autoCycleSteps() {
    let patterns = IdleScreenCreativePattern.patterns
    #expect(
      IdleScreenCreativePattern.autoCycle.resolved(at: 0, autoCycleInterval: 10) == patterns[0])
    #expect(
      IdleScreenCreativePattern.autoCycle.resolved(at: 9.9, autoCycleInterval: 10) == patterns[0])
    #expect(
      IdleScreenCreativePattern.autoCycle.resolved(at: 10, autoCycleInterval: 10) == patterns[1])
    #expect(
      IdleScreenCreativePattern.autoCycle.resolved(at: 25, autoCycleInterval: 10) == patterns[2])
    let wrap = Double(patterns.count) * 10
    #expect(
      IdleScreenCreativePattern.autoCycle.resolved(at: wrap, autoCycleInterval: 10) == patterns[0])
    #expect(
      IdleScreenCreativePattern.autoCycle.resolved(at: wrap + 10, autoCycleInterval: 10)
        == patterns[1])
  }

  @Test("negative and non-finite elapsed times resolve from the first slot")
  func autoCycleSafety() {
    let first = IdleScreenCreativePattern.patterns[0]
    #expect(IdleScreenCreativePattern.autoCycle.resolved(at: -50, autoCycleInterval: 10) == first)
    #expect(IdleScreenCreativePattern.autoCycle.resolved(at: .nan, autoCycleInterval: 10) == first)
    #expect(
      IdleScreenCreativePattern.autoCycle.resolved(at: .infinity, autoCycleInterval: 10) == first)
  }

  @Test("configuration resolves its pattern with its own cycle interval")
  func configurationResolution() {
    var settings = IdleScreenCreativeSettings.default
    settings.autoCycleInterval = 20
    let configuration = IdleScreenCreativeConfiguration(pattern: .autoCycle, settings: settings)
    let patterns = IdleScreenCreativePattern.patterns

    #expect(configuration.resolvedPattern == patterns[0])
    #expect(configuration.resolvedPattern(at: 45) == patterns[2])
    #expect(
      IdleScreenCreativeConfiguration(pattern: .ripple).resolvedPattern(at: 500) == .ripple
    )
  }
}
