import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Saved aquarium library")
struct AquariumLibraryTests {
  @Test func returningASupportPreservesAndDetachesItsMoss() throws {
    var library = IdleScreenAquariumLibrary.starter
    let rock = IdleScreenAquariumDecoration(kind: .rock, x: 0.5, y: 0.9)
    let moss = IdleScreenAquariumDecoration(kind: .moss, x: 0.3, y: 0.9)
    library.tanks[0].decorations = [rock, moss]
    try library.tanks[0].attachMoss(id: moss.id, to: rock.id)
    var expected = try #require(library.tanks[0].placedDecorations.last)
    expected.attachment = nil
    try library.removeDecoration(id: rock.id)
    #expect(library.tanks[0].decorations == [expected])
    #expect(library.inventory["rock"] == 1)
    try library.validate()
  }

  @Test func attachedMossFollowsItsSupportAndDetachesAtItsCurrentPose() throws {
    var tank = IdleScreenAquariumTank()
    var wood = IdleScreenAquariumDecoration(kind: .driftwood, x: 0.5, y: 0.9)
    let moss = IdleScreenAquariumDecoration(kind: .moss, x: 0.3, y: 0.9, scale: 0.8)
    tank.decorations = [wood, moss]
    try tank.attachMoss(id: moss.id, to: wood.id)
    let first = try #require(tank.placedDecorations.first { $0.id == moss.id })
    #expect(first.x != moss.x && first.attachment?.parentID == wood.id)
    wood.x = 0.6
    wood.scale = 1.2
    wood.flipped = true
    wood.tilt = .right
    wood.foreground = true
    try tank.place(wood)
    let moved = try #require(tank.placedDecorations.first { $0.id == moss.id })
    #expect(moved.x != first.x && moved.y != first.y)
    #expect(abs(moved.scale - 0.96) < 0.00001)
    #expect(moved.flipped && moved.foreground && moved.tilt == .right)
    let pixelOffset = (moved.x - wood.x) * Double(tank.worldWidth)
    tank.worldSize = .wide
    let wide = try #require(tank.placedDecorations.first { $0.id == moss.id })
    #expect(abs((wide.x - wood.x) * Double(tank.worldWidth) - pixelOffset) < 0.00001)
    try tank.detachMoss(id: moss.id)
    let detached = try #require(tank.decorations.first { $0.id == moss.id })
    #expect(detached.attachment == nil)
    #expect(detached.x == wide.x && detached.y == wide.y && detached.scale == wide.scale)
    try tank.validate()
  }

  @Test func mossLinksRoundTripRejectDanglingSupportsAndKeepMovesAtomic() throws {
    var tank = IdleScreenAquariumTank()
    var rock = IdleScreenAquariumDecoration(kind: .rock, x: 0.5, y: 0.9)
    let moss = IdleScreenAquariumDecoration(kind: .moss, x: 0.3, y: 0.9, scale: 1.5)
    tank.decorations = [rock, moss]
    try tank.attachMoss(id: moss.id, to: rock.id)
    let before = tank
    rock.x = 0.05
    #expect(throws: IdleScreenAquariumError.invalidPlacement) { try tank.place(rock) }
    #expect(tank == before)
    let saved = try JSONDecoder().decode(
      IdleScreenAquariumTank.self, from: JSONEncoder().encode(tank))
    #expect(saved == tank && saved.placedDecorations == tank.placedDecorations)
    #expect(throws: IdleScreenAquariumError.invalidPlacement) {
      try tank.attachMoss(id: moss.id, to: moss.id)
    }
    #expect(tank == before)
    tank.decorations.removeFirst()
    #expect(throws: IdleScreenAquariumError.invalidPlacement) { try tank.validate() }
  }

  @Test func interruptedFeedingCommandCannotAddFoodTwice() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenAquariumStore(fileURL: directory.appending(path: "aquariums.json"))
    let command = UUID()
    let fedAt = Date(timeIntervalSince1970: 1_000)
    let first = try store.transact(expectedRevision: 0, commandID: command) {
      try $0.feed(at: fedAt)
    }
    let replay = try store.transact(expectedRevision: 0, commandID: command) {
      try $0.feed(at: fedAt.addingTimeInterval(10))
    }
    #expect(replay == first)
    #expect(replay.selectedTank?.lastFedAt == fedAt)
    #expect(replay.selectedTank?.water.waste == 0.3)
    #expect(try store.read() == first)
  }

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

  @Test func limitedTiltRoundTripsAndExpandedBoundsStayInsideTheTank() throws {
    var library = IdleScreenAquariumLibrary.starter
    var item = IdleScreenAquariumDecoration(kind: .rock, x: 0.045, y: 0.9)
    try item.validate()
    item.tilt = .right
    #expect(item.placementSize.width > item.kind.size.width)
    #expect(throws: IdleScreenAquariumError.invalidPlacement) { try item.validate() }
    item.x = 0.5
    try library.tanks[0].place(item)
    let saved = try JSONDecoder().decode(
      IdleScreenAquariumLibrary.self,
      from: JSONEncoder().encode(library))
    #expect(saved.tanks[0].decorations.last?.tilt == .right)
    #expect(IdleScreenAquariumDecoration(kind: .rock, x: 0.5, y: 0.9).tilt == nil)
    var tall = IdleScreenAquariumDecoration(kind: .shipwreck, x: 0.5, y: 0.6, scale: 1.5)
    try tall.validate()
    tall.tilt = .left
    #expect(throws: IdleScreenAquariumError.invalidPlacement) { try tall.validate() }
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
