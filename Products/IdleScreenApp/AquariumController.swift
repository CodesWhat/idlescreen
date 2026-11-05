import Foundation
import IdleScreenCore
import Observation

@MainActor
@Observable
final class IdleScreenAquariumController {
  static let shared = IdleScreenAquariumController(fileURL: IdleScreenAquariumProduct.storeURL())
  private(set) var library = IdleScreenAquariumLibrary.starter
  private(set) var errorMessage: String?
  private(set) var isWritable = true
  private var undoStack: [Layout] = []
  private var redoStack: [Layout] = []
  @ObservationIgnored private let store: IdleScreenAquariumStore
  @ObservationIgnored private let clock: () -> Date
  @ObservationIgnored var didChange: (() -> Void)?
  @ObservationIgnored private var timer: Timer?

  private struct Layout {
    let tankID: UUID
    let substrate: IdleScreenAquariumSubstrate
    let worldSize: IdleScreenAquariumWorldSize?
    let depth: Double
    let objects: [IdleScreenAquariumDecoration]
    init(_ tank: IdleScreenAquariumTank) {
      tankID = tank.id
      substrate = tank.substrate
      worldSize = tank.worldSize
      depth = tank.substrateDepth
      objects = tank.decorations
    }
  }

  init(fileURL: URL, clock: @escaping () -> Date = { Date() }) {
    store = .init(fileURL: fileURL)
    self.clock = clock
    reload()
    if isWritable, library.tanks.contains(where: { $0.lastAdvancedAt == nil }) {
      perform { $0.advance(to: clock()) }
    }
  }

  var selectedTank: IdleScreenAquariumTank { library.selectedTank ?? .init() }
  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }

  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.advance() }
    }
  }
  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func reload() {
    do {
      library = try store.read() ?? .starter
      isWritable = true
      errorMessage = nil
      undoStack = []
      redoStack = []
      didChange?()
    } catch {
      isWritable = false
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func perform(_ operation: (inout IdleScreenAquariumLibrary) throws -> Void) -> Bool {
    guard isWritable else { return false }
    do {
      library = try store.transact(expectedRevision: library.revision, commandID: UUID(), operation)
      errorMessage = nil
      didChange?()
      return true
    } catch {
      if error as? IdleScreenAquariumError == .staleRevision { reload() }
      errorMessage = error.localizedDescription
      return false
    }
  }

  func advance() {
    let now = clock()
    guard
      library.tanks.contains(where: {
        now.timeIntervalSince($0.lastAdvancedAt ?? .distantPast) >= 60
      })
    else { return }
    perform { $0.advance(to: now) }
  }

  func editTank(
    recordLayout: Bool = false, _ operation: (inout IdleScreenAquariumTank) throws -> Void
  ) {
    let previous = Layout(selectedTank)
    let success = perform { library in
      guard let index = library.tanks.firstIndex(where: { $0.id == library.selectedTankID }) else {
        throw IdleScreenAquariumError.missingItem
      }
      try operation(&library.tanks[index])
    }
    if success, recordLayout { remember(previous) }
  }

  func select(_ id: UUID) {
    if perform({ $0.selectedTankID = id }) {
      undoStack = []
      redoStack = []
    }
  }

  func newTank() {
    let id = UUID()
    perform { library in
      guard library.tanks.count < IdleScreenAquariumLibrary.maximumTankCount else {
        throw IdleScreenAquariumError.capacityReached
      }
      library.tanks.append(
        .init(
          id: id, name: "Aquarium \(library.tanks.count + 1)",
          seed: UInt64.random(in: 1...UInt64.max)))
      library.selectedTankID = id
    }
    undoStack = []
    redoStack = []
  }

  func duplicateTank() {
    let tank = selectedTank
    if perform({
      try $0.duplicateLayout(
        of: tank.id, id: UUID(), name: String((tank.name + " Copy").prefix(64)))
    }) {
      undoStack = []
      redoStack = []
    }
  }

  func deleteTank() {
    let id = selectedTank.id
    if perform({ library in
      guard library.tanks.count > 1 else { throw IdleScreenAquariumError.invalidOperation }
      for item in library.tanks.first(where: { $0.id == id })?.decorations ?? [] {
        guard library.inventory[item.kind.rawValue, default: 0] < 99 else {
          throw IdleScreenAquariumError.capacityReached
        }
        library.inventory[item.kind.rawValue, default: 0] += 1
      }
      library.tanks.removeAll { $0.id == id }
      library.displayAssignments = library.displayAssignments.filter { $0.value != id }
      library.selectedTankID = library.tanks[0].id
    }) {
      undoStack = []
      redoStack = []
    }
  }

  func addDecoration(_ kind: IdleScreenAquariumDecorationKind) {
    let previous = Layout(selectedTank)
    let x = 0.2 + Double(selectedTank.decorations.count % 4) * 0.2
    let item = IdleScreenAquariumDecoration(kind: kind, x: x, y: 0.91)
    if perform({ library in
      if library.inventory[kind.rawValue, default: 0] == 0 { try library.buyDecoration(kind) }
      try library.placeOwnedDecoration(item)
    }) {
      remember(previous)
    }
  }

  func removeDecoration(_ id: UUID) {
    let previous = Layout(selectedTank)
    if perform({ try $0.removeDecoration(id: id) }) { remember(previous) }
  }

  func updateDecoration(_ item: IdleScreenAquariumDecoration) {
    editTank(recordLayout: true) { try $0.place(item) }
  }

  func undoLayout() {
    guard let layout = undoStack.last else { return }
    let current = Layout(selectedTank)
    if restore(layout) {
      undoStack.removeLast()
      redoStack.append(current)
    }
  }
  func redoLayout() {
    guard let layout = redoStack.last else { return }
    let current = Layout(selectedTank)
    if restore(layout) {
      redoStack.removeLast()
      undoStack.append(current)
    }
  }

  private func remember(_ layout: Layout) {
    undoStack.append(layout)
    undoStack = Array(undoStack.suffix(32))
    redoStack = []
  }

  private func restore(_ layout: Layout) -> Bool {
    perform { library in
      guard let index = library.tanks.firstIndex(where: { $0.id == layout.tankID }),
        library.selectedTankID == layout.tankID
      else { throw IdleScreenAquariumError.missingItem }
      for item in library.tanks[index].decorations {
        library.inventory[item.kind.rawValue, default: 0] += 1
      }
      for item in layout.objects {
        guard library.inventory[item.kind.rawValue, default: 0] > 0 else {
          throw IdleScreenAquariumError.missingItem
        }
        library.inventory[item.kind.rawValue, default: 0] -= 1
      }
      library.tanks[index].decorations = layout.objects
      library.tanks[index].worldSize = layout.worldSize
      library.tanks[index].substrate = layout.substrate
      library.tanks[index].substrateDepth = layout.depth
    }
  }
}
