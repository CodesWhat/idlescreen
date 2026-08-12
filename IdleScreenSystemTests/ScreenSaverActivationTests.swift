import Testing
@testable import IdleScreenSystem

@Suite("Screen saver activation adapter")
struct ScreenSaverActivationTests {
    @Test("start launches the system ScreenSaverEngine")
    func start() throws {
        let runner = ActivationCommandRunner()
        let client = ScreenSaverActivationClient(commandRunner: runner)
        let selection = ScreenSaverSelectionReport(
            expectedBundleIdentifier: "com.idlescreen.app.dev.screensaver",
            providers: ["com.idlescreen.app.dev.screensaver"]
        )

        try client.startIdleScreen(selection: selection)

        #expect(runner.requests == [
            .init(executable: "/usr/bin/open", arguments: ["-a", "ScreenSaverEngine"])
        ])
    }

    @Test("start refuses to launch a different selected screen saver")
    func refusesDifferentSelection() {
        let runner = ActivationCommandRunner()
        let client = ScreenSaverActivationClient(commandRunner: runner)
        let selection = ScreenSaverSelectionReport(
            expectedBundleIdentifier: "com.idlescreen.app.dev.screensaver",
            providers: ["com.apple.wallpaper.choice.aerials"]
        )

        #expect(
            throws: ScreenSaverActivationClient.Error.notSelected(
                expected: "com.idlescreen.app.dev.screensaver",
                providers: ["com.apple.wallpaper.choice.aerials"]
            )
        ) {
            try client.startIdleScreen(selection: selection)
        }
        #expect(runner.requests.isEmpty)
    }

    @Test("settings opens the macOS 26 Wallpaper and Screen Saver pane")
    func settings() throws {
        let runner = ActivationCommandRunner()
        let client = ScreenSaverActivationClient(commandRunner: runner)

        try client.openScreenSaverSettings()

        #expect(runner.requests == [
            .init(
                executable: "/usr/bin/open",
                arguments: ["x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"]
            )
        ])
    }
}

private final class ActivationCommandRunner: CommandRunning, @unchecked Sendable {
    private(set) var requests: [CommandRequest] = []

    func run(_ request: CommandRequest) throws -> CommandResult {
        requests.append(request)
        return CommandResult(exitCode: 0, output: "")
    }
}
