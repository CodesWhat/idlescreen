import CoreGraphics
import Foundation

/// One immutable geometry pass serves every animal in a frame. Plants stay
/// permeable; hardscape supplies surfaces and masks the inside of shelters.
struct IdleScreenAquariumNavigation {
  struct Anchor {
    let x: Double
    let y: Double
  }
  struct Shelter {
    let objectIndex: Int
    let opening: CGRect
  }
  let floor: Double
  let worldWidth: Int
  let grazingAnchors: [Anchor]
  let shelters: [Shelter]
  private let schoolRanks: [UInt64: Int]
  private let surfaces: [Double]
  private let travelSurfaces: [Double]
  private let owners: [Int16]
  private let portals: [Int16]

  init(settings: IdleScreenAquariumRenderSettings, worldWidth: Int) {
    let school = Set(
      settings.inhabitants.prefix(32).filter { $0.species == "neonTetra" }.map(\.identity)
    ).sorted()
    schoolRanks = Dictionary(
      uniqueKeysWithValues: school.enumerated().map { ($0.element, $0.offset) })
    self.worldWidth = min(1152, max(384, worldWidth))
    let width = self.worldWidth
    let depth =
      settings.substrateDepth.isFinite ? min(0.24, max(0.08, settings.substrateDepth)) : 0.14
    let floor = Double(Int((1 - depth) * 216))
    self.floor = floor
    let phase = Double(settings.seed % 997) / 997 * 6.28
    var heights = (0..<width).map { floor + Double(Int(sin(Double($0) * 0.032 + phase) * 4)) }
    var owners = [Int16](repeating: -1, count: width * 216)
    var portals = owners
    var grazes: [Anchor] = []
    var shelters: [Shelter] = []
    for (index, object) in settings.objects.prefix(24).enumerated() {
      guard object.x.isFinite, object.y.isFinite, object.scale.isFinite,
        !["grass", "fern", "purplePlant"].contains(object.kind)
      else { continue }
      let sprite = IdleScreenAquarium.objectSprite(kind: object.kind, time: 0)
      let transform = IdleScreenAquariumObjectTransform(
        object: object,
        sourceWidth: sprite.width, sourceHeight: sprite.height)
      let w = transform.width
      let h = transform.height
      let left = Int(min(1, max(0, object.x)) * Double(width)) - w / 2
      let top = Int(min(1, max(0, object.y)) * 216) - h
      let opening = Self.opening(for: object.kind)
      for row in 0..<h {
        let y = top + row
        guard (0..<216).contains(y) else { continue }
        for column in 0..<w {
          let x = left + column
          guard (0..<width).contains(x),
            let source = transform.sourcePixel(column: column, row: row)
          else { continue }
          if opening?.contains(CGPoint(x: Double(source.x) + 0.5, y: Double(source.y) + 0.5))
            == true
          {
            portals[y * width + x] = Int16(index)
          }
          guard sprite.pixels[source.y * sprite.width + source.x].w > 0 else { continue }
          heights[x] = min(heights[x], Double(y))
          owners[y * width + x] = Int16(index)
        }
      }
      if ["rock", "slate", "driftwood", "moss"].contains(object.kind) {
        let x = min(width - 24, max(24, left + w / 2))
        grazes.append(.init(x: Double(x), y: heights[x]))
      }
      if let opening {
        let rect = transform.bounds(of: opening).offsetBy(dx: Double(left), dy: Double(top))
        shelters.append(.init(objectIndex: index, opening: rect))
      }
    }
    surfaces = heights
    // A two-pass distance transform creates a bounded approach above steep
    // faces. Shrimp swim these approaches rather than walking through stone.
    for x in 1..<width { heights[x] = min(heights[x], heights[x - 1] + 0.65) }
    for x in stride(from: width - 2, through: 0, by: -1) {
      heights[x] = min(heights[x], heights[x + 1] + 0.65)
    }
    travelSurfaces = heights
    self.owners = owners
    self.portals = portals
    grazingAnchors = grazes
    self.shelters = shelters
  }

  func surface(at x: Double, radius: Int) -> Double {
    height(in: surfaces, at: x, radius: radius)
  }

  func masks(x: Int, y: Int, shelterIndex: Int?, hiding: Bool = false) -> Bool {
    guard (0..<worldWidth).contains(x), (0..<216).contains(y) else { return hiding }
    let position = y * worldWidth + x
    let portal = portals[position]
    if hiding, let shelterIndex, portal != shelterIndex { return true }
    let owner = owners[position]
    guard owner >= 0 else { return false }
    if let shelterIndex, owner == shelterIndex, portal == shelterIndex { return false }
    return true
  }

  private static func opening(for kind: String) -> CGRect? {
    switch kind {
    case "cave": .init(x: 13, y: 15, width: 22, height: 15)
    case "hollowLog": .init(x: 4, y: 9, width: 8, height: 10)
    case "castle": .init(x: 19, y: 37, width: 11, height: 21)
    case "skull": .init(x: 5, y: 8, width: 6, height: 6)
    case "shipwreck": .init(x: 15, y: 20, width: 22, height: 10)
    case "pirateChest": .init(x: 0, y: 12, width: 8, height: 12)
    default: nil
    }
  }

