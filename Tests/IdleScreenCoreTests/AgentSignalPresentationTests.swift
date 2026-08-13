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
        #expect(IdleScreenAgentPresentationPolicy.isVisible(
            destination: .all,
            display: .init(isPrimary: false, isFocus: false)
        ))
        #expect(IdleScreenAgentPresentationPolicy.isVisible(
            destination: .primary,
            display: .init(isPrimary: true, isFocus: false)
        ))
        #expect(!IdleScreenAgentPresentationPolicy.isVisible(
            destination: .primary,
            display: .init(isPrimary: false, isFocus: true)
        ))
        #expect(IdleScreenAgentPresentationPolicy.isVisible(
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
