import IdleScreenCore
import IdleScreenDisplay
import SwiftUI

struct DisplaysView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(IdleScreenCompanionNavigation.self) private var navigation
  @Environment(DisplaySceneCoordinator.self) private var coordinator
  @State private var showsIdentification = false
  private let detailsInitiallyExpanded: Bool

  init(detailsInitiallyExpanded: Bool = false) {
    self.detailsInitiallyExpanded = detailsInitiallyExpanded
  }

  var body: some View {
    WorkbenchSplit(showsInspector: navigation.isInspectorVisible) {
      VStack(spacing: 0) {
        WorkbenchHeader(
          title: "Your displays", summary: "Choose how the scene moves across your screens."
        ) {
          Button {
            coordinator.refreshTopology()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.designSecondary)
          .accessibilityHint("Reads the display layout again")
        }
        arrangement
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(24)
        ScrollView {
          VStack(spacing: 0) {
            ForEach(renderingDisplays, id: \.persistentIdentifier) { display in
              Button {
                navigation.previewDisplayIdentifier = display.persistentIdentifier
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: "display")
                  Text(displayLabel(display.persistentIdentifier))
                  Spacer()
                  Text("\(Int(display.logicalFrame.width)) × \(Int(display.logicalFrame.height))")
                    .foregroundStyle(DesignPalette.ink2)
                  if display.persistentIdentifier == navigation.previewDisplayIdentifier {
                    Image(systemName: "checkmark").foregroundStyle(DesignPalette.accentMark)
                  }
                }
                .font(DesignFont.sans(DesignFont.caption))
                .padding(.vertical, 12)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(
                display.persistentIdentifier == navigation.previewDisplayIdentifier
                  ? .isSelected : [])
              DesignHairline()
            }
            DesignDetails(initiallyExpanded: detailsInitiallyExpanded) {
              DesignRow(title: "Display layout version") { DesignValueText(layoutVersion) }
              DesignRow(title: "Scene plan") { DesignValueText(planSummary) }
              DesignRow(title: "Configuration revision") {
                DesignValueText(String(model.configuration.revision))
              }
            }
          }
          .padding(.horizontal, 28)
          .padding(.vertical, 12)
        }
        .frame(height: detailsInitiallyExpanded ? 300 : 160)
        .background(DesignPalette.surface)
        .overlay(alignment: .top) { DesignHairline() }
      }
    } inspector: {
      WorkbenchInspector(
        eyebrow: "Selected display",
        title: navigation.previewDisplayIdentifier.map(displayLabel) ?? "Displays",
        summary: policyDetail
      ) {
        StudioSection(title: "Scene layout") {
          Picker("Scene layout", selection: policyBinding) {
            Text("Panorama").tag(DisplayScenePolicy.panorama)
            Text("Per display").tag(DisplayScenePolicy.perDisplay)
            Text("Focus display").tag(DisplayScenePolicy.focusDisplay)
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()
          .accessibilityLabel("Scene layout")
          if model.configuration.display.policy == .focusDisplay {
            Picker("Focus display", selection: focalDisplayBinding) {
              ForEach(renderingDisplays, id: \.persistentIdentifier) { display in
                Text(displayLabel(display.persistentIdentifier)).tag(
                  Optional(display.persistentIdentifier))
              }
            }
            Picker("Other displays", selection: quietBinding) {
              Text("Black").tag(DisplayQuietTreatment.black)
              Text("Subdued").tag(DisplayQuietTreatment.subdued)
            }
          }
        }
        StudioSection(title: "Outer edges") {
          Picker("Outer edges", selection: boundaryBinding) {
            Text("Wall").tag(DisplayOuterBoundaryBehavior.wall)
            Text("Drain").tag(DisplayOuterBoundaryBehavior.drain)
            Text("Off-world").tag(DisplayOuterBoundaryBehavior.offWorld)
          }
          .labelsHidden()
          .accessibilityLabel("Outer edges")
          Text(boundaryDetail).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(
            DesignPalette.ink2)
        }
        StudioField(title: "Show display numbers") {
          Toggle("Show display numbers", isOn: $showsIdentification)
            .labelsHidden().accessibilityLabel("Show display numbers")
            .toggleStyle(.designSwitch)
        }
        Button {
          navigation.destination = .studio
        } label: {
          Label("Edit scene on this display", systemImage: "arrow.right")
        }
        .buttonStyle(.designSecondary)
        .disabled(navigation.previewDisplayIdentifier == nil)
      }
    }
    .onAppear {
      selectDefaultDisplayIfNeeded()
    }
    .onChange(of: coordinator.latestSnapshot?.generation) { _, _ in
      selectDefaultDisplayIfNeeded()
    }
  }

  @ViewBuilder
  private var arrangement: some View {
    if let topology = coordinator.latestSnapshot?.topology {
      DisplayArrangementPreview(
        topology: topology,
        plan: coordinator.latestPlan,
        selectedIdentifier: navigation.previewDisplayIdentifier,
        showsIdentification: showsIdentification,
        select: { navigation.previewDisplayIdentifier = $0 }
      )
      .frame(minHeight: 250)
    } else if let failure = coordinator.topologyFailure {
      ContentUnavailableView(
        "Display layout unavailable",
        systemImage: "display.trianglebadge.exclamationmark",
        description: Text(failure.message)
      )
      .frame(minHeight: 250)
    } else {
      ProgressView("Looking for your displays…")
        .frame(maxWidth: .infinity, minHeight: 250)
    }
  }

  private var policyDetail: String {
    switch model.configuration.display.policy {
    case .panorama: "One scene spans every display."
    case .perDisplay: "Each display gets its own scene."
    case .focusDisplay: "One display shows the scene. The others stay quiet."
    }
  }

  /// What each outer-edge setting does in the Pixel Materials simulation. Drain and Off-world both let sand and
  /// water leave through the bottom edge today, so the two share a description until their behavior diverges.
  private var boundaryDetail: String {
    switch model.configuration.display.outerBoundaryBehavior {
    case .wall: "Edges are solid, so sand and water stay on screen."
    case .drain: "Sand and water that reach the bottom edge drain away."
    case .offWorld: "Sand and water that reach the bottom edge leave the scene."
    }
  }

  private var layoutVersion: String {
    coordinator.latestSnapshot.map { "Generation \($0.generation)" } ?? "Not read yet"
  }

  private var planSummary: String {
    guard let plan = coordinator.latestPlan else { return "No plan yet" }
    return
      "\(plan.assignments.count) assignments · \(plan.focalDisplayIdentifiers.count) focal owners"
  }

  private var renderingDisplays: [DisplayTopology.Display] {
    coordinator.latestSnapshot?.topology.displays.filter {
      $0.mirrorTargetIdentifier == nil
    } ?? []
  }

  private var policyBinding: Binding<DisplayScenePolicy> {
    .init(
      get: { model.configuration.display.policy },
      set: { model.updateDisplayPolicy($0) }
    )
  }

  private var focalDisplayBinding: Binding<DisplayTopology.PersistentDisplayIdentifier?> {
    .init(
      get: {
        if let stored = model.configuration.display.focalDisplayIdentifier,
          renderingDisplays.contains(where: {
            $0.persistentIdentifier == stored
          })
        {
          return stored
        }
        return renderingDisplays.first(where: \.isPrimary)?
          .persistentIdentifier
      },
      set: { model.updateFocalDisplay($0) }
    )
  }

  private var quietBinding: Binding<DisplayQuietTreatment> {
    .init(
      get: { model.configuration.display.quietTreatment },
      set: { model.updateDisplayQuietTreatment($0) }
    )
  }

  private var boundaryBinding: Binding<DisplayOuterBoundaryBehavior> {
    .init(
      get: { model.configuration.display.outerBoundaryBehavior },
      set: { model.updateDisplayOuterBoundaryBehavior($0) }
    )
  }

  private func selectDefaultDisplayIfNeeded() {
    if let selected = navigation.previewDisplayIdentifier,
      renderingDisplays.contains(where: {
        $0.persistentIdentifier == selected
      })
    {
      return
    }
    navigation.previewDisplayIdentifier =
      renderingDisplays.first(where: \.isPrimary)?
      .persistentIdentifier ?? renderingDisplays.first?.persistentIdentifier
  }

  private func displayLabel(
    _ identifier: DisplayTopology.PersistentDisplayIdentifier
  ) -> String {
    let index = coordinator.latestSnapshot?.topology.displays.firstIndex {
      $0.persistentIdentifier == identifier
    }.map { $0 + 1 }
    return index.map { "Display \($0)" } ?? "Display"
  }
}

