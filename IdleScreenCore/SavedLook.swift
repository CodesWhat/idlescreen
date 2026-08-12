import Foundation

/// The exact visual state captured by a Saved Look. Persistence metadata is
/// deliberately excluded so applying a look cannot rewrite revision history.
public struct IdleScreenLookSnapshot: Codable, Equatable, Sendable {
    public let source: IdleScreenSource
    public let appearance: IdleScreenAppearance
    public let creative: IdleScreenCreativeConfiguration
    public let materials: IdleScreenPixelMaterialsConfiguration

    public init(
        source: IdleScreenSource,
        appearance: IdleScreenAppearance,
        creative: IdleScreenCreativeConfiguration,
        materials: IdleScreenPixelMaterialsConfiguration = .default
    ) {
        self.source = source
        self.appearance = appearance
        self.creative = creative
        self.materials = materials.normalized
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case appearance
        case creative
        case materials
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try values.decode(IdleScreenSource.self, forKey: .source),
            appearance: try values.decode(
                IdleScreenAppearance.self,
                forKey: .appearance
            ),
            creative: try values.decode(
                IdleScreenCreativeConfiguration.self,
                forKey: .creative
            ),
            materials: try values.decodeIfPresent(
                IdleScreenPixelMaterialsConfiguration.self,
                forKey: .materials
            ) ?? .default
        )
    }
}

/// A durable, stable-ID visual snapshot owned by the shared configuration.
public struct IdleScreenSavedLook: Codable, Equatable, Identifiable, Sendable {
    public static let maximumCount = 32
    public static let maximumNameLength = 64
    public static let maximumNameUTF8ByteCount = 256
    public static let defaultName = "Untitled Look"

    public let id: UUID
    public let name: String
    public let snapshot: IdleScreenLookSnapshot

    public init(
        id: UUID,
        name: String,
        snapshot: IdleScreenLookSnapshot
    ) {
        self.id = id
        self.name = Self.validatedName(name) ?? Self.defaultName
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case snapshot
    }

    /// Decoding repairs malformed legacy/future names without discarding an
    /// otherwise valid user snapshot.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            snapshot: try values.decode(
                IdleScreenLookSnapshot.self,
                forKey: .snapshot
            )
        )
    }

    static func normalizedCollection(
        _ savedLooks: [Self]
    ) -> [Self] {
        var seenIDs: Set<UUID> = []
        var normalized: [Self] = []
        normalized.reserveCapacity(min(savedLooks.count, maximumCount))

        // Persisted order is authoritative. The first occurrence of an ID wins,
        // making recovery from malformed duplicate data deterministic.
        for savedLook in savedLooks {
            guard normalized.count < maximumCount,
                  seenIDs.insert(savedLook.id).inserted else {
                continue
            }
            normalized.append(Self(
                id: savedLook.id,
                name: savedLook.name,
                snapshot: savedLook.snapshot
            ))
        }
        return normalized
    }

    static func validatedName(_ name: String) -> String? {
        let withoutControls = name.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                ? " "
                : String(scalar)
        }.joined()
        let singleLineName = withoutControls
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !singleLineName.isEmpty else { return nil }

        var boundedName = ""
        for character in singleLineName {
            guard boundedName.count < maximumNameLength else { break }
            let next = String(character)
            guard boundedName.utf8.count + next.utf8.count
                    <= maximumNameUTF8ByteCount else {
                break
            }
            boundedName.append(character)
        }
        return boundedName.isEmpty ? nil : boundedName
    }
}

public enum IdleScreenSavedLookError: Error, Equatable, Sendable {
    case duplicateID(UUID)
    case collectionFull(maximumCount: Int)
    case invalidName
    case notFound(UUID)
}
