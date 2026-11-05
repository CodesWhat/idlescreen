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
  private let surfaces: [Double]
  private let travelSurfaces: [Double]
  private let owners: [Int16]

  init(settings: IdleScreenAquariumRenderSettings, worldWidth: Int) {
    self.worldWidth = min(1152, max(384, worldWidth))
    let width = self.worldWidth
    let depth =
      settings.substrateDepth.isFinite ? min(0.24, max(0.08, settings.substrateDepth)) : 0.14
    let floor = Double(Int((1 - depth) * 216))
    self.floor = floor
    let phase = Double(settings.seed % 997) / 997 * 6.28
    var heights = (0..<width).map { floor + Double(Int(sin(Double($0) * 0.032 + phase) * 4)) }
    var owners = [Int16](repeating: -1, count: width * 216)
    var grazes: [Anchor] = []
    var shelters: [Shelter] = []
    for (index, object) in settings.objects.prefix(24).enumerated() {
      guard object.x.isFinite, object.y.isFinite, object.scale.isFinite,
        !["grass", "fern", "purplePlant"].contains(object.kind)
      else { continue }
      let sprite = IdleScreenAquarium.objectSprite(kind: object.kind, time: 0)
      let scale = min(1.5, max(0.5, object.scale))
      let w = max(1, Int(Double(sprite.width) * scale))
      let h = max(1, Int(Double(sprite.height) * scale))
      let left = Int(min(1, max(0, object.x)) * Double(width)) - w / 2
      let top = Int(min(1, max(0, object.y)) * 216) - h
      for row in 0..<h {
        let y = top + row
        guard (0..<216).contains(y) else { continue }
        for column in 0..<w {
          let x = left + column
          guard (0..<width).contains(x) else { continue }
          let sourceX = column * sprite.width / w
          let mirroredX = object.flipped ? sprite.width - sourceX - 1 : sourceX
          guard sprite.pixels[(row * sprite.height / h) * sprite.width + mirroredX].w > 0 else {
            continue
          }
          heights[x] = min(heights[x], Double(y))
          owners[y * width + x] = Int16(index)
        }
      }
      if ["rock", "slate", "driftwood", "moss"].contains(object.kind) {
        let x = min(width - 24, max(24, left + w / 2))
        grazes.append(.init(x: Double(x), y: heights[x]))
      }
      let opening: CGRect?
      switch object.kind {
      case "cave": opening = .init(x: 13, y: 15, width: 22, height: 15)
      case "hollowLog": opening = .init(x: 4, y: 9, width: 8, height: 10)
      case "castle": opening = .init(x: 19, y: 37, width: 11, height: 21)
      case "skull": opening = .init(x: 5, y: 8, width: 6, height: 6)
      case "shipwreck": opening = .init(x: 15, y: 20, width: 22, height: 10)
      case "pirateChest": opening = .init(x: 0, y: 12, width: 8, height: 12)
      default: opening = nil
      }
      if let opening {
        let x = object.flipped ? Double(sprite.width) - opening.maxX : opening.minX
        shelters.append(
          .init(
            objectIndex: index,
            opening: .init(
              x: Double(left) + x * Double(w) / Double(sprite.width),
              y: Double(top) + opening.minY * Double(h) / Double(sprite.height),
              width: opening.width * Double(w) / Double(sprite.width),
              height: opening.height * Double(h) / Double(sprite.height))))
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
    grazingAnchors = grazes
    self.shelters = shelters
  }

  func surface(at x: Double, radius: Int) -> Double {
    height(in: surfaces, at: x, radius: radius)
  }

  func masks(x: Int, y: Int, shelterIndex: Int?, hiding: Bool = false) -> Bool {
    if hiding, let shelterIndex,
      let shelter = shelters.first(where: { $0.objectIndex == shelterIndex }),
      !shelter.opening.contains(CGPoint(x: x, y: y))
    {
      return true
    }
    guard (0..<worldWidth).contains(x), (0..<216).contains(y) else { return false }
    let owner = owners[y * worldWidth + x]
    guard owner >= 0 else { return false }
    if let shelterIndex, owner == shelterIndex,
      let shelter = shelters.first(where: { $0.objectIndex == shelterIndex }),
      shelter.opening.contains(CGPoint(x: x, y: y))
    {
      return false
    }
    return true
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
    let y = endpoints + (travel - endpoints) * middleWeight
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
