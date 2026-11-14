import Darwin
import Foundation
import Testing

@Suite("Planted tank checkpoints")
struct PlantedTankStoreTests {
  private func checkpoint(_ value: Int) -> Data {
    Data(
      "{\"schemaVersion\":1,\"tank\":{\"format\":\"idlescreen.aquarium\",\"schemaVersion\":1},\"runtime\":{\"clock\":\(value)}}"
        .utf8)
  }

  @Test func writesAreAtomicAndRejectAnotherOwnersStaleCheckpoint() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tank.json")
    let first = IdleScreenPlantedTankStore(fileURL: url)
    let second = IdleScreenPlantedTankStore(fileURL: url)
    #expect(try await first.read().revision == nil)
    let initial = try await first.write(checkpoint(1), expectedRevision: nil)
    let observed = try await second.read()
    #expect(observed.revision == initial)
    let latest = try await first.write(checkpoint(2), expectedRevision: initial)
    await #expect(throws: IdleScreenPlantedTankStore.StoreError.staleRevision) {
      try await second.write(checkpoint(3), expectedRevision: observed.revision)
    }
    let actual = try await second.read()
    #expect(actual.data == checkpoint(2))
    #expect(actual.revision == latest)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
        "tank.json", "tank.json.lock",
      ])
  }

  @Test func invalidAndFutureCheckpointsNeverReplaceTheLastGoodFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tank.json")
    let store = IdleScreenPlantedTankStore(fileURL: url)
    let revision = try await store.write(checkpoint(1), expectedRevision: nil)
    for bad in [
      Data("{".utf8), Data("{\"schemaVersion\":99}".utf8), Data(repeating: 32, count: 4_194_305),
    ] {
      await #expect(throws: (any Error).self) {
        try await store.write(bad, expectedRevision: revision)
      }
      #expect(try await store.read().data == checkpoint(1))
    }
    try Data(repeating: 32, count: 4_194_305).write(to: url)
    await #expect(throws: IdleScreenPlantedTankStore.StoreError.tooLarge) { try await store.read() }
  }
  @Test func anotherProcessesActiveSaveDoesNotGetOverwritten() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tank.json")
    let descriptor = Darwin.open(
      url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, mode_t(0o600))
    #expect(descriptor >= 0)
    defer { _ = Darwin.close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    defer { _ = flock(descriptor, LOCK_UN) }
    let store = IdleScreenPlantedTankStore(fileURL: url)
    await #expect(throws: IdleScreenPlantedTankStore.StoreError.busy) {
      try await store.write(checkpoint(1), expectedRevision: nil)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

}
