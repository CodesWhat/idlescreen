import AppKit
import Foundation
import IdleScreenRenderer
import Testing
import WebKit

@Suite("Planted tank editor", .timeLimit(.minutes(1)))
@MainActor
struct PlantedTankEditorTests {
  @Test func animalUndoAndRedoKeepIdentityAndIndependentLayoutHistory() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    await editor.add(assetID: "rotala", positionCm: .init(x: -22, y: 5, z: 12))
    let plant = try #require(editor.snapshot?.placedObjects.first)
    let originalIDs = try #require(editor.snapshot).animals.map(\.id)
    await editor.addAnimal(assetID: "shrimp/blue-dream")
    let added = try #require(editor.snapshot?.animals.first { !originalIDs.contains($0.id) })
    #expect(editor.canUndoAnimals && editor.canUndo)
    await editor.undoAnimals()
    #expect(editor.errorMessage == nil)
    #expect(editor.snapshot?.animals.map(\.id) == originalIDs)
    #expect(editor.snapshot?.placedObjects == [plant])
    #expect(editor.canRedoAnimals && editor.canUndo)
    await editor.redoAnimals()
    #expect(editor.errorMessage == nil)
    #expect(editor.snapshot?.animals.contains { $0.id == added.id } == true)
    await editor.removeAnimal(id: added.id)
    await editor.undoAnimals()
    #expect(editor.snapshot?.animals.contains { $0.id == added.id } == true)
    await editor.undo()
    #expect(editor.snapshot?.placedObjects.isEmpty == true)
    #expect(editor.snapshot?.animals.contains { $0.id == added.id } == true)
    try await editor.surface.shutdown()
  }

  @Test func failedAnimalUndoRetainsHistoryAndReloadClearsIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenPlantedTankStore(fileURL: directory.appendingPathComponent("tank.json"))
    let editor = IdleScreenPlantedTankEditor(store: store)
    await editor.activate()
    await editor.addAnimal(assetID: "fish/chili")
    let current = editor.surface
    let ids = try #require(editor.snapshot).animals.map(\.id)
    let external = try await current.exportTank(id: "planted-tank", name: "External edit")
    let revision = try await store.read().revision
    _ = try await store.write(external, expectedRevision: revision)
    await editor.undoAnimals()
    #expect(editor.errorMessage != nil)
    #expect(editor.surface === current)
    #expect(editor.snapshot?.animals.map(\.id) == ids)
    #expect(editor.canUndoAnimals && !editor.canRedoAnimals)
    #expect(try await store.read().data == external)
    await editor.reloadCheckpoint()
    #expect(editor.errorMessage == nil)
    #expect(!editor.canUndoAnimals && !editor.canRedoAnimals)
    try await editor.surface.shutdown()
  }

  @Test func animalRedoStaysPausedAfterHidingDuringUndo() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    await editor.addAnimal(assetID: "fish/chili")
    let ids = try #require(editor.snapshot).animals.map(\.id)
    let old = editor.surface
    let undo = Task { await editor.undoAnimals() }
    for _ in 0..<1000 {
      if editor.isBusy { break }
      await Task.yield()
    }
    #expect(editor.isBusy)
    await editor.deactivate()
    await undo.value
    #expect(editor.errorMessage == nil && editor.canRedoAnimals)
    #expect(old.state == .stopped && editor.surface.state == .paused)
    await editor.redoAnimals()
    #expect(editor.errorMessage == nil)
    #expect(editor.snapshot?.animals.map(\.id) == ids)
    #expect(editor.surface.state == .paused)
    try await editor.surface.shutdown()
  }

  @Test func animalUndoDoesNotResurrectADeadAddition() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    await editor.addAnimal(assetID: "fish/chili")
    let count = try #require(editor.snapshot).animals.filter { $0.kind == "fish" }.count
    await editor.deactivate()
    _ = try await editor.surface.view.evaluateJavaScript(
      "for(let i=0;i<\(count);i++) aquariumStudy.previewLifeEvent('death'); true")
    let current = editor.surface
    let before = try await current.exportTank(id: "planted-tank", name: "Planted tank")
    await editor.undoAnimals()
    #expect(editor.errorMessage?.contains("living animal") == true)
    #expect(editor.surface === current && editor.surface.state == .paused)
    #expect(editor.canUndoAnimals && !editor.canRedoAnimals)
    #expect(try await current.exportTank(id: "planted-tank", name: "Planted tank") == before)
    try await editor.surface.shutdown()
  }

  @Test func animalUndoRetainsTheCurrentPopulationWhenCapacityChanged() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    let animal = try #require(editor.snapshot?.animals.first { $0.alive })
    await editor.removeAnimal(id: animal.id)
    await editor.deactivate()
    _ = try await editor.surface.view.evaluateJavaScript(
      """
      (() => {
        let i=0;
        while(aquariumStudy.state.ecology.animals.length<80) {
          aquariumStudy.addStock({assetID:'fish/chili',id:'stock-independent-'+i++});
        }
        return true;
      })()
      """)
    let current = editor.surface
    let before = try await current.exportTank(id: "planted-tank", name: "Planted tank")
    await editor.undoAnimals()
    #expect(editor.errorMessage?.contains("capacity") == true)
    #expect(editor.surface === current && editor.surface.state == .paused)
    #expect(editor.canUndoAnimals && !editor.canRedoAnimals)
    #expect(try await current.exportTank(id: "planted-tank", name: "Planted tank") == before)
    try await editor.surface.shutdown()
  }

  @Test func removingLivingStockReplacesTheSurfaceAndSurvivesReopening() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenPlantedTankStore(fileURL: directory.appendingPathComponent("tank.json"))
    let editor = IdleScreenPlantedTankEditor(store: store)
    await editor.activate()
    let original = editor.surface
    let animal = try #require(editor.snapshot?.animals.first { $0.alive })
    let retained = try #require(editor.snapshot).animals.map(\.id).filter { $0 != animal.id }
    await editor.removeAnimal(id: animal.id)
    #expect(editor.errorMessage == nil)
    #expect(editor.surface !== original)
    #expect(original.state == .stopped)
    #expect(editor.snapshot?.animals.map(\.id) == retained)
    await editor.deactivate()
    let reopened = IdleScreenPlantedTankEditor(store: store)
    await reopened.activate()
    #expect(reopened.errorMessage == nil)
    #expect(reopened.snapshot?.animals.map(\.id) == retained)
    await reopened.deactivate()
    try await editor.surface.shutdown()
    try await reopened.surface.shutdown()
  }

  @Test(arguments: [false, true])
  func aStaleStockSaveRetainsTheCurrentSurfaceAndExternalFile(adding: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenPlantedTankStore(fileURL: directory.appendingPathComponent("tank.json"))
    let editor = IdleScreenPlantedTankEditor(store: store)
    await editor.activate()
    await editor.save()
    let original = editor.surface
    let animal = try #require(editor.snapshot?.animals.first { $0.alive })
    let originalIDs = try #require(editor.snapshot).animals.map(\.id)
    let external = try await original.exportTank(id: "planted-tank", name: "External edit")
    let revision = try await store.read().revision
    _ = try await store.write(external, expectedRevision: revision)
    if adding {
      await editor.addAnimal(assetID: "fish/chili")
    } else {
      await editor.removeAnimal(id: animal.id)
    }
    #expect(editor.errorMessage != nil)
    #expect(editor.surface === original)
    #expect(editor.surface.state == .running)
    #expect(editor.snapshot?.animals.map(\.id) == originalIDs)
    #expect(try await store.read().data == external)
    try await editor.surface.shutdown()
  }

  @Test(arguments: [false, true])
  func stockReplacementRemainsPausedWhenTheWorkspaceHides(adding: Bool) async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    let original = editor.surface
    let animal = try #require(editor.snapshot?.animals.first { $0.alive })
    let count = try #require(editor.snapshot).animals.count
    let removal = Task {
      if adding {
        await editor.addAnimal(assetID: "fish/chili")
      } else {
        await editor.removeAnimal(id: animal.id)
      }
    }
    for _ in 0..<1000 {
      if editor.isBusy { break }
      await Task.yield()
    }
    #expect(editor.isBusy)
    await editor.deactivate()
    await removal.value
    #expect(editor.errorMessage == nil)
    #expect(editor.surface !== original)
    #expect(original.state == .stopped)
    #expect(editor.surface.state == .paused)
    #expect(editor.snapshot?.animals.contains { $0.id == animal.id } == adding)
    #expect(editor.snapshot?.animals.count == count + (adding ? 1 : -1))
    try await editor.surface.shutdown()
  }

  @Test func newStockSurvivesReopeningWithItsOwnIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenPlantedTankStore(fileURL: directory.appendingPathComponent("tank.json"))
    let editor = IdleScreenPlantedTankEditor(store: store)
    await editor.activate()
    let original = editor.surface
    let retainedIDs = try #require(editor.snapshot).animals.map(\.id)
    await editor.addAnimal(assetID: "shrimp/blue-dream")
    #expect(editor.errorMessage == nil)
    #expect(editor.surface !== original)
    #expect(original.state == .stopped)
    let added = try #require(editor.snapshot?.animals.first { !retainedIDs.contains($0.id) })
    #expect(added.kind == "shrimp" && added.variant == "blue-dream" && added.alive)
    #expect(editor.selectedID == added.id)
    #expect(editor.animalLabel(added) == "Blue Dream Shrimp")
    let cleaner = try #require(editor.snapshot?.animals.first { $0.species == "otocinclus" })
    #expect(editor.animalLabel(cleaner) == "Otocinclus")
    await editor.deactivate()
    let reopened = IdleScreenPlantedTankEditor(store: store)
    await reopened.activate()
    #expect(reopened.errorMessage == nil)
    #expect(reopened.snapshot?.animals.map(\.id).contains(added.id) == true)
    #expect(
      retainedIDs.allSatisfy { id in reopened.snapshot?.animals.contains { $0.id == id } == true })
    await reopened.deactivate()
    try await editor.surface.shutdown()
    try await reopened.surface.shutdown()
  }

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

  @Test func pointerPlacementAndMovementUseCollisionChecksAndCurrentSurface() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    await editor.beginPlacing(assetID: "rotala")
    #expect(editor.pointerTool == .place)
    let initial = try #require(editor.snapshot)
    await editor.handlePick(
      .init(
        revision: initial.revision - 1, tool: .place, id: nil,
        positionCm: .init(x: -22, y: 5, z: 12), toolGeneration: editor.surface.toolGeneration))
    #expect(editor.snapshot == initial)
    await editor.handlePick(
      .init(
        revision: initial.revision, tool: .place, id: nil,
        positionCm: .init(x: 29, y: 5, z: 12), toolGeneration: editor.surface.toolGeneration))
    #expect(editor.errorMessage != nil)
    #expect(editor.pointerTool == .place)
    #expect(editor.snapshot == initial)
    await editor.handlePick(
      .init(
        revision: initial.revision, tool: .place, id: nil,
        positionCm: .init(x: -22, y: 5, z: 12), toolGeneration: editor.surface.toolGeneration))
    #expect(editor.errorMessage == nil)
    #expect(editor.pointerTool == .select)
    let plant = try #require(editor.selectedObject)
    await editor.beginMoving()
    #expect(editor.pointerTool == .move)
    await editor.handlePick(
      .init(
        revision: try #require(editor.snapshot).revision, tool: .move,
        id: plant.id, positionCm: .init(x: -21, y: 5, z: 12),
        toolGeneration: editor.surface.toolGeneration))
    #expect(editor.errorMessage == nil)
    #expect(editor.pointerTool == .select)
    #expect(editor.selectedObject?.positionCm.x == -21)
    await editor.undo()
    #expect(editor.selectedObject?.positionCm.x == -22)
    await editor.beginPlacing(assetID: "rotala")
    await editor.cancelPointerTool()
    #expect(editor.pointerTool == .select)
    await editor.deactivate()
    try await editor.surface.shutdown()
  }

  @Test func aCanvasClickReachesTheNativeEditorAndCreatesAPlant() async throws {
    let editor = IdleScreenPlantedTankEditor()
    editor.surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    await editor.activate()
    await editor.beginPlacing(assetID: "rotala")
    let script = """
      (() => {
        const s=aquariumStudy.state,c=s.camera;
        const camera=new THREE.PerspectiveCamera(c.fov,c.aspect,.1,1000);
        camera.position.fromArray(c.position);camera.lookAt(...c.target);
        camera.projectionMatrix.elements[9]=2*c.horizonPercent/100-1;camera.updateMatrixWorld();
        const centerZ=(s.world.floorBackZ+s.world.floorFrontZ)/2;
        const p=new THREE.Vector3(-22/s.physical.cmPerUnit,5/s.physical.cmPerUnit,centerZ+12/s.physical.cmPerUnit).project(camera);
        const canvas=document.querySelector('canvas'),r=canvas.getBoundingClientRect();
        canvas.dispatchEvent(new PointerEvent('pointerdown',{button:0,clientX:r.left+(p.x+1)*r.width/2,clientY:r.top+(1-p.y)*r.height/2}));
        return 'clicked';
      })()
      """
    _ = try await editor.surface.view.evaluateJavaScript(script)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while (editor.snapshot?.placedObjects.isEmpty == true || editor.isBusy)
      && ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(editor.errorMessage == nil)
    let plant = try #require(editor.selectedObject)
    #expect(plant.assetId == "rotala")
    #expect(abs(plant.positionCm.x + 22) < 0.001)
    #expect(abs(plant.positionCm.z - 12) < 0.001)
    #expect(editor.pointerTool == .select)
    #expect(editor.canUndo)
    await editor.undo()
    #expect(editor.snapshot?.placedObjects.isEmpty == true)
    await editor.deactivate()
    try await editor.surface.shutdown()
  }

  @Test func hiddenEditorsIgnoreQueuedPointerHits() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    await editor.beginPlacing(assetID: "rotala")
    let initial = try #require(editor.snapshot)
    let oldGeneration = editor.surface.toolGeneration
    await editor.deactivate()
    #expect(editor.pointerTool == .select)
    await editor.activate()
    await editor.handlePick(
      .init(
        revision: initial.revision, tool: .place, id: nil,
        positionCm: .init(x: -22, y: 5, z: 12), toolGeneration: oldGeneration))
    #expect(editor.snapshot == initial)
    #expect(!editor.canUndo)
    await editor.deactivate()
    try await editor.surface.shutdown()
  }

  @Test func queuedPicksCannotCrossToolActivations() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    await editor.beginPlacing(assetID: "rotala")
    let oldGeneration = editor.surface.toolGeneration
    let initial = try #require(editor.snapshot)
    await editor.cancelPointerTool()
    await editor.beginPlacing(assetID: "rotala")
    await editor.handlePick(
      .init(
        revision: initial.revision, tool: .place, id: nil,
        positionCm: .init(x: -22, y: 5, z: 12), toolGeneration: oldGeneration))
    #expect(editor.snapshot == initial)
    #expect(!editor.canUndo)
    await editor.deactivate()
    try await editor.surface.shutdown()
  }

  @Test func presetSelectionAndPointerMovesUseExistingUndoHistory() async throws {
    let editor = IdleScreenPlantedTankEditor()
    await editor.activate()
    let initial = try #require(editor.snapshot)
    let rock = try #require(initial.objects.first { $0.id == "base-rock" })
    await editor.handlePick(
      .init(
        revision: initial.revision, tool: .select, id: rock.id,
        positionCm: nil, toolGeneration: editor.surface.toolGeneration))
    #expect(editor.selectedID == rock.id)
    #expect(editor.canMoveSelected)
    await editor.beginMoving()
    #expect(editor.pointerTool == .move)
    var position = rock.positionCm
    position.z += 3
    await editor.handlePick(
      .init(
        revision: initial.revision, tool: .move, id: rock.id,
        positionCm: position, toolGeneration: editor.surface.toolGeneration))
    #expect(editor.errorMessage == nil)
    #expect(editor.pointerTool == .select)
    #expect(editor.snapshot?.objects.first { $0.id == rock.id }?.positionCm.z == position.z)
    #expect(editor.canUndo)
    await editor.undo()
    #expect(
      abs(
        try #require(editor.snapshot?.objects.first { $0.id == rock.id }).positionCm.z
          - rock.positionCm.z) < 1e-9)
    await editor.deactivate()
    try await editor.surface.shutdown()
  }

  @Test func equipmentEditsHaveHistoryAndCannotUseUnsupportedStockOperations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenPlantedTankStore(fileURL: directory.appendingPathComponent("tank.json"))
    let editor = IdleScreenPlantedTankEditor(store: store)
    await editor.activate()
    let original = try #require(
      editor.snapshot?.equipmentObjects.first { $0.id == "equipment/filter" })
    var moved = original
    moved.positionCm.x = 18
    await editor.update(moved)
    #expect(editor.errorMessage == nil)
    #expect(editor.canUndo)
    #expect(editor.snapshot?.equipmentObjects.first { $0.id == original.id }?.positionCm.x == 18)
    editor.selectedID = original.id
    #expect(!editor.canRemoveSelected)
    #expect(!editor.canRotateSelected)
    await editor.removeSelected()
    #expect(editor.snapshot?.equipmentObjects.count == 3)
    await editor.undo()
    #expect(editor.snapshot?.equipmentObjects.first { $0.id == original.id } == original)
    await editor.redo()
    #expect(editor.snapshot?.equipmentObjects.first { $0.id == original.id }?.positionCm.x == 18)
    await editor.deactivate()
    let reopened = IdleScreenPlantedTankEditor(store: store)
    await reopened.activate()
    #expect(reopened.errorMessage == nil)
    #expect(reopened.snapshot?.equipmentObjects.first { $0.id == original.id }?.positionCm.x == 18)
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
