import Foundation

public enum IdleScreenProcessKind: String, Codable, CaseIterable, Sendable {
  case companionApp
  case screenSaverExtension
  case cameraAgent

  public var expectedExecutableName: String {
    switch self {
    case .companionApp:
      "IdleScreen"
    case .screenSaverExtension:
      "IdleScreenScreenSaver"
    case .cameraAgent:
      "IdleScreenCameraAgent"
    }
  }

  public func matchesExecutablePath(_ executablePath: String) -> Bool {
    guard !executablePath.isEmpty else { return false }
    return URL(fileURLWithPath: executablePath).lastPathComponent == expectedExecutableName
  }
}

public struct IdleScreenBuildIdentity: Codable, Equatable, Sendable {
  public var version: String
  public var buildNumber: String
  public var bundleIdentifier: String

  public init(version: String, buildNumber: String, bundleIdentifier: String) {
    self.version = version
    self.buildNumber = buildNumber
    self.bundleIdentifier = bundleIdentifier
  }
}

public struct IdleScreenProcessHealth: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var process: IdleScreenProcessKind
  public var processIdentifier: Int32?
  public var instanceIdentifier: String?
  public var displayIdentifier: UInt32?
  public var lifecycle: IdleScreenLifecyclePhase
  public var build: IdleScreenBuildIdentity
  public var updatedAt: Date
  public var configurationRevision: UInt64?
  public var issue: String?

  public var reportIdentifier: String {
    guard let processIdentifier else { return process.rawValue }
    if let instanceIdentifier {
      return "\(process.rawValue)-\(processIdentifier)-\(instanceIdentifier)"
    }
    return "\(process.rawValue)-\(processIdentifier)"
  }

  public func isLive(activeProcessIdentifiers: Set<Int32>) -> Bool {
    guard let processIdentifier else { return false }
    return activeProcessIdentifiers.contains(processIdentifier)
  }

  public func couldBelongToProcess(
    startedAt: Date,
    clockResolutionTolerance: TimeInterval = 1
  ) -> Bool {
    updatedAt.addingTimeInterval(clockResolutionTolerance) >= startedAt
  }

  public init(
    schemaVersion: Int = currentSchemaVersion,
    process: IdleScreenProcessKind,
    processIdentifier: Int32? = ProcessInfo.processInfo.processIdentifier,
    instanceIdentifier: String? = nil,
    displayIdentifier: UInt32? = nil,
    lifecycle: IdleScreenLifecyclePhase,
    build: IdleScreenBuildIdentity,
    updatedAt: Date,
    configurationRevision: UInt64? = nil,
    issue: String?
  ) {
    self.schemaVersion = schemaVersion
    self.process = process
    self.processIdentifier = processIdentifier
    self.instanceIdentifier = instanceIdentifier
    self.displayIdentifier = displayIdentifier
    self.lifecycle = lifecycle
    self.build = build
    self.updatedAt = updatedAt
    self.configurationRevision = configurationRevision
    self.issue = issue
  }
}

public enum IdleScreenHealthSelection {
  public static func preferredReport(
    for process: IdleScreenProcessKind,
    in reports: [IdleScreenProcessHealth],
    liveReportIdentifiers: Set<String>
  ) -> IdleScreenProcessHealth? {
    let processReports = reports.filter { $0.process == process }
    let liveReports = processReports.filter {
      liveReportIdentifiers.contains($0.reportIdentifier)
    }
    guard !liveReports.isEmpty else {
      return processReports.max { $0.updatedAt < $1.updatedAt }
    }
    return liveReports.max { lhs, rhs in
      let lhsAnimating = lhs.lifecycle == .animating
      let rhsAnimating = rhs.lifecycle == .animating
      if lhsAnimating != rhsAnimating {
        return !lhsAnimating && rhsAnimating
      }
      return lhs.updatedAt < rhs.updatedAt
    }
  }
}

public struct IdleScreenHealthStore: Sendable {
  public enum Error: Swift.Error, Equatable {
    case unsupportedSchema(Int)
  }

  public let directoryURL: URL
  /// How long a writer or retention waits for the directory lock before
  /// degrading: writers publish anyway, retention skips this round.
  public let lockTimeout: TimeInterval

