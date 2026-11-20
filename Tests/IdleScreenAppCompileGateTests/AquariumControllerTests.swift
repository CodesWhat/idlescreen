import Foundation
import IdleScreenCore
import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium editing controller")
@MainActor
struct AquariumControllerTests {
  @Test func rejectedTankCreationKeepsUndoAndRedoHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    #expect(
      controller.perform { library in
        while library.tanks.count < IdleScreenAquariumLibrary.maximumTankCount {
          library.tanks.append(.init(name: "Other tank"))
        }
      })
    controller.editTank(recordLayout: true) { $0.substrate = .creamSand }
    controller.editTank(recordLayout: true) { $0.substrate = .riverGravel }
    controller.undoLayout()
    #expect(controller.canUndo && controller.canRedo)
    let before = controller.library
    controller.newTank()
    #expect(controller.library == before)
    #expect(controller.canUndo && controller.canRedo)
  }

  @Test func attachedMossUsesResolvedRenderingAndUndoSurvivesDirectEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    var wood = IdleScreenAquariumDecoration(kind: .driftwood, x: 0.5, y: 0.9)
    let moss = IdleScreenAquariumDecoration(kind: .moss, x: 0.3, y: 0.9)
    controller.editTank { $0.decorations = [wood, moss] }
    controller.editTank(recordLayout: true) { try $0.attachMoss(id: moss.id, to: wood.id) }
    wood.x = 0.6
    wood.flipped = true
    wood.tilt = .left
    controller.updateDecoration(wood)
    let posed = try #require(controller.selectedTank.placedDecorations.last)
    let mapped = try #require(
      IdleScreenAquariumProduct.settings(for: controller.selectedTank).objects.last)
    #expect(mapped.x == posed.x && mapped.x != moss.x)
    #expect(mapped.flipped && mapped.tiltDegrees == -15)
    let panorama = IdleScreenAquariumProduct.settings(
      for: controller.selectedTank, worldAspect: 3.5)
    let expandedMoss = try #require(panorama.objects.last)
    #expect(
      abs(
        (expandedMoss.x - wood.x) * Double(panorama.worldWidth)
          - (posed.x - wood.x) * Double(controller.selectedTank.worldWidth)) < 0.00001)
    controller.updateDecoration(posed)
    #expect(controller.selectedTank.decorations.last?.attachment == nil)
    controller.undoLayout()
    #expect(controller.selectedTank.decorations.last?.attachment?.parentID == wood.id)
    controller.reload()
    #expect(controller.selectedTank.placedDecorations.last == posed)
  }

  @Test func attachedMossTouchesThePaintedSupportAcrossTransforms() throws {
    for kind in [IdleScreenAquariumDecorationKind.rock, .slate, .cave, .driftwood, .hollowLog] {
      for tilt in IdleScreenAquariumObjectTilt.allCases {
        for flipped in [false, true] {
          var tank = IdleScreenAquariumTank()
          let parent = IdleScreenAquariumDecoration(
            kind: kind, x: 0.5, y: 0.9, scale: 1.25, flipped: flipped, tilt: tilt)
          let moss = IdleScreenAquariumDecoration(kind: .moss, x: 0.3, y: 0.9, scale: 0.8)
          tank.decorations = [parent, moss]
          try tank.attachMoss(id: moss.id, to: parent.id)
          let settings = IdleScreenAquariumProduct.settings(for: tank)
          var support = IdleScreenAquarium.Canvas()
          var plant = IdleScreenAquarium.Canvas()
          support.object(settings.objects[0], time: 0)
          plant.object(settings.objects[1], time: 0)
          let supportPixels = Set(support.pixels.indices.filter { support.pixels[$0].w > 0 })
          let touching = plant.pixels.indices.contains { index in
            plant.pixels[index].w > 0
              && [index, index - 1, index + 1, index - 384, index + 384].contains {
                supportPixels.contains($0)
              }
          }
          #expect(touching, "Disconnected moss: \(kind), \(tilt), flipped \(flipped)")
        }
      }
    }
  }

  @Test func keeperSetupPersistsAndRejectedHabitatDoesNotChangeTheStore() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "aquariums.json")
    let controller = IdleScreenAquariumController(fileURL: url)
    let animals = controller.selectedTank.animals
    #expect(controller.perform { try $0.setKeeperMode(true) })
    let saved = controller.library
    #expect(saved.selectedTank?.lighting.preset == .automatic)
    #expect(saved.selectedTank?.animals == animals)
    let reopened = IdleScreenAquariumController(fileURL: url)
    #expect(reopened.library == saved)
    let bytes = try Data(contentsOf: url)
    #expect(!controller.perform { try $0.setHabitat(.freshwater) })
    #expect(controller.library == saved)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(
      controller.errorMessage == IdleScreenAquariumError.incompatibleHabitat.localizedDescription)
  }

  @Test func editsPersistAndUndoDoesNotRollBackAnimalsOrCoins() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "aquariums.json")
    let controller = IdleScreenAquariumController(fileURL: url)
    controller.addDecoration(.driftwood)
    #expect(controller.selectedTank.decorations.contains { $0.kind == .driftwood })
    let count = controller.selectedTank.animals.count
    controller.perform { try $0.buyAnimal(.cherryShrimp, variant: .blue, sex: .female, id: UUID()) }
    controller.undoLayout()
    #expect(!controller.selectedTank.decorations.contains { $0.kind == .driftwood })
    #expect(controller.selectedTank.animals.count == count + 1)
    controller.redoLayout()
    let reopened = IdleScreenAquariumController(fileURL: url)
    #expect(reopened.library == controller.library)
  }

  @Test func tankLengthPersistsAndParticipatesInLayoutUndo() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "aquariums.json")
    let controller = IdleScreenAquariumController(fileURL: url)
    let animals = controller.selectedTank.animals
    controller.editTank(recordLayout: true) { $0.worldSize = .wide }
    #expect(controller.selectedTank.worldWidth == 768)
    controller.undoLayout()
    #expect(controller.selectedTank.worldWidth == 384)
    controller.redoLayout()
    let reopened = IdleScreenAquariumController(fileURL: url)
    #expect(reopened.selectedTank.worldWidth == 768)
    #expect(reopened.selectedTank.animals == animals)
  }

  @Test func applyingAndResettingPresetsUndoOnlyCosmeticState() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    controller.editTank {
      $0.worldSize = .wide
      $0.seed = 91
      $0.lighting.preset = .blacklight
    }
    controller.savePreset(name: "Night wood")
    let preset = try #require(controller.library.layoutPresets?.first)
    controller.editTank {
      $0.worldSize = .standard
      $0.seed = 42
      $0.lighting.preset = .daylight
    }
    controller.applyPreset(preset.id)
    #expect(controller.selectedTank.worldWidth == 768)
    #expect(controller.selectedTank.lighting.preset == .blacklight)
    controller.perform { try $0.buyAnimal(.cherryShrimp, variant: .blue, sex: .female, id: UUID()) }
    let animals = controller.selectedTank.animals
    let balance = controller.library.balance
    controller.undoLayout()
    #expect(controller.selectedTank.worldWidth == 384)
    #expect(controller.selectedTank.seed == 42)
    #expect(controller.selectedTank.lighting.preset == .daylight)
    #expect(controller.selectedTank.animals == animals)
    #expect(controller.library.balance == balance)
    controller.redoLayout()
    controller.resetLayout()
    #expect(controller.selectedTank.worldWidth == 384)
    controller.undoLayout()
    #expect(controller.selectedTank.worldWidth == 768)
    #expect(controller.selectedTank.animals == animals)
  }

  @Test func decorationTiltReachesTheRendererAndSurvivesUndoAndReload() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "aquariums.json")
    let controller = IdleScreenAquariumController(fileURL: url)
    var item = try #require(controller.selectedTank.decorations.first { $0.kind == .rock })
    item.tilt = .left
    controller.updateDecoration(item)
    #expect(
      IdleScreenAquariumProduct.settings(for: controller.selectedTank).objects
        .first { $0.kind == "rock" }?.tiltDegrees == -15)
    controller.undoLayout()
    #expect(controller.selectedTank.decorations.first { $0.id == item.id }?.tilt == nil)
    controller.redoLayout()
    let reopened = IdleScreenAquariumController(fileURL: url)
    #expect(reopened.selectedTank.decorations.first { $0.id == item.id }?.tilt == .left)
  }

  @Test func invalidEditsLeaveSavedStateAndHistoryUntouched() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = IdleScreenAquariumController(
      fileURL: directory.appending(path: "aquariums.json"))
    let original = controller.library
    controller.editTank { $0.substrateDepth = .nan }
    #expect(controller.library == original)
    #expect(controller.errorMessage != nil)
    #expect(!controller.canUndo)
  }
}
