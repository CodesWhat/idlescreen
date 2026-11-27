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
  /// Parallel to `grazingAnchors`: stops under a cliff's approach slope, where
  /// an animal would hover instead of sit on the surface.
  let liftedAnchors: [Bool]
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
    let rawHeights = heights
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
    liftedAnchors = grazes.map {
      let spot = Int(min(Double(width - 32), max(32, $0.x)))
      let lo = max(0, spot - 8)
      let hi = min(width - 1, spot + 8)
      return rawHeights[lo...hi].min()! - heights[lo...hi].min()! > 1.5
    }
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

  /// Timid animals favor tight openings, bold ones wide openings, and seeded
  /// noise breaks ties. Stable for an identity and seed; nil when the animal
  /// never takes cover.
  func shelter(for personality: IdleScreenAquariumPersonality, identity: UInt64, seed: UInt64)
    -> Shelter?
  {
    guard personality.shelterAffinity >= IdleScreenAquariumPersonality.minimumShelterAffinity
    else { return nil }
    var best: Shelter?
    var bestScore = -Double.infinity
    for candidate in shelters {
      let openness = min(1, Double(candidate.opening.width * candidate.opening.height) / 400)
      let fit = personality.boldness * openness + (1 - personality.boldness) * (1 - openness)
      let noise = IdleScreenAquariumPersonality.unit(identity, seed, UInt64(candidate.objectIndex))
      let score = noise * 0.4 + fit * 0.6
      if score > bestScore {
        bestScore = score
        best = candidate
      }
    }
    return best
  }

  /// One grazing stop per trip. Timid animals keep to stops near their cover;
  /// bold ones wander, so successive trips trace a trail across the hardscape.
  func grazeAnchor(
    for personality: IdleScreenAquariumPersonality, identity: UInt64, seed: UInt64, trip: Int,
    origin: Double, side: Double
  ) -> Anchor {
    grazeStop(
      for: personality, identity: identity, seed: seed, trip: trip, origin: origin, side: side
    ).anchor
  }

  /// The chosen stop and whether it sits under a cliff's approach slope.
  func grazeStop(
    for personality: IdleScreenAquariumPersonality, identity: UInt64, seed: UInt64, trip: Int,
    origin: Double, side: Double
  ) -> (anchor: Anchor, lifted: Bool) {
    var best: Anchor?
    var bestLifted = false
    var bestScore = -Double.infinity
    for (index, candidate) in grazeStops.enumerated() {
      let distance = abs(candidate.x - origin) / Double(worldWidth)
      let noise = IdleScreenAquariumPersonality.unit(
        identity, seed, UInt64(trip) << 8 | UInt64(index & 0xFF) | 1 << 62)
      var score =
        noise * 0.5 - (1 - personality.boldness) * distance + personality.boldness * distance * 0.3
      // Stops stay on the animal's own side of its cover, so the resting spot
      // behind the opening never flips between trips.
      if (candidate.x <= origin) != (side > 0) { score -= 4 }
      // A stop under a cliff's approach slope would leave the animal hovering.
      if !liftedAnchors.isEmpty, liftedAnchors[index] { score -= 1.5 }
      if score > bestScore {
        bestScore = score
        best = candidate
        bestLifted = !liftedAnchors.isEmpty && liftedAnchors[index]
      }
    }
    return (best ?? Anchor(x: Double(worldWidth) * 0.25, y: floor), bestLifted)
  }

  private var grazeStops: [Anchor] {
    grazingAnchors.isEmpty ? [Anchor(x: Double(worldWidth) * 0.25, y: floor)] : grazingAnchors
  }

  /// +1 when the animal's grazing stops lie left of `origin` (it rests on the
  /// right side of its cover), -1 for the other side. Fixed per individual.
  private func restingSide(origin: Double, identity: UInt64, seed: UInt64) -> Double {
    let lefts = grazeStops.filter { $0.x <= origin }.count
    if lefts == 0 { return -1 }
    if lefts == grazeStops.count { return 1 }
    return IdleScreenAquariumPersonality.unit(identity, seed, 99) < 0.5 ? 1 : -1
  }

  func groundPose(
    item: IdleScreenAquariumRenderInhabitant, species: IdleScreenAquariumSpecies,
    base: IdleScreenAquariumAnimal, time: Double, seed: UInt64
  ) -> IdleScreenAquariumAnimal {
    let scale = base.scale * (item.juvenile ? 0.55 : 1)
    let radius =
      species == .mantisShrimp ? 22 : species == .clawedCrab ? 18 : species == .corydoras ? 13 : 8
    let identity = item.identity &+ seed
    let personality = IdleScreenAquariumPersonality(identity: item.identity, seed: seed)
    let floorWalker = species == .clawedCrab
    let safeTime = time.isFinite ? max(0, time) : 0
    let rate = species == .snail ? 0.22 : 1.0
    let shifted = safeTime * rate + Double(identity % 997) * 0.17
    let trip = Int(shifted / 80)
    let local = shifted.truncatingRemainder(dividingBy: 80)
    let shelter =
      floorWalker ? nil : self.shelter(for: personality, identity: item.identity, seed: seed)
    let bX = shelter.map { Double($0.opening.midX) } ?? Double(worldWidth) * 0.75
    // Resting height: on the surface, and never above the approach slope, so
    // pausing at a stop keeps the same height the route used to reach it. A
    // stop under the approach slope rests on the physical surface instead.
    var lifted = false
    func ground(_ x: Double) -> Double {
      floorWalker
        ? floor + 3
        : lifted
          ? surface(at: x, radius: radius)
          : min(surface(at: x, radius: radius), height(in: travelSurfaces, at: x, radius: radius))
    }
    let side = restingSide(origin: bX, identity: item.identity, seed: seed)

    // Snails sometimes spend a trip on the side glass: floor, then up the wall.
    let glass =
      species == .snail
      && personality.glassAffinity
        > IdleScreenAquariumPersonality.unit(item.identity, seed, UInt64(trip) | 1 << 61)
    let a: Anchor
    var wallHeight = 0.0
    if glass {
      let inset = 12 * scale + 2
      let left =
        shelter != nil
        ? side > 0
        : IdleScreenAquariumPersonality.unit(item.identity, seed, UInt64(trip) | 1 << 60) < 0.5
      let wallX = left ? inset : Double(worldWidth) - inset
      a = Anchor(x: wallX, y: ground(wallX))
      // Keep the sprite inside the tank when an object lifts the ground near the wall.
      // The snail sprite is 20 rows tall.
      let spriteHeight = 20 * scale
      wallHeight = min(28 + 42 * personality.boldness, max(0, a.y - spriteHeight))
    } else {
      let stop = grazeStop(
        for: personality, identity: item.identity, seed: seed, trip: trip, origin: bX, side: side)
      let graze = stop.anchor
      lifted = stop.lifted
      let aX = min(Double(worldWidth - 32), max(32, graze.x))
      a = Anchor(x: aX, y: ground(aX))
    }
    let inset = shelter == nil ? 0 : (side > 0 ? 10 : -10) * scale
    let b = Anchor(
      x: min(Double(worldWidth - 32), max(32, bX + inset)),
      y: floorWalker
        ? floor + 3
        : shelter.map { Double($0.opening.maxY) + 2 * scale } ?? surface(at: bX, radius: radius))

    // Timid animals sometimes abandon a grazing stop early and dash for cover.
    let retreat =
      !glass && shelter != nil
      && IdleScreenAquariumPersonality.unit(item.identity, seed, UInt64(trip) | 1 << 58)
        < personality.retreatChance
    let travelWindow = 24 / personality.speed
    let returnStart = retreat ? 38 - 2 * (1 - personality.boldness) : 40
    let outbound = local < returnStart
    var movement = outbound ? local : local - returnStart
    // On a glass trip the snail climbs after reaching the wall and descends
    // before it heads back across the floor.
    var climb = 0.0
    if glass {
      if outbound {
        climb = Self.ease(min(1, max(0, (movement - travelWindow) / 8)))
      } else {
        climb = 1 - Self.ease(min(1, movement / 8))
        movement -= 8
      }
    }
    let window = !outbound && retreat ? travelWindow * 0.75 : travelWindow
    let moving = movement >= 0 && movement < window
    let t = min(1, max(0, movement / window))
    let progress = t * t * (3 - 2 * t)
    var aEnd = a
    if !glass, species != .mantisShrimp, !outbound || movement >= window {
      // A short grazing creep along the same surface. Only creeps that stay
      // on one smooth stretch are taken, so the animal never hops a cliff.
      let direction =
        IdleScreenAquariumPersonality.unit(item.identity, seed, UInt64(trip) | 1 << 59) < 0.5
        ? -1.0 : 1.0
      // Not `scale`: the prototype's scale breathes with time and would flip the choice.
      let length = (6 + 14 * personality.boldness) * (item.juvenile ? 0.55 : 1)
      for fraction in [1.0, 0.66, 0.33] {
        let x = min(Double(worldWidth - 32), max(32, a.x + direction * length * fraction))
        let level = ground(x)
        let steps = max(3, Int((abs(x - a.x) / 2).rounded(.up)))
        var hugs = true
        for step in 1...steps {
          let f = Double(step) / Double(steps)
          let gap = ground(a.x + (x - a.x) * f) - (a.y + (level - a.y) * f)
          if gap < 0 || gap > 3 {
            hugs = false
            break
          }
        }
        if hugs {
          aEnd = Anchor(x: x, y: level)
          break
        }
      }
    }
    let start = outbound ? b : aEnd
    let end = outbound ? a : b
    var x = start.x + (end.x - start.x) * progress
    let travel = floorWalker ? floor + 3 : height(in: travelSurfaces, at: x, radius: radius)
    let fromEnd = min(1, max(0, (1 - progress) * 6))
    let fromStart = min(1, max(0, progress * 6))
    let middleWeight = fromEnd * fromStart
    let endpoints = start.y + (end.y - start.y) * progress
    let blendedY = endpoints + (travel - endpoints) * middleWeight
    let enteringShelter = shelter != nil && (outbound ? progress < 1.0 / 6 : progress > 5.0 / 6)
    var y = floorWalker || enteringShelter || lifted ? blendedY : min(blendedY, travel)
    if outbound, !glass, movement >= window {
      let creep = Self.ease(min(1, (movement - window) / 6))
      x = a.x + (aEnd.x - a.x) * creep
      y = a.y + (aEnd.y - a.y) * creep
    }
    y -= climb * wallHeight
    let turn = glass && outbound ? 0 : min(1, max(0, (movement - window) / 1.2))
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
    if climb > 0 { activity = climb < 1 ? .walking : .grazing }
    var pose = IdleScreenAquariumAnimal(
      species: species, x: x, y: y + (species == .cherryShrimp ? 2 * scale : 0),
      scale: scale, horizontalScale: 1 - 0.76 * sin(.pi * turn),
      facingRight: facing, activity: activity,
      animationPhase: Int(local * (moving || climb > 0 && climb < 1 ? 5 : 2)) % 4,
      strikeProgress: strike)
    pose.shelterIndex = climb > 0 ? nil : shelter?.objectIndex
    return pose
  }

  private static func ease(_ value: Double) -> Double { value * value * (3 - 2 * value) }

  private func height(in values: [Double], at x: Double, radius: Int) -> Double {
    let center = x.isFinite ? Int(min(Double(worldWidth - 1), max(0, x))) : 0
    let left = max(0, center - max(0, radius))
    let right = min(worldWidth - 1, center + max(0, radius))
    return values[left...right].min() ?? floor
  }
}