  public init(directoryURL: URL, lockTimeout: TimeInterval = 0.25) {
    self.directoryURL = directoryURL
    self.lockTimeout = max(0, lockTimeout)
  }

  /// Takes an exclusive `flock` on the health directory, polling without
  /// blocking until `lockTimeout` passes. Returns nil when the lock could not
  /// be taken, so callers can degrade instead of stalling the screen saver.
  private func withDirectoryLock<T>(_ body: () throws -> T) rethrows -> T? {
    let descriptor = open(directoryURL.path, O_RDONLY)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    let deadline = Date().addingTimeInterval(lockTimeout)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { return nil }
      usleep(5_000)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  public func write(_ report: IdleScreenProcessHealth) throws {
    guard report.schemaVersion <= IdleScreenProcessHealth.currentSchemaVersion else {
      throw Error.unsupportedSchema(report.schemaVersion)
    }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    let publish = {
      try data.write(
        to: directoryURL.appending(path: report.reportIdentifier + ".json"),
        options: .atomic
      )
      if report.processIdentifier != nil {
        try? FileManager.default.removeItem(
          at: directoryURL.appending(path: report.process.rawValue + ".json")
        )
      }
      if let processIdentifier = report.processIdentifier,
        report.instanceIdentifier != nil
      {
        try? FileManager.default.removeItem(
          at: directoryURL.appending(
            path: "\(report.process.rawValue)-\(processIdentifier).json"
          )
        )
      }
    }
    // A report must always publish; if the lock is contended past the
    // timeout the write goes ahead unlocked, and retention's byte compare
    // still protects it.
    if try withDirectoryLock(publish) == nil {
      try publish()
    }
  }

  private static let publishQueue = DispatchQueue(
    label: "com.codeswhat.idlescreen.health-publish", qos: .utility)

  /// Publishes from a serial background queue so an interactive caller never waits on the
  /// directory lock. Reports from every caller land in submission order, so a later report can't be
  /// overwritten by an earlier one. `onFailure` and `onComplete` run on that queue; `onComplete`
  /// runs after the write attempt whether it succeeded or failed, so a dependent read can start
  /// once the publication has landed without blocking the caller.
  public func writeInBackground(
    _ report: IdleScreenProcessHealth,
    onFailure: @escaping @Sendable (any Swift.Error) -> Void = { _ in },
    onComplete: @escaping @Sendable () -> Void = {}
  ) {
    let store = self
    Self.publishQueue.async {
      do {
        try store.write(report)
      } catch {
        onFailure(error)
      }
      onComplete()
    }
  }

  /// Blocks until every report queued by `writeInBackground` has been published. For tests and
  /// orderly shutdown, never an interactive path.
  public static func drainBackgroundWrites() {
    publishQueue.sync {}
  }

  public func readAll() throws -> [IdleScreenProcessHealth] {
    try inspectReports().map(\.report)
  }

  /// Reports kept per process kind once the caller's protected reports are set aside.
  public static let historicalReportLimit = 64

  public struct RetentionResult: Equatable, Sendable {
    /// Every readable report still on disk after pruning, ordered by filename.
    public var retained: [IdleScreenProcessHealth]
    public var removedReportIdentifiers: [String]
    /// Identifiers the classifier reported live from the same inspection
    /// retention used. Empty when `enforceRetention(protecting:)` is used.
    public var liveReportIdentifiers: Set<String> = []
    /// True when the directory lock could not be taken in time, so nothing
    /// was pruned this round.
    public var skippedPruning = false
  }

  /// Removes the oldest historical reports so each process kind keeps at most
  /// `historicalLimitPerProcess` of them. Reports named in
  /// `protectedReportIdentifiers` (the caller's live ones) never count toward
  /// the limit and are never removed. History is ordered newest `updatedAt`
  /// first with the filename as a deterministic tie-break. Only files whose
  /// name matches their report identifier are removable, and a file is
  /// removed only while its bytes still match what was inspected, so a
  /// concurrent atomic rewrite survives.
  @discardableResult
  public func enforceRetention(
    protecting protectedReportIdentifiers: Set<String> = [],
    historicalLimitPerProcess: Int = historicalReportLimit
  ) throws -> RetentionResult {
    try enforceRetention(
      classifyingLive: { _ in protectedReportIdentifiers },
      historicalLimitPerProcess: historicalLimitPerProcess,
      beforeRemoving: { _ in }
    )
  }

  /// Classifies and prunes from one inspection taken under the directory
  /// lock, so a report published between the two steps can't read as
  /// non-live. `classifyLive` receives every readable report and returns the
  /// identifiers to protect. If the lock isn't available in time, nothing is
  /// pruned and `skippedPruning` is set.
  @discardableResult
  public func enforceRetention(
    classifyingLive classifyLive: ([IdleScreenProcessHealth]) -> Set<String>,
    historicalLimitPerProcess: Int = historicalReportLimit
  ) throws -> RetentionResult {
    try enforceRetention(
      classifyingLive: classifyLive,
      historicalLimitPerProcess: historicalLimitPerProcess,
      beforeRemoving: { _ in }
    )
  }

  /// `beforeRemoving` runs after a file is chosen for removal and before it
  /// is re-verified, which lets tests rewrite it at exactly that moment.
  func enforceRetention(
    classifyingLive classifyLive: ([IdleScreenProcessHealth]) -> Set<String>,
    historicalLimitPerProcess: Int,
    beforeRemoving: (URL) -> Void
  ) throws -> RetentionResult {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else {
      return RetentionResult(retained: [], removedReportIdentifiers: [])
    }
    let locked = try withDirectoryLock {
      prune(
        entries: try inspectReports(),
        classifyLive: classifyLive,
        historicalLimitPerProcess: historicalLimitPerProcess,
        beforeRemoving: beforeRemoving
      )
    }
    if let locked { return locked }
    let entries = try inspectReports()
    var result = RetentionResult(
      retained: entries.map(\.report),
      removedReportIdentifiers: []
    )
    result.liveReportIdentifiers = classifyLive(result.retained)
    result.skippedPruning = true
    return result
  }

  private func prune(
    entries inspected: [InspectedReport],
    classifyLive: ([IdleScreenProcessHealth]) -> Set<String>,
    historicalLimitPerProcess: Int,
    beforeRemoving: (URL) -> Void
  ) -> RetentionResult {
    let limit = max(0, historicalLimitPerProcess)
    var entries = inspected
    let protectedReportIdentifiers = classifyLive(entries.map(\.report))
    var removed: [String] = []

    for process in IdleScreenProcessKind.allCases {
      let history =
        entries
        .filter {
          $0.report.process == process
            && $0.isRecognizedName
            && !protectedReportIdentifiers.contains($0.report.reportIdentifier)
        }
        .sorted {
          if $0.report.updatedAt != $1.report.updatedAt {
            return $0.report.updatedAt > $1.report.updatedAt
          }
          return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
      for entry in history.dropFirst(limit) {
        beforeRemoving(entry.url)
        guard let current = try? Data(contentsOf: entry.url), current == entry.data else {
          continue
        }
        do {
          try FileManager.default.removeItem(at: entry.url)
        } catch {
          continue
        }
        removed.append(entry.report.reportIdentifier)
        entries.removeAll { $0.url == entry.url }
      }
    }
    var result = RetentionResult(
      retained: entries.map(\.report),
      removedReportIdentifiers: removed
    )
    result.liveReportIdentifiers = protectedReportIdentifiers
    return result
  }

  private struct InspectedReport {
    let url: URL
    let data: Data
    let report: IdleScreenProcessHealth

    var isRecognizedName: Bool {
      url.lastPathComponent == report.reportIdentifier + ".json"
    }
  }

  private func inspectReports() throws -> [InspectedReport] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .compactMap { url in
      guard let data = try? Data(contentsOf: url),
        let report = try? decoder.decode(
          IdleScreenProcessHealth.self,
          from: data
        ),
        report.schemaVersion <= IdleScreenProcessHealth.currentSchemaVersion
      else {
        return nil
      }
      return InspectedReport(url: url, data: data, report: report)
    }
  }
}