private struct DisplayArrangementPreview: View {
  let topology: DisplayTopology
  let plan: DisplayScenePlan?
  let selectedIdentifier: DisplayTopology.PersistentDisplayIdentifier?
  let showsIdentification: Bool
  let select: (DisplayTopology.PersistentDisplayIdentifier) -> Void

  var body: some View {
    GeometryReader { proxy in
      let bounds = topology.desktopBounds
      let scale = min(
        max(0, proxy.size.width - 32) / bounds.width,
        max(0, proxy.size.height - 32) / bounds.height
      )
      let contentWidth = bounds.width * scale
      let contentHeight = bounds.height * scale
      let originX = (proxy.size.width - contentWidth) / 2
      let originY = (proxy.size.height - contentHeight) / 2

      ForEach(Array(topology.displays.enumerated()), id: \.element.persistentIdentifier) {
        index, display in
        let frame = display.logicalFrame
        let assignment = plan?.assignment(for: display.persistentIdentifier)
        let isSelected =
          selectedIdentifier
          == (assignment?.representativeIdentifier
            ?? display.persistentIdentifier)
        let card = DisplayArrangementCard(
          index: index,
          display: display,
          assignment: assignment,
          isSelected: isSelected,
          showsIdentification: showsIdentification
        )
        Button {
          select(
            assignment?.representativeIdentifier
              ?? display.persistentIdentifier)
        } label: {
          card
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .frame(
          width: max(48, frame.width * scale),
          height: max(40, frame.height * scale)
        )
        .position(
          x: originX + (frame.x - bounds.x) * scale
            + frame.width * scale / 2,
          y: originY + (bounds.maxY - frame.maxY) * scale
            + frame.height * scale / 2
        )
      }
    }
    .padding(8)
  }

}

private struct DisplayArrangementCard: View {
  let index: Int
  let display: DisplayTopology.Display
  let assignment: DisplaySceneAssignment?
  let isSelected: Bool
  let showsIdentification: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(fill)
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          isSelected ? DesignPalette.accentMark : DesignPalette.hair,
          lineWidth: isSelected ? 3 : 1
        )
      VStack(spacing: 5) {
        if showsIdentification {
          Text("\(index + 1)")
            .font(DesignFont.display(33))
        } else {
          Text(roleLabel)
            .font(DesignFont.sans(DesignFont.body, .semibold))
        }
        Text(displaySubtitle)
          .font(DesignFont.sans(DesignFont.caption))
        Text(sizeLabel)
          .font(DesignFont.mono(DesignFont.eyebrow))
      }
      .foregroundStyle(textColor)
      .padding(4)
    }
  }

  var accessibilityDescription: String {
    "\(displaySubtitle), \(roleLabel), \(sizeLabel)"
  }

  private var sizeLabel: String {
    "\(Int(display.logicalFrame.width)) × \(Int(display.logicalFrame.height))"
  }

  private var displaySubtitle: String {
    if display.isPrimary { return "Primary" }
    if display.mirrorTargetIdentifier != nil { return "Mirror" }
    return "Display \(index + 1)"
  }

  private var fill: Color {
    switch assignment?.role {
    case .panorama: DesignPalette.accentSoft
    case .independent: DesignPalette.sel
    case .focus: DesignPalette.accent
    case .quiet(.black): DesignPalette.previewGround
    case .quiet(.subdued): DesignPalette.track
    case .none: DesignPalette.hair2
    }
  }

  private var textColor: Color {
    switch assignment?.role {
    case .focus: DesignPalette.onAccent
    case .quiet(.black): Color.white
    default: DesignPalette.ink
    }
  }

  private var roleLabel: String {
    switch assignment?.role {
    case .panorama: "Panorama"
    case .independent: "Own scene"
    case .focus: "Focus"
    case .quiet(.black): "Black"
    case .quiet(.subdued): "Subdued"
    case .none: "Not used"
    }
  }
}
