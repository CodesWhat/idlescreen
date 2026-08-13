import Foundation

/// Explicit multi-display behavior. Host/view creation order never selects a
/// policy implicitly.
public enum DisplayScenePolicy: String, Codable, CaseIterable, Equatable,
    Identifiable, Sendable
{
    case panorama
    case perDisplay
    case focusDisplay

    public var id: String { rawValue }
}

public enum DisplayQuietTreatment: String, Codable, CaseIterable, Equatable,
    Identifiable, Sendable
{
    case black
    case subdued

    public var id: String { rawValue }
}

/// Treatment for portions of a display edge that do not touch another scene
/// viewport. Shared segments are emitted separately in Panorama mode.
public enum DisplayOuterBoundaryBehavior: String, Codable, CaseIterable,
    Equatable, Identifiable, Sendable
{
    case wall
    case drain
    case offWorld

    public var id: String { rawValue }
}

/// Versioned configuration inputs shared by the companion, saver, and pure
/// scene planner. Process-local topology generations and clocks do not persist.
public struct DisplaySceneSettings: Codable, Equatable, Sendable {
    public let policy: DisplayScenePolicy
    public let focalDisplayIdentifier: DisplayTopology.PersistentDisplayIdentifier?
    public let quietTreatment: DisplayQuietTreatment
    public let outerBoundaryBehavior: DisplayOuterBoundaryBehavior
    public let baseSeed: UInt64

    public init(
        policy: DisplayScenePolicy,
        focalDisplayIdentifier: DisplayTopology.PersistentDisplayIdentifier? = nil,
        quietTreatment: DisplayQuietTreatment = .black,
        outerBoundaryBehavior: DisplayOuterBoundaryBehavior = .wall,
        baseSeed: UInt64 = 0
    ) {
        self.policy = policy
        self.focalDisplayIdentifier = focalDisplayIdentifier
        self.quietTreatment = quietTreatment
        self.outerBoundaryBehavior = outerBoundaryBehavior
        self.baseSeed = baseSeed
    }

    public static let `default` = Self(policy: .panorama)
}
