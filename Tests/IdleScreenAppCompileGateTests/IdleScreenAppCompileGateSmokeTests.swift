import Foundation
import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import Testing

@Suite("Companion source compile gate")
struct IdleScreenAppCompileGateSmokeTests {
  @MainActor
  @Test("window resize keeps the proposed width and height independent of the display")
  func previewWindowFreeResize() {
    for ratio in [16.0 / 9, 9.0 / 16, 21.0 / 9] {
      let content = IdleScreenAppDelegate.constrainedPreviewContentSize(
        proposed: CGSize(width: 1_200, height: 800),
        current: CGSize(width: 1_040, height: 680),
        previewAspectRatio: ratio
      )
      #expect(content == CGSize(width: 1_200, height: 800))
    }
  }

  @MainActor
  @Test("small window proposals clamp each dimension without changing their other dimension")
  func previewWindowMinimumSize() {
    let content = IdleScreenAppDelegate.constrainedPreviewContentSize(
      proposed: CGSize(width: 500, height: 800),
      current: CGSize(width: 1_200, height: 800),
      previewAspectRatio: 9.0 / 16
    )
    #expect(content == CGSize(width: 900, height: 800))
  }

  @Test("switching preview displays keeps saved window geometry intact")
  func previewWindowNormalization() {
    for ratio in [16.0 / 9, 9.0 / 16, 21.0 / 9] {
      let content = IdleScreenPreviewWindowGeometry.normalizedContentSize(
        current: CGSize(width: 1_200, height: 900),
        previewAspectRatio: ratio
      )
      #expect(content == CGSize(width: 1_200, height: 900))
    }
  }

  @Test("all workbench destinations are available")
  func companionSourcesAreLinked() {
    #expect(Destination.allCases.map(\.rawValue) == ["Scene", "Displays", "Agents", "Settings"])
  }

