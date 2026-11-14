import IdleScreenRenderer
import SwiftUI

struct IdleScreenAquariumWorkspaceView: View {
  @State private var showsExistingTanks = false

  var body: some View {
    VStack(spacing: 0) {
      Picker("Aquarium workspace", selection: $showsExistingTanks) {
        Text("Planted tank").tag(false)
        Text("Existing tanks").tag(true)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 360)
      .padding()
      Divider()
      if showsExistingTanks {
        IdleScreenAquariumView()
      } else {
        IdleScreenPlantedTankView()
      }
    }
  }
}

private struct IdleScreenPlantedTankView: View {
  @State private var editor = IdleScreenPlantedTankEditor.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading) {
          Text("Planted tank").font(.title2.bold())
          Text("60 × 36 × 36 cm · Saves include the ecosystem")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Reopen saved tank") { Task { await editor.reloadCheckpoint() } }
          .disabled(!editor.canReopen)
        Button("Save tank") { Task { await editor.save() } }.disabled(!editor.canSave)
        Button("Undo") { Task { await editor.undo() } }.disabled(!editor.canUndo)
        Button("Redo") { Task { await editor.redo() } }.disabled(!editor.canRedo)
      }
      .padding()
      HSplitView {
        List(selection: $editor.selectedID) {
          ForEach(editor.snapshot?.objects ?? []) { object in
            VStack(alignment: .leading) {
              Text(object.assetId.replacingOccurrences(of: "-", with: " ").capitalized)
              Text(object.id).font(.caption).foregroundStyle(.secondary)
            }
            .tag(object.id)
          }
        }
        .frame(minWidth: 150, idealWidth: 190, maxWidth: 240)
        PlantedTankSurface(surface: editor.surface)
          .id(ObjectIdentifier(editor.surface))
          .frame(minWidth: 320, minHeight: 300)
        VStack(alignment: .leading) {
          if let object = editor.selectedObject {
            PlantedTankInspector(object: object, editor: editor)
              .id("\(object.id)-\(editor.snapshot?.revision ?? 0)")
          } else {
            Text("Select a tank object to move, turn or remove it.")
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding()
        .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
      }
      if let error = editor.errorMessage {
        Text(error).font(.callout).foregroundStyle(.red).padding()
      }
    }
    .task { await editor.activate() }
    .onDisappear { Task { await editor.deactivate() } }
  }
}

private struct PlantedTankSurface: NSViewRepresentable {
  let surface: IdleScreenAquariumWebSurface
  func makeNSView(context: Context) -> NSView { surface.view }
  func updateNSView(_ view: NSView, context: Context) {}
}

private struct PlantedTankInspector: View {
  let object: IdleScreenAquariumWebSurface.PresetObject
  let editor: IdleScreenPlantedTankEditor
  @State private var x: Double
  @State private var depth: Double
  @State private var degrees: Double

  init(object: IdleScreenAquariumWebSurface.PresetObject, editor: IdleScreenPlantedTankEditor) {
    self.object = object
    self.editor = editor
    _x = State(initialValue: object.positionCm.x)
    _depth = State(initialValue: object.positionCm.z)
    _degrees = State(initialValue: object.rotationY * 180 / .pi)
  }

  var body: some View {
    Form {
      Text(object.assetId.replacingOccurrences(of: "-", with: " ").capitalized).font(.headline)
      TextField("Across (cm)", value: $x, format: .number)
      TextField("Depth (cm)", value: $depth, format: .number)
      TextField("Turn (°)", value: $degrees, format: .number)
      LabeledContent(
        "Height (cm)", value: object.positionCm.y.formatted(.number.precision(.fractionLength(1))))
      Text("Height follows its current support. Invalid placements are rejected.")
        .font(.caption).foregroundStyle(.secondary)
      Button("Apply position") {
        var moved = object
        moved.positionCm.x = x
        moved.positionCm.z = depth
        moved.rotationY = degrees * .pi / 180
        Task { await editor.update(moved) }
      }
      Button("Remove object", role: .destructive) { Task { await editor.removeSelected() } }
    }
    .disabled(editor.isBusy)
  }
}
