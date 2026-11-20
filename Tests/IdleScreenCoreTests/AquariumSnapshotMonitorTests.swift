import Darwin
import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Shared aquarium snapshot monitor")
struct AquariumSnapshotMonitorTests {
  /// Scripted file state and call counters behind the injected functions.
  final class Disk: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: IdleScreenAquariumFileObservation
    private var library: IdleScreenAquariumLibrary?
    private var failure: Error?
    private var observed = 0
    private var attempted = 0

    init(inode: UInt64 = 1, revision: UInt64 = 1) {
      observation = .present(Self.fingerprint(inode: inode))
      library = Self.library(revision)
    }

    static func fingerprint(inode: UInt64, size: Int64 = 100, nanos: Int64 = 5)
      -> IdleScreenAquariumFileFingerprint
    {
      .init(
        device: 1, inode: inode, size: size, modifiedSeconds: 1_000, modifiedNanoseconds: nanos)
    }

    static func library(_ revision: UInt64) -> IdleScreenAquariumLibrary {
      var library = IdleScreenAquariumLibrary.starter
      library.revision = revision
      return library
    }

    func replace(inode: UInt64, size: Int64 = 100, nanos: Int64 = 5, revision: UInt64) {
      lock.withLock {
        observation = .present(Self.fingerprint(inode: inode, size: size, nanos: nanos))
        library = Self.library(revision)
        failure = nil
      }
    }
    func delete() {
      lock.withLock {
        observation = .missing
        library = nil
        failure = nil
      }
    }
    func corrupt(inode: UInt64) {
      lock.withLock {
        observation = .present(Self.fingerprint(inode: inode))
        failure = IdleScreenAquariumError.invalidTank
      }
    }
    func repair(revision: UInt64) {
      lock.withLock {
        failure = nil
        library = Self.library(revision)
      }
    }
    /// The file appeared after the stat and before the read.
    func appearAfterObserving(revision: UInt64) {
      lock.withLock {
        observation = .missing
        library = Self.library(revision)
        failure = nil
      }
    }
    func makeUnknown() { lock.withLock { observation = .unknown } }

    var observeCount: Int { lock.withLock { observed } }
    var attemptCount: Int { lock.withLock { attempted } }

