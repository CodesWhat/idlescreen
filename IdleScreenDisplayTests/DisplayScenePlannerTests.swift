import Foundation
import IdleScreenCore
import Testing

@testable import IdleScreenDisplay

@Suite("Display scene planning")
struct DisplayScenePlannerTests {
    @Test("Panorama uses one scene with deterministic crops and partial shared edges")
    func panoramaCropsAndBoundaries() throws {
        let snapshot = try snapshot(
            generation: 4,
            displays: SceneTopologyFixtures.offsetThreeDisplays
        )
        let settings = DisplaySceneSettings(
            policy: .panorama,
            focalDisplayIdentifier: .init(rawValue: "right"),
            quietTreatment: .black,
            outerBoundaryBehavior: .wall,
            baseSeed: 42
        )

        let plan = try DisplayScenePlanner().makePlan(
            for: snapshot,
            settings: settings,
            sceneEpoch: 9
        )

        #expect(plan.topologyGeneration == 4)
        #expect(plan.policy == .panorama)
        #expect(plan.focalDisplayIdentifiers == [.init(rawValue: "right")])
        #expect(
            plan.assignments.map(\.displayIdentifier.rawValue) == [
                "left",
                "primary",
                "right",
            ])

        let left = try #require(plan.assignment(for: .init(rawValue: "left")))
        let primary = try #require(plan.assignment(for: .init(rawValue: "primary")))
        let right = try #require(plan.assignment(for: .init(rawValue: "right")))
        let world = DisplayTopology.Rect(x: -500, y: 0, width: 2_300, height: 800)

