import IdleScreenRenderer
import Observation

@MainActor
@Observable
final class IdleScreenPlantedTankEditor {
  typealias Object = IdleScreenAquariumWebSurface.PresetObject
  static let shared = IdleScreenPlantedTankEditor()
  @ObservationIgnored let surface = IdleScreenAquariumWebSurface()
  private(set) var snapshot: IdleScreenAquariumWebSurface.EditorSnapshot?
  private(set) var errorMessage: String?
  private(set) var isBusy = false
  var selectedID: String?
  private var undoStack: [[Object]] = []
  private var redoStack: [[Object]] = []
  @ObservationIgnored private var wantsVisible = false
  @ObservationIgnored private var isActivating = false

  var canUndo: Bool { !isBusy && !undoStack.isEmpty }
  var canRedo: Bool { !isBusy && !redoStack.isEmpty }
  var selectedObject: Object? { snapshot?.objects.first { $0.id == selectedID } }

  func activate() async {
    guard !Task.isCancelled else { return }
    wantsVisible = true
    guard !isActivating else { return }
    isActivating = true
    defer { isActivating = false }
    do {
      if surface.state == .unloaded {
        guard let url = IdleScreenAquariumRuntime.sceneURL else {
          throw IdleScreenAquariumWebSurface.SurfaceError.invalidLocalResource
        }
        try await surface.load(sceneURL: url)
        snapshot = try await surface.beginEditing()
      }
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

  private func apply(_ objects: [Object]) async -> Bool {
    guard !isBusy, let snapshot else { return false }
    isBusy = true
    defer { isBusy = false }
    do {
      self.snapshot = try await surface.applyPresetObjects(
        expectedRevision: snapshot.revision, objects: objects)
      if !(self.snapshot?.objects.contains { $0.id == selectedID } ?? false) { selectedID = nil }
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      self.snapshot = (try? await surface.editorSnapshot()) ?? snapshot
      return false
    }
  }
}
