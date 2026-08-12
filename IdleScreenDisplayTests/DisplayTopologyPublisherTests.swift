import Foundation
import IdleScreenCore
import Testing

@testable import IdleScreenDisplay

@Suite("Display topology observation adapter")
struct DisplayTopologyObservationAdapterTests {
    @Test("runtime mirror identities resolve to persistent topology identities")
    func resolvesMirrorIdentities() throws {
        let topology = try DisplayTopologyObservationAdapter().topology(from: [
            observation(
                runtimeID: 30,
                persistentID: "projector",
                frame: .init(x: 0, y: 0, width: 1_920, height: 1_080),
                pixels: .init(width: 1_280, height: 720),
                scale: 1,
                mirrorTargetRuntimeID: 10
            ),
            observation(
                runtimeID: 20,
                persistentID: "right",
                frame: .init(x: 1_920, y: 0, width: 1_280, height: 1_024),
                pixels: .init(width: 2_560, height: 2_048),
                scale: 2,
                refresh: .init(minimumHz: 48, maximumHz: 120, currentHz: 60)
            ),
            observation(
                runtimeID: 10,
                persistentID: "primary",
                frame: .init(x: 0, y: 0, width: 1_920, height: 1_080),
                pixels: .init(width: 3_840, height: 2_160),
                scale: 2,
                isPrimary: true
            ),
        ])

        #expect(
            topology.displays.map(\.persistentIdentifier.rawValue) == [
                "primary",
                "projector",
                "right",
            ])
        let projector = try #require(
            topology.displays.first {
                $0.persistentIdentifier.rawValue == "projector"
            })
        #expect(projector.mirrorTargetIdentifier?.rawValue == "primary")
        #expect(projector.nativePixelSize == .init(width: 1_280, height: 720))
        #expect(topology.adjacencies.count == 1)
    }

    @Test("a missing runtime mirror target fails before publishing an invalid snapshot")
    func rejectsMissingMirrorTarget() {
        #expect(
            throws: DisplayTopologyObservationError.missingMirrorTarget(
                display: .init(rawValue: 30),
                target: .init(rawValue: 999)
            )
        ) {
            try DisplayTopologyObservationAdapter().topology(from: [
                observation(
                    runtimeID: 10,
                    persistentID: "primary",
                    isPrimary: true
                ),
                observation(
                    runtimeID: 30,
                    persistentID: "projector",
                    mirrorTargetRuntimeID: 999
                ),
            ])
        }
    }

    @Test("duplicate transient runtime identities fail deterministically")
    func rejectsDuplicateRuntimeIdentity() {
        #expect(
            throws: DisplayTopologyObservationError.duplicateRuntimeIdentifier(
                .init(rawValue: 10)
            )
        ) {
            try DisplayTopologyObservationAdapter().topology(from: [
                observation(
                    runtimeID: 10,
                    persistentID: "primary",
                    isPrimary: true
                ),
                observation(
                    runtimeID: 10,
                    persistentID: "duplicate"
                ),
            ])
        }
    }

    @MainActor
    @Test("the macOS reader validates observations through the shared adapter")
    func macReaderUsesSharedAdapter() throws {
        let reader = MacDisplayTopologyReader(readObservations: {
            [
                observation(
                    runtimeID: 10,
                    persistentID: "primary",
                    isPrimary: true
                )
            ]
        })

        let topology = try reader.readTopology()

        #expect(topology.displays.count == 1)
        #expect(topology.displays[0].persistentIdentifier.rawValue == "primary")
    }
}

@MainActor
@Suite("Generation-fenced display topology publisher")
struct DisplayTopologyPublisherTests {
    @Test("only accepted topology changes advance the published generation")
    func publishesMonotonicChanges() throws {
        let reader = try TopologyReaderFixture(width: 1_920)
        let publisher = DisplayTopologyPublisher(
            notificationCenter: NotificationCenter(),
            notificationName: .init("DisplayTopologyPublisherTests.change"),
            readTopology: { try reader.read() }
        )
        var snapshots: [DisplayTopologySnapshot] = []
        _ = publisher.addObserver { snapshots.append($0) }

        publisher.start()
        publisher.start()
        publisher.refresh()
        try reader.succeed(width: 2_560)
        publisher.refresh()

        #expect(snapshots.map(\.generation) == [1, 2])
        #expect(publisher.latestSnapshot == snapshots.last)
        #expect(!snapshots[0].isNewer(than: snapshots[1].generation))
        #expect(snapshots[1].isNewer(than: snapshots[0].generation))
    }

