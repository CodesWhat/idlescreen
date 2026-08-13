import Foundation

/// A validated, deterministic snapshot of the logical macOS desktop.
///
/// Version 1 persists only stable display metadata. Runtime Core Graphics IDs,
/// snapshot generations, desktop bounds, and adjacency are intentionally
/// excluded from the payload:
/// an adapter may associate a transient runtime ID with a persistent ID while
/// observing the system, a later live publisher owns generation fencing, and
/// every consumer derives geometry from this snapshot.
public struct DisplayTopology: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumPersistentIdentifierUTF8ByteCount = 1_024

    public let schemaVersion: Int
    public let displays: [Display]

    public init(displays: [Display]) throws {
        try self.init(
            schemaVersion: Self.currentSchemaVersion,
            displays: displays
        )
    }

    private init(schemaVersion: Int, displays: [Display]) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }

        let canonicalDisplays = displays.sorted {
            $0.persistentIdentifier.rawValue
                < $1.persistentIdentifier.rawValue
        }
        try Self.validate(canonicalDisplays)

        self.schemaVersion = schemaVersion
        self.displays = canonicalDisplays
    }

    public var desktopBounds: Rect {
        displays.dropFirst().reduce(displays[0].logicalFrame) { bounds, display in
            bounds.union(display.logicalFrame)
        }
    }

    /// Canonical edge mappings between logical desktop representatives.
    /// Mirrored followers share their target's viewport and therefore do not
    /// produce duplicate logical adjacencies.
    public var adjacencies: [Adjacency] {
        let representatives = displays.filter {
            $0.mirrorTargetIdentifier == nil
        }
        var result: [Adjacency] = []

        for firstIndex in representatives.indices {
            let secondStart = representatives.index(after: firstIndex)
            guard secondStart < representatives.endIndex else { continue }
            for secondIndex in secondStart..<representatives.endIndex {
                if let adjacency = Self.adjacency(
                    between: representatives[firstIndex],
                    and: representatives[secondIndex]
                ) {
                    result.append(adjacency)
                }
            }
        }

        return result
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case displays
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        let displays = try container.decode([Display].self, forKey: .displays)
        try self.init(schemaVersion: schemaVersion, displays: displays)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(displays, forKey: .displays)
    }
}

extension DisplayTopology {
    /// A persistent, opaque identity suitable for snapshots and saved policy.
    public struct PersistentDisplayIdentifier:
        Codable,
        Hashable,
        RawRepresentable,
        Sendable
    {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// A transient Core Graphics display identity. It is deliberately a
    /// distinct, non-Codable type and is not part of `DisplayTopology.Display`.
    public struct RuntimeDisplayIdentifier:
        Equatable,
        Hashable,
        RawRepresentable,
        Sendable
    {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
    }

    /// Logical global-desktop coordinates. Positive X points right and positive
    /// Y points up, so a display whose `minY` equals another display's `maxY`
    /// touches that display's top edge.
    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var minX: Double { x }
        public var minY: Double { y }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }

        fileprivate func union(_ other: Self) -> Self {
            let lowerX = min(minX, other.minX)
            let lowerY = min(minY, other.minY)
            let upperX = max(maxX, other.maxX)
            let upperY = max(maxY, other.maxY)
            return Self(
                x: lowerX,
                y: lowerY,
                width: upperX - lowerX,
                height: upperY - lowerY
            )
        }

