import Darwin
import Foundation
import IdleScreenAgent
import IdleScreenCore
import IdleScreenSystem
import OSLog
import Observation

@MainActor
@Observable
final class IdleScreenAppModel {
  static let shared = IdleScreenAppModel()

  /// What one background health pass produces: the reports left after
  /// retention and the identifiers of those that belong to a running process.
  struct ProcessHealthSnapshot: Sendable {
    let reports: [IdleScreenProcessHealth]
    let liveReportIdentifiers: Set<String>

    init(reports: [IdleScreenProcessHealth], liveReportIdentifiers: Set<String>) {
      self.reports = reports
      self.liveReportIdentifiers = liveReportIdentifiers
    }
  }

  typealias ProcessHealthLoader = @Sendable (URL) throws -> ProcessHealthSnapshot

  struct AgentIntegrationDependencies: Sendable {
    let sharedPaths: IdleScreenSharedPaths?
    let appGroupIdentifier: String?
    let legacyConfigurationURLs: [URL]
    let codexHookSettingsURL: URL
    let claudeHookSettingsURL: URL
    let agentControlExecutableURL: URL
    let clock: @Sendable () -> Date
    let loadAgentSignals:
      @Sendable (
        IdleScreenAgentSignalStore,
        Date
      ) throws -> IdleScreenAgentSignalInbox
    let loadProcessHealth: ProcessHealthLoader

    init(
      sharedPaths: IdleScreenSharedPaths?,
      appGroupIdentifier: String?,
      legacyConfigurationURLs: [URL],
      codexHookSettingsURL: URL,
      claudeHookSettingsURL: URL,
      agentControlExecutableURL: URL,
      clock: @escaping @Sendable () -> Date,
      loadAgentSignals:
        @escaping @Sendable (
          IdleScreenAgentSignalStore,
          Date
        ) throws -> IdleScreenAgentSignalInbox,
      loadProcessHealth: @escaping ProcessHealthLoader = IdleScreenAppModel
        .loadProcessHealthSnapshot
    ) {
      self.sharedPaths = sharedPaths
      self.appGroupIdentifier = appGroupIdentifier
      self.legacyConfigurationURLs = legacyConfigurationURLs
      self.codexHookSettingsURL = codexHookSettingsURL
      self.claudeHookSettingsURL = claudeHookSettingsURL
      self.agentControlExecutableURL = agentControlExecutableURL
      self.clock = clock
      self.loadAgentSignals = loadAgentSignals
      self.loadProcessHealth = loadProcessHealth
    }
  }

  private static let cameraColorPalette = "Camera Color"
  private static let generativePaletteFallback = "Phosphor"

  private enum RefreshOutcome: Sendable {
    case refreshed(
      registration: ScreenSaverRegistrationAssessment,
      selection: ScreenSaverSelectionReport
    )
    case failed(String)
  }

  private enum BackgroundOutcome: Sendable {
    case saverSetup(
      registration: ScreenSaverRegistrationAssessment,
      selection: ScreenSaverSelectionReport,
      openedSettings: Bool
    )
    case saverStarted(
      registration: ScreenSaverRegistrationAssessment,
      selection: ScreenSaverSelectionReport
    )
    case saverRepaired(
      registration: ScreenSaverRegistrationAssessment,
      selection: ScreenSaverSelectionReport
    )
    case success
    case failure(String)
  }

  private static let logger = Logger(subsystem: "com.idlescreen.app", category: "AppModel")

  private let bundle: Bundle
  private let registrationClient: ScreenSaverRegistrationClient?
  private let selectionClient: ScreenSaverSelectionClient?
  private let activationClient = ScreenSaverActivationClient()
  private let sharedPaths: IdleScreenSharedPaths?
  private let legacyConfigurationURLs: [URL]
  private let clock: @Sendable () -> Date
  private let processHealthLoader: ProcessHealthLoader
  private var processHealthRequest: UInt64 = 0
  private var processHealthAppliedRequest: UInt64 = 0
  private var processHealthRefreshInFlight = false
  private var processHealthRefreshPending = false
  private var processHealthLiveIdentifiers: Set<String> = []
  private var refreshGeneration: UInt64 = 0

