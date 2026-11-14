import Foundation
import IdleScreenRenderer
import Testing

@Suite("Planted tank editor", .timeLimit(.minutes(1)))
@MainActor
struct PlantedTankEditorTests {
  @Test func addedPlantsHaveIndependentHistoryAndSurviveReopening() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenPlantedTankStore(fileURL: directory.appendingPathComponent("tank.json"))
    let editor = IdleScreenPlantedTankEditor(store: store)
    await editor.activate()
    await editor.add(assetID: "rotala", positionCm: .init(x: -22, y: 5, z: 12))
    #expect(editor.errorMessage == nil)
    let plant = try #require(editor.snapshot?.placedObjects.first)
    #expect(editor.selectedID == plant.id)
    var rock = try #require(editor.snapshot?.objects.first { $0.id == "base-rock" })
    rock.positionCm.z += 3
    await editor.update(rock)
    await editor.undo()
    #expect(editor.snapshot?.placedObjects == [plant])
    await editor.undo()
    #expect(editor.snapshot?.placedObjects.isEmpty == true)
    await editor.redo()
    #expect(editor.snapshot?.placedObjects == [plant])
    await editor.redo()
    #expect(editor.snapshot?.objects.first { $0.id == rock.id }?.positionCm.z == rock.positionCm.z)
    let retained = editor.snapshot
    await editor.add(assetID: "rotala", positionCm: .init(x: 29, y: 5, z: 12))
    #expect(editor.errorMessage != nil)
    #expect(editor.snapshot == retained)
    #expect(!editor.canRedo)
    editor.selectedID = plant.id
    await editor.removeSelected()
    #expect(editor.snapshot?.placedObjects.isEmpty == true)
    await editor.undo()
    #expect(editor.snapshot?.placedObjects == [plant])
    await editor.deactivate()
    let reopened = IdleScreenPlantedTankEditor(store: store)
    await reopened.activate()
    #expect(reopened.errorMessage == nil)
    #expect(reopened.snapshot?.placedObjects == [plant])
    #expect(!reopened.canUndo)
    await reopened.deactivate()
    try await editor.surface.shutdown()
    try await reopened.surface.shutdown()
  }

  @Test func undoAndRedoUseCurrentRevisionsAndRejectedEditsLeaveHistoryIntact() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    #expect(editor.errorMessage == nil)
    let initial = try #require(editor.snapshot)
    let rock = try #require(initial.objects.first { $0.id == "base-rock" })
    var moved = rock
    moved.positionCm.z += 3
    await editor.update(moved)
    #expect(editor.canUndo)
    #expect(!editor.canRedo)
    #expect(editor.snapshot?.objects.first { $0.id == rock.id }?.positionCm.z == moved.positionCm.z)
    let edited = try #require(editor.snapshot)
    moved.positionCm.x = 50
    await editor.update(moved)
    #expect(editor.errorMessage != nil)
    #expect(editor.snapshot == edited)
    #expect(editor.canUndo)
    await editor.undo()
    #expect(editor.errorMessage == nil)
    #expect(!editor.canUndo)
    #expect(editor.canRedo)
    #expect(
      abs(
        try #require(editor.snapshot?.objects.first { $0.id == rock.id }).positionCm.z
          - rock.positionCm.z) < 1e-9)
    await editor.redo()
    #expect(editor.canUndo)
    #expect(!editor.canRedo)
    #expect(
      editor.snapshot?.objects.first { $0.id == rock.id }?.positionCm.z == rock.positionCm.z + 3)
    editor.selectedID = rock.id
    await editor.removeSelected()
    #expect(editor.snapshot?.objects.contains { $0.id == rock.id } == false)
    #expect(editor.selectedID == nil)
    await editor.undo()
    #expect(editor.snapshot?.objects.contains { $0.id == rock.id } == true)
    await editor.deactivate()
    #expect(editor.surface.state == .paused)
    let retained = editor.snapshot
    await editor.activate()
    #expect(editor.snapshot == retained)
    await editor.deactivate()
    try await editor.surface.shutdown()
  }

  @Test func disappearingDuringLoadDoesNotResumeTheHiddenSurface() async throws {
    let editor = IdleScreenPlantedTankEditor()
    let loading = Task { await editor.activate() }
    while editor.surface.state == .unloaded { await Task.yield() }
    await editor.deactivate()
    await loading.value
    #expect(editor.surface.state == .paused)
    #expect(editor.errorMessage == nil)
    try await editor.surface.shutdown()
  }
  @Test func returningDuringACancelledLoadResumesOnlyTheCurrentPresentation() async throws {
    let editor = IdleScreenPlantedTankEditor()
    let loading = Task { await editor.activate() }
    while editor.surface.state == .unloaded { await Task.yield() }
    loading.cancel()
    await editor.deactivate()
    await editor.activate()
    await loading.value
    #expect(editor.surface.state == .running)
    await editor.deactivate()
    try await editor.surface.shutdown()
  }

  @Test func aSavedTankReopensWithoutResettingItsEditedLayout() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenPlantedTankStore(fileURL: directory.appendingPathComponent("tank.json"))
    let first = IdleScreenPlantedTankEditor(store: store)
    await first.activate()
    var rock = try #require(first.snapshot?.objects.first { $0.id == "base-rock" })
    rock.positionCm.z += 3
    await first.update(rock)
    await first.save()
    #expect(first.savedAt != nil)
    #expect(first.errorMessage == nil)
    await first.deactivate()
    let second = IdleScreenPlantedTankEditor(store: store)
    await second.activate()
    #expect(second.errorMessage == nil)
    let reopened = try #require(second.snapshot?.objects.first { $0.id == rock.id })
    #expect(abs(reopened.positionCm.z - rock.positionCm.z) < 1e-9)
    #expect(!second.canUndo)
    await second.deactivate()
    try await first.surface.shutdown()
    try await second.surface.shutdown()
  }

  @Test func anUnreadableCheckpointIsPreservedAndSavingStaysDisabled() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tank.json")
    let corrupt = Data("{".utf8)
    try corrupt.write(to: url)
    let editor = IdleScreenPlantedTankEditor(store: IdleScreenPlantedTankStore(fileURL: url))
    await editor.activate()
    #expect(editor.errorMessage != nil)
    #expect(editor.snapshot == nil)
    #expect(!editor.canSave)
    #expect(editor.surface.state == .paused)
    await editor.save()
    await editor.deactivate()
    #expect(try Data(contentsOf: url) == corrupt)
    try await editor.surface.shutdown()
  }

  @Test func theCompileGateWorkspaceCannotWriteTheUsersDevelopmentTank() async throws {
    let editor = IdleScreenPlantedTankEditor.shared
    await editor.activate()
    #expect(editor.snapshot != nil)
    #expect(!editor.canSave)
    await editor.deactivate()
  }

  @Test func reloadingAChangedCheckpointUsesAFreshSurfaceAndKeepsTheOldTankOnFailure() async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tank.json")
    let store = IdleScreenPlantedTankStore(fileURL: url)
    let first = IdleScreenPlantedTankEditor(store: store)
    await first.activate()
    await first.save()
    let second = IdleScreenPlantedTankEditor(store: store)
    await second.activate()
    var rock = try #require(second.snapshot?.objects.first { $0.id == "base-rock" })
    rock.positionCm.z += 3
    await second.update(rock)
    #expect(second.errorMessage == nil)
    await first.save()
    #expect(first.errorMessage != nil)
    let oldSurface = first.surface
    let reopening = Task { await first.reloadCheckpoint() }
    while !first.isBusy { await Task.yield() }
    await first.deactivate()
    await first.activate()
    #expect(oldSurface.state != .running)
    await reopening.value
    #expect(first.errorMessage == nil)
    #expect(first.surface !== oldSurface)
    #expect(oldSurface.state == .stopped)
    #expect(
      abs(
        try #require(first.snapshot?.objects.first { $0.id == rock.id }).positionCm.z
          - rock.positionCm.z) < 1e-9)
    let retainedSurface = first.surface
    let retained = try await first.surface.exportTank(id: "planted-tank", name: "Planted tank")
    try Data("{".utf8).write(to: url)
    await first.reloadCheckpoint()
    #expect(first.errorMessage != nil)
    #expect(first.surface === retainedSurface)
    #expect(
      try await first.surface.exportTank(id: "planted-tank", name: "Planted tank") == retained)
    #expect(first.surface.state == .running)
    try await first.surface.shutdown()
    try await second.surface.shutdown()
  }

}
