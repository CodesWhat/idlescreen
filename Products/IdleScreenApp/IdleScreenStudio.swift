// IdleScreen companion workbench.
// macOS 26+, SwiftUI.

import Foundation
import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import MetalKit
import SwiftUI

#if !IDLESCREEN_APP_COMPILE_GATE
  @main
#endif
struct IdleScreenApp: App {
  @NSApplicationDelegateAdaptor(IdleScreenAppDelegate.self) private var appDelegate
  @State private var model = IdleScreenAppModel.shared

  var body: some Scene {
    MenuBarExtra {
      IdleScreenMenuBar()
        .environment(model)
    } label: {
      let glyph = appDelegate.menuBarGlyph
      let assetName = glyph.assetName
      Image(nsImage: glyph.image)
        .accessibilityLabel(glyph.state.accessibilityDescription)
        .id(assetName)
    }
    .menuBarExtraStyle(.menu)
  }
}

enum Destination: String, CaseIterable, Identifiable {
  case studio = "Scene"
  case aquarium = "Aquarium"
  case displays = "Displays"
  case integrations = "Agents"
  case status = "Settings"

  static let primaryCases: [Destination] = [.studio, .aquarium, .displays, .integrations, .status]

  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .studio: "play.rectangle"
    case .aquarium: "fish"
    case .displays: "rectangle.3.group"
    case .integrations: "point.3.connected.trianglepath.dotted"
    case .status: "waveform.path.ecg"
    }
  }
}

@MainActor
@Observable
final class IdleScreenCompanionNavigation {
  var destination: Destination = .studio
  /// Setup progress that survives navigating away and back: the camera skip, the one-time upgrade auto-skip, the last fresh
  /// macOS answer, and "Set up later".
  var setupSession = SetupSession()
  /// Set by "Set up later". Studio shows instead of the setup flow until setup is reopened.
  var isSetupDeferred: Bool {
    get { setupSession.isDeferred }
    set { setupSession.isDeferred = newValue }
  }
  private let preferences: UserDefaults?

  private enum Preference {
    static let savedLooks = "workbench.showsSavedLooks"
    static let inspector = "workbench.inspectorVisible"
    static let sceneInspector = "workbench.sceneInspectorVisible"
    static let display = "workbench.previewDisplay"
  }

  init(preferences: UserDefaults? = nil) {
    self.preferences = preferences
    showsSavedLooks = preferences?.bool(forKey: Preference.savedLooks) ?? false
    isInspectorVisible = preferences?.object(forKey: Preference.inspector) as? Bool ?? true
    isSceneInspectorVisible = preferences?.bool(forKey: Preference.sceneInspector) ?? false
    previewDisplayIdentifier = preferences?.string(forKey: Preference.display).map {
      .init(rawValue: $0)
    }
  }

  var showsSavedLooks = false {
    didSet { preferences?.set(showsSavedLooks, forKey: Preference.savedLooks) }
  }
  var isInspectorVisible = true {
    didSet { preferences?.set(isInspectorVisible, forKey: Preference.inspector) }
  }
  var isSceneInspectorVisible = false {
    didSet { preferences?.set(isSceneInspectorVisible, forKey: Preference.sceneInspector) }
  }

  var currentInspectorVisible: Bool {
    destination == .studio ? isSceneInspectorVisible : isInspectorVisible
  }
  var displayAspectRatio: CGFloat = 16 / 9
  var previewDisplayIdentifier: DisplayTopology.PersistentDisplayIdentifier? {
    didSet { preferences?.set(previewDisplayIdentifier?.rawValue, forKey: Preference.display) }
  }

  func showCameraDiagnostics() {
    destination = .status
  }
}