  let embeddedExtensionURL: URL?
  let embeddedExtensionBundleIdentifier: String?
  let embeddedExtensionVersion: String?
  let appGroupIdentifier: String?
  let compatibility: ScreenSaverCompatibilityStatus

  var configuration: IdleScreenConfiguration
  var registrationAssessment: ScreenSaverRegistrationAssessment
  var selection: ScreenSaverSelectionReport?
  var processHealth: [IdleScreenProcessHealth] = []
  var isRefreshing = false
  var hasFreshSaverStatus = false
  var isRegistering = false
  var isStartingScreenSaver = false
  var saverActionStatus: String?
  /// The raw error from macOS, the system layer or a store. Views show `UserFacingIssue.message(for:)`; the raw text stays here,
  /// in the log and in Status > Technical details.
  var lastError: String? {
    didSet {
      if let lastError, lastError != oldValue {
        Self.logger.error("Last error: \(lastError, privacy: .public)")
      }
    }
  }
  /// Set when the saved configuration could not be read at launch. Unlike `lastError` it survives unrelated status updates, and
  /// while it is set nothing may overwrite the unreadable file on disk.
  private(set) var configurationLoadFailure: String?
  /// Agent signals, hook install state and the Integrations status line.
  let agentIntegration: AgentIntegrationController

  init(
    bundle: Bundle = .main,
    agentIntegrationDependencies: AgentIntegrationDependencies? = nil
  ) {
    self.bundle = bundle
    compatibility = ScreenSaverCompatibilityProbe.check()

    let extensionURL = bundle.builtInPlugInsURL?
      .appending(path: "IdleScreenScreenSaver.appex", directoryHint: .isDirectory)
    embeddedExtensionURL = extensionURL
    let extensionBundle = extensionURL.flatMap(Bundle.init(url:))
    embeddedExtensionBundleIdentifier = extensionBundle?.bundleIdentifier
    embeddedExtensionVersion =
      extensionBundle?
      .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    registrationClient = extensionBundle?.bundleIdentifier.map {
      ScreenSaverRegistrationClient(
        bundleIdentifier: $0,
        hostRefresher: ScreenSaverHostRefreshClient()
      )
    }
    selectionClient = extensionBundle?.bundleIdentifier.map {
      ScreenSaverSelectionClient(expectedBundleIdentifier: $0)
    }
    registrationAssessment = ScreenSaverRegistrationAssessment(
      registration: .notRegistered,
      extensionAt: extensionURL ?? URL(fileURLWithPath: "/missing/IdleScreenScreenSaver.appex")
    )

    let codexHookSettingsURL: URL
    let claudeHookSettingsURL: URL
    let agentControlExecutableURL: URL
    let agentSignalLoader:
      @Sendable (
        IdleScreenAgentSignalStore,
        Date
      ) throws -> IdleScreenAgentSignalInbox
    if let dependencies = agentIntegrationDependencies {
      appGroupIdentifier = dependencies.appGroupIdentifier
      sharedPaths = dependencies.sharedPaths
      legacyConfigurationURLs = dependencies.legacyConfigurationURLs
      codexHookSettingsURL = dependencies.codexHookSettingsURL
      claudeHookSettingsURL = dependencies.claudeHookSettingsURL
      agentControlExecutableURL = dependencies.agentControlExecutableURL
      clock = dependencies.clock
      agentSignalLoader = dependencies.loadAgentSignals
      processHealthLoader = dependencies.loadProcessHealth
    } else {
      appGroupIdentifier =
        bundle.object(
          forInfoDictionaryKey: "IdleScreenAppGroupIdentifier"
        ) as? String
      let sharedContainerEnabled = Self.boolInfoValue(
        bundle.object(forInfoDictionaryKey: "IdleScreenSharedContainerEnabled")
      )
      sharedPaths =
        sharedContainerEnabled
        ? appGroupIdentifier.flatMap(
          IdleScreenSharedContainer.locate(appGroupIdentifier:)
        )
        : nil
      legacyConfigurationURLs =
        IdleScreenLegacyConfigurationMigration
        .defaultFileURLs()
      let home = FileManager.default.homeDirectoryForCurrentUser
      codexHookSettingsURL = home.appending(path: ".codex/hooks.json")
      claudeHookSettingsURL = home.appending(path: ".claude/settings.json")
      agentControlExecutableURL = bundle.bundleURL.appending(
        path: "Contents/Helpers/idlescreenctl"
      )
      clock = { Date() }
      processHealthLoader = Self.loadProcessHealthSnapshot
      agentSignalLoader = { store, date in
        try store.read(at: date)
      }
    }
    let agentSignalStore = sharedPaths.map {
      IdleScreenAgentSignalStore(fileURL: $0.agentSignalsInboxURL)
    }
    agentIntegration = AgentIntegrationController(
      appGroupIdentifier: appGroupIdentifier,
      agentSignalStore: agentSignalStore,
      codexHookSettingsURL: codexHookSettingsURL,
      claudeHookSettingsURL: claudeHookSettingsURL,
      agentControlExecutableURL: agentControlExecutableURL,
      clock: clock,
      loadAgentSignals: agentSignalLoader
    )
    var shouldPersistInitialConfiguration = true
    if let sharedPaths {
      do {
        configuration =
          try IdleScreenConfigurationStore(
            fileURL: sharedPaths.configurationURL
          ).read(
            importingLegacyConfigurationAt: legacyConfigurationURLs
          )
          ?? .default
      } catch {
        configuration = .default
        configurationLoadFailure = error.localizedDescription
        lastError = error.localizedDescription
        shouldPersistInitialConfiguration = false
      }
    } else {
      configuration = .default
    }

    let normalizedConfiguration = Self.normalizingActivePalette(in: configuration)
    let repairedPersistedConfiguration = normalizedConfiguration != configuration
    configuration = normalizedConfiguration
    if repairedPersistedConfiguration {
      configuration.schemaVersion = IdleScreenConfiguration.currentSchemaVersion
      configuration.revision &+= 1
      configuration.modifiedAt = clock()
    }

    agentIntegration.configurationProvider = { [unowned self] in self.configuration }

    if shouldPersistInitialConfiguration {
      persistConfigurationIfNeeded(overwritingExisting: repairedPersistedConfiguration)
    }
    agentIntegration.start()
    publishAppHealth()
    refresh()
  }

