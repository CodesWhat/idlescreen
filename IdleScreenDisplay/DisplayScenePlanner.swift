import IdleScreenCore

public enum DisplayScenePlanningError: Error, Equatable, Sendable {
    case invalidTopologyGeneration(UInt64)
    case staleTopologyGeneration(received: UInt64, accepted: UInt64)
}

public enum DisplaySceneIdentity: Equatable, Sendable {
    case panorama
    case display(DisplayTopology.PersistentDisplayIdentifier)
    case focus(DisplayTopology.PersistentDisplayIdentifier)
}

public struct DisplayScene: Equatable, Sendable {
    public let identity: DisplaySceneIdentity
    public let seed: UInt64
    public let epoch: UInt64
    public let bounds: DisplayTopology.Rect

    public init(
        identity: DisplaySceneIdentity,
        seed: UInt64,
        epoch: UInt64,
        bounds: DisplayTopology.Rect
    ) {
        self.identity = identity
        self.seed = seed
        self.epoch = epoch
        self.bounds = bounds
    }
}

public struct DisplaySceneViewport: Equatable, Sendable {
    public let frameInScene: DisplayTopology.Rect
    public let normalizedFrame: DisplayTopology.Rect

    public init(
        frameInScene: DisplayTopology.Rect,
        normalizedFrame: DisplayTopology.Rect
    ) {
        self.frameInScene = frameInScene
        self.normalizedFrame = normalizedFrame
    }
}

public enum DisplaySceneRole: Equatable, Sendable {
    case panorama
    case independent
    case focus
    case quiet(DisplayQuietTreatment)
}

public enum DisplaySceneBoundaryDisposition: Equatable, Sendable {
    case shared(
        neighborIdentifier: DisplayTopology.PersistentDisplayIdentifier,
        neighborEdge: DisplayTopology.Edge
    )
    case outer(DisplayOuterBoundaryBehavior)
}

public struct DisplaySceneBoundary: Equatable, Sendable {
    public let edge: DisplayTopology.Edge
    public let span: DisplayTopology.OverlapSpan
    public let disposition: DisplaySceneBoundaryDisposition

    public init(
        edge: DisplayTopology.Edge,
        span: DisplayTopology.OverlapSpan,
        disposition: DisplaySceneBoundaryDisposition
    ) {
        self.edge = edge
        self.span = span
        self.disposition = disposition
    }
}

public struct DisplaySceneAssignment: Equatable, Sendable {
    public let displayIdentifier: DisplayTopology.PersistentDisplayIdentifier
    public let representativeIdentifier: DisplayTopology.PersistentDisplayIdentifier
    public let role: DisplaySceneRole
    public let scene: DisplayScene?
    public let viewport: DisplaySceneViewport?
    public let ownsFocalElement: Bool
    public let boundaries: [DisplaySceneBoundary]

    public var isMirrorFollower: Bool {
        displayIdentifier != representativeIdentifier
    }

    public init(
        displayIdentifier: DisplayTopology.PersistentDisplayIdentifier,
        representativeIdentifier: DisplayTopology.PersistentDisplayIdentifier,
        role: DisplaySceneRole,
        scene: DisplayScene?,
        viewport: DisplaySceneViewport?,
        ownsFocalElement: Bool,
        boundaries: [DisplaySceneBoundary]
    ) {
        self.displayIdentifier = displayIdentifier
        self.representativeIdentifier = representativeIdentifier
        self.role = role
        self.scene = scene
        self.viewport = viewport
        self.ownsFocalElement = ownsFocalElement
        self.boundaries = boundaries
    }
}

public struct DisplayScenePlan: Equatable, Sendable {
    public let topologyGeneration: UInt64
    public let policy: DisplayScenePolicy
    public let focalDisplayIdentifiers: [DisplayTopology.PersistentDisplayIdentifier]
    public let assignments: [DisplaySceneAssignment]

    public init(
        topologyGeneration: UInt64,
        policy: DisplayScenePolicy,
        focalDisplayIdentifiers: [DisplayTopology.PersistentDisplayIdentifier],
        assignments: [DisplaySceneAssignment]
    ) {
        self.topologyGeneration = topologyGeneration
        self.policy = policy
        self.focalDisplayIdentifiers = focalDisplayIdentifiers
        self.assignments = assignments
    }

    public func assignment(
        for identifier: DisplayTopology.PersistentDisplayIdentifier
    ) -> DisplaySceneAssignment? {
        assignments.first { $0.displayIdentifier == identifier }
    }
}

/// Pure planner for renderer-independent multi-display scene coordination.
/// It accepts only a new published topology generation and returns assignments
/// in persistent-identifier order.
public struct DisplayScenePlanner: Sendable {
    public init() {}

