import AppKit
import IdleScreenCamera
import SwiftUI

// First-run setup, shown in the main window until it is finished. Steps follow Mouthtype's setup: step dots on top, one card for
// the current step, one short line each. The checkmarks come from live model state through `SetupProgress`, never from stored
// flags, so a step advances the moment macOS reports it done. Only "setup is finished" is stored.

/// Wires the model and the camera client into `SetupFlowContent`.
struct SetupFlowView: View {
  @Environment(IdleScreenAppModel.self) private var model
  @Environment(IdleScreenCompanionCameraClient.self) private var cameraClient
  /// Called when the user opens Studio from the last card, and when setup turns out to be done already.
  var onFinish: () -> Void
  var onLater: () -> Void

  @State private var cameraSkipped = false
  @State private var resolved = false

  private var inputs: SetupInputs {
    SetupInputs(
      registrationCurrent: model.registrationAssessment.isCurrentBuild,
      selectedEverywhere: model.selection?.isSelectedEverywhere == true,
      cameraAccess: Self.cameraAccess(cameraClient.readinessSnapshot.authorization),
      cameraSkipped: cameraSkipped
    )
  }

  static func cameraAccess(_ observation: CameraAgentAuthorizationObservation) -> SetupCameraAccess
  {
    switch observation {
    case .unknown: .unknown
    case .observed(.notDetermined): .notDetermined
    case .observed(.authorized): .authorized
    case .observed(.denied), .observed(.restricted): .blocked
    }
  }

  var body: some View {
    let progress = SetupProgress(inputs)
    Group {
      if resolved {
        SetupFlowContent(
          progress: progress,
          cameraAccess: inputs.cameraAccess,
          isRegistering: model.isRegistering,
          statusMessage: model.saverActionStatus,
          errorMessage: model.lastError,
          actions: SetupFlowActions(
            register: { model.registerExtension() },
            openScreenSaverSettings: { model.openScreenSaverSettings() },
            allowCamera: { cameraClient.performRecommendedRepair() },
            skipCamera: { cameraSkipped = true },
            openStudio: onFinish,
            later: onLater
          )
        )
      } else {
        DesignPalette.bg.overlay {
          Text("Checking your Mac…").font(DesignFont.sans(DesignFont.body))
            .foregroundStyle(DesignPalette.ink2)
        }
      }
    }
    .onAppear { model.refresh() }
    .onChange(of: model.hasFreshSaverStatus, initial: true) { resolveIfReady() }
    .onChange(of: model.lastError) { resolveIfReady() }
    .onChange(of: progress.current) { _, current in
      if current == .camera {
        cameraClient.cameraDiagnosticsDidAppear()
      } else {
        cameraClient.cameraDiagnosticsDidDisappear()
      }
    }
    .onDisappear { cameraClient.cameraDiagnosticsDidDisappear() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      model.refresh()
    }
  }

  /// The first answer from macOS decides whether this is a first run. A Mac that is already registered and selected has nothing
  /// to set up, so setup finishes without showing itself.
  private func resolveIfReady() {
    guard !resolved, model.hasFreshSaverStatus || model.lastError != nil else { return }
    resolved = true
    if SetupProgress(inputs).requiredStepsDone { onFinish() }
  }
}

struct SetupFlowActions {
  var register: () -> Void = {}
  var openScreenSaverSettings: () -> Void = {}
  var allowCamera: () -> Void = {}
  var skipCamera: () -> Void = {}
  var openStudio: () -> Void = {}
  var later: () -> Void = {}
}

