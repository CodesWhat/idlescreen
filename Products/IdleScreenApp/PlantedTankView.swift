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
        Button("Undo layout") { Task { await editor.undo() } }.disabled(!editor.canUndo)
        Button("Redo layout") { Task { await editor.redo() } }.disabled(!editor.canRedo)
      }
      .padding()
      HSplitView {
        List(selection: $editor.selectedID) {
          Section("Tank objects") {
            ForEach(editor.snapshot?.objects ?? []) { object in
              objectRow(object)
            }
          }
          Section("Equipment") {
            ForEach(editor.snapshot?.equipmentObjects ?? []) { object in
              objectRow(object)
            }
          }
          Section("Animals") {
            ForEach(editor.snapshot?.animals ?? []) { animal in
              VStack(alignment: .leading) {
                Text(editor.animalLabel(animal))
                Text(animal.alive ? animal.kind.capitalized : "Dead")
                  .font(.caption).foregroundStyle(.secondary)
              }.tag(animal.id)
            }
          }
          Section("Added plants and hardscape") {
            ForEach(editor.snapshot?.placedObjects ?? []) { object in
              objectRow(object)
            }
          }
        }
        .frame(minWidth: 150, idealWidth: 190, maxWidth: 240)
        .disabled(editor.isBusy || editor.pointerTool != .select)
        PlantedTankSurface(surface: editor.surface)
          .id(ObjectIdentifier(editor.surface))
          .frame(minWidth: 320, minHeight: 300)
        VStack(alignment: .leading) {
          PlantedTankStockPicker(editor: editor)
          Divider().padding(.vertical, 8)
          PlantedTankAssetPicker(editor: editor)
          Divider().padding(.vertical, 8)
          if let animal = editor.selectedAnimal {
            Text(editor.animalLabel(animal)).font(.headline)
            if animal.alive {
              Button("Remove from tank", role: .destructive) {
                Task { await editor.removeAnimal(id: animal.id) }
              }
              .disabled(editor.isBusy)
              .help("Takes this animal and any carried brood out of the tank.")
            } else {
              Text("This animal is no longer alive. Its remains belong to the tank ecosystem.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          if let object = editor.selectedObject {
            PlantedTankInspector(object: object, editor: editor)
              .id("\(object.id)-\(editor.snapshot?.revision ?? 0)")
          } else if editor.selectedAnimal == nil {
            Text("Select a tank object to move, turn or remove it.")
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding()
        .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
      }
      if editor.pointerTool != .select {
        HStack {
          Text(
            editor.pointerTool == .place
              ? "Click in the tank to place the specimen. Attached plants need a rock or driftwood surface."
              : "Click in the tank to move the selected specimen."
          )
          .font(.callout)
          Spacer()
          Button("Cancel placement") { Task { await editor.cancelPointerTool() } }
            .disabled(editor.isBusy)
        }.padding()
      }
      if let error = editor.errorMessage {
        Text(error).font(.callout).foregroundStyle(.red).padding()
      }
    }
    .task { await editor.activate() }
    .onChange(of: editor.selectedID) { _, _ in
      Task { await editor.syncSelection() }
    }
    .onDisappear { Task { await editor.deactivate() } }
  }
  private func objectRow(_ object: IdleScreenAquariumWebSurface.PresetObject) -> some View {
    VStack(alignment: .leading) {
      Text(
        editor.snapshot?.catalog.first { $0.id == object.assetId }?.label
          ?? object.assetId.replacingOccurrences(of: "-", with: " ").capitalized)
      Text(object.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .tag(object.id)
  }

}

private struct PlantedTankStockPicker: View {
  let editor: IdleScreenPlantedTankEditor
  @State private var assetID = "fish/chili"

  var body: some View {
    VStack(alignment: .leading) {
      Text("Animals").font(.headline)
      Picker("Animal", selection: $assetID) {
        ForEach(editor.snapshot?.stockCatalog ?? []) { asset in
          Text(asset.label).tag(asset.id)
        }
      }
      Button("Add animal") { Task { await editor.addAnimal(assetID: assetID) } }
    }
    .disabled(editor.isBusy || editor.snapshot == nil || editor.pointerTool != .select)
  }
}

private struct PlantedTankAssetPicker: View {
  let editor: IdleScreenPlantedTankEditor
  @State private var assetID = "rotala"
  @State private var x: Double = -22
  @State private var depth: Double = 12

  private var placement: String? {
    editor.snapshot?.catalog.first { $0.id == assetID }?.placement
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Add plants and hardscape").font(.headline)
      Picker("Specimen", selection: $assetID) {
        ForEach(editor.snapshot?.catalog ?? []) { asset in
          Text(asset.label).tag(asset.id)
        }
      }
      TextField("Across (cm)", value: $x, format: .number)
      TextField("Depth (cm)", value: $depth, format: .number)
      if placement == "attached" {
        Text(
          "Mounts on the highest eligible rock or driftwood at this position. Unsupported positions are rejected."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Button("Place in tank") { Task { await editor.beginPlacing(assetID: assetID) } }
      Button("Add at coordinates") {
        let height = placement == "floating" ? 34.5 : 5
        Task { await editor.add(assetID: assetID, positionCm: .init(x: x, y: height, z: depth)) }
      }
    }
    .disabled(editor.isBusy || editor.snapshot == nil || editor.pointerTool != .select)
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
        .disabled(!editor.canChangeDepthSelected)
      TextField("Turn (°)", value: $degrees, format: .number)
        .disabled(!editor.canRotateSelected)
      if editor.snapshot?.placedObjects.contains(where: { $0.id == object.id }) == true,
        editor.snapshot?.catalog.first(where: { $0.id == object.assetId })?.placement == "attached"
      {
        LabeledContent("Height", value: "Follows its mount")
      } else {
        LabeledContent(
          "Height (cm)", value: object.positionCm.y.formatted(.number.precision(.fractionLength(1)))
        )
      }
      Text("Height follows its current support. Invalid placements are rejected.")
        .font(.caption).foregroundStyle(.secondary)
      Button("Apply position") {
        var moved = object
        moved.positionCm.x = x
        moved.positionCm.z = depth
        moved.rotationY = degrees * .pi / 180
        Task { await editor.update(moved) }
      }
      if editor.canMoveSelected {
        Button("Move in tank") { Task { await editor.beginMoving() } }
      }
      Button("Remove object", role: .destructive) { Task { await editor.removeSelected() } }
        .disabled(!editor.canRemoveSelected)
      if !editor.canRemoveSelected {
        Text(
          "Move equipment along its support. Equipment removal is not available in this preview."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .disabled(editor.isBusy || editor.pointerTool != .select)
  }
}
