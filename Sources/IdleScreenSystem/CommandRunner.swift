import Darwin
import Foundation

public struct CommandRequest: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) throws -> CommandResult
}

public struct FoundationCommandRunner: CommandRunning {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case timedOut(executable: String, timeout: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case let .timedOut(executable, timeout):
                "Command \(executable) timed out after \(timeout) seconds."
            }
        }
    }

    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval

    public init(
        timeout: TimeInterval = 15,
        terminationGracePeriod: TimeInterval = 1
    ) {
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 15
        self.terminationGracePeriod = terminationGracePeriod.isFinite
            && terminationGracePeriod > 0
            ? terminationGracePeriod
            : 1
    }

    public func run(_ request: CommandRequest) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments

        let outputURL = FileManager.default.temporaryDirectory.appending(
            path: "idlescreen-command-\(UUID().uuidString).output"
        )
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw POSIXError(.EIO)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputHandle = try FileHandle(forUpdating: outputURL)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        try process.run()
        if termination.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if termination.wait(
                timeout: .now() + terminationGracePeriod
            ) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw Error.timedOut(
                executable: request.executable,
                timeout: timeout
            )
        }

        try outputHandle.seek(toOffset: 0)
        let outputData = try outputHandle.readToEnd() ?? Data()

        return CommandResult(
            exitCode: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self)
        )
    }
}
