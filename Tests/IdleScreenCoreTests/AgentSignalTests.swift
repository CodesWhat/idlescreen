import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Agent signal contract")
struct AgentSignalTests {
    @Test("explicit display text becomes bounded plain text")
    func sanitizesDisplayText() throws {
        let createdAt = Date(timeIntervalSince1970: 1_786_295_958)
        let signal = try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: "thread-123",
            eventID: "turn-456",
            state: .needsAttention,
            title: "  **Build**\u{001B}[31m alert  ",
            message: "First\tline\n<script>secret</script>\nThird line\nIgnored line",
            temporaryLookID: nil,
            priority: 7,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(300),
            acknowledgedAt: nil,
            nonce: "nonce-789",
            validatedAt: createdAt
        )

        #expect(signal.title == "Build alert")
        #expect(signal.message == "First line\nsecret\nThird line")
        #expect(signal.message?.utf8.count ?? 0 <= 280)
        #expect(signal.schemaVersion == 1)
    }

    @Test("future signal schemas fail closed")
    func rejectsFutureSchema() throws {
        let createdAt = Date(timeIntervalSince1970: 1_786_295_958)
        let signal = try IdleScreenAgentSignal.validated(
            provider: .claude,
            sessionID: "session-1",
            eventID: "event-1",
            state: .working,
            title: nil,
            message: nil,
            temporaryLookID: nil,
            priority: 0,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(60),
            acknowledgedAt: nil,
            nonce: "nonce-1",
            validatedAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try #require(String(
            data: encoder.encode(signal),
            encoding: .utf8
        ))
        let futurePayload = payload.replacingOccurrences(
            of: #""schemaVersion":1"#,
            with: #""schemaVersion":999"#
        )
        let data = try #require(futurePayload.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        #expect(throws: IdleScreenAgentSignal.ValidationError.unsupportedSchema(999)) {
            try decoder.decode(IdleScreenAgentSignal.self, from: data)
        }
    }

    @Test("active arbitration is urgent deterministic and expiry aware")
    func arbitratesActiveSignals() throws {
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let signals = try [
            makeSignal(
                sessionID: "working",
                state: .working,
                priority: 100,
                createdAt: now.addingTimeInterval(-5),
                expiresAt: now.addingTimeInterval(60)
            ),
            makeSignal(
                sessionID: "error",
                state: .error,
                priority: 100,
                createdAt: now.addingTimeInterval(-4),
                expiresAt: now.addingTimeInterval(60)
            ),
            makeSignal(
                sessionID: "attention-old",
                state: .needsAttention,
                priority: 4,
                createdAt: now.addingTimeInterval(-3),
                expiresAt: now.addingTimeInterval(60)
            ),
            makeSignal(
                sessionID: "attention-new",
                state: .needsAttention,
                priority: 4,
                createdAt: now.addingTimeInterval(-2),
                expiresAt: now.addingTimeInterval(60)
            ),
            makeSignal(
                sessionID: "expired",
                state: .needsAttention,
                priority: 99,
                createdAt: now.addingTimeInterval(-20),
                expiresAt: now.addingTimeInterval(-1)
            ),
            makeSignal(
                sessionID: "idle",
                state: .idle,
                priority: 100,
                createdAt: now.addingTimeInterval(-1),
                expiresAt: now.addingTimeInterval(60)
            ),
        ]

        let active = IdleScreenAgentSignalArbitrator.activeSignal(
            in: signals,
            at: now
        )

        #expect(active?.sessionID == "attention-new")
    }

    private func makeSignal(
        sessionID: String,
        state: IdleScreenAgentSignalState,
        priority: Int,
        createdAt: Date,
        expiresAt: Date,
        acknowledgedAt: Date? = nil
    ) throws -> IdleScreenAgentSignal {
        try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: sessionID,
            eventID: "event-\(sessionID)",
            state: state,
            title: nil,
            message: nil,
            temporaryLookID: nil,
            priority: priority,
            createdAt: createdAt,
            expiresAt: expiresAt,
            acknowledgedAt: acknowledgedAt,
            nonce: "nonce-\(sessionID)",
            validatedAt: createdAt
        )
    }
}
