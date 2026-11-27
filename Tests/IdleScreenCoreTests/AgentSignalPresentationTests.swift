import Foundation
import Testing

@testable import IdleScreenCore

@Suite("AgentSignal presentation policy")
struct AgentSignalPresentationTests {
  @Test("presentation respects privacy controls state mapping and quiet hours")
  func mapsAndSuppresses() throws {
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let signal = try makeSignal(
      state: .needsAttention,
      title: "Codex needs attention",
      message: "Approve the next step",
      temporaryLookID: nil,
      now: now
    )
    let configuration = IdleScreenAgentIntegrationConfiguration(
      codexEnabled: true,
      claudeEnabled: false,
      quietHours: .init(startMinute: 1_320, endMinute: 420),
      showsProviderLabel: false,
      showsMessage: false
    )

    let visible = IdleScreenAgentPresentationPolicy.presentation(
      for: signal,
      configuration: configuration,
      at: now,
      minuteOfDay: 600
    )
    let quiet = IdleScreenAgentPresentationPolicy.presentation(
      for: signal,
      configuration: configuration,
      at: now,
      minuteOfDay: 60
    )

    #expect(visible?.providerLabel == nil)
    #expect(visible?.title == "Codex needs attention")
    #expect(visible?.message == nil)
    #expect(visible?.style == .attention)
    #expect(visible?.accessibilityLabel == "Codex needs attention")
    #expect(quiet == nil)
  }

  @Test("display destination is deterministic")
  func routesDisplays() {
    #expect(
      IdleScreenAgentPresentationPolicy.isVisible(
        destination: .all,
        display: .init(isPrimary: false, isFocus: false)
      ))
    #expect(
      IdleScreenAgentPresentationPolicy.isVisible(
        destination: .primary,
        display: .init(isPrimary: true, isFocus: false)
      ))
    #expect(
      !IdleScreenAgentPresentationPolicy.isVisible(
        destination: .primary,
        display: .init(isPrimary: false, isFocus: true)
      ))
    #expect(
      IdleScreenAgentPresentationPolicy.isVisible(
        destination: .focus,
        display: .init(isPrimary: false, isFocus: true)
      ))
  }

  @Test("temporary looks overlay the renderer input without mutating durable configuration")
  func appliesTemporaryLookInMemory() throws {
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let lookID = UUID(uuidString: "B3882715-1CDD-4EA0-AB97-38CB66772DD7")!
    var lookSource = IdleScreenConfiguration.default
    lookSource.appearance.palette = "Ocean"
    let withLook = try lookSource.savingCurrentLook(id: lookID, named: "Ocean")
    var durable = withLook
    durable.appearance.palette = "Ember"
    let signal = try makeSignal(
      state: .working,
      title: nil,
      message: nil,
      temporaryLookID: lookID,
      now: now
    )

    let presented = IdleScreenAgentPresentationPolicy.configuration(
      durable,
      applyingTemporaryLookFrom: signal
    )

    #expect(presented.appearance.palette == "Ocean")
    #expect(durable.appearance.palette == "Ember")
    #expect(presented.revision == durable.revision)
  }

  @Test("a hidden style suppresses the presentation for that state only")
  func hiddenStyleSuppresses() throws {
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    var configuration = IdleScreenAgentIntegrationConfiguration(codexEnabled: true)
    configuration.stateVisuals.error = .hidden
    let failing = try makeSignal(
      state: .error, title: nil, message: nil, temporaryLookID: nil, now: now)
    let working = try makeSignal(
      state: .working, title: nil, message: nil, temporaryLookID: nil, now: now)

    #expect(
      IdleScreenAgentPresentationPolicy.presentation(
        for: failing, configuration: configuration, at: now, minuteOfDay: 600) == nil)
    #expect(
      IdleScreenAgentPresentationPolicy.presentation(
        for: working, configuration: configuration, at: now, minuteOfDay: 600)?.style == .active)
  }

  @Test("a disabled provider, an idle state and an expired signal never present")
  func gatesProviderIdleAndExpiry() throws {
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let signal = try makeSignal(
      state: .working, title: nil, message: nil, temporaryLookID: nil, now: now)
    let idle = try makeSignal(
      state: .idle, title: nil, message: nil, temporaryLookID: nil, now: now)
    let enabled = IdleScreenAgentIntegrationConfiguration(codexEnabled: true)
    let claudeOnly = IdleScreenAgentIntegrationConfiguration(claudeEnabled: true)

    #expect(
      IdleScreenAgentPresentationPolicy.presentation(
        for: signal, configuration: claudeOnly, at: now, minuteOfDay: 600) == nil)
    #expect(
      IdleScreenAgentPresentationPolicy.presentation(
        for: idle, configuration: enabled, at: now, minuteOfDay: 600) == nil)
    #expect(
      IdleScreenAgentPresentationPolicy.presentation(
        for: signal, configuration: enabled, at: signal.expiresAt, minuteOfDay: 600) == nil)
    #expect(
      IdleScreenAgentPresentationPolicy.presentation(
        for: signal, configuration: enabled, at: now, minuteOfDay: 600) != nil)
  }

  @Test("a missing title falls back to a per-state default naming the provider")
  func defaultTitlePerState() throws {
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let expected: [IdleScreenAgentSignalState: String] = [
      .working: "Codex is working",
      .needsAttention: "Codex needs attention",
      .done: "Codex finished",
      .error: "Codex stopped with an error",
    ]
    let configuration = IdleScreenAgentIntegrationConfiguration(codexEnabled: true)
    for (state, title) in expected {
      let signal = try makeSignal(
        state: state, title: nil, message: nil, temporaryLookID: nil, now: now)
      let presented = IdleScreenAgentPresentationPolicy.presentation(
        for: signal, configuration: configuration, at: now, minuteOfDay: 600)
      #expect(presented?.title == title)
      #expect(presented?.accessibilityLabel == "Codex, \(title)")
    }
  }

  @Test("an absent or unknown temporary look leaves the durable configuration untouched")
  func temporaryLookFallsBack() throws {
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    var durable = IdleScreenConfiguration.default
    durable.appearance.palette = "Ember"
    let none = try makeSignal(
      state: .working, title: nil, message: nil, temporaryLookID: nil, now: now)
    let unknown = try makeSignal(
      state: .working, title: nil, message: nil, temporaryLookID: UUID(), now: now)

    #expect(
      IdleScreenAgentPresentationPolicy.configuration(
        durable, applyingTemporaryLookFrom: nil) == durable)
    #expect(
      IdleScreenAgentPresentationPolicy.configuration(
        durable, applyingTemporaryLookFrom: none) == durable)
    #expect(
      IdleScreenAgentPresentationPolicy.configuration(
        durable, applyingTemporaryLookFrom: unknown) == durable)
  }

  private func makeSignal(
    state: IdleScreenAgentSignalState,
    title: String?,
    message: String?,
    temporaryLookID: UUID?,
    now: Date
  ) throws -> IdleScreenAgentSignal {
    try IdleScreenAgentSignal.validated(
      provider: .codex,
      sessionID: "session-1",
      eventID: "event-1",
      state: state,
      title: title,
      message: message,
      temporaryLookID: temporaryLookID,
      priority: 0,
      createdAt: now,
      expiresAt: now.addingTimeInterval(120),
      acknowledgedAt: nil,
      nonce: "nonce-1",
      validatedAt: now
    )
  }
}