        fileprivate func overlapsArea(of other: Self) -> Bool {
            min(maxX, other.maxX) > max(minX, other.minX)
                && min(maxY, other.maxY) > max(minY, other.minY)
        }
    }

    public struct PixelSize: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct RefreshRateRange: Codable, Equatable, Sendable {
        public var minimumHz: Double
        public var maximumHz: Double
        public var currentHz: Double

        public init(
            minimumHz: Double,
            maximumHz: Double,
            currentHz: Double
        ) {
            self.minimumHz = minimumHz
            self.maximumHz = maximumHz
            self.currentHz = currentHz
        }
    }

    public struct SafeAreaInsets: Codable, Equatable, Sendable {
        public static let zero = Self(top: 0, left: 0, bottom: 0, right: 0)

        public var top: Double
        public var left: Double
        public var bottom: Double
        public var right: Double

        public init(top: Double, left: Double, bottom: Double, right: Double) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }
    }

    public struct Display: Codable, Equatable, Sendable {
        public var persistentIdentifier: PersistentDisplayIdentifier
        public var logicalFrame: Rect
        public var nativePixelSize: PixelSize
        public var backingScale: Double
        public var rotationDegrees: Int
        /// `nil` when the observing system cannot report a reliable range.
        public var refreshRateRange: RefreshRateRange?
        public var safeAreaInsets: SafeAreaInsets
        public var isPrimary: Bool
        public var mirrorTargetIdentifier: PersistentDisplayIdentifier?

        public init(
            persistentIdentifier: PersistentDisplayIdentifier,
            logicalFrame: Rect,
            nativePixelSize: PixelSize,
            backingScale: Double,
            rotationDegrees: Int,
            refreshRateRange: RefreshRateRange?,
            safeAreaInsets: SafeAreaInsets,
            isPrimary: Bool,
            mirrorTargetIdentifier: PersistentDisplayIdentifier?
        ) {
            self.persistentIdentifier = persistentIdentifier
            self.logicalFrame = logicalFrame
            self.nativePixelSize = nativePixelSize
            self.backingScale = backingScale
            self.rotationDegrees = rotationDegrees
            self.refreshRateRange = refreshRateRange
            self.safeAreaInsets = safeAreaInsets
            self.isPrimary = isPrimary
            self.mirrorTargetIdentifier = mirrorTargetIdentifier
        }
    }

    public enum Edge: String, Codable, Equatable, Sendable {
        case left
        case right
        case bottom
        case top
    }

    public enum Axis: String, Codable, Equatable, Sendable {
        case horizontal
        case vertical
    }

    public struct OverlapSpan: Codable, Equatable, Sendable {
        public var axis: Axis
        public var lowerBound: Double
        public var upperBound: Double

        public init(axis: Axis, lowerBound: Double, upperBound: Double) {
            self.axis = axis
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }
    }

    public struct Adjacency: Codable, Equatable, Sendable {
        public var firstDisplayIdentifier: PersistentDisplayIdentifier
        public var firstEdge: Edge
        public var secondDisplayIdentifier: PersistentDisplayIdentifier
        public var secondEdge: Edge
        public var overlap: OverlapSpan

        public init(
            firstDisplayIdentifier: PersistentDisplayIdentifier,
            firstEdge: Edge,
            secondDisplayIdentifier: PersistentDisplayIdentifier,
            secondEdge: Edge,
            overlap: OverlapSpan
        ) {
            self.firstDisplayIdentifier = firstDisplayIdentifier
            self.firstEdge = firstEdge
            self.secondDisplayIdentifier = secondDisplayIdentifier
            self.secondEdge = secondEdge
            self.overlap = overlap
        }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchemaVersion(Int)
        case invalidPersistentIdentifier(PersistentDisplayIdentifier)
        case duplicatePersistentIdentifier(PersistentDisplayIdentifier)
        case invalidLogicalFrame(PersistentDisplayIdentifier)
        case invalidNativePixelSize(PersistentDisplayIdentifier)
        case invalidBackingScale(PersistentDisplayIdentifier)
        case unsupportedRotation(PersistentDisplayIdentifier, degrees: Int)
        case invalidRefreshRateRange(PersistentDisplayIdentifier)
        case invalidSafeAreaInsets(PersistentDisplayIdentifier)
        case missingPrimaryDisplay
        case multiplePrimaryDisplays([PersistentDisplayIdentifier])
        case primaryDisplayCannotMirror(PersistentDisplayIdentifier)
        case mirrorTargetMissing(
            display: PersistentDisplayIdentifier,
            target: PersistentDisplayIdentifier
        )
        case mirrorTargetIsSelf(PersistentDisplayIdentifier)
        case nestedMirror(
            display: PersistentDisplayIdentifier,
            target: PersistentDisplayIdentifier
        )
        case mirrorGeometryMismatch(
            display: PersistentDisplayIdentifier,
            target: PersistentDisplayIdentifier
        )
        case overlappingDisplays(
            first: PersistentDisplayIdentifier,
            second: PersistentDisplayIdentifier
        )
    }
}

