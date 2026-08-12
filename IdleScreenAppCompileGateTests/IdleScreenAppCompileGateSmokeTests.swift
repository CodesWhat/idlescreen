import Foundation
import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import Testing

@Suite("Companion source compile gate")
struct IdleScreenAppCompileGateSmokeTests {
    @MainActor
    @Test("width-driven window resize excludes preview chrome from aspect ratio")
    func previewWindowWidthDrivenResize() {
        let content = IdleScreenAppDelegate.constrainedPreviewContentSize(
            proposed: CGSize(width: 1_681, height: 600),
            current: CGSize(width: 1_081, height: 600),
            previewAspectRatio: 1.6
        )

        #expect(content.width == 1_681)
        let previewRatio = (
            content.width - IdleScreenPreviewWindowGeometry.leadingChromeWidth
        ) / content.height
        #expect(abs(previewRatio - 1.6) < 0.000_001)
    }

    @MainActor
    @Test("height-driven window resize grows width around fixed preview chrome")
    func previewWindowHeightDrivenResize() {
        let content = IdleScreenAppDelegate.constrainedPreviewContentSize(
            proposed: CGSize(width: 1_081, height: 900),
            current: CGSize(width: 1_081, height: 600),
            previewAspectRatio: 1.6
        )

        #expect(content == CGSize(width: 1_521, height: 900))
    }

    @MainActor
    @Test("preview window cannot resize below a chrome-adjusted minimum")
    func previewWindowMinimumSize() {
        let content = IdleScreenAppDelegate.constrainedPreviewContentSize(
            proposed: CGSize(width: 500, height: 300),
            current: CGSize(width: 1_081, height: 600),
            previewAspectRatio: 1.6
        )

        #expect(content == CGSize(width: 1_041, height: 600))
    }

    @Test("saved window geometry normalizes to the preview aspect")
    func previewWindowNormalization() {
        let content = IdleScreenPreviewWindowGeometry.normalizedContentSize(
            current: CGSize(width: 1_200, height: 900),
            previewAspectRatio: 1.6
        )
        let previewRatio = (
            content.width - IdleScreenPreviewWindowGeometry.leadingChromeWidth
        ) / content.height

        #expect(content.width == 1_200)
        #expect(abs(previewRatio - 1.6) < 0.000_001)
    }

