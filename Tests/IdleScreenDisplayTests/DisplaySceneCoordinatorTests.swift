import Foundation
import IdleScreenCore
import Testing
@testable import IdleScreenDisplay

@MainActor
@Suite("Process-wide display scene coordination")
struct DisplaySceneCoordinatorTests {
    @Test("the first host starts observation and the final host releases all topology state")
    func referenceCountedLifecycle() throws {
        var reads = 0
        let topology = try SceneCoordinatorFixtures.topology(
            SceneCoordinatorFixtures.sideBySide
        )
        let coordinator = DisplaySceneCoordinator(
            notificationCenter: NotificationCenter(),
            notificationName: .init("scene-coordinator-test"),
            readTopology: {
                reads += 1
                return topology
            }
        )

        let first = coordinator.attach(
            settings: .default,
            configurationRevision: 3
        )
        let second = coordinator.attach(
            settings: .default,
            configurationRevision: 3
        )

        #expect(reads == 1)
        #expect(coordinator.activeHostCount == 2)
        #expect(coordinator.latestSnapshot?.generation == 1)
        #expect(coordinator.latestPlan?.topologyGeneration == 1)

        coordinator.detach(first)
        #expect(coordinator.activeHostCount == 1)
        #expect(coordinator.latestPlan != nil)

        coordinator.detach(second)
        #expect(coordinator.activeHostCount == 0)
        #expect(coordinator.latestSnapshot == nil)
        #expect(coordinator.latestPlan == nil)
        #expect(coordinator.settings == nil)
        #expect(coordinator.configurationRevision == nil)

        coordinator.refreshTopology()
        #expect(reads == 1)
        #expect(!coordinator.update(
            settings: .init(policy: .perDisplay),
            configurationRevision: 4
        ))
        #expect(coordinator.settings == nil)
        #expect(coordinator.configurationRevision == nil)
    }

    @Test("hot plug replaces the whole plan and resolves a removed focus to primary")
    func hotPlugReprojection() throws {
        let reader = SceneCoordinatorReaderFixture(
            topology: try SceneCoordinatorFixtures.topology(
                SceneCoordinatorFixtures.sideBySide
            )
        )
        let coordinator = DisplaySceneCoordinator(
            notificationCenter: NotificationCenter(),
            notificationName: .init("scene-coordinator-hotplug"),
            readTopology: { try reader.read() }
        )
        let token = coordinator.attach(
            settings: .init(
                policy: .focusDisplay,
                focalDisplayIdentifier: .init(rawValue: "right")
            ),
            configurationRevision: 8
        )
        defer { coordinator.detach(token) }

        #expect(coordinator.latestPlan?.topologyGeneration == 1)
        #expect(coordinator.latestPlan?.focalDisplayIdentifiers == [
            .init(rawValue: "right")
        ])
        #expect(coordinator.latestPlan?.assignment(
            for: .init(rawValue: "right")
        ) != nil)

        reader.succeed(try SceneCoordinatorFixtures.topology(
            SceneCoordinatorFixtures.single
        ))
        coordinator.refreshTopology()

        #expect(coordinator.latestPlan?.topologyGeneration == 2)
        #expect(coordinator.latestPlan?.focalDisplayIdentifiers == [
            .init(rawValue: "primary")
        ])
        #expect(coordinator.latestPlan?.assignment(
            for: .init(rawValue: "right")
        ) == nil)
        #expect(coordinator.latestPlan?.assignments.count == 1)
    }

    @Test("configuration revisions replan once and reject stale or conflicting values")
    func configurationRevisionFencing() throws {
        let coordinator = DisplaySceneCoordinator(
            notificationCenter: NotificationCenter(),
            notificationName: .init("scene-coordinator-configuration"),
            readTopology: {
                try SceneCoordinatorFixtures.topology(
                    SceneCoordinatorFixtures.sideBySide
                )
            }
        )
        let token = coordinator.attach(
            settings: .default,
            configurationRevision: 10
        )
        defer { coordinator.detach(token) }

        #expect(coordinator.latestPlan?.policy == .panorama)
        #expect(coordinator.update(
            settings: .init(policy: .perDisplay, baseSeed: 7),
            configurationRevision: 11
        ))
        #expect(coordinator.latestPlan?.policy == .perDisplay)
        #expect(coordinator.latestPlan?.topologyGeneration == 1)
        #expect(coordinator.configurationRevision == 11)

        #expect(!coordinator.update(
            settings: .init(policy: .focusDisplay),
            configurationRevision: 10
        ))
        #expect(coordinator.lastFailure == .staleConfigurationRevision(
            received: 10,
            accepted: 11
        ))
        #expect(!coordinator.update(
            settings: .init(policy: .focusDisplay),
            configurationRevision: 11
        ))
        #expect(coordinator.lastFailure == .conflictingConfigurationRevision(11))
        #expect(coordinator.latestPlan?.policy == .perDisplay)

        #expect(coordinator.update(
            settings: .init(policy: .perDisplay, baseSeed: 7),
            configurationRevision: 11
        ))
        #expect(coordinator.lastFailure == nil)
    }

    @Test("failed refresh retains the last accepted plan and later recovery advances once")
    func failedRefreshRetention() throws {
        let reader = SceneCoordinatorReaderFixture(
            topology: try SceneCoordinatorFixtures.topology(
                SceneCoordinatorFixtures.single
            )
        )
        let coordinator = DisplaySceneCoordinator(
            notificationCenter: NotificationCenter(),
            notificationName: .init("scene-coordinator-failure"),
            readTopology: { try reader.read() }
        )
        let token = coordinator.attach(
            settings: .default,
            configurationRevision: 1
        )
        defer { coordinator.detach(token) }

        reader.fail()
        coordinator.refreshTopology()
        #expect(coordinator.latestPlan?.topologyGeneration == 1)
        #expect(coordinator.topologyFailure != nil)

        reader.succeed(try SceneCoordinatorFixtures.topology(
            SceneCoordinatorFixtures.sideBySide
        ))
        coordinator.refreshTopology()
        #expect(coordinator.latestPlan?.topologyGeneration == 2)
        #expect(coordinator.topologyFailure == nil)
    }

    @Test("logical host frames resolve only to rendering representatives")
    func hostFrameResolution() throws {
        let coordinator = DisplaySceneCoordinator(
            notificationCenter: NotificationCenter(),
            notificationName: .init("scene-coordinator-resolution"),
            readTopology: {
                try SceneCoordinatorFixtures.topology(
                    SceneCoordinatorFixtures.mirrored
                )
            }
        )
        let token = coordinator.attach(
            settings: .default,
            configurationRevision: 1
        )
        defer { coordinator.detach(token) }

        #expect(coordinator.representativeIdentifier(
            for: .init(x: 0, y: 0, width: 1_000, height: 800)
        ) == .init(rawValue: "primary"))
        #expect(coordinator.representativeIdentifier(
            for: .init(x: 1_050, y: 10, width: 800, height: 700)
        ) == .init(rawValue: "right"))
        #expect(coordinator.representativeIdentifier(
            for: .init(x: 4_000, y: 0, width: 100, height: 100)
        ) == nil)
    }
}

