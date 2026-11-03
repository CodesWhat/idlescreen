import AppKit
import IdleScreenCamera
import IdleScreenRenderer
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

  @Environment(IdleScreenCompanionNavigation.self) private var navigation

  private var session: SetupSession { navigation.setupSession }

  /// What macOS reports right now, stale or not.
  private var liveInputs: SetupInputs {
    SetupInputs(
      registrationCurrent: model.registrationAssessment.isCurrentBuild,
      selectedEverywhere: model.selection?.isSelectedEverywhere == true,
      cameraAccess: Self.cameraAccess(cameraClient.readinessSnapshot.authorization),
      cameraSkipped: session.cameraSkipped
    )
  }

  /// What setup draws from: the live facts while fresh, the last fresh ones while a refresh is in flight or has failed.
  private var inputs: SetupInputs {
    SetupInputs.settled(
      live: liveInputs, lastFresh: session.lastFreshInputs, isFresh: model.hasFreshSaverStatus)
  }

  static func cameraAccess(_ observation: CameraAgentAuthorizationObservation) -> SetupCameraAccess
  {
    switch observation {
    case .unknown: .unknown
    case .observed(.notDetermined): .notDetermined
    case .observed(.authorized): .authorized
    case .observed(.denied): .blocked
    case .observed(.restricted): .restricted
    }
  }

  private var decision: SetupGateDecision {
    SetupGate.decide(
      session: session,
      hasFreshStatus: model.hasFreshSaverStatus,
      hasError: model.lastError != nil,
      requiredStepsDone: SetupProgress(inputs).requiredStepsDone,
      isRefreshing: model.isRefreshing
    )
  }

  var body: some View {
    let progress = SetupProgress(inputs)
    Group {
      if decision.showsFlow {
        SetupFlowContent(
          progress: progress,
          cameraAccess: inputs.cameraAccess,
          isRegistering: model.isRegistering,
          extensionMissing: !model.isExtensionEmbedded,
          statusMessage: model.saverActionStatus,
          errorMessage: model.lastError,
          actions: SetupFlowActions(
            register: { model.registerExtension() },
            openScreenSaverSettings: { model.openScreenSaverSettings() },
            allowCamera: { cameraClient.performSetupCameraAction() },
            skipCamera: { navigation.setupSession.skipCamera() },
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
    .onChange(of: model.hasFreshSaverStatus, initial: true) { settleSession() }
    .onChange(of: model.lastError) { settleSession() }
    .onChange(of: liveInputs) { settleSession() }
    .onChange(of: progress.current, initial: true) { _, current in
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

  /// Records the last fresh answer and runs the upgrade auto-skip once, on the first fresh status. A Mac that is already
  /// registered and selected has nothing to set up, so setup finishes without showing itself. Nothing else finishes setup
  /// for the user; the done card's "Open Studio" does the rest.
  private func settleSession() {
    navigation.setupSession.record(live: liveInputs, isFresh: model.hasFreshSaverStatus)
    let decision = decision
    guard decision.evaluatesAutoSkip else { return }
    navigation.setupSession.apply(decision)
    if decision.finishesSetup { onFinish() }
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

/// What the current step's card says and offers, from plain values so tests can assert it without drawing pixels.
struct SetupCardModel: Equatable {
  let title: String
  let detail: String
  let caption: String
  let primaryTitle: String
  let primaryEnabled: Bool
  let offersSkip: Bool
  let offersLater: Bool

  init(
    progress: SetupProgress, cameraAccess: SetupCameraAccess, isRegistering: Bool,
    extensionMissing: Bool = false
  ) {
    switch progress.current {
    case .register:
      title = "Register IdleScreen"
      detail =
        extensionMissing
        ? "This copy of IdleScreen is missing its screen saver. Reinstall IdleScreen."
        : "Tell macOS that IdleScreen is here. It only takes a moment."
      primaryTitle = isRegistering ? "Registering…" : "Register IdleScreen"
      primaryEnabled = !isRegistering && !extensionMissing
    case .choose:
      title = "Choose IdleScreen"
      detail = "Pick IdleScreen as your screen saver in Screen Saver settings."
      primaryTitle = "Open Screen Saver settings"
      primaryEnabled = true
    case .camera:
      title = "Add your camera"
      let optional =
        "Optional. Some looks react to you. The camera is processed on this Mac and never leaves it."
      switch cameraAccess {
      case .blocked:
        detail = "Camera access is off. Turn it on in Privacy & Security, or skip this for now."
        primaryTitle = "Open camera privacy"
        primaryEnabled = true
      case .restricted:
        detail =
          "A policy on this Mac blocks the camera. Ask whoever manages it, or skip this for now."
        primaryTitle = "Camera restricted"
        primaryEnabled = false
      case .unknown:
        detail = optional
        primaryTitle = "Checking camera…"
        primaryEnabled = false
      case .notDetermined, .authorized:
        detail = optional
        primaryTitle = "Allow camera"
        primaryEnabled = true
      }
    case nil:
      title = "You're all set"
      detail = "IdleScreen is ready. Pick a look in Studio."
      primaryTitle = "Open Studio"
      primaryEnabled = true
    }
    if let current = progress.current {
      caption = "Step \(current.rawValue + 1) of \(SetupStep.allCases.count)"
    } else {
      caption = "Setup complete"
    }
    offersSkip = progress.current == .camera
    offersLater = !progress.isComplete
  }
}

/// The setup screen, drawn from plain values so it renders without a model.
struct SetupFlowContent: View {
  let progress: SetupProgress
  var cameraAccess: SetupCameraAccess = .unknown
  var isRegistering = false
  var extensionMissing = false
  var statusMessage: String?
  var errorMessage: String?
  var actions = SetupFlowActions()

  private var cardModel: SetupCardModel {
    SetupCardModel(
      progress: progress, cameraAccess: cameraAccess, isRegistering: isRegistering,
      extensionMissing: extensionMissing)
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Below this width the preview drops away and the steps stack in one column.
  static let twoColumnMinWidth: CGFloat = 900
  static let leadingColumnRange: ClosedRange<CGFloat> = 420...560

  var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= Self.twoColumnMinWidth
      ScrollView {
        Group {
          if wide {
            HStack(alignment: .center, spacing: 40) {
              stepsColumn
                .frame(width: Self.leadingColumnWidth(in: geometry.size.width))
              SetupPreviewPane(reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, DesignMetrics.pageBottomMargin + 8)
            .frame(minHeight: geometry.size.height)
          } else {
            stepsColumn
              .frame(maxWidth: 460)
              .padding(.horizontal, DesignMetrics.pageSideMargin)
              .padding(.top, DesignMetrics.pageTopMargin)
              .padding(.bottom, DesignMetrics.pageBottomMargin)
              .frame(maxWidth: .infinity)
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: progress.current)
      }
    }
    .background(DesignPalette.bg)
  }

  /// The left column is about 38% of the window, held between 420 and 560 pt.
  static func leadingColumnWidth(in width: CGFloat) -> CGFloat {
    min(leadingColumnRange.upperBound, max(leadingColumnRange.lowerBound, width * 0.38))
  }

  private var stepsColumn: some View {
    VStack(spacing: DesignMetrics.sectionSpacing) {
      SetupStepDots(progress: progress)
      card
        .id(progress.current?.rawValue ?? -1)
        .transition(reduceMotion ? .identity : .opacity)
      if let errorMessage, !errorMessage.isEmpty {
        DesignNotice(kind: .error, text: errorMessage)
      }
      stepList
      if cardModel.offersLater {
        Button("Set up later", action: actions.later).buttonStyle(.plain)
          .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
          .accessibilityHint(
            "Closes setup for now. Studio keeps a Continue setup button until you finish.")
      }
    }
  }

  // MARK: Current step

  private var card: some View {
    VStack(spacing: 10) {
      Text(cardModel.title).font(DesignFont.headlineFont()).foregroundStyle(DesignPalette.ink)
        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
      Text(cardModel.detail).font(DesignFont.sans(DesignFont.body)).foregroundStyle(
        DesignPalette.ink2
      )
      .fixedSize(horizontal: false, vertical: true)
      controls.padding(.top, 6)
      if let message = visibleStatusMessage {
        Text(message).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(cardModel.caption).designEyebrow().padding(.top, 4).accessibilityHidden(true)
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

  @ViewBuilder private var controls: some View {
    switch progress.current {
    case .register:
      Button(cardModel.primaryTitle, action: actions.register)
        .buttonStyle(.designPrimary).disabled(!cardModel.primaryEnabled)
        .accessibilityHint("Tells macOS that IdleScreen is installed.")
    case .choose:
      Button(cardModel.primaryTitle, action: actions.openScreenSaverSettings)
        .buttonStyle(.designPrimary)
        .accessibilityHint("Opens macOS settings so you can pick IdleScreen.")
    case .camera:
      HStack(spacing: 8) {
        Button(cardModel.primaryTitle, action: actions.allowCamera)
          .buttonStyle(.designPrimary).disabled(!cardModel.primaryEnabled)
          .accessibilityHint(cameraHint)
        Button("Skip for now", action: actions.skipCamera).buttonStyle(.designSecondary)
          .accessibilityHint("Skips the camera step. You can turn it on later in Status.")
      }
    case nil:
      Button(cardModel.primaryTitle, action: actions.openStudio).buttonStyle(.designPrimary)
        .keyboardShortcut(.defaultAction)
    }
  }

  private var cameraHint: String {
    switch cameraAccess {
    case .blocked: "Opens camera privacy settings."
    case .restricted: "Camera access is restricted by a policy on this Mac."
    case .unknown: "Waiting for macOS to report camera access."
    case .notDetermined, .authorized: "Asks macOS for camera access."
    }
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
          } else if step == .camera, status == .current, cameraAccess == .restricted {
            DesignStatus(kind: .attention, text: "Restricted")
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

/// The live screen saver beside the setup steps: the same renderer view Studio's canvas hosts, on the procedural default look
/// with no camera. Reduce Motion holds one still frame instead of animating.
struct SetupPreviewPane: View {
  var reduceMotion = false
  var caption = "This is IdleScreen."

  var body: some View {
    VStack(spacing: 12) {
      IdleScreenMetalPreview(
        configuration: .default,
        mode: .generative,
        cameraFrame: nil,
        elapsedTime: reduceMotion ? Self.stillFrameTime : nil
      )
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .background(Color.black)
      .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
          .strokeBorder(DesignPalette.hair2, lineWidth: 1)
      )
      .accessibilityHidden(true)
      Text(caption).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
    }
  }

  /// Seconds into the scene for the Reduce Motion still frame, far enough in that the pattern has formed.
  static let stillFrameTime: TimeInterval = 6
}
