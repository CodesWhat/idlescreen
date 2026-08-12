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

    @Test("a failed read does not consume the polling interval")
    func failedReadRetriesImmediately() throws {
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

        let retried = try monitor.poll(at: now)

        #expect(retried?.inboxRevision == 7)
        #expect(retried?.ignoredEventCounts == [.codex: 2])
    }
}