    public func makePlan(
        for snapshot: DisplayTopologySnapshot,
        settings: DisplaySceneSettings,
        sceneEpoch: UInt64,
        after acceptedGeneration: UInt64? = nil
    ) throws -> DisplayScenePlan {
        guard snapshot.generation > 0 else {
            throw DisplayScenePlanningError.invalidTopologyGeneration(
                snapshot.generation
            )
        }
        if let acceptedGeneration,
            snapshot.generation <= acceptedGeneration
        {
            throw DisplayScenePlanningError.staleTopologyGeneration(
                received: snapshot.generation,
                accepted: acceptedGeneration
            )
        }

        let topology = snapshot.topology
        let representatives = topology.displays.filter {
            $0.mirrorTargetIdentifier == nil
        }
        let primary = representatives.first { $0.isPrimary }!
        let representativeIdentifiers = Set(
            representatives.map(\.persistentIdentifier)
        )
        let requestedFocal = settings.focalDisplayIdentifier.flatMap {
            requestedIdentifier in
            topology.displays.first {
                $0.persistentIdentifier == requestedIdentifier
            }.map {
                $0.mirrorTargetIdentifier ?? $0.persistentIdentifier
            }
        }
        let resolvedFocal =
            requestedFocal.flatMap {
                representativeIdentifiers.contains($0) ? $0 : nil
            } ?? primary.persistentIdentifier

        let focalIdentifiers: [DisplayTopology.PersistentDisplayIdentifier]
        switch settings.policy {
        case .perDisplay:
            focalIdentifiers = representatives.map(\.persistentIdentifier)
        case .panorama, .focusDisplay:
            focalIdentifiers = [resolvedFocal]
        }

        let panoramaScene = DisplayScene(
            identity: .panorama,
            seed: settings.baseSeed,
            epoch: sceneEpoch,
            bounds: topology.desktopBounds
        )
        let representativeAssignments = Dictionary(
            uniqueKeysWithValues: representatives.map { display in
                let assignment = representativeAssignment(
                    for: display,
                    topology: topology,
                    settings: settings,
                    sceneEpoch: sceneEpoch,
                    resolvedFocal: resolvedFocal,
                    panoramaScene: panoramaScene
                )
                return (display.persistentIdentifier, assignment)
            }
        )

        let assignments = topology.displays.map { display in
            let representativeIdentifier =
                display.mirrorTargetIdentifier
                ?? display.persistentIdentifier
            let representative = representativeAssignments[representativeIdentifier]!
            guard display.mirrorTargetIdentifier != nil else {
                return representative
            }
            return DisplaySceneAssignment(
                displayIdentifier: display.persistentIdentifier,
                representativeIdentifier: representativeIdentifier,
                role: representative.role,
                scene: representative.scene,
                viewport: representative.viewport,
                ownsFocalElement: false,
                boundaries: []
            )
        }

        return DisplayScenePlan(
            topologyGeneration: snapshot.generation,
            policy: settings.policy,
            focalDisplayIdentifiers: focalIdentifiers,
            assignments: assignments
        )
    }
}

private extension DisplayScenePlanner {
    static let edgeOrder: [DisplayTopology.Edge] = [
        .left,
        .right,
        .bottom,
        .top,
    ]

    func representativeAssignment(
        for display: DisplayTopology.Display,
        topology: DisplayTopology,
        settings: DisplaySceneSettings,
        sceneEpoch: UInt64,
        resolvedFocal: DisplayTopology.PersistentDisplayIdentifier,
        panoramaScene: DisplayScene
    ) -> DisplaySceneAssignment {
        let identifier = display.persistentIdentifier
        let localBounds = DisplayTopology.Rect(
            x: 0,
            y: 0,
            width: display.logicalFrame.width,
            height: display.logicalFrame.height
        )

        let role: DisplaySceneRole
        let scene: DisplayScene?
        let viewport: DisplaySceneViewport?
        let ownsFocalElement: Bool
        let boundaries: [DisplaySceneBoundary]

        switch settings.policy {
        case .panorama:
            role = .panorama
            scene = panoramaScene
            viewport = .init(
                frameInScene: display.logicalFrame,
                normalizedFrame: normalized(
                    display.logicalFrame,
                    in: panoramaScene.bounds
                )
            )
            ownsFocalElement = identifier == resolvedFocal
            boundaries = makeBoundaries(
                for: display,
                topology: topology,
                outerBehavior: settings.outerBoundaryBehavior,
                sharesAdjacentEdges: true
            )

        case .perDisplay:
            role = .independent
            scene = .init(
                identity: .display(identifier),
                seed: derivedSeed(
                    baseSeed: settings.baseSeed,
                    namespace: "display:\(identifier.rawValue)"
                ),
                epoch: sceneEpoch,
                bounds: localBounds
            )
            viewport = fullViewport(in: localBounds)
            ownsFocalElement = true
            boundaries = makeBoundaries(
                for: display,
                topology: topology,
                outerBehavior: settings.outerBoundaryBehavior,
                sharesAdjacentEdges: false
            )

        case .focusDisplay:
            guard identifier == resolvedFocal else {
                return DisplaySceneAssignment(
                    displayIdentifier: identifier,
                    representativeIdentifier: identifier,
                    role: .quiet(settings.quietTreatment),
                    scene: nil,
                    viewport: nil,
                    ownsFocalElement: false,
                    boundaries: []
                )
            }
            role = .focus
            scene = .init(
                identity: .focus(identifier),
                seed: derivedSeed(
                    baseSeed: settings.baseSeed,
                    namespace: "focus:\(identifier.rawValue)"
                ),
                epoch: sceneEpoch,
                bounds: localBounds
            )
            viewport = fullViewport(in: localBounds)
            ownsFocalElement = true
            boundaries = makeBoundaries(
                for: display,
                topology: topology,
                outerBehavior: settings.outerBoundaryBehavior,
                sharesAdjacentEdges: false
            )
        }

        return DisplaySceneAssignment(
            displayIdentifier: identifier,
            representativeIdentifier: identifier,
            role: role,
            scene: scene,
            viewport: viewport,
            ownsFocalElement: ownsFocalElement,
            boundaries: boundaries
        )
    }

