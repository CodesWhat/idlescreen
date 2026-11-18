import Foundation
import IdleScreenAgent
import IdleScreenCore
import Observation

/// Owns the agent integration: the signal inbox monitor, the Claude and Codex
/// hook install state, and the status line the Integrations view shows. The
/// app model owns the configuration and hands it in through `configurationProvider`.
@MainActor
@Observable
final class AgentIntegrationController {
  private struct AgentSignalRefreshRequest: Sendable {
    let generation: UInt64
    let date: Date
  }

  private enum AgentSignalLoadOutcome: Sendable {
    case loaded(
      request: AgentSignalRefreshRequest,
      inbox: IdleScreenAgentSignalInbox
    )
    case failed(request: AgentSignalRefreshRequest, message: String)
  }

  @ObservationIgnored private let appGroupIdentifier: String?
  @ObservationIgnored private let codexHookSettingsURL: URL
  @ObservationIgnored private let claudeHookSettingsURL: URL
  @ObservationIgnored private let agentControlExecutableURL: URL
  @ObservationIgnored private let clock: @Sendable () -> Date
  /// Wired by the app model right after its own init, since the closure
  /// captures the model.
  @ObservationIgnored var configurationProvider: @MainActor () -> IdleScreenConfiguration = {
    .default
  }
  @ObservationIgnored private let agentSignalStore: IdleScreenAgentSignalStore?
  @ObservationIgnored private let agentSignalLoader:
    @Sendable (
      IdleScreenAgentSignalStore,
      Date
    ) throws -> IdleScreenAgentSignalInbox
  private var agentSignalMonitor: IdleScreenAgentSignalMonitor?
  private var agentSignalRefreshGeneration: UInt64 = 0
  private var agentSignalRefreshInFlight = false
  private var pendingAgentSignalRefresh: AgentSignalRefreshRequest?

  var activeAgentSignal: IdleScreenAgentSignal?
  var activeAgentSignals: [IdleScreenAgentSignal] = []
  var agentIgnoredEventCounts: [IdleScreenAgentProvider: UInt64] = [:]
  var codexHooksInstalled = false
  var claudeHooksInstalled = false
  var status: String?

  init(
    appGroupIdentifier: String?,
    agentSignalStore: IdleScreenAgentSignalStore?,
    codexHookSettingsURL: URL,
    claudeHookSettingsURL: URL,
    agentControlExecutableURL: URL,
    clock: @escaping @Sendable () -> Date,
    loadAgentSignals:
      @escaping @Sendable (
        IdleScreenAgentSignalStore,
        Date
      ) throws -> IdleScreenAgentSignalInbox
  ) {
    self.appGroupIdentifier = appGroupIdentifier
    self.agentSignalStore = agentSignalStore
    self.codexHookSettingsURL = codexHookSettingsURL
    self.claudeHookSettingsURL = claudeHookSettingsURL
    self.agentControlExecutableURL = agentControlExecutableURL
    self.clock = clock
    self.agentSignalLoader = loadAgentSignals
  }

  /// Starts polling and reads the initial hook install state.
  func start() {
    if agentSignalStore != nil {
      agentSignalMonitor = IdleScreenAgentSignalMonitor()
      refreshAgentSignals()
    }
    refreshAgentHookInstallationStatus()
  }

  private var agentIntegrationConfiguration: IdleScreenAgentIntegrationConfiguration {
    configurationProvider().agentIntegration
  }

  func refreshAgentSignals(at date: Date? = nil) {
    guard let monitor = agentSignalMonitor,
      let agentSignalStore
    else {
      activeAgentSignal = nil
      activeAgentSignals = []
      agentIgnoredEventCounts = [:]
      return
    }
    let date = date ?? clock()
    guard monitor.canPoll(at: date) else { return }

    agentSignalRefreshGeneration &+= 1
    let request = AgentSignalRefreshRequest(
      generation: agentSignalRefreshGeneration,
      date: date
    )
    guard !agentSignalRefreshInFlight else {
      pendingAgentSignalRefresh = request
      return
    }
    beginAgentSignalRefresh(
      request,
      store: agentSignalStore
    )
  }

