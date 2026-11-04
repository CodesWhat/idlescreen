import Foundation
import IdleScreenCore
import Testing

@Suite("Aquarium editing controller")
@MainActor
struct AquariumControllerTests {
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