  var isExtensionEmbedded: Bool {
    guard let embeddedExtensionURL else { return false }
    return FileManager.default.fileExists(atPath: embeddedExtensionURL.path)
  }

  var hasSharedContainer: Bool { sharedPaths != nil }

  var registration: ScreenSaverRegistrationStatus {
    registrationAssessment.registration
  }

  var extensionHealth: IdleScreenProcessHealth? {
    IdleScreenHealthSelection.preferredReport(
      for: .screenSaverExtension,
      in: processHealth,
      liveReportIdentifiers: processHealthLiveIdentifiers
    )
  }

  /// Liveness as of the last completed health pass. Classification runs off
  /// the main actor, so views only look the answer up.
  func isProcessReportLive(_ report: IdleScreenProcessHealth) -> Bool {
    processHealthLiveIdentifiers.contains(report.reportIdentifier)
  }

  nonisolated static func isProcessReportRunning(_ report: IdleScreenProcessHealth) -> Bool {
    guard let processIdentifier = report.processIdentifier else { return false }
    let processExists = Darwin.kill(processIdentifier, 0) == 0 || errno == EPERM
    guard processExists,
      let executablePath = executablePath(for: processIdentifier),
      report.process.matchesExecutablePath(executablePath),
      let processStartedAt = processStartDate(for: processIdentifier),
      report.couldBelongToProcess(startedAt: processStartedAt)
    else {
      return false
    }
    return report.isLive(
      activeProcessIdentifiers: [processIdentifier]
    )
  }

