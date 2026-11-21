import Foundation

public struct IdleScreenAquariumMossAttachment: Codable, Equatable, Sendable {
  public var parentID: UUID
  public var relativeScale: Double

  public init(parentID: UUID, relativeScale: Double) {
    self.parentID = parentID
    self.relativeScale = relativeScale
  }
}

extension IdleScreenAquariumDecorationKind {
  public var supportsMoss: Bool {
    [.rock, .slate, .cave, .driftwood, .hollowLog].contains(self)
  }

  fileprivate var mossAnchor: (x: Double, y: Double) {
    switch self {
    case .rock: (16.5, 3.5)
    case .slate: (21.5, 3.5)
    case .cave: (24.5, 3.5)
    case .driftwood: (45.5, 18.5)
    case .hollowLog: (28.5, 5.5)
    default: (size.width / 2, size.height / 2)
    }
  }
}

extension IdleScreenAquariumTank {
  public var placedDecorations: [IdleScreenAquariumDecoration] {
    placedDecorations(inWorldWidth: worldWidth)
  }

  public func placedDecorations(inWorldWidth width: Int) -> [IdleScreenAquariumDecoration] {
    let worldWidth = min(1152, max(384, width))
    let parents = decorations.reduce(into: [UUID: IdleScreenAquariumDecoration]()) {
      $0[$1.id] = $1
    }
    return decorations.map { item in
      guard let attachment = item.attachment, let parent = parents[attachment.parentID],
        item.kind == .moss, parent.kind.supportsMoss
      else { return item }
      let angle = (parent.tilt?.degrees ?? 0) * .pi / 180
      let c = cos(angle)
      let s = sin(angle)
      let anchor = parent.kind.mossAnchor
      let x = (anchor.x - parent.kind.size.width / 2) * parent.scale * (parent.flipped ? -1 : 1)
      let y = (anchor.y - parent.kind.size.height / 2) * parent.scale
      let anchorX = parent.x * Double(worldWidth) + x * c - y * s
      let anchorY = parent.y * 216 - parent.placementSize.height / 2 + x * s + y * c
      var placed = item
      placed.scale = parent.scale * attachment.relativeScale
      placed.flipped = parent.flipped
      placed.tilt = parent.tilt
      placed.foreground = parent.foreground
      let rootY = (item.kind.size.height / 2 - 1.5) * placed.scale
      placed.x = (anchorX + s * rootY) / Double(worldWidth)
      placed.y = (anchorY - c * rootY + placed.placementSize.height / 2) / 216
      return placed
    }
  }

  public mutating func attachMoss(id: UUID, to parentID: UUID) throws {
    guard let index = decorations.firstIndex(where: { $0.id == id }),
      let parent = decorations.first(where: { $0.id == parentID }),
      let moss = placedDecorations.first(where: { $0.id == id }),
      moss.kind == .moss, parent.kind.supportsMoss
    else { throw IdleScreenAquariumError.invalidPlacement }
    var proposed = self
    proposed.decorations[index].attachment = .init(
      parentID: parentID, relativeScale: moss.scale / parent.scale)
    try proposed.validate()
    self = proposed
  }

  public mutating func detachMoss(id: UUID) throws {
    guard let index = decorations.firstIndex(where: { $0.id == id }),
      var item = placedDecorations.first(where: { $0.id == id }), item.kind == .moss
    else { throw IdleScreenAquariumError.missingItem }
    item.attachment = nil
    var proposed = self
    proposed.decorations[index] = item
    try proposed.validate()
    self = proposed
  }

  public mutating func removeDecoration(id: UUID) throws {
    guard decorations.contains(where: { $0.id == id }) else {
      throw IdleScreenAquariumError.missingItem
    }
    var proposed = self
    proposed.decorations = placedDecorations.filter { $0.id != id }.map { item in
      var copy = item
      if copy.attachment?.parentID == id { copy.attachment = nil }
      return copy
    }
    try proposed.validate()
    self = proposed
  }

  func validateMossAttachments() throws {
    let parents = decorations.reduce(into: [UUID: IdleScreenAquariumDecoration]()) {
      $0[$1.id] = $1
    }
    for item in decorations {
      guard let attachment = item.attachment else { continue }
      guard item.kind == .moss, let parent = parents[attachment.parentID],
        parent.kind.supportsMoss, attachment.relativeScale.isFinite,
        (1.0 / 3...3).contains(attachment.relativeScale)
      else { throw IdleScreenAquariumError.invalidPlacement }
    }
    for item in placedDecorations { try item.validate(worldWidth: worldWidth) }
  }
}