  func agentPresentation(at date: Date? = nil) -> IdleScreenAgentOverlayPresentation? {
    guard let activeAgentSignal else { return nil }
    let date = date ?? clock()
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    return IdleScreenAgentPresentationPolicy.presentation(
      for: activeAgentSignal,
      configuration: agentIntegrationConfiguration,
      at: date,
      minuteOfDay: minute
    )
  }

  /// Presentations for every live agent, after the same policy gates the
  /// saver applies. They become sprites in the preview scene.
  func agentPresentations(at date: Date? = nil) -> [IdleScreenAgentOverlayPresentation] {
    let date = date ?? clock()
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    return activeAgentSignals.compactMap {
      IdleScreenAgentPresentationPolicy.presentation(
        for: $0,
        configuration: agentIntegrationConfiguration,
        at: date,
        minuteOfDay: minute
      )
    }
  }

  func configurationApplyingActiveAgentSignal(
    at date: Date? = nil
  ) -> IdleScreenConfiguration {
    let first = agentPresentations(at: date).first
    let configuration = configurationProvider()
    guard first != nil else { return configuration }
    return IdleScreenAgentPresentationPolicy.configuration(
      configuration,
      applyingTemporaryLookFrom: IdleScreenAgentPresentationPolicy.signal(
        behind: first, in: activeAgentSignals)
    )
  }

  func previewAgentHookConfiguration(for provider: IdleScreenAgentProvider) -> String {
    guard let appGroupIdentifier else { return "Signed App Group access is unavailable." }
    do {
      return try IdleScreenAgentHookConfigurationManager.preview(
        provider: provider,
        executableURL: agentControlExecutableURL,
        appGroupIdentifier: appGroupIdentifier
      )
    } catch {
      return "Unable to prepare hook preview: \(error.localizedDescription)"
    }
  }

  func installAgentHooks(for provider: IdleScreenAgentProvider) {
    guard let manager = agentHookManager(for: provider) else {
      status =
        "Hook installation unavailable until the app is signed for its App Group."
      return
    }
    do {
      try manager.install()
      status =
        provider == .codex
        ? "Codex hooks installed. Review and trust them with /hooks in Codex."
        : "Claude hooks installed."
      refreshAgentHookInstallationStatus()
    } catch {
      status = "Hook installation failed: \(error.localizedDescription)"
    }
  }

  func uninstallAgentHooks(for provider: IdleScreenAgentProvider) {
    guard let manager = agentHookManager(for: provider) else {
      status = "Hook removal unavailable until the app is signed for its App Group."
      return
    }
    do {
      try manager.uninstall()
      status =
        provider == .codex
        ? "Codex hooks removed."
        : "Claude hooks removed."
      refreshAgentHookInstallationStatus()
    } catch {
      status = "Hook removal failed: \(error.localizedDescription)"
    }
  }

  func refreshAgentHookInstallationStatus() {
    var failures: [String] = []
    do {
      codexHooksInstalled = try agentHookManager(for: .codex)?.isInstalled() ?? false
    } catch {
      codexHooksInstalled = false
      failures.append("Codex hook status unavailable: \(error.localizedDescription)")
    }
    do {
      claudeHooksInstalled = try agentHookManager(for: .claude)?.isInstalled() ?? false
    } catch {
      claudeHooksInstalled = false
      failures.append("Claude hook status unavailable: \(error.localizedDescription)")
    }
    if !failures.isEmpty {
      status = failures.joined(separator: " ")
    } else if status?.contains("hook status unavailable:") == true {
      status = nil
    }
  }