  /// Reads, classifies and prunes the health directory. Runs off the main actor.
  nonisolated static func loadProcessHealthSnapshot(
    directoryURL: URL
  ) throws -> ProcessHealthSnapshot {
    let store = IdleScreenHealthStore(directoryURL: directoryURL)
    let result = try store.enforceRetention(classifyingLive: { reports in
      Set(
        reports.compactMap { report -> String? in
          isProcessReportRunning(report) ? report.reportIdentifier : nil
        })
    })
    let retained = result.retained
    let live = result.liveReportIdentifiers
    let retainedIdentifiers = Set(retained.map(\.reportIdentifier))
    return ProcessHealthSnapshot(
      reports: retained,
      liveReportIdentifiers: live.intersection(retainedIdentifiers)
    )
  }

  func refresh() {
    readProcessHealth()

    refreshGeneration &+= 1
    let generation = refreshGeneration
    hasFreshSaverStatus = false

    guard let registrationClient,
      let selectionClient,
      let embeddedExtensionURL
    else {
      selection = nil
      isRefreshing = false
      return
    }

    isRefreshing = true
    Task {
      let outcome = await Task.detached { () -> RefreshOutcome in
        do {
          let registration = try registrationClient.assessment(
            extensionAt: embeddedExtensionURL
          )
          let selection = try selectionClient.status()
          return .refreshed(
            registration: registration,
            selection: selection
          )
        } catch {
          return .failed(error.localizedDescription)
        }
      }.value

      guard generation == refreshGeneration else { return }
      switch outcome {
      case .refreshed(let registration, let selection):
        registrationAssessment = registration
        self.selection = selection
        hasFreshSaverStatus = true
        lastError = nil
      case .failed(let message):
        self.selection = nil
        hasFreshSaverStatus = false
        lastError = message
      }
      isRefreshing = false
      publishAppHealth()
      readProcessHealth()
    }
  }

  func registerExtension() {
    guard let registrationClient, let selectionClient, let embeddedExtensionURL else {
      lastError = "The embedded screen saver extension is missing from this app build."
      return
    }
    let activationClient = self.activationClient
    isRegistering = true
    saverActionStatus = "Registering the embedded extension with macOS…"
    lastError = nil
    Task {
      let outcome = await Task.detached { () -> BackgroundOutcome in
        do {
          let registration = try registrationClient.repair(extensionAt: embeddedExtensionURL)
          let selection = try selectionClient.status()
          guard selection.isSelectedEverywhere else {
            try activationClient.openScreenSaverSettings()
            return .saverSetup(
              registration: registration,
              selection: selection,
              openedSettings: true
            )
          }
          return .saverSetup(
            registration: registration,
            selection: selection,
            openedSettings: false
          )
        } catch {
          return .failure(error.localizedDescription)
        }
      }.value
      apply(outcome)
      isRegistering = false
    }
  }

  func forceRepairExtension() {
    guard let registrationClient, let selectionClient, let embeddedExtensionURL else {
      lastError = "The embedded screen saver extension is missing from this app build."
      return
    }
    guard !isRegistering, !isStartingScreenSaver else { return }
    isRegistering = true
    saverActionStatus = "Refreshing the screen saver registration and macOS host…"
    lastError = nil
    Task {
      let outcome = await Task.detached { () -> BackgroundOutcome in
        do {
          let registration = try registrationClient.forceRepair(
            extensionAt: embeddedExtensionURL
          )
          let selection = try selectionClient.status()
          return .saverRepaired(
            registration: registration,
            selection: selection
          )
        } catch {
          return .failure(error.localizedDescription)
        }
      }.value
      apply(outcome)
      isRegistering = false
    }
  }