  @Test("the entire preview fits landscape, portrait and ultrawide displays")
  func previewFitsDisplay() {
    let available = CGSize(width: 600, height: 400)
    for ratio in [16.0 / 9, 9.0 / 16, 21.0 / 9] {
      let fitted = IdleScreenPreviewWindowGeometry.fittedPreviewSize(
        inside: available, aspectRatio: ratio)
      #expect(fitted.width <= available.width && fitted.height <= available.height)
      #expect(abs(fitted.width / fitted.height - ratio) < 0.000_001)
      #expect(fitted.width == available.width || fitted.height == available.height)
    }
    #expect(
      IdleScreenPreviewWindowGeometry.fittedPreviewSize(inside: available, aspectRatio: .nan)
        == .zero)
    #expect(
      IdleScreenPreviewWindowGeometry.fittedPreviewSize(inside: .zero, aspectRatio: 16.0 / 9)
        == .zero)
  }

  @MainActor
  @Test(
    "inspector and library preferences survive a relaunch without restoring transient setup state")
  func workbenchPreferencesSurviveRelaunch() throws {
    let suiteName = "IdleScreenWorkbenchTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let first = IdleScreenCompanionNavigation(preferences: preferences)
    #expect(!first.isSceneInspectorVisible)
    #expect(first.isInspectorVisible)
    first.isSceneInspectorVisible = true
    first.isInspectorVisible = false
    first.showsSavedLooks = true
    first.previewDisplayIdentifier = .init(rawValue: "external-display")
    first.isSetupDeferred = true
    first.destination = .integrations
    let restored = IdleScreenCompanionNavigation(preferences: preferences)
    #expect(restored.isSceneInspectorVisible)
    #expect(!restored.isInspectorVisible)
    #expect(restored.showsSavedLooks)
    #expect(restored.previewDisplayIdentifier?.rawValue == "external-display")
    #expect(restored.destination == .studio)
    #expect(!restored.isSetupDeferred)
  }

  @Test(
    "a tall saved window fits the available screen without shrinking its width below the minimum")
  func restoredWindowFitsScreen() {
    let fitted = IdleScreenPreviewWindowGeometry.normalizedContentSize(
      current: CGSize(width: 900, height: 2_200), previewAspectRatio: 16.0 / 9,
      availableSize: CGSize(width: 1_400, height: 850))
    #expect(fitted == CGSize(width: 900, height: 850))
    let wide = IdleScreenPreviewWindowGeometry.normalizedContentSize(
      current: CGSize(width: 3_000, height: 700), previewAspectRatio: 9.0 / 16,
      availableSize: CGSize(width: 1_400, height: 850))
    #expect(wide == CGSize(width: 1_400, height: 700))
  }

  @Test("a screen smaller than the workbench does not shrink content below its minimum")
  func smallScreenPreservesWindowMinimum() {
    let fitted = IdleScreenPreviewWindowGeometry.normalizedContentSize(
      current: CGSize(width: 1_200, height: 800), previewAspectRatio: 16.0 / 9,
      availableSize: CGSize(width: 800, height: 500))
    #expect(fitted == IdleScreenPreviewWindowGeometry.absoluteMinimumContentSize)
  }

  @Test("new scenes start full bleed without a dark sky mask")
  func defaultSceneIsFullBleed() {
    #expect(IdleScreenConfiguration.default.creative.framing == .none)
  }

  @Test("shared Pixel Materials configuration maps every product input")
  func pixelMaterialsRendererMapping() {
    var configuration = IdleScreenConfiguration.default
    configuration.creative.pattern = .pixelMaterials
    configuration.materials = .init(
      material: .mixed,
      terrainFamily: .caverns,
      seed: 0xA5,
      basinCount: 5,
      basinDepth: 11,
      minimumBasinCapacity: 64,
      channelConnectivity: 0.4,
      channelWidth: 4,
      rockRatio: 0.7,
      soilRatio: 0.3,
      emitterCount: 3,
      emitterPosition: 0.6,
      emitterWidth: 5,
      emitterRate: 4,
      gravity: 0.8,
      cellScale: 1.5,
      waterLateralFlow: 0.6,
      waterEqualization: 0.7,
      waterPressure: 0.2,
      spillRate: 0.5,
      drainRate: 0.3,
      evaporationRate: 0.1,
      obstacleDensity: 0.25,
      palette: .tidal,
      persistence: 0.9,
      phaseDurations: .init(
        quiet: 1,
        filling: 9,
        settled: 3,
        draining: 2
      ),
      regenerationCadence: 15
    )
    let identifier = DisplayTopology.PersistentDisplayIdentifier(
      rawValue: "preview"
    )
    let assignment = DisplaySceneAssignment(
      displayIdentifier: identifier,
      representativeIdentifier: identifier,
      role: .panorama,
      scene: .init(
        identity: .panorama,
        seed: 0x0F,
        epoch: 1,
        bounds: .init(x: 0, y: 0, width: 1, height: 1)
      ),
      viewport: nil,
      ownsFocalElement: true,
      boundaries: []
    )

    let rendered = configuration.rendererConfiguration(for: assignment)
    let settings = rendered.pixelMaterialsSettings

    #expect(rendered.patternRawValue == "pixelMaterials")
    #expect(settings.material == .mixed)
    #expect(settings.terrainStyle == .caverns)
    #expect(settings.seed == 0xA5)
    #expect(settings.basinCount == 5)
    #expect(settings.basinDepth == 11)
    #expect(settings.minimumBasinCapacity == 64)
    #expect(settings.channelConnectivity == 0.4)
    #expect(settings.channelWidth == 4)
    #expect(settings.rockRatio == 0.7)
    #expect(settings.soilRatio == 0.3)
    #expect(settings.emitterCount == 3)
    #expect(settings.emitterPosition == 0.6)
    #expect(settings.emitterWidth == 5)
    #expect(settings.emitterRate == 4)
    #expect(settings.gravity == 0.8)
    #expect(settings.cellScale == 1.5)
    #expect(settings.waterLateralFlow == 0.6)
    #expect(settings.waterEqualization == 0.7)
    #expect(settings.waterPressure == 0.2)
    #expect(settings.spillRate == 0.5)
    #expect(settings.drainRate == 0.3)
    #expect(settings.evaporationRate == 0.1)
    #expect(settings.obstacleDensity == 0.25)
    #expect(settings.paletteRawValue == "tidal")
    #expect(settings.persistence == 0.9)
    #expect(settings.phaseDurations.quiet == 1)
    #expect(settings.phaseDurations.filling == 9)
    #expect(settings.phaseDurations.settled == 3)
    #expect(settings.phaseDurations.draining == 2)
    #expect(settings.regenerationCadence == 15)
    #expect(rendered.sceneSeed == 0x0F)
  }

  @MainActor
  @Test("Studio material mutations normalize and persist one revision each")
  func studioMaterialMutations() {
    let model = IdleScreenAppModel(bundle: Bundle(for: TestBundleMarker.self))
    let initialRevision = model.configuration.revision

    model.updatePixelMaterial(.mixed)
    model.updatePixelMaterials { settings in
      settings.seed = 919
      settings.basinCount = 7
      settings.cellScale = 2
    }

    #expect(model.configuration.materials.material == .mixed)
    #expect(model.configuration.materials.seed == 919)
    #expect(model.configuration.materials.basinCount == 7)
    #expect(model.configuration.materials.cellScale == 2)
    #expect(model.configuration.revision == initialRevision + 2)
  }

  @MainActor
  @Test("agent controls stay in scratch storage and publish one loaded inbox")
  func scratchAgentIntegrationControls() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_300)
    let fixture = try AgentModelFixture(now: now)
    defer { fixture.removeScratchDirectory() }
    let model = fixture.model

    model.updateAgentIntegration {
      $0.codexEnabled = true
      $0.claudeEnabled = true
      $0.messageTimeout = 45
    }
    #expect(model.configuration.agentIntegration.codexEnabled)
    #expect(model.configuration.agentIntegration.claudeEnabled)
    #expect(model.configuration.agentIntegration.messageTimeout == 45)

    model.agentIntegration.testAgentSignal(for: .codex, at: now)
    #expect(await eventually { model.agentIntegration.activeAgentSignal?.provider == .codex })
    _ = try fixture.store.apply(.recordIgnored(provider: .claude), at: now)
    model.agentIntegration.refreshAgentSignals(at: now.addingTimeInterval(2))
    #expect(await eventually { model.agentIntegration.agentIgnoredEventCounts[.claude] == 1 })

    model.agentIntegration.installAgentHooks(for: .codex)
    model.agentIntegration.installAgentHooks(for: .claude)
    model.agentIntegration.refreshAgentHookInstallationStatus()
    #expect(model.agentIntegration.codexHooksInstalled)
    #expect(model.agentIntegration.claudeHooksInstalled)
    #expect(FileManager.default.fileExists(atPath: fixture.codexSettingsURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.claudeSettingsURL.path))
    #expect(fixture.codexSettingsURL.path.hasPrefix(fixture.root.path + "/"))
    #expect(fixture.claudeSettingsURL.path.hasPrefix(fixture.root.path + "/"))

    model.agentIntegration.uninstallAgentHooks(for: .codex)
    model.agentIntegration.uninstallAgentHooks(for: .claude)
    model.agentIntegration.refreshAgentHookInstallationStatus()
    #expect(!model.agentIntegration.codexHooksInstalled)
    #expect(!model.agentIntegration.claudeHooksInstalled)

    model.agentIntegration.clearAgentSignals(at: now.addingTimeInterval(3))
    #expect(await eventually { model.agentIntegration.activeAgentSignal == nil })
    #expect(model.agentIntegration.status == "All agent signals cleared.")
  }

  @MainActor
  @Test("Clear repairs a malformed agent inbox and reports success")
  func clearRepairsMalformedInbox() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_350)
    let fixture = try AgentModelFixture(now: now)
    defer { fixture.removeScratchDirectory() }
    let model = fixture.model
    let inboxURL = fixture.store.fileURL
    try FileManager.default.createDirectory(
      at: inboxURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{broken".utf8).write(to: inboxURL)
    #expect(throws: (any Error).self) { try fixture.store.read(at: now) }

    model.agentIntegration.clearAgentSignals(at: now.addingTimeInterval(1))

    #expect(model.agentIntegration.status == "All agent signals cleared.")
    let repaired = try fixture.store.read(at: now.addingTimeInterval(2))
    #expect(repaired.signals.isEmpty)
  }

  @MainActor
  @Test("a failed background inbox load retries on the next polling tick")
  func agentSignalRefreshRetries() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_400)
    let signal = try testSignal(
      provider: .claude,
      eventID: "retry",
      at: now
    )
    let loader = ScriptedAgentInboxLoader(steps: [
      .failure(.expectedFailure),
      .success(
        IdleScreenAgentSignalInbox(
          revision: 8,
          updatedAt: now,
          signals: [signal],
          ignoredEventCounts: [.codex: 3]
        )),
    ])
    let fixture = try AgentModelFixture(now: now, loader: loader.load)
    defer { fixture.removeScratchDirectory() }

    #expect(
      await eventually {
        fixture.model.agentIntegration.status?.contains("unavailable") == true
      })
    fixture.model.agentIntegration.refreshAgentSignals(at: now)

    #expect(await eventually { fixture.model.agentIntegration.activeAgentSignal == signal })
    #expect(fixture.model.agentIntegration.agentIgnoredEventCounts == [.codex: 3])
    #expect(loader.callCount == 2)
  }

  @MainActor
  @Test("background inbox loading coalesces and accepts only the newest request")
  func agentSignalRefreshNewestResultWins() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_500)
    let firstSignal = try testSignal(
      provider: .codex,
      eventID: "stale",
      at: now
    )
    let newestSignal = try testSignal(
      provider: .claude,
      eventID: "newest",
      at: now
    )
    let releaseFirstLoad = DispatchSemaphore(value: 0)
    let loader = ScriptedAgentInboxLoader(steps: [
      .blocked(
        release: releaseFirstLoad,
        inbox: IdleScreenAgentSignalInbox(
          revision: 1,
          updatedAt: now,
          signals: [firstSignal]
        )
      ),
      .success(
        IdleScreenAgentSignalInbox(
          revision: 3,
          updatedAt: now.addingTimeInterval(2),
          signals: [newestSignal],
          ignoredEventCounts: [.claude: 4]
        )),
    ])
    let fixture = try AgentModelFixture(now: now, loader: loader.load)
    defer {
      releaseFirstLoad.signal()
      fixture.removeScratchDirectory()
    }
    #expect(await eventually { loader.callCount == 1 })

    fixture.model.agentIntegration.refreshAgentSignals(at: now.addingTimeInterval(1))
    fixture.model.agentIntegration.refreshAgentSignals(at: now.addingTimeInterval(2))
    releaseFirstLoad.signal()

    #expect(await eventually { fixture.model.agentIntegration.activeAgentSignal == newestSignal })
    #expect(fixture.model.agentIntegration.agentIgnoredEventCounts == [.claude: 4])
    #expect(loader.callCount == 2)
    #expect(loader.loadedDates == [now, now.addingTimeInterval(2)])
  }

  @MainActor
  @Test("clear fences a late inbox result before its forced refresh")
  func clearFencesLateAgentSignalResult() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_600)
    let staleSignal = try testSignal(
      provider: .codex,
      eventID: "before-clear",
      at: now
    )
    let releaseStaleLoad = DispatchSemaphore(value: 0)
    let releaseClearLoad = DispatchSemaphore(value: 0)
    let loader = ScriptedAgentInboxLoader(steps: [
      .blocked(
        release: releaseStaleLoad,
        inbox: IdleScreenAgentSignalInbox(
          revision: 1,
          updatedAt: now,
          signals: [staleSignal]
        )
      ),
      .blocked(
        release: releaseClearLoad,
        inbox: IdleScreenAgentSignalInbox(
          revision: 2,
          updatedAt: now.addingTimeInterval(1)
        )
      ),
    ])
    let fixture = try AgentModelFixture(now: now, loader: loader.load)
    defer {
      releaseStaleLoad.signal()
      releaseClearLoad.signal()
      fixture.removeScratchDirectory()
    }
    #expect(await eventually { loader.callCount == 1 })

    fixture.model.agentIntegration.clearAgentSignals(at: now.addingTimeInterval(1))
    releaseStaleLoad.signal()
    #expect(await eventually { loader.callCount == 2 })

    #expect(fixture.model.agentIntegration.activeAgentSignal == nil)
    releaseClearLoad.signal()
    #expect(await eventually { loader.completedCallCount == 2 })
  }

  @MainActor
  @Test("an unchanged inbox still advances the polling interval")
  func unchangedAgentSignalInboxAdvancesPolling() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_700)
    let unchangedInbox = IdleScreenAgentSignalInbox(
      revision: 4,
      updatedAt: now
    )
    let loader = ScriptedAgentInboxLoader(steps: [
      .success(unchangedInbox),
      .success(unchangedInbox),
      .success(unchangedInbox),
    ])
    let fixture = try AgentModelFixture(now: now, loader: loader.load)
    defer { fixture.removeScratchDirectory() }
    #expect(await eventually { loader.completedCallCount == 1 })

    fixture.model.agentIntegration.refreshAgentSignals(at: now.addingTimeInterval(1))
    #expect(await eventually { loader.completedCallCount == 2 })
    fixture.model.agentIntegration.refreshAgentSignals(at: now.addingTimeInterval(1.5))
    try? await Task.sleep(for: .milliseconds(50))

    #expect(loader.callCount == 2)
  }

  @MainActor
  @Test("regular ticks do not invalidate a slow read in progress")
  func regularTicksCoalesceIntoSlowRead() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_450)
    let signal = try testSignal(provider: .codex, eventID: "slow", at: now)
    let release = DispatchSemaphore(value: 0)
    let loader = ScriptedAgentInboxLoader(steps: [
      .blocked(
        release: release,
        inbox: IdleScreenAgentSignalInbox(revision: 1, updatedAt: now, signals: [signal])
      )
    ])
    let fixture = try AgentModelFixture(now: now, loader: loader.load)
    defer {
      release.signal()
      fixture.removeScratchDirectory()
    }
    #expect(await eventually { loader.callCount == 1 })

    fixture.model.agentIntegration.refreshAgentSignals()
    fixture.model.agentIntegration.refreshAgentSignals()
    release.signal()

    #expect(await eventually { fixture.model.agentIntegration.activeAgentSignal == signal })
    #expect(loader.callCount == 1)
  }

  @MainActor
  @Test("a read that finishes after a signal expired does not publish it")
  func lateReadDoesNotPublishExpiredSignal() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_460)
    let signal = try testSignal(provider: .codex, eventID: "expiring", at: now)
    let clockBox = MutableTestClock(now)
    let release = DispatchSemaphore(value: 0)
    let loader = ScriptedAgentInboxLoader(steps: [
      .blocked(
        release: release,
        inbox: IdleScreenAgentSignalInbox(revision: 1, updatedAt: now, signals: [signal])
      )
    ])
    let fixture = try AgentModelFixture(now: now, clock: clockBox.read, loader: loader.load)
    defer {
      release.signal()
      fixture.removeScratchDirectory()
    }
    #expect(await eventually { loader.callCount == 1 })

    clockBox.set(now.addingTimeInterval(120))
    release.signal()
    #expect(await eventually { loader.completedCallCount == 1 })
    try? await Task.sleep(for: .milliseconds(50))

    #expect(fixture.model.agentIntegration.activeAgentSignal == nil)
    #expect(fixture.model.agentIntegration.activeAgentSignals.isEmpty)
  }

  @MainActor
  @Test("an identical inbox republishes after a failed read")
  func identicalInboxRepublishesAfterFailure() async throws {
    let now = Date(timeIntervalSince1970: 1_786_296_470)
    let signal = try testSignal(provider: .claude, eventID: "recover", at: now)
    let inbox = IdleScreenAgentSignalInbox(revision: 5, updatedAt: now, signals: [signal])
    let loader = ScriptedAgentInboxLoader(steps: [
      .success(inbox),
      .failure(.expectedFailure),
      .success(inbox),
    ])
    let fixture = try AgentModelFixture(now: now, loader: loader.load)
    defer { fixture.removeScratchDirectory() }
    #expect(await eventually { fixture.model.agentIntegration.activeAgentSignal == signal })

    fixture.model.agentIntegration.refreshAgentSignals(at: now.addingTimeInterval(1))
    #expect(await eventually { fixture.model.agentIntegration.activeAgentSignal == nil })
    #expect(fixture.model.agentIntegration.status?.contains("unavailable") == true)

    fixture.model.agentIntegration.refreshAgentSignals(at: now.addingTimeInterval(2))
    #expect(await eventually { fixture.model.agentIntegration.activeAgentSignal == signal })
  }

  @MainActor
  @Test("hook mutations report unavailable App Group access")
  func hookMutationsRequireAppGroup() throws {
    let now = Date(timeIntervalSince1970: 1_786_296_800)
    let fixture = try AgentModelFixture(
      now: now,
      appGroupIdentifier: nil
    )
    defer { fixture.removeScratchDirectory() }

    fixture.model.agentIntegration.installAgentHooks(for: .codex)
    #expect(
      fixture.model.agentIntegration.status
        == "Hook installation unavailable until the app is signed for its App Group.")
    fixture.model.agentIntegration.uninstallAgentHooks(for: .codex)
    #expect(
      fixture.model.agentIntegration.status
        == "Hook removal unavailable until the app is signed for its App Group.")
  }

  @MainActor
  @Test("a malformed provider file does not hide the other installed provider")
  func hookStatusIsProviderIndependent() throws {
    let fixture = try AgentModelFixture(
      now: Date(timeIntervalSince1970: 1_786_296_900)
    )
    defer { fixture.removeScratchDirectory() }
    fixture.model.agentIntegration.installAgentHooks(for: .codex)
    try FileManager.default.createDirectory(
      at: fixture.claudeSettingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{malformed".utf8).write(to: fixture.claudeSettingsURL)

    fixture.model.agentIntegration.refreshAgentHookInstallationStatus()

    #expect(fixture.model.agentIntegration.codexHooksInstalled)
    #expect(!fixture.model.agentIntegration.claudeHooksInstalled)
    #expect(
      fixture.model.agentIntegration.status?
        .contains("Claude hook status unavailable") == true
    )
  }
}

