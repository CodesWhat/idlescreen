import Foundation
import Testing
@testable import IdleScreenAgent
@testable import IdleScreenCore

@Suite("idlescreenctl command execution")
struct CommandExecutorTests {
    private static let testDate = Date(timeIntervalSince1970: 1_786_295_958)

    @Test("a hook updates the inbox with no companion process")
    func hookWritesInbox() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IdleScreenSharedPaths(rootURL: root)
        var configuration = IdleScreenConfiguration.default
        configuration.agentIntegration.codexEnabled = true
        try IdleScreenConfigurationStore(fileURL: paths.configurationURL)
            .write(configuration)
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "session-1",
            "turn_id": "turn-1",
            "tool_input": "private tool parameters",
        ])
        let executor = IdleScreenAgentCommandExecutor(
            sharedPaths: paths,
            now: { Date(timeIntervalSince1970: 1_786_295_958) },
            nonce: { "nonce-1" }
        )

        let result = executor.run(
            arguments: ["hook", "--provider", "codex"],
            standardInput: payload
        )
        let inbox = try IdleScreenAgentSignalStore(
            fileURL: paths.agentSignalsInboxURL
        ).read(at: Date(timeIntervalSince1970: 1_786_295_958))
        let stored = try #require(inbox.signals.first)
        let persisted = try String(
            contentsOf: paths.agentSignalsInboxURL,
            encoding: .utf8
        )

        #expect(result == .success)
        #expect(stored.state == .needsAttention)
        #expect(!persisted.contains("private tool parameters"))
    }

    @Test("manual status sanitizes explicit text and clear-all is immediate")
    func manualStatusAndClear() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IdleScreenSharedPaths(rootURL: root)
        let executor = IdleScreenAgentCommandExecutor(
            sharedPaths: paths,
            now: { Date(timeIntervalSince1970: 1_786_295_958) },
            nonce: { "nonce-2" }
        )

        #expect(executor.run(arguments: [
            "status", "--provider", "claude", "--session", "manual-1",
            "--state", "done", "--title", "**Finished**",
            "--message", "safe\u{001B}[31m message", "--timeout", "45",
        ], standardInput: Data()) == .success)
        var inbox = try IdleScreenAgentSignalStore(
            fileURL: paths.agentSignalsInboxURL
        ).read(at: Date(timeIntervalSince1970: 1_786_295_958))
        #expect(inbox.signals.first?.title == "Finished")
        #expect(inbox.signals.first?.message == "safe message")

        #expect(executor.run(
            arguments: ["clear-all"],
            standardInput: Data()
        ) == .success)
        inbox = try IdleScreenAgentSignalStore(
            fileURL: paths.agentSignalsInboxURL
        ).read(at: Date(timeIntervalSince1970: 1_786_295_959))
        #expect(inbox.signals.isEmpty)
    }

    @Test("command grammar rejects unknown and malformed arguments")
    func commandGrammar() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let usageCases: [[String]] = [
            [],
            ["unknown"],
            ["hook"],
            ["hook", "--provider", "codex", "--unknown", "value"],
            ["hook", "--provider", "codex", "--installation", "other"],
            ["hook", "--", "value"],
            ["hook", "--provider"],
            ["hook", "--provider", "codex", "--provider", "claude"],
            ["status", "--provider", "other", "--session", "session", "--state", "done"],
            ["status", "--provider", "codex", "--state", "done"],
            ["status", "--provider", "codex", "--session", "", "--state", "done"],
            ["status", "--provider", "codex", "--session", "session", "--state", "idle"],
            ["status", "--provider", "codex", "--session", "session", "--state", "other"],
            ["status", "--provider", "codex", "--session", "session", "--state", "done", "--timeout", "nan"],
            ["status", "--provider", "codex", "--session", "session", "--state", "done", "--priority", "high"],
            ["status", "--provider", "codex", "--session", "session", "--state", "done", "--priority", "101"],
            ["status", "--provider", "codex", "--session", "session", "--state", "done", "--look", "not-a-uuid"],
            ["status", "--provider", "codex", "--session", "session", "--state", "done", "--unknown", "value"],
            ["clear", "--provider", "codex"],
            ["clear", "--provider", "codex", "--session", ""],
            ["clear", "--provider", "codex", "--session", "bad session"],
            ["clear", "--provider", "codex", "--session", String(repeating: "a", count: 129)],
            ["clear", "--provider", "codex", "--session", "session", "--unknown", "value"],
            ["clear-all", "unexpected"],
        ]

        for arguments in usageCases {
            #expect(
                executor.run(arguments: arguments, standardInput: Data()) == .usage,
                "expected usage for \(arguments)"
            )
        }
    }

    @Test("hook input and provider opt-out map to stable result codes")
    func hookResultCodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IdleScreenSharedPaths(rootURL: root)
        let executor = makeExecutor(root: root)

        #expect(executor.run(
            arguments: [
                "hook", "--provider", "codex",
                "--installation", "idlescreen-v1",
            ],
            standardInput: Data("not-json".utf8)
        ) == .success)

        var configuration = IdleScreenConfiguration.default
        configuration.agentIntegration.codexEnabled = true
        try IdleScreenConfigurationStore(fileURL: paths.configurationURL)
            .write(configuration)

        let malformedCases = [
            Data("not-json".utf8),
            Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8),
            Self.hookPayload(
                byteCount: IdleScreenAgentHookAdapter.maximumPayloadByteCount + 1
            ),
        ]
        for input in malformedCases {
            #expect(executor.run(
                arguments: ["hook", "--provider", "codex"],
                standardInput: input
            ) == .malformedInput)
        }

        #expect(executor.run(
            arguments: [
                "hook", "--provider", "codex",
                "--installation", "idlescreen-v1",
            ],
            standardInput: Self.hookPayload(
                byteCount: IdleScreenAgentHookAdapter.maximumPayloadByteCount
            )
        ) == .success)
    }

    @Test("valid manual options and storage failures map deterministically")
    func manualOptionAndStorageResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let lookID = UUID()

        #expect(executor.run(arguments: [
            "status", "--provider", "codex", "--session", "session",
            "--state", "working", "--look", lookID.uuidString,
            "--priority", "100", "--timeout", "1",
        ], standardInput: Data()) == .success)
        let inbox = try IdleScreenAgentSignalStore(
            fileURL: IdleScreenSharedPaths(rootURL: root).agentSignalsInboxURL
        ).read(at: Self.testDate)
        #expect(inbox.signals.first?.temporaryLookID == lookID)
        #expect(inbox.signals.first?.priority == 100)
        #expect(inbox.signals.first?.expiresAt.timeIntervalSince(Self.testDate) == 15)

        let fileRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileRoot) }
        try Data("not-a-directory".utf8).write(to: fileRoot)
        #expect(makeExecutor(root: fileRoot).run(arguments: [
            "status", "--provider", "codex", "--session", "session",
            "--state", "done",
        ], standardInput: Data()) == .storageFailure)
    }

    private func makeExecutor(root: URL) -> IdleScreenAgentCommandExecutor {
        IdleScreenAgentCommandExecutor(
            sharedPaths: IdleScreenSharedPaths(rootURL: root),
            now: { Self.testDate },
            nonce: { "test-nonce" }
        )
    }

    private static func hookPayload(byteCount: Int) -> Data {
        let prefix = Data(
            #"{"hook_event_name":"PermissionRequest","session_id":"boundary","padding":""#.utf8
        )
        let suffix = Data(#""}"#.utf8)
        precondition(byteCount >= prefix.count + suffix.count)
        var payload = prefix
        payload.append(Data(
            repeating: 0x61,
            count: byteCount - prefix.count - suffix.count
        ))
        payload.append(suffix)
        return payload
    }
}
