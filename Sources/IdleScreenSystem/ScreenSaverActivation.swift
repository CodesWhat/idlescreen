import Foundation

public struct ScreenSaverActivationClient: Sendable {
    public enum Error: LocalizedError, Equatable {
        case commandFailed(CommandRequest, CommandResult)
        case notSelected(expected: String, providers: [String])

        public var errorDescription: String? {
            switch self {
            case let .commandFailed(request, result):
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "\(request.executable) exited with status \(result.exitCode)."
                    : detail
            case let .notSelected(expected, providers):
                let current = providers.isEmpty ? "no readable screen saver" : providers.joined(separator: ", ")
                return "Select \(expected) in Screen Saver Settings before starting it. Current: \(current)."
            }
        }
    }

    private let commandRunner: any CommandRunning

    public init(commandRunner: any CommandRunning = FoundationCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func startCurrentScreenSaver() throws {
        try perform(
            CommandRequest(
                executable: "/usr/bin/open",
                arguments: ["-a", "ScreenSaverEngine"]
            )
        )
    }

    public func startIdleScreen(selection: ScreenSaverSelectionReport) throws {
        guard selection.isSelectedEverywhere else {
            throw Error.notSelected(
                expected: selection.expectedBundleIdentifier,
                providers: selection.providers
            )
        }
        try startCurrentScreenSaver()
    }

    public func openScreenSaverSettings() throws {
        try perform(
            CommandRequest(
                executable: "/usr/bin/open",
                arguments: ["x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"]
            )
        )
    }

    private func perform(_ request: CommandRequest) throws {
        let result = try commandRunner.run(request)
        guard result.exitCode == 0 else {
            throw Error.commandFailed(request, result)
        }
    }
}
