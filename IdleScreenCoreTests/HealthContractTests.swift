import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Per-process health contract")
struct HealthContractTests {
    @Test("process kinds recognize only their expected executable names")
    func executableIdentity() {
        #expect(
            IdleScreenProcessKind.companionApp.matchesExecutablePath(
                "/Applications/idlescreen.app/Contents/MacOS/IdleScreen"
            )
        )
        #expect(
            IdleScreenProcessKind.screenSaverExtension.matchesExecutablePath(
                "/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
            )
        )
        #expect(!IdleScreenProcessKind.screenSaverExtension.matchesExecutablePath("/bin/sleep"))
        #expect(!IdleScreenProcessKind.companionApp.matchesExecutablePath(""))
    }

    @Test("preferred extension health keeps a live animating display ahead of a later detached sibling")
    func preferredLiveDisplayHealth() {
        let build = IdleScreenBuildIdentity(
            version: "0.1",
            buildNumber: "1",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        )
        let animating = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 4242,
            instanceIdentifier: "display-2",
            displayIdentifier: 2,
            lifecycle: .animating,
            build: build,
            updatedAt: Date(timeIntervalSince1970: 100),
            issue: nil
        )
        let detached = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 4242,
            instanceIdentifier: "display-3",
            displayIdentifier: 3,
            lifecycle: .detached,
            build: build,
            updatedAt: Date(timeIntervalSince1970: 101),
            issue: nil
        )

        #expect(
            IdleScreenHealthSelection.preferredReport(
                for: .screenSaverExtension,
                in: [animating, detached],
                liveReportIdentifiers: [animating.reportIdentifier, detached.reportIdentifier]
            ) == animating
        )
        #expect(
            IdleScreenHealthSelection.preferredReport(
                for: .screenSaverExtension,
                in: [animating, detached],
                liveReportIdentifiers: []
            ) == detached
        )
    }

    @Test("a reused PID cannot make a stale view report live")
    func exactReportLiveness() {
        let build = IdleScreenBuildIdentity(
            version: "0.1",
            buildNumber: "1",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        )
        let staleAnimating = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 4242,
            instanceIdentifier: "stale-view",
            displayIdentifier: 2,
            lifecycle: .animating,
            build: build,
            updatedAt: Date(timeIntervalSince1970: 100),
            issue: nil
        )
        let currentDetached = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 4242,
            instanceIdentifier: "current-view",
            displayIdentifier: 3,
            lifecycle: .detached,
            build: build,
            updatedAt: Date(timeIntervalSince1970: 101),
            issue: nil
        )

        #expect(
            IdleScreenHealthSelection.preferredReport(
                for: .screenSaverExtension,
                in: [staleAnimating, currentDetached],
                liveReportIdentifiers: [currentDetached.reportIdentifier]
            ) == currentDetached
        )
    }

    @Test("health predating the current process lifetime is stale")
    func processLifetimeIdentity() {
        let report = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 4242,
            instanceIdentifier: "view-a",
            lifecycle: .animating,
            build: .init(
                version: "0.1",
                buildNumber: "1",
                bundleIdentifier: "com.idlescreen.app.screensaver"
            ),
            updatedAt: Date(timeIntervalSince1970: 100),
            issue: nil
        )

        #expect(report.couldBelongToProcess(startedAt: Date(timeIntervalSince1970: 99.5)))
        #expect(report.couldBelongToProcess(startedAt: Date(timeIntervalSince1970: 101)))
        #expect(!report.couldBelongToProcess(startedAt: Date(timeIntervalSince1970: 102)))
    }

    @Test("health reports retain process and build identity")
    func identity() {
        let report = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 4242,
            instanceIdentifier: "view-a",
            displayIdentifier: 2,
            lifecycle: .animating,
            build: .init(version: "0.1", buildNumber: "12", bundleIdentifier: "com.idlescreen.app.dev.screensaver"),
            updatedAt: Date(timeIntervalSince1970: 1_785_525_109),
            configurationRevision: 42,
            issue: nil
        )

        #expect(report.process == .screenSaverExtension)
        #expect(report.schemaVersion == 2)
        #expect(report.processIdentifier == 4242)
        #expect(report.instanceIdentifier == "view-a")
        #expect(report.displayIdentifier == 2)
        #expect(report.reportIdentifier == "screenSaverExtension-4242-view-a")
        #expect(report.lifecycle == .animating)
        #expect(report.build.bundleIdentifier.hasSuffix(".screensaver"))
        #expect(report.configurationRevision == 42)
        #expect(report.issue == nil)
        #expect(report.isLive(activeProcessIdentifiers: [4242]))
        #expect(!report.isLive(activeProcessIdentifiers: [9999]))
    }

    @Test("schema-one reports without a configuration revision remain readable")
    func legacyReportCompatibility() throws {
        let json = """
        {
          "schemaVersion": 1,
          "process": "screenSaverExtension",
          "lifecycle": "animating",
          "build": {
            "version": "0.1",
            "buildNumber": "1",
            "bundleIdentifier": "com.idlescreen.app.dev.screensaver"
          },
          "updatedAt": "2026-07-31T20:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let report = try decoder.decode(IdleScreenProcessHealth.self, from: Data(json.utf8))

        #expect(report.configurationRevision == nil)
        #expect(report.processIdentifier == nil)
        #expect(!report.isLive(activeProcessIdentifiers: [4242]))
    }

    @Test("each process publishes a separately readable health report")
    func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IdleScreenHealthStore(directoryURL: directory)
        let app = IdleScreenProcessHealth(
            process: .companionApp,
            processIdentifier: 1001,
            lifecycle: .attached,
            build: .init(version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.dev"),
            updatedAt: Date(timeIntervalSince1970: 1_785_525_109),
            issue: nil
        )
        let extensionReport = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 1002,
            lifecycle: .animating,
            build: .init(version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.dev.screensaver"),
            updatedAt: Date(timeIntervalSince1970: 1_785_525_110),
            issue: nil
        )

        try store.write(app)
        try store.write(extensionReport)

        #expect(try store.readAll() == [app, extensionReport])
    }

    @Test("one malformed health file does not hide valid process reports")
    func malformedReportIsIsolated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IdleScreenHealthStore(directoryURL: directory)
        let validReport = IdleScreenProcessHealth(
            process: .companionApp,
            processIdentifier: 1001,
            lifecycle: .attached,
            build: .init(
                version: "0.1",
                buildNumber: "1",
                bundleIdentifier: "com.idlescreen.app.dev"
            ),
            updatedAt: Date(timeIntervalSince1970: 1_785_525_109),
            issue: nil
        )

        try store.write(validReport)
        try Data("{not-json".utf8).write(
            to: directory.appending(path: "screenSaverExtension-corrupt.json")
        )

        #expect(try store.readAll() == [validReport])
    }

    @Test("a future-schema health file does not hide current process reports")
    func futureReportIsIsolated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IdleScreenHealthStore(directoryURL: directory)
        let validReport = IdleScreenProcessHealth(
            process: .companionApp,
            processIdentifier: 1001,
            lifecycle: .attached,
            build: .init(
                version: "0.1",
                buildNumber: "1",
                bundleIdentifier: "com.idlescreen.app.dev"
            ),
            updatedAt: Date(timeIntervalSince1970: 1_785_525_109),
            issue: nil
        )

        try store.write(validReport)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedReport = try encoder.encode(validReport)
        var futureReport = try #require(
            JSONSerialization.jsonObject(with: encodedReport) as? [String: Any]
        )
        futureReport["schemaVersion"] = IdleScreenProcessHealth.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: futureReport).write(
            to: directory.appending(path: "cameraAgent-future.json")
        )

        #expect(try store.readAll() == [validReport])
    }

    @Test("concurrent views in one extension process retain independent reports")
    func concurrentExtensionViewReports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IdleScreenHealthStore(directoryURL: directory)
        let legacyPerProcess = IdleScreenProcessHealth(
            schemaVersion: 1,
            process: .screenSaverExtension,
            processIdentifier: 2001,
            lifecycle: .animating,
            build: .init(version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.screensaver"),
            updatedAt: Date(timeIntervalSince1970: 1_785_525_108),
            configurationRevision: 11,
            issue: nil
        )
        let detached = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 2001,
            instanceIdentifier: "display-2",
            displayIdentifier: 2,
            lifecycle: .detached,
            build: .init(version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.screensaver"),
            updatedAt: Date(timeIntervalSince1970: 1_785_525_109),
            configurationRevision: 12,
            issue: nil
        )
        let animating = IdleScreenProcessHealth(
            process: .screenSaverExtension,
            processIdentifier: 2001,
            instanceIdentifier: "display-3",
            displayIdentifier: 3,
            lifecycle: .animating,
            build: .init(version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.screensaver"),
            updatedAt: Date(timeIntervalSince1970: 1_785_525_110),
            configurationRevision: 12,
            issue: nil
        )

        try store.write(legacyPerProcess)
        try store.write(detached)
        try store.write(animating)

        let reports = try store.readAll()
        #expect(reports.count == 2)
        #expect(reports.contains(detached))
        #expect(reports.contains(animating))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "screenSaverExtension-2001-display-2.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "screenSaverExtension-2001-display-3.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "screenSaverExtension-2001.json").path))
    }
}
