import Foundation
import IdleScreenCore
import IdleScreenRenderer
import SwiftUI

struct IntegrationsView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(IdleScreenCompanionNavigation.self) private var navigation
  @State private var expandedSnippet: IdleScreenAgentProvider?
  @State private var previewStartedAt = Date()
  private let detailsInitiallyExpanded: Bool

  init(detailsInitiallyExpanded: Bool = false) {
    self.detailsInitiallyExpanded = detailsInitiallyExpanded
  }

  var body: some View {
    WorkbenchSplit(showsInspector: navigation.isInspectorVisible) {
      VStack(spacing: 0) {
        WorkbenchHeader(
          title: "Agents", summary: "Your agents appear as small characters in the scene."
        ) { EmptyView() }
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            if let status = model.agentIntegrationStatus {
              DesignNotice(kind: Self.statusKind(status), text: status)
            }
            preview
            providerSection(.codex)
            providerSection(.claude)
            Text(
              "Prompt, transcript, tool, command, assistant, credential, and error content is never imported."
            )
            .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
            details
          }
          .padding(24)
        }
      }
    } inspector: {
      WorkbenchInspector(
        eyebrow: "Agents", title: "Presentation", summary: "Control how status appears."
      ) {
        presentationControls
        stateStyles
      }
    }
    .onAppear {
      model.refreshAgentHookInstallationStatus()
      model.refreshAgentSignals()
    }
  }

  /// Failures and unavailable states read as errors, the rest as a plain result.
  static func statusKind(_ status: String) -> DesignStatusKind {
    let lower = status.lowercased()
    if lower.contains("failed") || lower.contains("unavailable") { return .error }
    if lower.hasPrefix("enable this provider") { return .attention }
    return .ok
  }

  private var preview: some View {
    DesignSection(
      eyebrow: "Saver preview",
      footer:
        "Agents run along the bottom of the scene. A sample plays until a real signal arrives."
    ) {
      TimelineView(.periodic(from: .now, by: 1)) { timeline in
        IdleScreenMetalPreview(
          configuration: previewConfiguration(at: timeline.date),
          mode: .generative,
          cameraFrame: nil
        )
      }
      .environment(\.colorScheme, .dark)
      .frame(height: 200)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityLabel("Saver preview with agent status sprites")
    }
  }

  private func providerSection(_ provider: IdleScreenAgentProvider) -> some View {
    let name = providerName(provider)
    let enabled = model.configuration.agentIntegration.isEnabled(for: provider)
    let installed =
      provider == .codex
      ? model.codexHooksInstalled : model.claudeHooksInstalled
    return DesignSection(eyebrow: name) {
      DesignRow(
        title: "Show \(name) status",
        detail: "Display \(name) activity on the saver."
      ) {
        Toggle("Show \(name) status", isOn: providerEnabledBinding(provider))
          .labelsHidden()
          .accessibilityLabel("Show \(name) status")
          .toggleStyle(.designSwitch)
      }
      DesignRow(title: "Hooks", detail: hooksDetail(provider, installed: installed)) {
        DesignStatus(
          kind: installed ? .ok : .neutral,
          text: installed ? "Installed" : "Not installed"
        )
        if installed {
          Button("Uninstall hooks") {
            model.uninstallAgentHooks(for: provider)
          }
          .buttonStyle(.designDestructive)
          .accessibilityLabel("Uninstall hooks")
          .accessibilityHint("Removes IdleScreen's \(name) hooks")
        } else {
          Button("Install hooks") {
            model.installAgentHooks(for: provider)
          }
          .buttonStyle(.designPrimary)
          .accessibilityLabel("Install hooks")
          .accessibilityHint("Adds IdleScreen's \(name) hooks")
          .disabled(!enabled || !model.hasSharedContainer)
        }
      }
      DesignRow(
        title: "Send a test",
        detail: "Send a sample \(name) status to check the setup."
      ) {
        Button("Send test") { model.testAgentSignal(for: provider) }
          .buttonStyle(.designSecondary)
          .accessibilityLabel("Send test")
          .accessibilityHint("Sends a sample \(name) status")
          .disabled(!enabled)
      }
    }
  }

  private func hooksDetail(_ provider: IdleScreenAgentProvider, installed: Bool) -> String {
    let name = providerName(provider)
    if installed { return "\(name) reports status to IdleScreen." }
    if !model.hasSharedContainer { return "Hook install isn't available in this build." }
    return "Install hooks so \(name) can report status."
  }

  private var presentationControls: some View {
    DesignSection(eyebrow: "Messages") {
      DesignRow(
        title: "Message timeout",
        detail: "How long a status stays on screen."
      ) {
        Slider(value: timeoutBinding, in: 15...600, step: 15) {
          Text("Message timeout")
        }
        .labelsHidden()
        .accessibilityLabel("Message timeout")
        .accessibilityValue("\(Int(model.configuration.agentIntegration.messageTimeout)) seconds")
        .frame(width: 140)
        Text("\(Int(model.configuration.agentIntegration.messageTimeout)) sec")
          .font(DesignFont.mono(DesignFont.detail))
          .foregroundStyle(DesignPalette.ink2)
          .frame(width: 60, alignment: .trailing)
          .accessibilityHidden(true)
      }
      DesignRow(title: "Show on", detail: "Which displays show the status.") {
        DesignPopup(
          title: "Show on",
          selection: destinationBinding,
          choices: [
            DesignChoice("All displays", IdleScreenAgentDisplayDestination.all),
            DesignChoice("Primary display", IdleScreenAgentDisplayDestination.primary),
            DesignChoice("Focus display", IdleScreenAgentDisplayDestination.focus),
          ]
        )
      }
      DesignRow(
        title: "Position",
        detail:
          "Agents run along the bottom edge of the scene."
      ) {
        Text("Bottom")
          .foregroundStyle(DesignPalette.ink2)
      }
      DesignRow(
        title: "Show provider name",
        detail: "Label each status with Codex or Claude."
      ) {
        Toggle("Show provider name", isOn: showsProviderBinding)
          .labelsHidden()
          .accessibilityLabel("Show provider name")
          .toggleStyle(.designSwitch)
      }
      DesignRow(
        title: "Show message text",
        detail: "Include the short message when the agent sends one."
      ) {
        Toggle("Show message text", isOn: showsMessageBinding)
          .labelsHidden()
          .accessibilityLabel("Show message text")
          .toggleStyle(.designSwitch)
      }
      DesignRow(
        title: "Quiet hours",
        detail: "Hide agent status during a daily window."
      ) {
        Toggle("Quiet hours", isOn: quietHoursEnabledBinding)
          .labelsHidden()
          .accessibilityLabel("Quiet hours")
          .toggleStyle(.designSwitch)
      }
      if model.configuration.agentIntegration.quietHours != nil {
        DesignRow(title: "Quiet from") {
          DatePicker(
            "Quiet hours start",
            selection: quietStartBinding,
            displayedComponents: .hourAndMinute
          )
          .labelsHidden()
          .accessibilityLabel("Quiet hours start")
        }
        DesignRow(title: "Quiet until") {
          DatePicker(
            "Quiet hours end",
            selection: quietEndBinding,
            displayedComponents: .hourAndMinute
          )
          .labelsHidden()
          .accessibilityLabel("Quiet hours end")
        }
      }
    }
  }

  private var stateStyles: some View {
    DesignSection(
      eyebrow: "State styles",
      footer: "Choose how the saver shows each agent state."
    ) {
      stateStyleRow("Working", keyPath: \.working)
      stateStyleRow("Needs attention", keyPath: \.needsAttention)
      stateStyleRow("Done", keyPath: \.done)
      stateStyleRow("Error", keyPath: \.error)
    }
  }

  private var details: some View {
    DesignDetails(initiallyExpanded: detailsInitiallyExpanded) {
      DesignRow(title: "Active signal") {
        DesignValueText(activeSignalSummary)
      }
      DesignRow(title: "Ignored events") {
        DesignValueText(
          "Codex \(model.agentIgnoredEventCounts[.codex, default: 0]) · "
            + "Claude \(model.agentIgnoredEventCounts[.claude, default: 0])"
        )
      }
      if let status = model.agentIntegrationStatus {
        DesignRow(title: "Last result") {
          DesignValueText(status)
        }
      }
      DesignRow(title: "Codex events", detail: "How Codex events map to states.") {
        DesignValueText(providerMapping(.codex))
      }
      DesignRow(title: "Claude events", detail: "How Claude events map to states.") {
        DesignValueText(providerMapping(.claude))
      }
      hookConfigRow(.codex)
      hookConfigRow(.claude)
      DesignRow(title: "Clear signals", detail: "Remove every active agent status.") {
        Button("Clear all signals") {
          model.clearAgentSignals()
        }
        .buttonStyle(.designDestructive)
        .accessibilityLabel("Clear all signals")
        .accessibilityHint("Removes every active agent status")
      }
    }
  }

  @ViewBuilder
  private func hookConfigRow(_ provider: IdleScreenAgentProvider) -> some View {
    let name = providerName(provider)
    let isExpanded = expandedSnippet == provider
    DesignRow(
      title: "\(name) hook config",
      detail: "The entries IdleScreen adds to \(name)."
    ) {
      Button(isExpanded ? "Hide hook config" : "Show hook config") {
        expandedSnippet = isExpanded ? nil : provider
      }
      .buttonStyle(.designSecondary)
      .accessibilityLabel(isExpanded ? "Hide hook config" : "Show hook config")
      .accessibilityHint("\(name) hook entries")
    }
    if isExpanded {
      VStack(alignment: .leading, spacing: 8) {
        ScrollView(.horizontal) {
          Text(model.previewAgentHookConfiguration(for: provider))
            .font(DesignFont.mono(DesignFont.caption))
            .foregroundStyle(DesignPalette.ink)
            .textSelection(.enabled)
            .padding(10)
        }
        .background(DesignPalette.bg, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(name) hook config")
        Text(
          provider == .codex
            ? "Codex asks you to review and trust non-managed command hooks with /hooks after installation."
            : "Installation merges these entries into ~/.claude/settings.json and keeps your other settings."
        )
        .font(DesignFont.sans(DesignFont.caption))
        .foregroundStyle(DesignPalette.ink2)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, DesignMetrics.rowHorizontalPadding)
      .padding(.vertical, DesignMetrics.rowVerticalPadding)
    }
  }

  private var activeSignalSummary: String {
    guard let signal = model.activeAgentSignal else { return "No active signal" }
    return "\(providerName(signal.provider)) \(stateSentence(signal.state)). "
      + "Clears at \(signal.expiresAt.formatted(date: .omitted, time: .shortened))."
  }

  private func stateSentence(_ state: IdleScreenAgentSignalState) -> String {
    switch state {
    case .working: "is working"
    case .needsAttention: "needs attention"
    case .done: "is done"
    case .error: "hit an error"
    case .idle: "is idle"
    }
  }

  private func styleName(_ style: IdleScreenAgentVisualStyle) -> String {
    switch style {
    case .subtle: "Subtle"
    case .active: "Active"
    case .attention: "Attention"
    case .success: "Success"
    case .failure: "Failure"
    case .hidden: "Hidden"
    }
  }

  /// The shared renderer draws the same sprites the saver does. Real signals
  /// win; otherwise a Claude run and a Codex request stand in as a sample.
  private func previewConfiguration(at date: Date) -> IdleScreenRendererConfiguration {
    let live = model.agentPresentations(at: date)
    var configuration = model.configuration.rendererConfiguration(
      for: nil,
      agentPresentations: live.isEmpty ? samplePresentations : live,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    configuration.glyphScale = 0
    return configuration
  }

  private var samplePresentations: [IdleScreenAgentOverlayPresentation] {
    let integration = model.configuration.agentIntegration
    func sample(
      _ provider: IdleScreenAgentProvider,
      _ state: IdleScreenAgentSignalState,
      _ style: IdleScreenAgentVisualStyle,
      startedAt: Date
    ) -> IdleScreenAgentOverlayPresentation {
      IdleScreenAgentOverlayPresentation(
        provider: provider,
        state: state,
        providerLabel: nil,
        title: "",
        message: nil,
        style: style,
        position: integration.overlayPosition,
        accessibilityLabel: "",
        expiresAt: startedAt.addingTimeInterval(3_600),
        startedAt: startedAt
      )
    }
    return [
      sample(
        .claude, .working, integration.stateVisuals.working, startedAt: previewStartedAt),
      sample(
        .codex, .needsAttention, integration.stateVisuals.needsAttention,
        startedAt: previewStartedAt.addingTimeInterval(-30)),
    ].filter { $0.style != .hidden }
  }

  private func providerEnabledBinding(
    _ provider: IdleScreenAgentProvider
  ) -> Binding<Bool> {
    Binding(
      get: { model.configuration.agentIntegration.isEnabled(for: provider) },
      set: { enabled in
        model.updateAgentIntegration {
          if provider == .codex { $0.codexEnabled = enabled } else { $0.claudeEnabled = enabled }
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
          $0.quietHours =
            enabled
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
        let quiet =
          model.configuration.agentIntegration.quietHours
          ?? .init(startMinute: 1_320, endMinute: 420)
        return date(for: isStart ? quiet.startMinute : quiet.endMinute)
      },
      set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        model.updateAgentIntegration {
          let quiet =
            $0.quietHours
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
    DesignRow(title: label) {
      DesignPopup(
        title: "\(label) style",
        selection: Binding(
          get: { model.configuration.agentIntegration.stateVisuals[keyPath: keyPath] },
          set: { value in
            model.updateAgentIntegration { $0.stateVisuals[keyPath: keyPath] = value }
          }
        ),
        choices: IdleScreenAgentVisualStyle.allCases.map {
          DesignChoice(styleName($0), $0)
        }
      )
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
      "Start or prompt: working\nPermission: needs attention\nStop: done\nSession end: clears"
    case .claude:
      "Start or prompt: working\nPermission or notification: needs attention\nStop: done\nFailure: error\nSession end: clears"
    }
  }
}
