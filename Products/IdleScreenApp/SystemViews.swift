import AppKit
import IdleScreenCamera
import IdleScreenCore
import SwiftUI

/// The Status page: a verdict, three cards and a collapsed Technical details section. The wording and the decisions live in
/// `StatusSummary`; this view reads the model, hands over the facts and runs the action the summary names.
@MainActor
struct StatusView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(IdleScreenCompanionCameraClient.self) private var cameraClient
  @Environment(IdleScreenCompanionNavigation.self) private var navigation

  private let detailsInitiallyExpanded: Bool

  init(detailsInitiallyExpanded: Bool = false) {
    self.detailsInitiallyExpanded = detailsInitiallyExpanded
  }

  private enum CameraCheckLayer: Equatable {
    case client
    case service
    case identity
    case snapshot
    case authorization
    case control
  }

  private var inputs: StatusInputs {
    StatusInputs.live(model: model, cameraClient: cameraClient, setupCompleted: setupCompleted)
  }

  @AppStorage(IdleScreenSetupStore.completedKey) private var setupCompleted = false

  var body: some View {
    StatusPageContent(
      summary: StatusSummary(inputs),
      lastError: model.lastError.map(UserFacingIssue.message(for:)),
      isRefreshing: model.isRefreshing,
      detailsInitiallyExpanded: detailsInitiallyExpanded,
      perform: perform,
      refresh: { model.refresh() }
    ) {
      technicalRows
    }
    .onAppear {
      model.refresh()
      cameraClient.cameraDiagnosticsDidAppear()
    }
    .onDisappear {
      cameraClient.cameraDiagnosticsDidDisappear()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      model.refresh()
    }
  }

  private func perform(_ action: StatusAction) {
    switch action {
    case .registerSaver, .repairSaver: model.registerExtension()
    case .openScreenSaverSettings: model.openScreenSaverSettings()
    case .openSetup:
      navigation.setupSession.reopenFromCameraCard()
      navigation.destination = .studio
    case .allowCamera: cameraClient.performSetupCameraAction()
    case .openCameraPrivacy: cameraClient.openCameraPrivacySettings()
    case .fixCamera: cameraClient.performRecommendedRepair()
    case .openAgents: navigation.destination = .integrations
    }
  }

  /// Every raw row the old System page showed, unchanged, for when something needs a closer look.
  @ViewBuilder
  private var technicalRows: some View {
    // Screen saver
    checkRow(
      title: "Saver extension",
      value: model.isExtensionEmbedded ? "Ready" : "Missing",
      detail: model.embeddedExtensionVersion.map { "Version \($0)." }
        ?? "This app doesn't include the screen saver.",
      kind: model.isExtensionEmbedded ? .ok : .error
    )
    if let rawError = model.lastError, !rawError.isEmpty {
      checkRow(title: "Last error", value: "Reported", detail: rawError, kind: .attention)
    }
    checkRow(
      title: "Registration",
      value: registrationValue,
      detail: registrationDetail,
      kind: registrationKind,
      actionTitle: registrationRepairTitle,
      action: registrationRepairAction
    )
    checkRow(
      title: "Selected in macOS",
      value: selectionValue,
      detail: selectionDetail,
      kind: selectionKind,
      actionTitle: selectionRepairTitle,
      action: selectionRepairAction
    )
    checkRow(
      title: "macOS compatibility",
      value: model.compatibility.isCompatible ? "Compatible" : "Blocked",
      detail: compatibilityDetail,
      kind: model.compatibility.isCompatible ? .ok : .error
    )
    checkRow(
      title: "Shared data",
      value: model.hasSharedContainer ? "Connected" : "Unavailable",
      detail: model.hasSharedContainer
        ? "The app and the saver can share settings."
        : "IdleScreen's shared storage isn't available. Reinstall the app.",
      kind: model.hasSharedContainer ? .ok : .attention
    )
    // Camera
    checkRow(
      title: "Camera runtime",
      value: cameraClientValue,
      detail: cameraClientDetail,
      kind: cameraClientKind,
      actionTitle: cameraRepairTitle(for: .client),
      action: cameraRepairAction(for: .client)
    )
    checkRow(
      title: "Camera agent",
      value: cameraServiceValue,
      detail: cameraServiceDetail,
      kind: cameraServiceKind,
      actionTitle: cameraRepairTitle(for: .service),
      action: cameraRepairAction(for: .service)
    )
    checkRow(
      title: "Identity",
      value: identityValue,
      detail: identityDetail,
      kind: identityKind,
      actionTitle: cameraRepairTitle(for: .identity),
      action: cameraRepairAction(for: .identity)
    )
    checkRow(
      title: "Status check",
      value: liveSnapshotValue,
      detail: liveSnapshotDetail,
      kind: liveSnapshotKind,
      actionTitle: cameraRepairTitle(for: .snapshot),
      action: cameraRepairAction(for: .snapshot)
    )
    checkRow(
      title: "Camera access",
      value: authorizationValue,
      detail: authorizationDetail,
      kind: authorizationKind,
      actionTitle: cameraRepairTitle(for: .authorization),
      action: cameraRepairAction(for: .authorization)
    )
    checkRow(
      title: "Camera service",
      value: controlValue,
      detail: controlDetail,
      kind: controlKind,
      actionTitle: cameraRepairTitle(for: .control),
      action: cameraRepairAction(for: .control)
    )
    DesignRow(
      title: "Camera checks",
      detail: "Open camera privacy settings, or check the camera again."
    ) {
      cameraCheckButtons
    }
    detailRows
  }

  // MARK: Rows

  private func checkRow(
    title: String,
    value: String,
    detail: String,
    kind: DesignStatusKind,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) -> some View {
    DesignRow(title: title, detail: detail) {
      DesignStatus(kind: kind, text: value)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.designSecondary)
          .accessibilityLabel("\(actionTitle), \(title)")
      }
    }
  }

  private var cameraCheckButtons: some View {
    HStack(spacing: 8) {
      Button("Camera privacy…") {
        cameraClient.openCameraPrivacySettings()
      }
      .buttonStyle(.designSecondary)
      .accessibilityLabel("Camera privacy")
      .accessibilityHint("Opens camera privacy settings")

      Button {
        cameraClient.retryCameraDiagnostics()
      } label: {
        if cameraDiagnosticsAreLoading {
          Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
        } else {
          Label("Run checks", systemImage: "arrow.clockwise")
        }
      }
      .buttonStyle(.designSecondary)
      .accessibilityLabel(cameraDiagnosticsAreLoading ? "Checking" : "Run checks")
      .accessibilityHint("Runs the camera checks again")
      .disabled(
        cameraDiagnosticsAreLoading
          || cameraClient.cameraAgentRepairState.isInProgress
      )
    }
  }

  @ViewBuilder
  private var detailRows: some View {
    DesignRow(
      title: "Process reports",
      detail: model.processHealth.isEmpty
        ? "Signed builds publish app, saver, and camera agent reports here."
        : "Lifecycle reports shared by IdleScreen's processes."
    ) {
      DesignValueText(processReportSummary)
    }
    ForEach(model.processHealth, id: \.reportIdentifier) { report in
      ProcessHealthRow(
        report: report,
        isLive: model.isProcessReportLive(report)
      )
    }
    DesignRow(title: "Camera status snapshot") {
      DesignValueText(liveSnapshotRawDetail)
    }
    if let processDetail = cameraAgentProcessDetail {
      DesignRow(title: "Camera agent process") {
        DesignValueText(processDetail)
      }
    }
    DesignRow(title: "App") {
      DesignValueText(Bundle.main.bundleIdentifier ?? "Unknown")
    }
    DesignRow(title: "Saver extension") {
      DesignValueText(model.embeddedExtensionBundleIdentifier ?? "Missing")
    }
    DesignRow(title: "Shared storage") {
      DesignValueText(model.appGroupIdentifier ?? "No App Group identifier")
    }
    DesignRow(title: "Configuration revision") {
      DesignValueText(String(model.configuration.revision))
    }
    DesignRow(title: "Configuration schema") {
      DesignValueText(String(model.configuration.schemaVersion))
    }
  }

  private var registrationIsCurrent: Bool {
    model.registrationAssessment.isCurrentBuild
  }

  private var selectionIsCurrent: Bool {
    model.selection?.isSelectedEverywhere == true
  }

  private var registrationValue: String {
    switch model.registrationAssessment.location {
    case .currentBuild: "Registered"
    case .differentCopy: "Different copy"
    case .notRegistered: "Not registered"
    }
  }

  private var registrationDetail: String {
    switch model.registrationAssessment.location {
    case .currentBuild:
      "macOS is using this copy of IdleScreen."
    case .differentCopy:
      model.registrationAssessment.isSelectedBuild
        ? "This copy is selected, but older copies are also registered."
        : "macOS points to \(model.registration.path ?? "another copy")."
    case .notRegistered:
      "macOS doesn't have IdleScreen registered yet."
    }
  }

  private var registrationKind: DesignStatusKind {
    registrationIsCurrent ? .ok : .attention
  }

  private var registrationRepairTitle: String? {
    if registrationIsCurrent { return "Repair IdleScreen" }
    return model.registrationAssessment.location == .differentCopy
      ? "Repair IdleScreen"
      : "Set up IdleScreen"
  }

  private var registrationRepairAction: (() -> Void)? {
    guard registrationRepairTitle != nil else { return nil }
    return registrationIsCurrent
      ? { model.forceRepairExtension() }
      : { model.registerExtension() }
  }

  private var selectionValue: String {
    guard let selection = model.selection else { return "Unknown" }
    if selection.isSelectedEverywhere { return "IdleScreen" }
    if selection.isSelectedAnywhere { return "Some displays" }
    return "Another saver"
  }

  private var selectionDetail: String {
    guard let selection = model.selection else {
      return "macOS didn't say which saver is selected."
    }
    return selection.providers.isEmpty
      ? "No saver is recorded in the wallpaper store."
      : selection.providers.joined(separator: ", ")
  }

  private var selectionKind: DesignStatusKind {
    guard let selection = model.selection else { return .neutral }
    if selection.isSelectedEverywhere { return .ok }
    if selection.isSelectedAnywhere { return .attention }
    return .neutral
  }

  private var selectionRepairTitle: String? {
    selectionIsCurrent ? nil : "Screen Saver Settings…"
  }

  private var selectionRepairAction: (() -> Void)? {
    guard selectionRepairTitle != nil else { return nil }
    return { model.openScreenSaverSettings() }
  }

  private var compatibilityDetail: String {
    let missingSymbols =
      model.compatibility.missingClassNames
      + model.compatibility.missingSelectorNames
    return missingSymbols.isEmpty
      ? "This version of macOS has what IdleScreen needs."
      : missingSymbols.joined(separator: ", ")
  }

  private var cameraDiagnosticsAreLoading: Bool {
    if case .loading = cameraClient.cameraAgentDiagnosticState { return true }
    return false
  }

  // MARK: Camera checks

  private var cameraClientValue: String {
    guard let status = cameraClient.bootstrapStatus else { return "Checking" }
    return switch status {
    case .ready: "Ready"
    case .missingConfiguration: "Configuration missing"
    case .invalidConfiguration: "Configuration invalid"
    case .appGroupContainerUnavailable: "Shared storage unavailable"
    }
  }

  private var cameraClientDetail: String {
    guard let status = cameraClient.bootstrapStatus else {
      return "The camera runtime is still starting."
    }
    return switch status {
    case .ready: "The camera runtime is ready."
    case .missingConfiguration: "Camera configuration is missing."
    case .invalidConfiguration: "Camera configuration is invalid."
    case .appGroupContainerUnavailable:
      "IdleScreen's shared storage isn't available. Reinstall the app."
    }
  }

  private var cameraClientKind: DesignStatusKind {
    guard let status = cameraClient.bootstrapStatus else { return .pending }
    return status == .ready ? .ok : .error
  }

  private var cameraServiceValue: String {
    switch cameraClient.readinessSnapshot.serviceRegistration {
    case .unknown: "Not checked"
    case .notRegistered: "Not enabled"
    case .enabled: "Enabled"
    case .requiresApproval: "Needs approval"
    case .notFound: "Missing"
    case .failed: "Failed"
    }
  }

  private var cameraServiceDetail: String {
    switch cameraClient.readinessSnapshot.serviceRegistration {
    case .unknown: "The camera agent's status hasn't been read yet."
    case .notRegistered: "The camera agent is turned off."
    case .enabled: "The camera agent is turned on for your account."
    case .requiresApproval: "Allow the camera agent in Login Items."
    case .notFound: "This app doesn't include the camera agent."
    case .failed: "macOS couldn't check the camera agent."
    }
  }

  private var cameraServiceKind: DesignStatusKind {
    switch cameraClient.readinessSnapshot.serviceRegistration {
    case .enabled: .ok
    case .unknown: .pending
    case .notRegistered, .requiresApproval: .attention
    case .notFound, .failed: .error
    }
  }

  private var identityValue: String {
    switch cameraClient.cameraAgentRepairState {
    case .replacing: return "Replacing"
    case .verifying: return "Verifying"
    case .verified(let bundleVersion, _, _)
    where cameraClient.readinessSnapshot.identity == .current:
      return "Current · build \(bundleVersion)"
    case .idle, .verified, .failed: break
    }
    return switch cameraClient.readinessSnapshot.identity {
    case .unknown: "Not verified"
    case .absent: "Absent"
    case .stale: "Out of date"
    case .mismatched: "Mismatch"
    case .current: "Current"
    }
  }

  private var identityDetail: String {
    switch cameraClient.cameraAgentRepairState {
    case .replacing:
      return "Replacing the older camera agent with this app's copy."
    case .verifying:
      return "Checking the camera agent's signature and process."
    case .verified(_, let sourceAppPath, _)
    where cameraClient.readinessSnapshot.identity == .current:
      return "Running from \(sourceAppPath)."
    case .failed(let message):
      return "Repair failed: \(message)"
    case .idle, .verified:
      break
    }
    return switch cameraClient.readinessSnapshot.identity {
    case .unknown: "Waiting for the camera service to finish starting."
    case .absent: "The camera agent isn't installed or isn't running."
    case .stale: "The installed copy is out of date. Repair to update it."
    case .mismatched: "The camera agent's signature didn't check out."
    case .current: "The installed camera agent matches this app."
    }
  }

  private var identityKind: DesignStatusKind {
    switch cameraClient.readinessSnapshot.identity {
    case .current: .ok
    case .mismatched: .error
    case .absent, .stale: .attention
    case .unknown: .pending
    }
  }

  private var cameraAgentProcessDetail: String? {
    guard
      case .verified(let bundleVersion, let sourceAppPath, let processIdentifier) =
        cameraClient.cameraAgentRepairState
    else { return nil }
    return "build \(bundleVersion) · PID \(processIdentifier) · \(sourceAppPath)"
  }

  private var liveSnapshotValue: String {
    switch cameraClient.readinessSnapshot.liveSnapshot {
    case .unknown: "Not checked"
    case .unavailable: "Unavailable"
    case .rejected: "Rejected"
    case .accepted: "Passed"
    }
  }

  private var liveSnapshotDetail: String {
    switch cameraClient.cameraAgentDiagnosticState {
    case .notRequested: return "No status check has been requested."
    case .loading: return "Asking the camera agent for its status."
    case .live: return "The camera agent reported its status."
    case .unavailable(.serviceRegistration): return "The camera agent isn't enabled."
    case .unavailable(.clientRuntime): return "The camera runtime isn't available."
    case .unavailable(.control): return "IdleScreen couldn't reach the camera agent."
    case .unavailable(.rejected): return "The camera agent's reply was rejected."
    }
  }

  /// The raw snapshot line for Details: capture state, leases and the stream epoch.
  private var liveSnapshotRawDetail: String {
    guard case .live(let snapshot) = cameraClient.cameraAgentDiagnosticState else {
      return "No snapshot yet"
    }
    let capture = snapshot.captureActive ? "capture active" : "capture idle"
    let leases =
      snapshot.activeLeaseCount == 1
      ? "1 active lease"
      : "\(snapshot.activeLeaseCount) active leases"
    return
      "\(snapshot.summary) · \(capture) · \(leases) · stream epoch \(snapshot.producerStreamEpoch)"
  }

  private var liveSnapshotKind: DesignStatusKind {
    switch cameraClient.readinessSnapshot.liveSnapshot {
    case .accepted: .ok
    case .rejected: .error
    case .unavailable: .attention
    case .unknown: .pending
    }
  }

  private var authorizationValue: String {
    switch cameraClient.readinessSnapshot.authorization {
    case .unknown: "Not checked"
    case .observed(.notDetermined): "Not requested"
    case .observed(.authorized): "Authorized"
    case .observed(.denied): "Denied"
    case .observed(.restricted): "Restricted"
    }
  }

  private var authorizationDetail: String {
    switch cameraClient.readinessSnapshot.authorization {
    case .unknown: "IdleScreen checks without prompting while this page is open."
    case .observed(.notDetermined): "IdleScreen asks for camera access only when you choose to."
    case .observed(.authorized): "The current camera agent reports authorization."
    case .observed(.denied): "Camera access is off in Privacy & Security."
    case .observed(.restricted): "A system policy restricts camera access."
    }
  }

  private var authorizationKind: DesignStatusKind {
    cameraClient.readinessSnapshot.authorization == .observed(.authorized)
      ? .ok
      : .attention
  }

  private var controlValue: String {
    switch cameraClient.controlReachability {
    case .unknown: "Not connected"
    case .reachable: "Responding"
    case .unreachable: "Unavailable"
    case .timedOut: "Timed out"
    }
  }

  private var controlDetail: String {
    switch cameraClient.controlReachability {
    case .unknown: "No status request has been sent yet."
    case .reachable: "The camera service is responding."
    case .unreachable: "IdleScreen couldn't reach the camera service."
    case .timedOut: "The camera service took too long to respond."
    }
  }

  private var controlKind: DesignStatusKind {
    cameraClient.controlReachability == .reachable ? .ok : .attention
  }

  private func cameraRepairTitle(for layer: CameraCheckLayer) -> String? {
    guard !cameraDiagnosticsAreLoading,
      !cameraClient.cameraAgentRepairState.isInProgress
    else {
      return nil
    }
    if layer == .snapshot,
      cameraClient.readinessSnapshot.identity == .current,
      cameraClient.readinessSnapshot.liveSnapshot != .accepted
    {
      return "Retry"
    }
    guard repairBelongs(to: layer) else { return nil }
    if layer == .identity && cameraClient.isCameraAgentReplacementRecommended {
      return "Replace"
    }
    return switch cameraClient.recommendedRepair {
    case .refresh(.clientRuntime): "Retry"
    case .registerAgent: "Enable"
    case .requestCameraAuthorization: "Allow"
    case .refresh(.serviceRegistration): "Refresh"
    case .refresh(.identity): "Verify"
    case .refresh(.liveSnapshot): "Retry"
    case .refresh(.authorization): "Check"
    case .refresh(.control): "Retry"
    case .refresh(.frameReadiness): nil
    case .openRepairSurface(.backgroundItemsSettings): "Open Login Items"
    case .openRepairSurface(.cameraPrivacySettings): "Open Privacy"
    case .openRepairSurface(.cameraAgentDiagnostics): "Repair"
    case nil: nil
    }
  }

  private func cameraRepairAction(for layer: CameraCheckLayer) -> (() -> Void)? {
    guard cameraRepairTitle(for: layer) != nil else { return nil }
    if layer == .snapshot,
      cameraClient.readinessSnapshot.identity == .current,
      cameraClient.readinessSnapshot.liveSnapshot != .accepted
    {
      return { cameraClient.retryCameraDiagnostics() }
    }
    return { cameraClient.performRecommendedRepair() }
  }

  private func repairBelongs(to layer: CameraCheckLayer) -> Bool {
    if layer == .identity && cameraClient.isCameraAgentReplacementRecommended {
      return true
    }
    return switch cameraClient.recommendedRepair {
    case .refresh(.clientRuntime): layer == .client
    case .registerAgent,
      .refresh(.serviceRegistration),
      .openRepairSurface(.backgroundItemsSettings):
      layer == .service
    case .refresh(.identity): layer == .identity
    case .openRepairSurface(.cameraAgentDiagnostics):
      cameraClient.readinessSnapshot.identity == .current
        ? layer == .snapshot
        : layer == .identity
    case .refresh(.liveSnapshot): layer == .snapshot
    case .requestCameraAuthorization,
      .refresh(.authorization),
      .openRepairSurface(.cameraPrivacySettings):
      layer == .authorization
    case .refresh(.control): layer == .control
    case .refresh(.frameReadiness), nil: false
    }
  }

  private var processReportSummary: String {
    guard !model.processHealth.isEmpty else { return "No reports yet" }
    let liveCount = model.processHealth.filter(model.isProcessReportLive).count
    let newest = model.processHealth.map(\.updatedAt).max()
    let timestamp = newest?.formatted(date: .omitted, time: .standard) ?? ""
    return "\(liveCount) live · \(model.processHealth.count) reports · \(timestamp)"
  }
}