  func startScreenSaver() {
    guard let registrationClient, let selectionClient, let embeddedExtensionURL else {
      lastError = "The embedded screen saver extension is missing from this app build."
      return
    }
    guard !isRegistering, !isStartingScreenSaver else { return }
    let activationClient = self.activationClient
    isStartingScreenSaver = true
    saverActionStatus = "Checking registration and the current macOS selection…"
    lastError = nil
    Task {
      let outcome = await Task.detached { () -> BackgroundOutcome in
        do {
          var registration = try registrationClient.assessment(
            extensionAt: embeddedExtensionURL
          )
          if registration.needsRepair {
            registration = try registrationClient.repair(
              extensionAt: embeddedExtensionURL
            )
          }
          let selection = try selectionClient.status()
          guard selection.isSelectedEverywhere else {
            try activationClient.openScreenSaverSettings()
            return .saverSetup(
              registration: registration,
              selection: selection,
              openedSettings: true
            )
          }
          try activationClient.startIdleScreen(selection: selection)
          return .saverStarted(
            registration: registration,
            selection: selection
          )
        } catch {
          return .failure(error.localizedDescription)
        }
      }.value
      apply(outcome)
      isStartingScreenSaver = false
    }
  }

  func openScreenSaverSettings() {
    saverActionStatus = "Opening Screen Saver Settings…"
    lastError = nil
    runInBackground { [activationClient] in
      try activationClient.openScreenSaverSettings()
    }
  }

  func updateSource(_ source: IdleScreenSource) {
    configuration.source = source
    normalizeActivePalette()
    commitConfiguration()
  }

  func updateCameraSelection(_ selection: IdleScreenCameraSelection) {
    guard configuration.camera.selection != selection else { return }
    configuration.camera.selection = selection
    commitConfiguration()
  }

  func updatePreferredCamera(_ deviceIdentifier: String?) {
    let validatedIdentifier =
      IdleScreenCameraConfiguration.validatedPreferredIdentifier(
        deviceIdentifier
      )
    guard
      configuration.camera.preferredDeviceIdentifier
        != validatedIdentifier
    else {
      return
    }
    configuration.camera.preferredDeviceIdentifier = validatedIdentifier
    commitConfiguration()
  }

  func updateCameraMirroring(_ isMirrored: Bool) {
    guard configuration.camera.isMirrored != isMirrored else { return }
    configuration.camera.isMirrored = isMirrored
    commitConfiguration()
  }

  func updateDisplayPolicy(_ policy: DisplayScenePolicy) {
    updateDisplaySettings { current in
      .init(
        policy: policy,
        focalDisplayIdentifier: current.focalDisplayIdentifier,
        quietTreatment: current.quietTreatment,
        outerBoundaryBehavior: current.outerBoundaryBehavior,
        baseSeed: current.baseSeed
      )
    }
  }

  func updateFocalDisplay(
    _ identifier: DisplayTopology.PersistentDisplayIdentifier?
  ) {
    updateDisplaySettings { current in
      .init(
        policy: current.policy,
        focalDisplayIdentifier: identifier,
        quietTreatment: current.quietTreatment,
        outerBoundaryBehavior: current.outerBoundaryBehavior,
        baseSeed: current.baseSeed
      )
    }
  }

  func updateDisplayQuietTreatment(_ treatment: DisplayQuietTreatment) {
    updateDisplaySettings { current in
      .init(
        policy: current.policy,
        focalDisplayIdentifier: current.focalDisplayIdentifier,
        quietTreatment: treatment,
        outerBoundaryBehavior: current.outerBoundaryBehavior,
        baseSeed: current.baseSeed
      )
    }
  }

  func updateDisplayOuterBoundaryBehavior(
    _ behavior: DisplayOuterBoundaryBehavior
  ) {
    updateDisplaySettings { current in
      .init(
        policy: current.policy,
        focalDisplayIdentifier: current.focalDisplayIdentifier,
        quietTreatment: current.quietTreatment,
        outerBoundaryBehavior: behavior,
        baseSeed: current.baseSeed
      )
    }
  }

  func updateGlyphScale(_ glyphScale: Double) {
    configuration.appearance.glyphScale = glyphScale
    commitConfiguration()
  }

  func updateContrast(_ contrast: Double) {
    configuration.appearance.contrast = contrast
    commitConfiguration()
  }

  func updatePalette(_ palette: String) {
    guard Self.isPalette(palette, compatibleWith: configuration.source) else {
      return
    }
    configuration.appearance.palette = palette
    commitConfiguration()
  }