  func testAgentSignal(for provider: IdleScreenAgentProvider, at date: Date? = nil) {
    guard agentIntegrationConfiguration.isEnabled(for: provider),
      let agentSignalStore
    else {
      status = "Enable this provider before sending a test."
      return
    }
    let date = date ?? clock()
    resetAgentSignalMonitor()
    do {
      let nonce = UUID().uuidString.lowercased()
      let signal = try IdleScreenAgentSignal.validated(
        provider: provider,
        sessionID: "idlescreen-test",
        eventID: "test-\(nonce)",
        state: .needsAttention,
        title: provider == .codex ? "Codex needs attention" : "Claude needs attention",
        message: "This is an IdleScreen integration test.",
        temporaryLookID: nil,
        priority: 50,
        createdAt: date,
        expiresAt: date.addingTimeInterval(
          agentIntegrationConfiguration.messageTimeout
        ),
        acknowledgedAt: nil,
        nonce: nonce,
        validatedAt: date
      )
      _ = try agentSignalStore.apply(.set(signal), at: date)
      refreshAgentSignals(at: date)
      status = "Test signal sent."
    } catch {
      status = "Test signal failed: \(error.localizedDescription)"
    }
  }

  func clearAgentSignals(at date: Date? = nil) {
    guard let agentSignalStore else { return }
    let date = date ?? clock()
    resetAgentSignalMonitor()
    do {
      _ = try agentSignalStore.apply(.clearAll, at: date)
      activeAgentSignal = nil
      activeAgentSignals = []
      refreshAgentSignals(at: date)
      status = "All agent signals cleared."
    } catch {
      status = "Clear failed: \(error.localizedDescription)"
    }
  }

  private func agentHookManager(
    for provider: IdleScreenAgentProvider
  ) -> IdleScreenAgentHookConfigurationManager? {
    guard let appGroupIdentifier else { return nil }
    let settingsURL =
      switch provider {
      case .codex: codexHookSettingsURL
      case .claude: claudeHookSettingsURL
      }
    return IdleScreenAgentHookConfigurationManager(
      provider: provider,
      settingsURL: settingsURL,
      executableURL: agentControlExecutableURL,
      appGroupIdentifier: appGroupIdentifier
    )
  }

  private func beginAgentSignalRefresh(
    _ request: AgentSignalRefreshRequest,
    store: IdleScreenAgentSignalStore
  ) {
    agentSignalRefreshInFlight = true
    let loader = agentSignalLoader
    Task {
      let outcome = await Task.detached {
        do {
          return AgentSignalLoadOutcome.loaded(
            request: request,
            inbox: try loader(store, request.date)
          )
        } catch {
          return AgentSignalLoadOutcome.failed(
            request: request,
            message: error.localizedDescription
          )
        }
      }.value
      finishAgentSignalRefresh(outcome)
    }
  }

  private func finishAgentSignalRefresh(_ outcome: AgentSignalLoadOutcome) {
    let request =
      switch outcome {
      case .loaded(let request, _), .failed(let request, _): request
      }
    agentSignalRefreshInFlight = false

    if request.generation == agentSignalRefreshGeneration {
      switch outcome {
      case .loaded(_, let inbox):
        if var monitor = agentSignalMonitor {
          let change = monitor.consume(inbox, at: request.date)
          agentSignalMonitor = monitor
          if let change {
            activeAgentSignal = change.signal
            activeAgentSignals = change.signals
            agentIgnoredEventCounts = change.ignoredEventCounts
          }
        }
        if status?.hasPrefix(
          "Agent signal inbox unavailable:"
        ) == true {
          status = nil
        }
      case .failed(_, let message):
        activeAgentSignal = nil
        activeAgentSignals = []
        status = "Agent signal inbox unavailable: \(message)"
      }
    }

    guard let pending = pendingAgentSignalRefresh,
      let agentSignalStore
    else { return }
    pendingAgentSignalRefresh = nil
    beginAgentSignalRefresh(pending, store: agentSignalStore)
  }

  private func resetAgentSignalMonitor() {
    agentSignalRefreshGeneration &+= 1
    pendingAgentSignalRefresh = nil
    agentSignalMonitor =
      agentSignalStore == nil
      ? nil
      : IdleScreenAgentSignalMonitor()
  }
}
