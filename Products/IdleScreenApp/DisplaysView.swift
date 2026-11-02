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
    DesignPage(
      title: "Displays",
      summary: "Choose how your screen saver spreads across your displays.",
      trailing: {
        Button {
          coordinator.refreshTopology()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.designSecondary)
        .accessibilityLabel("Refresh display layout")
      }
    ) {
      DesignSection(
        eyebrow: "Layout",
        footer: "Select a display to preview it in Studio."
      ) {
        arrangement
      }

      DesignSection(eyebrow: "Scene") {
        DesignRow(title: "Scene layout", detail: policyDetail) {
          DesignSegmented(
            title: "Scene layout",
            selection: policyBinding,
            choices: [
              DesignChoice("Panorama", DisplayScenePolicy.panorama),
              DesignChoice("Per Display", DisplayScenePolicy.perDisplay),
              DesignChoice("Focus Display", DisplayScenePolicy.focusDisplay),
            ]
          )
        }
        if model.configuration.display.policy == .focusDisplay {
          DesignRow(
            title: "Focus display",
            detail: "The display that shows the scene."
          ) {
            DesignPopup(
              title: "Focus display",
              selection: focalDisplayBinding,
              choices: renderingDisplays.map {
                DesignChoice(
                  displayLabel($0.persistentIdentifier),
                  Optional($0.persistentIdentifier)
                )
              }
            )
          }
          DesignRow(
            title: "Other displays",
            detail: "How the displays without the scene look."
          ) {
            DesignPopup(
              title: "Other displays",
              selection: quietBinding,
              choices: [
                DesignChoice("Black", DisplayQuietTreatment.black),
                DesignChoice("Subdued", DisplayQuietTreatment.subdued),
              ]
            )
          }
        }
      }

      DesignSection(eyebrow: "Edges and preview") {
        DesignRow(title: "Outer edges", detail: boundaryDetail) {
          DesignPopup(
            title: "Outer edges",
            selection: boundaryBinding,
            choices: [
              DesignChoice("Wall", DisplayOuterBoundaryBehavior.wall),
              DesignChoice("Drain", DisplayOuterBoundaryBehavior.drain),
              DesignChoice("Off-world", DisplayOuterBoundaryBehavior.offWorld),
            ]
          )
        }
        DesignRow(
          title: "Show display numbers",
          detail: "Number each display in the layout above."
        ) {
          Toggle("Show display numbers", isOn: $showsIdentification)
            .labelsHidden()
            .accessibilityLabel("Show display numbers")
            .toggleStyle(.designSwitch)
        }
        DesignRow(
          title: "Preview in Studio",
          detail: "Show the selected display in the Studio preview."
        ) {
          Button("Open in Studio") {
            navigation.destination = .studio
          }
          .buttonStyle(.designSecondary)
          .accessibilityLabel("Open selected display in Studio")
          .disabled(navigation.previewDisplayIdentifier == nil)
        }
      }

      DesignDetails(initiallyExpanded: detailsInitiallyExpanded) {
        DesignRow(title: "Display layout version") {
          DesignValueText(layoutVersion)
        }
        DesignRow(title: "Scene plan") {
          DesignValueText(planSummary)
        }
        DesignRow(title: "Configuration revision") {
          DesignValueText(String(model.configuration.revision))
        }
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
    let index = renderingDisplays.firstIndex {
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
            .font(DesignFont.mono(32, .semibold))
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
