/// Library presentation identity. Selection continues to use the existing source and pattern fields.
public enum IdleScreenSceneLibraryEntry: Equatable, Identifiable, Sendable {
  case camera
  case pattern(IdleScreenCreativePattern)

  public var id: String {
    switch self {
    case .camera: "camera"
    case .pattern(let pattern): pattern.rawValue
    }
  }

  public var title: String {
    switch self {
    case .camera: "Camera"
    case .pattern(.aquarium): "Aquarium"
    case .pattern(let pattern): pattern.displayName
    }
  }
}

/// Chooser grouping only; renderer cycle order and persisted pattern identifiers remain unchanged.
public enum IdleScreenSceneLibrary {
  public static let families: [IdleScreenSceneLibraryEntry] = [
    .camera, .pattern(.aquarium), .pattern(.pixelMaterials),
  ]

  public static let featuredGlyphs: [IdleScreenSceneLibraryEntry] = [
    .pattern(.topograph), .pattern(.perlin), .pattern(.matrixRain),
  ]

  public static let moreGlyphs: [IdleScreenSceneLibraryEntry] =
    IdleScreenCreativePattern.allCases.map(IdleScreenSceneLibraryEntry.pattern).filter {
      !families.contains($0) && !featuredGlyphs.contains($0)
    }

  public static func selection(
    source: IdleScreenSource, pattern: IdleScreenCreativePattern
  ) -> IdleScreenSceneLibraryEntry {
    source == .camera ? .camera : .pattern(pattern)
  }
}