private extension DisplayTopology {
    static func validate(_ displays: [Display]) throws {
        for display in displays {
            try validatePersistentIdentifier(display.persistentIdentifier)
        }

        for index in displays.indices.dropFirst() {
            if displays[index - 1].persistentIdentifier
                == displays[index].persistentIdentifier {
                throw ValidationError.duplicatePersistentIdentifier(
                    displays[index].persistentIdentifier
                )
            }
        }

        for display in displays {
            try validateGeometryAndMetadata(display)
        }

        let primaryIdentifiers = displays.filter(\.isPrimary).map(\.persistentIdentifier)
        guard !primaryIdentifiers.isEmpty else {
            throw ValidationError.missingPrimaryDisplay
        }
        guard primaryIdentifiers.count == 1 else {
            throw ValidationError.multiplePrimaryDisplays(primaryIdentifiers)
        }

        let displaysByIdentifier = Dictionary(
            uniqueKeysWithValues: displays.map {
                ($0.persistentIdentifier, $0)
            }
        )
        for display in displays {
            guard let targetIdentifier = display.mirrorTargetIdentifier else {
                continue
            }
            if display.isPrimary {
                throw ValidationError.primaryDisplayCannotMirror(
                    display.persistentIdentifier
                )
            }
            if targetIdentifier == display.persistentIdentifier {
                throw ValidationError.mirrorTargetIsSelf(
                    display.persistentIdentifier
                )
            }
            guard let target = displaysByIdentifier[targetIdentifier] else {
                throw ValidationError.mirrorTargetMissing(
                    display: display.persistentIdentifier,
                    target: targetIdentifier
                )
            }
            if target.mirrorTargetIdentifier != nil {
                throw ValidationError.nestedMirror(
                    display: display.persistentIdentifier,
                    target: targetIdentifier
                )
            }
            if display.logicalFrame != target.logicalFrame {
                throw ValidationError.mirrorGeometryMismatch(
                    display: display.persistentIdentifier,
                    target: targetIdentifier
                )
            }
        }

        for firstIndex in displays.indices {
            let secondStart = displays.index(after: firstIndex)
            guard secondStart < displays.endIndex else { continue }
            for secondIndex in secondStart..<displays.endIndex {
                let first = displays[firstIndex]
                let second = displays[secondIndex]
                guard first.logicalFrame.overlapsArea(of: second.logicalFrame) else {
                    continue
                }

                let firstRoot = first.mirrorTargetIdentifier
                    ?? first.persistentIdentifier
                let secondRoot = second.mirrorTargetIdentifier
                    ?? second.persistentIdentifier
                let isExactMirrorGroupOverlap = firstRoot == secondRoot
                    && first.logicalFrame == second.logicalFrame
                guard isExactMirrorGroupOverlap else {
                    throw ValidationError.overlappingDisplays(
                        first: first.persistentIdentifier,
                        second: second.persistentIdentifier
                    )
                }
            }
        }
    }

    static func validatePersistentIdentifier(
        _ identifier: PersistentDisplayIdentifier
    ) throws {
        let rawValue = identifier.rawValue
        let containsControlCharacter = rawValue.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= maximumPersistentIdentifierUTF8ByteCount,
              !containsControlCharacter else {
            throw ValidationError.invalidPersistentIdentifier(identifier)
        }
    }

