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
  private var undoStack: [[Object]] = []
  private var redoStack: [[Object]] = []
  @ObservationIgnored private var wantsVisible = false
  @ObservationIgnored private var isActivating = false
  @ObservationIgnored private var isReloading = false

  init(store: IdleScreenPlantedTankStore? = nil) { self.store = store }

  var canSave: Bool { store != nil && snapshot != nil && !isBusy }
  var canReopen: Bool { store != nil && !isBusy && !isActivating }

  var canUndo: Bool { !isBusy && !undoStack.isEmpty }
  var canRedo: Bool { !isBusy && !redoStack.isEmpty }
  var selectedObject: Object? { snapshot?.objects.first { $0.id == selectedID } }

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

  func update(_ object: Object) async {
    guard let snapshot, snapshot.objects.contains(where: { $0.id == object.id }) else { return }
    await edit(snapshot.objects.map { $0.id == object.id ? object : $0 })
  }

  func removeSelected() async {
    guard let snapshot, let selectedID else { return }
    await edit(snapshot.objects.filter { $0.id != selectedID })
  }

  private func edit(_ objects: [Object]) async {
    guard !isBusy, let snapshot, objects != snapshot.objects else { return }
    if await apply(objects) {
      undoStack.append(snapshot.objects)
      if undoStack.count > 100 { undoStack.removeFirst() }
      redoStack.removeAll()
    }
  }

  func undo() async {
    guard canUndo, let objects = undoStack.last, let snapshot else { return }
    if await apply(objects) {
      undoStack.removeLast()
      redoStack.append(snapshot.objects)
    }
  }

  func redo() async {
    guard canRedo, let objects = redoStack.last, let snapshot else { return }
    if await apply(objects) {
      redoStack.removeLast()
      undoStack.append(snapshot.objects)
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

  private func apply(_ objects: [Object]) async -> Bool {
    guard !isBusy, let snapshot else { return false }
    isBusy = true
    defer { isBusy = false }
    do {
      self.snapshot = try await surface.applyPresetObjects(
        expectedRevision: snapshot.revision, objects: objects)
      if !(self.snapshot?.objects.contains { $0.id == selectedID } ?? false) { selectedID = nil }
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