struct ContentView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(IdleScreenCompanionCameraClient.self) private var cameraClient
  @Environment(IdleScreenCompanionNavigation.self) private var navigation
  @Environment(DisplaySceneCoordinator.self) private var displayCoordinator
  @AppStorage(IdleScreenSetupStore.completedKey) private var setupCompleted = false

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      Group {
        switch navigation.destination {
        case .studio:
          if !showsSetup {
            StudioView()
          } else {
            SetupFlowView(
              onFinish: { setupCompleted = true },
              onLater: { navigation.setupSession.deferSetup() }
            )
          }
        case .aquarium: IdleScreenAquariumView()
        case .displays: DisplaysView()
        case .integrations: IntegrationsView()
        case .status: StatusView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      HStack {
        Image(systemName: statusSummary.pillKind.symbol)
          .foregroundStyle(statusSummary.pillKind.color)
        Text(statusSummary.pillLabel)
        Spacer()
        if showsSetupBanner && !showsSetup {
          Button("Continue setup") { navigation.setupSession.continueSetup() }
            .buttonStyle(.plain)
            .foregroundStyle(DesignPalette.accentMark)
            .accessibilityHint("Returns to the setup steps.")
        } else {
          Text("Changes save automatically")
        }
      }
      .font(DesignFont.sans(DesignFont.eyebrow))
      .foregroundStyle(DesignPalette.ink2)
      .padding(.horizontal, 20)
      .frame(height: 22)
    }
    .background(DesignPalette.bg)
    .background {
      ForEach(Array(Destination.primaryCases.enumerated()), id: \.element) { index, destination in
        Button(destination.rawValue) { navigation.destination = destination }
          .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
          .hidden().accessibilityHidden(true)
      }
    }
    .windowAppearance(Self.windowAppearance(for: navigation.destination, showsSetup: showsSetup))
    .ignoresSafeArea()
    .onChange(of: model.configuration.revision, initial: true) {
      _, _ in updateDisplayPresentation()
    }
    .onChange(of: IdleScreenAquariumController.shared.library.revision) { _, _ in
      updateDisplayPresentation()
    }
    .onChange(of: displayCoordinator.latestSnapshot?.generation, initial: true) { _, _ in
      synchronizePreviewDisplay()
    }
    .onChange(of: navigation.previewDisplayIdentifier) { _, _ in
      synchronizePreviewDisplay()
    }
    .task {
      while !Task.isCancelled {
        model.refreshAgentSignals()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func synchronizePreviewDisplay() {
    guard let topology = displayCoordinator.latestSnapshot?.topology else { return }
    let displays = topology.displays.filter { $0.mirrorTargetIdentifier == nil }
    let selected =
      displays.first { $0.persistentIdentifier == navigation.previewDisplayIdentifier }
      ?? displays.first(where: \.isPrimary) ?? displays.first
    navigation.previewDisplayIdentifier = selected?.persistentIdentifier
    if let selected {
      navigation.displayAspectRatio = selected.logicalFrame.width / selected.logicalFrame.height
    }
  }

  private func updateDisplayPresentation() {
    let library = IdleScreenAquariumController.shared.library
    _ = displayCoordinator.update(
      settings: IdleScreenAquariumProduct.displaySettings(
        configuration: model.configuration, library: library),
      configurationRevision: IdleScreenAquariumProduct.presentationRevision(
        configuration: model.configuration, library: library))
  }

  private var showsSetup: Bool { !(setupCompleted || navigation.isSetupDeferred) }

  static func windowAppearance(for destination: Destination, showsSetup: Bool = false)
    -> NSAppearance?
  {
    nil
  }

  private var toolbar: some View {
    @Bindable var navigation = navigation
    return ZStack {
      HStack {
        Text("IdleScreen").font(DesignFont.display(24))
          .padding(.leading, 82)
        Spacer()
        Button {
          model.startScreenSaver()
        } label: {
          Label("Start IdleScreen", systemImage: "play.fill")
        }
        .buttonStyle(.designPrimary)
        .disabled(model.isRegistering || model.isStartingScreenSaver || !model.isExtensionEmbedded)
        Button {
          if navigation.destination == .studio {
            navigation.isSceneInspectorVisible.toggle()
          } else {
            navigation.isInspectorVisible.toggle()
          }
        } label: {
          Image(systemName: "sidebar.trailing")
        }
        .buttonStyle(.designSecondary)
        .keyboardShortcut("i", modifiers: [.command, .option])
        .accessibilityLabel("Inspector")
        .accessibilityValue(navigation.currentInspectorVisible ? "Shown" : "Hidden")
        .help("Show or hide the inspector")
        .disabled(showsSetup && navigation.destination == .studio)
      }
      Picker("App section", selection: $navigation.destination) {
        ForEach(Destination.primaryCases) { destination in
          Text(destination.rawValue).tag(destination)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 300)
      .accessibilityLabel("App section")
    }
    .padding(.horizontal, 18)
    .frame(height: 48)
    .background(DesignPalette.surface)
  }

  /// The required steps as macOS last reported them, ignoring a refresh that is in flight or failed.
  private var showsSetupBanner: Bool {
    let live = SetupInputs(
      registrationCurrent: model.registrationAssessment.isCurrentBuild,
      selectedEverywhere: model.selection?.isSelectedEverywhere == true,
      cameraAccess: .unknown,
      cameraSkipped: false
    )
    let inputs = SetupInputs.settled(
      live: live, lastFresh: navigation.setupSession.lastFreshInputs,
      isFresh: model.hasFreshSaverStatus)
    return SetupGate.showsStudioBanner(
      setupCompleted: setupCompleted,
      requiredStepsDone: SetupProgress(inputs).requiredStepsDone)
  }

  private var statusSummary: StatusSummary {
    StatusSummary(
      StatusInputs.live(model: model, cameraClient: cameraClient, setupCompleted: setupCompleted))
  }
}

struct StudioView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(IdleScreenCompanionCameraClient.self) private var cameraClient
  @Environment(IdleScreenCompanionNavigation.self) private var navigation
  @Environment(DisplaySceneCoordinator.self) private var displayCoordinator
  @State private var isSaverChooserExpanded = true
  @State private var isPixelAdvancedExpanded = false
  @State private var isLoupeEnabled = false
  @State private var loupePointerLocation: CGPoint?
  @State private var studioClockStartedAt = Date()
  @State private var isSaveLookPresented = false
  @State private var lookNameDraft = ""
  @State private var lookBeingRenamed: IdleScreenSavedLook?
  @State private var pendingLookDeletion: IdleScreenSavedLook?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(IdleScreenSetupStore.completedKey) private var setupCompleted = false

  /// Render fixtures can open advanced material controls.
  init(pixelAdvancedInitiallyExpanded: Bool = false) {
    _isPixelAdvancedExpanded = State(initialValue: pixelAdvancedInitiallyExpanded)
  }

  private enum CameraPillStatus {
    case live
    case starting
    case unavailable
    case checking

    var label: String {
      switch self {
      case .live: "Camera Live"
      case .starting: "Camera Starting"
      case .unavailable: "Camera Unavailable"
      case .checking: "Camera Checking"
      }
    }

    var kind: DesignStatusKind {
      switch self {
      case .live: .ok
      case .starting, .checking: .pending
      case .unavailable: .attention
      }
    }
  }

  var body: some View {
    WorkbenchSplit(showsInspector: navigation.isSceneInspectorVisible) {
      HStack(spacing: 0) {
        if isSaverChooserExpanded {
          saverChooser.frame(width: 208)
          Divider()
        }
        previewCanvas
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.black)
          .overlay(alignment: .top) {
            canvasToolbar.environment(\.colorScheme, .dark)
          }
          .overlay(alignment: .bottom) {
            if !navigation.isSceneInspectorVisible {
              compactSettingsDock
                .padding(12)
                .environment(\.colorScheme, .dark)
            }
          }
      }

    } inspector: {
      sceneInspector
    }
    .onAppear {
      studioClockStartedAt = Date()
      reconcileCameraPreviewSurface()
    }
    .onChange(of: model.configuration.source) { _, _ in
      reconcileCameraPreviewSurface()
    }
    .onChange(of: navigation.previewDisplayIdentifier) { _, _ in
      reconcileCameraPreviewSurface()
    }
    .onChange(of: previewUsesCamera) { _, _ in
      reconcileCameraPreviewSurface()
    }
    .onChange(of: cameraClient.canStartCameraPreview) { _, canStart in
      guard previewUsesCamera, canStart else { return }
      cameraClient.startCameraPreview()
    }
    .onDisappear {
      isLoupeEnabled = false
      loupePointerLocation = nil
      endCameraPreviewSurface()
    }
    .alert("Save Current Look", isPresented: $isSaveLookPresented) {
      TextField("Look name", text: $lookNameDraft)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        if model.saveCurrentLook(named: lookNameDraft) {
          navigation.showsSavedLooks = true
          isSaverChooserExpanded = true
        }
      }
      .disabled(lookNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("Save this screen saver, palette, and its adjustments.")
    }
    .alert(
      "Rename Saved Look",
      isPresented: Binding(
        get: { lookBeingRenamed != nil },
        set: { if !$0 { lookBeingRenamed = nil } }
      )
    ) {
      TextField("Look name", text: $lookNameDraft)
      Button("Cancel", role: .cancel) { lookBeingRenamed = nil }
      Button("Rename") {
        if let lookBeingRenamed {
          _ = model.renameSavedLook(
            id: lookBeingRenamed.id,
            to: lookNameDraft
          )
        }
        lookBeingRenamed = nil
      }
      .disabled(lookNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .confirmationDialog(
      "Delete Saved Look?",
      isPresented: Binding(
        get: { pendingLookDeletion != nil },
        set: { if !$0 { pendingLookDeletion = nil } }
      ),
      presenting: pendingLookDeletion
    ) { savedLook in
      Button("Delete “\(savedLook.name)”", role: .destructive) {
        _ = model.removeSavedLook(id: savedLook.id)
        pendingLookDeletion = nil
      }
      Button("Cancel", role: .cancel) { pendingLookDeletion = nil }
    }
  }

  @ViewBuilder
  private var previewCanvas: some View {
    GeometryReader { geometry in
      let canvasSize = IdleScreenPreviewWindowGeometry.fittedPreviewSize(
        inside: geometry.size, aspectRatio: previewAspectRatio)
      ZStack {
        Color.black.frame(width: canvasSize.width, height: canvasSize.height)

        if cameraClient.isMainWindowPresentationActive,
          canvasSize.width > 0,
          canvasSize.height > 0
        {
          ZStack(alignment: .topLeading) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
              IdleScreenMetalPreview(
                configuration: previewRendererConfiguration(at: timeline.date),
                mode: previewRendererMode,
                cameraFrame: previewUsesCamera
                  ? cameraClient.rendererCameraFrame : nil,
                cameraFrameRelay: cameraClient.rendererFrameRelay,
                pointerLocationDidChange: { location in
                  guard isLoupeEnabled else { return }
                  loupePointerLocation = location
                }
              )
            }
            .background(.black)

            if isLoupeEnabled,
              let loupePointerLocation
            {
              TimelineView(
                .animation(minimumInterval: 1 / 15)
              ) { timeline in
                IdleScreenLoupeView(
                  configuration: previewRendererConfiguration(at: timeline.date),
                  mode: previewRendererMode,
                  cameraFrame: previewUsesCamera
                    ? cameraClient.rendererCameraFrame : nil,
                  canvasSize: canvasSize,
                  pointerLocation: loupePointerLocation,
                  elapsedTime: max(
                    0,
                    timeline.date.timeIntervalSince(
                      studioClockStartedAt
                    )
                  )
                )
              }
            }

            if cameraSourceSelected,
              let guidance = cameraSetupGuidance
            {
              cameraSetupOverlay(guidance)
                .frame(
                  maxWidth: .infinity,
                  maxHeight: .infinity,
                  alignment: .center
                )
            }

          }
          .frame(width: canvasSize.width, height: canvasSize.height)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }

  private var rendererMode: IdleScreenRendererMode {
    switch model.configuration.source {
    case .generative: .generative
    case .camera: .camera
    }
  }

  private var previewAssignment: DisplaySceneAssignment? {
    let plan = displayCoordinator.latestPlan
    if let identifier = navigation.previewDisplayIdentifier,
      let assignment = plan?.assignment(for: identifier)
    {
      return assignment
    }
    return plan?.assignments.first(where: { !$0.isMirrorFollower })
  }

  private var previewUsesCamera: Bool {
    StudioCameraPreviewReconciliation.usesCamera(
      source: model.configuration.source,
      previewRole: previewAssignment?.role
    )
  }

  private var previewRendererMode: IdleScreenRendererMode {
    previewUsesCamera ? rendererMode : .generative
  }

  private func previewRendererConfiguration(at date: Date) -> IdleScreenRendererConfiguration {
    model.configurationApplyingActiveAgentSignal(at: date)
      .rendererConfiguration(
        for: previewAssignment,
        aquarium: IdleScreenAquariumController.shared.library,
        agentPresentations: model.agentPresentations(at: date),
        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      )
  }

  private var cameraSourceSelected: Bool {
    model.configuration.source == .camera
  }

  private var cameraPillStatus: CameraPillStatus {
    if cameraClient.isPreviewLeaseRequested,
      cameraClient.isPreviewLeaseAttached,
      cameraClient.frameReadiness == .ready,
      cameraClient.rendererCameraFrame != nil
    {
      return .live
    }
    if cameraSetupGuidance != nil {
      return .unavailable
    }
    if cameraClient.isPreviewLeaseRequested
      || cameraClient.canStartCameraPreview
    {
      return .starting
    }
    return .checking
  }

  private func reconcileCameraPreviewSurface() {
    if !previewUsesCamera {
      endCameraPreviewSurface()
    } else {
      cameraClient.studioCameraPreviewDidAppear()
      cameraClient.cameraPageDidAppear()
      cameraClient.startCameraPreview()
    }
  }

  @ViewBuilder
  private func cameraSetupOverlay(_ guidance: CameraCardGuidance) -> some View {
    VStack(spacing: 8) {
      Image(systemName: DesignStatusKind.attention.symbol)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(DesignStatusKind.attention.color)
        .accessibilityHidden(true)
      Text(guidance.title)
        .font(DesignFont.sans(DesignFont.panelTitle, .semibold))
        .foregroundStyle(DesignPalette.ink)
        .accessibilityAddTraits(.isHeader)
      Text(guidance.detail)
        .font(DesignFont.sans(DesignFont.detail))
        .foregroundStyle(DesignPalette.ink2)
        .multilineTextAlignment(.center)
      if let actionTitle = guidance.actionTitle {
        Button(actionTitle) {
          performCameraSetupAction(guidance.action)
        }
        .buttonStyle(.designPrimary)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: 310)
    .studioPanel()
    .accessibilityElement(children: .contain)
  }

  private func performCameraSetupAction(_ action: CameraCardGuidance.Action) {
    switch action {
    case .openSetup:
      navigation.setupSession.reopenFromCameraCard()
    case .allowAccess, .openCameraPrivacy:
      cameraClient.performSetupCameraAction()
    case .openStatus:
      navigation.destination = .status
    case .none:
      break
    }
  }

  /// Studio only reports a camera that stopped working. First-run permission and agent setup lives in the setup flow and Status.
  private var cameraSetupGuidance: CameraCardGuidance? {
    guard cameraHasRuntimeFailure else { return nil }
    return CameraCardGuidance.make(
      authorization: cameraClient.readinessSnapshot.authorization, setupCompleted: setupCompleted)
  }

  private var cameraHasRuntimeFailure: Bool {
    let snapshot = cameraClient.readinessSnapshot
    if let bootstrapStatus = cameraClient.bootstrapStatus, bootstrapStatus != .ready {
      return true
    }
    switch snapshot.serviceRegistration {
    case .notRegistered, .notFound, .requiresApproval, .failed: return true
    case .unknown, .enabled: break
    }
    switch snapshot.identity {
    case .absent, .stale, .mismatched: return true
    case .unknown, .current: break
    }
    switch snapshot.liveSnapshot {
    case .unavailable, .rejected: return true
    case .unknown, .accepted: break
    }
    switch snapshot.authorization {
    case .observed(.notDetermined), .observed(.denied), .observed(.restricted): return true
    case .unknown, .observed(.authorized): break
    }
    switch cameraClient.controlReachability {
    case .unreachable, .timedOut: return true
    case .unknown, .reachable: break
    }
    if cameraClient.isPreviewLeaseRequested {
      switch snapshot.frame {
      case .unavailable, .stalled: return true
      case .unknown, .awaitingFirstFrame, .ready: break
      }
    }
    return false
  }

  private func endCameraPreviewSurface() {
    cameraClient.cameraPageDidDisappear()
    cameraClient.studioCameraPreviewDidDisappear()
  }

  private var canvasToolbar: some View {
    ViewThatFits(in: .horizontal) {
      canvasToolbarItems.labelStyle(.titleAndIcon)
      canvasToolbarItems.labelStyle(.iconOnly)
    }
    .font(DesignFont.sans(DesignFont.caption))
    .foregroundStyle(DesignPalette.ink2)
    .buttonStyle(.plain)
    .padding(.horizontal, 16)
    .frame(height: 36)
    .background(DesignPalette.surface)
    .overlay(alignment: .bottom) { DesignHairline() }
  }

  private var canvasToolbarItems: some View {
    HStack(spacing: 12) {
      Menu {
        ForEach(previewDisplays, id: \.persistentIdentifier) { display in
          Button(displayLabel(display.persistentIdentifier)) {
            navigation.previewDisplayIdentifier = display.persistentIdentifier
          }
        }
      } label: {
        Label(previewDisplayLabel, systemImage: "display")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Preview display")
      .disabled(previewDisplays.isEmpty)
      Spacer()
      if cameraSourceSelected {
        DesignStatus(kind: cameraPillStatus.kind, text: cameraPillStatus.label)
      } else if model.configuration.creative.pattern != .pixelMaterials {
        Menu {
          Picker(
            "Framing",
            selection: Binding(
              get: { model.configuration.creative.framing },
              set: { model.updateCreativeFraming($0) }
            )
          ) {
            ForEach(IdleScreenSceneFraming.allCases) { framing in
              Text(framing.displayName).tag(framing)
            }
          }
        } label: {
          Text(model.configuration.creative.framing.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Framing")
      }
      Button {
        animate { isSaverChooserExpanded.toggle() }
      } label: {
        Label(
          isSaverChooserExpanded ? "Hide library" : "Show library", systemImage: "sidebar.leading")
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])
      .accessibilityValue(isSaverChooserExpanded ? "Shown" : "Hidden")
      Button {
        isLoupeEnabled.toggle()
        loupePointerLocation = nil
      } label: {
        Label("Loupe", systemImage: "magnifyingglass")
      }
      .accessibilityValue(isLoupeEnabled ? "On" : "Off")
      Button {
        NSApp.keyWindow?.toggleFullScreen(nil)
      } label: {
        Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
      }
    }
  }

  private var previewDisplays: [DisplayTopology.Display] {
    displayCoordinator.latestSnapshot?.topology.displays.filter { $0.mirrorTargetIdentifier == nil }
      ?? []
  }

  private var selectedPreviewDisplay: DisplayTopology.Display? {
    previewDisplays.first { $0.persistentIdentifier == navigation.previewDisplayIdentifier }
      ?? previewDisplays.first(where: \.isPrimary) ?? previewDisplays.first
  }

  private var previewAspectRatio: CGFloat {
    guard let frame = selectedPreviewDisplay?.logicalFrame else {
      return navigation.displayAspectRatio
    }
    return frame.width / frame.height
  }

  private var previewDisplayLabel: String {
    selectedPreviewDisplay.map { displayLabel($0.persistentIdentifier) } ?? "Display"
  }

  private func displayLabel(_ identifier: DisplayTopology.PersistentDisplayIdentifier) -> String {
    guard let index = previewDisplays.firstIndex(where: { $0.persistentIdentifier == identifier })
    else { return "Display" }
    return previewDisplays[index].isPrimary ? "Main display" : "Display \(index + 1)"
  }

  private var saverChooser: some View {
    VStack(spacing: 0) {
      Picker(
        "Scene library",
        selection: Binding(
          get: { navigation.showsSavedLooks },
          set: { navigation.showsSavedLooks = $0 }
        )
      ) {
        Text("Scenes").tag(false)
        Text("Your looks").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Scene library")
      .controlSize(.small)
      .padding(12)
      DesignHairline()
      ScrollView {
        LazyVStack(spacing: 4) {
          if navigation.showsSavedLooks {
            if model.configuration.savedLooks.isEmpty {
              Text("No saved looks yet. Save this scene to keep its adjustments.")
                .font(DesignFont.sans(DesignFont.caption))
                .foregroundStyle(DesignPalette.ink2)
                .padding(.vertical, 16)
            }
            ForEach(model.configuration.savedLooks) { savedLook in
              Button {
                _ = model.applySavedLook(id: savedLook.id)
              } label: {
                SavedLookChooserCard(savedLook: savedLook)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(savedLook.name)
              .contextMenu {
                Button("Apply") { _ = model.applySavedLook(id: savedLook.id) }
                Button("Update from Current") { _ = model.replaceSavedLook(id: savedLook.id) }
                Button("Rename…") {
                  lookNameDraft = savedLook.name
                  lookBeingRenamed = savedLook
                }
                Button("Delete…", role: .destructive) { pendingLookDeletion = savedLook }
              }
            }
          } else {
            ForEach(IdleScreenCreativePattern.allCases) { pattern in
              Button {
                select(pattern)
              } label: {
                SaverLibraryRow(
                  title: pattern.displayName, art: .pattern(pattern),
                  isSelected: !cameraSourceSelected
                    && model.configuration.creative.pattern == pattern)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(pattern.displayName)
              .accessibilityAddTraits(
                !cameraSourceSelected && model.configuration.creative.pattern == pattern
                  ? .isSelected : [])
            }
            Button {
              selectCameraSaver()
            } label: {
              SaverLibraryRow(title: "Camera", art: .camera, isSelected: cameraSourceSelected)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera")
            .accessibilityAddTraits(cameraSourceSelected ? .isSelected : [])
          }
        }
        .padding(8)
      }
      DesignHairline()
      Button {
        beginSavingLook()
      } label: {
        Label("Save look…", systemImage: "plus").frame(maxWidth: .infinity)
      }
      .buttonStyle(.designSecondary)
      .disabled(model.configuration.savedLooks.count >= IdleScreenSavedLook.maximumCount)
      .padding(12)
    }
    .background(DesignPalette.surface)
  }

  private var compactSettingsDock: some View {
    HStack(spacing: 14) {
      Text(selectedSaverName)
        .font(DesignFont.sans(DesignFont.detail, .semibold))
      StudioDivider()
      if cameraSourceSelected {
        cameraSelectionMenu(includesUtilities: true)
      } else if model.configuration.creative.pattern == .pixelMaterials {
        StudioSlider(
          title: "Cell",
          value: Binding(
            get: { model.configuration.materials.cellScale },
            set: { value in model.updatePixelMaterials { $0.cellScale = value } }),
          range: 0.25...4,
          layout: .inline(width: 64))
      } else {
        StudioSlider(
          title: "Speed",
          value: Binding(
            get: { model.configuration.creative.settings.speed },
            set: { model.updateCreativeSpeed($0) }),
          range: IdleScreenCreativeSettings.minimumSpeed...IdleScreenCreativeSettings.maximumSpeed,
          layout: .inline(width: 64))
      }
      Menu {
        ForEach(["Cobalt", "Ember", "Phosphor", "Ivory", "Blueprint", "Signal"], id: \.self) {
          palette in
          Button(palette) { model.updatePalette(palette) }
        }
        Button("Camera Color") { model.updatePalette("Camera Color") }
          .disabled(!model.canSelectPalette("Camera Color"))
      } label: {
        Text(model.configuration.appearance.palette)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Palette")
      StudioDivider()
      StudioSlider(
        title: "Size",
        value: Binding(
          get: { model.configuration.appearance.glyphScale },
          set: { model.updateGlyphScale($0) }),
        layout: .inline(width: 64))
      StudioSlider(
        title: "Contrast",
        value: Binding(
          get: { model.configuration.appearance.contrast },
          set: { model.updateContrast($0) }),
        layout: .inline(width: 64))
      Button("More", systemImage: "slider.horizontal.3") {
        navigation.isSceneInspectorVisible = true
      }
      .buttonStyle(.plain)
      .accessibilityHint("Shows every control for this scene")
    }
    .font(DesignFont.sans(DesignFont.detail))
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .fixedSize()
    .studioPanel(radius: 10)
    .frame(maxWidth: .infinity)
  }

  private var sceneInspector: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack {
            Text("Scene").designEyebrow()
            Spacer()
            if !cameraSourceSelected {
              Button("Reset") {
                if model.configuration.creative.pattern == .pixelMaterials {
                  model.resetPixelMaterials()
                } else {
                  model.resetCreativeSettings()
                }
              }
              .buttonStyle(.plain).foregroundStyle(DesignPalette.accentMark)
            }
          }
          VStack(alignment: .leading, spacing: 6) {
            Text(selectedSaverName).font(DesignFont.sans(18, .semibold)).foregroundStyle(
              DesignPalette.ink
            )
            .accessibilityAddTraits(.isHeader)
            Text(cameraSourceSelected ? "Camera scene" : "Procedural scene")
              .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
          }
          paletteSelector
          DesignHairline()
          if cameraSourceSelected {
            expandedCameraSettings
          } else if model.configuration.creative.pattern == .pixelMaterials {
            expandedPixelMaterialsSettings
          } else {
            expandedProceduralSettings
          }
        }
        .padding(20)
      }
      DesignHairline()
      VStack(spacing: 8) {
        Button {
          beginSavingLook()
        } label: {
          Label("Save look…", systemImage: "plus").frame(maxWidth: .infinity)
        }
        .buttonStyle(.designSecondary)
        .disabled(model.configuration.savedLooks.count >= IdleScreenSavedLook.maximumCount)
        Text("Scene changes apply automatically")
          .font(DesignFont.sans(DesignFont.eyebrow)).foregroundStyle(DesignPalette.ink2)
      }
      .padding(18)
    }
  }

  private func cameraSelectionMenu(includesUtilities: Bool) -> some View {
    Menu {
      Section("Camera") {
        Button {
          model.updateCameraSelection(.automatic)
          cameraClient.refreshCameraDeviceInventory()
        } label: {
          cameraMenuLabel(
            title: "Automatic",
            selected: model.configuration.camera.selection == .automatic
          )
        }

        ForEach(connectedCameraDevices) { device in
          Button {
            guard
              let selection = IdleScreenCameraSelection.deviceIfValid(
                uniqueID: device.deviceIdentifier
              )
            else { return }
            model.updateCameraSelection(selection)
            cameraClient.refreshCameraDeviceInventory()
          } label: {
            cameraMenuLabel(
              title: device.displayName,
              selected: model.configuration.camera.selection.deviceIdentifier
                == device.deviceIdentifier
            )
          }
        }
      }

      if model.configuration.camera.selection == .automatic {
        Section("Preferred") {
          Button {
            model.updatePreferredCamera(nil)
            cameraClient.refreshCameraDeviceInventory()
          } label: {
            cameraMenuLabel(
              title: "No preference",
              selected: model.configuration.camera.preferredDeviceIdentifier == nil,
              preferred: true
            )
          }

          ForEach(connectedCameraDevices) { device in
            Button {
              model.updatePreferredCamera(device.deviceIdentifier)
              cameraClient.refreshCameraDeviceInventory()
            } label: {
              cameraMenuLabel(
                title: device.displayName,
                selected: model.configuration.camera.preferredDeviceIdentifier
                  == device.deviceIdentifier,
                preferred: true
              )
            }
          }
        }
      }

      if includesUtilities {
        Divider()

        Toggle(
          "Mirror camera",
          isOn: Binding(
            get: { model.configuration.camera.isMirrored },
            set: { model.updateCameraMirroring($0) }
          )
        )

        Button("Camera setup…") {
          navigation.destination = .status
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(
          systemName: model.configuration.camera.preferredDeviceIdentifier == nil
            ? "camera.fill" : "star.fill"
        )
        .foregroundStyle(
          model.configuration.camera.preferredDeviceIdentifier == nil
            ? DesignPalette.ink2 : DesignPalette.accentMark
        )
        .accessibilityHidden(true)
        Text(selectedCameraLabel)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(
            maxWidth: includesUtilities ? nil : 150,
            alignment: .trailing
          )
      }
      .font(DesignFont.sans(DesignFont.detail, .semibold))
      .foregroundStyle(DesignPalette.ink)
    }
    .menuStyle(.borderlessButton)
    .accessibilityHint(
      model.configuration.camera.preferredDeviceIdentifier == nil
        ? "Camera source" : "Camera source, a preferred camera is set")
  }

  private func cameraMenuLabel(
    title: String,
    selected: Bool,
    preferred: Bool = false
  ) -> some View {
    Label(
      title,
      systemImage: selected
        ? (preferred ? "star.fill" : "checkmark")
        : (preferred ? "star" : "circle")
    )
  }

  private var paletteSelector: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Palette").font(DesignFont.sans(12, .medium))
        Spacer()
        Text(model.configuration.appearance.palette)
          .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
      }
      HStack(spacing: 8) {
        ForEach(["Cobalt", "Ember", "Phosphor", "Ivory", "Blueprint", "Signal"], id: \.self) {
          palette in
          Button {
            model.updatePalette(palette)
          } label: {
            Circle().fill(palettePair(for: palette).b)
              .frame(width: 22, height: 22)
              .overlay {
                if model.configuration.appearance.palette == palette {
                  Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palettePair(for: palette).a)
                }
              }
              .padding(3)
              .overlay {
                Circle().strokeBorder(
                  model.configuration.appearance.palette == palette
                    ? DesignPalette.accentMark : DesignPalette.hair,
                  lineWidth: model.configuration.appearance.palette == palette ? 2 : 1)
              }
          }
          .buttonStyle(.plain)
          .accessibilityLabel(palette + " palette")
          .accessibilityAddTraits(
            model.configuration.appearance.palette == palette ? .isSelected : [])
        }
      }
      if cameraSourceSelected {
        Button("Camera Color") { model.updatePalette("Camera Color") }
          .buttonStyle(.designSecondary)
          .disabled(!model.canSelectPalette("Camera Color"))
      }
    }
  }

  private var expandedCameraSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 22) {
        StudioSection(title: "Input") {
          StudioField(title: "Source") {
            cameraSelectionMenu(includesUtilities: false)
              .accessibilityLabel("Source")
              .accessibilityValue(selectedCameraLabel)
          }

          if model.configuration.camera.selection == .automatic {
            StudioField(title: "Preferred") {
              Text(preferredCameraLabel)
                .font(DesignFont.sans(DesignFont.caption))
                .lineLimit(1)
                .foregroundStyle(DesignPalette.ink2)
                .accessibilityLabel("Preferred")
                .accessibilityValue(preferredCameraLabel)
            }
          }

          StudioField(title: "Mirror camera") {
            Toggle(
              "Mirror camera",
              isOn: Binding(
                get: { model.configuration.camera.isMirrored },
                set: { model.updateCameraMirroring($0) }
              )
            )
            .labelsHidden()
            .accessibilityLabel("Mirror camera")
            .toggleStyle(.designSwitch)
          }

          Button {
            navigation.destination = .status
          } label: {
            Label("Camera Settings…", systemImage: "gearshape")
          }
          .buttonStyle(.designSecondary)
        }

        StudioSection(title: "Appearance") {
          StudioSlider(
            title: "Size",
            value: Binding(
              get: { model.configuration.appearance.glyphScale },
              set: { model.updateGlyphScale($0) }
            ),
            range: 0...1,
            valueText: percentage(model.configuration.appearance.glyphScale),
            step: 0.01
          )
          StudioSlider(
            title: "Contrast",
            value: Binding(
              get: { model.configuration.appearance.contrast },
              set: { model.updateContrast($0) }
            ),
            range: 0...1,
            valueText: percentage(model.configuration.appearance.contrast),
            step: 0.01
          )
        }
      }

      expandedSettingsFooter(showsQuality: false)
    }
  }

  private var expandedProceduralSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 22) {
        StudioSection(title: "Motion") {
          StudioSlider(
            title: "Speed",
            value: Binding(
              get: { model.configuration.creative.settings.speed },
              set: { model.updateCreativeSpeed($0) }
            ),
            range: IdleScreenCreativeSettings
              .minimumSpeed...IdleScreenCreativeSettings.maximumSpeed,
            valueText: model.configuration.creative.settings.speed.formatted(
              .number.precision(.fractionLength(1))
            ) + "×",
            step: 0.1
          )

          if expandedScaleControlApplies {
            StudioSlider(
              title: "Scale",
              value: Binding(
                get: { model.configuration.creative.settings.scale },
                set: { model.updateCreativeScale($0) }
              ),
              range: IdleScreenCreativeSettings
                .minimumScale...IdleScreenCreativeSettings.maximumScale,
              valueText: model.configuration.creative.settings.scale.formatted(
                .number.precision(.fractionLength(2))
              ) + "×",
              step: 0.05
            )
          }

          Picker(
            "Framing",
            selection: Binding(
              get: { model.configuration.creative.framing },
              set: { model.updateCreativeFraming($0) }
            )
          ) {
            ForEach(IdleScreenSceneFraming.allCases) { framing in
              Text(framing.displayName).tag(framing)
            }
          }
          .pickerStyle(.segmented)
        }

        StudioSection(title: "Appearance") {
          StudioSlider(
            title: "Size",
            value: Binding(
              get: { model.configuration.appearance.glyphScale },
              set: { model.updateGlyphScale($0) }
            ),
            range: 0...1,
            valueText: percentage(model.configuration.appearance.glyphScale),
            step: 0.01
          )
          StudioSlider(
            title: "Contrast",
            value: Binding(
              get: { model.configuration.appearance.contrast },
              set: { model.updateContrast($0) }
            ),
            range: 0...1,
            valueText: percentage(model.configuration.appearance.contrast),
            step: 0.01
          )
        }
      }

      DisclosureGroup("Pattern") {
        VStack(alignment: .leading, spacing: 12) {
          if expandedIntensityControlApplies {
            StudioSlider(
              title: "Intensity",
              value: Binding(
                get: { model.configuration.creative.settings.intensity },
                set: { model.updateCreativeIntensity($0) }
              ),
              range: 0...1,
              valueText: percentage(
                model.configuration.creative.settings.intensity
              ),
              step: 0.01
            )
          }

          if expandedTrailingControlApplies {
            StudioSlider(
              title: "Trailing",
              value: Binding(
                get: { model.configuration.creative.settings.trailing },
                set: { model.updateCreativeTrailing($0) }
              ),
              range: 0...1,
              valueText: percentage(
                model.configuration.creative.settings.trailing
              ),
              step: 0.01
            )
          }

          expandedPatternSpecificControl

        }
      }
      .font(DesignFont.sans(DesignFont.caption))

      expandedSettingsFooter(showsQuality: expandedQualityControlApplies)
    }
  }

  private var expandedPixelMaterialsSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 22) {
        StudioSection(title: "Material", minHeight: 0) {
          DesignSegmented(
            title: "Material",
            selection: Binding(
              get: { model.configuration.materials.material },
              set: { model.updatePixelMaterial($0) }
            ),
            choices: IdleScreenPixelMaterial.allCases.map { DesignChoice($0.label, $0) }
          )

          StudioField(title: "Palette") {
            DesignPopup(
              title: "Palette",
              selection: Binding(
                get: { model.configuration.materials.palette },
                set: { palette in
                  model.updatePixelMaterials { $0.palette = palette }
                }
              ),
              choices: IdleScreenPixelMaterialsPalette.allCases.map { DesignChoice($0.label, $0) }
            )
          }
        }

        StudioSection(title: "Terrain", minHeight: 0) {
          StudioField(title: "Terrain") {
            DesignPopup(
              title: "Terrain",
              selection: Binding(
                get: { model.configuration.materials.terrainFamily },
                set: { terrain in
                  model.updatePixelMaterials {
                    $0.terrainFamily = terrain
                  }
                }
              ),
              choices: IdleScreenPixelTerrainFamily.allCases.map { DesignChoice($0.label, $0) }
            )
          }

          StudioField(title: "Seed") {
            HStack(spacing: 6) {
              Text(model.configuration.materials.seed.formatted())
                .font(DesignFont.sans(DesignFont.caption).monospacedDigit())
                .foregroundStyle(DesignPalette.ink2)
                .lineLimit(1)
                .accessibilityLabel("Seed")
                .accessibilityValue(model.configuration.materials.seed.formatted())
              Button("New") {
                model.updatePixelMaterials { settings in
                  settings.seed =
                    settings.seed
                    &* 6_364_136_223_846_793_005 &+ 1
                }
              }
              .buttonStyle(.designSecondary)
              .accessibilityHint("Generates a new deterministic seed")
            }
          }
        }
      }

      StudioDisclosure(title: "Advanced", isExpanded: $isPixelAdvancedExpanded) {
        VStack {
          VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 12) {
              StudioSection(title: "Watershed", minHeight: 0) {
                materialStepper(
                  "Basin count",
                  value: Binding(
                    get: { model.configuration.materials.basinCount },
                    set: { value in
                      model.updatePixelMaterials { $0.basinCount = value }
                    }
                  ),
                  range: 2...8
                )
                materialStepper(
                  "Basin depth",
                  value: Binding(
                    get: { model.configuration.materials.basinDepth },
                    set: { value in
                      model.updatePixelMaterials { $0.basinDepth = value }
                    }
                  ),
                  range: 3...24
                )
                materialStepper(
                  "Minimum basin capacity",
                  value: Binding(
                    get: {
                      model.configuration.materials
                        .minimumBasinCapacity
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.minimumBasinCapacity = value
                      }
                    }
                  ),
                  range: 8...4096
                )
                materialSlider(
                  "Channel connectivity",
                  value: Binding(
                    get: {
                      model.configuration.materials
                        .channelConnectivity
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.channelConnectivity = value
                      }
                    }
                  )
                )
                materialStepper(
                  "Channel width",
                  value: Binding(
                    get: { model.configuration.materials.channelWidth },
                    set: { value in
                      model.updatePixelMaterials { $0.channelWidth = value }
                    }
                  ),
                  range: 1...6
                )
                materialSlider(
                  "Rock ratio",
                  value: Binding(
                    get: { model.configuration.materials.rockRatio },
                    set: { value in
                      model.updatePixelMaterials { $0.rockRatio = value }
                    }
                  )
                )
                materialSlider(
                  "Soil ratio",
                  value: Binding(
                    get: { model.configuration.materials.soilRatio },
                    set: { value in
                      model.updatePixelMaterials { $0.soilRatio = value }
                    }
                  )
                )
              }
              StudioSection(title: "Emitters", minHeight: 0) {
                materialStepper(
                  "Emitter count",
                  value: Binding(
                    get: { model.configuration.materials.emitterCount },
                    set: { value in
                      model.updatePixelMaterials { $0.emitterCount = value }
                    }
                  ),
                  range: 1...4
                )
                materialSlider(
                  "Emitter position",
                  value: Binding(
                    get: {
                      model.configuration.materials.emitterPosition
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.emitterPosition = value
                      }
                    }
                  )
                )
                materialStepper(
                  "Emitter width",
                  value: Binding(
                    get: { model.configuration.materials.emitterWidth },
                    set: { value in
                      model.updatePixelMaterials { $0.emitterWidth = value }
                    }
                  ),
                  range: 1...8
                )
                materialStepper(
                  "Emitter rate",
                  value: Binding(
                    get: { model.configuration.materials.emitterRate },
                    set: { value in
                      model.updatePixelMaterials { $0.emitterRate = value }
                    }
                  ),
                  range: 1...8
                )
              }
            }
            VStack(spacing: 12) {
              StudioSection(title: "Flow", minHeight: 0) {
                materialSlider(
                  "Cell scale",
                  value: Binding(
                    get: { model.configuration.materials.cellScale },
                    set: { value in
                      model.updatePixelMaterials { $0.cellScale = value }
                    }
                  ),
                  range: 0.25...4,
                  step: 0.25
                )
                materialSlider(
                  "Gravity",
                  value: Binding(
                    get: { model.configuration.materials.gravity },
                    set: { value in
                      model.updatePixelMaterials { $0.gravity = value }
                    }
                  )
                )
                materialSlider(
                  "Lateral flow",
                  value: Binding(
                    get: { model.configuration.materials.waterLateralFlow },
                    set: { value in
                      model.updatePixelMaterials { $0.waterLateralFlow = value }
                    }
                  )
                )
                materialSlider(
                  "Equalization",
                  value: Binding(
                    get: { model.configuration.materials.waterEqualization },
                    set: { value in
                      model.updatePixelMaterials { $0.waterEqualization = value }
                    }
                  )
                )
                materialSlider(
                  "Water pressure",
                  value: Binding(
                    get: {
                      model.configuration.materials.waterPressure
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.waterPressure = value
                      }
                    }
                  )
                )
                materialSlider(
                  "Spill rate",
                  value: Binding(
                    get: { model.configuration.materials.spillRate },
                    set: { value in
                      model.updatePixelMaterials { $0.spillRate = value }
                    }
                  )
                )
                materialSlider(
                  "Drain rate",
                  value: Binding(
                    get: { model.configuration.materials.drainRate },
                    set: { value in
                      model.updatePixelMaterials { $0.drainRate = value }
                    }
                  )
                )
                materialSlider(
                  "Evaporation rate",
                  value: Binding(
                    get: {
                      model.configuration.materials.evaporationRate
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.evaporationRate = value
                      }
                    }
                  )
                )
                materialSlider(
                  "Obstacle density",
                  value: Binding(
                    get: {
                      model.configuration.materials.obstacleDensity
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.obstacleDensity = value
                      }
                    }
                  )
                )
                materialSlider(
                  "Persistence",
                  value: Binding(
                    get: { model.configuration.materials.persistence },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.persistence = value
                      }
                    }
                  )
                )
              }
              StudioSection(title: "Phases", minHeight: 0) {
                materialSlider(
                  "Quiet duration",
                  value: Binding(
                    get: {
                      model.configuration.materials.phaseDurations
                        .quiet
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.phaseDurations.quiet = value
                      }
                    }
                  ),
                  range: 0.25...60,
                  step: 0.25,
                  suffix: "s"
                )
                materialSlider(
                  "Fill duration",
                  value: Binding(
                    get: {
                      model.configuration.materials.phaseDurations
                        .filling
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.phaseDurations.filling = value
                      }
                    }
                  ),
                  range: 0.25...300,
                  step: 0.25,
                  suffix: "s"
                )
                materialSlider(
                  "Settled duration",
                  value: Binding(
                    get: {
                      model.configuration.materials.phaseDurations
                        .settled
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.phaseDurations.settled = value
                      }
                    }
                  ),
                  range: 0.25...300,
                  step: 0.25,
                  suffix: "s"
                )
                materialSlider(
                  "Drain duration",
                  value: Binding(
                    get: {
                      model.configuration.materials.phaseDurations
                        .draining
                    },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.phaseDurations.draining = value
                      }
                    }
                  ),
                  range: 0.25...300,
                  step: 0.25,
                  suffix: "s"
                )
                materialSlider(
                  "Regeneration",
                  value: Binding(
                    get: { model.configuration.materials.regenerationCadence },
                    set: { value in
                      model.updatePixelMaterials {
                        $0.regenerationCadence = value
                      }
                    }
                  ),
                  range: 5...120,
                  step: 1,
                  suffix: "s"
                )
              }
            }
          }
        }

      }

      expandedSettingsFooter(showsQuality: true)
    }
  }

  private func materialStepper(
    _ title: String,
    value: Binding<Int>,
    range: ClosedRange<Int>
  ) -> some View {
    Stepper(
      value: value,
      in: range
    ) {
      LabeledContent(title, value: value.wrappedValue.formatted())
    }
    .font(DesignFont.sans(DesignFont.caption, .medium))
    .foregroundStyle(DesignPalette.ink)
    .accessibilityLabel(title)
    .accessibilityValue(value.wrappedValue.formatted())
  }

  private func materialSlider(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double> = 0...1,
    step: Double = 0.01,
    suffix: String = ""
  ) -> some View {
    StudioSlider(
      title: title,
      value: value,
      range: range,
      valueText: value.wrappedValue.formatted(
        .number.precision(.fractionLength(step < 0.1 ? 2 : 1))
      ) + suffix,
      step: step
    )
  }

  @ViewBuilder
  private func expandedSettingsFooter(showsQuality: Bool) -> some View {
    if showsQuality {
      DisclosureGroup("Rendering") {
        Picker("Quality", selection: expandedQualityBinding) {
          ForEach(ExpandedStudioQuality.allCases) { quality in Text(quality.title).tag(quality) }
        }
        .padding(.top, 8)
      }
      .font(DesignFont.sans(DesignFont.caption))
      .foregroundStyle(DesignPalette.ink2)
    }
  }

  private var expandedQualityBinding: Binding<ExpandedStudioQuality> {
    Binding(
      get: {
        ExpandedStudioQuality.nearest(
          to: model.configuration.creative.settings.qualityLevel
        )
      },
      set: { model.updateCreativeQualityLevel($0.rawValue) }
    )
  }

  @ViewBuilder
  private var expandedPatternSpecificControl: some View {
    switch model.configuration.creative.pattern {
    case .autoCycle:
      StudioSlider(
        title: "Every",
        value: Binding(
          get: { model.configuration.creative.settings.autoCycleInterval },
          set: { model.updateCreativeAutoCycleInterval($0) }
        ),
        range: 1...120,
        valueText: model.configuration.creative.settings.autoCycleInterval.formatted(
          .number.precision(.fractionLength(0))
        ) + "s",
        step: 1
      )
    case .matrixRain:
      StudioSlider(
        title: "Trail length",
        value: Binding(
          get: { model.configuration.creative.settings.matrixTrailLength },
          set: { model.updateCreativeMatrixTrailLength($0) }
        ),
        range: 0...1,
        valueText: percentage(
          model.configuration.creative.settings.matrixTrailLength
        ),
        step: 0.01
      )
    case .rainbowCycle:
      StudioSlider(
        title: "Amplitude",
        value: Binding(
          get: { model.configuration.creative.settings.rainbowAmplitude },
          set: { model.updateCreativeRainbowAmplitude($0) }
        ),
        range: 0...1,
        valueText: percentage(
          model.configuration.creative.settings.rainbowAmplitude
        ),
        step: 0.01
      )
    case .fireEffect:
      StudioSlider(
        title: "Decay",
        value: Binding(
          get: { model.configuration.creative.settings.fireDecay },
          set: { model.updateCreativeFireDecay($0) }
        ),
        range: 0...1,
        valueText: percentage(model.configuration.creative.settings.fireDecay),
        step: 0.01
      )
    default:
      EmptyView()
    }
  }

  private var expandedScaleControlApplies: Bool {
    switch model.configuration.creative.pattern {
    case .matrixRain, .staticNoise: false
    default: true
    }
  }

  private var expandedIntensityControlApplies: Bool {
    model.configuration.creative.pattern != .dvdBounce
  }

  private var expandedTrailingControlApplies: Bool {
    model.configuration.creative.pattern != .matrixRain
  }

  private var expandedQualityControlApplies: Bool {
    model.configuration.creative.pattern != .dvdBounce
  }

  private func percentage(_ value: Double) -> String {
    (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
  }

  private var connectedCameraDevices: [IdleScreenCompanionCameraDevice] {
    guard case .live(let snapshot) = cameraClient.cameraDeviceState else {
      return []
    }
    return snapshot.connectedDevices
  }

  private var selectedCameraLabel: String {
    switch model.configuration.camera.selection {
    case .automatic:
      if let preferredIdentifier = model.configuration.camera.preferredDeviceIdentifier,
        let device = connectedCameraDevices.first(where: {
          $0.deviceIdentifier == preferredIdentifier
        })
      {
        return device.displayName
      }
      return "Automatic"
    case .device(let uniqueID):
      return connectedCameraDevices.first(where: {
        $0.deviceIdentifier == uniqueID
      })?.displayName ?? "Selected camera"
    }
  }

  private var preferredCameraLabel: String {
    guard let identifier = model.configuration.camera.preferredDeviceIdentifier else {
      return "None"
    }
    return connectedCameraDevices.first(where: {
      $0.deviceIdentifier == identifier
    })?.displayName ?? "Unavailable camera"
  }

  private var selectedSaverName: String {
    cameraSourceSelected
      ? "Camera"
      : model.configuration.creative.pattern.displayName
  }

  /// The panel and chooser animations, skipped under Reduce Motion.
  private func animate(_ changes: () -> Void) {
    withAnimation(reduceMotion ? nil : .snappy(duration: 0.24), changes)
  }

  private func selectCameraSaver() {
    model.updateSource(.camera)
  }

  private func select(_ pattern: IdleScreenCreativePattern) {
    if model.configuration.source != .generative {
      model.updateSource(.generative)
    }
    model.updateCreativePattern(pattern)
  }

  private func beginSavingLook() {
    lookNameDraft = "\(selectedSaverName) Look"
    isSaveLookPresented = true
  }

  private func palettePair(for palette: String) -> (a: Color, b: Color) {
    switch palette.lowercased() {
    case "cobalt":
      (
        Color(red: 0.016, green: 0.02, blue: 0.035),
        Color(red: 0.231, green: 0.424, blue: 0.941)
      )
    case "phosphor":
      (
        Color(red: 0.01, green: 0.04, blue: 0.01),
        Color(red: 0.28, green: 1.00, blue: 0.38)
      )
    case "ivory":
      (
        Color(red: 0.04, green: 0.035, blue: 0.025),
        Color(red: 1.00, green: 0.94, blue: 0.78)
      )
    case "blueprint":
      (
        Color(red: 0.01, green: 0.04, blue: 0.12),
        Color(red: 0.35, green: 0.78, blue: 1.00)
      )
    case "signal":
      (
        Color(red: 0.06, green: 0.01, blue: 0.01),
        Color(red: 1.00, green: 0.22, blue: 0.14)
      )
    case "camera color":
      (
        Color(red: 0.12, green: 0.65, blue: 1.00),
        Color(red: 1.00, green: 0.28, blue: 0.18)
      )
    default:
      (
        Color(red: 0.17, green: 0.09, blue: 0.03),
        Color(red: 1.00, green: 0.71, blue: 0.36)
      )
    }
  }

}

