// IdleScreen — Preview shell, direction 1c (icon rail · full-bleed art · floating glass controls)
// macOS 26+, SwiftUI.

import Foundation
import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import MetalKit
import SwiftUI

private enum StudioLayout {
  static let navigationRailWidth = IdleScreenPreviewWindowGeometry
    .navigationRailWidth
}

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
      Text("is")
        .font(.system(size: 13, weight: .heavy, design: .monospaced))
        .tracking(-0.5)
    }
    .menuBarExtraStyle(.menu)
  }
}

enum Destination: String, CaseIterable, Identifiable {
  case studio = "Studio"
  case displays = "Displays"
  case integrations = "Integrations"
  case system = "System"

  static let primaryCases: [Destination] = [.studio, .displays, .integrations, .system]

  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .studio: "play.rectangle"
    case .displays: "rectangle.3.group"
    case .integrations: "point.3.connected.trianglepath.dotted"
    case .system: "waveform.path.ecg"
    }
  }
}

@MainActor
@Observable
final class IdleScreenCompanionNavigation {
  var destination: Destination = .studio
  var displayAspectRatio: CGFloat = 16 / 9
  var previewDisplayIdentifier: DisplayTopology.PersistentDisplayIdentifier?

  func showCameraDiagnostics() {
    destination = .system
  }
}