  func canSelectPalette(_ palette: String) -> Bool {
    Self.isPalette(palette, compatibleWith: configuration.source)
  }

  func updateCreativePattern(_ pattern: IdleScreenCreativePattern) {
    configuration.creative.pattern = pattern
    commitConfiguration()
  }

  func updateCreativeFraming(_ framing: IdleScreenSceneFraming) {
    configuration.creative.framing = framing
    commitConfiguration()
  }

  func updateCreativeSpeed(_ speed: Double) {
    updateCreativeSettings { $0.speed = speed }
  }

  func updateCreativeScale(_ scale: Double) {
    updateCreativeSettings { $0.scale = scale }
  }

  func updateCreativeIntensity(_ intensity: Double) {
    updateCreativeSettings { $0.intensity = intensity }
  }

  func updateCreativeTrailing(_ trailing: Double) {
    updateCreativeSettings { $0.trailing = trailing }
  }

  func updateCreativeAutoCycleInterval(_ interval: TimeInterval) {
    updateCreativeSettings { $0.autoCycleInterval = interval }
  }

  func updateCreativeMatrixTrailLength(_ trailLength: Double) {
    updateCreativeSettings { $0.matrixTrailLength = trailLength }
  }

  func updateCreativeRainbowAmplitude(_ amplitude: Double) {
    updateCreativeSettings { $0.rainbowAmplitude = amplitude }
  }

  func updateCreativeFireDecay(_ decay: Double) {
    updateCreativeSettings { $0.fireDecay = decay }
  }

  func updateCreativeQualityLevel(_ qualityLevel: Double) {
    updateCreativeSettings { $0.qualityLevel = qualityLevel }
  }

  func updatePixelMaterial(_ material: IdleScreenPixelMaterial) {
    updatePixelMaterials { $0.material = material }
  }

  func updatePixelMaterials(
    _ update: (inout IdleScreenPixelMaterialsConfiguration) -> Void
  ) {
    var settings = configuration.materials
    update(&settings)
    let normalized = settings.normalized
    guard normalized != configuration.materials else { return }
    configuration.materials = normalized
    commitConfiguration()
  }

  func updateAgentIntegration(
    _ update: (inout IdleScreenAgentIntegrationConfiguration) -> Void
  ) {
    var settings = configuration.agentIntegration
    update(&settings)
    let normalized = settings.normalized
    guard normalized != configuration.agentIntegration else { return }
    configuration.agentIntegration = normalized
    commitConfiguration()
    agentIntegration.refreshAgentSignals()
  }

  func resetPixelMaterials() {
    guard configuration.materials != .default else { return }
    configuration.materials = .default
    commitConfiguration()
  }

  func resetCreativeSettings() {
    guard configuration.creative.settings != .default else { return }
    configuration.creative.settings = .default
    commitConfiguration()
  }

  @discardableResult
  func saveCurrentLook(named name: String) -> Bool {
    do {
      configuration = try configuration.savingCurrentLook(
        id: UUID(),
        named: name
      )
      commitConfiguration()
      return true
    } catch {
      lastError = savedLookErrorMessage(error)
      return false
    }
  }

  @discardableResult
  func applySavedLook(id: UUID) -> Bool {
    do {
      configuration = try configuration.applyingSavedLook(id: id)
      normalizeActivePalette()
      commitConfiguration()
      return true
    } catch {
      lastError = savedLookErrorMessage(error)
      return false
    }
  }

  @discardableResult
  func replaceSavedLook(id: UUID) -> Bool {
    do {
      configuration = try configuration.replacingSavedLook(id: id)
      commitConfiguration()
      return true
    } catch {
      lastError = savedLookErrorMessage(error)
      return false
    }
  }

  @discardableResult
  func renameSavedLook(id: UUID, to name: String) -> Bool {
    do {
      configuration = try configuration.renamingSavedLook(
        id: id,
        to: name
      )
      commitConfiguration()
      return true
    } catch {
      lastError = savedLookErrorMessage(error)
      return false
    }
  }