private struct SavedLookChooserCard: View {
  let savedLook: IdleScreenSavedLook

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SaverTile(
        art: savedLook.snapshot.source == .camera
          ? .camera : .pattern(savedLook.snapshot.creative.pattern),
        cornerRadius: 6
      )
      .frame(height: 54)
      Text(savedLook.name)
        .font(DesignFont.sans(DesignFont.caption, .medium))
        .foregroundStyle(DesignPalette.ink)
        .lineLimit(1)
    }
    .padding(6)
    .frame(width: 140, alignment: .leading)
    .background(DesignPalette.sel, in: RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair2, lineWidth: 1) }
    .contentShape(RoundedRectangle(cornerRadius: 8))
  }
}

private enum ExpandedStudioQuality: Double, CaseIterable, Identifiable {
  case efficient = 0.4
  case balanced = 0.7
  case detailed = 1

  var id: Double { rawValue }

  var title: String {
    switch self {
    case .efficient: "Efficient"
    case .balanced: "Balanced"
    case .detailed: "Detailed"
    }
  }

  static func nearest(to value: Double) -> Self {
    allCases.min {
      abs($0.rawValue - value) < abs($1.rawValue - value)
    } ?? .balanced
  }
}

enum IdleScreenMetalPreviewState: Equatable, Sendable {
  case initializing
  case live
  case failed(String)
}

