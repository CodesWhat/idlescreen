import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Per-process health contract")
struct HealthContractTests {
  @Test("process kinds recognize only their expected executable names")
  func executableIdentity() {
    #expect(
      IdleScreenProcessKind.companionApp.matchesExecutablePath(
        "/Applications/IdleScreen.app/Contents/MacOS/IdleScreen"
      )
    )
    #expect(
      IdleScreenProcessKind.screenSaverExtension.matchesExecutablePath(
        "/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
      )
    )
    #expect(!IdleScreenProcessKind.screenSaverExtension.matchesExecutablePath("/bin/sleep"))
    #expect(!IdleScreenProcessKind.companionApp.matchesExecutablePath(""))
  }

  @Test(
    "preferred extension health keeps a live animating display ahead of a later detached sibling")
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
      build: .init(
        version: "0.1", buildNumber: "12", bundleIdentifier: "com.idlescreen.app.dev.screensaver"),
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
      build: .init(
        version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.dev.screensaver"),
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
      build: .init(
        version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.screensaver"),
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
      build: .init(
        version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.screensaver"),
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
      build: .init(
        version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.app.screensaver"),
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
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "screenSaverExtension-2001-display-2.json").path))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "screenSaverExtension-2001-display-3.json").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appending(path: "screenSaverExtension-2001.json").path))
  }

  private func retentionReport(
    _ process: IdleScreenProcessKind,
    pid: Int32,
    instance: String? = nil,
    at seconds: TimeInterval,
    lifecycle: IdleScreenLifecyclePhase = .detached
  ) -> IdleScreenProcessHealth {
    IdleScreenProcessHealth(
      process: process,
      processIdentifier: pid,
      instanceIdentifier: instance,
      lifecycle: lifecycle,
      build: .init(version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.tests"),
      updatedAt: Date(timeIntervalSince1970: seconds),
      issue: nil
    )
  }

  private func retentionDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  @Test("retention bounds history per process kind and keeps protected live reports")
  func retentionBoundsHistory() throws {
    let directory = retentionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenHealthStore(directoryURL: directory)

    var protected: Set<String> = []
    for index in 0..<100 {
      try store.write(
        retentionReport(
          .screenSaverExtension, pid: Int32(10_000 + index), instance: "view",
          at: 1_000 + Double(index)))
    }
    for index in 0..<70 {
      try store.write(
        retentionReport(.cameraAgent, pid: Int32(20_000 + index), at: 1_000 + Double(index)))
    }
    // Old live view reports that the age ordering alone would prune.
    for display in 0..<3 {
      let live = retentionReport(
        .screenSaverExtension, pid: 5, instance: "display-\(display)",
        at: 1, lifecycle: .animating)
      try store.write(live)
      protected.insert(live.reportIdentifier)
    }

    let result = try store.enforceRetention(protecting: protected)
    let kept = try store.readAll()
    #expect(kept == result.retained)

    let extensionReports = kept.filter { $0.process == .screenSaverExtension }
    let history = extensionReports.filter { !protected.contains($0.reportIdentifier) }
    #expect(history.count == IdleScreenHealthStore.historicalReportLimit)
    #expect(extensionReports.count == 64 + 3)
    // The newest 64 (indexes 36..<100) survive; the oldest are gone.
    #expect(
      history.compactMap(\.processIdentifier).sorted() == (36..<100).map { Int32(10_000 + $0) })
    #expect(protected.isSubset(of: Set(kept.map(\.reportIdentifier))))
    #expect(kept.filter { $0.process == .cameraAgent }.count == 64)
    #expect(result.removedReportIdentifiers.count == 36 + 6)

    // Idempotent.
    #expect(try store.enforceRetention(protecting: protected).removedReportIdentifiers.isEmpty)
  }

  @Test("retention breaks updatedAt ties by filename")
  func retentionTieBreak() throws {
    let directory = retentionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenHealthStore(directoryURL: directory)
    for pid in 1...5 {
      try store.write(retentionReport(.companionApp, pid: Int32(pid), at: 50))
    }
    try store.enforceRetention(historicalLimitPerProcess: 2)
    #expect(try store.readAll().map(\.processIdentifier) == [1, 2])
  }

  @Test("repeated writes to one identity replace the report")
  func repeatedWritesReplace() throws {
    let directory = retentionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenHealthStore(directoryURL: directory)
    for tick in 0..<10 {
      try store.write(
        retentionReport(.screenSaverExtension, pid: 9, instance: "v", at: Double(tick)))
    }
    let reports = try store.readAll()
    #expect(reports.count == 1)
    #expect(reports.first?.updatedAt == Date(timeIntervalSince1970: 9))
  }

  @Test("background publication returns while the directory lock is held and keeps order")
  func backgroundWriteDoesNotWaitOnTheLock() throws {
    let directory = retentionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenHealthStore(directoryURL: directory, lockTimeout: 0.1)
    try store.write(retentionReport(.companionApp, pid: 7, instance: "i", at: 0))
    let descriptor = open(directory.path, O_RDONLY)
    #expect(descriptor >= 0)
    #expect(flock(descriptor, LOCK_EX) == 0)

    let started = ContinuousClock.now
    for tick in 1...5 {
      store.writeInBackground(
        retentionReport(.companionApp, pid: 7, instance: "i", at: Double(tick)))
    }
    #expect(ContinuousClock.now - started < .milliseconds(250), "the caller waited on the lock")

    flock(descriptor, LOCK_UN)
    close(descriptor)
    IdleScreenHealthStore.drainBackgroundWrites()
    #expect(try store.readAll().first?.updatedAt == Date(timeIntervalSince1970: 5))
  }

  @Test("retention never removes unrecognized files")
  func retentionIgnoresUnrecognizedFiles() throws {
    let directory = retentionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenHealthStore(directoryURL: directory)
    try store.write(retentionReport(.companionApp, pid: 1, at: 1))
    try store.write(retentionReport(.companionApp, pid: 2, at: 2))
    let renamed = retentionReport(.companionApp, pid: 3, at: 0)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let stray = directory.appending(path: "backup-of-report.json")
    try encoder.encode(renamed).write(to: stray)
    let corrupt = directory.appending(path: "companionApp-corrupt.json")
    try Data("{nope".utf8).write(to: corrupt)
    let notes = directory.appending(path: "notes.txt")
    try Data("hi".utf8).write(to: notes)

    try store.enforceRetention(historicalLimitPerProcess: 0)

    #expect(FileManager.default.fileExists(atPath: stray.path))
    #expect(FileManager.default.fileExists(atPath: corrupt.path))
    #expect(FileManager.default.fileExists(atPath: notes.path))
    #expect(try store.readAll().map(\.processIdentifier) == [3])
  }

  @Test("a report refreshed while retention runs survives pruning")
  func concurrentRefreshSurvivesPruning() throws {
    let directory = retentionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenHealthStore(directoryURL: directory)
    for pid in 1...5 {
      try store.write(retentionReport(.cameraAgent, pid: Int32(pid), at: Double(pid)))
    }
    // pid 1 is the oldest and selected for removal; it is rewritten first.
    let refreshed = retentionReport(.cameraAgent, pid: 1, at: 99)
    let result = try store.enforceRetention(
      classifyingLive: { _ in [] },
      historicalLimitPerProcess: 4,
      beforeRemoving: { _ in try? store.write(refreshed) }
    )

    #expect(result.removedReportIdentifiers.isEmpty)
    #expect(try store.readAll().contains(refreshed))
  }

  @Test("a report published between inspection and removal is kept")
  func reportPublishedAfterInspectionSurvives() throws {
    let directory = retentionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenHealthStore(directoryURL: directory, lockTimeout: 0.05)
    for pid in 1...3 {
      try store.write(retentionReport(.cameraAgent, pid: Int32(pid), at: Double(pid)))
    }
    let fresh = retentionReport(.cameraAgent, pid: 50, at: 99)
    let rewritten = retentionReport(.cameraAgent, pid: 1, at: 100)
    let result = try store.enforceRetention(
      classifyingLive: { _ in
        // Published after the inspection the classifier and pruner share.
        try? store.write(fresh)
        return []
      },
      historicalLimitPerProcess: 0,
      beforeRemoving: { url in
        if url.lastPathComponent == "cameraAgent-1.json" { try? store.write(rewritten) }
      }
    )

    let kept = try store.readAll()
    #expect(kept.contains(fresh))
    #expect(kept.contains(rewritten))
    #expect(!result.removedReportIdentifiers.contains("cameraAgent-1"))
    #expect(!result.removedReportIdentifiers.contains("cameraAgent-50"))
  }

  @Test("retention skips pruning when the directory lock is held")
  func retentionSkipsWhenLockHeld() throws {
    let directory = retentionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenHealthStore(directoryURL: directory, lockTimeout: 0.05)
    for pid in 1...4 {
      try store.write(retentionReport(.companionApp, pid: Int32(pid), at: Double(pid)))
    }
    let descriptor = open(directory.path, O_RDONLY)
    #expect(descriptor >= 0)
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

    let result = try store.enforceRetention(
      classifyingLive: { _ in ["companionApp-4"] },
      historicalLimitPerProcess: 0
    )
    // A write still publishes while the lock is contended.
    let late = retentionReport(.companionApp, pid: 9, at: 9)
    try store.write(late)
    flock(descriptor, LOCK_UN)
    close(descriptor)

    #expect(result.skippedPruning)
    #expect(result.removedReportIdentifiers.isEmpty)
    #expect(result.retained.count == 4)
    #expect(result.liveReportIdentifiers == ["companionApp-4"])
    #expect(try store.readAll().count == 5)

    let after = try store.enforceRetention(historicalLimitPerProcess: 0)
    #expect(!after.skippedPruning)
    #expect(after.retained.isEmpty)
  }
}
