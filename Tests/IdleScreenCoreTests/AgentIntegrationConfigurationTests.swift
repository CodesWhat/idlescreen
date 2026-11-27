import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Agent integration configuration")
struct AgentIntegrationConfigurationTests {
  @Test("schema nine adds an explicitly opted-out bounded integration default")
  func defaults() {
    let integration = IdleScreenConfiguration.default.agentIntegration

    #expect(IdleScreenConfiguration.currentSchemaVersion == 9)
    #expect(integration == .default)
    #expect(!integration.codexEnabled)
    #expect(!integration.claudeEnabled)
    #expect(integration.messageTimeout == 120)
    #expect(integration.displayDestination == .primary)
    #expect(integration.overlayPosition == .topTrailing)
  }

  @Test("schema eight migrates with providers explicitly disabled")
  func migratesSchemaEight() throws {
    let payload = Data(
      #"""
      {
        "schemaVersion": 8,
        "revision": 44,
        "modifiedAt": "2026-08-09T12:00:00Z",
        "source": "generative",
        "appearance": {"glyphScale": 0.38, "contrast": 0.58, "palette": "Ember"}
      }
      """#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let configuration = try decoder.decode(
      IdleScreenConfiguration.self,
      from: payload
    )

    #expect(configuration.schemaVersion == 8)
    #expect(configuration.agentIntegration == .default)
  }

  @Test("timeouts and overnight quiet hours are bounded")
  func normalizesBounds() {
    #expect(
      IdleScreenAgentIntegrationConfiguration(messageTimeout: 1)
        .messageTimeout == 15)
    #expect(
      IdleScreenAgentIntegrationConfiguration(messageTimeout: 9_999)
        .messageTimeout == 3_600)
    #expect(
      IdleScreenAgentIntegrationConfiguration(messageTimeout: .infinity)
        .messageTimeout == 120)
    let quiet = IdleScreenAgentQuietHours(startMinute: 1_320, endMinute: 420)
    #expect(quiet.contains(minuteOfDay: 1_380))
    #expect(quiet.contains(minuteOfDay: 120))
    #expect(!quiet.contains(minuteOfDay: 720))
  }

  @Test("quiet hours clamp their bounds and start equal to end is never quiet")
  func quietHourEdges() {
    let clamped = IdleScreenAgentQuietHours(startMinute: -50, endMinute: 5_000)
    #expect(clamped.startMinute == 0)
    #expect(clamped.endMinute == 1_439)
    #expect(clamped.contains(minuteOfDay: 0))
    #expect(!clamped.contains(minuteOfDay: 1_439))

    let never = IdleScreenAgentQuietHours(startMinute: 600, endMinute: 600)
    for minute in [0, 599, 600, 601, 1_439, -10, 9_999] {
      #expect(!never.contains(minuteOfDay: minute))
    }

    let overnight = IdleScreenAgentQuietHours(startMinute: 1_320, endMinute: 420)
    #expect(overnight.contains(minuteOfDay: 1_320))
    #expect(!overnight.contains(minuteOfDay: 420))
    #expect(overnight.contains(minuteOfDay: 9_999))
  }

  @Test("a fully customised configuration survives an encode and decode")
  func roundTrips() throws {
    let original = IdleScreenAgentIntegrationConfiguration(
      codexEnabled: true,
      claudeEnabled: true,
      messageTimeout: 300,
      quietHours: .init(startMinute: 1_320, endMinute: 420),
      displayDestination: .focus,
      overlayPosition: .bottomLeading,
      showsProviderLabel: false,
      showsMessage: false,
      stateVisuals: .init(
        working: .subtle, needsAttention: .hidden, done: .active, error: .attention)
    )
    let decoded = try JSONDecoder().decode(
      IdleScreenAgentIntegrationConfiguration.self,
      from: JSONEncoder().encode(original)
    )
    #expect(decoded == original)
    #expect(decoded.normalized == original)

    let bare = IdleScreenAgentIntegrationConfiguration.default
    let bareDecoded = try JSONDecoder().decode(
      IdleScreenAgentIntegrationConfiguration.self,
      from: JSONEncoder().encode(bare)
    )
    #expect(bareDecoded == bare)
    #expect(bareDecoded.quietHours == nil)
  }

  @Test("out-of-range persisted quiet hours and timeouts are bounded on decode")
  func decodeBoundsPersistedValues() throws {
    let payload = Data(
      #"""
      {
        "codexEnabled": true, "claudeEnabled": false, "messageTimeout": 1,
        "quietHours": {"startMinute": -20, "endMinute": 9000},
        "displayDestination": "all", "overlayPosition": "topLeading",
        "showsProviderLabel": true, "showsMessage": true,
        "stateVisuals": {"working": "active", "needsAttention": "attention", "done": "success", "error": "failure"}
      }
      """#.utf8)
    let decoded = try JSONDecoder().decode(
      IdleScreenAgentIntegrationConfiguration.self, from: payload)

    #expect(decoded.messageTimeout == 15)
    #expect(decoded.quietHours == .init(startMinute: 0, endMinute: 1_439))
  }
}
