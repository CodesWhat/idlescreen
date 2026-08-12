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
        let payload = Data(#"""
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
        #expect(IdleScreenAgentIntegrationConfiguration(messageTimeout: 1)
            .messageTimeout == 15)
        #expect(IdleScreenAgentIntegrationConfiguration(messageTimeout: 9_999)
            .messageTimeout == 3_600)
        #expect(IdleScreenAgentIntegrationConfiguration(messageTimeout: .infinity)
            .messageTimeout == 120)
        let quiet = IdleScreenAgentQuietHours(startMinute: 1_320, endMinute: 420)
        #expect(quiet.contains(minuteOfDay: 1_380))
        #expect(quiet.contains(minuteOfDay: 120))
        #expect(!quiet.contains(minuteOfDay: 720))
    }
}
