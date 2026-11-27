import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Agent signal monitor")
struct AgentSignalMonitorTests {
  @Test("polling publishes changes and observes expiry without a new write")
  func publishesAndExpires() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_295_958)
    let store = IdleScreenAgentSignalStore(
      fileURL: root.appending(path: "inbox-v1.json")
    )
    let signal = try IdleScreenAgentSignal.validated(
      provider: .codex,
      sessionID: "session-1",
      eventID: "event-1",
      state: .working,
      title: "Codex",
      message: nil,
      temporaryLookID: nil,
      priority: 0,
      createdAt: now,
      expiresAt: now.addingTimeInterval(2),
      acknowledgedAt: nil,
      nonce: "nonce-1",
      validatedAt: now
    )
    _ = try store.apply(.set(signal), at: now)
    var monitor = IdleScreenAgentSignalMonitor(store: store, pollingInterval: 1)

    let initial = try monitor.poll(at: now)
    let tooSoon = try monitor.poll(at: now.addingTimeInterval(0.5))
    let unchanged = try monitor.poll(at: now.addingTimeInterval(1))
    let expired = try monitor.poll(at: now.addingTimeInterval(2))

    #expect(initial?.signal == signal)
    #expect(tooSoon == nil)
    #expect(unchanged == nil)
    #expect(expired?.signal == nil)
  }

  @Test("one poll publishes the inbox revision, signal, and ignored counters")
  func publishesWholeInboxResult() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_296_100)
    let store = IdleScreenAgentSignalStore(
      fileURL: root.appending(path: "inbox-v1.json")
    )
    _ = try store.apply(.recordIgnored(provider: .claude), at: now)
    var monitor = IdleScreenAgentSignalMonitor(store: store)

    let change = try monitor.poll(at: now)

    #expect(change?.inboxRevision == 1)
    #expect(change?.signal == nil)
    #expect(change?.ignoredEventCounts == [.claude: 1])
  }

  @Test("a failed read consumes the polling interval and stays throttled")
  func failedReadConsumesInterval() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let fileURL = root.appending(path: "inbox-v1.json")
    try Data("not json".utf8).write(to: fileURL)
    let now = Date(timeIntervalSince1970: 1_786_296_200)
    var monitor = IdleScreenAgentSignalMonitor(
      store: IdleScreenAgentSignalStore(fileURL: fileURL),
      pollingInterval: 10
    )

    #expect(throws: (any Error).self) {
      _ = try monitor.poll(at: now)
    }
    let inbox = IdleScreenAgentSignalInbox(
      revision: 7,
      updatedAt: now,
      ignoredEventCounts: [.codex: 2]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(inbox).write(to: fileURL)

    let beforeDeadline = try monitor.poll(at: now.addingTimeInterval(9))
    let retried = try monitor.poll(at: now.addingTimeInterval(10))

    #expect(beforeDeadline == nil)
    #expect(retried?.inboxRevision == 7)
    #expect(retried?.ignoredEventCounts == [.codex: 2])
  }

  @Test("repeated failed reads stay throttled to the polling interval")
  func repeatedFailuresStayThrottled() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let fileURL = root.appending(path: "inbox-v1.json")
    try Data("not json".utf8).write(to: fileURL)
    let now = Date(timeIntervalSince1970: 1_786_296_300)
    var monitor = IdleScreenAgentSignalMonitor(
      store: IdleScreenAgentSignalStore(fileURL: fileURL),
      pollingInterval: 10
    )

    for step in [0.0, 10, 20] {
      #expect(throws: (any Error).self) {
        _ = try monitor.poll(at: now.addingTimeInterval(step))
      }
      #expect(!monitor.canPoll(at: now.addingTimeInterval(step + 9)))
      #expect(monitor.canPoll(at: now.addingTimeInterval(step + 10)))
      let throttled = try monitor.poll(at: now.addingTimeInterval(step + 5))
      #expect(throttled == nil)
    }
  }

  @Test("a transient failure republishes the identical signal at the next scheduled poll")
  func republishesAfterTransientFailure() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_296_400)
    let fileURL = root.appending(path: "inbox-v1.json")
    let store = IdleScreenAgentSignalStore(fileURL: fileURL)
    let signal = try IdleScreenAgentSignal.validated(
      provider: .codex,
      sessionID: "session-1",
      eventID: "event-1",
      state: .needsAttention,
      title: "Codex",
      message: nil,
      temporaryLookID: nil,
      priority: 0,
      createdAt: now,
      expiresAt: now.addingTimeInterval(120),
      acknowledgedAt: nil,
      nonce: "nonce-1",
      validatedAt: now
    )
    _ = try store.apply(.set(signal), at: now)
    let healthy = try Data(contentsOf: fileURL)
    var monitor = IdleScreenAgentSignalMonitor(store: store, pollingInterval: 1)

    let first = try monitor.poll(at: now)
    try Data("not json".utf8).write(to: fileURL)
    #expect(throws: (any Error).self) {
      _ = try monitor.poll(at: now.addingTimeInterval(1))
    }
    try healthy.write(to: fileURL)
    let beforeDeadline = try monitor.poll(at: now.addingTimeInterval(1.5))
    let republished = try monitor.poll(at: now.addingTimeInterval(2))
    let unchanged = try monitor.poll(at: now.addingTimeInterval(3))

    #expect(first?.signal == signal)
    #expect(beforeDeadline == nil)
    #expect(republished?.signal == signal)
    #expect(republished?.inboxRevision == first?.inboxRevision)
    #expect(unchanged == nil)
  }

  @Test("the polling interval is clamped to its bounds")
  func clampsPollingInterval() throws {
    let now = Date(timeIntervalSince1970: 1_786_296_500)
    let empty = IdleScreenAgentSignalInbox()
    let minimum = IdleScreenAgentSignalMonitor.minimumPollingInterval
    let maximum = IdleScreenAgentSignalMonitor.maximumPollingInterval

    var tiny = IdleScreenAgentSignalMonitor(pollingInterval: 0)
    _ = tiny.consume(empty, at: now)
    #expect(!tiny.canPoll(at: now.addingTimeInterval(minimum - 0.01)))
    #expect(tiny.canPoll(at: now.addingTimeInterval(minimum)))

    var negative = IdleScreenAgentSignalMonitor(pollingInterval: -5)
    _ = negative.consume(empty, at: now)
    #expect(negative.canPoll(at: now.addingTimeInterval(minimum)))
    #expect(!negative.canPoll(at: now))

    var huge = IdleScreenAgentSignalMonitor(pollingInterval: 3_600)
    _ = huge.consume(empty, at: now)
    #expect(!huge.canPoll(at: now.addingTimeInterval(maximum - 0.01)))
    #expect(huge.canPoll(at: now.addingTimeInterval(maximum)))

    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    var stored = IdleScreenAgentSignalMonitor(
      store: IdleScreenAgentSignalStore(fileURL: root.appending(path: "inbox-v1.json")),
      pollingInterval: 3_600
    )
    _ = try stored.poll(at: now)
    #expect(!stored.canPoll(at: now.addingTimeInterval(maximum - 0.01)))
    #expect(stored.canPoll(at: now.addingTimeInterval(maximum)))
  }

  @Test("a revision bump publishes even when the active signal is unchanged")
  func revisionBumpWithoutSignalChange() throws {
    let now = Date(timeIntervalSince1970: 1_786_296_600)
    let signal = try IdleScreenAgentSignal.validated(
      provider: .codex, sessionID: "session-1", eventID: "event-1",
      state: .working, title: nil, message: nil, temporaryLookID: nil, priority: 0,
      createdAt: now, expiresAt: now.addingTimeInterval(600), acknowledgedAt: nil,
      nonce: "nonce-1", validatedAt: now)
    var monitor = IdleScreenAgentSignalMonitor(pollingInterval: 1)
    var inbox = IdleScreenAgentSignalInbox(revision: 1, updatedAt: now)
    inbox.signals = [signal]

    let first = monitor.consume(inbox, at: now)
    let same = monitor.consume(inbox, at: now.addingTimeInterval(1))
    inbox.revision = 2
    inbox.ignoredEventCounts = [.claude: 3]
    let bumped = monitor.consume(inbox, at: now.addingTimeInterval(2))
    let settled = monitor.consume(inbox, at: now.addingTimeInterval(3))

    #expect(first?.inboxRevision == 1)
    #expect(same == nil)
    #expect(bumped?.inboxRevision == 2)
    #expect(bumped?.signal == signal)
    #expect(bumped?.ignoredEventCounts == [.claude: 3])
    #expect(settled == nil)
  }
}