    func monitor() -> IdleScreenAquariumSnapshotMonitor {
      .init(
        observe: { [self] _ in
          lock.withLock {
            observed += 1
            return observation
          }
        },
        read: { [self] _ in
          try lock.withLock {
            attempted += 1
            if let failure { throw failure }
            return library
          }
        })
    }
  }

  private let url = URL(fileURLWithPath: "/tmp/aquariums-test.json")

  @Test func anUnchangedFileDecodesOnceAcrossSeveralDisplays() {
    let disk = Disk()
    let monitor = disk.monitor()
    var displays = (0..<3).map { _ in IdleScreenAquariumSnapshotPoller() }
    for tick in 0..<5 {
      for index in displays.indices {
        let outcome = displays[index].poll(
          at: Double(tick) * 2, needed: true, url: url, monitor: monitor)
        #expect(outcome?.error == nil)
        #expect(displays[index].snapshot?.revision == 1)
      }
    }
    #expect(monitor.readCount == 1)
    #expect(disk.attemptCount == 1)
  }

  @Test func aSnapshotReadUnderAMissingObservationIsNotCached() throws {
    let disk = Disk()
    disk.delete()
    disk.appearAfterObserving(revision: 7)
    let monitor = disk.monitor()
    #expect(try monitor.snapshot(at: url)?.revision == 7)
    disk.delete()
    #expect(try monitor.snapshot(at: url) == nil)
    // A plain missing file is still cached.
    #expect(try monitor.snapshot(at: url) == nil)
    #expect(disk.attemptCount == 2)
  }

  @Test func nonAquariumTicksNeverTouchTheFile() {
    let disk = Disk()
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    for tick in 0..<20 {
      #expect(poller.poll(at: Double(tick) * 2, needed: false, url: url, monitor: monitor) == nil)
    }
    #expect(disk.observeCount == 0 && monitor.readCount == 0)
    #expect(poller.snapshot == nil)
  }

  @Test func enteringAnAquariumLoadsTheLatestSnapshotImmediately() {
    let disk = Disk(revision: 4)
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    #expect(poller.poll(at: 10, needed: false, url: url, monitor: monitor) == nil)
    let entered = poller.poll(at: 10.1, needed: true, url: url, monitor: monitor)
    #expect(entered?.revisionChanged == true)
    #expect(poller.snapshot?.revision == 4)
    // Now inside the interval, so the next ticks don't look at the disk.
    let before = disk.observeCount
    #expect(poller.poll(at: 10.6, needed: true, url: url, monitor: monitor) == nil)
    #expect(disk.observeCount == before)
    // Leaving and re-entering inside one interval still refreshes at once.
    disk.replace(inode: 2, revision: 5)
    _ = poller.poll(at: 10.7, needed: false, url: url, monitor: monitor)
    #expect(
      poller.poll(at: 10.8, needed: true, url: url, monitor: monitor)?.revisionChanged == true)
    #expect(poller.snapshot?.revision == 5)
  }

  @Test func theIntervalGatesLaterPollsOfAnActiveAquarium() {
    let disk = Disk()
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    #expect(poller.poll(at: 0, needed: true, url: url, monitor: monitor) != nil)
    #expect(poller.poll(at: 0.9, needed: true, url: url, monitor: monitor) == nil)
    let due = poller.poll(at: 1.0, needed: true, url: url, monitor: monitor)
    #expect(due?.revisionChanged == false)
    #expect(monitor.readCount == 1)
  }

  @Test func anAtomicReplacementIsReadEvenWhenSizeAndTimeMatch() {
    let disk = Disk(inode: 1, revision: 1)
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    _ = poller.poll(at: 0, needed: true, url: url, monitor: monitor)
    disk.replace(inode: 2, size: 100, nanos: 5, revision: 2)
    let outcome = poller.poll(at: 2, needed: true, url: url, monitor: monitor)
    #expect(outcome?.revisionChanged == true)
    #expect(poller.snapshot?.revision == 2)
    #expect(monitor.readCount == 2)
  }

  @Test func sizeOrNanosecondChangesAloneTriggerARead() {
    let disk = Disk()
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    _ = poller.poll(at: 0, needed: true, url: url, monitor: monitor)
    disk.replace(inode: 1, size: 101, revision: 2)
    _ = poller.poll(at: 2, needed: true, url: url, monitor: monitor)
    disk.replace(inode: 1, size: 101, nanos: 6, revision: 3)
    _ = poller.poll(at: 4, needed: true, url: url, monitor: monitor)
    #expect(poller.snapshot?.revision == 3)
    #expect(monitor.readCount == 3)
  }

  @Test func deletionAndRecreationFollowTheFile() {
    let disk = Disk()
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    _ = poller.poll(at: 0, needed: true, url: url, monitor: monitor)
    disk.delete()
    let removed = poller.poll(at: 2, needed: true, url: url, monitor: monitor)
    #expect(removed?.error == nil && removed?.revisionChanged == true)
    #expect(poller.snapshot == nil)
    // A missing file is a stable state, read once.
    _ = poller.poll(at: 4, needed: true, url: url, monitor: monitor)
    #expect(disk.attemptCount == 2)
    disk.replace(inode: 9, revision: 1)
    let recreated = poller.poll(at: 6, needed: true, url: url, monitor: monitor)
    #expect(recreated?.revisionChanged == true)
    #expect(poller.snapshot?.revision == 1)
    #expect(disk.attemptCount == 3)
  }

  @Test func aMalformedReplacementKeepsTheLastGoodSnapshotAndRetries() {
    let disk = Disk(revision: 1)
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    _ = poller.poll(at: 0, needed: true, url: url, monitor: monitor)
    disk.corrupt(inode: 2)
    for tick in 1...3 {
      let outcome = poller.poll(at: Double(tick) * 2, needed: true, url: url, monitor: monitor)
      #expect(outcome?.error != nil && outcome?.revisionChanged == false)
      #expect(poller.snapshot?.revision == 1)
    }
    // Nothing was committed, so every poll retried the decode.
    #expect(disk.attemptCount == 4)
    #expect(monitor.readCount == 1)
    disk.repair(revision: 2)
    let fixed = poller.poll(at: 8, needed: true, url: url, monitor: monitor)
    #expect(fixed?.error == nil && fixed?.revisionChanged == true)
    #expect(poller.snapshot?.revision == 2)
    _ = poller.poll(at: 10, needed: true, url: url, monitor: monitor)
    #expect(disk.attemptCount == 5)
  }

  @Test func anUndeterminedFileStateAlwaysReadsAndNeverCommits() {
    let disk = Disk()
    disk.makeUnknown()
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    for tick in 0..<3 {
      _ = poller.poll(at: Double(tick) * 2, needed: true, url: url, monitor: monitor)
    }
    #expect(disk.attemptCount == 3)
  }

  @Test func revisionChangesDriveThePlanUpdateSignal() {
    let disk = Disk(revision: 1)
    let monitor = disk.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    var signals: [Bool] = []
    func tick(_ time: Double) {
      signals.append(
        poller.poll(at: time, needed: true, url: url, monitor: monitor)?.revisionChanged ?? false)
    }
    tick(0)
    tick(2)
    disk.replace(inode: 2, revision: 2)
    tick(4)
    tick(6)
    // Same revision in a different file is a re-read, not a plan change.
    disk.replace(inode: 3, revision: 2)
    tick(8)
    #expect(signals == [true, false, true, false, false])
  }

  @Test func differentFilesAreTrackedIndependently() {
    let first = Disk(revision: 1)
    let monitor = first.monitor()
    var poller = IdleScreenAquariumSnapshotPoller()
    _ = poller.poll(at: 0, needed: true, url: url, monitor: monitor)
    _ = poller.poll(
      at: 2, needed: true, url: URL(fileURLWithPath: "/tmp/other-aquariums.json"),
      monitor: monitor)
    #expect(monitor.readCount == 2)
  }

  @Test func realFilesDetectAtomicReplacementWithIdenticalSizeAndTimestamp() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "aquarium-monitor-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "aquariums-v1.json")
    let store = IdleScreenAquariumStore(fileURL: file)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func write(_ revision: UInt64, to url: URL) throws {
      try encoder.encode(Disk.library(revision)).write(to: url)
    }
    let monitor = IdleScreenAquariumSnapshotMonitor()
    #expect(try monitor.snapshot(at: file) == nil)
    try write(1, to: file)
    #expect(try monitor.snapshot(at: file)?.revision == 1)
    #expect(try monitor.snapshot(at: file)?.revision == 1)
    #expect(monitor.readCount == 2)
    var original = stat()
    #expect(stat(file.path, &original) == 0)
    let replacement = directory.appending(path: "replacement.json")
    try write(2, to: replacement)
    var times = [original.st_mtimespec, original.st_mtimespec].map {
      timeval(tv_sec: $0.tv_sec, tv_usec: Int32($0.tv_nsec / 1_000))
    }
    #expect(utimes(replacement.path, &times) == 0)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
    var updated = stat()
    #expect(stat(file.path, &updated) == 0)
    #expect(updated.st_size == original.st_size)
    #expect(try monitor.snapshot(at: file)?.revision == 2)
    #expect(try store.read()?.revision == 2)
    try FileManager.default.removeItem(at: file)
    #expect(try monitor.snapshot(at: file) == nil)
  }
}