@MainActor
@Observable
private final class IdleScreenMetalPreviewStatus {
  var state: IdleScreenMetalPreviewState = .initializing

  func publish(_ newState: IdleScreenMetalPreviewState) {
    Task { @MainActor [weak self] in
      guard let self, self.state != newState else { return }
      self.state = newState
    }
  }
}

/// SwiftUI host for the shared production renderer. Initialization is explicit:
/// a failed Metal renderer is replaced by an honest in-view error instead of a
/// silent black surface in either Studio or Visuals.
@MainActor
struct IdleScreenMetalPreview: View {
  let configuration: IdleScreenRendererConfiguration
  let mode: IdleScreenRendererMode
  let cameraFrame: IdleScreenRendererCameraFrame?
  let cameraFrameRelay: IdleScreenRendererCameraFrameRelay?
  let elapsedTime: TimeInterval?
  private let pointerLocationDidChange: ((CGPoint?) -> Void)?
  private let reportedState: Binding<IdleScreenMetalPreviewState>?
  @State private var status = IdleScreenMetalPreviewStatus()

  init(
    configuration: IdleScreenRendererConfiguration,
    mode: IdleScreenRendererMode,
    cameraFrame: IdleScreenRendererCameraFrame?,
    cameraFrameRelay: IdleScreenRendererCameraFrameRelay? = nil,
    elapsedTime: TimeInterval? = nil,
    pointerLocationDidChange: ((CGPoint?) -> Void)? = nil,
    state: Binding<IdleScreenMetalPreviewState>? = nil
  ) {
    self.configuration = configuration
    self.mode = mode
    self.cameraFrame = cameraFrame
    self.cameraFrameRelay = cameraFrameRelay
    self.elapsedTime = elapsedTime
    self.pointerLocationDidChange = pointerLocationDidChange
    reportedState = state
  }

