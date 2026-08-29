import AppKit
import IdleScreenCamera
import IdleScreenDisplay
import IdleScreenSystem
import OSLog
import ServiceManagement
import SwiftUI

private struct IdleScreenCameraAgentRebindResult: Codable {
  let status: String
  let companionProcessIdentifier: Int32
  let previousHelperProcessIdentifier: Int32?
  let helperProcessIdentifier: Int32?
  let helperProcessEpoch: UInt64?
  let helperBundleVersion: String?
  let helperSourceAppPath: String?
  let helperCodeDirectoryHash: String?
  let failureMessage: String?
}

@MainActor
final class IdleScreenAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let logger = Logger(subsystem: "com.idlescreen.app", category: "WindowLifecycle")
  private var mainWindow: NSWindow?
  private var mainWindowIsEnteringFullScreen = false
  private let navigation = IdleScreenCompanionNavigation()
  private let displayCoordinator = DisplaySceneCoordinator.shared
  private var displayHostToken: DisplaySceneHostToken?
  private lazy var cameraClient = Self.makeCameraClient(
    navigation: navigation
  )

  override init() {
    super.init()
    logger.info("App delegate initialized")
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    logger.info("Application did finish launching")
    // Construction performs one read-only SMAppService status observation.
    // It does not connect XPC, bootstrap preview, register, prompt, or open UI.
    _ = cameraClient
    let arguments = ProcessInfo.processInfo.arguments
    let showsMainWindow = IdleScreenLaunchPolicy.shouldShowMainWindow(arguments: arguments)
    // Decided once, before anything opens: settling the policy here and not
    // per-branch keeps a normal launch from flipping .regular twice, which
    // flickers the Dock tile.
    applyDockPresentation(showsMainWindow: showsMainWindow)
    let backgroundProbe = IdleScreenLaunchPolicy.backgroundProbe(arguments: arguments)
    if case .cameraAgentRebind(let resultPath, let previousProcessIdentifier) =
      backgroundProbe
    {
      logger.info("Starting hidden camera-agent upgrade rebind")
      performCameraAgentUpgradeRebind(
        resultPath: resultPath,
        previousProcessIdentifier: previousProcessIdentifier
      )
      return
    }
    guard showsMainWindow else {
      logger.info("Background lifecycle probe will not activate or reveal the main window")
      if case .configurationContrast(let contrast) = backgroundProbe {
        logger.info("Applying background configuration delivery probe")
        IdleScreenAppModel.shared.updateContrast(contrast)
      }
      return
    }
    showMainWindow()
  }

  private func performCameraAgentUpgradeRebind(
    resultPath: String,
    previousProcessIdentifier: Int32?
  ) {
    cameraClient.rebindCameraAgentForInstalledUpgrade(
      previousProcessIdentifier: previousProcessIdentifier
    ) { [weak self] receipt, failureMessage in
      guard let self else { return }
      let result = IdleScreenCameraAgentRebindResult(
        status: receipt == nil ? "failed" : "verified",
        companionProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        previousHelperProcessIdentifier:
          receipt?.previousProcessIdentifier
          ?? previousProcessIdentifier,
        helperProcessIdentifier: receipt?.processIdentifier,
        helperProcessEpoch: receipt?.processEpoch,
        helperBundleVersion: receipt?.bundleVersion,
        helperSourceAppPath: receipt?.sourceAppPath,
        helperCodeDirectoryHash: receipt?.codeDirectoryHash,
        failureMessage: failureMessage
      )
      do {
        let resultURL = URL(fileURLWithPath: resultPath)
        guard !FileManager.default.fileExists(atPath: resultURL.path) else {
          throw CocoaError(.fileWriteFileExists)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(result).write(to: resultURL, options: .atomic)
        self.logger.info(
          "Camera-agent upgrade rebind finished status=\(result.status, privacy: .public)"
        )
      } catch {
        self.logger.error(
          "Could not write camera-agent rebind result: \(error.localizedDescription, privacy: .public)"
        )
      }
      DispatchQueue.main.async {
        NSApp.terminate(nil)
      }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showMainWindow()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    updateMainWindowPresentationState()
  }

  func applicationDidResignActive(_ notification: Notification) {
    cameraClient.mainWindowPresentationDidChange(isActive: false)
  }

  func applicationWillTerminate(_ notification: Notification) {
    detachDisplayHost()
  }

  func applicationDidChangeScreenParameters(_ notification: Notification) {
    guard let mainWindow,
      !mainWindowIsEnteringFullScreen,
      !mainWindow.styleMask.contains(.fullScreen)
    else {
      return
    }
    scheduleScreenAspectRatioNormalization(for: mainWindow)
  }

  func showMainWindow() {
    logger.info("showMainWindow requested existing=\(self.mainWindow != nil, privacy: .public)")
    // Ordered before activation: an .accessory app cannot take key focus.
    applyDockPresentation(showsMainWindow: true)
    NSApp.activate(ignoringOtherApps: true)
    attachDisplayHostIfNeeded()
    if let mainWindow {
      mainWindow.makeKeyAndOrderFront(nil)
      cameraClient.mainWindowDidOpen()
      updateMainWindowPresentationState()
      return
    }

    let rootView = ContentView()
      .environment(IdleScreenAppModel.shared)
      .environment(cameraClient)
      .environment(navigation)
      .environment(displayCoordinator)
      .frame(minWidth: 900, minHeight: 600)
      .preferredColorScheme(.dark)
    let hostingController = NSHostingController(rootView: rootView)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "idlescreen"
    window.identifier = NSUserInterfaceItemIdentifier("main")
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unifiedCompact
    window.contentViewController = hostingController
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("IdleScreenMainWindow")
    applyScreenAspectRatio(to: window)
    mainWindow = window
    window.makeKeyAndOrderFront(nil)
    cameraClient.mainWindowDidOpen()
    updateMainWindowPresentationState()
    logger.info(
      "Main window ordered visible=\(window.isVisible, privacy: .public) windows=\(NSApp.windows.count, privacy: .public)"
    )
  }

  func showStudio() {
    navigation.destination = .studio
    showMainWindow()
  }

  func showDiagnostics() {
    navigation.showCameraDiagnostics()
    showMainWindow()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    cameraClient.mainWindowWillClose()
    return true
  }

  func windowWillClose(_ notification: Notification) {
    // Keep this second, idempotent edge: AppKit can bypass
    // `windowShouldClose` during process-driven teardown.
    cameraClient.mainWindowWillClose()
    detachDisplayHost()
    guard let window = notification.object as? NSWindow,
      window === mainWindow
    else { return }
    // AppKit does not deliver windowDidExitFullScreen to a window that closes
    // out of full screen, and the window is reused, so leaving the latch set
    // disables every later resize and screen-change normalization.
    mainWindowIsEnteringFullScreen = false
    // Deferred on purpose: changing the process type inside the close, and
    // inside a full-screen Space teardown, is what strands the Space. The next
    // turn also never arrives during NSApp.terminate, so quitting no longer
    // pops the tile on the way out.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.mainWindow else { return }
      // isVisible is false for a miniaturized window, so both are required:
      // an accessory app loses the minimized tile too, stranding the window.
      guard !window.isVisible, !window.isMiniaturized else { return }
      self.applyDockPresentation(showsMainWindow: false)
    }
  }

  private func applyDockPresentation(showsMainWindow: Bool) {
    let policy = IdleScreenDockPresentation.activationPolicy(
      showsMainWindow: showsMainWindow
    )
    guard NSApp.activationPolicy() != policy else { return }
    guard NSApp.setActivationPolicy(policy) else {
      // A refused .regular transition leaves the app with no Dock tile and no
      // menu bar, so the window opens non-key and the camera preview never
      // starts. The guard above re-attempts it on the next call.
      logger.error(
        "Dock presentation refused showsMainWindow=\(showsMainWindow, privacy: .public)"
      )
      return
    }
    logger.info("Dock presentation set showsMainWindow=\(showsMainWindow, privacy: .public)")
  }

  func windowDidChangeOcclusionState(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window === mainWindow
    else { return }
    updateMainWindowPresentationState()
  }

  func windowDidMiniaturize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window === mainWindow
    else { return }
    updateMainWindowPresentationState()
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window === mainWindow
    else { return }
    updateMainWindowPresentationState()
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard sender === mainWindow,
      !mainWindowIsEnteringFullScreen,
      !sender.styleMask.contains(.fullScreen),
      let screen = sender.screen ?? NSScreen.main,
      screen.frame.width > 0,
      screen.frame.height > 0
    else {
      return frameSize
    }

    let proposedContentSize = sender.contentRect(
      forFrameRect: NSRect(origin: .zero, size: frameSize)
    ).size
    let currentContentSize = sender.contentRect(
      forFrameRect: sender.frame
    ).size
    let aspectRatio = screen.frame.width / screen.frame.height
    let constrainedContentSize = Self.constrainedPreviewContentSize(
      proposed: proposedContentSize,
      current: currentContentSize,
      previewAspectRatio: aspectRatio
    )
    return sender.frameRect(
      forContentRect: NSRect(origin: .zero, size: constrainedContentSize)
    ).size
  }

  func windowDidChangeScreen(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window === mainWindow,
      !mainWindowIsEnteringFullScreen,
      !window.styleMask.contains(.fullScreen)
    else {
      return
    }
    scheduleScreenAspectRatioNormalization(for: window)
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window === mainWindow
    else {
      return
    }
    mainWindowIsEnteringFullScreen = true
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window === mainWindow
    else {
      return
    }
    mainWindowIsEnteringFullScreen = false
    scheduleScreenAspectRatioNormalization(for: window)
  }

  func windowDidFailToEnterFullScreen(_ window: NSWindow) {
    guard window === mainWindow else { return }
    mainWindowIsEnteringFullScreen = false
    scheduleScreenAspectRatioNormalization(for: window)
  }

  func windowDidFailToExitFullScreen(_ window: NSWindow) {
    guard window === mainWindow else { return }
    mainWindowIsEnteringFullScreen = true
  }

  private func updateMainWindowPresentationState() {
    guard let mainWindow else {
      cameraClient.mainWindowPresentationDidChange(isActive: false)
      return
    }
    let isPresented =
      NSApp.isActive
      && !NSApp.isHidden
      && mainWindow.isVisible
      && !mainWindow.isMiniaturized
      && mainWindow.occlusionState.contains(.visible)
    cameraClient.mainWindowPresentationDidChange(isActive: isPresented)
  }

  private func attachDisplayHostIfNeeded() {
    guard displayHostToken == nil else { return }
    let configuration = IdleScreenAppModel.shared.configuration
    displayHostToken = displayCoordinator.attach(
      settings: configuration.display,
      configurationRevision: configuration.revision
    )
  }

  private func detachDisplayHost() {
    guard let displayHostToken else { return }
    displayCoordinator.detach(displayHostToken)
    self.displayHostToken = nil
  }

  private func scheduleScreenAspectRatioNormalization(for window: NSWindow) {
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self,
        let window,
        window === self.mainWindow,
        !self.mainWindowIsEnteringFullScreen,
        !window.styleMask.contains(.fullScreen)
      else {
        return
      }
      self.applyScreenAspectRatio(to: window)
    }
  }

  private func applyScreenAspectRatio(to window: NSWindow) {
    guard let screen = window.screen ?? NSScreen.main,
      screen.frame.width > 0,
      screen.frame.height > 0
    else {
      return
    }

    let aspectRatio = screen.frame.width / screen.frame.height
    navigation.displayAspectRatio = aspectRatio
    window.contentAspectRatio = .zero

    let minimumContentSize = Self.minimumContentSize(for: aspectRatio)
    window.contentMinSize = minimumContentSize
    window.minSize =
      window.frameRect(
        forContentRect: NSRect(origin: .zero, size: minimumContentSize)
      ).size

    let currentContentSize = window.contentRect(forFrameRect: window.frame)
      .size
    var targetContentSize =
      IdleScreenPreviewWindowGeometry
      .normalizedContentSize(
        current: currentContentSize,
        previewAspectRatio: aspectRatio
      )
    let targetFrameSize = window.frameRect(
      forContentRect: NSRect(origin: .zero, size: targetContentSize)
    ).size
    let scale = min(
      1,
      screen.visibleFrame.width / targetFrameSize.width,
      screen.visibleFrame.height / targetFrameSize.height
    )
    if scale < 1,
      targetContentSize.width * scale >= minimumContentSize.width,
      targetContentSize.height * scale >= minimumContentSize.height
    {
      targetContentSize =
        IdleScreenPreviewWindowGeometry
        .normalizedContentSize(
          current: CGSize(
            width: targetContentSize.width * scale,
            height: targetContentSize.height * scale
          ),
          previewAspectRatio: aspectRatio
        )
    }
    window.setContentSize(targetContentSize)

    logger.info(
      "Main window aspect locked to screen ratio \(aspectRatio, privacy: .public)"
    )
  }

  private static func minimumContentSize(for aspectRatio: CGFloat) -> NSSize {
    IdleScreenPreviewWindowGeometry.minimumContentSize(
      previewAspectRatio: aspectRatio
    )
  }

  static func constrainedPreviewContentSize(
    proposed: CGSize,
    current: CGSize,
    previewAspectRatio: CGFloat
  ) -> CGSize {
    IdleScreenPreviewWindowGeometry.constrainedContentSize(
      proposed: proposed,
      current: current,
      previewAspectRatio: previewAspectRatio
    )
  }

  private static func makeCameraClient(
    navigation: IdleScreenCompanionNavigation
  ) -> IdleScreenCompanionCameraClient {
    let infoDictionary = Bundle.main.infoDictionary ?? [:]
    let serviceIdentity = (infoDictionary[CameraClientBootstrap.appGroupInfoKey] as? String).flatMap
    { appGroupIdentifier in
      try? CameraAgentServiceIdentity(
        appGroupIdentifier: appGroupIdentifier
      )
    }
    let registrationClient = serviceIdentity.map { identity in
      CameraAgentRegistrationClient(identity: identity)
    }
    let identityCollector = {
      guard let serviceIdentity,
        let teamIdentifier =
          infoDictionary[CameraClientBootstrap.teamIdentifierInfoKey] as? String,
        let configuration = try? CameraAgentIdentityCollectorConfiguration(
          containingApplicationURL: Bundle.main.bundleURL,
          serviceIdentity: serviceIdentity,
          expectedTeamIdentifier: teamIdentifier
        )
      else {
        return nil as CameraAgentIdentityCollector?
      }
      return CameraAgentIdentityCollector(configuration: configuration)
    }()

    let controlClient = {
      guard
        let machServiceName =
          infoDictionary[CameraClientBootstrap.machServiceInfoKey] as? String,
        let teamIdentifier =
          infoDictionary[CameraClientBootstrap.teamIdentifierInfoKey] as? String,
        let configuration = CameraAgentXPCClientConfiguration(
          machServiceName: machServiceName,
          expectedTeamIdentifier: teamIdentifier
        )
      else {
        return nil as CameraAgentControlClient?
      }
      return CameraAgentControlClient(configuration: configuration)
    }()

    return IdleScreenCompanionCameraClient(
      infoDictionary: infoDictionary,
      effects: IdleScreenCompanionCameraEffects(
        readServiceRegistration: {
          guard let registrationClient else { return .failed }
          return cameraRegistration(
            from: registrationClient.refresh()
          )
        },
        registerAgent: {
          guard let registrationClient else { return .failed }
          return cameraRegistration(
            from: registrationClient.register()
          )
        },
        replaceAgent: { completion in
          guard let registrationClient else {
            completion(
              .failed(
                "The installed app is missing its camera-agent registration configuration."
              ))
            return
          }
          registrationClient.replace { outcome in
            Task { @MainActor in
              completion(cameraReplacement(from: outcome))
            }
          }
        },
        openRepairSurface: { surface in
          switch surface {
          case .backgroundItemsSettings:
            SMAppService.openSystemSettingsLoginItems()
            return true
          case .cameraPrivacySettings:
            guard
              let url = URL(
                string:
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
              )
            else { return false }
            return NSWorkspace.shared.open(url)
          case .cameraAgentDiagnostics:
            navigation.showCameraDiagnostics()
            return true
          }
        },
        bootstrapPreview: { infoDictionary in
          let result = CameraClientBootstrap.makeRuntime(
            infoDictionary: infoDictionary
          )
          return IdleScreenCompanionCameraBootstrap(
            status: result.status,
            runtime: result.runtime
          )
        },
        assessAgentIdentity: { identity, remoteProcessIdentifier in
          let generationIdentifier = cameraAgentGenerationIdentifier(
            identity
          )
          guard let registrationClient else {
            return IdleScreenCompanionCameraIdentityAssessment(
              observation: .unknown,
              generationIdentifier: generationIdentifier,
              serviceRegistration: .failed
            )
          }
          let registrationState = cameraRegistrationState(
            from: registrationClient.refresh()
          )
          let serviceRegistration = cameraRegistration(
            from: registrationState
          )
          guard
            identity.matches(
              remoteProcessIdentifier: remoteProcessIdentifier
            )
          else {
            return IdleScreenCompanionCameraIdentityAssessment(
              observation: .mismatched,
              generationIdentifier: generationIdentifier,
              serviceRegistration: serviceRegistration
            )
          }
          guard let identityCollector else {
            return IdleScreenCompanionCameraIdentityAssessment(
              observation: .unknown,
              generationIdentifier: generationIdentifier,
              serviceRegistration: serviceRegistration
            )
          }

          let helperBundleURL = URL(
            fileURLWithPath: identity.sourceAppPath,
            isDirectory: true
          ).appendingPathComponent(
            "Contents/Helpers/IdleScreenCameraAgent.app",
            isDirectory: true
          ).resolvingSymlinksInPath().standardizedFileURL
          guard
            let fingerprint = try? CameraAgentArtifactFingerprint(
              canonicalBundlePath: helperBundleURL.path,
              serviceIdentifier: identity.serviceIdentifier,
              bundleIdentifier: identity.bundleIdentifier,
              bundleVersion: identity.bundleVersion,
              marketingVersion: identity.marketingVersion,
              signingIdentifier: identity.signingIdentifier,
              teamIdentifier: identity.teamIdentifier,
              codeDirectoryHash: identity.codeDirectoryHash,
              executableSHA256: identity.executableSHA256,
              launchAgentSHA256: identity.launchAgentSHA256,
              provisioningProfileSHA256: identity.provisioningProfileSHA256
            ),
            let liveEvidence = try? CameraAgentAuthenticatedLiveIdentityEvidence(
              processIdentifier: identity.processIdentifier,
              authenticatedControlProcessIdentifier: remoteProcessIdentifier,
              processEpoch: identity.processIncarnationEpoch,
              bundleURL: helperBundleURL,
              fingerprint: fingerprint
            )
          else {
            return IdleScreenCompanionCameraIdentityAssessment(
              observation: .mismatched,
              generationIdentifier: generationIdentifier,
              serviceRegistration: serviceRegistration
            )
          }

          let assessment = CameraAgentIdentityHealthMapper.map(
            identityCollector.collect(
              registrationState: registrationState,
              liveEvidence: liveEvidence
            )
          )
          return IdleScreenCompanionCameraIdentityAssessment(
            observation: cameraIdentityObservation(
              from: assessment.classification
            ),
            generationIdentifier: assessment.generationIdentifier
              ?? generationIdentifier,
            serviceRegistration: serviceRegistration,
            runningBundleVersion: identity.bundleVersion,
            runningSourceAppPath: identity.sourceAppPath,
            runningProcessIdentifier: identity.processIdentifier,
            runningProcessEpoch: identity.processIncarnationEpoch,
            runningCodeDirectoryHash: identity.codeDirectoryHash
          )
        },
        connectControl: { attempt, eventHandler in
          controlClient?.connect(
            attempt: attempt,
            eventHandler: eventHandler
          )
        }
      ),
      scheduler: IdleScreenCompanionCameraTaskScheduler()
    )
  }

  private static func cameraRegistration(
    from outcome: CameraAgentRegistrationOutcome
  ) -> CameraAgentServiceRegistration {
    switch outcome {
    case .refreshed(let state),
      .registered(let state),
      .unregistered(let state),
      .replaced(let state):
      return cameraRegistration(from: state)
    case .failed:
      return .failed
    }
  }

  private static func cameraRegistrationState(
    from outcome: CameraAgentRegistrationOutcome
  ) -> CameraAgentRegistrationState {
    switch outcome {
    case .refreshed(let state),
      .registered(let state),
      .unregistered(let state),
      .replaced(let state),
      .failed(_, let state, _):
      state
    }
  }

  private static func cameraReplacement(
    from outcome: CameraAgentRegistrationOutcome
  ) -> IdleScreenCompanionCameraAgentReplacementOutcome {
    switch outcome {
    case .replaced(let state):
      let registration = cameraRegistration(from: state)
      guard registration == .enabled else {
        return .failed(
          state == .requiresApproval
            ? "The replacement needs approval in Login Items."
            : "The replacement was submitted but did not become enabled.",
          serviceRegistration: registration
        )
      }
      return .succeeded(registration)
    case .failed(_, let state, let diagnostic):
      return .failed(
        diagnostic.description,
        serviceRegistration: cameraRegistration(from: state)
      )
    case .refreshed(let state),
      .registered(let state),
      .unregistered(let state):
      return .failed(
        "The camera agent replacement returned an unexpected operation result.",
        serviceRegistration: cameraRegistration(from: state)
      )
    }
  }

  private static func cameraRegistration(
    from state: CameraAgentRegistrationState
  ) -> CameraAgentServiceRegistration {
    switch state {
    case .notRegistered: .notRegistered
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notFound: .notFound
    }
  }

  private static func cameraIdentityObservation(
    from classification: CameraAgentIdentityHealthClassification
  ) -> CameraAgentHelperIdentityObservation {
    switch classification {
    case .unknown: .unknown
    case .absent: .absent
    case .stale: .stale
    case .mismatched: .mismatched
    case .current: .current
    }
  }

  private static func cameraAgentGenerationIdentifier(
    _ identity: IdleScreenCameraAgentIdentity
  ) -> String {
    let helperPath = (identity.sourceAppPath as NSString).appendingPathComponent(
      "Contents/Helpers/IdleScreenCameraAgent.app"
    )
    return [
      "pid=\(identity.processIdentifier)",
      "epoch=\(identity.processIncarnationEpoch)",
      "path=\(helperPath)",
      "service=\(identity.serviceIdentifier)",
      "bundle=\(identity.bundleIdentifier)",
      "bundle-version=\(identity.bundleVersion)",
      "marketing-version=\(identity.marketingVersion)",
      "signing=\(identity.signingIdentifier)",
      "team=\(identity.teamIdentifier)",
      "cdhash=\(identity.codeDirectoryHash.lowercased())",
      "executable=\(identity.executableSHA256.lowercased())",
      "launch-agent=\(identity.launchAgentSHA256.lowercased())",
      "profile=\(identity.provisioningProfileSHA256.lowercased())",
    ].joined(separator: ";")
  }
}
