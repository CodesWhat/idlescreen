import Foundation
import IdleScreenCore
import SwiftUI

struct IntegrationsView: View {
    @Environment(IdleScreenAppModel.self) private var model
    @State private var expandedSnippet: IdleScreenAgentProvider?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                preview
                providerCard(.codex)
                providerCard(.claude)
                presentationControls
                diagnostics
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
        }
        .background(Color.black.opacity(0.88))
        .onAppear {
            model.refreshAgentHookInstallationStatus()
            model.refreshAgentSignals()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent Integrations")
                .font(.system(size: 27, weight: .bold))
            Text("Show brief, expiring Codex and Claude lifecycle status on idlescreen. Prompt, transcript, tool, command, assistant, credential, and error content is never imported.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preview: some View {
        GroupBox("Saver preview") {
            ZStack {
                LinearGradient(
                    colors: [.black, .indigo.opacity(0.32)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                AgentSignalOverlayView(presentation: previewPresentation)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: previewPresentation.position.swiftUIAlignment
                    )
                    .padding(18)
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func providerCard(_ provider: IdleScreenAgentProvider) -> some View {
        let enabled = model.configuration.agentIntegration.isEnabled(for: provider)
        let installed = provider == .codex
            ? model.codexHooksInstalled : model.claudeHooksInstalled
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: providerEnabledBinding(provider)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(providerName(provider))
                            .font(.headline)
                        Text(providerMapping(provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Send Test") { model.testAgentSignal(for: provider) }
                        .disabled(!enabled)
                    Button(expandedSnippet == provider ? "Hide Hook JSON" : "Preview Hook JSON") {
                        expandedSnippet = expandedSnippet == provider ? nil : provider
                    }
                    Spacer()
                    if installed {
                        Button("Uninstall Hooks", role: .destructive) {
                            model.uninstallAgentHooks(for: provider)
                        }
                    } else {
                        Button("Install Hooks") {
                            model.installAgentHooks(for: provider)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!enabled || !model.hasSharedContainer)
                    }
                }

                if expandedSnippet == provider {
                    ScrollView(.horizontal) {
                        Text(model.previewAgentHookConfiguration(for: provider))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
                    Text(provider == .codex
                        ? "Codex requires you to review and trust non-managed command hooks with /hooks after installation."
                        : "Installation merges these entries into ~/.claude/settings.json and preserves unrelated settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var presentationControls: some View {
        GroupBox("Presentation and expiry") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Timeout")
                    Slider(value: timeoutBinding, in: 15...600, step: 15)
                    Text("\(Int(model.configuration.agentIntegration.messageTimeout)) sec")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Picker("Display", selection: destinationBinding) {
                        Text("All displays").tag(IdleScreenAgentDisplayDestination.all)
                        Text("Primary display").tag(IdleScreenAgentDisplayDestination.primary)
                        Text("Focus display").tag(IdleScreenAgentDisplayDestination.focus)
                    }
                    Picker("Position", selection: positionBinding) {
                        ForEach(IdleScreenAgentOverlayPosition.allCases, id: \.self) {
                            Text(positionName($0)).tag($0)
                        }
                    }
                }
                Toggle("Show provider label", isOn: showsProviderBinding)
                Toggle("Show explicit message text", isOn: showsMessageBinding)
                quietHoursControls
                Divider()
                Text("State mapping")
                    .font(.headline)
                stateStyleRow("Working", keyPath: \.working)
                stateStyleRow("Needs attention", keyPath: \.needsAttention)
                stateStyleRow("Done", keyPath: \.done)
                stateStyleRow("Error", keyPath: \.error)
            }
            .padding(4)
        }
    }

    private var quietHoursControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Quiet hours", isOn: quietHoursEnabledBinding)
            if model.configuration.agentIntegration.quietHours != nil {
                HStack {
                    DatePicker("From", selection: quietStartBinding, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: quietEndBinding, displayedComponents: .hourAndMinute)
                }
            }
        }
    }

    private var diagnostics: some View {
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.activeAgentSignal.map {
                    "Active: \(providerName($0.provider)) · \($0.state.rawValue) · expires \($0.expiresAt.formatted(date: .omitted, time: .standard))"
                } ?? "No active signal")
                Text("Ignored unknown events: Codex \(model.agentIgnoredEventCounts[.codex, default: 0]), Claude \(model.agentIgnoredEventCounts[.claude, default: 0])")
                    .foregroundStyle(.secondary)
                if let status = model.agentIntegrationStatus {
                    Text(status).foregroundStyle(.secondary)
                }
                Button("Clear All Signals", role: .destructive) {
                    model.clearAgentSignals()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var previewPresentation: IdleScreenAgentOverlayPresentation {
        model.agentPresentation() ?? IdleScreenAgentOverlayPresentation(
            provider: .codex,
            state: .needsAttention,
            providerLabel: model.configuration.agentIntegration.showsProviderLabel
                ? "Codex" : nil,
            title: "Codex needs attention",
            message: model.configuration.agentIntegration.showsMessage
                ? "Approve the next step" : nil,
            style: model.configuration.agentIntegration.stateVisuals.needsAttention,
            position: model.configuration.agentIntegration.overlayPosition,
            accessibilityLabel: "Codex needs attention, Approve the next step",
            expiresAt: Date().addingTimeInterval(120)
        )
    }

    private func providerEnabledBinding(
        _ provider: IdleScreenAgentProvider
    ) -> Binding<Bool> {
        Binding(
            get: { model.configuration.agentIntegration.isEnabled(for: provider) },
            set: { enabled in
                model.updateAgentIntegration {
                    if provider == .codex { $0.codexEnabled = enabled }
                    else { $0.claudeEnabled = enabled }
                }
            }
        )
    }

    private var timeoutBinding: Binding<Double> {
        Binding(
            get: { model.configuration.agentIntegration.messageTimeout },
            set: { value in model.updateAgentIntegration { $0.messageTimeout = value } }
        )
    }

    private var destinationBinding: Binding<IdleScreenAgentDisplayDestination> {
        Binding(
            get: { model.configuration.agentIntegration.displayDestination },
            set: { value in model.updateAgentIntegration { $0.displayDestination = value } }
        )
    }

    private var positionBinding: Binding<IdleScreenAgentOverlayPosition> {
        Binding(
            get: { model.configuration.agentIntegration.overlayPosition },
            set: { value in model.updateAgentIntegration { $0.overlayPosition = value } }
        )
    }

    private var showsProviderBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.agentIntegration.showsProviderLabel },
            set: { value in model.updateAgentIntegration { $0.showsProviderLabel = value } }
        )
    }

    private var showsMessageBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.agentIntegration.showsMessage },
            set: { value in model.updateAgentIntegration { $0.showsMessage = value } }
        )
    }

    private var quietHoursEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.agentIntegration.quietHours != nil },
            set: { enabled in
                model.updateAgentIntegration {
                    $0.quietHours = enabled
                        ? IdleScreenAgentQuietHours(startMinute: 1_320, endMinute: 420)
                        : nil
                }
            }
        )
    }

    private var quietStartBinding: Binding<Date> { quietDateBinding(isStart: true) }
    private var quietEndBinding: Binding<Date> { quietDateBinding(isStart: false) }

    private func quietDateBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let quiet = model.configuration.agentIntegration.quietHours
                    ?? .init(startMinute: 1_320, endMinute: 420)
                return date(for: isStart ? quiet.startMinute : quiet.endMinute)
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                model.updateAgentIntegration {
                    let quiet = $0.quietHours
                        ?? .init(startMinute: 1_320, endMinute: 420)
                    $0.quietHours = .init(
                        startMinute: isStart ? minute : quiet.startMinute,
                        endMinute: isStart ? quiet.endMinute : minute
                    )
                }
            }
        )
    }

    private func stateStyleRow(
        _ label: String,
        keyPath: WritableKeyPath<IdleScreenAgentStateVisuals, IdleScreenAgentVisualStyle>
    ) -> some View {
        Picker(label, selection: Binding(
            get: { model.configuration.agentIntegration.stateVisuals[keyPath: keyPath] },
            set: { value in
                model.updateAgentIntegration { $0.stateVisuals[keyPath: keyPath] = value }
            }
        )) {
            ForEach(IdleScreenAgentVisualStyle.allCases, id: \.self) {
                Text($0.rawValue.capitalized).tag($0)
            }
        }
    }

    private func date(for minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour: minute / 60,
            minute: minute % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func providerName(_ provider: IdleScreenAgentProvider) -> String {
        provider == .codex ? "Codex" : "Claude"
    }

    private func providerMapping(_ provider: IdleScreenAgentProvider) -> String {
        switch provider {
        case .codex:
            "Start/prompt → working · permission → attention · stop → done · session end → clear"
        case .claude:
            "Start/prompt → working · permission/notification → attention · stop → done · failure → error · session end → clear"
        }
    }

    private func positionName(_ position: IdleScreenAgentOverlayPosition) -> String {
        switch position {
        case .topLeading: "Top Left"
        case .topTrailing: "Top Right"
        case .bottomLeading: "Bottom Left"
        case .bottomTrailing: "Bottom Right"
        }
    }
}