        #expect(left.role == .panorama)
        #expect(primary.role == .panorama)
        #expect(right.role == .panorama)
        #expect(left.scene == primary.scene)
        #expect(primary.scene == right.scene)
        #expect(
            primary.scene
                == .init(
                    identity: .panorama,
                    seed: 42,
                    epoch: 9,
                    bounds: world
                ))
        #expect(
            primary.viewport
                == .init(
                    frameInScene: .init(x: 0, y: 0, width: 1_000, height: 800),
                    normalizedFrame: .init(
                        x: 500.0 / 2_300.0,
                        y: 0,
                        width: 1_000.0 / 2_300.0,
                        height: 1
                    )
                ))
        #expect(
            right.viewport?.normalizedFrame
                == .init(
                    x: 1_500.0 / 2_300.0,
                    y: 100.0 / 800.0,
                    width: 800.0 / 2_300.0,
                    height: 600.0 / 800.0
                ))
        #expect(!primary.ownsFocalElement)
        #expect(right.ownsFocalElement)

        #expect(
            primary.boundaries.filter { $0.edge == .left } == [
                .init(
                    edge: .left,
                    span: .init(axis: .vertical, lowerBound: 0, upperBound: 200),
                    disposition: .outer(.wall)
                ),
                .init(
                    edge: .left,
                    span: .init(axis: .vertical, lowerBound: 200, upperBound: 600),
                    disposition: .shared(
                        neighborIdentifier: .init(rawValue: "left"),
                        neighborEdge: .right
                    )
                ),
                .init(
                    edge: .left,
                    span: .init(axis: .vertical, lowerBound: 600, upperBound: 800),
                    disposition: .outer(.wall)
                ),
            ])
        #expect(
            primary.boundaries.filter { $0.edge == .right } == [
                .init(
                    edge: .right,
                    span: .init(axis: .vertical, lowerBound: 0, upperBound: 100),
                    disposition: .outer(.wall)
                ),
                .init(
                    edge: .right,
                    span: .init(axis: .vertical, lowerBound: 100, upperBound: 700),
                    disposition: .shared(
                        neighborIdentifier: .init(rawValue: "right"),
                        neighborEdge: .left
                    )
                ),
                .init(
                    edge: .right,
                    span: .init(axis: .vertical, lowerBound: 700, upperBound: 800),
                    disposition: .outer(.wall)
                ),
            ])
    }

    @Test("Per Display creates stable independent scenes with full local viewports")
    func perDisplayScenes() throws {
        let topology = try DisplayTopology(
            displays: SceneTopologyFixtures.offsetThreeDisplays
        )
        let settings = DisplaySceneSettings(
            policy: .perDisplay,
            outerBoundaryBehavior: .drain,
            baseSeed: 42
        )
        let planner = DisplayScenePlanner()
        let first = try planner.makePlan(
            for: .init(generation: 5, topology: topology),
            settings: settings,
            sceneEpoch: 11
        )
        let repeated = try planner.makePlan(
            for: .init(generation: 5, topology: topology),
            settings: settings,
            sceneEpoch: 11
        )

        #expect(first == repeated)
        #expect(
            first.focalDisplayIdentifiers.map(\.rawValue) == [
                "left",
                "primary",
                "right",
            ])

        let left = try #require(first.assignment(for: .init(rawValue: "left")))
        let primary = try #require(first.assignment(for: .init(rawValue: "primary")))
        let right = try #require(first.assignment(for: .init(rawValue: "right")))

        #expect(left.role == .independent)
        #expect(left.scene?.identity == .display(.init(rawValue: "left")))
        #expect(left.scene?.seed == 6_204_341_043_383_119_890)
        #expect(primary.scene?.seed == 7_852_743_785_725_505_723)
        #expect(right.scene?.seed == 9_195_891_712_254_578_247)
        #expect(left.scene?.seed != primary.scene?.seed)
        #expect(
            left.viewport
                == .init(
                    frameInScene: .init(x: 0, y: 0, width: 500, height: 400),
                    normalizedFrame: .init(x: 0, y: 0, width: 1, height: 1)
                ))
        #expect(left.ownsFocalElement)
        #expect(primary.ownsFocalElement)
        #expect(right.ownsFocalElement)
        #expect(primary.boundaries.allSatisfy { $0.disposition == .outer(.drain) })
    }

    @Test("Focus renders one selected display and assigns a quiet treatment to peers")
    func focusDisplayAndQuietPeers() throws {
        let plan = try DisplayScenePlanner().makePlan(
            for: snapshot(
                generation: 6,
                displays: SceneTopologyFixtures.offsetThreeDisplays
            ),
            settings: .init(
                policy: .focusDisplay,
                focalDisplayIdentifier: .init(rawValue: "left"),
                quietTreatment: .subdued,
                outerBoundaryBehavior: .offWorld,
                baseSeed: 42
            ),
            sceneEpoch: 12
        )

        let left = try #require(plan.assignment(for: .init(rawValue: "left")))
        let primary = try #require(plan.assignment(for: .init(rawValue: "primary")))
        let right = try #require(plan.assignment(for: .init(rawValue: "right")))

        #expect(plan.focalDisplayIdentifiers == [.init(rawValue: "left")])
        #expect(left.role == .focus)
        #expect(left.scene?.identity == .focus(.init(rawValue: "left")))
        #expect(left.scene?.seed == 7_511_645_640_986_348_152)
        #expect(left.viewport?.normalizedFrame == .init(x: 0, y: 0, width: 1, height: 1))
        #expect(left.ownsFocalElement)
        #expect(left.boundaries.allSatisfy { $0.disposition == .outer(.offWorld) })
        #expect(primary.role == .quiet(.subdued))
        #expect(primary.scene == nil)
        #expect(primary.viewport == nil)
        #expect(primary.boundaries.isEmpty)
        #expect(right.role == .quiet(.subdued))
        #expect(!right.ownsFocalElement)
    }

    @Test("Unavailable focus falls back to primary and a mirror request resolves to its leader")
    func focusResolution() throws {
        let planner = DisplayScenePlanner()
        let snapshot = try snapshot(
            generation: 7,
            displays: SceneTopologyFixtures.mirrored
        )
        let missing = try planner.makePlan(
            for: snapshot,
            settings: .init(
                policy: .focusDisplay,
                focalDisplayIdentifier: .init(rawValue: "removed")
            ),
            sceneEpoch: 1
        )
        let mirror = try planner.makePlan(
            for: snapshot,
            settings: .init(
                policy: .focusDisplay,
                focalDisplayIdentifier: .init(rawValue: "projector")
            ),
            sceneEpoch: 1
        )

        #expect(missing.focalDisplayIdentifiers == [.init(rawValue: "primary")])
        #expect(mirror.focalDisplayIdentifiers == [.init(rawValue: "primary")])
        #expect(missing == mirror)
    }

    @Test("Mirror followers reuse leader content without duplicate focal or boundaries")
    func mirrorAssignments() throws {
        let plan = try DisplayScenePlanner().makePlan(
            for: snapshot(
                generation: 8,
                displays: SceneTopologyFixtures.mirrored
            ),
            settings: .init(
                policy: .panorama,
                focalDisplayIdentifier: .init(rawValue: "projector"),
                baseSeed: 99
            ),
            sceneEpoch: 2
        )

        let leader = try #require(plan.assignment(for: .init(rawValue: "primary")))
        let mirror = try #require(plan.assignment(for: .init(rawValue: "projector")))

        #expect(mirror.representativeIdentifier == .init(rawValue: "primary"))
        #expect(mirror.isMirrorFollower)
        #expect(mirror.role == leader.role)
        #expect(mirror.scene == leader.scene)
        #expect(mirror.viewport == leader.viewport)
        #expect(!mirror.ownsFocalElement)
        #expect(mirror.boundaries.isEmpty)
        #expect(leader.ownsFocalElement)
        #expect(plan.assignments.filter(\.ownsFocalElement).count == 1)
    }

    @Test("Physical gaps never become shared edges")
    func gappedDisplays() throws {
        let plan = try DisplayScenePlanner().makePlan(
            for: snapshot(
                generation: 9,
                displays: SceneTopologyFixtures.gapped
            ),
            settings: .init(
                policy: .panorama,
                outerBoundaryBehavior: .offWorld
            ),
            sceneEpoch: 3
        )
        let primary = try #require(plan.assignment(for: .init(rawValue: "primary")))
        let gapped = try #require(plan.assignment(for: .init(rawValue: "gapped")))

        #expect(
            primary.boundaries.filter { $0.edge == .right } == [
                .init(
                    edge: .right,
                    span: .init(axis: .vertical, lowerBound: 0, upperBound: 800),
                    disposition: .outer(.offWorld)
                )
            ])
        #expect(
            gapped.boundaries.filter { $0.edge == .left } == [
                .init(
                    edge: .left,
                    span: .init(axis: .vertical, lowerBound: 0, upperBound: 800),
                    disposition: .outer(.offWorld)
                )
            ])
        #expect(
            plan.assignments.flatMap(\.boundaries).allSatisfy {
                if case .shared = $0.disposition { return false }
                return true
            })
    }

    @Test("Zero and stale topology generations fail closed")
    func generationFencing() throws {
        let topology = try DisplayTopology(displays: SceneTopologyFixtures.single)
        let planner = DisplayScenePlanner()

        #expect(throws: DisplayScenePlanningError.invalidTopologyGeneration(0)) {
            try planner.makePlan(
                for: .init(generation: 0, topology: topology),
                settings: .init(policy: .panorama),
                sceneEpoch: 1
            )
        }
        #expect(
            throws: DisplayScenePlanningError.staleTopologyGeneration(
                received: 10,
                accepted: 10
            )
        ) {
            try planner.makePlan(
                for: .init(generation: 10, topology: topology),
                settings: .init(policy: .panorama),
                sceneEpoch: 1,
                after: 10
            )
        }
        #expect(
            throws: DisplayScenePlanningError.staleTopologyGeneration(
                received: 9,
                accepted: 10
            )
        ) {
            try planner.makePlan(
                for: .init(generation: 9, topology: topology),
                settings: .init(policy: .panorama),
                sceneEpoch: 1,
                after: 10
            )
        }

        let accepted = try planner.makePlan(
            for: .init(generation: 11, topology: topology),
            settings: .init(policy: .panorama),
            sceneEpoch: 1,
            after: 10
        )
        #expect(accepted.topologyGeneration == 11)
    }

    @Test("Canonical topology order produces byte-for-byte equal plans")
    func inputOrderIsIrrelevant() throws {
        let forward = try snapshot(
            generation: 12,
            displays: SceneTopologyFixtures.offsetThreeDisplays
        )
        let reversed = try snapshot(
            generation: 12,
            displays: SceneTopologyFixtures.offsetThreeDisplays.reversed()
        )
        let settings = DisplaySceneSettings(
            policy: .panorama,
            focalDisplayIdentifier: .init(rawValue: "right"),
            outerBoundaryBehavior: .wall,
            baseSeed: 123
        )
        let planner = DisplayScenePlanner()

        #expect(
            try planner.makePlan(
                for: forward,
                settings: settings,
                sceneEpoch: 4
            )
                == planner.makePlan(
                    for: reversed,
                    settings: settings,
                    sceneEpoch: 4
                ))
    }
}

