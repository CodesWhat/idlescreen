import CryptoKit
import Foundation
import Testing

@testable import IdleScreenAgent
@testable import IdleScreenCore

@Suite("Private lifecycle hook adapters")
struct HookAdapterTests {
  private let now = Date(timeIntervalSince1970: 1_786_295_958)

  @Test(
    "Codex lifecycle events map without retaining private payload fields",
    arguments: [
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

  @Test(
    "Claude-only events map to attention and failure",
    arguments: [
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

    #expect(
      mutation
        == .clear(
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

  @Test("event IDs follow the invocation nonce, not the turn")
  func eventIDsFollowNonce() throws {
    func eventID(nonce: String) throws -> String {
      let mutation = try IdleScreenAgentHookAdapter.mutation(
        provider: .codex,
        payload: try hookPayload(event: "PermissionRequest"),
        configuration: enabledConfiguration,
        receivedAt: now,
        nonce: nonce
      )
      return try #require(mutation.signal).eventID
    }

    let first = try eventID(nonce: "nonce-a")
    let second = try eventID(nonce: "nonce-b")
    let replay = try eventID(nonce: "nonce-a")

    #expect(first != second)
    #expect(first == replay)
    #expect(!first.contains("turn-456"))
  }

  @Test("identifiers that are not clean fall back to a stable SHA-256 digest")
  func hashesUncleanIdentifiers() throws {
    func digest(_ value: String) -> String {
      SHA256.hash(data: Data(value.utf8)).prefix(16)
        .map { String(format: "%02x", $0) }.joined()
    }
    func mutation(session: String, nonce: String) throws -> IdleScreenAgentSignal {
      let payload = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "Stop", "session_id": session,
      ])
      return try #require(
        try IdleScreenAgentHookAdapter.mutation(
          provider: .codex,
          payload: payload,
          configuration: enabledConfiguration,
          receivedAt: now,
          nonce: nonce
        ).signal)
    }
    let dirty = "my session/with spaces \u{00E9}"
    let overlong = String(repeating: "a", count: 129)

    let hashed = try mutation(session: dirty, nonce: "nonce-1")
    #expect(hashed.sessionID == "sessionid-\(digest(dirty))")
    #expect(try mutation(session: dirty, nonce: "nonce-1").sessionID == hashed.sessionID)
    #expect(
      try mutation(session: "my session/with spaces", nonce: "nonce-1").sessionID
        != hashed.sessionID)
    #expect(
      try mutation(session: overlong, nonce: "nonce-1").sessionID == "sessionid-\(digest(overlong))"
    )

    let clean = String(repeating: "a", count: 128)
    #expect(try mutation(session: clean, nonce: "nonce-1").sessionID == clean)

    let dirtyNonce = try mutation(session: "session-1", nonce: "nonce with spaces")
    #expect(dirtyNonce.nonce == "nonce-\(digest("nonce with spaces"))")
    #expect(dirtyNonce.eventID == "stop-event-\(digest("nonce with spaces"))")
  }

  @Test("an empty or missing session id fails closed instead of hashing")
  func rejectsMissingSession() throws {
    for payload in [
      ["hook_event_name": "Stop"],
      ["hook_event_name": "Stop", "session_id": ""],
    ] {
      #expect(throws: IdleScreenAgentHookAdapter.Error.missingField("session_id")) {
        try IdleScreenAgentHookAdapter.mutation(
          provider: .codex,
          payload: try JSONSerialization.data(withJSONObject: payload),
          configuration: enabledConfiguration,
          receivedAt: now,
          nonce: "nonce-1"
        )
      }
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

extension IdleScreenAgentSignalStore.Mutation {
  fileprivate var signal: IdleScreenAgentSignal? {
    guard case .set(let signal) = self else { return nil }
    return signal
  }
}
