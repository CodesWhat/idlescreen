import Darwin
import Foundation

/// Serializes companion transactions across app instances. Renderers only read
/// atomic snapshots; they never acquire writer ownership or advance the world.
public struct IdleScreenAquariumStore: Sendable {
  public let fileURL: URL
  public init(fileURL: URL) { self.fileURL = fileURL }

  public func read() throws -> IdleScreenAquariumLibrary? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let count = values.fileSize, count <= 2_097_152 else {
      throw IdleScreenAquariumError.invalidTank
    }
    let data = try Data(contentsOf: fileURL)
    guard data.count <= 2_097_152 else { throw IdleScreenAquariumError.invalidTank }
    let library = try JSONDecoder().decode(IdleScreenAquariumLibrary.self, from: data)
    try library.validate()
    return library
  }

  @discardableResult
  public func transact(
    expectedRevision: UInt64, commandID: UUID,
    _ update: (inout IdleScreenAquariumLibrary) throws -> Void
  ) throws -> IdleScreenAquariumLibrary {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lockURL = fileURL.appendingPathExtension("lock")
    let descriptor = open(
      lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { flock(descriptor, LOCK_UN) }
    var library = try read() ?? .starter
    if library.appliedCommands.contains(commandID) { return library }
    guard library.revision == expectedRevision, library.revision < UInt64.max else {
      throw IdleScreenAquariumError.staleRevision
    }
    try update(&library)
    library.revision += 1
    library.appliedCommands.append(commandID)
    library.appliedCommands = Array(library.appliedCommands.suffix(512))
    try library.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(library)
    guard data.count <= 2_097_152 else { throw IdleScreenAquariumError.capacityReached }
    try data.write(to: fileURL, options: .atomic)
    return library
  }
}
