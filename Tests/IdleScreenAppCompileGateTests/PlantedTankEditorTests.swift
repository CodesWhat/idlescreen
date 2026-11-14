import IdleScreenRenderer
import Testing

@Suite("Planted tank editor", .timeLimit(.minutes(1)))
@MainActor
struct PlantedTankEditorTests {
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

}