    @Test("a failed refresh preserves the last valid generation")
    func rejectedRefreshPreservesSnapshot() throws {
        let reader = try TopologyReaderFixture(width: 1_920)
        let publisher = DisplayTopologyPublisher(
            notificationCenter: NotificationCenter(),
            notificationName: .init("DisplayTopologyPublisherTests.failure"),
            readTopology: { try reader.read() }
        )

        publisher.start()
        reader.fail()
        publisher.refresh()

        #expect(publisher.latestSnapshot?.generation == 1)
        #expect(publisher.lastFailure?.attempt == 2)
        #expect(publisher.lastFailure?.message.contains("unavailable") == true)

        try reader.succeed(width: 2_560)
        publisher.refresh()
        #expect(publisher.latestSnapshot?.generation == 2)
        #expect(publisher.lastFailure == nil)
    }

    @Test("start observes screen changes and stop removes the observation")
    func notificationLifecycle() async throws {
        let center = NotificationCenter()
        let name = Notification.Name("DisplayTopologyPublisherTests.lifecycle")
        let reader = try TopologyReaderFixture(width: 1_920)
        let publisher = DisplayTopologyPublisher(
            notificationCenter: center,
            notificationName: name,
            readTopology: { try reader.read() }
        )
        var snapshots: [DisplayTopologySnapshot] = []
        _ = publisher.addObserver { snapshots.append($0) }

        publisher.start()
        try reader.succeed(width: 2_560)
        center.post(name: name, object: nil)
        await settleMainActorTasks()
        publisher.stop()
        try reader.succeed(width: 3_000)
        center.post(name: name, object: nil)
        await settleMainActorTasks()

        #expect(snapshots.map(\.generation) == [1, 2])
        #expect(snapshots.last?.topology.desktopBounds.width == 2_560)
    }

    @Test("new observers receive the latest snapshot and removal stops delivery")
    func observationReplayAndRemoval() throws {
        let reader = try TopologyReaderFixture(width: 1_920)
        let publisher = DisplayTopologyPublisher(
            notificationCenter: NotificationCenter(),
            notificationName: .init("DisplayTopologyPublisherTests.observers"),
            readTopology: { try reader.read() }
        )
        publisher.start()

        var generations: [UInt64] = []
        let token = publisher.addObserver { generations.append($0.generation) }
        try reader.succeed(width: 2_560)
        publisher.refresh()
        publisher.removeObserver(token)
        try reader.succeed(width: 3_000)
        publisher.refresh()

        #expect(generations == [1, 2])
    }
}

@MainActor
private func settleMainActorTasks() async {
    for _ in 0..<4 {
        await Task.yield()
    }
}

private enum FixtureError: Error {
    case unavailable
}

@MainActor
private final class TopologyReaderFixture {
    private var result: Result<DisplayTopology, FixtureError>

    init(width: Double) throws {
        result = .success(try topology(width: width))
    }

    func read() throws -> DisplayTopology {
        try result.get()
    }

    func succeed(width: Double) throws {
        result = .success(try topology(width: width))
    }

    func fail() {
        result = .failure(.unavailable)
    }
}

private func topology(width: Double) throws -> DisplayTopology {
    try DisplayTopology(displays: [
        .init(
            persistentIdentifier: .init(rawValue: "primary"),
            logicalFrame: .init(x: 0, y: 0, width: width, height: 1_080),
            nativePixelSize: .init(width: Int(width * 2), height: 2_160),
            backingScale: 2,
            rotationDegrees: 0,
            refreshRateRange: nil,
            safeAreaInsets: .zero,
            isPrimary: true,
            mirrorTargetIdentifier: nil
        )
    ])
}

private func observation(
    runtimeID: UInt32,
    persistentID: String,
    frame: DisplayTopology.Rect = .init(x: 0, y: 0, width: 1_920, height: 1_080),
    pixels: DisplayTopology.PixelSize = .init(width: 1_920, height: 1_080),
    scale: Double = 1,
    rotation: Int = 0,
    refresh: DisplayTopology.RefreshRateRange? = nil,
    safeArea: DisplayTopology.SafeAreaInsets = .zero,
    isPrimary: Bool = false,
    mirrorTargetRuntimeID: UInt32? = nil
) -> DisplayTopologyObservation {
    .init(
        runtimeIdentifier: .init(rawValue: runtimeID),
        persistentIdentifier: .init(rawValue: persistentID),
        logicalFrame: frame,
        nativePixelSize: pixels,
        backingScale: scale,
        rotationDegrees: rotation,
        refreshRateRange: refresh,
        safeAreaInsets: safeArea,
        isPrimary: isPrimary,
        mirrorTargetRuntimeIdentifier: mirrorTargetRuntimeID.map {
            .init(rawValue: $0)
        }
    )
}