    static func validateGeometryAndMetadata(_ display: Display) throws {
        let identifier = display.persistentIdentifier
        let frame = display.logicalFrame
        guard frame.x.isFinite,
              frame.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0,
              frame.maxX.isFinite,
              frame.maxY.isFinite else {
            throw ValidationError.invalidLogicalFrame(identifier)
        }

        guard display.nativePixelSize.width > 0,
              display.nativePixelSize.height > 0 else {
            throw ValidationError.invalidNativePixelSize(identifier)
        }

        guard display.backingScale.isFinite,
              display.backingScale > 0 else {
            throw ValidationError.invalidBackingScale(identifier)
        }

        guard [0, 90, 180, 270].contains(display.rotationDegrees) else {
            throw ValidationError.unsupportedRotation(
                identifier,
                degrees: display.rotationDegrees
            )
        }

        if let refresh = display.refreshRateRange {
            guard refresh.minimumHz.isFinite,
                  refresh.maximumHz.isFinite,
                  refresh.currentHz.isFinite,
                  refresh.minimumHz > 0,
                  refresh.minimumHz <= refresh.currentHz,
                  refresh.currentHz <= refresh.maximumHz else {
                throw ValidationError.invalidRefreshRateRange(identifier)
            }
        }

        let insets = display.safeAreaInsets
        guard insets.top.isFinite,
              insets.left.isFinite,
              insets.bottom.isFinite,
              insets.right.isFinite,
              insets.top >= 0,
              insets.left >= 0,
              insets.bottom >= 0,
              insets.right >= 0,
              insets.left + insets.right < frame.width,
              insets.top + insets.bottom < frame.height else {
            throw ValidationError.invalidSafeAreaInsets(identifier)
        }
    }

    static func adjacency(
        between first: Display,
        and second: Display
    ) -> Adjacency? {
        let firstFrame = first.logicalFrame
        let secondFrame = second.logicalFrame

        if firstFrame.maxX == secondFrame.minX {
            return verticalAdjacency(
                first: first,
                firstEdge: .right,
                second: second,
                secondEdge: .left
            )
        }
        if firstFrame.minX == secondFrame.maxX {
            return verticalAdjacency(
                first: first,
                firstEdge: .left,
                second: second,
                secondEdge: .right
            )
        }
        if firstFrame.maxY == secondFrame.minY {
            return horizontalAdjacency(
                first: first,
                firstEdge: .top,
                second: second,
                secondEdge: .bottom
            )
        }
        if firstFrame.minY == secondFrame.maxY {
            return horizontalAdjacency(
                first: first,
                firstEdge: .bottom,
                second: second,
                secondEdge: .top
            )
        }
        return nil
    }

    static func verticalAdjacency(
        first: Display,
        firstEdge: Edge,
        second: Display,
        secondEdge: Edge
    ) -> Adjacency? {
        let lowerBound = max(first.logicalFrame.minY, second.logicalFrame.minY)
        let upperBound = min(first.logicalFrame.maxY, second.logicalFrame.maxY)
        guard upperBound > lowerBound else { return nil }
        return Adjacency(
            firstDisplayIdentifier: first.persistentIdentifier,
            firstEdge: firstEdge,
            secondDisplayIdentifier: second.persistentIdentifier,
            secondEdge: secondEdge,
            overlap: OverlapSpan(
                axis: .vertical,
                lowerBound: lowerBound,
                upperBound: upperBound
            )
        )
    }

    static func horizontalAdjacency(
        first: Display,
        firstEdge: Edge,
        second: Display,
        secondEdge: Edge
    ) -> Adjacency? {
        let lowerBound = max(first.logicalFrame.minX, second.logicalFrame.minX)
        let upperBound = min(first.logicalFrame.maxX, second.logicalFrame.maxX)
        guard upperBound > lowerBound else { return nil }
        return Adjacency(
            firstDisplayIdentifier: first.persistentIdentifier,
            firstEdge: firstEdge,
            secondDisplayIdentifier: second.persistentIdentifier,
            secondEdge: secondEdge,
            overlap: OverlapSpan(
                axis: .horizontal,
                lowerBound: lowerBound,
                upperBound: upperBound
            )
        )
    }
}