private struct ProcessHealthRow: View {
  let report: IdleScreenProcessHealth
  let isLive: Bool

  var body: some View {
    DesignRow(title: processName, detail: identifierDetail) {
      VStack(alignment: .trailing, spacing: 3) {
        DesignStatus(kind: statusKind, text: statusText)
        if let revision = report.configurationRevision {
          DesignValueText("Config r\(revision)")
        }
        DesignValueText(report.updatedAt.formatted(date: .omitted, time: .standard))
      }
    }
  }

  private var statusKind: DesignStatusKind {
    guard isLive else { return .neutral }
    return report.issue == nil ? .ok : .attention
  }

  private var statusText: String {
    guard isLive else { return "Exited" }
    return switch report.lifecycle {
    case .detached: "Detached"
    case .attached: "Ready"
    case .animating: "Running"
    }
  }

  private var identifierDetail: String {
    [report.build.bundleIdentifier, executionDetail].compactMap { $0 }.joined(separator: "\n")
  }

  private var processName: String {
    switch report.process {
    case .companionApp: "Companion app"
    case .screenSaverExtension: "Screen saver extension"
    case .cameraAgent: "Camera agent"
    }
  }

  private var executionDetail: String? {
    guard let processIdentifier = report.processIdentifier else { return nil }
    var components = ["PID \(processIdentifier)"]
    if let displayIdentifier = report.displayIdentifier {
      components.append("Display \(displayIdentifier)")
    }
    if let instanceIdentifier = report.instanceIdentifier {
      components.append("View \(instanceIdentifier.prefix(8))")
    }
    return components.joined(separator: " · ")
  }
}