  @discardableResult
  func removeSavedLook(id: UUID) -> Bool {
    do {
      configuration = try configuration.removingSavedLook(id: id)
      commitConfiguration()
      return true
    } catch {
      lastError = savedLookErrorMessage(error)
      return false
    }
  }

  private func updateCreativeSettings(
    _ update: (inout IdleScreenCreativeSettings) -> Void
  ) {
    var settings = configuration.creative.settings
    update(&settings)
    configuration.creative.settings = settings.normalized
    commitConfiguration()
  }

  private func updateDisplaySettings(
    _ update: (DisplaySceneSettings) -> DisplaySceneSettings
  ) {
    let updated = update(configuration.display)
    guard updated != configuration.display else { return }
    configuration.display = updated
    commitConfiguration()
  }

  private func savedLookErrorMessage(_ error: Error) -> String {
    guard let savedLookError = error as? IdleScreenSavedLookError else {
      return error.localizedDescription
    }
    switch savedLookError {
    case .duplicateID:
      return "That Saved Look identifier already exists."
    case .collectionFull(let maximumCount):
      return "Saved Looks is full. Remove one of the "
        + String(maximumCount)
        + " existing looks before saving another."
    case .invalidName:
      return "Enter a name for this Saved Look."
    case .notFound:
      return "That Saved Look is no longer available."
    }
  }