private enum SceneTopologyFixtures {
    static let single = [
        display("primary", isPrimary: true)
    ]

    static let offsetThreeDisplays = [
        display(
            "primary",
            x: 0,
            y: 0,
            width: 1_000,
            height: 800,
            isPrimary: true
        ),
        display(
            "left",
            x: -500,
            y: 200,
            width: 500,
            height: 400
        ),
        display(
            "right",
            x: 1_000,
            y: 100,
            width: 800,
            height: 600
        ),
    ]

    static let mirrored = [
        display("primary", isPrimary: true),
        display("projector", mirrorTarget: "primary"),
        display("right", x: 1_000),
    ]

    static let gapped = [
        display("primary", isPrimary: true),
        display("gapped", x: 1_020),
    ]

    static func display(
        _ identifier: String,
        x: Double = 0,
        y: Double = 0,
        width: Double = 1_000,
        height: Double = 800,
        isPrimary: Bool = false,
        mirrorTarget: String? = nil
    ) -> DisplayTopology.Display {
        .init(
            persistentIdentifier: .init(rawValue: identifier),
            logicalFrame: .init(x: x, y: y, width: width, height: height),
            nativePixelSize: .init(width: Int(width), height: Int(height)),
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

private func snapshot(
    generation: UInt64,
    displays: some Collection<DisplayTopology.Display>
) throws -> DisplayTopologySnapshot {
    try .init(
        generation: generation,
        topology: DisplayTopology(displays: Array(displays))
    )
}
