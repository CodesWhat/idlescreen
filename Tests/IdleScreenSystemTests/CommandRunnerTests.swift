import Foundation
import Testing
@testable import IdleScreenSystem

@Suite("Foundation command runner")
struct CommandRunnerTests {
    @Test("a completed subprocess returns merged output and exit status")
    func subprocessOutput() throws {
        let runner = FoundationCommandRunner(timeout: 1)

        let result = try runner.run(CommandRequest(
            executable: "/bin/sh",
            arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"]
        ))

        #expect(result.exitCode == 7)
        #expect(result.output.contains("stdout"))
        #expect(result.output.contains("stderr"))
    }

    @Test("a subprocess that exceeds its deadline is terminated")
    func subprocessTimeout() {
        let runner = FoundationCommandRunner(timeout: 0.05)
        let startedAt = Date()

        do {
            _ = try runner.run(CommandRequest(
                executable: "/bin/sleep",
                arguments: ["5"]
            ))
            Issue.record("Expected the subprocess to time out")
        } catch let error as FoundationCommandRunner.Error {
            #expect(error == .timedOut(
                executable: "/bin/sleep",
                timeout: 0.05
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test("a subprocess timeout explains the failed command and deadline")
    func subprocessTimeoutDescription() {
        let error = FoundationCommandRunner.Error.timedOut(
            executable: "/usr/bin/example-tool",
            timeout: 2.5
        )

        #expect(error.localizedDescription.contains("/usr/bin/example-tool"))
        #expect(error.localizedDescription.contains("2.5"))
        #expect(error.localizedDescription.localizedCaseInsensitiveContains("timed out"))
    }
}