private final class TestBundleMarker {}

private enum AgentModelTestError: Error {
  case expectedFailure
  case missingScriptedResult
}

private final class MutableTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  @Sendable func read() -> Date {
    lock.withLock { date }
  }

  func set(_ newDate: Date) {
    lock.withLock { date = newDate }
  }
}

private final class ScriptedAgentInboxLoader: @unchecked Sendable {
  enum Step: Sendable {
    case success(IdleScreenAgentSignalInbox)
    case failure(AgentModelTestError)
    case blocked(
      release: DispatchSemaphore,
      inbox: IdleScreenAgentSignalInbox
    )
  }

  private let lock = NSLock()
  private var steps: [Step]
  private var dates: [Date] = []
  private var completedCount = 0

  init(steps: [Step]) {
    self.steps = steps
  }

  var callCount: Int {
    lock.withLock { dates.count }
  }

  var loadedDates: [Date] {
    lock.withLock { dates }
  }

  var completedCallCount: Int {
    lock.withLock { completedCount }
  }

  func load(
    store: IdleScreenAgentSignalStore,
    at date: Date
  ) throws -> IdleScreenAgentSignalInbox {
    let step = lock.withLock { () -> Step? in
      dates.append(date)
      return steps.isEmpty ? nil : steps.removeFirst()
    }
    defer {
      lock.withLock {
        completedCount += 1
      }
    }
    switch step {
    case .success(let inbox):
      return inbox
    case .failure(let error):
      throw error
    case .blocked(let release, let inbox):
      release.wait()
      return inbox
    case nil:
      throw AgentModelTestError.missingScriptedResult
    }
  }
}