  func schoolPose(item: IdleScreenAquariumRenderInhabitant, time: Double, seed: UInt64)
    -> IdleScreenAquariumAnimal
  {
    let rank = schoolRanks[item.identity] ?? 0
    let count = max(1, schoolRanks.count)
    let columns = min(8, Int(ceil(sqrt(Double(count) * 2))))
    let row = rank / columns
    let column = rank % columns
    let rowCount = min(columns, count - row * columns)
    let rows = Int(ceil(Double(count) / Double(columns)))
    let safeTime = time.isFinite ? max(0, time) : 0
    let period = 96 * Double(worldWidth) / 384
    let phase =
      (safeTime.truncatingRemainder(dividingBy: period) / period + Double(seed % 997) / 997) * 2
      * .pi
    let direction = cos(phase)
    let x =
      Double(worldWidth) / 2 + (Double(worldWidth) / 2 - 85) * sin(phase)
      + (Double(column) - Double(rowCount - 1) / 2) * 18
    let sway = sin(safeTime.truncatingRemainder(dividingBy: 6) / 6 * 2 * .pi + Double(rank)) * 1.2
    let y = 105 + sin(phase * 2) * 8 + (Double(row) - Double(rows - 1) / 2) * 12 + sway
    return .init(
      species: .neonTetra, x: x, y: y, scale: item.juvenile ? 0.33 : 0.6,
      horizontalScale: max(0.12, min(1, abs(direction) * 4)), facingRight: direction >= 0,
      activity: .swimming,
      animationPhase: (Int(safeTime.truncatingRemainder(dividingBy: 1) * 8) + rank) & 3,
      strikeProgress: 0)
  }

  func groundPose(
    item: IdleScreenAquariumRenderInhabitant, species: IdleScreenAquariumSpecies,
    base: IdleScreenAquariumAnimal, time: Double, seed: UInt64
  ) -> IdleScreenAquariumAnimal {
    let scale = base.scale * (item.juvenile ? 0.55 : 1)
    let radius =
      species == .mantisShrimp ? 22 : species == .clawedCrab ? 18 : species == .corydoras ? 13 : 8
    let identity = item.identity &+ seed
    let graze =
      grazingAnchors.isEmpty
      ? Anchor(x: Double(worldWidth) * 0.25, y: floor)
      : grazingAnchors[Int(identity % UInt64(grazingAnchors.count))]
    let floorWalker = species == .clawedCrab
    let shelter =
      floorWalker || shelters.isEmpty ? nil : shelters[Int(identity % UInt64(shelters.count))]
    let aX = min(Double(worldWidth - 32), max(32, graze.x))
    let a = Anchor(x: aX, y: floorWalker ? floor + 3 : surface(at: aX, radius: radius))
    let bX = shelter.map { Double($0.opening.midX) } ?? Double(worldWidth) * 0.75
    let inset = shelter == nil ? 0 : (bX >= a.x ? 10 : -10) * scale
    let b = Anchor(
      x: min(Double(worldWidth - 32), max(32, bX + inset)),
      y: floorWalker
        ? floor + 3
        : shelter.map { Double($0.opening.maxY) + 2 * scale } ?? surface(at: bX, radius: radius))
    let safeTime = time.isFinite ? max(0, time) : 0
    let rate = species == .snail ? 0.22 : 1.0
    let local = (safeTime * rate + Double(identity % 997) * 0.17).truncatingRemainder(
      dividingBy: 80)
    let outbound = local < 40
    let movement = outbound ? local : local - 40
    let moving = movement < 24
    let t = min(1, movement / 24)
    let progress = t * t * (3 - 2 * t)
    let start = outbound ? b : a
    let end = outbound ? a : b
    let x = start.x + (end.x - start.x) * progress
    let travel = floorWalker ? floor + 3 : height(in: travelSurfaces, at: x, radius: radius)
    let fromEnd = min(1, max(0, (1 - progress) * 6))
    let fromStart = min(1, max(0, progress * 6))
    let middleWeight = fromEnd * fromStart
    let endpoints = start.y + (end.y - start.y) * progress
    let blendedY = endpoints + (travel - endpoints) * middleWeight
    let enteringShelter = shelter != nil && (outbound ? progress < 1.0 / 6 : progress > 5.0 / 6)
    let y = floorWalker || enteringShelter ? blendedY : min(blendedY, travel)
    let turn = min(1, max(0, (movement - 24) / 1.2))
    let direction = end.x >= start.x
    let facing = turn < 0.5 ? direction : !direction
    var activity: IdleScreenAquariumActivity = moving ? .walking : outbound ? .grazing : .resting
    if !moving, !outbound, shelter != nil { activity = .hiding }
    if moving, y < surface(at: x, radius: radius) - 3 { activity = .swimming }
    var strike = 0.0
    if species == .mantisShrimp, !moving, movement >= 30, movement < 31 {
      let phase = movement - 30
      strike = phase < 0.2 ? phase / 0.2 : 1 - (phase - 0.2) / 0.8
      activity = .striking
    }
    if turn > 0, turn < 1 { activity = .turning }
    var pose = IdleScreenAquariumAnimal(
      species: species, x: x, y: y + (species == .cherryShrimp ? 2 * scale : 0),
      scale: scale, horizontalScale: 1 - 0.76 * sin(.pi * turn),
      facingRight: facing, activity: activity,
      animationPhase: Int(local * (moving ? 5 : 2)) % 4, strikeProgress: strike)
    pose.shelterIndex = shelter?.objectIndex
    return pose
  }

  private func height(in values: [Double], at x: Double, radius: Int) -> Double {
    let center = x.isFinite ? Int(min(Double(worldWidth - 1), max(0, x))) : 0
    let left = max(0, center - max(0, radius))
    let right = min(worldWidth - 1, center + max(0, radius))
    return values[left...right].min() ?? floor
  }
}