struct ContentView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(IdleScreenCompanionCameraClient.self) private var cameraClient
  @Environment(IdleScreenCompanionNavigation.self) private var navigation
  @Environment(DisplaySceneCoordinator.self) private var displayCoordinator

  var body: some View {
    HStack(spacing: 0) {
      railView
      Divider().opacity(0.4)
      switch navigation.destination {
      case .studio: StudioView()
      case .displays: DisplaysView()
      case .integrations: IntegrationsView()
      case .system: SystemView()
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .ignoresSafeArea()
    .onChange(of: model.configuration.revision, initial: true) {
      _, revision in
      _ = displayCoordinator.update(
        settings: model.configuration.display,
        configurationRevision: revision
      )
    }
    .task {
      while !Task.isCancelled {
        model.refreshAgentSignals()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private var railView: some View {
    VStack(spacing: 6) {
      Spacer().frame(height: 44)  // traffic-light clearance (hidden title bar)
      ForEach(Destination.primaryCases) { destination in
        destinationButton(destination)
      }
      Spacer()

      Button {
        model.openScreenSaverSettings()
      } label: {
        railLabel(
          title: "macOS",
          symbol: "gearshape",
          tint: .secondary,
          isSelected: false
        )
      }
      .buttonStyle(.plain)
      .help("Open macOS Screen Saver Settings")
      .padding(.bottom, 10)
    }
    .frame(width: StudioLayout.navigationRailWidth)
    .background(.ultraThinMaterial)
  }

  private func destinationButton(_ destination: Destination) -> some View {
    Button {
      navigation.destination = destination
    } label: {
      railLabel(
        title: destination.rawValue,
        symbol: destination.symbol,
        tint: navigation.destination == destination ? .accentColor : .secondary,
        isSelected: navigation.destination == destination
      )
    }
    .buttonStyle(.plain)
    .help(destination.rawValue)
  }

  private func railLabel(
    title: String,
    symbol: String,
    tint: Color,
    isSelected: Bool
  ) -> some View {
    VStack(spacing: 3) {
      ZStack(alignment: .topTrailing) {
        Image(systemName: symbol)
          .font(.system(size: 16, weight: .medium))
        if title == Destination.system.rawValue {
          Circle()
            .fill(healthSummary.tint)
            .frame(width: 6, height: 6)
            .offset(x: 5, y: -3)
        }
      }
      Text(title)
        .font(.system(size: 9, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .frame(width: 58, height: 46)
    .foregroundStyle(tint)
    .background(
      RoundedRectangle(cornerRadius: 9)
        .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
    )
    .contentShape(RoundedRectangle(cornerRadius: 9))
  }

  private var healthSummary: (label: String, symbol: String, tint: Color) {
    if model.isRefreshing {
      return ("Checking", "arrow.clockwise", .secondary)
    }
    if model.lastError != nil
      || !model.compatibility.isCompatible
      || !model.isExtensionEmbedded
    {
      return ("Attention", "exclamationmark.triangle.fill", .orange)
    }
    if model.configuration.source != .generative,
      cameraClient.recommendedRepair != nil
    {
      return ("Attention", "exclamationmark.triangle.fill", .orange)
    }
    if !model.registrationAssessment.isCurrentBuild
      || model.selection?.isSelectedEverywhere != true
    {
      return ("Set Up", "circle.dashed", .orange)
    }
    return ("Ready", "checkmark.circle.fill", .green)
  }
}

struct StudioView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(IdleScreenCompanionCameraClient.self) private var cameraClient
  @Environment(IdleScreenCompanionNavigation.self) private var navigation
  @Environment(DisplaySceneCoordinator.self) private var displayCoordinator
  @State private var isSaverChooserExpanded = true
  @State private var isMoreExpanded = false
  @State private var isLoupeEnabled = false
  @State private var loupePointerLocation: CGPoint?
  @State private var studioClockStartedAt = Date()
  @State private var isSaveLookPresented = false
  @State private var lookNameDraft = ""
  @State private var lookBeingRenamed: IdleScreenSavedLook?
  @State private var pendingLookDeletion: IdleScreenSavedLook?

  private let saverColumns = [
    GridItem(.flexible(), spacing: 8),
    GridItem(.flexible(), spacing: 8),
  ]

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

    var tint: Color {
      switch self {
      case .live: .green
      case .starting, .checking: .secondary
      case .unavailable: .orange
      }
    }
  }

  private struct CameraSetupGuidance {
    let title: String
    let detail: String
  }

  var body: some View {
    ZStack {
      previewCanvas
        .ignoresSafeArea()

      VStack(spacing: 10) {
        HStack(spacing: 7) {
          StatusPill(
            label: registrationPillLabel,
            systemImage: "display",
            tint: model.registrationAssessment.isCurrentBuild
              ? .green : .orange
          )
          if cameraSourceSelected {
            StatusPill(
              label: cameraPillStatus.label,
              systemImage: "camera.fill",
              tint: cameraPillStatus.tint
            )
          }
          Button {
            withAnimation(.snappy(duration: 0.24)) {
              isSaverChooserExpanded.toggle()
            }
          } label: {
            Label(
              "Screen Savers",
              systemImage: isSaverChooserExpanded
                ? "chevron.up" : "chevron.down"
            )
            .font(.system(size: 12, weight: .semibold))
          }
          .buttonStyle(.bordered)

          Spacer()

          Button {
            isLoupeEnabled.toggle()
            if !isLoupeEnabled {
              loupePointerLocation = nil
            }
          } label: {
            Label(
              "Loupe",
              systemImage: isLoupeEnabled
                ? "magnifyingglass.circle.fill"
                : "magnifyingglass"
            )
            .font(.system(size: 12, weight: .semibold))
          }
          .buttonStyle(.bordered)
          .help(
            isLoupeEnabled
              ? "Turn off the pointer-following live preview loupe"
              : "Inspect the live character field under the pointer"
          )

          Button {
            model.startScreenSaver()
          } label: {
            Label("Start idlescreen", systemImage: "play.fill")
              .font(.system(size: 12, weight: .semibold))
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
          .disabled(
            model.isRegistering
              || model.isStartingScreenSaver
              || !model.isExtensionEmbedded
          )

        }
        .padding(.horizontal, 16)
        .padding(.top, 14)

        if isSaverChooserExpanded {
          saverChooser
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
          Spacer(minLength: 16)
        }

        settingsDock
          .padding(.horizontal, 16)
          .padding(.bottom, 18)
      }
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
        _ = model.saveCurrentLook(named: lookNameDraft)
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
      let canvasSize = fittedPreviewSize(inside: geometry.size)
      ZStack {
        Color.black

        if cameraClient.isMainWindowPresentationActive,
          canvasSize.width > 0,
          canvasSize.height > 0
        {
          ZStack(alignment: .topLeading) {
            IdleScreenMetalPreview(
              configuration: previewRendererConfiguration,
              mode: previewRendererMode,
              cameraFrame: previewUsesCamera
                ? cameraClient.rendererCameraFrame : nil,
              cameraFrameRelay: cameraClient.rendererFrameRelay,
              pointerLocationDidChange: { location in
                guard isLoupeEnabled else { return }
                loupePointerLocation = location
              }
            )
            .background(.black)

            if isLoupeEnabled,
              let loupePointerLocation
            {
              TimelineView(
                .animation(minimumInterval: 1 / 15)
              ) { timeline in
                IdleScreenLoupeView(
                  configuration: previewRendererConfiguration,
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

            if let presentation = model.agentPresentation() {
              AgentSignalOverlayView(presentation: presentation)
                .frame(
                  maxWidth: .infinity,
                  maxHeight: .infinity,
                  alignment: presentation.position.swiftUIAlignment
                )
                .padding(24)
                .allowsHitTesting(false)
            }
          }
          .frame(width: canvasSize.width, height: canvasSize.height)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }

  private func fittedPreviewSize(inside availableSize: CGSize) -> CGSize {
    let aspectRatio = navigation.displayAspectRatio
    guard availableSize.width > 0,
      availableSize.height > 0,
      aspectRatio.isFinite,
      aspectRatio > 0
    else {
      return .zero
    }

    if availableSize.width / availableSize.height > aspectRatio {
      return CGSize(
        width: availableSize.height * aspectRatio,
        height: availableSize.height
      )
    }
    return CGSize(
      width: availableSize.width,
      height: availableSize.width / aspectRatio
    )
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

  private var previewRendererConfiguration: IdleScreenRendererConfiguration {
    model.configurationApplyingActiveAgentSignal()
      .rendererConfiguration(for: previewAssignment)
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
  private func cameraSetupOverlay(_ guidance: CameraSetupGuidance) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "camera.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.orange)
      Text(guidance.title)
        .font(.headline)
      Text(guidance.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(cameraSetupActionTitle) {
        performCameraSetupAction()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: 310)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
  }

  private var cameraSetupActionTitle: String {
    switch cameraClient.readinessSnapshot.authorization {
    case .observed(.notDetermined): "Allow Camera Access"
    case .observed(.denied), .observed(.restricted): "Open Camera Privacy"
    case .unknown, .observed(.authorized): "Camera Setup"
    }
  }

  private func performCameraSetupAction() {
    switch cameraClient.readinessSnapshot.authorization {
    case .observed(.notDetermined),
      .observed(.denied),
      .observed(.restricted):
      cameraClient.performRecommendedRepair()
    case .unknown, .observed(.authorized):
      navigation.destination = .system
    }
  }

  private var cameraSetupGuidance: CameraSetupGuidance? {
    if let bootstrapStatus = cameraClient.bootstrapStatus,
      bootstrapStatus != .ready
    {
      return CameraSetupGuidance(
        title: "Camera runtime needs attention",
        detail: "Open System to repair the camera runtime."
      )
    }

    switch cameraClient.readinessSnapshot.serviceRegistration {
    case .notRegistered, .notFound, .requiresApproval, .failed:
      return CameraSetupGuidance(
        title: "Camera agent needs setup",
        detail: "Open System to enable or repair the camera agent."
      )
    case .unknown, .enabled:
      break
    }

    switch cameraClient.readinessSnapshot.identity {
    case .absent, .stale, .mismatched:
      return CameraSetupGuidance(
        title: "Camera agent needs repair",
        detail: "Open System to replace the camera agent with this app's copy."
      )
    case .unknown, .current:
      break
    }

    switch cameraClient.readinessSnapshot.liveSnapshot {
    case .unavailable, .rejected:
      return CameraSetupGuidance(
        title: "Camera check failed",
        detail: "Open System to reconnect or repair the camera agent."
      )
    case .unknown, .accepted:
      break
    }

    switch cameraClient.readinessSnapshot.authorization {
    case .observed(.notDetermined):
      return CameraSetupGuidance(
        title: "Allow camera access",
        detail: "Open System and allow idlescreen to use the camera."
      )
    case .observed(.denied):
      return CameraSetupGuidance(
        title: "Camera access is off",
        detail: "Open System to restore access in Privacy & Security."
      )
    case .observed(.restricted):
      return CameraSetupGuidance(
        title: "Camera access is restricted",
        detail: "System policy is preventing camera access."
      )
    case .unknown, .observed(.authorized):
      break
    }

    switch cameraClient.controlReachability {
    case .unreachable, .timedOut:
      return CameraSetupGuidance(
        title: "Camera agent is unavailable",
        detail: "Open System to reconnect or repair the camera agent."
      )
    case .unknown, .reachable:
      break
    }

    if cameraClient.isPreviewLeaseRequested {
      switch cameraClient.frameReadiness {
      case .unavailable, .stalled:
        return CameraSetupGuidance(
          title: "Camera feed is unavailable",
          detail: "Open System to check the camera and its connection."
        )
      case .unknown, .awaitingFirstFrame, .ready:
        break
      }
    }

    return nil
  }

  private func endCameraPreviewSurface() {
    cameraClient.cameraPageDidDisappear()
    cameraClient.studioCameraPreviewDidDisappear()
  }

  private var saverChooser: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Your Looks")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Text("\(model.configuration.savedLooks.count)/\(IdleScreenSavedLook.maximumCount)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
        Spacer()
        Button {
          beginSavingLook()
        } label: {
          Label("Save current", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(
          model.configuration.savedLooks.count
            >= IdleScreenSavedLook.maximumCount
        )
      }

      if model.configuration.savedLooks.isEmpty {
        Text("Save a look to bring this exact saver and styling back in one click.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
      } else {
        ScrollView(.horizontal) {
          HStack(spacing: 9) {
            ForEach(model.configuration.savedLooks) { savedLook in
              Button {
                _ = model.applySavedLook(id: savedLook.id)
              } label: {
                SavedLookChooserCard(savedLook: savedLook)
              }
              .buttonStyle(.plain)
              .contextMenu {
                Button("Apply") {
                  _ = model.applySavedLook(id: savedLook.id)
                }
                Button("Update from Current") {
                  _ = model.replaceSavedLook(id: savedLook.id)
                }
                Button("Rename…") {
                  lookNameDraft = savedLook.name
                  lookBeingRenamed = savedLook
                }
                Divider()
                Button("Delete…", role: .destructive) {
                  pendingLookDeletion = savedLook
                }
              }
            }
          }
        }
        .scrollIndicators(.hidden)
      }

      Divider().opacity(0.45)

      Text("All Savers")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)

      ScrollView {
        LazyVGrid(columns: saverColumns, alignment: .leading, spacing: 10) {
          Button {
            selectCameraSaver()
          } label: {
            SaverChooserCard(
              title: "Camera",
              subtitle: "Your camera, live",
              symbol: "camera.fill",
              colors: [
                Color(red: 0.12, green: 0.65, blue: 1),
                Color(red: 1, green: 0.28, blue: 0.18),
              ],
              isSelected: cameraSourceSelected
            )
          }
          .buttonStyle(.plain)

          ForEach(IdleScreenCreativePattern.allCases) { pattern in
            Button {
              select(pattern)
            } label: {
              SaverChooserCard(
                title: pattern.displayName,
                subtitle: pattern.galleryEyebrow,
                symbol: pattern.symbolName,
                colors: pattern.galleryColors,
                isSelected: !cameraSourceSelected
                  && model.configuration.creative.pattern == pattern
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
      }
    }
    .padding(14)
    .frame(width: 278)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.48), radius: 24, y: 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var settingsDock: some View {
    Group {
      if isMoreExpanded {
        expandedSettingsDock
          .transition(.move(edge: .bottom).combined(with: .opacity))
      } else {
        compactSettingsDock
      }
    }
    .frame(maxWidth: 930)
    .frame(maxWidth: .infinity)
  }

  private var compactSettingsDock: some View {
    HStack(spacing: 13) {
      Button {
        withAnimation(.snappy(duration: 0.24)) {
          isSaverChooserExpanded.toggle()
        }
      } label: {
        Label(selectedSaverName, systemImage: selectedSaverSymbol)
          .font(.system(size: 12, weight: .semibold))
          .frame(minHeight: 22)
          .padding(.leading, 16)
          .padding(.vertical, 10)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Divider().frame(height: 22)

      if cameraSourceSelected {
        cameraSelectionMenu(includesUtilities: true)
      } else if model.configuration.creative.pattern == .pixelMaterials {
        pixelMaterialsCompactControls
      } else {
        proceduralKeyControls
      }

      Divider().frame(height: 22)

      paletteMenu

      Divider().frame(height: 22)

      LabeledSlider(
        title: "Size",
        value: Binding(
          get: { model.configuration.appearance.glyphScale },
          set: { model.updateGlyphScale($0) }
        ))
      LabeledSlider(
        title: "Contrast",
        value: Binding(
          get: { model.configuration.appearance.contrast },
          set: { model.updateContrast($0) }
        ))

      Button {
        withAnimation(.snappy(duration: 0.24)) {
          isSaverChooserExpanded = false
          isMoreExpanded = true
        }
      } label: {
        HStack(spacing: 4) {
          Text("More")
          Image(systemName: "chevron.down")
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.5), radius: 25, y: 16)
  }

  private var expandedSettingsDock: some View {
    VStack(alignment: .leading, spacing: 13) {
      expandedSettingsHeader

      Divider().opacity(0.42)

      if cameraSourceSelected {
        expandedCameraSettings
      } else if model.configuration.creative.pattern == .pixelMaterials {
        expandedPixelMaterialsSettings
      } else {
        expandedProceduralSettings
      }
    }
    .padding(16)
    .frame(width: 758)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.5), radius: 25, y: 16)
  }

  private var expandedSettingsHeader: some View {
    HStack(spacing: 13) {
      Label(selectedSaverName, systemImage: selectedSaverSymbol)
        .font(.system(size: 13, weight: .semibold))

      Spacer(minLength: 12)

      paletteMenu

      Button {
        beginSavingLook()
      } label: {
        Label("Save Look", systemImage: "plus")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(
        model.configuration.savedLooks.count
          >= IdleScreenSavedLook.maximumCount
      )

      if !cameraSourceSelected {
        Button("Reset") {
          if model.configuration.creative.pattern == .pixelMaterials {
            model.resetPixelMaterials()
          } else {
            model.resetCreativeSettings()
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(
          model.configuration.creative.pattern == .pixelMaterials
            ? model.configuration.materials == .default
            : model.configuration.creative.settings == .default
        )
      }

      Button {
        withAnimation(.snappy(duration: 0.24)) {
          isMoreExpanded = false
        }
      } label: {
        HStack(spacing: 4) {
          Text("Less")
          Image(systemName: "chevron.up")
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
        .padding(.leading, 13)
        .padding(.trailing, 16)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.leading, -13)
      .padding(.trailing, -16)
    }
  }

  @ViewBuilder
  private var proceduralKeyControls: some View {
    CompactStudioSlider(
      title: "Speed",
      value: Binding(
        get: { model.configuration.creative.settings.speed },
        set: { model.updateCreativeSpeed($0) }
      ),
      range: IdleScreenCreativeSettings.minimumSpeed...IdleScreenCreativeSettings.maximumSpeed
    )

    if model.configuration.creative.pattern == .autoCycle {
      CompactStudioSlider(
        title: "Every",
        value: Binding(
          get: { model.configuration.creative.settings.autoCycleInterval },
          set: { model.updateCreativeAutoCycleInterval($0) }
        ),
        range: 1...120,
        suffix: "s"
      )
    }
  }

  @ViewBuilder
  private var pixelMaterialsCompactControls: some View {
    Menu {
      ForEach(IdleScreenPixelMaterial.allCases) { material in
        Button(material.label) {
          model.updatePixelMaterial(material)
        }
      }
    } label: {
      Label(
        model.configuration.materials.material.label,
        systemImage: "drop.triangle"
      )
      .font(.system(size: 12, weight: .semibold))
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("Material")

    CompactStudioSlider(
      title: "Cell",
      value: Binding(
        get: { model.configuration.materials.cellScale },
        set: { value in
          model.updatePixelMaterials { $0.cellScale = value }
        }
      ),
      range: 0.25...4
    )
    .accessibilityLabel("Cell scale")
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
          navigation.destination = .system
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
            ? Color.secondary : Color.yellow
        )
        Text(selectedCameraLabel)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(
            maxWidth: includesUtilities ? nil : 150,
            alignment: .trailing
          )
      }
      .font(.system(size: 12, weight: .semibold))
    }
    .menuStyle(.borderlessButton)
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

  private var paletteMenu: some View {
    Menu {
      ForEach(["Ember", "Phosphor", "Ivory", "Blueprint", "Signal"], id: \.self) {
        palette in
        Button(palette) { model.updatePalette(palette) }
      }
      Button("Camera Color") { model.updatePalette("Camera Color") }
        .disabled(!model.canSelectPalette("Camera Color"))
    } label: {
      HStack(spacing: 6) {
        PalettePair(a: selectedPalettePair.a, b: selectedPalettePair.b)
        Text(model.configuration.appearance.palette)
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var expandedCameraSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        ExpandedStudioSection(title: "Input", systemImage: "camera.fill") {
          LabeledContent("Source") {
            cameraSelectionMenu(includesUtilities: false)
          }
          .font(.system(size: 11.5, weight: .medium))

          if model.configuration.camera.selection == .automatic {
            LabeledContent("Preferred") {
              Text(preferredCameraLabel)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5, weight: .medium))
          }

          Toggle(
            "Mirror camera",
            isOn: Binding(
              get: { model.configuration.camera.isMirrored },
              set: { model.updateCameraMirroring($0) }
            )
          )
          .toggleStyle(.switch)
          .controlSize(.small)

          Button {
            navigation.destination = .system
          } label: {
            Label("Camera Settings…", systemImage: "gearshape")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        ExpandedStudioSection(
          title: "Appearance",
          systemImage: "textformat.size"
        ) {
          ExpandedStudioSlider(
            title: "Size",
            value: Binding(
              get: { model.configuration.appearance.glyphScale },
              set: { model.updateGlyphScale($0) }
            ),
            range: 0...1,
            valueText: percentage(model.configuration.appearance.glyphScale),
            step: 0.01
          )
          ExpandedStudioSlider(
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
      HStack(alignment: .top, spacing: 12) {
        ExpandedStudioSection(
          title: "Motion",
          systemImage: "waveform.path"
        ) {
          ExpandedStudioSlider(
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
            ExpandedStudioSlider(
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
        }

        ExpandedStudioSection(title: "Pattern", systemImage: "sparkles") {
          if expandedIntensityControlApplies {
            ExpandedStudioSlider(
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
            ExpandedStudioSlider(
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

        ExpandedStudioSection(
          title: "Appearance",
          systemImage: "textformat.size"
        ) {
          ExpandedStudioSlider(
            title: "Size",
            value: Binding(
              get: { model.configuration.appearance.glyphScale },
              set: { model.updateGlyphScale($0) }
            ),
            range: 0...1,
            valueText: percentage(model.configuration.appearance.glyphScale),
            step: 0.01
          )
          ExpandedStudioSlider(
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

      expandedSettingsFooter(showsQuality: expandedQualityControlApplies)
    }
  }

  private var expandedPixelMaterialsSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        ExpandedStudioSection(
          title: "Material",
          systemImage: "drop.triangle"
        ) {
          Picker(
            "Material",
            selection: Binding(
              get: { model.configuration.materials.material },
              set: { model.updatePixelMaterial($0) }
            )
          ) {
            ForEach(IdleScreenPixelMaterial.allCases) { material in
              Text(material.label).tag(material)
            }
          }
          .pickerStyle(.segmented)

          Picker(
            "Terrain",
            selection: Binding(
              get: { model.configuration.materials.terrainFamily },
              set: { terrain in
                model.updatePixelMaterials {
                  $0.terrainFamily = terrain
                }
              }
            )
          ) {
            ForEach(IdleScreenPixelTerrainFamily.allCases) { terrain in
              Text(terrain.label).tag(terrain)
            }
          }

          Picker(
            "Palette",
            selection: Binding(
              get: { model.configuration.materials.palette },
              set: { palette in
                model.updatePixelMaterials { $0.palette = palette }
              }
            )
          ) {
            ForEach(IdleScreenPixelMaterialsPalette.allCases) { palette in
              Text(palette.label).tag(palette)
            }
          }

          LabeledContent("Seed") {
            HStack(spacing: 6) {
              Text(model.configuration.materials.seed.formatted())
                .monospacedDigit()
                .lineLimit(1)
              Button("New") {
                model.updatePixelMaterials { settings in
                  settings.seed =
                    settings.seed
                    &* 6_364_136_223_846_793_005 &+ 1
                }
              }
              .accessibilityLabel("New deterministic seed")
            }
          }
          .font(.system(size: 11.5, weight: .medium))
        }

        ExpandedStudioSection(
          title: "Watershed",
          systemImage: "mountain.2"
        ) {
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

        ExpandedStudioSection(
          title: "Flow",
          systemImage: "water.waves"
        ) {
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
    .font(.system(size: 11.5, weight: .medium))
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
    ExpandedStudioSlider(
      title: title,
      value: value,
      range: range,
      valueText: value.wrappedValue.formatted(
        .number.precision(.fractionLength(step < 0.1 ? 2 : 1))
      ) + suffix,
      step: step
    )
    .accessibilityLabel(title)
  }

  private func expandedSettingsFooter(showsQuality: Bool) -> some View {
    VStack(spacing: 10) {
      Divider().opacity(0.42)

      HStack(spacing: 12) {
        if showsQuality {
          Text("Quality")
            .font(.system(size: 11.5, weight: .medium))

          Picker("Quality", selection: expandedQualityBinding) {
            ForEach(ExpandedStudioQuality.allCases) { quality in
              Text(quality.title).tag(quality)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 270)
        }

        Spacer()

        HStack(spacing: 5) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("Changes save automatically and apply live")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
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
      ExpandedStudioSlider(
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
      ExpandedStudioSlider(
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
      ExpandedStudioSlider(
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
      ExpandedStudioSlider(
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

  private var selectedSaverSymbol: String {
    cameraSourceSelected
      ? "camera.fill"
      : model.configuration.creative.pattern.symbolName
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

  private var registrationPillLabel: String {
    switch model.registrationAssessment.location {
    case .currentBuild: "Current Extension Registered"
    case .differentCopy: "Stale Extension Registration"
    case .notRegistered: "Extension Not Registered"
    }
  }

  private var selectedPalettePair: (a: Color, b: Color) {
    switch model.configuration.appearance.palette.lowercased() {
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

private struct SaverChooserCard: View {
  let title: String
  let subtitle: String
  let symbol: String
  let colors: [Color]
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: 8)
          .fill(
            LinearGradient(
              colors: colors,
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ))
        Image(systemName: symbol)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.white.opacity(0.92))
          .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
      }
      .frame(height: 54)

      Text(title)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
      Text(subtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(6)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          isSelected ? Color.accentColor : Color.white.opacity(0.1),
          lineWidth: isSelected ? 1.5 : 0.5
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: 10))
  }
}

private struct SavedLookChooserCard: View {
  let savedLook: IdleScreenSavedLook

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 6)
        .fill(
          LinearGradient(
            colors: savedLook.snapshot.creative.pattern.galleryColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: 34, height: 28)
        .overlay {
          Image(
            systemName: savedLook.snapshot.source == .camera
              ? "camera.fill"
              : savedLook.snapshot.creative.pattern.symbolName
          )
          .font(.caption2.weight(.bold))
          .foregroundStyle(.white)
        }

      Text(savedLook.name)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
    }
    .contentShape(RoundedRectangle(cornerRadius: 9))
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

private struct ExpandedStudioSection<Content: View>: View {
  let title: String
  let systemImage: String
  private let content: Content

  init(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      content
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
    .background(
      Color.primary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
  }
}

private struct ExpandedStudioSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let valueText: String
  var step: Double? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
          .font(.system(size: 11.5, weight: .medium))
        Spacer()
        Text(valueText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Group {
        if let step {
          Slider(value: $value, in: range, step: step)
        } else {
          Slider(value: $value, in: range)
        }
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct CompactStudioSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var suffix = ""

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize()
      Slider(value: $value, in: range)
        .controlSize(.mini)
        .frame(width: 64)
      if !suffix.isEmpty {
        Text(value.formatted(.number.precision(.fractionLength(0))) + suffix)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .fixedSize()
      }
    }
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
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(3)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.94))
    .foregroundStyle(.white)
  }
}

/// AppKit lifecycle adapter for the shared renderer. State publication is
/// deferred to the main actor so SwiftUI is never mutated during view creation.
@MainActor
private struct IdleScreenMetalViewHost: NSViewRepresentable {
  let configuration: IdleScreenRendererConfiguration
  let mode: IdleScreenRendererMode
  let cameraFrame: IdleScreenRendererCameraFrame?
  let cameraFrameRelay: IdleScreenRendererCameraFrameRelay?
  let elapsedTime: TimeInterval?
  let pointerLocationDidChange: ((CGPoint?) -> Void)?
  let status: IdleScreenMetalPreviewStatus

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
        configuration: configuration,
        mode: mode,
        automaticallyDraws: elapsedTime == nil
      )
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
    guard let renderer = context.coordinator.renderer else { return }
    renderer.update(configuration: configuration)
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
        .font(.caption2.monospacedDigit().weight(.semibold))
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
    .shadow(color: .black.opacity(0.48), radius: 22, y: 10)
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
    for assignment: DisplaySceneAssignment?
  ) -> IdleScreenRendererConfiguration {
    IdleScreenRendererConfigurationBridge.configuration(
      for: self,
      assignment: assignment
    )
  }
}

// MARK: - Components

struct StatusPill: View {
  var label: String
  var systemImage: String? = nil
  var tint: Color = .primary
  var body: some View {
    HStack(spacing: 6) {
      if let systemImage {
        Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
          .foregroundStyle(tint == .primary ? .green : tint)
      }
      Text(label).font(.system(size: 11, weight: .semibold)).fixedSize()
    }
    .padding(.horizontal, 11).padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
  }
}

struct LabeledSlider: View {
  var title: String
  @Binding var value: Double
  var body: some View {
    HStack(spacing: 7) {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
      Slider(value: $value).controlSize(.mini).frame(width: 80)
    }
  }
}

struct PalettePair: View {
  var a: Color, b: Color
  var body: some View {
    HStack(spacing: -4) {
      Circle().fill(a).frame(width: 12, height: 12)
      Circle().fill(b).frame(width: 12, height: 12)
    }
  }
}

#Preview {
  ContentView()
    .environment(IdleScreenAppModel())
    .environment(IdleScreenCompanionNavigation())
    .frame(width: 1040, height: 680)
}
