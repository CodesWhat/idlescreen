import CryptoKit
import Darwin
import Foundation

actor IdleScreenPlantedTankStore {
  enum StoreError: Error, Equatable, LocalizedError {
    case staleRevision
    case busy
    case tooLarge
    case invalidDocument

    var errorDescription: String? {
      switch self {
      case .staleRevision:
        "The saved tank changed in another window or app. Reopen it before saving."
      case .busy: "Another app is saving this tank. Try saving again."
      case .tooLarge: "The tank checkpoint exceeds the 4 MiB limit."
      case .invalidDocument: "The tank checkpoint is unreadable or uses an unsupported format."
      }
    }
  }

  struct Snapshot: Sendable {
    let data: Data?
    let revision: String?
  }

  private struct Header: Decodable {
    struct Tank: Decodable {
      let format: String
      let schemaVersion: Int
    }
    let schemaVersion: Int
    let tank: Tank
  }

  private let fileURL: URL
  private let maximumBytes = 4_194_304

  init(fileURL: URL) { self.fileURL = fileURL }

  func read() throws -> Snapshot {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: fileURL)
    } catch {
      let failure = error as NSError
      if failure.domain == NSCocoaErrorDomain,
        [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
      {
        return Snapshot(data: nil, revision: nil)
      }
      throw error
    }
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    try validate(data)
    return Snapshot(data: data, revision: digest(data))
  }

  func write(_ data: Data, expectedRevision: String?) throws -> String {
    try validate(data)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let descriptor = Darwin.open(
      fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }
    defer { _ = flock(descriptor, LOCK_UN) }
    guard try read().revision == expectedRevision else { throw StoreError.staleRevision }
    try data.write(to: fileURL, options: .atomic)
    return digest(data)
  }

  private func validate(_ data: Data) throws {
    guard data.count <= maximumBytes else { throw StoreError.tooLarge }
    guard let header = try? JSONDecoder().decode(Header.self, from: data),
      header.schemaVersion == 1, header.tank.schemaVersion == 1,
      header.tank.format == "idlescreen.aquarium"
    else { throw StoreError.invalidDocument }
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