@MainActor
private final class AgentModelFixture {
  let root: URL
  let codexSettingsURL: URL
  let claudeSettingsURL: URL
  let store: IdleScreenAgentSignalStore
  let model: IdleScreenAppModel

  init(
    now: Date,
    appGroupIdentifier: String? = "group.com.idlescreen.tests.shared",
    clock: (@Sendable () -> Date)? = nil,
    loader:
      @escaping @Sendable (
        IdleScreenAgentSignalStore,
        Date
      ) throws -> IdleScreenAgentSignalInbox = { store, date in
        try store.read(at: date)
      }
  ) throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let sharedPaths = IdleScreenSharedPaths(
      rootURL: root.appending(path: "Shared", directoryHint: .isDirectory)
    )
    codexSettingsURL = root.appending(path: "Home/.codex/hooks.json")
    claudeSettingsURL = root.appending(path: "Home/.claude/settings.json")
    store = IdleScreenAgentSignalStore(fileURL: sharedPaths.agentSignalsInboxURL)
    model = IdleScreenAppModel(
      bundle: Bundle(for: TestBundleMarker.self),
      agentIntegrationDependencies: .init(
        sharedPaths: sharedPaths,
        appGroupIdentifier: appGroupIdentifier,
        legacyConfigurationURLs: [root.appending(path: "Legacy/config.json")],
        codexHookSettingsURL: codexSettingsURL,
        claudeHookSettingsURL: claudeSettingsURL,
        agentControlExecutableURL: root.appending(path: "Helpers/idlescreenctl"),
        clock: clock ?? { now },
        loadAgentSignals: loader
      )
    )
  }

  func removeScratchDirectory() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func testSignal(
  provider: IdleScreenAgentProvider,
  eventID: String,
  at date: Date
) throws -> IdleScreenAgentSignal {
  try IdleScreenAgentSignal.validated(
    provider: provider,
    sessionID: "test-session",
    eventID: eventID,
    state: .needsAttention,
    title: "Needs attention",
    message: "Scratch-only test",
    temporaryLookID: nil,
    priority: 10,
    createdAt: date,
    expiresAt: date.addingTimeInterval(60),
    acknowledgedAt: nil,
    nonce: "nonce-\(eventID)",
    validatedAt: date
  )
}

