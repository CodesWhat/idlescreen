import Darwin
import Foundation

private func statFile(_ path: String, _ info: inout stat) -> Int32 { stat(path, &info) }

/// What `stat` reports about the saved library file. An atomic replacement
/// changes the inode even when size and timestamp happen to match.
public struct IdleScreenAquariumFileFingerprint: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let size: Int64
  public let modifiedSeconds: Int64
  public let modifiedNanoseconds: Int64
  public let fileType: UInt32

  public init(
    device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64,
    modifiedNanoseconds: Int64, fileType: UInt32 = UInt32(S_IFREG)
  ) {
    self.device = device
    self.inode = inode
    self.size = size
    self.modifiedSeconds = modifiedSeconds
    self.modifiedNanoseconds = modifiedNanoseconds
    self.fileType = fileType
  }
}

public enum IdleScreenAquariumFileObservation: Equatable, Sendable {
  case missing
  case present(IdleScreenAquariumFileFingerprint)
  /// The file's state couldn't be determined; the read decides what happens.
  case unknown
}

/// Process-shared reader of the saved aquarium library. Every display's saver
/// view polls the same file; the monitor checks file identity, size and
/// high-resolution modification time first and decodes only when they change,
/// handing the validated snapshot to all views.
public final class IdleScreenAquariumSnapshotMonitor: @unchecked Sendable {
  public typealias Observe = @Sendable (URL) -> IdleScreenAquariumFileObservation
  public typealias Read = @Sendable (URL) throws -> IdleScreenAquariumLibrary?

  public static let shared = IdleScreenAquariumSnapshotMonitor()

  private struct Entry {
    let observation: IdleScreenAquariumFileObservation
    let snapshot: IdleScreenAquariumLibrary?
  }
  private let observe: Observe
  private let read: Read
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var reads = 0

  /// Number of times the file was actually decoded, for tests and diagnostics.
  public var readCount: Int { lock.withLock { reads } }

  public init(
    observe: @escaping Observe = IdleScreenAquariumSnapshotMonitor.observeFile,
    read: @escaping Read = { try IdleScreenAquariumStore(fileURL: $0).read() }
  ) {
    self.observe = observe
    self.read = read
  }

  /// The validated snapshot, or nil when no file exists. A failed read throws
  /// and commits nothing, so the next call retries. Holding the lock across the
  /// read keeps two views from decoding the same change twice.
  public func snapshot(at url: URL) throws -> IdleScreenAquariumLibrary? {
    try lock.withLock {
      let key = url.standardizedFileURL.path
      let observation = observe(url)
      if observation != .unknown, let entry = entries[key], entry.observation == observation {
        return entry.snapshot
      }
      let snapshot = try read(url)
      reads += 1
      // A file that appeared between observing and reading would be cached as
      // missing, so only a nil result may sit under `.missing`.
      if observation != .unknown, !(observation == .missing && snapshot != nil) {
        entries[key] = Entry(observation: observation, snapshot: snapshot)
      }
      return snapshot
    }
  }

  public static func observeFile(_ url: URL) -> IdleScreenAquariumFileObservation {
    var info = stat()
    guard statFile(url.path, &info) == 0 else {
      return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
    }
    return .present(
      .init(
        device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino,
        size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
        fileType: UInt32(info.st_mode) & UInt32(S_IFMT)))
  }
}

/// One view's use of the shared monitor: a one-second poll interval, and no
/// persistence reads at all unless the active configuration is an aquarium.
public struct IdleScreenAquariumSnapshotPoller {
  public static let interval: TimeInterval = 1

  public struct Outcome {
    /// The snapshot's revision differs from the one before this poll.
    public let revisionChanged: Bool
    /// Set when the read failed; the previous snapshot is kept.
    public let error: Error?
  }

  public private(set) var snapshot: IdleScreenAquariumLibrary?
  private var lastReadAt: TimeInterval?
  private var wasNeeded = false

  public init() {}

  /// Returns nil when nothing was read: not needed, or inside the interval.
  /// Becoming needed (entering an aquarium) reads immediately.
  public mutating func poll(
    at monotonicTime: TimeInterval, needed: Bool, url: @autoclosure () -> URL,
    monitor: IdleScreenAquariumSnapshotMonitor = .shared
  ) -> Outcome? {
    defer { wasNeeded = needed }
    guard needed else { return nil }
    if wasNeeded, let lastReadAt, monotonicTime - lastReadAt < Self.interval { return nil }
    lastReadAt = monotonicTime
    let previousRevision = snapshot?.revision
    do {
      snapshot = try monitor.snapshot(at: url())
      return Outcome(revisionChanged: previousRevision != snapshot?.revision, error: nil)
    } catch {
      return Outcome(revisionChanged: false, error: error)
    }
  }
}
