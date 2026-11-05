import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Saved aquarium library")
struct AquariumLibraryTests {
  @Test func starterHasStableTankAndAnimalIdentities() throws {
    let first = IdleScreenAquariumLibrary.starter
    #expect(first == .starter)
    #expect(first.tanks.count == 1)
    #expect(first.selectedTank?.animals.count == 10)
    let decoded = try JSONDecoder().decode(
      IdleScreenAquariumLibrary.self, from: JSONEncoder().encode(first))
    #expect(decoded == first)
    try decoded.validate()
  }

  @Test func layoutRejectsBadCoordinatesAndPreservesTravelCorridors() throws {
    var tank = try #require(IdleScreenAquariumLibrary.starter.selectedTank)
    let item = IdleScreenAquariumDecoration(kind: .driftwood, x: 0.2, y: 0.8)
    try tank.place(item)
    #expect(tank.decorations.contains(item))
    #expect(throws: IdleScreenAquariumError.self) {
      try tank.place(.init(kind: .pirateChest, x: .nan, y: 0.8))
    }
    #expect(throws: IdleScreenAquariumError.self) {
      try tank.place(.init(kind: .rock, x: 0.5, y: 0.1))
    }
    #expect(tank.decorations.count < 25)
  }

  @Test func tanksSurviveDisplayReassignmentAndLayoutDuplicationDoesNotCloneAnimals() throws {
    var library = IdleScreenAquariumLibrary.starter
    let original = try #require(library.selectedTank)
    let newID = UUID()
    try library.duplicateLayout(of: original.id, id: newID, name: "Shrimp room")
    #expect(library.tanks.count == 2)
    #expect(library.tanks[1].animals.isEmpty)
    try library.assign(tankID: newID, to: "monitor-a")
    #expect(library.tank(for: "monitor-a").id == newID)
    #expect(library.tank(for: "disconnected-monitor").id == newID)
    #expect(library.tanks.count == 2)
  }

  @Test func collectionLayoutCopiesPayForMountedObjectsAndDoNotSpendOnFailure() throws {
    var library = IdleScreenAquariumLibrary.starter
    library.economy = .collection
    library.balance = 10_000
    let original = try #require(library.selectedTank)
    let cost =
      original.decorations.reduce(0) { $0 + $1.kind.price }
      + original.automation.equipment.reduce(0) { $0 + $1.price }
    try library.duplicateLayout(of: original.id, id: UUID(), name: "Copy")
    #expect(library.balance == 10_000 - cost)
    library.balance = 0
    let before = library
    #expect(throws: IdleScreenAquariumError.insufficientFunds) {
      try library.duplicateLayout(of: original.id, id: UUID(), name: "Too expensive")
    }
    #expect(library == before)
  }

  @Test func authoredTankSizeRoundTripsAndControlsPlacementWithoutChangingCapacity() throws {
    var library = IdleScreenAquariumLibrary.starter
    let capacity = library.tanks[0].capacity
    let nearEdge = IdleScreenAquariumDecoration(kind: .rock, x: 0.025, y: 0.9)
    #expect(throws: IdleScreenAquariumError.invalidPlacement) {
      try library.tanks[0].place(nearEdge)
    }
    library.tanks[0].worldSize = .wide
    #expect(library.tanks[0].worldWidth == 768)
    try library.tanks[0].place(nearEdge)
    try library.validate()
    let decoded = try JSONDecoder().decode(
      IdleScreenAquariumLibrary.self, from: JSONEncoder().encode(library))
    #expect(decoded == library)
    #expect(decoded.tanks[0].capacity == capacity)
    library.tanks[0].worldSize = .standard
    #expect(throws: IdleScreenAquariumError.invalidPlacement) { try library.validate() }
  }

  @Test func storeTransactionsAreAtomicAndRetriesDoNotChargeAgain() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenAquariumStore(fileURL: directory.appending(path: "aquariums.json"))
    let command = UUID()
    let first = try store.transact(expectedRevision: 0, commandID: command) { library in
      library.balance -= 10
    }
    let retry = try store.transact(expectedRevision: 0, commandID: command) { library in
      library.balance -= 10
    }
    #expect(first == retry)
    #expect(first.balance == IdleScreenAquariumLibrary.starter.balance - 10)
    #expect(throws: IdleScreenAquariumError.self) {
      try store.transact(expectedRevision: 0, commandID: UUID()) { $0.balance -= 10 }
    }
    #expect(throws: IdleScreenAquariumError.self) {
      try store.transact(expectedRevision: first.revision, commandID: UUID()) { $0.balance = -1 }
    }
    #expect(try store.read() == first)
  }

  @Test func concurrentRetriesCommitOnePurchaseAndResumeOneBrood() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenAquariumStore(fileURL: directory.appending(path: "aquariums.json"))
    let start = Date(timeIntervalSince1970: 10_000)
    let initial = try store.transact(expectedRevision: 0, commandID: UUID()) {
      $0.economy = .collection
      $0.tanks[0].breedingEnabled = true
      $0.advance(to: start)
    }
    let command = UUID()
    let animalID = UUID()
    let results = try await withThrowingTaskGroup(of: IdleScreenAquariumLibrary.self) { group in
      for _ in 0..<4 {
        group.addTask {
          try store.transact(expectedRevision: initial.revision, commandID: command) {
            try $0.buyAnimal(.cherryShrimp, variant: .yellow, sex: .female, id: animalID)
            $0.advance(to: start.addingTimeInterval(26 * 60))
          }
        }
      }
      var values: [IdleScreenAquariumLibrary] = []
      for try await value in group { values.append(value) }
      return values
    }
    let saved = try #require(try store.read())
    #expect(results.count == 4)
    #expect(results.allSatisfy { $0 == saved })
    #expect(saved.revision == initial.revision + 1)
    #expect(saved.balance == initial.balance - 12)
    #expect(saved.tanks[0].animals.filter { $0.id == animalID }.count == 1)
    #expect(saved.tanks[0].animals.contains { !$0.parents.isEmpty })
    let resumed = try store.transact(expectedRevision: saved.revision, commandID: UUID()) {
      $0.advance(to: start.addingTimeInterval(26 * 60))
    }
    #expect(resumed.tanks == saved.tanks)
  }

  @Test func corruptAndFutureStoresArePreserved() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "aquariums.json")
    let corrupt = Data("invalid save".utf8)
    try corrupt.write(to: url)
    let store = IdleScreenAquariumStore(fileURL: url)
    #expect(throws: (any Error).self) { try store.read() }
    #expect(throws: (any Error).self) {
      try store.transact(expectedRevision: 0, commandID: UUID()) { $0.balance += 1 }
    }
    #expect(try Data(contentsOf: url) == corrupt)
    var future = IdleScreenAquariumLibrary.starter
    future.schemaVersion = 99
    try JSONEncoder().encode(future).write(to: url)
    #expect(throws: IdleScreenAquariumError.self) { try store.read() }
  }
}
