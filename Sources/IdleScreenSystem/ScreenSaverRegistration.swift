import Foundation

public struct ScreenSaverRegistrationStatus: Equatable, Sendable {
    public var isRegistered: Bool
    public var version: String?
    public var path: String?

    public init(isRegistered: Bool, version: String?, path: String?) {
        self.isRegistered = isRegistered
        self.version = version
        self.path = path
    }

    public static let notRegistered = ScreenSaverRegistrationStatus(
        isRegistered: false,
        version: nil,
        path: nil
    )
}

public enum ScreenSaverRegistrationLocation: Equatable, Sendable {
    case currentBuild
    case differentCopy
    case notRegistered
}

public struct ScreenSaverRegistrationAssessment: Equatable, Sendable {
    public let registration: ScreenSaverRegistrationStatus
    public let knownRegistrations: [ScreenSaverRegistrationStatus]
    public let expectedPath: String
    public let location: ScreenSaverRegistrationLocation

    public init(
        registration: ScreenSaverRegistrationStatus,
        knownRegistrations: [ScreenSaverRegistrationStatus]? = nil,
        extensionAt extensionURL: URL
    ) {
        self.registration = registration
        let standardizedExpectedPath = Self.standardizedPath(extensionURL.path)
        expectedPath = standardizedExpectedPath
        let registrations = knownRegistrations
            ?? (registration.isRegistered ? [registration] : [])
        self.knownRegistrations = registrations

        guard registration.isRegistered || !registrations.isEmpty else {
            location = .notRegistered
            return
        }

        if let registeredPath = registration.path,
           Self.standardizedPath(registeredPath) == standardizedExpectedPath,
           registrations.allSatisfy({ status in
               guard let path = status.path else { return false }
               return Self.standardizedPath(path) == standardizedExpectedPath
           }) {
            location = .currentBuild
        } else {
            location = .differentCopy
        }
    }

    public var isCurrentBuild: Bool { location == .currentBuild }
    public var isSelectedBuild: Bool {
        guard let path = registration.path else { return false }
        return Self.standardizedPath(path) == expectedPath
    }
    public var needsRepair: Bool { !isCurrentBuild }

    public var stalePaths: [String] {
        var seen: Set<String> = []
        return knownRegistrations.compactMap { status in
            guard let path = status.path else { return nil }
            let standardizedPath = Self.standardizedPath(path)
            guard standardizedPath != expectedPath,
                  seen.insert(standardizedPath).inserted else {
                return nil
            }
            return path
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}

enum ScreenSaverRegistrationParser {
    static func parse(_ output: String, bundleIdentifier: String) -> ScreenSaverRegistrationStatus {
        parseAll(output, bundleIdentifier: bundleIdentifier).first ?? .notRegistered
    }

    static func parseAll(_ output: String, bundleIdentifier: String) -> [ScreenSaverRegistrationStatus] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            var entry = line.trimmingCharacters(in: .whitespaces)
            if let marker = entry.first, "+-!=?".contains(marker) {
                entry.removeFirst()
                entry = entry.trimmingCharacters(in: .whitespaces)
            }

            let identityPrefix = bundleIdentifier + "("
            guard entry.hasPrefix(identityPrefix),
                  let closingParenthesis = entry.firstIndex(of: ")") else {
                return nil
            }

            let versionStart = entry.index(entry.startIndex, offsetBy: identityPrefix.count)
            let version = String(entry[versionStart..<closingParenthesis])
            let path = entry
                .split(separator: "\t", omittingEmptySubsequences: true)
                .last
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.hasPrefix("/") ? $0 : nil }

            return ScreenSaverRegistrationStatus(
                isRegistered: true,
                version: version.isEmpty ? nil : version,
                path: path
            )
        }
    }
}

public struct ScreenSaverRegistrationClient: Sendable {
    public enum Error: LocalizedError, Equatable {
        case commandFailed(executable: String, exitCode: Int32, output: String)
        case hostRefreshUnavailable
        case registrationPathMismatch(expected: String, actual: String?)
        case registrationConvergenceTimedOut(expected: String, actual: String?)

        public var errorDescription: String? {
            switch self {
            case let .commandFailed(executable, exitCode, output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "\(executable) exited with status \(exitCode)."
                    : "\(executable) exited with status \(exitCode): \(detail)"
            case .hostRefreshUnavailable:
                return "This build cannot refresh the macOS screen-saver host."
            case let .registrationPathMismatch(expected, actual):
                return "pluginkit did not select the embedded screen saver at \(expected). "
                    + "It reports \(actual ?? "no registered path") instead."
            case let .registrationConvergenceTimedOut(expected, actual):
                return "pluginkit did not converge on the embedded screen saver at \(expected). "
                    + "It last reported \(actual ?? "no registered path") instead."
            }
        }
    }

    private let bundleIdentifier: String
    private let commandRunner: any CommandRunning
    private let hostRefresher: (any ScreenSaverHostRefreshing)?