@MainActor
private func eventually(
  _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@MainActor
@Suite("Companion configuration load failure")
struct ConfigurationLoadFailureTests {
  private func makeModel(
    root: URL,
    sharedPaths: IdleScreenSharedPaths
  ) -> IdleScreenAppModel {
    IdleScreenAppModel(
      bundle: Bundle(for: TestBundleMarker.self),
      agentIntegrationDependencies: .init(
        sharedPaths: sharedPaths,
        appGroupIdentifier: "group.com.idlescreen.tests.shared",
        legacyConfigurationURLs: [root.appending(path: "Legacy/config.json")],
        codexHookSettingsURL: root.appending(path: "Home/.codex/hooks.json"),
        claudeHookSettingsURL: root.appending(path: "Home/.claude/settings.json"),
        agentControlExecutableURL: root.appending(path: "Helpers/idlescreenctl"),
        clock: { Date(timeIntervalSince1970: 1_800_000_000) },
        loadAgentSignals: { store, date in try store.read(at: date) }
      )
    )
  }

  private func scratch() throws -> (root: URL, paths: IdleScreenSharedPaths) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = IdleScreenSharedPaths(
      rootURL: root.appending(path: "Shared", directoryHint: .isDirectory)
    )
    try FileManager.default.createDirectory(
      at: paths.configurationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    return (root, paths)
  }

  private func assertEditsNeverOverwrite(original: Data, name: String) throws {
    let (root, paths) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try original.write(to: paths.configurationURL)

    let model = makeModel(root: root, sharedPaths: paths)
    #expect(model.configurationLoadFailure != nil, "\(name)")
    #expect(try Data(contentsOf: paths.configurationURL) == original, "\(name) after init")

    let failure = model.configurationLoadFailure
    for seed: UInt64 in [11, 12, 13] {
      model.lastError = nil
      model.updatePixelMaterials { $0.seed = seed }
      #expect(model.configuration.materials.seed == seed, "\(name) edit applied in memory")
      #expect(model.lastError == failure, "\(name) surfaces the retained error")
      #expect(try Data(contentsOf: paths.configurationURL) == original, "\(name) after edits")
    }
    #expect(model.configurationLoadFailure == failure)
  }

  @Test("Malformed configuration is never overwritten by edits")
  func malformedConfigurationSurvivesEdits() throws {
    try assertEditsNeverOverwrite(
      original: Data("{ not json at all".utf8),
      name: "malformed"
    )
  }

  @Test("Future-schema configuration is never overwritten by edits")
  func futureSchemaConfigurationSurvivesEdits() throws {
    var future = IdleScreenConfiguration.default
    future.schemaVersion = IdleScreenConfiguration.currentSchemaVersion + 1
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(future)
    try assertEditsNeverOverwrite(original: data, name: "future schema")
  }

  @Test("Missing configuration initializes and persists normally")
  func missingConfigurationPersists() throws {
    let (root, paths) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(root: root, sharedPaths: paths)
    #expect(model.configurationLoadFailure == nil)
    #expect(FileManager.default.fileExists(atPath: paths.configurationURL.path))

    let before = model.configuration.revision
    model.updatePixelMaterial(.mixed)
    let stored = try IdleScreenConfigurationStore(fileURL: paths.configurationURL).read()
    #expect(stored?.materials.material == .mixed)
    #expect(stored?.revision == before &+ 1)
  }

  @Test("Supported existing configuration persists edits")
  func supportedConfigurationPersists() throws {
    let (root, paths) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try IdleScreenConfigurationStore(fileURL: paths.configurationURL).write(.default)

    let model = makeModel(root: root, sharedPaths: paths)
    #expect(model.configurationLoadFailure == nil)
    model.updatePixelMaterial(.mixed)
    let stored = try IdleScreenConfigurationStore(fileURL: paths.configurationURL).read()
    #expect(stored?.materials.material == .mixed)
  }
}

private final class SuspendedHealthLoader: @unchecked Sendable {
  private let lock = NSLock()
  private let release = DispatchSemaphore(value: 0)
  private var calls = 0
  private var firstEntered = false

  var callCount: Int { lock.withLock { calls } }
  var hasEntered: Bool { lock.withLock { firstEntered } }

  func resume() { release.signal() }

  /// The first call blocks until `resume()`; later calls return at once.
  func load(
    snapshots: [IdleScreenAppModel.ProcessHealthSnapshot]
  ) -> IdleScreenAppModel.ProcessHealthSnapshot {
    let index = lock.withLock { () -> Int in
      calls += 1
      if calls == 1 { firstEntered = true }
      return calls - 1
    }
    if index == 0 { release.wait() }
    return snapshots[min(index, snapshots.count - 1)]
  }
}

@MainActor
@Suite("Companion process health refresh")
struct ProcessHealthRefreshTests {
  private func report(_ pid: Int32, at seconds: TimeInterval) -> IdleScreenProcessHealth {
    IdleScreenProcessHealth(
      process: .cameraAgent,
      processIdentifier: pid,
      lifecycle: .attached,
      build: .init(version: "0.1", buildNumber: "1", bundleIdentifier: "com.idlescreen.tests"),
      updatedAt: Date(timeIntervalSince1970: seconds),
      issue: nil
    )
  }

  @Test("a suspended loader leaves the main actor free and stale results never win")
  func suspendedLoaderCoalescesAndKeepsNewest() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let older = IdleScreenAppModel.ProcessHealthSnapshot(
      reports: [report(1, at: 1)], liveReportIdentifiers: [])
    let newer = IdleScreenAppModel.ProcessHealthSnapshot(
      reports: [report(2, at: 2)], liveReportIdentifiers: [report(2, at: 2).reportIdentifier])
    let loader = SuspendedHealthLoader()
    let model = IdleScreenAppModel(
      bundle: Bundle(for: TestBundleMarker.self),
      agentIntegrationDependencies: .init(
        sharedPaths: IdleScreenSharedPaths(rootURL: root.appending(path: "Shared")),
        appGroupIdentifier: "group.com.idlescreen.tests.shared",
        legacyConfigurationURLs: [root.appending(path: "Legacy/config.json")],
        codexHookSettingsURL: root.appending(path: "Home/.codex/hooks.json"),
        claudeHookSettingsURL: root.appending(path: "Home/.claude/settings.json"),
        agentControlExecutableURL: root.appending(path: "Helpers/idlescreenctl"),
        clock: { Date(timeIntervalSince1970: 1_800_000_000) },
        loadAgentSignals: { store, date in try store.read(at: date) },
        loadProcessHealth: { _ in loader.load(snapshots: [older, newer]) }
      )
    )

    // Init started the first (suspended) pass.
    #expect(await eventually { loader.hasEntered })

    // The main actor still runs while the loader is blocked, and overlapping
    // refreshes coalesce rather than starting more loads.
    model.refreshProcessHealth()
    model.refreshProcessHealth()
    model.refreshProcessHealth()
    model.updatePixelMaterials { $0.seed = 4242 }
    #expect(model.configuration.materials.seed == 4242)
    #expect(model.processHealth.isEmpty)
    #expect(loader.callCount == 1)

    loader.resume()
    // The first pass publishes, then the single coalesced follow-up replaces it.
    #expect(await eventually { model.processHealth.map(\.processIdentifier) == [2] })
    #expect(model.isProcessReportLive(report(2, at: 2)))
    #expect(loader.callCount == 2)

    // No later write may bring the older snapshot back.
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.processHealth.map(\.processIdentifier) == [2])
  }
}
