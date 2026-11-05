import Foundation

enum IdleScreenAquariumActivity: Equatable {
  case walking, grazing, swimming, exploring, resting, striking, hovering, turning, hiding
}

struct IdleScreenAquariumAnimal: Equatable {
  let species: IdleScreenAquariumSpecies
  let x: Double
  let y: Double
  let scale: Double
  let horizontalScale: Double
  let facingRight: Bool
  let activity: IdleScreenAquariumActivity
  let animationPhase: Int
  let strikeProgress: Double
  var shelterIndex: Int? = nil
}

/// Samples presentation behavior without coupling animal motion to frame rate
/// or the order in which display consumers ask for a frame.
enum IdleScreenAquariumBehavior {
  static func animals(at elapsed: TimeInterval, seed: UInt64) -> [IdleScreenAquariumAnimal] {
    let time = elapsed.isFinite ? max(0, elapsed).truncatingRemainder(dividingBy: 86_400) : 0
    let seedPhase = Double(seed % 997) / 997
    var animals: [IdleScreenAquariumAnimal] = []
    for index in 0..<10 {
      let species: IdleScreenAquariumSpecies =
        index < 8 ? .cherryShrimp : index == 8 ? .mantisShrimp : .lionfish
      let swimming = index >= 5 && index < 8
      let duration: Double =
        species == .lionfish ? 100 : species == .mantisShrimp || swimming ? 72 : 64
      let local = (time + Double(index) * 7.3 + seedPhase * duration).truncatingRemainder(
        dividingBy: duration)
      let moveEnd: Double =
        species == .lionfish ? 36 : species == .mantisShrimp ? 22 : swimming ? 28 : 20
      let returnStart = duration / 2
      let returnEnd = returnStart + moveEnd
      let outbound = local < returnStart
      let moving = local < moveEnd || (local >= returnStart && local < returnEnd)
      let movementTime = outbound ? local : local - returnStart
      let progress = smooth(min(1, movementTime / moveEnd))
      let start: Double
      let end: Double
      if species == .lionfish {
        start = 70 + seedPhase * 18
        end = 300 - seedPhase * 18
      } else if species == .mantisShrimp {
        start = 66 + seedPhase * 12
        end = 288 - seedPhase * 16
      } else {
        start = 36 + Double(index * 31 % 140)
        end = min(342, start + 74 + Double(index * 17 % 65))
      }
      let x = outbound ? start + (end - start) * progress : end - (end - start) * progress
      let pauseEnd = outbound ? returnStart : duration
      let turnDuration = species == .lionfish ? 2.0 : 1.2
      let turn = min(1, max(0, (local - (pauseEnd - turnDuration)) / turnDuration))
      let horizontalScale = 1 - 0.76 * sin(.pi * turn)
      let facingRight = turn < 0.5 ? outbound : !outbound
      var activity: IdleScreenAquariumActivity
      if species == .lionfish {
        activity = .hovering
      } else if swimming {
        activity = moving ? .swimming : .resting
      } else if species == .mantisShrimp {
        activity = moving ? .exploring : .resting
      } else {
        activity = moving ? .walking : .grazing
      }
      var strikeProgress = 0.0
      if species == .mantisShrimp {
        let strikeTime = local - (outbound ? 29.5 : 65.5)
        if strikeTime >= 0 && strikeTime < 1 {
          activity = .striking
          // A quick extension followed by a slower recovery into the folded pose.
          strikeProgress =
            strikeTime < 0.2 ? smooth(strikeTime / 0.2) : 1 - smooth((strikeTime - 0.2) / 0.8)
        }
      }
      if turn > 0 { activity = .turning }
      let depthPhase = local / duration * 2 * .pi
      let scale: Double
      let y: Double
      if species == .lionfish {
        scale = 0.94 + sin(depthPhase) * 0.04
        y = 94 + sin(depthPhase * 2) * 5
      } else if swimming {
        scale = 0.83 + sin(depthPhase) * 0.05
        y = 108 + Double(index % 3) * 24 + sin(depthPhase * 2) * 4
      } else {
        scale = species == .mantisShrimp ? 1 : 0.94 + Double(index % 3) * 0.03
        y = species == .mantisShrimp ? 193 : 188 + Double(index % 3) * 3
      }
      let rate: Double =
        moving ? (species == .lionfish ? 1.2 : 5) : (species == .lionfish ? 1.2 : 2)
      animals.append(
        .init(
          species: species, x: x, y: y, scale: scale,
          horizontalScale: horizontalScale, facingRight: facingRight, activity: activity,
          animationPhase: Int((local * rate).rounded(.down)) % 4,
          strikeProgress: strikeProgress))
    }
    return animals
  }

  private static func smooth(_ value: Double) -> Double {
    value * value * value * (value * (value * 6 - 15) + 10)
  }
}