  var body: some View {
    ZStack {
      IdleScreenMetalViewHost(
        configuration: configuration,
        mode: mode,
        cameraFrame: cameraFrame,
        cameraFrameRelay: cameraFrameRelay,
        elapsedTime: elapsedTime,
        pointerLocationDidChange: pointerLocationDidChange,
        status: status
      )

      switch status.state {
      case .initializing:
        rendererStatusView(
          title: "Starting renderer…",
          message: nil,
          systemImage: "hourglass"
        )
      case .live:
        EmptyView()
      case .failed(let message):
        rendererStatusView(
          title: "Metal preview unavailable",
          message: message,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
    .onAppear {
      reportedState?.wrappedValue = status.state
    }
    .onChange(of: status.state) { _, state in
      reportedState?.wrappedValue = state
    }
  }

  private func rendererStatusView(
    title: String,
    message: String?,
    systemImage: String
  ) -> some View {
    VStack(spacing: 9) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(DesignPalette.ink2)
        .accessibilityHidden(true)
      Text(title)
        .font(DesignFont.sans(DesignFont.body, .semibold))
        .foregroundStyle(DesignPalette.ink)
      if let message {
        Text(message)
          .font(DesignFont.sans(DesignFont.caption))
          .foregroundStyle(DesignPalette.ink2)
          .multilineTextAlignment(.center)
          .lineLimit(3)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DesignPalette.previewGround)
    .accessibilityElement(children: .combine)
  }
}

/// AppKit lifecycle adapter for the shared renderer. State publication is
/// deferred to the main actor so SwiftUI is never mutated during view creation.
@MainActor
private struct IdleScreenMetalViewHost: NSViewRepresentable {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let configuration: IdleScreenRendererConfiguration
  let mode: IdleScreenRendererMode
  let cameraFrame: IdleScreenRendererCameraFrame?
  let cameraFrameRelay: IdleScreenRendererCameraFrameRelay?
  let elapsedTime: TimeInterval?
  let pointerLocationDidChange: ((CGPoint?) -> Void)?
  let status: IdleScreenMetalPreviewStatus

  private var presentedConfiguration: IdleScreenRendererConfiguration {
    var value = configuration
    value.aquariumSettings?.reduceMotion =
      reduceMotion || configuration.aquariumSettings?.reduceMotion == true
    return value
  }

  private var staticAquarium: Bool {
    configuration.patternRawValue == "aquarium" && mode != .camera
      && presentedConfiguration.aquariumSettings?.reduceMotion == true
  }

  @MainActor
  final class Coordinator {
    var renderer: IdleScreenRenderer?
    var cameraFrameRelay: IdleScreenRendererCameraFrameRelay?
    var cameraFrameSubscription: IdleScreenRendererCameraFrameRelay.Subscription?

    func subscribe(
      renderer: IdleScreenRenderer,
      to relay: IdleScreenRendererCameraFrameRelay?
    ) {
      if cameraFrameRelay === relay { return }
      unsubscribe()
      cameraFrameRelay = relay
      cameraFrameSubscription = relay?.subscribe { [weak renderer] frame in
        guard let renderer else { return }
        if let frame {
          renderer.submit(cameraFrame: frame)
        } else {
          renderer.clearCameraFrame()
        }
      }
    }

    func unsubscribe() {
      if let cameraFrameSubscription {
        cameraFrameRelay?.unsubscribe(cameraFrameSubscription)
      }
      cameraFrameSubscription = nil
      cameraFrameRelay = nil
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> IdleScreenTrackedMetalView {
    let metalView = IdleScreenTrackedMetalView(frame: .zero)
    metalView.autoresizingMask = [.width, .height]
    metalView.pointerLocationDidChange = pointerLocationDidChange
    status.publish(.initializing)
    do {
      let renderer = try IdleScreenRenderer(
        metalView: metalView,
        configuration: presentedConfiguration,
        mode: mode,
        automaticallyDraws: elapsedTime == nil && !staticAquarium
      )
      metalView.enableSetNeedsDisplay = staticAquarium
      if staticAquarium { metalView.needsDisplay = true }
      context.coordinator.renderer = renderer
      context.coordinator.subscribe(
        renderer: renderer,
        to: cameraFrameRelay
      )
      if cameraFrameRelay == nil, let cameraFrame {
        renderer.submit(cameraFrame: cameraFrame)
      }
      if let elapsedTime {
        renderer.draw(at: elapsedTime)
      }
      status.publish(.live)
    } catch {
      context.coordinator.renderer = nil
      metalView.isPaused = true
      status.publish(.failed(error.localizedDescription))
    }
    return metalView
  }

  func updateNSView(
    _ metalView: IdleScreenTrackedMetalView,
    context: Context
  ) {
    metalView.pointerLocationDidChange = pointerLocationDidChange
    metalView.isPaused = elapsedTime != nil || staticAquarium
    metalView.enableSetNeedsDisplay = staticAquarium
    if staticAquarium { metalView.needsDisplay = true }
    guard let renderer = context.coordinator.renderer else { return }
    renderer.update(configuration: presentedConfiguration)
    renderer.update(mode: mode)
    context.coordinator.subscribe(
      renderer: renderer,
      to: cameraFrameRelay
    )
    if cameraFrameRelay == nil {
      if let cameraFrame {
        renderer.submit(cameraFrame: cameraFrame)
      } else {
        renderer.clearCameraFrame()
      }
    }
    if let elapsedTime {
      renderer.draw(at: elapsedTime)
    }
  }

  static func dismantleNSView(
    _ metalView: IdleScreenTrackedMetalView,
    coordinator: Coordinator
  ) {
    metalView.pointerLocationDidChange = nil
    coordinator.unsubscribe()
    coordinator.renderer?.shutdown()
    coordinator.renderer = nil
  }
}

/// AppKit owns pointer tracking for the Metal surface. SwiftUI hover gestures
/// are not reliably delivered through an `NSViewRepresentable`-backed MTKView,
/// while an NSTrackingArea follows the native view's real visible bounds.
@MainActor
private final class IdleScreenTrackedMetalView: MTKView {
  var pointerLocationDidChange: ((CGPoint?) -> Void)?
  private var pointerTrackingArea: NSTrackingArea?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.acceptsMouseMovedEvents = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let pointerTrackingArea {
      removeTrackingArea(pointerTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [
        .activeInKeyWindow,
        .inVisibleRect,
        .mouseEnteredAndExited,
        .mouseMoved,
      ],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    pointerTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    publishPointerLocation(from: event)
  }

  override func mouseMoved(with event: NSEvent) {
    publishPointerLocation(from: event)
  }

  override func mouseDragged(with event: NSEvent) {
    publishPointerLocation(from: event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    publishPointerLocation(from: event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    publishPointerLocation(from: event)
  }

  override func mouseExited(with event: NSEvent) {
    pointerLocationDidChange?(nil)
  }

  private func publishPointerLocation(from event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point) else {
      pointerLocationDidChange?(nil)
      return
    }
    pointerLocationDidChange?(
      CGPoint(
        x: point.x - bounds.minX,
        y: bounds.maxY - point.y
      ))
  }
}

/// A bounded cell renderer for the pointer's local canvas region.
///
/// The original loupe embedded a second canvas-sized `MTKView` and clipped all
/// but this circle. That doubled the full glyph-grid rebuild and allocated a
/// second full-window drawable chain. This path evaluates and draws only the
/// cells that can actually appear inside the lens.
@MainActor
private struct IdleScreenLoupeView: View {
  private static let magnification: CGFloat = 2.25

  let configuration: IdleScreenRendererConfiguration
  let mode: IdleScreenRendererMode
  let cameraFrame: IdleScreenRendererCameraFrame?
  let canvasSize: CGSize
  let pointerLocation: CGPoint
  let elapsedTime: TimeInterval
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    let radius = lensRadius
    let diameter = radius * 2
    let sourcePoint = boundedPointerLocation

    ZStack {
      IdleScreenLoupeCanvas(
        configuration: configuration,
        mode: mode,
        cameraFrame: cameraFrame,
        canvasSize: canvasSize,
        sourcePoint: sourcePoint,
        magnification: Self.magnification,
        displayScale: displayScale,
        elapsedTime: elapsedTime
      )

      VStack {
        Spacer()
        Text(
          Double(Self.magnification).formatted(
            .number.precision(.fractionLength(2))
          ) + "×"
        )
        .font(DesignFont.sans(DesignFont.eyebrow, .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.52), in: Capsule())
        .padding(.bottom, 10)
      }
    }
    .frame(width: diameter, height: diameter)
    .clipShape(Circle())
    .overlay {
      Circle()
        .strokeBorder(.white.opacity(0.88), lineWidth: 2)
    }
    .overlay {
      Circle()
        .inset(by: 5)
        .strokeBorder(.black.opacity(0.34), lineWidth: 1)
    }
    .position(lensCenter(radius: radius))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var lensRadius: CGFloat {
    let shortestSide = min(canvasSize.width, canvasSize.height)
    return max(48, min(112, shortestSide * 0.22))
  }

  private var boundedPointerLocation: CGPoint {
    CGPoint(
      x: min(canvasSize.width, max(0, pointerLocation.x)),
      y: min(canvasSize.height, max(0, pointerLocation.y))
    )
  }

  private func lensCenter(radius: CGFloat) -> CGPoint {
    let margin: CGFloat = 8
    let minimumX = radius + margin
    let minimumY = radius + margin
    let maximumX = max(minimumX, canvasSize.width - radius - margin)
    let maximumY = max(minimumY, canvasSize.height - radius - margin)
    return CGPoint(
      x: min(maximumX, max(minimumX, pointerLocation.x)),
      y: min(maximumY, max(minimumY, pointerLocation.y))
    )
  }
}

private struct IdleScreenLoupeCanvas: View {
  private static let glyphRamp = Array(" .:-=+*#%@")

  let configuration: IdleScreenRendererConfiguration
  let mode: IdleScreenRendererMode
  let cameraFrame: IdleScreenRendererCameraFrame?
  let canvasSize: CGSize
  let sourcePoint: CGPoint
  let magnification: CGFloat
  let displayScale: CGFloat
  let elapsedTime: TimeInterval

  var body: some View {
    Canvas(rendersAsynchronously: true) { context, lensSize in
      drawLoupe(in: &context, lensSize: lensSize)
    }
  }

  private func drawLoupe(
    in context: inout GraphicsContext,
    lensSize: CGSize
  ) {
    guard canvasSize.width > 0,
      canvasSize.height > 0,
      lensSize.width > 0,
      lensSize.height > 0
    else {
      return
    }

    let palette = LoupePalette(configuration.palette)
    context.fill(
      Path(CGRect(origin: .zero, size: lensSize)),
      with: .color(palette.background.color)
    )

    let normalizedScale = max(0, min(1, configuration.glyphScale))
    let glyphPixelSize = 8 + normalizedScale * 12
    let scale = max(0.5, displayScale)
    let columns = max(
      1,
      Int(canvasSize.width * scale / max(4, glyphPixelSize * 0.62))
    )
    let rows = max(
      1,
      Int(canvasSize.height * scale / max(6, glyphPixelSize))
    )
    let cellWidth = canvasSize.width / CGFloat(columns)
    let cellHeight = canvasSize.height / CGFloat(rows)
    let sourceHalfWidth = lensSize.width / (2 * magnification)
    let sourceHalfHeight = lensSize.height / (2 * magnification)
    let sourceMinX = sourcePoint.x - sourceHalfWidth
    let sourceMinY = sourcePoint.y - sourceHalfHeight
    let sourceMaxX = sourcePoint.x + sourceHalfWidth
    let sourceMaxY = sourcePoint.y + sourceHalfHeight
    let firstColumn = max(0, Int(floor(sourceMinX / cellWidth)))
    let lastColumn = min(
      columns - 1,
      Int(floor(sourceMaxX / cellWidth))
    )
    let firstRow = max(0, Int(floor(sourceMinY / cellHeight)))
    let lastRow = min(rows - 1, Int(floor(sourceMaxY / cellHeight)))
    guard firstColumn <= lastColumn, firstRow <= lastRow else { return }

    let renderedCellHeight = cellHeight * magnification
    let fontSize = renderedCellHeight * 0.68
    let glyphs = Self.glyphRamp.map { glyph in
      context.resolve(
        Text(String(glyph))
          .font(.custom("Menlo", size: fontSize))
      )
    }
    let contrast = Float(
      0.6 + max(0, min(1, configuration.contrast)) * 1.6
    )
    let usesCameraColor =
      configuration.palette.caseInsensitiveCompare(
        "Camera Color"
      ) == .orderedSame

    for row in firstRow...lastRow {
      for column in firstColumn...lastColumn {
        let cameraSample = sampledCameraPixel(
          column: column,
          row: row,
          columns: columns,
          rows: rows
        )
        let proceduralSample = proceduralCell(
          column: column,
          row: row,
          columns: columns,
          rows: rows
        )
        let resolved = resolvedCell(
          proceduralSample: proceduralSample,
          cameraSample: cameraSample,
          contrast: contrast
        )
        var glyph = glyphs[resolved.glyphIndex]
        let foreground =
          if usesCameraColor,
            mode != .generative,
            let cameraSample
          {
            cameraSample.color
          } else {
            palette.foreground
          }
        let intensity = 0.12 + 0.88 * Double(resolved.brightness)
        glyph.shading = .color(
          foreground.multiplied(by: intensity)
            .color.opacity(Double(resolved.brightness))
        )
        let center = CGPoint(
          x: lensSize.width / 2
            + (CGFloat(column) * cellWidth
              + cellWidth / 2 - sourcePoint.x) * magnification,
          y: lensSize.height / 2
            + (CGFloat(row) * cellHeight
              + cellHeight / 2 - sourcePoint.y) * magnification
        )
        context.draw(glyph, at: center, anchor: .center)
      }
    }
  }

  private func proceduralCell(
    column: Int,
    row: Int,
    columns: Int,
    rows: Int
  ) -> IdleScreenProceduralCellSample {
    IdleScreenProceduralPatterns.cellSample(
      patternRawValue: configuration.patternRawValue,
      settings: configuration.proceduralSettings,
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      glyphCount: Self.glyphRamp.count,
      time: elapsedTime
    )
  }

  private func sampledCameraPixel(
    column: Int,
    row: Int,
    columns: Int,
    rows: Int
  ) -> LoupeCameraSample? {
    guard let cameraFrame,
      cameraFrame.columns > 0,
      cameraFrame.rows > 0,
      cameraFrame.luminance.count
        == cameraFrame.columns * cameraFrame.rows,
      cameraFrame.interleavedRGB.count
        == cameraFrame.luminance.count * 3
    else {
      return nil
    }
    let unmirroredCameraColumn = min(
      cameraFrame.columns - 1,
      max(0, column * cameraFrame.columns / columns)
    )
    let cameraColumn =
      if configuration.cameraIsMirrored,
        mode != .generative
      {
        cameraFrame.columns - 1 - unmirroredCameraColumn
      } else {
        unmirroredCameraColumn
      }
    let cameraRow = min(
      cameraFrame.rows - 1,
      max(0, row * cameraFrame.rows / rows)
    )
    let sampleIndex = cameraRow * cameraFrame.columns + cameraColumn
    let rgbIndex = sampleIndex * 3
    return LoupeCameraSample(
      brightness: Float(cameraFrame.luminance[sampleIndex]) / 255,
      color: LoupeRGB(
        red: Double(cameraFrame.interleavedRGB[rgbIndex]) / 255,
        green: Double(cameraFrame.interleavedRGB[rgbIndex + 1]) / 255,
        blue: Double(cameraFrame.interleavedRGB[rgbIndex + 2]) / 255
      )
    )
  }

  private func resolvedCell(
    proceduralSample: IdleScreenProceduralCellSample,
    cameraSample: LoupeCameraSample?,
    contrast: Float
  ) -> LoupeResolvedCell {
    var brightness: Float
    var glyphIndex: Int?
    switch (mode, cameraSample?.brightness) {
    case (.generative, _), (.camera, nil):
      brightness = proceduralSample.brightness
      glyphIndex = proceduralSample.glyphIndex
    case (.camera, .some(let cameraBrightness)):
      brightness = cameraBrightness
      glyphIndex = nil
    }
    brightness = min(1, max(0, (brightness - 0.5) * contrast + 0.5))
    return LoupeResolvedCell(
      brightness: brightness,
      glyphIndex: glyphIndex
        ?? min(
          Self.glyphRamp.count - 1,
          Int(brightness * Float(Self.glyphRamp.count))
        )
    )
  }
}

private struct LoupeResolvedCell {
  let brightness: Float
  let glyphIndex: Int
}

private struct LoupeCameraSample {
  let brightness: Float
  let color: LoupeRGB
}

private struct LoupeRGB {
  let red: Double
  let green: Double
  let blue: Double

  var color: Color {
    Color(red: red, green: green, blue: blue)
  }

  func multiplied(by value: Double) -> Self {
    Self(red: red * value, green: green * value, blue: blue * value)
  }
}

private struct LoupePalette {
  let background: LoupeRGB
  let foreground: LoupeRGB

  init(_ name: String) {
    switch name.lowercased() {
    case "camera color":
      background = LoupeRGB(red: 0.008, green: 0.008, blue: 0.008)
      foreground = LoupeRGB(red: 0.92, green: 0.92, blue: 0.92)
    case "cobalt":
      background = LoupeRGB(red: 0.016, green: 0.02, blue: 0.035)
      foreground = LoupeRGB(red: 0.70, green: 0.74, blue: 0.82)
    case "phosphor":
      background = LoupeRGB(red: 0.01, green: 0.04, blue: 0.01)
      foreground = LoupeRGB(red: 0.28, green: 1, blue: 0.38)
    case "ivory":
      background = LoupeRGB(red: 0.04, green: 0.035, blue: 0.025)
      foreground = LoupeRGB(red: 1, green: 0.94, blue: 0.78)
    case "blueprint":
      background = LoupeRGB(red: 0.01, green: 0.04, blue: 0.12)
      foreground = LoupeRGB(red: 0.35, green: 0.78, blue: 1)
    case "signal":
      background = LoupeRGB(red: 0.06, green: 0.01, blue: 0.01)
      foreground = LoupeRGB(red: 1, green: 0.22, blue: 0.14)
    default:
      background = LoupeRGB(red: 0.043, green: 0.031, blue: 0.012)
      foreground = LoupeRGB(red: 1, green: 0.75, blue: 0.42)
    }
  }
}

extension IdleScreenConfiguration {
  var rendererConfiguration: IdleScreenRendererConfiguration {
    rendererConfiguration(for: nil)
  }

  func rendererConfiguration(
    for assignment: DisplaySceneAssignment?,
    aquarium: IdleScreenAquariumLibrary? = nil,
    agentPresentations: [IdleScreenAgentOverlayPresentation] = [],
    reduceMotion: Bool = false
  ) -> IdleScreenRendererConfiguration {
    IdleScreenRendererConfigurationBridge.configuration(
      for: self,
      assignment: assignment,
      aquarium: aquarium,
      agentPresentations: agentPresentations,
      reduceMotion: reduceMotion
    )
  }
}

// MARK: - Components

private struct SaverLibraryRow: View {
  let title: String
  let art: SaverTileArt
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 8) {
      SaverTile(art: art, cornerRadius: 4).frame(width: 44, height: 30)
      Text(title).font(DesignFont.sans(DesignFont.caption, isSelected ? .semibold : .regular))
        .foregroundStyle(DesignPalette.ink)
        .lineLimit(2)
      Spacer(minLength: 0)
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? DesignPalette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(Rectangle())
  }
}

struct PalettePair: View {
  var a: Color, b: Color
  var body: some View {
    HStack(spacing: -4) {
      Circle().fill(a).frame(width: 12, height: 12)
      Circle().fill(b).frame(width: 12, height: 12)
    }
    .accessibilityHidden(true)
  }
}

#Preview {
  ContentView()
    .environment(IdleScreenAppModel())
    .environment(IdleScreenCompanionNavigation())
    .frame(width: 1040, height: 680)
}
