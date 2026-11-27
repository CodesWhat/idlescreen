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
    let payload = try #require(
      String(
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

  @Test("validation rejects every malformed identifier, priority, timeline and lifetime")
  func rejectsInvalidInputs() throws {
    let createdAt = Date(timeIntervalSince1970: 1_786_295_958)
    func validate(
      sessionID: String = "session-1",
      eventID: String = "event-1",
      nonce: String = "nonce-1",
      priority: Int = 0,
      created: Date? = nil,
      expiresAt: Date? = nil,
      acknowledgedAt: Date? = nil
    ) throws -> IdleScreenAgentSignal {
      let created = created ?? createdAt
      return try IdleScreenAgentSignal.validated(
        provider: .codex,
        sessionID: sessionID,
        eventID: eventID,
        state: .working,
        title: nil,
        message: nil,
        temporaryLookID: nil,
        priority: priority,
        createdAt: created,
        expiresAt: expiresAt ?? created.addingTimeInterval(60),
        acknowledgedAt: acknowledgedAt,
        nonce: nonce,
        validatedAt: createdAt
      )
    }
    typealias Failure = IdleScreenAgentSignal.ValidationError

    for bad in [
      "", "has space", "slash/inside", "uni\u{00E9}code", String(repeating: "a", count: 129),
    ] {
      #expect(throws: Failure.invalidIdentifier(field: "sessionID")) {
        try validate(sessionID: bad)
      }
      #expect(throws: Failure.invalidIdentifier(field: "eventID")) {
        try validate(eventID: bad)
      }
      #expect(throws: Failure.invalidIdentifier(field: "nonce")) {
        try validate(nonce: bad)
      }
    }
    #expect(try validate(sessionID: String(repeating: "a", count: 128)).sessionID.count == 128)

    let low = IdleScreenAgentSignal.minimumPriority - 1
    let high = IdleScreenAgentSignal.maximumPriority + 1
    #expect(throws: Failure.invalidPriority(low)) { try validate(priority: low) }
    #expect(throws: Failure.invalidPriority(high)) { try validate(priority: high) }
    #expect(
      try validate(priority: IdleScreenAgentSignal.maximumPriority).priority
        == IdleScreenAgentSignal.maximumPriority)

    #expect(throws: Failure.invalidTimeline) {
      try validate(expiresAt: createdAt)
    }
    #expect(throws: Failure.invalidTimeline) {
      try validate(expiresAt: createdAt.addingTimeInterval(-1))
    }
    #expect(throws: Failure.invalidTimeline) {
      try validate(created: createdAt.addingTimeInterval(5 * 60 + 1))
    }
    #expect(throws: Failure.invalidTimeline) {
      try validate(acknowledgedAt: createdAt.addingTimeInterval(-1))
    }
    #expect(
      try validate(created: createdAt.addingTimeInterval(5 * 60)).createdAt
        == createdAt.addingTimeInterval(5 * 60))

    let limit = IdleScreenAgentSignal.maximumTimeToLive
    #expect(throws: Failure.expirationTooDistant) {
      try validate(expiresAt: createdAt.addingTimeInterval(limit + 1))
    }
    #expect(
      try validate(expiresAt: createdAt.addingTimeInterval(limit)).expiresAt
        == createdAt.addingTimeInterval(limit))
  }
}
