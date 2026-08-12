import IdleScreenCore

/// One transient system observation before runtime mirror identities are
/// resolved into persistent topology identities.
public struct DisplayTopologyObservation: Equatable, Sendable {
    public var runtimeIdentifier: DisplayTopology.RuntimeDisplayIdentifier
    public var persistentIdentifier: DisplayTopology.PersistentDisplayIdentifier
    public var logicalFrame: DisplayTopology.Rect
    public var nativePixelSize: DisplayTopology.PixelSize
    public var backingScale: Double
    public var rotationDegrees: Int
    public var refreshRateRange: DisplayTopology.RefreshRateRange?
    public var safeAreaInsets: DisplayTopology.SafeAreaInsets
    public var isPrimary: Bool
    public var mirrorTargetRuntimeIdentifier: DisplayTopology.RuntimeDisplayIdentifier?

    public init(
        runtimeIdentifier: DisplayTopology.RuntimeDisplayIdentifier,
        persistentIdentifier: DisplayTopology.PersistentDisplayIdentifier,
        logicalFrame: DisplayTopology.Rect,
        nativePixelSize: DisplayTopology.PixelSize,
        backingScale: Double,
        rotationDegrees: Int,
        refreshRateRange: DisplayTopology.RefreshRateRange?,
        safeAreaInsets: DisplayTopology.SafeAreaInsets,
        isPrimary: Bool,
        mirrorTargetRuntimeIdentifier:
            DisplayTopology.RuntimeDisplayIdentifier?
    ) {
        self.runtimeIdentifier = runtimeIdentifier
        self.persistentIdentifier = persistentIdentifier
        self.logicalFrame = logicalFrame
        self.nativePixelSize = nativePixelSize
        self.backingScale = backingScale
        self.rotationDegrees = rotationDegrees
        self.refreshRateRange = refreshRateRange
        self.safeAreaInsets = safeAreaInsets
        self.isPrimary = isPrimary
        self.mirrorTargetRuntimeIdentifier = mirrorTargetRuntimeIdentifier
    }
}

public enum DisplayTopologyObservationError: Error, Equatable, Sendable {
    case duplicateRuntimeIdentifier(
        DisplayTopology.RuntimeDisplayIdentifier
    )
    case missingMirrorTarget(
        display: DisplayTopology.RuntimeDisplayIdentifier,
        target: DisplayTopology.RuntimeDisplayIdentifier
    )
}

/// Converts one complete system observation into the validated persistent
/// topology contract. Runtime display IDs never enter the persisted snapshot.
public struct DisplayTopologyObservationAdapter: Sendable {
    public init() {}

    public func topology(
        from observations: [DisplayTopologyObservation]
    ) throws -> DisplayTopology {
        let canonicalObservations = observations.sorted {
            if $0.runtimeIdentifier.rawValue
                != $1.runtimeIdentifier.rawValue
            {
                return $0.runtimeIdentifier.rawValue
                    < $1.runtimeIdentifier.rawValue
            }
            return $0.persistentIdentifier.rawValue
                < $1.persistentIdentifier.rawValue
        }

        var persistentIdentifiersByRuntime:
            [DisplayTopology.RuntimeDisplayIdentifier:
                DisplayTopology.PersistentDisplayIdentifier] = [:]
        for observation in canonicalObservations {
            guard
                persistentIdentifiersByRuntime[
                    observation.runtimeIdentifier
                ] == nil
            else {
                throw
                    DisplayTopologyObservationError
                    .duplicateRuntimeIdentifier(
                        observation.runtimeIdentifier
                    )
            }
            persistentIdentifiersByRuntime[observation.runtimeIdentifier] =
                observation.persistentIdentifier
        }

        let displays = try canonicalObservations.map { observation in
            let mirrorTargetIdentifier =
                try observation
                .mirrorTargetRuntimeIdentifier.map { runtimeIdentifier in
                    guard
                        let persistentIdentifier =
                            persistentIdentifiersByRuntime[runtimeIdentifier]
                    else {
                        throw
                            DisplayTopologyObservationError
                            .missingMirrorTarget(
                                display: observation.runtimeIdentifier,
                                target: runtimeIdentifier
                            )
                    }
                    return persistentIdentifier
                }
            return DisplayTopology.Display(
                persistentIdentifier: observation.persistentIdentifier,
                logicalFrame: observation.logicalFrame,
                nativePixelSize: observation.nativePixelSize,
                backingScale: observation.backingScale,
                rotationDegrees: observation.rotationDegrees,
                refreshRateRange: observation.refreshRateRange,
                safeAreaInsets: observation.safeAreaInsets,
                isPrimary: observation.isPrimary,
                mirrorTargetIdentifier: mirrorTargetIdentifier
            )
        }
        return try DisplayTopology(displays: displays)
    }
}
