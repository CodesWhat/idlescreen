import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit

@testable import IdleScreenRenderer

@Suite("Bundled Three.js aquarium", .timeLimit(.minutes(1)))
@MainActor
struct AquariumRuntimeBundleTests {
  @Test func actualAquariumLoadsAndPreservesItsCoupledLifeAcrossPauses() async throws {
    let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
    #expect(resource.path.contains("IdleScreenRenderer.framework/"))
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    surface.view.configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.frameClock(emulatingVisibleDocument: true), injectionTime: .atDocumentStart,
        forMainFrameOnly: true)
    )
    try await surface.load(sceneURL: resource)
    let initial = try await snapshot(surface)
    #expect(initial.revision == "160")
    #expect(!initial.documentHidden)
    #expect(!initial.scene.motion)
    #expect(initial.pendingFrames == 0)
    #expect(initial.scene.physical.tankCm.width == 60)
    #expect(initial.scene.physical.tankCm.depth == 36)
    #expect(initial.scene.physical.tankCm.height == 36)
    #expect(initial.scene.water.volumeL == 50)
    #expect(initial.scene.condition.mode == "ecosystem")
    #expect(initial.scene.renderedFrames > 0)
    #expect(initial.scene.drawCalls > 0)
    #expect(initial.scene.triangles > 0)
    #expect(!initial.scene.ecology.animals.isEmpty)
    #expect(initial.visibleControls == 0)

    try await surface.resume()
    try await surface.resume()
    let running = try await snapshot(surface, frames: 3)
    #expect(running.pendingFrames == 1)
    #expect(running.scene.renderedFrames > initial.scene.renderedFrames)
    #expect(running.scene.water.elapsedSeconds > initial.scene.water.elapsedSeconds)
    #expect(running.scene.ecology.seconds == running.scene.water.elapsedSeconds)
    #expect(running.scene.ecology.animals.map(\.id) == initial.scene.ecology.animals.map(\.id))

    try await surface.pause()
    let paused = try await snapshot(surface, frames: 3)
    #expect(paused.pendingFrames == 0)
    #expect(paused.scene.clock == running.scene.clock)
    #expect(paused.scene.water.elapsedSeconds == running.scene.water.elapsedSeconds)
    #expect(paused.scene.ecology.animals == running.scene.ecology.animals)

    try await surface.resume()
    let resumed = try await snapshot(surface, frames: 3)
    #expect(resumed.pendingFrames == 1)
    #expect(resumed.scene.clock > paused.scene.clock)
    #expect(resumed.scene.water.elapsedSeconds > paused.scene.water.elapsedSeconds)
    #expect(resumed.scene.ecology.animals.map(\.id) == paused.scene.ecology.animals.map(\.id))
    try await surface.shutdown()
    #expect(surface.state == .stopped)
  }

  @Test func anUnattachedHiddenDocumentDoesNotAdvanceLife() async throws {
    let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    surface.view.configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.frameClock(emulatingVisibleDocument: false), injectionTime: .atDocumentStart,
        forMainFrameOnly: true))
    try await surface.load(sceneURL: resource)
    let initial = try await snapshot(surface)
    #expect(initial.documentHidden)
    try await surface.resume()
    let hidden = try await snapshot(surface, frames: 3)
    #expect(hidden.pendingFrames == 0)
    #expect(hidden.scene.clock == initial.scene.clock)
    #expect(hidden.scene.water.elapsedSeconds == initial.scene.water.elapsedSeconds)
    #expect(hidden.scene.ecology.animals == initial.scene.ecology.animals)
    try await surface.shutdown()
  }

  @Test func bundleContainsOnlyDeclaredRuntimeAndPinnedVendor() throws {
    let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
    let directory = resource.deletingLastPathComponent().resolvingSymlinksInPath()
    let manifest = try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("PROVENANCE.json")))
    let entry = try String(contentsOf: resource, encoding: .utf8)
    let scripts = entry.matches(of: /<script src="([^"]+)"/).map { String($0.1) }
    #expect(scripts == manifest.scriptOrder)
    #expect(scripts.allSatisfy { !$0.contains(":") && !$0.hasPrefix("/") && !$0.contains("..") })
    let enumerator = try #require(
      FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    )
    var files: Set<String> = []
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        files.insert(String(url.path.dropFirst(directory.path.count + 1)))
      }
    }
    #expect(files == Set(scripts + ["index.html", "PROVENANCE.json", "vendor/LICENSE"]))
    #expect(
      Set(manifest.importedFiles.map(\.path))
        == Set(scripts.filter { $0 != "native-host.js" } + ["vendor/LICENSE"]))
    #expect(manifest.vendor.revision == "160")
    for (path, expected) in [
      ("vendor/three.min.js", manifest.vendor.sha256),
      ("vendor/LICENSE", manifest.vendor.licenseSha256),
    ] {
      let data = try Data(contentsOf: directory.appendingPathComponent(path))
      #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected)
    }
  }

  @Test func collisionQueriesPreserveContactsWithoutScanningDistantTriangles() async throws {
    let fixture = try #require(
      Bundle(for: AquariumCollisionFixtureBundle.self).url(
        forResource: "collision-check", withExtension: "js", subdirectory: "WebSurfaceProof"))
    let source = try String(contentsOf: fixture, encoding: .utf8)
    let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
    let surface = IdleScreenAquariumWebSurface()
    try await surface.load(sceneURL: resource)
    let script = source + "\nJSON.stringify(runAquariumCollisionCheck(THREE, AquariumCollisions));"
    let json: String = try await withCheckedThrowingContinuation { continuation in
      surface.view.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let text = value as? String {
          continuation.resume(returning: text)
        } else {
          continuation.resume(throwing: CocoaError(.coderValueNotFound))
        }
      }
    }
    let result = try JSONDecoder().decode([String: Int].self, from: Data(json.utf8))
    #expect(result["samples"] == 24)
    #expect(result["bodyQueries"] == 6)
    #expect(try #require(result["maxVertexReads"]) < 500)
    try await surface.shutdown()
  }

  @Test func existingObjectValidationKeepsGeometryAndRefreshesObstacles() async throws {
    let result = try await runPresetFixture(
      "preset-edit-check",
      invocation:
        "runAquariumPresetEditCheck(THREE, AquariumDesignerPlacement, AquariumRootedPlantsV2)")
    #expect(result["checks"] == 9)
  }

  @Test func editingPresetObjectsPreservesLifeAndRestoresActualCollisionSurfaces() async throws {
    let result = try await runPresetFixture(
      "preset-scene-check", invocation: "runAquariumPresetSceneCheck(aquariumStudy)")
    #expect(result["checks"] == 10)
  }

  @Test func placedAssetsAreRevisionFencedAndRejectedWithoutChangingLife() async throws {
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let initial = try await surface.beginEditing()
    #expect(initial.catalog.count == 15)
    #expect(initial.placedObjects.isEmpty)
    #expect(!initial.catalog.contains { $0.id == "pirate-chest" })
    let before = try await surface.exportTank(id: "test", name: "Test")
    let plant = IdleScreenAquariumWebSurface.PresetObject(
      id: "placed-test", assetId: "rotala", positionCm: .init(x: -22, y: 5, z: 12), rotationY: 0)
    let edited = try await surface.applyPlacedObjects(
      expectedRevision: initial.revision, objects: [plant])
    #expect(edited.revision > initial.revision)
    #expect(edited.placedObjects == [plant])
    #expect(edited.objects == initial.objects)
    #expect(
      try await surface.applyPlacedObjects(expectedRevision: edited.revision, objects: [plant])
        == edited)
    await #expect(throws: IdleScreenAquariumWebSurface.EditorError.self) {
      try await surface.applyPlacedObjects(expectedRevision: initial.revision, objects: [])
    }
    for invalid in [
      IdleScreenAquariumWebSurface.PresetObject(
        id: "placed-test", assetId: "rotala", positionCm: .init(x: 29, y: 5, z: 12), rotationY: 0),
      IdleScreenAquariumWebSurface.PresetObject(
        id: "base-conflict", assetId: "rotala", positionCm: plant.positionCm, rotationY: 0),
    ] {
      await #expect(throws: IdleScreenAquariumWebSurface.EditorError.self) {
        try await surface.applyPlacedObjects(expectedRevision: edited.revision, objects: [invalid])
      }
      #expect(try await surface.editorSnapshot() == edited)
    }
    let after = try await surface.exportTank(id: "test", name: "Test")
    let first = try #require(JSONSerialization.jsonObject(with: before) as? NSDictionary)
    let last = try #require(JSONSerialization.jsonObject(with: after) as? NSDictionary)
    #expect(first["runtime"] as? NSDictionary == last["runtime"] as? NSDictionary)
    let removed = try await surface.applyPlacedObjects(
      expectedRevision: edited.revision, objects: [])
    #expect(removed.placedObjects.isEmpty)
    try await surface.shutdown()
  }

  @Test func movingAPresetCannotBuryAnAddedPlant() async throws {
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let initial = try await surface.beginEditing()
    let rock = try #require(initial.objects.first { $0.id == "base-rock" })
    let plant = IdleScreenAquariumWebSurface.PresetObject(
      id: "placed-rooted", assetId: "rotala", positionCm: .init(x: -22, y: 5, z: 12), rotationY: 0)
    let planted = try await surface.applyPlacedObjects(
      expectedRevision: initial.revision, objects: [plant])
    let before = try await surface.exportTank(id: "test", name: "Test")
    var moved = rock
    moved.positionCm.x = -20
    moved.positionCm.z = 10
    await #expect(throws: IdleScreenAquariumWebSurface.EditorError.self) {
      try await surface.applyPresetObjects(
        expectedRevision: planted.revision,
        objects: planted.objects.map { $0.id == rock.id ? moved : $0 })
    }
    #expect(try await surface.editorSnapshot() == planted)
    #expect(try await surface.exportTank(id: "test", name: "Test") == before)
    try await surface.shutdown()
  }

  @Test func nativePointerToolsReportRealBedHitsWithoutEditingTheLayout() async throws {
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let initial = try await surface.beginEditing()
    var received: IdleScreenAquariumWebSurface.EditorPick?
    var receivedCount = 0
    surface.onEditorPick = {
      received = $0
      receivedCount += 1
    }
    let placing = try await surface.setEditorTool(.place, assetID: "rotala")
    #expect(placing == initial)
    let script = """
      (() => {
        const s = aquariumStudy.state, c = s.camera;
        const camera = new THREE.PerspectiveCamera(c.fov,c.aspect,.1,1000);
        camera.position.fromArray(c.position);camera.lookAt(...c.target);
        camera.projectionMatrix.elements[9]=2*c.horizonPercent/100-1;
        camera.updateMatrixWorld();
        const centerZ=(s.world.floorBackZ+s.world.floorFrontZ)/2;
        const p=new THREE.Vector3(-22/s.physical.cmPerUnit,5/s.physical.cmPerUnit,centerZ+12/s.physical.cmPerUnit).project(camera);
        const canvas=document.querySelector('canvas'),r=canvas.getBoundingClientRect();
        canvas.dispatchEvent(new PointerEvent('pointerdown',{button:0,clientX:r.left+(p.x+1)*r.width/2,clientY:r.top+(1-p.y)*r.height/2}));
        window.idleScreenScene.setEditorTool({tool:'select',generation:42});
        return 'clicked';
      })()
      """
    _ = try await surface.view.evaluateJavaScript(script)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while received == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let pick = try #require(received)
    #expect(pick.tool == .place)
    #expect(pick.revision == initial.revision)
    let point = try #require(pick.positionCm)
    #expect(abs(point.x + 22) < 0.001)
    #expect(abs(point.y - 5) < 0.001)
    #expect(abs(point.z - 12) < 0.001)
    #expect(try await surface.editorSnapshot() == initial)
    _ = try await surface.setEditorTool(.select)
    _ = try await surface.setEditorTool(.place, assetID: "rotala")
    received = nil
    receivedCount = 0
    _ = try await surface.view.evaluateJavaScript(
      """
      window.postMessage({type:'aquarium-designer-pick',revision:\(pick.revision),tool:'place',
        toolGeneration:\(pick.toolGeneration),positionCm:{x:0,y:5,z:0}},'*');
      """)
    _ = try await surface.view.evaluateJavaScript(script)
    let freshDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while received == nil && ContinuousClock.now < freshDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let fresh = try #require(received)
    #expect(fresh.toolGeneration > pick.toolGeneration)
    #expect(receivedCount == 1)
    #expect(abs(try #require(fresh.positionCm).x + 22) < 0.001)
    _ = try await surface.setEditorTool(.select)
    await #expect(throws: IdleScreenAquariumWebSurface.EditorError.self) {
      try await surface.setEditorTool(.place, assetID: "pirate-chest")
    }
    await #expect(throws: IdleScreenAquariumWebSurface.EditorError.self) {
      try await surface.setEditorTool(.move, selectedID: "missing")
    }
    #expect(try await surface.editorSnapshot() == initial)
    try await surface.shutdown()
  }

  @Test func epiphytesFollowActualSupportNormalsWithoutLosingCollisionChecks() async throws {
    let result = try await runPresetFixture(
      "mount-normal-check",
      invocation:
        "runAquariumMountNormalCheck(THREE,AquariumDesignerPlacement,AquariumEpiphytePlantsV2)")
    #expect(result["checks"] == 8)
  }

  @Test func mountedPlantsSurviveRejectedSupportChangesAndAddedRocksCollide() async throws {
    let result = try await runPresetFixture(
      "mount-edit-check", invocation: "runAquariumMountEditCheck(aquariumStudy)")
    #expect(result["checks"] == 9)
  }

  @Test func nativeCanvasCanPickAndMovePresetRockWhileLegacySelectionStaysAddedOnly() async throws {
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let initial = try await surface.beginEditing()
    var rock = try #require(initial.objects.first { $0.id == "base-rock" })
    rock.positionCm.x = 0
    rock.positionCm.z = 0
    let centered = try await surface.applyPresetObjects(
      expectedRevision: initial.revision, objects: [rock])
    #expect(try await surface.setEditorTool(.select, selectedID: rock.id) == centered)
    var picks: [IdleScreenAquariumWebSurface.EditorPick] = []
    surface.onEditorPick = { picks.append($0) }
    try await clickTankPoint(surface, point: .init(x: 0, y: 8, z: 0))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while picks.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try #require(picks.first).id == rock.id)
    picks.removeAll()
    #expect(try await surface.setEditorTool(.move, selectedID: rock.id) == centered)
    #expect(try await surface.beginEditing() == centered)
    try await clickTankPoint(surface, point: .init(x: 0, y: rock.positionCm.y, z: 3))
    let movedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while picks.isEmpty && ContinuousClock.now < movedDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let pick = try #require(picks.first)
    #expect(pick.id == rock.id)
    #expect(pick.tool == .move)
    let position = try #require(pick.positionCm)
    #expect(abs(position.z - 3) < 0.001)
    #expect(position.y == rock.positionCm.y)
    #expect(try await surface.editorSnapshot() == centered)
    let legacy = try await tankScript(
      surface,
      "JSON.stringify(aquariumStudy.applyDesigner({layout:aquariumStudy.designer.layout,selectionScope:'added',selectedId:'base-rock'}))"
    )
    #expect(legacy.contains("error"))
    try await surface.shutdown()
  }

  @Test func equipmentPlacementsRegenerateBodiesRimLeadsAndCounterConnections() async throws {
    let result = try await runPresetFixture(
      "equipment-placement-check",
      invocation:
        "runAquariumEquipmentPlacementCheck(THREE,AquariumMetricBasicArt,AquariumMetricConnections)"
    )
    #expect(result["checks"] == 8)
  }

  @Test func liveEquipmentMovesPersistAndOldConfigurationsKeepDefaultHardware() async throws {
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let initial = try await surface.beginEditing()
    #expect(initial.equipmentObjects.count == 3)
    let cleared = try await surface.applyPresetObjects(
      expectedRevision: initial.revision, objects: [])
    var moved = cleared.equipmentObjects
    let index = try #require(moved.firstIndex { $0.id == "equipment/filter" })
    moved[index].positionCm.x = -15
    moved[index].positionCm.z = 8
    let edited = try await surface.applyEquipmentObjects(
      expectedRevision: cleared.revision, objects: moved)
    #expect(edited.equipmentObjects == moved)
    #expect(edited.objects.isEmpty)
    #expect(edited.revision > cleared.revision)
    let stable = try await surface.exportTank(id: "equipment-test", name: "Equipment")
    var invalid = moved
    invalid[index].positionCm.x = 29
    await #expect(throws: IdleScreenAquariumWebSurface.EditorError.self) {
      try await surface.applyEquipmentObjects(expectedRevision: edited.revision, objects: invalid)
    }
    #expect(try await surface.exportTank(id: "equipment-test", name: "Equipment") == stable)
    await #expect(throws: IdleScreenAquariumWebSurface.EditorError.self) {
      try await surface.applyEquipmentObjects(expectedRevision: cleared.revision, objects: moved)
    }
    let restored = IdleScreenAquariumWebSurface()
    try await restored.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let reopened = try await restored.restoreTank(from: stable)
    #expect(reopened.equipmentObjects == moved)
    var legacy = try #require(JSONSerialization.jsonObject(with: stable) as? [String: Any])
    var tank = try #require(legacy["tank"] as? [String: Any])
    var config = try #require(tank["configuration"] as? [String: Any])
    #expect(config["schemaVersion"] as? Int == 2)
    config["schemaVersion"] = 1
    config.removeValue(forKey: "equipment")
    tank["configuration"] = config
    legacy["tank"] = tank
    let old = IdleScreenAquariumWebSurface()
    try await old.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let oldState = try await old.restoreTank(from: JSONSerialization.data(withJSONObject: legacy))
    #expect(oldState.equipmentObjects == initial.equipmentObjects)
    try await surface.shutdown()
    try await restored.shutdown()
    try await old.shutdown()
  }

  @Test func liveEquipmentPreservesBiologyAndReleasesRejectedAndReplacedResources() async throws {
    let result = try await runPresetFixture(
      "equipment-live-check",
      invocation:
        "runAquariumEquipmentLiveCheck(aquariumStudy,AquariumMetricBasicArt,AquariumTankConfiguration,THREE,AquariumMossRockArt)"
    )
    #expect(result["checks"] == 9)
  }

  @Test func equipmentCanBePickedAndMovedThroughTheNativeCanvasBridge() async throws {
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let initial = try await surface.beginEditing()
    let cleared = try await surface.applyPresetObjects(
      expectedRevision: initial.revision, objects: [])
    let filter = try #require(cleared.equipmentObjects.first { $0.id == "equipment/filter" })
    _ = try await surface.setEditorTool(.select)
    var received: IdleScreenAquariumWebSurface.EditorPick?
    surface.onEditorPick = { received = $0 }
    try await clickTankPoint(
      surface, point: .init(x: filter.positionCm.x, y: 14, z: filter.positionCm.z))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while received == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try #require(received).id == filter.id)
    _ = try await surface.setEditorTool(.move, selectedID: filter.id)
    received = nil
    try await clickTankPoint(surface, point: .init(x: -15, y: 5, z: 8))
    let moveDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while received == nil && ContinuousClock.now < moveDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let point = try #require(received?.positionCm)
    #expect(abs(point.x + 15) < 0.001 && abs(point.z - 8) < 0.001)
    #expect(try await surface.editorSnapshot() == cleared)
    try await surface.shutdown()
  }

  @Test func equipmentIdentitiesDoNotShadowExistingSavedObjectNames() async throws {
    let surface = IdleScreenAquariumWebSurface()
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let initial = try await surface.beginEditing()
    let empty = try await surface.applyPresetObjects(
      expectedRevision: initial.revision, objects: [])
    let plant = IdleScreenAquariumWebSurface.PresetObject(
      id: "equipment-filter", assetId: "rotala",
      positionCm: .init(x: -22, y: 5, z: 12), rotationY: 0)
    let edited = try await surface.applyPlacedObjects(
      expectedRevision: empty.revision, objects: [plant])
    let ids =
      edited.objects.map(\.id) + edited.placedObjects.map(\.id) + edited.equipmentObjects.map(\.id)
    #expect(Set(ids).count == ids.count)
    try await surface.shutdown()
  }

  @Test func nativeEditorBridgeMovesObjectsAndRecoversFromRejectedEdits() async throws {
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    surface.view.configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.frameClock(emulatingVisibleDocument: false), injectionTime: .atDocumentStart,
        forMainFrameOnly: true))
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let before = try await snapshot(surface)
    let initial = try await surface.beginEditing()
    #expect(!initial.objects.isEmpty)
    #expect(try await surface.beginEditing() == initial)
    let rock = try #require(initial.objects.first { $0.id == "base-rock" })
    var moved = initial.objects
    let index = try #require(moved.firstIndex { $0.id == rock.id })
    moved[index].positionCm.z += 3
    let edited = try await surface.applyPresetObjects(
      expectedRevision: initial.revision, objects: moved)
    #expect(edited.revision > initial.revision)
    #expect(edited.objects[index].positionCm.z == rock.positionCm.z + 3)
    do {
      _ = try await surface.applyPresetObjects(
        expectedRevision: initial.revision, objects: initial.objects)
      Issue.record("Stale editor command was accepted")
    } catch IdleScreenAquariumWebSurface.EditorError.rejected(let message) {
      #expect(message.contains("stale"))
    }
    var invalid = edited.objects
    invalid[index].positionCm.x = 50
    await #expect(throws: IdleScreenAquariumWebSurface.EditorError.self) {
      try await surface.applyPresetObjects(expectedRevision: edited.revision, objects: invalid)
    }
    #expect(surface.state == .paused)
    #expect(try await surface.editorSnapshot() == edited)
    let restored = try await surface.applyPresetObjects(
      expectedRevision: edited.revision, objects: initial.objects)
    #expect(restored.objects.map(\.id) == initial.objects.map(\.id))
    for (actual, expected) in zip(restored.objects, initial.objects) {
      #expect(actual.assetId == expected.assetId)
      #expect(abs(actual.positionCm.x - expected.positionCm.x) < 1e-9)
      #expect(abs(actual.positionCm.y - expected.positionCm.y) < 1e-9)
      #expect(abs(actual.positionCm.z - expected.positionCm.z) < 1e-9)
      #expect(abs(actual.rotationY - expected.rotationY) < 1e-9)
    }
    let after = try await snapshot(surface)
    #expect(after.scene.ecology.animals == before.scene.ecology.animals)
    #expect(after.scene.water.elapsedSeconds == before.scene.water.elapsedSeconds)
    #expect(after.scene.clock == before.scene.clock)
    try await surface.shutdown()
    await #expect(throws: IdleScreenAquariumWebSurface.SurfaceError.self) {
      try await surface.editorSnapshot()
    }
  }

  @Test(arguments: ["basic", "lush", "waterfall"])
  func fullTankCheckpointRestoresLifeFoodAndLayoutInAFreshRuntime(setup: String) async throws {
    let source = IdleScreenAquariumWebSurface()
    source.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    source.view.configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.frameClock(emulatingVisibleDocument: true),
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    try await source.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let setupJSON = String(decoding: try JSONEncoder().encode(setup), as: UTF8.self)
    _ = try await tankScript(
      source, "aquariumStudy.setSceneStyle(\(setupJSON)); JSON.stringify(true)")
    _ = try await source.beginEditing()
    if setup == "basic" {
      let initial = try await source.editorSnapshot()
      let moved = initial.objects.map { item in
        var result = item
        if item.id == "base-rock" { result.positionCm.z += 3 }
        return result
      }
      _ = try await source.applyPresetObjects(expectedRevision: initial.revision, objects: moved)
      _ = try await tankScript(
        source,
        "aquariumStudy.applyDesigner({layout:{schemaVersion:1,units:'cm',name:'Living tank',base:{setup:'basic'},instances:[{id:'saved-rotala',assetId:'rotala',positionCm:{x:-22,y:5,z:12},rotationY:0}]}}); JSON.stringify(true)"
      )
    }
    _ = try await tankScript(
      source,
      "aquariumStudy.setGlassPane('snail-0','back'); aquariumStudy.setPumpOutput(.6); aquariumStudy.setTankLightCount(1); aquariumStudy.setLight('warm'); aquariumStudy.feed({automatic:true}); aquariumStudy.previewLifeEvent('molt'); aquariumStudy.previewLifeEvent('death'); aquariumStudy.setEcologyRate(120); JSON.stringify(true)"
    )
    try await source.resume()
    _ = try await snapshot(source, frames: 5)
    try await source.pause()
    let savedData = try await source.exportTank(id: "tank-one", name: "Living tank")
    let saved = String(decoding: savedData, as: UTF8.self)
    let savedValue = try #require(
      JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
    let target = IdleScreenAquariumWebSurface()
    target.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    target.view.configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.frameClock(emulatingVisibleDocument: true),
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    try await target.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    _ = try await target.restoreTank(from: savedData)
    let exported = try await tankScript(
      target, "JSON.stringify(aquariumStudy.exportTank({id:'tank-one',name:'Living tank'}))")
    let restored = try #require(
      JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
    let beforeEnvelope = try #require(savedValue["tank"] as? [String: Any])
    let afterEnvelope = try #require(restored["tank"] as? [String: Any])
    let beforeDocument = try #require(beforeEnvelope["document"] as? [String: Any])
    let afterDocument = try #require(afterEnvelope["document"] as? [String: Any])
    #expect(
      NSDictionary(dictionary: try #require(beforeDocument["checkpoint"] as? [String: Any]))
        == NSDictionary(dictionary: try #require(afterDocument["checkpoint"] as? [String: Any])))
    #expect(
      NSDictionary(dictionary: try #require(savedValue["runtime"] as? [String: Any]))
        == NSDictionary(dictionary: try #require(restored["runtime"] as? [String: Any])))
    #expect(
      NSDictionary(dictionary: try #require(beforeEnvelope["configuration"] as? [String: Any]))
        == NSDictionary(dictionary: try #require(afterEnvelope["configuration"] as? [String: Any])))
    let checkpoint = try #require(beforeDocument["checkpoint"] as? [String: Any])
    let domain = try #require(checkpoint["data"] as? [String: Any])
    let ecology = try #require(domain["ecology"] as? [String: Any])
    let statistics = try #require(ecology["stats"] as? [String: Any])
    #expect(try #require(statistics["deaths"] as? Int) > 0)
    #expect(try #require(statistics["molts"] as? Int) > 0)
    #expect(!(try #require(ecology["food"] as? [Any])).isEmpty)
    let oldLayout = try #require(beforeDocument["layout"] as? [String: Any])
    let newLayout = try #require(afterDocument["layout"] as? [String: Any])
    func objects(_ layout: [String: Any]) throws -> [IdleScreenAquariumWebSurface.PresetObject] {
      try JSONDecoder().decode(
        [IdleScreenAquariumWebSurface.PresetObject].self,
        from: JSONSerialization.data(withJSONObject: #require(layout["objects"])))
    }
    let expectedObjects = try objects(oldLayout)
    let actualObjects = try objects(newLayout)
    #expect(actualObjects.map(\.id) == expectedObjects.map(\.id))
    for (actual, expected) in zip(actualObjects, expectedObjects) {
      #expect(actual.assetId == expected.assetId)
      #expect(abs(actual.positionCm.x - expected.positionCm.x) < 1e-9)
      #expect(abs(actual.positionCm.y - expected.positionCm.y) < 1e-9)
      #expect(abs(actual.positionCm.z - expected.positionCm.z) < 1e-9)
      #expect(abs(actual.rotationY - expected.rotationY) < 1e-9)
    }
    #expect(target.state == .paused)
    await #expect(throws: (any Error).self) { try await target.restoreTank(from: savedData) }
    let paused = try await snapshot(target)
    try await target.resume()
    let continued = try await snapshot(target, frames: 4)
    #expect(continued.scene.ecology.animals.map(\.id) == paused.scene.ecology.animals.map(\.id))
    #expect(continued.scene.water.elapsedSeconds > paused.scene.water.elapsedSeconds)
    try await source.shutdown()
    try await target.shutdown()
  }

  @Test func invalidCheckpointArtAndBindingsAreRejectedBeforeAnySceneMutation() async throws {
    let result = try await runPresetFixture(
      "checkpoint-validation", invocation: "runAquariumCheckpointValidation(aquariumStudy)")
    #expect(result["checks"] == 9)
  }

  @Test func removedStockIsNotResurrectedWhenTheSceneRebuilds() async throws {
    let result = try await runPresetFixture(
      "checkpoint-stock", invocation: "runAquariumCheckpointStock(aquariumStudy)")
    #expect(result["checks"] == 2)
  }

  @Test func domainCheckpointsContinueBirthsWasteAndMassWithoutDuplicatingHistory() async throws {
    let result = try await runPresetFixture(
      "domain-checkpoint-checks", invocation: "runAquariumDomainCheckpointChecks()")
    #expect(result["checks"] == 8)
  }

  @Test func decomposedCorpsesDoNotLeaveUnsavableVisualBindings() async throws {
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    surface.view.configuration.userContentController.addUserScript(
      WKUserScript(
        source: """
          Object.defineProperty(window, 'AquariumEcology', {configurable:true,set(api){
            Object.defineProperty(window, 'AquariumEcology', {value:{...api,create(options){
              const model=api.create(options); window.checkpointEcologyProof=model; return model;
            }}});
          }});
          """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    _ = try await surface.beginEditing()
    _ = try await tankScript(
      surface,
      """
      aquariumStudy.previewLifeEvent('death');
      const domain=window.checkpointEcologyProof, index=domain.deposits.findIndex(d=>d.kind==='corpse');
      domain.stats.dissolved+=domain.deposits[index].amount; domain.deposits.splice(index,1);
      aquariumStudy.previewLifeEvent('molt'); JSON.stringify(true)
      """)
    let saved = try await surface.exportTank(id: "old-tank", name: "After decomposition")
    #expect(!saved.isEmpty)
    try await surface.shutdown()
  }

  @Test func originalOrnamentsHaveClosedSurfacesAndRealSwimthroughs() async throws {
    let result = try await runPresetFixture(
      "ornament-checks", invocation: "runAquariumOrnamentChecks()")
    #expect(result["checks"] == 7)
  }

  private func clickTankPoint(
    _ surface: IdleScreenAquariumWebSurface,
    point: IdleScreenAquariumWebSurface.PositionCm
  ) async throws {
    let argument = String(decoding: try JSONEncoder().encode(point), as: UTF8.self)
    _ = try await tankScript(
      surface,
      """
      (() => {
        const s=aquariumStudy.state,c=s.camera,point=\(argument);
        const camera=new THREE.PerspectiveCamera(c.fov,c.aspect,.1,1000);
        camera.position.fromArray(c.position);camera.lookAt(...c.target);
        camera.projectionMatrix.elements[9]=2*c.horizonPercent/100-1;camera.updateMatrixWorld();
        const centerZ=(s.world.floorBackZ+s.world.floorFrontZ)/2;
        const p=new THREE.Vector3(point.x/s.physical.cmPerUnit,point.y/s.physical.cmPerUnit,centerZ+point.z/s.physical.cmPerUnit).project(camera);
        const canvas=document.querySelector('canvas'),r=canvas.getBoundingClientRect();
        canvas.dispatchEvent(new PointerEvent('pointerdown',{button:0,clientX:r.left+(p.x+1)*r.width/2,clientY:r.top+(1-p.y)*r.height/2}));
        return 'clicked';
      })()
      """)
  }

  private func tankScript(_ surface: IdleScreenAquariumWebSurface, _ script: String) async throws
    -> String
  {
    try await withCheckedThrowingContinuation { continuation in
      surface.view.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let text = value as? String {
          continuation.resume(returning: text)
        } else {
          continuation.resume(throwing: CocoaError(.coderValueNotFound))
        }
      }
    }
  }

  private func runPresetFixture(_ name: String, invocation: String) async throws -> [String: Int] {
    let fixture = try #require(
      Bundle(for: AquariumCollisionFixtureBundle.self).url(
        forResource: name, withExtension: "js", subdirectory: "WebSurfaceProof"))
    let source = try String(contentsOf: fixture, encoding: .utf8)
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    try await surface.load(sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
    let script = source + "\nJSON.stringify(" + invocation + ");"
    let json: String = try await withCheckedThrowingContinuation { continuation in
      surface.view.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let text = value as? String {
          continuation.resume(returning: text)
        } else {
          continuation.resume(throwing: CocoaError(.coderValueNotFound))
        }
      }
    }
    let result = try JSONDecoder().decode([String: Int].self, from: Data(json.utf8))
    try await surface.shutdown()
    return result
  }

  private func snapshot(_ surface: IdleScreenAquariumWebSurface, frames: Int = 0) async throws
    -> Snapshot
  {
    let script = """
      for (let index = 0; index < \(frames); index++) window.aquariumFrameProof.advance();
      JSON.stringify({
        revision: THREE.REVISION,
        documentHidden: document.hidden,
        scene: aquariumStudy.state,
        pendingFrames: window.aquariumFrameProof.pending,
        visibleControls: Array.from(document.querySelectorAll('button')).filter(
          element => element.getClientRects().length > 0).length
      });
      """
    let json: String = try await withCheckedThrowingContinuation { continuation in
      surface.view.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let json = value as? String {
          continuation.resume(returning: json)
        } else {
          continuation.resume(throwing: CocoaError(.coderValueNotFound))
        }
      }
    }
    return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
  }

  private static func frameClock(emulatingVisibleDocument: Bool) -> String {
    """
    (() => {
      // The unattached test view is hidden. Emulate host visibility only here.
      if (\(emulatingVisibleDocument)) Object.defineProperty(document, 'hidden', { get: () => false });
      let nextID = 0;
      let time = 0;
      const callbacks = new Map();
      window.requestAnimationFrame = callback => {
        const id = ++nextID;
        callbacks.set(id, callback);
        return id;
      };
      window.cancelAnimationFrame = id => callbacks.delete(id);
      window.aquariumFrameProof = {
        get pending() { return callbacks.size; },
        advance() {
          time += 50;
          const current = Array.from(callbacks.values());
          callbacks.clear();
          current.forEach(callback => callback(time));
        }
      };
    })();
    """
  }

  private struct Snapshot: Decodable {
    let revision: String
    let documentHidden: Bool
    let scene: Scene
    let pendingFrames: Int
    let visibleControls: Int

    struct Scene: Decodable {
      let motion: Bool
      let clock: Double
      let renderedFrames: Int
      let drawCalls: Int
      let triangles: Int
      let water: Water
      let ecology: Ecology
      let condition: Condition
      let physical: Physical
    }

    struct Water: Decodable {
      let elapsedSeconds: Double
      let volumeL: Double
    }

    struct Ecology: Decodable {
      let seconds: Double
      let animals: [Animal]
    }

    struct Animal: Decodable, Equatable {
      let id: String
      let alive: Bool
      let health: Double
      let hunger: Double
    }

    struct Condition: Decodable { let mode: String }
    struct Physical: Decodable { let tankCm: Dimensions }
    struct Dimensions: Decodable {
      let width: Double
      let depth: Double
      let height: Double
    }
  }

  private struct Manifest: Decodable {
    let scriptOrder: [String]
    let importedFiles: [ImportedFile]
    let vendor: Vendor
    struct ImportedFile: Decodable { let path: String }
    struct Vendor: Decodable {
      let revision: String
      let sha256: String
      let licenseSha256: String
    }
  }
}

private final class AquariumCollisionFixtureBundle {}
