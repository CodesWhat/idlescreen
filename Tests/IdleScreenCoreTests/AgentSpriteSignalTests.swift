import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Agent signals for scene sprites")
struct AgentSpriteSignalTests {
  private let now = Date(timeIntervalSince1970: 1_786_295_958)

  private func signal(
    _ provider: IdleScreenAgentProvider,
    _ state: IdleScreenAgentSignalState,
    createdAt: Date? = nil,
    lifetime: TimeInterval = 120
  ) throws -> IdleScreenAgentSignal {
    let created = createdAt ?? now
    return try IdleScreenAgentSignal.validated(
      provider: provider,
      sessionID: "\(provider.rawValue)-session",
      eventID: "\(provider.rawValue)-\(state.rawValue)",
      state: state,
      title: nil,
      message: nil,
      temporaryLookID: nil,
      priority: 0,
      createdAt: created,
      expiresAt: created.addingTimeInterval(lifetime),
      acknowledgedAt: nil,
      nonce: "\(provider.rawValue)-nonce",
      validatedAt: created
    )
  }

  @Test("the strongest signal per provider survives, strongest first")
  func perProvider() throws {
    let signals = [
      try signal(.codex, .working),
      try signal(.claude, .error),
      try signal(.codex, .needsAttention),
    ]
    let active = IdleScreenAgentSignalArbitrator.activeSignalsPerProvider(
      in: signals, at: now)
    #expect(active.map(\.provider) == [.codex, .claude])
    #expect(active.map(\.state) == [.needsAttention, .error])
    #expect(active.first == IdleScreenAgentSignalArbitrator.activeSignal(in: signals, at: now))
  }

  @Test("expired and idle signals never become sprites")
  func dropsDeadSignals() throws {
    let signals = [
      try signal(.codex, .done, lifetime: 5),
      try signal(.claude, .idle),
    ]
    #expect(
      IdleScreenAgentSignalArbitrator.activeSignalsPerProvider(
        in: signals, at: now.addingTimeInterval(10)
      ).isEmpty)
    #expect(
      IdleScreenAgentSignalArbitrator.activeSignalsPerProvider(in: signals, at: now).map(\.provider)
        == [.codex])
  }

  @Test("the monitor publishes every live agent and notices a second provider")
  func monitorPublishesBoth() throws {
    var monitor = IdleScreenAgentSignalMonitor(pollingInterval: 1)
    let codex = try signal(.codex, .needsAttention)
    let claude = try signal(.claude, .working)

    let first = monitor.consume(
      .init(revision: 1, signals: [codex], ignoredEventCounts: [:]), at: now)
    #expect(first?.signals == [codex])

    let second = monitor.consume(
      .init(revision: 1, signals: [codex, claude], ignoredEventCounts: [:]),
      at: now.addingTimeInterval(1))
    #expect(second?.signals.map(\.provider) == [.codex, .claude])
    #expect(second?.signal == codex)
  }

  @Test("presentations carry when the signal began")
  func presentationStart() throws {
    let started = now.addingTimeInterval(-30)
    var configuration = IdleScreenAgentIntegrationConfiguration()
    configuration.claudeEnabled = true
    let presentation = IdleScreenAgentPresentationPolicy.presentation(
      for: try signal(.claude, .done, createdAt: started),
      configuration: configuration,
      at: now,
      minuteOfDay: 600
    )
    #expect(presentation?.startedAt == started)
  }

  @Test("the signal behind a presentation is the one that passed the policy")
  func signalBehindPresentation() throws {
    let codex = try signal(.codex, .error)
    let claude = try signal(.claude, .working)
    var configuration = IdleScreenAgentIntegrationConfiguration.default
    configuration.codexEnabled = false
    configuration.claudeEnabled = true
    let presentations = [codex, claude].compactMap {
      IdleScreenAgentPresentationPolicy.presentation(
        for: $0, configuration: configuration, at: now, minuteOfDay: 600)
    }
    #expect(presentations.map(\.provider) == [.claude])
    #expect(
      IdleScreenAgentPresentationPolicy.signal(behind: presentations.first, in: [codex, claude])
        == claude)
    #expect(IdleScreenAgentPresentationPolicy.signal(behind: nil, in: [codex, claude]) == nil)
  }

  @Test("one accessibility label joins every presentation")
  func joinedLabel() throws {
    var configuration = IdleScreenAgentIntegrationConfiguration.default
    configuration.codexEnabled = true
    configuration.claudeEnabled = true
    let presentations = try [signal(.codex, .error), signal(.claude, .working)].compactMap {
      IdleScreenAgentPresentationPolicy.presentation(
        for: $0, configuration: configuration, at: now, minuteOfDay: 600)
    }
    let label = try #require(
      IdleScreenAgentPresentationPolicy.accessibilityLabel(for: presentations))
    #expect(label.contains("Codex stopped with an error") && label.contains("Claude is working"))
    #expect(IdleScreenAgentPresentationPolicy.accessibilityLabel(for: []) == nil)
  }
}
