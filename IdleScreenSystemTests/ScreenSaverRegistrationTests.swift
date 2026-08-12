import Foundation
import Testing
@testable import IdleScreenSystem

@Suite("Screen saver registration adapter")
struct ScreenSaverRegistrationTests {
    private let bundleIdentifier = "com.idlescreen.app.dev.screensaver"

    @Test("pluginkit output resolves an exact registration")
    func parsesRegistration() {
        let output = """
             com.apple.Flurry(1.0)\tF66199DC\t/System/Library/ExtensionKit/Extensions/Flurry.appex
        +    com.idlescreen.app.dev.screensaver(0.1)\tABCD1234\t2026-07-31 19:20:00 +0000\t/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex
         (2 plug-ins)
        """

        let status = ScreenSaverRegistrationParser.parse(output, bundleIdentifier: bundleIdentifier)

        #expect(status.isRegistered)
        #expect(status.version == "0.1")
        #expect(status.path == "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex")
    }

    @Test("a bundle identifier prefix is not treated as this extension")
    func rejectsPrefixCollision() {
        let output = "com.idlescreen.app.dev.screensaver.backup(0.1)\tUUID\t/tmp/Backup.appex"

        #expect(
            ScreenSaverRegistrationParser.parse(output, bundleIdentifier: bundleIdentifier)
                == .notRegistered
        )
    }

    @Test("all pluginkit election markers are parsed as registrations")
    func parsesEveryElectionMarker() {
        let paths = [
            "/tmp/use.appex",
            "/tmp/ignore.appex",
            "/tmp/debug.appex",
            "/tmp/superseded.appex",
            "/tmp/unknown.appex"
        ]
        let markers = ["+", "-", "!", "=", "?"]
        let output = zip(markers, paths)
            .map { marker, path in
                "\(marker) \(bundleIdentifier)(0.1)\tUUID\t\(path)"
            }
            .joined(separator: "\n")

        let registrations = ScreenSaverRegistrationParser.parseAll(
            output,
            bundleIdentifier: bundleIdentifier
        )

        #expect(registrations.compactMap(\.path) == paths)
    }

    @Test("a pluginkit query failure is not reported as an absent registration")
    func reportsQueryFailure() {
        let runner = QueueCommandRunner(results: [
            .init(exitCode: 71, output: "plugin registry unavailable")
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        #expect(throws: ScreenSaverRegistrationClient.Error.commandFailed(
            executable: "/usr/bin/pluginkit",
            exitCode: 71,
            output: "plugin registry unavailable"
        )) {
            try client.status()
        }
    }

    @Test("register returns the status observed after pluginkit accepts the extension")
    func registersAndRequeries() throws {
        let extensionURL = URL(fileURLWithPath: "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex")
        let runner = QueueCommandRunner(results: [
            .init(exitCode: 0, output: ""),
            .init(
                exitCode: 0,
                output: "com.idlescreen.app.dev.screensaver(0.1)\tUUID\t\(extensionURL.path)"
            )
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        let status = try client.register(extensionAt: extensionURL)

        #expect(status.isRegistered)
        #expect(status.path == extensionURL.path)
        #expect(runner.commands == [
            .init(executable: "/usr/bin/pluginkit", arguments: ["-a", extensionURL.path]),
            .init(executable: "/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.screensaver"])
        ])
    }

    @Test("assessment identifies the embedded extension as the current registration")
    func assessesCurrentBuild() throws {
        let extensionURL = URL(
            fileURLWithPath: "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        )
        let runner = QueueCommandRunner(results: [
            registrationResult(path: extensionURL.path),
            registrationResults(paths: [extensionURL.path])
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        let assessment = try client.assessment(extensionAt: extensionURL)

        #expect(assessment.location == .currentBuild)
        #expect(assessment.isCurrentBuild)
        #expect(!assessment.needsRepair)
        #expect(assessment.registration.path == extensionURL.path)
    }

    @Test("assessment standardizes equivalent extension paths")
    func assessesEquivalentPathAsCurrent() throws {
        let extensionURL = URL(
            fileURLWithPath: "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        )
        let equivalentPath = "/Applications/IdleScreen.app/Contents/PlugIns/../PlugIns/IdleScreenScreenSaver.appex"
        let runner = QueueCommandRunner(results: [
            registrationResult(path: equivalentPath),
            registrationResults(paths: [equivalentPath])
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        let assessment = try client.assessment(extensionAt: extensionURL)

        #expect(assessment.location == .currentBuild)
        #expect(!assessment.needsRepair)
    }

    @Test("assessment resolves the macOS temporary-directory symlink")
    func assessesTemporaryPathAliasAsCurrent() {
        let extensionURL = URL(fileURLWithPath: "/tmp")
        let registration = ScreenSaverRegistrationStatus(
            isRegistered: true,
            version: "0.1",
            path: "/private/tmp"
        )

        let assessment = ScreenSaverRegistrationAssessment(
            registration: registration,
            knownRegistrations: [registration],
            extensionAt: extensionURL
        )

        #expect(assessment.location == .currentBuild)
        #expect(!assessment.needsRepair)
    }

    @Test("assessment identifies a different app copy as stale")
    func assessesDifferentCopy() throws {
        let extensionURL = URL(
            fileURLWithPath: "/DerivedData/Build/Products/Debug/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        )
        let stalePath = "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        let runner = QueueCommandRunner(results: [
            registrationResult(path: stalePath),
            registrationResults(paths: [stalePath])
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        let assessment = try client.assessment(extensionAt: extensionURL)

        #expect(assessment.location == .differentCopy)
        #expect(!assessment.isCurrentBuild)
        #expect(assessment.needsRepair)
        #expect(assessment.registration.path == stalePath)
        #expect(assessment.expectedPath == extensionURL.path)
    }

    @Test("assessment exposes hidden stale copies behind the selected embedded build")
    func assessesHiddenStaleCopy() {
        let extensionURL = URL(
            fileURLWithPath: "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        )
        let current = ScreenSaverRegistrationStatus(
            isRegistered: true,
            version: "0.1",
            path: extensionURL.path
        )
        let stalePath = "/private/tmp/older/IdleScreenScreenSaver.appex"
        let stale = ScreenSaverRegistrationStatus(
            isRegistered: true,
            version: "0.1",
            path: stalePath
        )

        let assessment = ScreenSaverRegistrationAssessment(
            registration: current,
            knownRegistrations: [stale, current],
            extensionAt: extensionURL
        )

        #expect(assessment.location == .differentCopy)
        #expect(assessment.isSelectedBuild)
        #expect(assessment.needsRepair)
        #expect(assessment.stalePaths == [stalePath])
    }

    @Test("repair removes a stale copy, adds the embedded extension, and verifies it")
    func repairsDifferentCopy() throws {
        let extensionURL = URL(
            fileURLWithPath: "/DerivedData/Build/Products/Debug/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        )
        let stalePath = "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        let runner = QueueCommandRunner(results: [
            registrationResult(path: stalePath),
            registrationResults(paths: [stalePath]),
            .init(exitCode: 0, output: ""),
            .init(exitCode: 0, output: ""),
            registrationResult(path: extensionURL.path),
            registrationResults(paths: [extensionURL.path])
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        let assessment = try client.repair(extensionAt: extensionURL)

        #expect(assessment.location == .currentBuild)
        #expect(runner.commands == [
            registrationQuery,
            duplicateRegistrationQuery,
            .init(executable: "/usr/bin/pluginkit", arguments: ["-r", stalePath]),
            .init(executable: "/usr/bin/pluginkit", arguments: ["-a", extensionURL.path]),
            registrationQuery,
            duplicateRegistrationQuery
        ])
    }

    @Test("repair fails explicitly when pluginkit keeps a stale copy")
    func rejectsUnverifiedRepair() throws {
        let extensionURL = URL(
            fileURLWithPath: "/DerivedData/Build/Products/Debug/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        )
        let stalePath = "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        let runner = QueueCommandRunner(results: [
            registrationResult(path: stalePath),
            registrationResults(paths: [stalePath]),
            .init(exitCode: 0, output: ""),
            .init(exitCode: 0, output: ""),
            registrationResult(path: stalePath),
            registrationResults(paths: [stalePath])
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        #expect(throws: ScreenSaverRegistrationClient.Error.registrationPathMismatch(
            expected: extensionURL.path,
            actual: stalePath
        )) {
            try client.repair(extensionAt: extensionURL)
        }
    }

    @Test("repair is idempotent for the currently embedded extension")
    func repairDoesNothingWhenCurrent() throws {
        let extensionURL = URL(
            fileURLWithPath: "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        )
        let runner = QueueCommandRunner(results: [
            registrationResult(path: extensionURL.path),
            registrationResults(paths: [extensionURL.path])
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        let assessment = try client.repair(extensionAt: extensionURL)

        #expect(assessment.location == .currentBuild)
        #expect(runner.commands == [registrationQuery, duplicateRegistrationQuery])
    }

    @Test("repair removes every stale physical instance before adding the embedded extension")
    func repairsEveryPhysicalCopy() throws {
        let extensionURL = URL(
            fileURLWithPath: "/DerivedData/Build/Products/Debug/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        )
        let selectedStalePath = "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        let hiddenStalePath = "/private/tmp/older/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
        let runner = QueueCommandRunner(results: [
            registrationResult(path: selectedStalePath),
            registrationResults(paths: [hiddenStalePath, selectedStalePath]),
            .init(exitCode: 0, output: ""),
            .init(exitCode: 0, output: ""),
            .init(exitCode: 0, output: ""),
            registrationResult(path: extensionURL.path),
            registrationResults(paths: [extensionURL.path])
        ])
        let client = ScreenSaverRegistrationClient(
            bundleIdentifier: bundleIdentifier,
            commandRunner: runner
        )

        let assessment = try client.repair(extensionAt: extensionURL)

        #expect(assessment.location == .currentBuild)
        #expect(runner.commands == [
            registrationQuery,
            duplicateRegistrationQuery,
            .init(executable: "/usr/bin/pluginkit", arguments: ["-r", hiddenStalePath]),
            .init(executable: "/usr/bin/pluginkit", arguments: ["-r", selectedStalePath]),
            .init(executable: "/usr/bin/pluginkit", arguments: ["-a", extensionURL.path]),
            registrationQuery,
            duplicateRegistrationQuery
        ])
    }

    private var registrationQuery: CommandRequest {
        .init(
            executable: "/usr/bin/pluginkit",
            arguments: ["-m", "-v", "-p", "com.apple.screensaver"]
        )
    }

    private var duplicateRegistrationQuery: CommandRequest {
        .init(
            executable: "/usr/bin/pluginkit",
            arguments: ["-m", "-A", "-D", "-v", "-p", "com.apple.screensaver"]
        )
    }

    private func registrationResult(path: String) -> CommandResult {
        .init(
            exitCode: 0,
            output: "com.idlescreen.app.dev.screensaver(0.1)\tUUID\t\(path)"
        )
    }

    private func registrationResults(paths: [String]) -> CommandResult {
        .init(
            exitCode: 0,
            output: paths
                .map { "com.idlescreen.app.dev.screensaver(0.1)\tUUID\t\($0)" }
                .joined(separator: "\n")
        )
    }
}

private final class QueueCommandRunner: CommandRunning, @unchecked Sendable {
    private var results: [CommandResult]
    private(set) var commands: [CommandRequest] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(_ request: CommandRequest) throws -> CommandResult {
        commands.append(request)
        return results.removeFirst()
    }
}
