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
