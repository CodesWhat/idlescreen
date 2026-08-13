import Foundation
import Testing
@testable import IdleScreenAgent
@testable import IdleScreenCore

@Suite("Private lifecycle hook adapters")
struct HookAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_786_295_958)

    @Test("Codex lifecycle events map without retaining private payload fields", arguments: [
        ("SessionStart", IdleScreenAgentSignalState.working),
        ("UserPromptSubmit", .working),
        ("PermissionRequest", .needsAttention),
        ("Stop", .done),
    ])
    func mapsCodex(event: String, state: IdleScreenAgentSignalState) throws {
        let data = try hookPayload(
            event: event,
            privateFields: [
                "prompt": "do not persist this prompt",
                "transcript_path": "/secret/transcript.jsonl",
                "tool_input": "rm -rf private",
                "last_assistant_message": "private assistant answer",
            ]
        )
        let mutation = try IdleScreenAgentHookAdapter.mutation(
            provider: .codex,
            payload: data,
            configuration: enabledConfiguration,
            receivedAt: now,
            nonce: "nonce-1"
        )
        let signal = try #require(mutation.signal)
        let encoded = try String(decoding: JSONEncoder().encode(signal), as: UTF8.self)

        #expect(signal.state == state)
        #expect(signal.provider == .codex)
        #expect(signal.message == nil)
        #expect(!encoded.contains("do not persist"))
        #expect(!encoded.contains("secret/transcript"))
        #expect(!encoded.contains("rm -rf"))
        #expect(!encoded.contains("private assistant"))
    }

    @Test("Claude-only events map to attention and failure", arguments: [
        ("Notification", IdleScreenAgentSignalState.needsAttention),
        ("StopFailure", .error),
    ])
    func mapsClaudeExtensions(event: String, state: IdleScreenAgentSignalState) throws {
        let data = try hookPayload(
            event: event,
            privateFields: [
                "message": "private notification",
                "error": "private failure details",
            ]
        )

        let mutation = try IdleScreenAgentHookAdapter.mutation(
            provider: .claude,
            payload: data,
            configuration: enabledConfiguration,
            receivedAt: now,
            nonce: "nonce-2"
        )
        let signal = try #require(mutation.signal)

        #expect(signal.state == state)
        #expect(signal.message == nil)
    }

    @Test("session end clears its provider session")
    func mapsSessionEnd() throws {
        let mutation = try IdleScreenAgentHookAdapter.mutation(
            provider: .codex,
            payload: try hookPayload(event: "SessionEnd"),
            configuration: enabledConfiguration,
            receivedAt: now,
            nonce: "nonce-3"
        )

        #expect(mutation == .clear(
            provider: .codex,
            sessionID: "session-123",
            eventID: "sessionend-nonce-3"
        ))
    }

    @Test("unknown events increment only the provider counter")
    func ignoresUnknownEvents() throws {
        let mutation = try IdleScreenAgentHookAdapter.mutation(
            provider: .claude,
            payload: try hookPayload(
                event: "FuturePrivateEvent",
                privateFields: ["payload": "must-not-survive"]
            ),
            configuration: enabledConfiguration,
            receivedAt: now,
            nonce: "nonce-4"
        )

        #expect(mutation == .recordIgnored(provider: .claude))
    }

    @Test("disabled providers and oversized payloads fail closed")
    func failsClosed() throws {
        #expect(throws: IdleScreenAgentHookAdapter.Error.providerDisabled(.codex)) {
            try IdleScreenAgentHookAdapter.mutation(
                provider: .codex,
                payload: try hookPayload(event: "SessionStart"),
                configuration: .default,
                receivedAt: now,
                nonce: "nonce-5"
            )
        }
        #expect(throws: IdleScreenAgentHookAdapter.Error.payloadTooLarge) {
            try IdleScreenAgentHookAdapter.mutation(
                provider: .codex,
                payload: Data(repeating: 0x41, count: 65_537),
                configuration: enabledConfiguration,
                receivedAt: now,
                nonce: "nonce-6"
            )
        }
    }

    private var enabledConfiguration: IdleScreenAgentIntegrationConfiguration {
        .init(codexEnabled: true, claudeEnabled: true, messageTimeout: 90)
    }

    private func hookPayload(
        event: String,
        privateFields: [String: String] = [:]
    ) throws -> Data {
        var payload = privateFields
        payload["hook_event_name"] = event
        payload["session_id"] = "session-123"
        payload["turn_id"] = "turn-456"
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

private extension IdleScreenAgentSignalStore.Mutation {
    var signal: IdleScreenAgentSignal? {
        guard case let .set(signal) = self else { return nil }
        return signal
    }
}