    func fullViewport(
        in bounds: DisplayTopology.Rect
    ) -> DisplaySceneViewport {
        .init(
            frameInScene: bounds,
            normalizedFrame: .init(x: 0, y: 0, width: 1, height: 1)
        )
    }

    func normalized(
        _ frame: DisplayTopology.Rect,
        in bounds: DisplayTopology.Rect
    ) -> DisplayTopology.Rect {
        .init(
            x: (frame.x - bounds.x) / bounds.width,
            y: (frame.y - bounds.y) / bounds.height,
            width: frame.width / bounds.width,
            height: frame.height / bounds.height
        )
    }

    func derivedSeed(baseSeed: UInt64, namespace: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in namespace.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash ^ baseSeed
    }

    func makeBoundaries(
        for display: DisplayTopology.Display,
        topology: DisplayTopology,
        outerBehavior: DisplayOuterBoundaryBehavior,
        sharesAdjacentEdges: Bool
    ) -> [DisplaySceneBoundary] {
        Self.edgeOrder.flatMap { edge in
            boundaries(
                for: display,
                edge: edge,
                topology: topology,
                outerBehavior: outerBehavior,
                sharesAdjacentEdges: sharesAdjacentEdges
            )
        }
    }

    func boundaries(
        for display: DisplayTopology.Display,
        edge: DisplayTopology.Edge,
        topology: DisplayTopology,
        outerBehavior: DisplayOuterBoundaryBehavior,
        sharesAdjacentEdges: Bool
    ) -> [DisplaySceneBoundary] {
        let fullSpan = fullSpan(for: display.logicalFrame, edge: edge)
        guard sharesAdjacentEdges else {
            return [
                outerBoundary(
                    edge: edge,
                    span: fullSpan,
                    behavior: outerBehavior
                )
            ]
        }

        let shared = topology.adjacencies.compactMap { adjacency -> DisplaySceneBoundary? in
            if adjacency.firstDisplayIdentifier == display.persistentIdentifier,
                adjacency.firstEdge == edge
            {
                return .init(
                    edge: edge,
                    span: adjacency.overlap,
                    disposition: .shared(
                        neighborIdentifier: adjacency.secondDisplayIdentifier,
                        neighborEdge: adjacency.secondEdge
                    )
                )
            }
            if adjacency.secondDisplayIdentifier == display.persistentIdentifier,
                adjacency.secondEdge == edge
            {
                return .init(
                    edge: edge,
                    span: adjacency.overlap,
                    disposition: .shared(
                        neighborIdentifier: adjacency.firstDisplayIdentifier,
                        neighborEdge: adjacency.firstEdge
                    )
                )
            }
            return nil
        }.sorted {
            $0.span.lowerBound < $1.span.lowerBound
        }

        var result: [DisplaySceneBoundary] = []
        var cursor = fullSpan.lowerBound
        for boundary in shared {
            if cursor < boundary.span.lowerBound {
                result.append(
                    outerBoundary(
                        edge: edge,
                        span: .init(
                            axis: fullSpan.axis,
                            lowerBound: cursor,
                            upperBound: boundary.span.lowerBound
                        ),
                        behavior: outerBehavior
                    ))
            }
            result.append(boundary)
            cursor = boundary.span.upperBound
        }
        if cursor < fullSpan.upperBound {
            result.append(
                outerBoundary(
                    edge: edge,
                    span: .init(
                        axis: fullSpan.axis,
                        lowerBound: cursor,
                        upperBound: fullSpan.upperBound
                    ),
                    behavior: outerBehavior
                ))
        }
        return result
    }

    func fullSpan(
        for frame: DisplayTopology.Rect,
        edge: DisplayTopology.Edge
    ) -> DisplayTopology.OverlapSpan {
        switch edge {
        case .left, .right:
            .init(
                axis: .vertical,
                lowerBound: frame.minY,
                upperBound: frame.maxY
            )
        case .bottom, .top:
            .init(
                axis: .horizontal,
                lowerBound: frame.minX,
                upperBound: frame.maxX
            )
        }
    }

    func outerBoundary(
        edge: DisplayTopology.Edge,
        span: DisplayTopology.OverlapSpan,
        behavior: DisplayOuterBoundaryBehavior
    ) -> DisplaySceneBoundary {
        .init(
            edge: edge,
            span: span,
            disposition: .outer(behavior)
        )
    }
}