@MainActor
private final class SceneCoordinatorReaderFixture {
    enum Failure: Error { case unavailable }

    private var result: Result<DisplayTopology, Failure>

    init(topology: DisplayTopology) {
        result = .success(topology)
    }

    func read() throws -> DisplayTopology {
        try result.get()
    }

    func fail() {
        result = .failure(.unavailable)
    }

    func succeed(_ topology: DisplayTopology) {
        result = .success(topology)
    }
}

private enum SceneCoordinatorFixtures {
    static let single = [
        display("primary", isPrimary: true),
    ]

    static let sideBySide = [
        display("primary", isPrimary: true),
        display("right", x: 1_000),
    ]

    static let mirrored = [
        display("primary", isPrimary: true),
        display("projector", mirrorTarget: "primary"),
        display("right", x: 1_000),
    ]

    static func topology(
        _ displays: [DisplayTopology.Display]
    ) throws -> DisplayTopology {
        try DisplayTopology(displays: displays)
    }

    static func display(
        _ identifier: String,
        x: Double = 0,
        isPrimary: Bool = false,
        mirrorTarget: String? = nil
    ) -> DisplayTopology.Display {
        .init(
            persistentIdentifier: .init(rawValue: identifier),
            logicalFrame: .init(x: x, y: 0, width: 1_000, height: 800),
            nativePixelSize: .init(width: 1_000, height: 800),
            backingScale: 1,
            rotationDegrees: 0,
            refreshRateRange: .init(
                minimumHz: 60,
                maximumHz: 60,
                currentHz: 60
            ),
            safeAreaInsets: .zero,
            isPrimary: isPrimary,
            mirrorTargetIdentifier: mirrorTarget.map {
                .init(rawValue: $0)
            }
        )
    }
}
