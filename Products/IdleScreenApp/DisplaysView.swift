import IdleScreenCore
import IdleScreenDisplay
import SwiftUI

struct DisplaysView: View {
    @Environment(IdleScreenAppModel.self) private var model
    @Environment(IdleScreenCompanionNavigation.self) private var navigation
    @Environment(DisplaySceneCoordinator.self) private var coordinator
    @State private var showsIdentification = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Displays")
                        .font(.largeTitle.bold())
                    Text("One saved scene policy, projected onto the live Mac layout.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let generation = coordinator.latestSnapshot?.generation {
                    Text("Topology g\(generation)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    coordinator.refreshTopology()
                }
            }

            GroupBox("Detected arrangement") {
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
                    ProgressView("Reading display layout…")
                        .frame(maxWidth: .infinity, minHeight: 250)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                GroupBox("Scene policy") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Policy", selection: policyBinding) {
                            Text("Panorama").tag(DisplayScenePolicy.panorama)
                            Text("Per Display").tag(DisplayScenePolicy.perDisplay)
                            Text("Focus Display").tag(DisplayScenePolicy.focusDisplay)
                        }
                        .pickerStyle(.segmented)

                        if model.configuration.display.policy == .focusDisplay {
                            Picker("Focus", selection: focalDisplayBinding) {
                                ForEach(renderingDisplays, id: \.persistentIdentifier) {
                                    display in
                                    Text(displayLabel(display.persistentIdentifier))
                                        .tag(Optional(display.persistentIdentifier))
                                }
                            }
                            Picker("Other displays", selection: quietBinding) {
                                Text("Black").tag(DisplayQuietTreatment.black)
                                Text("Subdued").tag(DisplayQuietTreatment.subdued)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("Edges and preview") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Outer edges", selection: boundaryBinding) {
                            Text("Wall").tag(DisplayOuterBoundaryBehavior.wall)
                            Text("Drain").tag(DisplayOuterBoundaryBehavior.drain)
                            Text("Off-world").tag(DisplayOuterBoundaryBehavior.offWorld)
                        }
                        Toggle("Show identification overlay", isOn: $showsIdentification)
                        Button("Preview selected display in Studio") {
                            navigation.destination = .studio
                        }
                        .disabled(navigation.previewDisplayIdentifier == nil)
                    }
                    .padding(8)
                }
            }

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(26)
        .onAppear {
            selectDefaultDisplayIfNeeded()
        }
        .onChange(of: coordinator.latestSnapshot?.generation) { _, _ in
            selectDefaultDisplayIfNeeded()
        }
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
                   }) {
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

    private var statusLine: String {
        guard let plan = coordinator.latestPlan else {
            return "Waiting for one accepted topology generation."
        }
        return "\(plan.assignments.count) physical assignment(s), "
            + "\(plan.focalDisplayIdentifiers.count) focal owner(s), "
            + "configuration r\(model.configuration.revision)."
    }

    private func selectDefaultDisplayIfNeeded() {
        if let selected = navigation.previewDisplayIdentifier,
           renderingDisplays.contains(where: {
               $0.persistentIdentifier == selected
           }) {
            return
        }
        navigation.previewDisplayIdentifier = renderingDisplays.first(where: \.isPrimary)?
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
                Button {
                    select(assignment?.representativeIdentifier
                        ?? display.persistentIdentifier)
                } label: {
                    DisplayArrangementCard(
                        index: index,
                        display: display,
                        assignment: assignment,
                        isSelected: selectedIdentifier
                            == (assignment?.representativeIdentifier
                                ?? display.persistentIdentifier),
                        showsIdentification: showsIdentification
                    )
                }
                .buttonStyle(.plain)
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
                    isSelected ? Color.accentColor : .white.opacity(0.28),
                    lineWidth: isSelected ? 3 : 1
                )
            VStack(spacing: 5) {
                if showsIdentification {
                    Text("\(index + 1)")
                        .font(.system(size: 36, weight: .black))
                } else {
                    Text(roleLabel)
                        .font(.headline)
                }
                Text(displaySubtitle)
                    .font(.caption)
                Text(
                    "\(Int(display.logicalFrame.width)) × "
                        + "\(Int(display.logicalFrame.height))"
                )
                .font(.caption2.monospacedDigit())
            }
        }
    }

    private var displaySubtitle: String {
        if display.isPrimary { return "Primary" }
        if display.mirrorTargetIdentifier != nil { return "Mirror" }
        return "Display \(index + 1)"
    }

    private var fill: Color {
        switch assignment?.role {
        case .panorama: .blue.opacity(0.32)
        case .independent: .purple.opacity(0.32)
        case .focus: .orange.opacity(0.38)
        case .quiet(.black): .black.opacity(0.82)
        case .quiet(.subdued): .gray.opacity(0.28)
        case .none: .secondary.opacity(0.2)
        }
    }

    private var roleLabel: String {
        switch assignment?.role {
        case .panorama: "Panorama"
        case .independent: "Independent"
        case .focus: "Focus"
        case .quiet(.black): "Black"
        case .quiet(.subdued): "Subdued"
        case .none: "Unassigned"
        }
    }
}