    public init(
        bundleIdentifier: String,
        commandRunner: any CommandRunning = FoundationCommandRunner(),
        hostRefresher: (any ScreenSaverHostRefreshing)? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.commandRunner = commandRunner
        self.hostRefresher = hostRefresher
    }

    public func status() throws -> ScreenSaverRegistrationStatus {
        let result = try runPlugInKit(
            arguments: ["-m", "-v", "-p", "com.apple.screensaver"]
        )
        return ScreenSaverRegistrationParser.parse(result.output, bundleIdentifier: bundleIdentifier)
    }

    public func registrations() throws -> [ScreenSaverRegistrationStatus] {
        let result = try runPlugInKit(
            arguments: ["-m", "-A", "-D", "-v", "-p", "com.apple.screensaver"]
        )
        return ScreenSaverRegistrationParser.parseAll(
            result.output,
            bundleIdentifier: bundleIdentifier
        )
    }

    public func register(extensionAt extensionURL: URL) throws -> ScreenSaverRegistrationStatus {
        try runPlugInKit(arguments: ["-a", extensionURL.path])
        return try status()
    }

    public func assessment(extensionAt extensionURL: URL) throws -> ScreenSaverRegistrationAssessment {
        let selectedRegistration = try status()
        var knownRegistrations = try registrations()
        if selectedRegistration.isRegistered,
           !knownRegistrations.contains(selectedRegistration) {
            knownRegistrations.append(selectedRegistration)
        }
        return ScreenSaverRegistrationAssessment(
            registration: selectedRegistration,
            knownRegistrations: knownRegistrations,
            extensionAt: extensionURL
        )
    }

    public func repair(extensionAt extensionURL: URL) throws -> ScreenSaverRegistrationAssessment {
        let current = try assessment(extensionAt: extensionURL)
        guard current.needsRepair else { return current }

        for stalePath in current.stalePaths {
            try runPlugInKit(arguments: ["-r", stalePath])
        }
        try runPlugInKit(arguments: ["-a", extensionURL.path])

        let repaired: ScreenSaverRegistrationAssessment
        if let hostRefresher {
            // Do not disturb the live per-user host until PlugInKit has
            // repeatedly confirmed one canonical registration. After the
            // guarded refresh, converge again before reporting success.
            repaired = try waitForCanonicalRegistration(extensionAt: extensionURL)
            try hostRefresher.refresh()
            return try waitForCanonicalRegistration(extensionAt: extensionURL)
        }

        repaired = try assessment(extensionAt: extensionURL)
        guard repaired.isCurrentBuild else {
            throw Error.registrationPathMismatch(
                expected: repaired.expectedPath,
                actual: repaired.registration.path
            )
        }
        return repaired
    }

    /// Explicit recovery for a canonical registration whose already-running
    /// macOS host may still have the previous extension module cached. Unlike
    /// `repair`, this operation deliberately runs even when the path is
    /// already current and must never be called from passive refresh/startup.
    public func forceRepair(extensionAt extensionURL: URL) throws
        -> ScreenSaverRegistrationAssessment {
        guard let hostRefresher else {
            throw Error.hostRefreshUnavailable
        }

        let current = try assessment(extensionAt: extensionURL)
        for stalePath in current.stalePaths {
            try runPlugInKit(arguments: ["-r", stalePath])
        }
        try runPlugInKit(arguments: ["-a", extensionURL.path])

        _ = try waitForCanonicalRegistration(extensionAt: extensionURL)
        try hostRefresher.refresh()
        return try waitForCanonicalRegistration(extensionAt: extensionURL)
    }

    private func waitForCanonicalRegistration(
        extensionAt extensionURL: URL,
        timeout: TimeInterval = 15,
        pollInterval: TimeInterval = 0.1,
        stableObservationTarget: Int = 10
    ) throws -> ScreenSaverRegistrationAssessment {
        let deadline = Date().addingTimeInterval(timeout)
        var stableObservations = 0
        var lastAssessment: ScreenSaverRegistrationAssessment?

        while Date() < deadline {
            let current = try assessment(extensionAt: extensionURL)
            lastAssessment = current
            if current.isCurrentBuild {
                stableObservations += 1
                if stableObservations >= stableObservationTarget {
                    return current
                }
            } else {
                stableObservations = 0
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        throw Error.registrationConvergenceTimedOut(
            expected: ScreenSaverRegistrationAssessment(
                registration: .notRegistered,
                extensionAt: extensionURL
            ).expectedPath,
            actual: lastAssessment?.registration.path
        )
    }

    @discardableResult
    private func runPlugInKit(arguments: [String]) throws -> CommandResult {
        let request = CommandRequest(
            executable: "/usr/bin/pluginkit",
            arguments: arguments
        )
        let result = try commandRunner.run(request)
        guard result.exitCode == 0 else {
            throw Error.commandFailed(
                executable: request.executable,
                exitCode: result.exitCode,
                output: result.output
            )
        }
        return result
    }
}
