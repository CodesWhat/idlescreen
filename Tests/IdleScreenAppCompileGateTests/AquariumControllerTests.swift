import Foundation
import IdleScreenCore
import Testing

@Suite("Aquarium editing controller")
@MainActor
struct AquariumControllerTests {
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