/// The setup screen, drawn from plain values so it renders without a model.
struct SetupFlowContent: View {
  let progress: SetupProgress
  var cameraAccess: SetupCameraAccess = .unknown
  var isRegistering = false
  var statusMessage: String?
  var errorMessage: String?
  var actions = SetupFlowActions()

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollView {
      VStack(spacing: DesignMetrics.sectionSpacing) {
        SetupStepDots(progress: progress)
        card
          .id(progress.current?.rawValue ?? -1)
          .transition(reduceMotion ? .identity : .opacity)
        if let errorMessage, !errorMessage.isEmpty {
          DesignNotice(kind: .error, text: errorMessage)
        }
        stepList
        if !progress.isComplete {
          Button("Set up later", action: actions.later).buttonStyle(.plain)
            .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
            .accessibilityHint("Closes setup. You can finish it from Studio.")
        }
      }
      .frame(maxWidth: 460)
      .padding(.horizontal, DesignMetrics.pageSideMargin)
      .padding(.top, DesignMetrics.pageTopMargin)
      .padding(.bottom, DesignMetrics.pageBottomMargin)
      .frame(maxWidth: .infinity)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: progress.current)
    }
    .background(DesignPalette.bg)
  }

  // MARK: Current step

  private var card: some View {
    VStack(spacing: 10) {
      Text(title).font(DesignFont.headlineFont()).foregroundStyle(DesignPalette.ink)
        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
      Text(detail).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
        .fixedSize(horizontal: false, vertical: true)
      controls.padding(.top, 6)
      if let message = visibleStatusMessage {
        Text(message).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(caption).designEyebrow().padding(.top, 4).accessibilityHidden(true)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, 28).padding(.vertical, 28)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous).fill(
        DesignPalette.surface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
        .strokeBorder(DesignPalette.hair2, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }

  private var title: String {
    switch progress.current {
    case .register: "Register IdleScreen"
    case .choose: "Choose IdleScreen"
    case .camera: "Add your camera"
    case nil: "You're all set"
    }
  }

  private var detail: String {
    switch progress.current {
    case .register: "Tell macOS that IdleScreen is here. It only takes a moment."
    case .choose: "Pick IdleScreen as your screen saver in Screen Saver settings."
    case .camera:
      switch cameraAccess {
      case .blocked:
        "Camera access is off. Turn it on in Privacy & Security, or skip this for now."
      default:
        "Optional. Some looks react to you. The camera is processed on this Mac and never leaves it."
      }
    case nil: "IdleScreen is ready. Pick a look in Studio."
    }
  }

  @ViewBuilder private var controls: some View {
    switch progress.current {
    case .register:
      Button(isRegistering ? "Registering…" : "Register IdleScreen", action: actions.register)
        .buttonStyle(.designPrimary).disabled(isRegistering)
        .accessibilityHint("Tells macOS that IdleScreen is installed.")
    case .choose:
      Button("Open Screen Saver settings", action: actions.openScreenSaverSettings)
        .buttonStyle(.designPrimary)
        .accessibilityHint("Opens macOS settings so you can pick IdleScreen.")
    case .camera:
      HStack(spacing: 8) {
        Button(
          cameraAccess == .blocked ? "Open camera privacy" : "Allow camera",
          action: actions.allowCamera
        )
        .buttonStyle(.designPrimary)
        .accessibilityHint(
          cameraAccess == .blocked
            ? "Opens camera privacy settings." : "Asks macOS for camera access.")
        Button("Skip for now", action: actions.skipCamera).buttonStyle(.designSecondary)
          .accessibilityHint("Skips the camera step. You can turn it on later in System.")
      }
    case nil:
      Button("Open Studio", action: actions.openStudio).buttonStyle(.designPrimary)
        .keyboardShortcut(.defaultAction)
    }
  }

  private var caption: String {
    guard let current = progress.current else { return "Setup complete" }
    return "Step \(current.rawValue + 1) of \(SetupStep.allCases.count)"
  }

  /// The model's last action message, in the app's name. Shown under the step it belongs to.
  private var visibleStatusMessage: String? {
    guard let statusMessage, !statusMessage.isEmpty, progress.current != nil else { return nil }
    return statusMessage.replacingOccurrences(of: "idlescreen", with: "IdleScreen")
  }

  // MARK: Step list

  private var stepList: some View {
    DesignSection(eyebrow: "Steps") {
      ForEach(SetupStep.allCases) { step in
        DesignRow(title: Self.name(step), detail: Self.summary(step)) {
          let status = progress.status(step)
          if step == .camera, status == .current, cameraAccess == .blocked {
            DesignStatus(kind: .attention, text: "Blocked")
          } else {
            DesignStatus(kind: Self.kind(status), text: Self.word(status))
          }
        }
      }
    }
  }

  static func name(_ step: SetupStep) -> String {
    switch step {
    case .register: "Register"
    case .choose: "Choose IdleScreen"
    case .camera: "Camera (optional)"
    }
  }

  static func summary(_ step: SetupStep) -> String {
    switch step {
    case .register: "Lets macOS find IdleScreen."
    case .choose: "Makes it your screen saver."
    case .camera: "Lets looks react to you."
    }
  }

  static func word(_ status: SetupStepStatus) -> String {
    switch status {
    case .done: "Done"
    case .current: "Up next"
    case .upcoming: "Waiting"
    case .skipped: "Skipped"
    }
  }

  static func kind(_ status: SetupStepStatus) -> DesignStatusKind {
    switch status {
    case .done: .ok
    case .current: .current
    case .upcoming, .skipped: .neutral
    }
  }
}

/// One dot per step. The current step is a wide accent pill, finished steps are solid, the rest are quiet.
struct SetupStepDots: View {
  let progress: SetupProgress

  var body: some View {
    HStack(spacing: 6) {
      ForEach(SetupStep.allCases) { step in
        let status = progress.status(step)
        Capsule().fill(fill(status)).frame(width: status == .current ? 18 : 5, height: 5)
          .overlay {
            if status == .current {
              Capsule().strokeBorder(DesignPalette.accentMark, lineWidth: 1)
            }
          }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
  }

  private var label: String {
    if let current = progress.current {
      return "Step \(current.rawValue + 1) of \(SetupStep.allCases.count)"
    }
    return "Setup complete"
  }

  private func fill(_ status: SetupStepStatus) -> Color {
    switch status {
    case .current: DesignPalette.accent
    case .done: DesignPalette.success
    case .upcoming, .skipped: DesignPalette.track
    }
  }
}