  private func commitConfiguration() {
    if let configurationLoadFailure {
      lastError = configurationLoadFailure
      publishAppHealth()
      return
    }
    configuration.schemaVersion = IdleScreenConfiguration.currentSchemaVersion
    configuration.revision &+= 1
    configuration.modifiedAt = clock()
    guard let sharedPaths else {
      lastError = "Shared configuration is unavailable until the app is signed for its App Group."
      publishAppHealth()
      return
    }
    do {
      try IdleScreenConfigurationStore(fileURL: sharedPaths.configurationURL).write(configuration)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    publishAppHealth()
  }

  private func persistConfigurationIfNeeded(overwritingExisting: Bool = false) {
    guard let sharedPaths, configurationLoadFailure == nil else { return }
    let store = IdleScreenConfigurationStore(fileURL: sharedPaths.configurationURL)
    do {
      let existingConfiguration = try store.read()
      if overwritingExisting || existingConfiguration == nil {
        try store.write(configuration)
      }
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func normalizeActivePalette() {
    configuration = Self.normalizingActivePalette(in: configuration)
  }

  private static func normalizingActivePalette(
    in configuration: IdleScreenConfiguration
  ) -> IdleScreenConfiguration {
    guard
      !isPalette(
        configuration.appearance.palette,
        compatibleWith: configuration.source
      )
    else {
      return configuration
    }
    var result = configuration
    result.appearance.palette = generativePaletteFallback
    return result
  }

  private static func isPalette(
    _ palette: String,
    compatibleWith source: IdleScreenSource
  ) -> Bool {
    source != .generative
      || palette.caseInsensitiveCompare(cameraColorPalette) != .orderedSame
  }

  func refreshProcessHealth() {
    readProcessHealth()
  }

  private enum ProcessHealthOutcome: Sendable {
    case loaded(ProcessHealthSnapshot)
    case failed(String)
  }

  /// Overlapping calls coalesce into at most one follow-up pass, and only a
  /// completed pass newer than the last one applied is published.
  private func readProcessHealth() {
    guard let sharedPaths else {
      processHealth = []
      processHealthLiveIdentifiers = []
      return
    }
    guard !processHealthRefreshInFlight else {
      processHealthRefreshPending = true
      return
    }
    processHealthRefreshInFlight = true
    processHealthRefreshPending = false
    processHealthRequest &+= 1
    let request = processHealthRequest
    let directoryURL = sharedPaths.healthDirectoryURL
    let loader = processHealthLoader
    Task {
      let outcome = await Task.detached { () -> ProcessHealthOutcome in
        do {
          return .loaded(try loader(directoryURL))
        } catch {
          return .failed(error.localizedDescription)
        }
      }.value
      applyProcessHealth(outcome, request: request)
    }
  }

  private func applyProcessHealth(_ outcome: ProcessHealthOutcome, request: UInt64) {
    processHealthRefreshInFlight = false
    if request > processHealthAppliedRequest {
      processHealthAppliedRequest = request
      switch outcome {
      case .loaded(let snapshot):
        processHealth = snapshot.reports
        processHealthLiveIdentifiers = snapshot.liveReportIdentifiers
      case .failed(let message):
        lastError = message
      }
    }
    if processHealthRefreshPending {
      readProcessHealth()
    }
  }

  private func publishAppHealth() {
    guard let sharedPaths else { return }
    let report = IdleScreenProcessHealth(
      process: .companionApp,
      lifecycle: .attached,
      build: IdleScreenBuildIdentity(
        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "unknown",
        buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        bundleIdentifier: bundle.bundleIdentifier ?? "unknown"
      ),
      updatedAt: clock(),
      configurationRevision: configuration.revision,
      issue: lastError
    )
    do {
      try IdleScreenHealthStore(directoryURL: sharedPaths.healthDirectoryURL).write(report)
    } catch {
      Self.logger.error(
        "Unable to publish app health: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func runInBackground(_ operation: @escaping @Sendable () throws -> Void) {
    Task {
      let outcome = await Task.detached { () -> BackgroundOutcome in
        do {
          try operation()
          return .success
        } catch {
          return .failure(error.localizedDescription)
        }
      }.value
      apply(outcome)
    }
  }

  private func apply(_ outcome: BackgroundOutcome) {
    switch outcome {
    case .saverSetup(let registration, let status, let openedSettings):
      registrationAssessment = registration
      selection = status
      hasFreshSaverStatus = true
      saverActionStatus =
        openedSettings
        ? "The extension is registered. Setup is complete once IdleScreen is selected in Screen Saver Settings."
        : "IdleScreen is registered and selected. Setup is complete."
      lastError = nil
    case .saverStarted(let registration, let status):
      registrationAssessment = registration
      selection = status
      hasFreshSaverStatus = true
      saverActionStatus = "macOS accepted the request to start IdleScreen."
      lastError = nil
    case .saverRepaired(let registration, let status):
      registrationAssessment = registration
      selection = status
      hasFreshSaverStatus = true
      saverActionStatus = "Screen saver registration and the macOS host were refreshed."
      lastError = nil
    case .success:
      saverActionStatus = "Screen Saver Settings opened."
      lastError = nil
    case .failure(let message):
      saverActionStatus = nil
      lastError = message
    }
    publishAppHealth()
    readProcessHealth()
  }

  private static func boolInfoValue(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
      return ["YES", "TRUE", "1"].contains(value.uppercased())
    }
    return false
  }

  nonisolated private static func executablePath(for processIdentifier: Int32) -> String? {
    var pathBuffer = [CChar](repeating: 0, count: 4096)
    let pathLength = Darwin.proc_pidpath(
      processIdentifier,
      &pathBuffer,
      UInt32(pathBuffer.count)
    )
    guard pathLength > 0 else { return nil }
    let reportedByteCount = min(Int(pathLength), pathBuffer.count)
    let pathBytes =
      pathBuffer
      .prefix(reportedByteCount)
      .prefix { $0 != 0 }
      .map { UInt8(bitPattern: $0) }
    return String(decoding: pathBytes, as: UTF8.self)
  }

  nonisolated private static func processStartDate(for processIdentifier: Int32) -> Date? {
    var processInfo = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let actualSize = Darwin.proc_pidinfo(
      processIdentifier,
      PROC_PIDTBSDINFO,
      0,
      &processInfo,
      expectedSize
    )
    guard actualSize == expectedSize else { return nil }
    let seconds = TimeInterval(processInfo.pbi_start_tvsec)
    let microseconds = TimeInterval(processInfo.pbi_start_tvusec) / 1_000_000
    return Date(timeIntervalSince1970: seconds + microseconds)
  }
}