extension StatusInputs {
  /// The live facts for the Status page and for the verdict pill in Studio, so the two cannot disagree.
  @MainActor
  static func live(
    model: IdleScreenAppModel, cameraClient: IdleScreenCompanionCameraClient, setupCompleted: Bool
  ) -> StatusInputs {
    StatusInputs(
      saverStatusKnown: model.hasFreshSaverStatus,
      extensionEmbedded: model.isExtensionEmbedded,
      macOSCompatible: model.compatibility.isCompatible,
      registrationLocation: model.registrationAssessment.location,
      selectedEverywhere: model.selection?.isSelectedEverywhere == true,
      sharedContainerAvailable: StatusSummary.sharedContainerAvailable(
        hasSharedContainer: model.hasSharedContainer, bootstrap: cameraClient.bootstrapStatus),
      setupCompleted: setupCompleted,
      cameraInUse: model.configuration.source == .camera,
      cameraAuthorization: cameraClient.readinessSnapshot.authorization,
      cameraHasFault: StatusCameraFault.hasFault(
        snapshot: cameraClient.readinessSnapshot, bootstrap: cameraClient.bootstrapStatus,
        control: cameraClient.controlReachability),
      codexHooksInstalled: model.codexHooksInstalled,
      claudeHooksInstalled: model.claudeHooksInstalled)
  }
}
