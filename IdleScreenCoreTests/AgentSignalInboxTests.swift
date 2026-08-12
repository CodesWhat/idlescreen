import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Agent signal inbox", .serialized)
struct AgentSignalInboxTests {
    @Test("a unique event replaces its session while a replay is a no-op")
    func replacesAndDeduplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json")
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let working = try signal(
            eventID: "turn-1",
            state: .working,
            createdAt: now
        )
        let attention = try signal(
            eventID: "turn-2",
            state: .needsAttention,
            createdAt: now.addingTimeInterval(1)
        )

        let first = try store.apply(.set(working), at: now)
        let second = try store.apply(
            .set(attention),
            at: now.addingTimeInterval(1)
        )
        let replay = try store.apply(
            .set(attention),
            at: now.addingTimeInterval(2)
        )

        #expect(first.revision == 1)
        #expect(second.revision == 2)
        #expect(second.signals == [attention])
        #expect(replay == second)
    }

    @Test("clear removes only the addressed provider session and is replay safe")
    func clearsOneSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json")
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let active = try signal(
            eventID: "turn-1",
            state: .working,
            createdAt: now
        )
        _ = try store.apply(.set(active), at: now)

        let cleared = try store.apply(
            .clear(
                provider: .codex,
                sessionID: "session-1",
                eventID: "session-end-1"
            ),
            at: now.addingTimeInterval(1)
        )
        let replay = try store.apply(
            .clear(
                provider: .codex,
                sessionID: "session-1",
                eventID: "session-end-1"
            ),
            at: now.addingTimeInterval(2)
        )

        #expect(cleared.signals.isEmpty)
        #expect(cleared.revision == 2)
        #expect(replay == cleared)
    }

    @Test("concurrent tasks retain one bounded signal per session")
    func concurrentWriters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json")
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let signal = try IdleScreenAgentSignal.validated(
                        provider: index.isMultiple(of: 2) ? .codex : .claude,
                        sessionID: "session-\(index)",
                        eventID: "event-\(index)",
                        state: .working,
                        title: nil,
                        message: nil,
                        temporaryLookID: nil,
                        priority: 0,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(120),
                        acknowledgedAt: nil,
                        nonce: "nonce-\(index)",
                        validatedAt: now
                    )
                    _ = try store.apply(.set(signal), at: now)
                }
            }
            try await group.waitForAll()
        }

        let inbox = try store.read(at: now)
        #expect(inbox.signals.count == 32)
        #expect(inbox.revision == 32)
    }

    @Test("a lock symlink is rejected without opening its target")
    func rejectsLockSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let victimURL = root.appending(path: "victim")
        let victimData = Data("do not open".utf8)
        try victimData.write(to: victimURL)
        let fileURL = root.appending(path: "inbox-v1.json")
        try FileManager.default.createSymbolicLink(
            at: fileURL.appendingPathExtension("lock"),
            withDestinationURL: victimURL
        )
        let store = IdleScreenAgentSignalStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_786_295_958)

        #expect(throws: (any Error).self) {
            _ = try store.apply(
                .set(try signal(eventID: "turn-1", state: .working, createdAt: now)),
                at: now
            )
        }
        #expect(try Data(contentsOf: victimURL) == victimData)
    }

    @Test("process contention stops at the shared monotonic deadline")
    func processContentionTimesOutAtDeadline() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestMonotonicClock(now: 1_000_000_000)
        let processLock = TestProcessLock(clock: clock, availableAt: nil)
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json"),
            clock: clock,
            processLock: processLock
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)

        #expect(throws: IdleScreenAgentSignalStore.StoreError.coordinationTimedOut) {
            _ = try store.apply(
                .set(try signal(eventID: "turn-1", state: .working, createdAt: now)),
                at: now
            )
        }
        #expect(clock.nowNanoseconds() == 1_250_000_000)
        #expect(processLock.attemptCount == 251)
    }

    @Test("a lock acquired exactly at the deadline is accepted")
    func acceptsLockAtDeadline() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestMonotonicClock(now: 2_000_000_000)
        let processLock = TestProcessLock(
            clock: clock,
            availableAt: 2_250_000_000
        )
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json"),
            clock: clock,
            processLock: processLock
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)

        let inbox = try store.apply(
            .set(try signal(eventID: "turn-1", state: .working, createdAt: now)),
            at: now
        )

        #expect(inbox.revision == 1)
        #expect(clock.nowNanoseconds() == 2_250_000_000)
        #expect(processLock.attemptCount == 251)
    }

    @Test("a process lock acquired after the deadline is rejected")
    func rejectsProcessLockAcquiredAfterDeadline() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestMonotonicClock(now: 4_000_000_000)
        let processLock = OvershootingProcessLock(
            clock: clock,
            acquisitionDelay: 251_000_000
        )
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json"),
            clock: clock,
            processLock: processLock
        )

        #expect(throws: IdleScreenAgentSignalStore.StoreError.coordinationTimedOut) {
            _ = try store.apply(
                .clearAll,
                at: Date(timeIntervalSince1970: 1_786_295_958)
            )
        }
        #expect(clock.nowNanoseconds() == 4_251_000_000)
        #expect(processLock.unlockCount == 1)
    }

    @Test("a file lock acquired after the deadline is released and rejected")
    func rejectsFileLockAcquiredAfterDeadline() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ScriptedMonotonicClock(values: [
            5_000_000_000,
            5_000_000_000,
            5_000_000_000,
            5_000_000_000,
            5_251_000_000,
        ])
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json"),
            clock: clock,
            processLock: TestProcessLock.alwaysAvailable()
        )

        #expect(throws: IdleScreenAgentSignalStore.StoreError.coordinationTimedOut) {
            _ = try store.apply(
                .clearAll,
                at: Date(timeIntervalSince1970: 1_786_295_958)
            )
        }
        #expect(clock.nowNanoseconds() == 5_251_000_000)
    }

    @Test("a foreign lock holder times out, then a later mutation recovers")
    func foreignHolderTimesOutThenRecovers() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        let store = IdleScreenAgentSignalStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        _ = try store.apply(.clearAll, at: now)
        let worker = try launchWorker([
            "hold-lock",
            fileURL.appendingPathExtension("lock").path
        ])
        defer { stop(worker) }
        #expect(try worker.output.read(upToCount: 1) == Data([0x52]))

        let startedAt = ProcessInfo.processInfo.systemUptime
        #expect(throws: IdleScreenAgentSignalStore.StoreError.coordinationTimedOut) {
            _ = try store.apply(.recordIgnored(provider: .codex), at: now)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        #expect(elapsed >= 0.2)
        #expect(elapsed < 1)

        try worker.input.write(contentsOf: Data([0x47]))
        try worker.input.close()
        worker.process.waitUntilExit()
        #expect(worker.process.terminationStatus == 0)
        let recovered = try store.apply(
            .recordIgnored(provider: .codex),
            at: now.addingTimeInterval(1)
        )
        #expect(recovered.ignoredEventCounts[.codex] == 1)
    }

    @Test("file contention receives only the process gate's remaining deadline")
    func fileLockUsesRemainingDeadline() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        _ = try IdleScreenAgentSignalStore(fileURL: fileURL).apply(.clearAll, at: now)
        let worker = try launchWorker([
            "hold-lock",
            fileURL.appendingPathExtension("lock").path
        ])
        defer { stop(worker) }
        #expect(try worker.output.read(upToCount: 1) == Data([0x52]))
        let clock = TestMonotonicClock(now: 3_000_000_000)
        let processLock = TestProcessLock(
            clock: clock,
            availableAt: 3_200_000_000
        )
        let store = IdleScreenAgentSignalStore(
            fileURL: fileURL,
            clock: clock,
            processLock: processLock
        )

        #expect(throws: IdleScreenAgentSignalStore.StoreError.coordinationTimedOut) {
            _ = try store.apply(.recordIgnored(provider: .codex), at: now)
        }
        #expect(clock.nowNanoseconds() == 3_250_000_000)
        #expect(processLock.attemptCount == 201)
    }

    @Test("pipe-synchronized processes preserve every mutation")
    func processesPreserveEveryMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        let workers = try (0..<8).map { index in
            try launchWorker(["apply-set", fileURL.path, String(index)])
        }
        defer { workers.forEach(stop) }
        for worker in workers {
            #expect(try worker.output.read(upToCount: 1) == Data([0x52]))
        }
        for worker in workers {
            try worker.input.write(contentsOf: Data([0x47]))
            try worker.input.close()
        }
        for worker in workers {
            worker.process.waitUntilExit()
            #expect(worker.process.terminationStatus == 0)
        }

        let inbox = try IdleScreenAgentSignalStore(fileURL: fileURL).read(
            at: Date(timeIntervalSince1970: 1_786_295_958)
        )
        #expect(inbox.revision == 8)
        #expect(inbox.signals.count == 8)
        #expect(inbox.recentEvents.count == 8)
    }

    @Test("a malformed primary recovers the prior complete atomic snapshot")
    func recoversPreviousSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        let store = IdleScreenAgentSignalStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let first = try signal(
            eventID: "turn-1",
            state: .working,
            createdAt: now
        )
        let second = try signal(
            eventID: "turn-2",
            state: .done,
            createdAt: now.addingTimeInterval(1)
        )
        let prior = try store.apply(.set(first), at: now)
        _ = try store.apply(.set(second), at: now.addingTimeInterval(1))
        try Data("{broken".utf8).write(to: fileURL, options: .atomic)

        let recovered = try store.read(at: now.addingTimeInterval(2))

        #expect(recovered == prior)
    }

    @Test("fallback recovery emits one redacted reason")
    func reportsRedactedFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        let diagnostics = DiagnosticRecorder()
        let store = IdleScreenAgentSignalStore(
            fileURL: fileURL,
            clock: TestMonotonicClock(now: 0),
            processLock: TestProcessLock.alwaysAvailable(),
            diagnosticSink: diagnostics.record
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let prior = try store.apply(
            .set(try signal(eventID: "turn-1", state: .working, createdAt: now)),
            at: now
        )
        _ = try store.apply(
            .set(try signal(
                eventID: "turn-2",
                state: .done,
                createdAt: now.addingTimeInterval(1)
            )),
            at: now.addingTimeInterval(1)
        )
        let secret = "secret-session-at-\(root.path)"
        try Data("{broken \(secret)".utf8).write(to: fileURL, options: .atomic)

        let recovered = try store.read(at: now.addingTimeInterval(2))

        #expect(recovered == prior)
        #expect(diagnostics.values == [.recoveredPrevious(.malformedPayload)])
        #expect(!String(describing: diagnostics.values).contains(secret))
        #expect(!String(describing: diagnostics.values).contains(root.path))
    }

    @Test("private publication atomically replaces a mode-0600 inode")
    func atomicallyPublishesPrivateSnapshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        let store = IdleScreenAgentSignalStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        _ = try store.apply(
            .set(try signal(eventID: "turn-1", state: .working, createdAt: now)),
            at: now
        )
        let oldHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? oldHandle.close() }
        let oldBytes = try oldHandle.readToEnd() ?? Data()

        _ = try store.apply(
            .set(try signal(
                eventID: "turn-2",
                state: .done,
                createdAt: now.addingTimeInterval(1)
            )),
            at: now.addingTimeInterval(1)
        )
        try oldHandle.seek(toOffset: 0)

        #expect(try oldHandle.readToEnd() == oldBytes)
        #expect(try Data(contentsOf: fileURL) != oldBytes)
        #expect(try permissions(at: fileURL) == 0o600)
        #expect(try permissions(at: fileURL.appendingPathExtension("previous")) == 0o600)
    }

    @Test("the inbox and recovery files are private to the current user")
    func privateFileModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        let store = IdleScreenAgentSignalStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        _ = try store.apply(
            .set(try signal(eventID: "turn-1", state: .working, createdAt: now)),
            at: now
        )
        _ = try store.apply(
            .set(try signal(
                eventID: "turn-2",
                state: .done,
                createdAt: now.addingTimeInterval(1)
            )),
            at: now.addingTimeInterval(1)
        )

        #expect(try permissions(at: root) == 0o700)
        #expect(try permissions(at: fileURL) == 0o600)
        #expect(try permissions(at: fileURL.appendingPathExtension("previous")) == 0o600)
        #expect(try permissions(at: fileURL.appendingPathExtension("lock")) == 0o600)
    }

    @Test("ignored hook events retain only a bounded provider counter")
    func recordsIgnoredEventWithoutPayload() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        let store = IdleScreenAgentSignalStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_786_295_958)

        let first = try store.apply(
            .recordIgnored(provider: .claude),
            at: now
        )
        let second = try store.apply(
            .recordIgnored(provider: .claude),
            at: now.addingTimeInterval(1)
        )
        let payload = try String(contentsOf: fileURL, encoding: .utf8)

        #expect(first.ignoredEventCounts[.claude] == 1)
        #expect(first.signals.isEmpty)
        #expect(second.ignoredEventCounts[.claude] == 2)
        #expect(!payload.contains("hook payload"))
        #expect(!payload.contains("event name"))
        #expect(!payload.contains("session-1"))
        #expect(!payload.contains("unknown-1"))
    }

    @Test("acknowledgement suppresses an unacknowledged completion")
    func acknowledgesCompletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json")
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        _ = try store.apply(
            .set(try signal(eventID: "turn-1", state: .done, createdAt: now)),
            at: now
        )

        let acknowledged = try store.apply(
            .acknowledge(
                provider: .codex,
                sessionID: "session-1",
                eventID: "ack-1"
            ),
            at: now.addingTimeInterval(1)
        )

        #expect(acknowledged.signals.first?.acknowledgedAt == now.addingTimeInterval(1))
        #expect(IdleScreenAgentSignalArbitrator.activeSignal(
            in: acknowledged.signals,
            at: now.addingTimeInterval(1)
        ) == nil)
    }

    @Test("emergency clear removes every provider session")
    func clearsAllSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json")
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        _ = try store.apply(
            .set(try signal(eventID: "turn-1", state: .working, createdAt: now)),
            at: now
        )
        let claude = try IdleScreenAgentSignal.validated(
            provider: .claude,
            sessionID: "claude-session",
            eventID: "claude-turn",
            state: .needsAttention,
            title: nil,
            message: nil,
            temporaryLookID: nil,
            priority: 0,
            createdAt: now,
            expiresAt: now.addingTimeInterval(120),
            acknowledgedAt: nil,
            nonce: "claude-nonce",
            validatedAt: now
        )
        _ = try store.apply(.set(claude), at: now)

        let cleared = try store.apply(.clearAll, at: now.addingTimeInterval(1))

        #expect(cleared.signals.isEmpty)
        #expect(cleared.revision == 3)
    }

    @Test("a one-hundred-event storm remains bounded and deterministic")
    func boundsEventStorm() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdleScreenAgentSignalStore(
            fileURL: root.appending(path: "inbox-v1.json")
        )
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        for index in 0..<100 {
            let signal = try IdleScreenAgentSignal.validated(
                provider: index.isMultiple(of: 2) ? .codex : .claude,
                sessionID: "session-\(index)",
                eventID: "event-\(index)",
                state: index == 99 ? .needsAttention : .working,
                title: nil,
                message: nil,
                temporaryLookID: nil,
                priority: 0,
                createdAt: now.addingTimeInterval(Double(index) / 100),
                expiresAt: now.addingTimeInterval(120),
                acknowledgedAt: nil,
                nonce: "nonce-\(index)",
                validatedAt: now.addingTimeInterval(1)
            )
            _ = try store.apply(.set(signal), at: now.addingTimeInterval(1))
        }

        let inbox = try store.read(at: now.addingTimeInterval(2))
        #expect(inbox.revision == 100)
        #expect(inbox.signals.count == IdleScreenAgentSignalStore.maximumSignalCount)
        #expect(inbox.recentEvents.count == 100)
        #expect(IdleScreenAgentSignalArbitrator.activeSignal(
            in: inbox.signals,
            at: now.addingTimeInterval(2)
        )?.sessionID == "session-99")
    }

    @Test("a persisted signal beyond bounded clock skew is ignored")
    func rejectsFuturePersistedSignal() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "inbox-v1.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_786_295_958)
        let future = now.addingTimeInterval(3_600)
        let signal = try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: "future-session",
            eventID: "future-event",
            state: .needsAttention,
            title: nil,
            message: nil,
            temporaryLookID: nil,
            priority: 100,
            createdAt: future,
            expiresAt: future.addingTimeInterval(120),
            acknowledgedAt: nil,
            nonce: "future-nonce",
            validatedAt: future
        )
        let inbox = IdleScreenAgentSignalInbox(
            revision: 1,
            updatedAt: future,
            signals: [signal]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(inbox).write(to: fileURL)

        let read = try IdleScreenAgentSignalStore(fileURL: fileURL).read(at: now)

        #expect(read.signals.isEmpty)
    }

    @Test("an oversized inbox fails before decoding")
    func rejectsOversizedInbox() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appending(path: "inbox-v1.json")
        try Data(
            repeating: 0x20,
            count: IdleScreenAgentSignalStore.maximumInboxByteCount + 1
        ).write(to: fileURL)

        #expect(throws: IdleScreenAgentSignalStore.StoreError.payloadTooLarge) {
            try IdleScreenAgentSignalStore(fileURL: fileURL).read(at: Date())
        }
    }

    private func signal(
        eventID: String,
        state: IdleScreenAgentSignalState,
        createdAt: Date
    ) throws -> IdleScreenAgentSignal {
        try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: "session-1",
            eventID: eventID,
            state: state,
            title: nil,
            message: nil,
            temporaryLookID: nil,
            priority: 0,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(120),
            acknowledgedAt: nil,
            nonce: "nonce-\(eventID)",
            validatedAt: createdAt
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int) & 0o777
    }

    private func launchWorker(_ arguments: [String]) throws -> StoreWorkerProcess {
        let executableURL = Bundle(for: AgentSignalStoreWorkerBundleToken.self)
            .bundleURL
            .deletingLastPathComponent()
            .appending(path: "idlescreen-store-test-worker")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return StoreWorkerProcess(
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading
        )
    }

    private func stop(_ worker: StoreWorkerProcess) {
        if worker.process.isRunning {
            try? worker.input.write(contentsOf: Data([0x58]))
            try? worker.input.close()
            worker.process.terminate()
            worker.process.waitUntilExit()
        }
    }
}

