import Foundation
import IdleScreenRenderer
import Observation

@MainActor
@Observable
final class IdleScreenPlantedTankEditor {
  typealias Object = IdleScreenAquariumWebSurface.PresetObject
  #if IDLESCREEN_APP_COMPILE_GATE
    static let shared = IdleScreenPlantedTankEditor()
  #else
    static let shared = IdleScreenPlantedTankEditor(
      store: IdleScreenPlantedTankStore(
        fileURL: IdleScreenAquariumProduct.storeURL().deletingLastPathComponent()
          .appendingPathComponent("planted-tank-v1.json")))
  #endif
  private(set) var surface = IdleScreenAquariumWebSurface()
  private(set) var snapshot: IdleScreenAquariumWebSurface.EditorSnapshot?
  private(set) var errorMessage: String?
  private(set) var isBusy = false
  private(set) var savedAt: Date?
  @ObservationIgnored private let store: IdleScreenPlantedTankStore?
  @ObservationIgnored private var storedRevision: String?
  var selectedID: String?
  private enum ObjectKind { case preset, placed }
  private struct LayoutEdit {
    let kind: ObjectKind
    let objects: [Object]
  }
  private var undoStack: [LayoutEdit] = []
  private var redoStack: [LayoutEdit] = []
  @ObservationIgnored private var wantsVisible = false
  @ObservationIgnored private var isActivating = false
  @ObservationIgnored private var isReloading = false

  init(store: IdleScreenPlantedTankStore? = nil) { self.store = store }

  var canSave: Bool { store != nil && snapshot != nil && !isBusy }
  var canReopen: Bool { store != nil && !isBusy && !isActivating }

  var canUndo: Bool { !isBusy && !undoStack.isEmpty }
  var canRedo: Bool { !isBusy && !redoStack.isEmpty }
  var selectedObject: Object? {
    allObjects.first { $0.id == selectedID }
  }
  var allObjects: [Object] { (snapshot?.objects ?? []) + (snapshot?.placedObjects ?? []) }

  private func objects(_ kind: ObjectKind) -> [Object] {
    switch kind {
    case .preset: snapshot?.objects ?? []
    case .placed: snapshot?.placedObjects ?? []
    }
  }

  func activate() async {
    guard !Task.isCancelled else { return }
    wantsVisible = true
    guard !isReloading else { return }
    guard !isActivating else { return }
    isActivating = true
    defer { isActivating = false }
    do {
      if surface.state == .unloaded {
        guard let url = IdleScreenAquariumRuntime.sceneURL else {
          throw IdleScreenAquariumWebSurface.SurfaceError.invalidLocalResource
        }
        try await surface.load(sceneURL: url)
        if let saved = try await store?.read() {
          if let data = saved.data { _ = try await surface.restoreTank(from: data) }
          storedRevision = saved.revision
        }
        snapshot = try await surface.beginEditing()
      }
      guard snapshot != nil else { throw IdleScreenAquariumWebSurface.SurfaceError.invalidState }
      guard wantsVisible else { return }
      try await surface.resume()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deactivate() async {
    wantsVisible = false
    do {
      if surface.state == .running { try await surface.pause() }
      await save()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func add(assetID: String, positionCm: IdleScreenAquariumWebSurface.PositionCm) async {
    guard !isBusy, let snapshot, snapshot.catalog.contains(where: { $0.id == assetID }) else {
      return
    }
    let object = Object(
      id: "placed-" + UUID().uuidString, assetId: assetID,
      positionCm: positionCm, rotationY: 0)
    if await edit(snapshot.placedObjects + [object], kind: .placed) { selectedID = object.id }
  }

  func update(_ object: Object) async {
    guard allObjects.contains(where: { $0.id == object.id }) else { return }
    let kind: ObjectKind =
      snapshot?.placedObjects.contains(where: { $0.id == object.id }) == true ? .placed : .preset
    _ = await edit(objects(kind).map { $0.id == object.id ? object : $0 }, kind: kind)
  }

  func removeSelected() async {
    guard let selectedID, allObjects.contains(where: { $0.id == selectedID }) else { return }
    let kind: ObjectKind =
      snapshot?.placedObjects.contains(where: { $0.id == selectedID }) == true ? .placed : .preset
    _ = await edit(objects(kind).filter { $0.id != selectedID }, kind: kind)
  }

  private func edit(_ proposed: [Object], kind: ObjectKind) async -> Bool {
    guard !isBusy, snapshot != nil else { return false }
    let previous = objects(kind)
    guard proposed != previous else { return false }
    if await apply(LayoutEdit(kind: kind, objects: proposed)) {
      undoStack.append(LayoutEdit(kind: kind, objects: previous))
      if undoStack.count > 100 { undoStack.removeFirst() }
      redoStack.removeAll()
      return true
    }
    return false
  }

  func undo() async {
    guard canUndo, let edit = undoStack.last else { return }
    let current = LayoutEdit(kind: edit.kind, objects: objects(edit.kind))
    if await apply(edit) {
      undoStack.removeLast()
      redoStack.append(current)
    }
  }

  func redo() async {
    guard canRedo, let edit = redoStack.last else { return }
    let current = LayoutEdit(kind: edit.kind, objects: objects(edit.kind))
    if await apply(edit) {
      redoStack.removeLast()
      undoStack.append(current)
    }
  }

  func reloadCheckpoint() async {
    guard canReopen, let store else { return }
    isBusy = true
    isReloading = true
    defer {
      isBusy = false
      isReloading = false
    }
    let previous = surface
    let wasRunning = previous.state == .running
    let candidate = IdleScreenAquariumWebSurface()
    do {
      if wasRunning { try await previous.pause() }
      let saved = try await store.read()
      guard let url = IdleScreenAquariumRuntime.sceneURL else {
        throw IdleScreenAquariumWebSurface.SurfaceError.invalidLocalResource
      }
      try await candidate.load(sceneURL: url)
      if let data = saved.data { _ = try await candidate.restoreTank(from: data) }
      let restored = try await candidate.beginEditing()
      if wantsVisible { try await candidate.resume() }
      surface = candidate
      snapshot = restored
      storedRevision = saved.revision
      selectedID = nil
      undoStack.removeAll()
      redoStack.removeAll()
      savedAt = nil
      errorMessage = nil
      try? await previous.shutdown()
    } catch {
      try? await candidate.shutdown()
      if wantsVisible && previous.state == .paused { try? await previous.resume() }
      errorMessage = error.localizedDescription
    }
  }

  func save() async {
    guard canSave else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await persist()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func persist() async throws {
    guard let store else { return }
    let data = try await surface.exportTank(id: "planted-tank", name: "Planted tank")
    storedRevision = try await store.write(data, expectedRevision: storedRevision)
    savedAt = Date()
  }

  private func apply(_ edit: LayoutEdit) async -> Bool {
    guard !isBusy, let snapshot else { return false }
    isBusy = true
    defer { isBusy = false }
    do {
      switch edit.kind {
      case .preset:
        self.snapshot = try await surface.applyPresetObjects(
          expectedRevision: snapshot.revision, objects: edit.objects)
      case .placed:
        self.snapshot = try await surface.applyPlacedObjects(
          expectedRevision: snapshot.revision, objects: edit.objects)
      }
      if !allObjects.contains(where: { $0.id == selectedID }) { selectedID = nil }
      errorMessage = nil
      do { try await persist() } catch { errorMessage = error.localizedDescription }
      return true
    } catch {
      errorMessage = error.localizedDescription
      self.snapshot = (try? await surface.editorSnapshot()) ?? snapshot
      return false
    }
  }
}
