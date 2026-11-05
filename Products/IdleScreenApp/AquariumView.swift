import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import MetalKit
import SwiftUI

struct IdleScreenAquariumView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(DisplaySceneCoordinator.self) private var displays
  @State private var controller = IdleScreenAquariumController.shared
  @State private var presentation = IdleScreenAquariumPresentationHost.shared
  @State private var selectedObject: UUID?
  @State private var species: IdleScreenAquariumSpeciesKind = .cherryShrimp
  @State private var variant: IdleScreenAquariumVariant = .red
  @State private var sex: IdleScreenAquariumSex = .female
  @State private var draftName = ""
  @State private var presetName = ""
  @State private var deletePrompt = false
  @State private var rehomeID: UUID?
  @State private var rehomeFromNursery = false
  @State private var selectedTab = "layout"
  @State private var previewAnimal = false

  private var isPreviewingAnimal: Bool { selectedTab == "animals" && previewAnimal }

  private var displayedTank: IdleScreenAquariumTank {
    isPreviewingAnimal
      ? IdleScreenAquariumProduct.previewTank(
        for: species, variant: variant, sex: sex, in: controller.selectedTank)
      : controller.selectedTank
  }

  var body: some View {
    HSplitView {
      tankList.frame(minWidth: 145, idealWidth: 170, maxWidth: 210)
      VStack(spacing: 0) {
        header.padding(12)
        Divider()
        VSplitView {
          preview.frame(minHeight: 170, idealHeight: 300)
          TabView(selection: $selectedTab) {
            layoutPanel.tabItem { Label("Layout", systemImage: "square.3.layers.3d") }.tag("layout")
            livestockPanel.tabItem { Label("Animals", systemImage: "fish") }.tag("animals")
            lightingPanel.tabItem { Label("Lighting", systemImage: "lightbulb") }.tag("lighting")
            equipmentPanel.tabItem { Label("Equipment", systemImage: "water.waves") }.tag(
              "equipment")
            carePanel.tabItem { Label("Care", systemImage: "drop") }.tag("care")
            collectionPanel.tabItem { Label("Collection", systemImage: "square.stack") }.tag(
              "collection")
          }
          .padding(8)
          .frame(minHeight: 240, idealHeight: 290)
          .disabled(!controller.isWritable)
        }
        if let message = controller.errorMessage ?? presentation.errorMessage {
          HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(message).font(.caption)
            Spacer()
            Button("Reload") { controller.reload() }
          }
          .foregroundStyle(.orange).padding(10)
        }
      }
      .frame(minWidth: 540)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { draftName = controller.selectedTank.name }
    .onChange(of: controller.library.selectedTankID) { _, _ in
      selectedObject = nil
      draftName = controller.selectedTank.name
    }
    .confirmationDialog("Delete this tank and its inhabitants?", isPresented: $deletePrompt) {
      Button("Delete tank", role: .destructive) { controller.deleteTank() }
    } message: {
      Text("Decorations return to the collection. Animals and broods in this tank will be removed.")
    }
    .confirmationDialog(
      "Rehome this animal?",
      isPresented: Binding(
        get: { rehomeID != nil }, set: { if !$0 { rehomeID = nil } })
    ) {
      Button("Rehome", role: .destructive) {
        if let id = rehomeID {
          controller.perform { try $0.rehome(id: id, fromNursery: rehomeFromNursery) }
        }
        rehomeID = nil
      }
    } message: {
      Text(
        "This removes the animal from your collection. In Collection mode, raised offspring earn 3 coins."
      )
    }
  }

  private var tankList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Aquariums").font(.headline).padding(.horizontal)
      List(
        controller.library.tanks,
        selection: Binding(
          get: { Optional(controller.library.selectedTankID) },
          set: { if let id = $0 { controller.select(id) } })
      ) { tank in
        VStack(alignment: .leading, spacing: 3) {
          Text(tank.name).lineLimit(1)
          Text("\(tank.animals.count) inhabitants").font(.caption).foregroundStyle(.secondary)
        }.tag(tank.id)
      }
      HStack {
        Button {
          controller.newTank()
        } label: {
          Image(systemName: "plus")
        }.help("New empty tank")
          .accessibilityLabel("New tank")
        Button {
          controller.duplicateTank()
        } label: {
          Image(systemName: "doc.on.doc")
        }.help("Duplicate layout without livestock")
          .accessibilityLabel("Duplicate layout")
        Button {
          deletePrompt = true
        } label: {
          Image(systemName: "trash")
        }.disabled(controller.library.tanks.count < 2)
          .accessibilityLabel("Delete tank")
      }.padding(.horizontal).padding(.bottom, 10)
    }.padding(.top, 14)
  }

  private var header: some View {
    HStack {
      TextField("Tank name", text: $draftName)
        .textFieldStyle(.plain).font(.title2.weight(.semibold))
        .onSubmit {
          controller.editTank {
            $0.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }
      Spacer()
      Button("Window") { presentation.showWindowed() }
      Button(controller.library.desktopEnabled ? "Stop desktop" : "Show desktop") {
        presentation.toggleDesktop()
      }
      Button("Use as saver") {
        model.updateSource(.generative)
        model.updateCreativePattern(.aquarium)
      }
      Button {
        controller.undoLayout()
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }
      .disabled(!controller.canUndo).help("Undo layout").accessibilityLabel("Undo layout")
      Button {
        controller.redoLayout()
      } label: {
        Image(systemName: "arrow.uturn.forward")
      }
      .disabled(!controller.canRedo).help("Redo layout").accessibilityLabel("Redo layout")
    }
  }

  private var preview: some View {
    GeometryReader { geometry in
      let fitted = IdleScreenPreviewWindowGeometry.fittedPreviewSize(
        inside: geometry.size, aspectRatio: Double(controller.selectedTank.worldWidth) / 216)
      ZStack {
        Color.black
        ZStack(alignment: .topLeading) {
          IdleScreenAquariumMetalPreview(tank: displayedTank)
          ForEach(selectedTab == "layout" ? controller.selectedTank.placedDecorations : []) {
            item in
            let width =
              item.placementSize.width / Double(controller.selectedTank.worldWidth)
              * fitted.width
            let height = item.placementSize.height / 216 * fitted.height
            Rectangle().fill(.clear)
              .overlay {
                Rectangle().stroke(
                  selectedObject == item.id ? Color.accentColor : .clear, lineWidth: 2)
              }
              .contentShape(Rectangle())
              .frame(width: width, height: height)
              .position(x: item.x * fitted.width, y: item.y * fitted.height - height / 2)
              .onTapGesture { selectedObject = item.id }
              .gesture(
                DragGesture(minimumDistance: 3).onEnded { gesture in
                  var moved = item
                  moved.x += gesture.translation.width / fitted.width
                  moved.y += gesture.translation.height / fitted.height
                  controller.updateDecoration(moved)
                  selectedObject = item.id
                }
              )
              .accessibilityLabel(item.kind.title)
              .accessibilityHint("Select to edit position, size and layer")
          }
        }
        .frame(width: fitted.width, height: fitted.height)
      }
      .overlay(alignment: .topLeading) {
        if isPreviewingAnimal {
          HStack {
            Text("Preview: \(species.title) · not added")
            Button("Show tank") { previewAnimal = false }
          }
          .font(.caption).padding(8).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 8)
          )
          .padding(8)
        }
      }
    }
  }

  private var layoutPanel: some View {
    HStack(alignment: .top, spacing: 16) {
      ScrollView {
        Form {
          Picker(
            "Tank length",
            selection: Binding(
              get: { controller.selectedTank.worldSize ?? .standard },
              set: { size in controller.editTank(recordLayout: true) { $0.worldSize = size } })
          ) {
            ForEach(IdleScreenAquariumWorldSize.allCases) { size in
              Text(size.title).tag(size)
            }
          }
          choice("Substrate", selection: tankBinding(\.substrate, layout: true))
          LabeledContent("Gravel depth") {
            Slider(value: tankBinding(\.substrateDepth, layout: true), in: 0.08...0.24)
          }
          Picker(
            "Add decoration",
            selection: Binding<IdleScreenAquariumDecorationKind?>(
              get: { nil },
              set: {
                if let kind = $0 { controller.addDecoration(kind) }
              })
          ) {
            Text("Choose an item…").tag(Optional<IdleScreenAquariumDecorationKind>.none)
            ForEach(IdleScreenAquariumDecorationKind.allCases) { kind in
              Text("\(kind.title) · \(price(kind.price))").tag(Optional(kind))
            }
          }
          Text(
            "Drag objects in the tank, or select one to adjust it. The upper swimming lane stays clear."
          )
          .font(.caption).foregroundStyle(.secondary)
          Button(
            "Reset layout · \(layoutPrice(.init(tank: IdleScreenAquariumLibrary.starter.tanks[0])))"
          ) {
            controller.resetLayout()
            selectedObject = nil
          }
        }
        Divider().padding(.vertical, 8)
        presetControls
      }.frame(maxWidth: .infinity)
      if let item = controller.selectedTank.placedDecorations.first(where: {
        $0.id == selectedObject
      }) {
        ScrollView { objectInspector(item) }.frame(maxWidth: .infinity)
      } else {
        VStack(alignment: .leading) {
          Text("Placed objects").font(.headline)
          ScrollView {
            ForEach(controller.selectedTank.placedDecorations) { item in
              Button(item.kind.title) { selectedObject = item.id }.buttonStyle(.plain).padding(3)
            }
          }
        }.frame(maxWidth: .infinity)
      }
    }.padding(12)
  }

  private var presetControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Saved layouts").font(.headline)
      TextField("Preset name", text: $presetName)
      Button("Save layout preset") {
        controller.savePreset(name: presetName)
      }
      .disabled(
        presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || presetName.count > 64 || (controller.library.layoutPresets?.count ?? 0) >= 16)
      ForEach(controller.library.layoutPresets ?? []) { preset in
        HStack {
          Text(preset.name).lineLimit(1)
          Spacer()
          Button("Apply · \(layoutPrice(preset.layout))") {
            controller.applyPreset(preset.id)
            selectedObject = nil
          }
          Button {
            controller.perform { try $0.deleteLayoutPreset(id: preset.id) }
          } label: {
            Image(systemName: "trash")
          }.accessibilityLabel("Delete preset \(preset.name)")
        }
      }
      Text(
        "Layouts contain decorations, substrate, tank length and lighting. Animals and equipment stay in their tank."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func layoutPrice(_ layout: IdleScreenAquariumLayout) -> String {
    guard let cost = try? controller.library.costToApplyLayout(layout) else { return "Unavailable" }
    return price(cost)
  }

  private func objectInspector(_ item: IdleScreenAquariumDecoration) -> some View {
    Form {
      Text(item.kind.title).font(.headline)
      if item.kind == .moss { mossAttachmentControls(item) }
      LabeledContent("Horizontal") { Slider(value: objectBinding(item, \.x), in: 0.04...0.96) }
      LabeledContent("Bottom") {
        Slider(value: objectBinding(item, \.y), in: (item.kind == .moss ? 0.22 : 0.55)...0.96)
      }
      LabeledContent("Size") { Slider(value: objectBinding(item, \.scale), in: 0.5...1.5) }
      Picker(
        "Tilt",
        selection: Binding(
          get: {
            controller.selectedTank.placedDecorations.first { $0.id == item.id }?.tilt ?? .upright
          },
          set: { tilt in
            var updated =
              controller.selectedTank.placedDecorations.first { $0.id == item.id } ?? item
            updated.tilt = tilt == .upright ? nil : tilt
            controller.updateDecoration(updated)
          })
      ) {
        ForEach(IdleScreenAquariumObjectTilt.allCases) { tilt in Text(tilt.title).tag(tilt) }
      }
      Toggle("Flip", isOn: objectBinding(item, \.flipped))
      Toggle("Foreground", isOn: objectBinding(item, \.foreground))
      Button("Return to collection", role: .destructive) {
        controller.removeDecoration(item.id)
        selectedObject = nil
      }
    }
  }

  private func mossAttachmentControls(_ item: IdleScreenAquariumDecoration) -> some View {
    VStack(alignment: .leading) {
      Picker(
        "Attach to",
        selection: Binding<UUID?>(
          get: { item.attachment?.parentID },
          set: { parentID in
            controller.editTank(recordLayout: true) { tank in
              if let parentID {
                try tank.attachMoss(id: item.id, to: parentID)
              } else {
                try tank.detachMoss(id: item.id)
              }
            }
          })
      ) {
        Text("Unattached").tag(Optional<UUID>.none)
        ForEach(controller.selectedTank.placedDecorations.filter { $0.kind.supportsMoss }) {
          parent in
          Text("\(parent.kind.title) · \(Int(parent.x * 100))% across").tag(Optional(parent.id))
        }
      }
      Text(
        "Attached moss follows its support's position, size, flip, tilt and layer. Editing the moss directly detaches it."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var livestockPanel: some View {
    HStack(alignment: .top) {
      ScrollView {
        Form {
          choice("Species", selection: $species)
          Text("\(species.sizeDescription) · \(species.habitat.title) · 1 space")
            .font(.caption).foregroundStyle(.secondary)
          Text(species.behaviorDescription).font(.caption)
          Text("Sizes are stylized for readability, not biological proportions.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("Preview selected animal", isOn: $previewAnimal)
          choice("Shrimp variant", selection: $variant)
            .disabled(species != .cherryShrimp)
          Picker("Sex", selection: $sex) {
            Text("Female").tag(IdleScreenAquariumSex.female)
            Text("Male").tag(IdleScreenAquariumSex.male)
          }
          Button("Add \(species.title) · \(price(species.price))") {
            controller.perform { try $0.buyAnimal(species, variant: variant, sex: sex, id: UUID()) }
          }
          Text(
            "\(controller.selectedTank.reservedPopulation) / \(controller.selectedTank.capacity) spaces, including carried broods"
          )
          .font(.caption).foregroundStyle(.secondary)
          Stepper(
            "Tank capacity: \(controller.selectedTank.capacity)", value: tankBinding(\.capacity),
            in: 4...32)
          Toggle("Breed cherry shrimp", isOn: tankBinding(\.breedingEnabled))
          Text(
            "Adults carry a brood before juveniles appear. These are accelerated game rules. Full tanks pause new broods."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(controller.selectedTank.animals) { animal in
            HStack {
              VStack(alignment: .leading) {
                Text(animal.species.title)
                Text(
                  "\(animal.species == .cherryShrimp ? animal.variant.title + " · " : "")\(animal.isAdult ? "Adult" : "Juvenile")\(controller.selectedTank.broods.contains(where: { $0.motherID == animal.id }) ? " · Carrying eggs" : "")"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Nursery") { controller.perform { try $0.moveToNursery(id: animal.id) } }
              Button("Rehome") {
                rehomeFromNursery = false
                rehomeID = animal.id
              }
            }
          }
        }
      }.frame(maxWidth: .infinity)
    }.padding(12)
  }

  private var lightingPanel: some View {
    Form {
      choice("Lighting", selection: tankBinding(\.lighting.preset))
      LabeledContent("Brightness") {
        Slider(value: tankBinding(\.lighting.brightness), in: 0.15...1)
      }
      Stepper(
        "Daylight starts at \(controller.selectedTank.lighting.startsAtHour):00",
        value: tankBinding(\.lighting.startsAtHour), in: 0...23)
      Stepper(
        "Daylight: \(controller.selectedTank.lighting.durationHours) hours",
        value: tankBinding(\.lighting.durationHours), in: 1...18)
      Text(
        "Automatic lighting follows your local day. Blacklight is a decorative fluorescence effect; UV clarification is separate equipment."
      )
      .font(.caption).foregroundStyle(.secondary)
    }.padding(16)
  }

  private var equipmentPanel: some View {
    ScrollView {
      Form {
        ForEach(IdleScreenAquariumEquipment.allCases) { item in
          Toggle(
            "\(item.title) · \(equipmentPrice(item))",
            isOn: Binding(
              get: { controller.selectedTank.automation.equipment.contains(item) },
              set: { enabled in
                if enabled {
                  controller.perform { try $0.buyEquipment(item) }
                } else {
                  controller.perform { try $0.setEquipmentActive(item, active: false) }
                }
              }))
        }
        meter("Filter media load", controller.selectedTank.water.filterLoad ?? 0)
        let owned = controller.selectedTank.automation.equipment.union(
          controller.selectedTank.automation.inactiveEquipment ?? [])
        Button("Rinse filter media · Free") { controller.perform { try $0.serviceFilter() } }
          .disabled(!owned.contains(.spongeFilter) && !owned.contains(.externalFilter))
        Text(
          "Rinsing clears captured waste without resetting filter maturity. Media load is bounded, so filtering continues while you're away."
        )
        .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Flow") {
          Slider(value: tankBinding(\.automation.flow), in: 0...1)
            .help("Adjusts the current and filter turnover.")
        }
        LabeledContent("Heater set point") {
          Slider(
            value: tankBinding(\.automation.heaterTemperature),
            in: controller.selectedTank.keeperMode
              ? controller.selectedTank.habitat.temperatureRange : 18...30)
        }
        Stepper(
          "Feed every \(controller.selectedTank.automation.feedEveryMinutes) game minutes",
          value: tankBinding(\.automation.feedEveryMinutes), in: 5...240, step: 5)
        Stepper(
          "Water change every \(controller.selectedTank.automation.changeEveryMinutes) game minutes",
          value: tankBinding(\.automation.changeEveryMinutes), in: 10...360, step: 10)
        LabeledContent("Water-change fraction") {
          Slider(value: tankBinding(\.automation.waterChangeFraction), in: 0.1...0.5)
        }
        LabeledContent("Nitrate dosing set point") {
          Slider(value: tankBinding(\.automation.nitrateSetPoint), in: 0.1...0.8)
        }
        Text(
          "The dosing controller manages nitrate in this simplified game model. It doesn't replace biological filtration."
        )
        .font(.caption).foregroundStyle(.secondary)
      }.padding(16)
    }
  }

  private var carePanel: some View {
    ScrollView {
      Form {
        Toggle(
          "Keeper rules",
          isOn: Binding(
            get: { controller.selectedTank.keeperMode },
            set: { enabled in controller.perform { try $0.setKeeperMode(enabled) } }))
        choice(
          "Habitat",
          selection: Binding(
            get: { controller.selectedTank.habitat },
            set: { habitat in controller.perform { try $0.setHabitat(habitat) } }))
        Text(
          "Enabling Keeper supplies a free filter, feeder and timer, applies game habitat bounds, and schedules 6–12 hours of daylight. You can adjust the equipment afterward."
        )
        .font(.caption).foregroundStyle(.secondary)
        if controller.selectedTank.habitat == .fantasy {
          Text(
            "Fantasy allows a mixed display community. Choose Freshwater or Marine for habitat stocking rules."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Text(
          controller.selectedTank.keeperMode
            ? controller.selectedTank.water.summary : "Display mode is maintenance-free"
        )
        .font(.headline)
        HStack {
          Button("Feed") { controller.perform { try $0.feed() } }
          Button("Change 25% water") { controller.perform { try $0.changeWater(fraction: 0.25) } }
        }
        if let fedAt = controller.selectedTank.lastFedAt {
          Text("Last feeding: \(fedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
        }
        let water = controller.selectedTank.water
        meter("Waste", water.waste)
        meter("Ammonia", water.ammonia)
        meter("Nitrite", water.nitrite)
        meter("Nitrate", water.nitrate)
        meter("Oxygen", water.oxygen)
        meter("Filter maturity", water.filterMaturity)
        if controller.selectedTank.keeperMode {
          Text(
            "Temperature: \(water.temperature, specifier: "%.1f") °C · pH: \(water.ph, specifier: "%.1f") · Salinity: \(water.salinity, specifier: "%.1f")"
          )
          .font(.caption)
        }
        Text(
          "Care uses simplified game values. Growth catches up for at most six hours, and animals aren't lost while you're away."
        )
        .font(.caption).foregroundStyle(.secondary)
      }.padding(16)
    }
  }

  private var collectionPanel: some View {
    ScrollView {
      Form {
        Picker(
          "Catalog",
          selection: Binding(
            get: { controller.library.economy },
            set: { value in controller.perform { $0.economy = value } })
        ) {
          Text("Free sandbox").tag(IdleScreenAquariumEconomy.sandbox)
          Text("Earned coins").tag(IdleScreenAquariumEconomy.collection)
        }
        Text(
          "\(controller.library.balance) coins · \(controller.library.unlockedVariants.count) shrimp variants collected"
        )
        Text("Raised offspring earn coins when rehomed. No real-money purchases.").font(.caption)
          .foregroundStyle(.secondary)
        ForEach(
          IdleScreenAquariumDecorationKind.allCases.filter {
            controller.library.inventory[$0.rawValue, default: 0] > 0
          }
        ) { item in
          HStack {
            Text("\(item.title) · \(controller.library.inventory[item.rawValue, default: 0]) owned")
            Spacer()
            Button("Place") { controller.addDecoration(item) }
          }
        }
        Section("Nursery") {
          ForEach(controller.selectedTank.nursery) { animal in
            HStack {
              Text(
                animal.species.title
                  + (animal.species == .cherryShrimp ? " · " + animal.variant.title : ""))
              Spacer()
              Button("Return") { controller.perform { try $0.returnFromNursery(id: animal.id) } }
              Button("Rehome") {
                rehomeFromNursery = true
                rehomeID = animal.id
              }
            }
          }
        }
        Section("Display assignments") {
          Picker(
            "Layout",
            selection: Binding(
              get: { controller.library.presentation },
              set: { value in controller.perform { $0.presentation = value } })
          ) {
            Text("One tank per display").tag(IdleScreenAquariumPresentation.perDisplay)
            Text("Panorama").tag(IdleScreenAquariumPresentation.panorama)
          }
          ForEach(
            displays.latestSnapshot?.topology.displays.filter { $0.mirrorTargetIdentifier == nil }
              ?? [], id: \.persistentIdentifier
          ) { display in
            let identifier = display.persistentIdentifier.rawValue
            Picker(
              display.isPrimary ? "Primary display" : "Display \(identifier.suffix(6))",
              selection: Binding(
                get: { controller.library.tank(for: identifier).id },
                set: { id in controller.perform { try $0.assign(tankID: id, to: identifier) } })
            ) {
              ForEach(controller.library.tanks) { tank in Text(tank.name).tag(tank.id) }
            }
          }
        }
      }.padding(16)
    }
  }

  private func meter(_ title: String, _ value: Double) -> some View {
    LabeledContent(title) { ProgressView(value: value, total: 1).frame(maxWidth: 220) }
  }
  private func equipmentPrice(_ item: IdleScreenAquariumEquipment) -> String {
    let automation = controller.selectedTank.automation
    return automation.equipment.contains(item)
      || automation.inactiveEquipment?.contains(item) == true
      ? "Owned" : price(item.price)
  }

  private func price(_ value: Int) -> String {
    controller.library.economy == .sandbox ? "Free" : "\(value) coins"
  }
  private func choice<Value: IdleScreenAquariumChoice & Hashable>(
    _ title: String, selection: Binding<Value>
  ) -> some View {
    Picker(title, selection: selection) {
      ForEach(Array(Value.allCases)) { Text($0.title).tag($0) }
    }
  }
  private func tankBinding<Value>(
    _ path: WritableKeyPath<IdleScreenAquariumTank, Value>, layout: Bool = false
  ) -> Binding<Value> {
    Binding(
      get: { controller.selectedTank[keyPath: path] },
      set: { value in controller.editTank(recordLayout: layout) { $0[keyPath: path] = value } })
  }
  private func objectBinding<Value>(
    _ item: IdleScreenAquariumDecoration,
    _ path: WritableKeyPath<IdleScreenAquariumDecoration, Value>
  ) -> Binding<Value> {
    Binding(
      get: {
        (controller.selectedTank.placedDecorations.first { $0.id == item.id } ?? item)[
          keyPath: path]
      },
      set: { value in
        var updated = controller.selectedTank.placedDecorations.first { $0.id == item.id } ?? item
        updated[keyPath: path] = value
        controller.updateDecoration(updated)
      })
  }
}

@MainActor
struct IdleScreenAquariumMetalPreview: NSViewRepresentable {
  let tank: IdleScreenAquariumTank
  @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion
  private let motionOverride: Bool?
  init(tank: IdleScreenAquariumTank, reduceMotion: Bool? = nil) {
    self.tank = tank
    motionOverride = reduceMotion
  }
  private var isReducedMotion: Bool { motionOverride ?? environmentReduceMotion }
  private var configuration: IdleScreenRendererConfiguration {
    var value = IdleScreenAquariumProduct.configuration(for: tank)
    value.aquariumSettings?.reduceMotion = isReducedMotion
    return value
  }
  final class Coordinator { var renderer: IdleScreenRenderer? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero)
    do {
      context.coordinator.renderer = try IdleScreenRenderer(
        metalView: view, configuration: configuration, automaticallyDraws: !isReducedMotion)
      view.enableSetNeedsDisplay = isReducedMotion
    } catch { view.isPaused = true }
    return view
  }
  func updateNSView(_ view: MTKView, context: Context) {
    context.coordinator.renderer?.update(configuration: configuration)
    view.isPaused = isReducedMotion
    view.enableSetNeedsDisplay = isReducedMotion
    if isReducedMotion { view.needsDisplay = true }
  }
  static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
    coordinator.renderer?.shutdown()
    coordinator.renderer = nil
  }
}
