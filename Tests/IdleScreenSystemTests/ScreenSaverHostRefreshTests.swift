import Foundation
import Testing
@testable import IdleScreenSystem

@Suite("Screen saver host refresh")
struct ScreenSaverHostRefreshTests {
    @Test("a PID change before TERM fails closed without signalling")
    func rejectsPIDChangeBeforeTerm() {
        let runner = HostRefreshCommandRunner(results: [
            identityResult(hash: String(repeating: "a", count: 40)),
            processResult([101]),
            processResult([202]),
        ])
        let client = makeClient(runner: runner)

        #expect(
            throws: ScreenSaverHostRefreshClient.Error.wallpaperAgentIdentityChanged(
                expectedPID: 101,
                actualPIDs: [202]
            )
        ) {
            try client.refresh()
        }
        #expect(!runner.commands.contains { $0.executable == "/bin/kill" })
    }

    @Test("a changed relaunch signature is rejected after TERM")
    func rejectsChangedRelaunchIdentity() {
        let newHash = String(repeating: "b", count: 40)
        let runner = HostRefreshCommandRunner(results: [
            identityResult(hash: String(repeating: "a", count: 40)),
            processResult([101]),
            processResult([101]),
            .success,
            processResult([202]),
            identityResult(hash: newHash),
        ])
        let client = makeClient(runner: runner)

        #expect(
            throws: ScreenSaverHostRefreshClient.Error.invalidAppleSignature(
                identifier: "com.apple.wallpaper.agent",
                cdHash: newHash
            )
        ) {
            try client.refresh()
        }
        #expect(runner.commands.filter { $0.executable == "/bin/kill" }.count == 1)
    }

    @Test("multiple matching processes are rejected before TERM")
    func rejectsMultipleProcessesBeforeTerm() {
        let runner = HostRefreshCommandRunner(results: [
            identityResult(hash: String(repeating: "a", count: 40)),
            processResult([101, 202]),
        ])
        let client = makeClient(runner: runner)

        #expect(throws: ScreenSaverHostRefreshClient.Error.wallpaperAgentCount(2)) {
            try client.refresh()
        }
        #expect(!runner.commands.contains { $0.executable == "/bin/kill" })
    }

    @Test("multiple relaunched processes are rejected after one guarded TERM")
    func rejectsMultipleProcessesAfterTerm() {
        let runner = HostRefreshCommandRunner(results: [
            identityResult(hash: String(repeating: "a", count: 40)),
            processResult([101]),
            processResult([101]),
            .success,
            processResult([202, 303]),
        ])
        let client = makeClient(runner: runner)

        #expect(throws: ScreenSaverHostRefreshClient.Error.wallpaperAgentCount(2)) {
            try client.refresh()
        }
        #expect(runner.commands.filter { $0.executable == "/bin/kill" }.count == 1)
    }

    @Test("a relaunch timeout signals the original PID exactly once")
    func relaunchTimeoutSignalsOnce() {
        let runner = HostRefreshCommandRunner(results: [
            identityResult(hash: String(repeating: "a", count: 40)),
            processResult([101]),
            processResult([101]),
            .success,
        ])
        let client = makeClient(runner: runner, timeout: 0)

        #expect(
            throws: ScreenSaverHostRefreshClient.Error.wallpaperAgentRelaunchTimedOut(
                previousPID: 101
            )
        ) {
            try client.refresh()
        }
        #expect(
            runner.commands.filter { $0.executable == "/bin/kill" } == [
                .init(executable: "/bin/kill", arguments: ["-TERM", "101"]),
            ]
        )
    }

    @Test("a new PID with the same normalized identity completes refresh")
    func acceptsSameIdentityRelaunch() throws {
        let uppercaseHash = String(repeating: "A", count: 40)
        let lowercaseHash = String(repeating: "a", count: 40)
        let runner = HostRefreshCommandRunner(results: [
            identityResult(hash: uppercaseHash),
            processResult([101]),
            processResult([101]),
            .success,
            processResult([202]),
            identityResult(hash: lowercaseHash),
        ])
        let client = makeClient(runner: runner)

        try client.refresh()

        #expect(runner.remainingResultCount == 0)
        #expect(runner.commands.map(\.executable) == [
            "/usr/bin/codesign",
            "/bin/ps",
            "/bin/ps",
            "/bin/kill",
            "/bin/ps",
            "/usr/bin/codesign",
        ])
    }

    private func makeClient(
        runner: HostRefreshCommandRunner,
        timeout: TimeInterval = 1
    ) -> ScreenSaverHostRefreshClient {
        ScreenSaverHostRefreshClient(
            commandRunner: runner,
            currentUserIdentifier: 501,
            timeout: timeout,
            pollInterval: 0
        )
    }

    private func identityResult(hash: String) -> CommandResult {
        .init(
            exitCode: 0,
            output: "Identifier=com.apple.wallpaper.agent\nCDHash=\(hash)\n"
        )
    }

    private func processResult(_ pids: [Int32]) -> CommandResult {
        let executable =
            "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
        return .init(
            exitCode: 0,
            output: pids.map { "\($0) 501 \(executable)" }.joined(separator: "\n")
        )
    }
}

private final class HostRefreshCommandRunner: CommandRunning, @unchecked Sendable {
    private enum RunnerError: Error {
        case exhausted
    }

    private var results: [CommandResult]
    private(set) var commands: [CommandRequest] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    var remainingResultCount: Int { results.count }

    func run(_ request: CommandRequest) throws -> CommandResult {
        commands.append(request)
        guard !results.isEmpty else { throw RunnerError.exhausted }
        return results.removeFirst()
    }
}

private extension CommandResult {
    static let success = CommandResult(exitCode: 0, output: "")
}
