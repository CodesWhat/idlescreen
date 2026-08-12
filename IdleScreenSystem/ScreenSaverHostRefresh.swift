import Darwin
import Foundation

public protocol ScreenSaverHostRefreshing: Sendable {
    func refresh() throws
}

/// Refreshes the per-user macOS screen-saver host after PlugInKit has
/// converged on a newly registered extension. The target is resolved by exact
/// uid and executable path immediately before signalling; broad process-name
/// termination is deliberately avoided.
public struct ScreenSaverHostRefreshClient: ScreenSaverHostRefreshing, Sendable {
    public enum Error: LocalizedError, Equatable {
        case commandFailed(CommandRequest, CommandResult)
        case invalidAppleSignature(identifier: String?, cdHash: String?)
        case wallpaperAgentCount(Int)
        case wallpaperAgentIdentityChanged(expectedPID: Int32, actualPIDs: [Int32])
        case wallpaperAgentRelaunchTimedOut(previousPID: Int32)

        public var errorDescription: String? {
            switch self {
            case let .commandFailed(request, result):
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "\(request.executable) exited with status \(result.exitCode)."
                    : "\(request.executable) exited with status \(result.exitCode): \(detail)"
            case let .invalidAppleSignature(identifier, cdHash):
                return "WallpaperAgent did not have the expected Apple identity "
                    + "(identifier: \(identifier ?? "missing"), "
                    + "CDHash: \(cdHash ?? "missing"))."
            case let .wallpaperAgentCount(count):
                return "Expected exactly one current-user Apple WallpaperAgent, found \(count)."
            case let .wallpaperAgentIdentityChanged(expectedPID, actualPIDs):
                let actual = actualPIDs.map(String.init).joined(separator: ", ")
                return "WallpaperAgent changed before the guarded refresh "
                    + "(expected PID \(expectedPID), found \(actual.isEmpty ? "none" : actual))."
            case let .wallpaperAgentRelaunchTimedOut(previousPID):
                return "WallpaperAgent did not relaunch with a new PID after refreshing PID \(previousPID)."
            }
        }
    }

    private struct CodeIdentity: Equatable {
        let identifier: String
        let cdHash: String
    }

    private static let executablePath =
        "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
    private static let signingIdentifier = "com.apple.wallpaper.agent"

    private let commandRunner: any CommandRunning
    private let currentUserIdentifier: Int
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(
        commandRunner: any CommandRunning = FoundationCommandRunner(),
        currentUserIdentifier: Int = Int(Darwin.getuid()),
        timeout: TimeInterval = 15,
        pollInterval: TimeInterval = 0.1
    ) {
        self.commandRunner = commandRunner
        self.currentUserIdentifier = currentUserIdentifier
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func refresh() throws {
        let expectedCodeIdentity = try wallpaperAgentCodeIdentity()
        let initialPIDs = try currentUserWallpaperAgentPIDs()
        guard initialPIDs.count == 1, let previousPID = initialPIDs.first else {
            throw Error.wallpaperAgentCount(initialPIDs.count)
        }

        // Resolve uid + executable again immediately before TERM. If the PID
        // changed between observations, fail closed instead of signalling it.
        let guardedPIDs = try currentUserWallpaperAgentPIDs()
        guard guardedPIDs == [previousPID] else {
            throw Error.wallpaperAgentIdentityChanged(
                expectedPID: previousPID,
                actualPIDs: guardedPIDs
            )
        }

        try perform(
            CommandRequest(
                executable: "/bin/kill",
                arguments: ["-TERM", String(previousPID)]
            )
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let currentPIDs = try currentUserWallpaperAgentPIDs()
            if currentPIDs.count > 1 {
                throw Error.wallpaperAgentCount(currentPIDs.count)
            }
            if let currentPID = currentPIDs.first, currentPID != previousPID {
                let currentCodeIdentity = try wallpaperAgentCodeIdentity()
                guard currentCodeIdentity == expectedCodeIdentity else {
                    throw Error.invalidAppleSignature(
                        identifier: currentCodeIdentity.identifier,
                        cdHash: currentCodeIdentity.cdHash
                    )
                }
                return
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        throw Error.wallpaperAgentRelaunchTimedOut(previousPID: previousPID)
    }

    private func currentUserWallpaperAgentPIDs() throws -> [Int32] {
        let result = try perform(
            CommandRequest(
                executable: "/bin/ps",
                arguments: ["-ww", "-axo", "pid=,uid=,comm="]
            )
        )

        return result.output
            .split(whereSeparator: \Character.isNewline)
            .compactMap { line -> Int32? in
                let fields = line.split(
                    maxSplits: 2,
                    omittingEmptySubsequences: true,
                    whereSeparator: \Character.isWhitespace
                )
                guard fields.count == 3,
                      Int(fields[1]) == currentUserIdentifier,
                      fields[2] == Self.executablePath else {
                    return nil
                }
                return Int32(fields[0])
            }
            .sorted()
    }

    private func wallpaperAgentCodeIdentity() throws -> CodeIdentity {
        let result = try perform(
            CommandRequest(
                executable: "/usr/bin/codesign",
                arguments: ["-dvvv", Self.executablePath]
            )
        )
        let lines = result.output.split(whereSeparator: \Character.isNewline)
        let identifier = lines.first(where: { $0.hasPrefix("Identifier=") })
            .map { String($0.dropFirst("Identifier=".count)) }
        let cdHash = lines.first(where: { $0.hasPrefix("CDHash=") })
            .map { String($0.dropFirst("CDHash=".count)) }
        guard let identifier,
              identifier == Self.signingIdentifier,
              let cdHash,
              cdHash.range(of: "^[0-9a-fA-F]{40,64}$", options: .regularExpression) != nil else {
            throw Error.invalidAppleSignature(identifier: identifier, cdHash: cdHash)
        }
        return CodeIdentity(identifier: identifier, cdHash: cdHash.lowercased())
    }

    @discardableResult
    private func perform(_ request: CommandRequest) throws -> CommandResult {
        let result = try commandRunner.run(request)
        guard result.exitCode == 0 else {
            throw Error.commandFailed(request, result)
        }
        return result
    }
}