    @Test("all companion destinations are linked into the non-app test bundle")
    func companionSourcesAreLinked() {
        #expect(Destination.allCases.map(\.rawValue) == [
            "Studio",
            "Displays",
            "Integrations",
            "System",
        ])
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

    @Test("Pixel Materials inspector exposes the complete accessible control set")
    func materialsInspectorContract() {
        #expect(IdleScreenPixelMaterialsInspectorContract.controlLabels == [
            "Material",
            "Terrain",
            "Palette",
            "Seed",
            "Basin count",
            "Basin depth",
            "Minimum basin capacity",
            "Channel connectivity",
            "Channel width",
            "Rock ratio",
            "Soil ratio",
            "Emitter count",
            "Emitter position",
            "Emitter width",
            "Emitter rate",
            "Cell scale",
            "Gravity",
            "Lateral flow",
            "Equalization",
            "Water pressure",
            "Spill rate",
            "Drain rate",
            "Evaporation rate",
            "Obstacle density",
            "Persistence",
            "Quiet duration",
            "Fill duration",
            "Settled duration",
            "Drain duration",
            "Regeneration",
        ])
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

        model.testAgentSignal(for: .codex, at: now)
        #expect(await eventually { model.activeAgentSignal?.provider == .codex })
        _ = try fixture.store.apply(.recordIgnored(provider: .claude), at: now)
        model.refreshAgentSignals(at: now.addingTimeInterval(2))
        #expect(await eventually { model.agentIgnoredEventCounts[.claude] == 1 })

        model.installAgentHooks(for: .codex)
        model.installAgentHooks(for: .claude)
        model.refreshAgentHookInstallationStatus()
        #expect(model.codexHooksInstalled)
        #expect(model.claudeHooksInstalled)
        #expect(FileManager.default.fileExists(atPath: fixture.codexSettingsURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.claudeSettingsURL.path))
        #expect(fixture.codexSettingsURL.path.hasPrefix(fixture.root.path + "/"))
        #expect(fixture.claudeSettingsURL.path.hasPrefix(fixture.root.path + "/"))

        model.uninstallAgentHooks(for: .codex)
        model.uninstallAgentHooks(for: .claude)
        model.refreshAgentHookInstallationStatus()
        #expect(!model.codexHooksInstalled)
        #expect(!model.claudeHooksInstalled)

        model.clearAgentSignals(at: now.addingTimeInterval(3))
        #expect(await eventually { model.activeAgentSignal == nil })
        #expect(model.agentIntegrationStatus == "All agent signals cleared.")
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
            .success(IdleScreenAgentSignalInbox(
                revision: 8,
                updatedAt: now,
                signals: [signal],
                ignoredEventCounts: [.codex: 3]
            )),
        ])
        let fixture = try AgentModelFixture(now: now, loader: loader.load)
        defer { fixture.removeScratchDirectory() }

        #expect(await eventually {
            fixture.model.agentIntegrationStatus?.contains("unavailable") == true
        })
        fixture.model.refreshAgentSignals(at: now)

        #expect(await eventually { fixture.model.activeAgentSignal == signal })
        #expect(fixture.model.agentIgnoredEventCounts == [.codex: 3])
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
            .success(IdleScreenAgentSignalInbox(
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

        fixture.model.refreshAgentSignals(at: now.addingTimeInterval(1))
        fixture.model.refreshAgentSignals(at: now.addingTimeInterval(2))
        releaseFirstLoad.signal()

        #expect(await eventually { fixture.model.activeAgentSignal == newestSignal })
        #expect(fixture.model.agentIgnoredEventCounts == [.claude: 4])
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

        fixture.model.clearAgentSignals(at: now.addingTimeInterval(1))
        releaseStaleLoad.signal()
        #expect(await eventually { loader.callCount == 2 })

        #expect(fixture.model.activeAgentSignal == nil)
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

        fixture.model.refreshAgentSignals(at: now.addingTimeInterval(1))
        #expect(await eventually { loader.completedCallCount == 2 })
        fixture.model.refreshAgentSignals(at: now.addingTimeInterval(1.5))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(loader.callCount == 2)
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

        fixture.model.installAgentHooks(for: .codex)
        #expect(fixture.model.agentIntegrationStatus == "Hook installation unavailable until the app is signed for its App Group.")
        fixture.model.uninstallAgentHooks(for: .codex)
        #expect(fixture.model.agentIntegrationStatus == "Hook removal unavailable until the app is signed for its App Group.")
    }

    @MainActor
    @Test("a malformed provider file does not hide the other installed provider")
    func hookStatusIsProviderIndependent() throws {
        let fixture = try AgentModelFixture(
            now: Date(timeIntervalSince1970: 1_786_296_900)
        )
        defer { fixture.removeScratchDirectory() }
        fixture.model.installAgentHooks(for: .codex)
        try FileManager.default.createDirectory(
            at: fixture.claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{malformed".utf8).write(to: fixture.claudeSettingsURL)

        fixture.model.refreshAgentHookInstallationStatus()

        #expect(fixture.model.codexHooksInstalled)
        #expect(!fixture.model.claudeHooksInstalled)
        #expect(
            fixture.model.agentIntegrationStatus?
                .contains("Claude hook status unavailable") == true
        )
    }
}

private final class TestBundleMarker {}

private enum AgentModelTestError: Error {
    case expectedFailure
    case missingScriptedResult
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
        case let .success(inbox):
            return inbox
        case let .failure(error):
            throw error
        case let .blocked(release, inbox):
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
        loader: @escaping @Sendable (
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
                clock: { now },
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