private final class AgentSignalStoreWorkerBundleToken: NSObject {}

private struct StoreWorkerProcess {
    let process: Process
    let input: FileHandle
    let output: FileHandle
}

private final class TestMonotonicClock:
    IdleScreenAgentSignalStoreMonotonicClock,
    @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(now: UInt64) {
        value = now
    }

    func nowNanoseconds() -> UInt64 {
        lock.withLock { value }
    }

    func sleep(nanoseconds: UInt64) {
        lock.withLock {
            value &+= nanoseconds
        }
    }
}

private final class TestProcessLock:
    IdleScreenAgentSignalStoreProcessLocking,
    @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TestMonotonicClock?
    private let availableAt: UInt64?
    private var attempts = 0

    init(clock: TestMonotonicClock?, availableAt: UInt64?) {
        self.clock = clock
        self.availableAt = availableAt
    }

    static func alwaysAvailable() -> TestProcessLock {
        TestProcessLock(clock: nil, availableAt: 0)
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func tryLock() -> Bool {
        lock.withLock {
            attempts += 1
            guard let availableAt else { return false }
            return (clock?.nowNanoseconds() ?? availableAt) >= availableAt
        }
    }

    func unlock() {}
}

private final class OvershootingProcessLock:
    IdleScreenAgentSignalStoreProcessLocking,
    @unchecked Sendable {
    private let clock: TestMonotonicClock
    private let acquisitionDelay: UInt64
    private let lock = NSLock()
    private var unlocks = 0

    init(clock: TestMonotonicClock, acquisitionDelay: UInt64) {
        self.clock = clock
        self.acquisitionDelay = acquisitionDelay
    }

    var unlockCount: Int {
        lock.withLock { unlocks }
    }

    func tryLock() -> Bool {
        clock.sleep(nanoseconds: acquisitionDelay)
        return true
    }

    func unlock() {
        lock.withLock {
            unlocks += 1
        }
    }
}

private final class ScriptedMonotonicClock:
    IdleScreenAgentSignalStoreMonotonicClock,
    @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var lastValue: UInt64

    init(values: [UInt64]) {
        precondition(!values.isEmpty)
        self.values = values
        lastValue = values[0]
    }

    func nowNanoseconds() -> UInt64 {
        lock.withLock {
            guard !values.isEmpty else { return lastValue }
            lastValue = values.removeFirst()
            return lastValue
        }
    }

    func sleep(nanoseconds: UInt64) {
        lock.withLock {
            lastValue &+= nanoseconds
        }
    }
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IdleScreenAgentSignalStore.Diagnostic] = []

    var values: [IdleScreenAgentSignalStore.Diagnostic] {
        lock.withLock { storage }
    }

    func record(_ diagnostic: IdleScreenAgentSignalStore.Diagnostic) {
        lock.withLock {
            storage.append(diagnostic)
        }
    }
}
