import CoreGraphics
import Foundation

/// A demoscene-style text scroller on a strict 16-colour VGA palette.
///
/// The scene is a raster of palette indices, never blended colours: heavy,
/// sheared bitmap letters set tight into one logo block, each letter in its
/// own palette hue with a one-pixel bright bevel on its top-left edge, and a
/// hard near-black drop shadow, on a flat light-grey field. Text scrolls right
/// to left with every letter's baseline riding a sine wave, and the hues
/// rotate through the palette in discrete steps. Reduce Motion holds the text
/// still, centred, in its first colours.
///
/// The frame is a pure function of its arguments so the same inputs always
/// give the same pixels. The renderer maps each index to one grid cell, so a
/// scene pixel scales as a whole number of points with no filtering.
public enum IdleScreenDemoScroller {
  /// The standard 16 VGA/CGA colours, in index order.
  public static let palette: [SIMD3<UInt8>] = [
    SIMD3(0x00, 0x00, 0x00),  // 0 black
    SIMD3(0x00, 0x00, 0xAA),  // 1 blue
    SIMD3(0x00, 0xAA, 0x00),  // 2 green
    SIMD3(0x00, 0xAA, 0xAA),  // 3 cyan
    SIMD3(0xAA, 0x00, 0x00),  // 4 red
    SIMD3(0xAA, 0x00, 0xAA),  // 5 magenta
    SIMD3(0xAA, 0x55, 0x00),  // 6 brown
    SIMD3(0xAA, 0xAA, 0xAA),  // 7 light grey
    SIMD3(0x55, 0x55, 0x55),  // 8 dark grey
    SIMD3(0x55, 0x55, 0xFF),  // 9 light blue
    SIMD3(0x55, 0xFF, 0x55),  // 10 light green
    SIMD3(0x55, 0xFF, 0xFF),  // 11 light cyan
    SIMD3(0xFF, 0x55, 0x55),  // 12 light red
    SIMD3(0xFF, 0x55, 0xFF),  // 13 light magenta
    SIMD3(0xFF, 0xFF, 0x55),  // 14 yellow
    SIMD3(0xFF, 0xFF, 0xFF),  // 15 white
  ]

  /// The flat field behind the text: light grey.
  public static let fieldIndex: UInt8 = 7

  /// The hard drop shadow: black.
  public static let shadowColor: UInt8 = 0

  /// Letter hues in rotation order. Every letter takes the next entry, and the
  /// whole ring advances one entry per colour step.
  public static let hueRing: [UInt8] = [4, 2, 1, 5, 6, 3]

  /// The bright twin that bevels a hue's top-left edge.
  public static func highlightIndex(for hue: UInt8) -> UInt8 {
    hue >= 1 && hue <= 6 ? hue + 8 : 15
  }

  /// Scene rows the layout aims for. A display's pixel scale is its height
  /// over this, rounded to a whole number.
  public static let targetRows = 108
  /// Longest text drawn; anything past it is dropped.
  public static let maximumTextLength = 256
  /// Palette rotation steps per second at speed 1.
  public static let colorStepsPerSecond = 5.0
  /// Letter height as a share of the scene height.
  public static let textHeightShare = 0.40

  /// Scene pixels per font pixel for a scene `rows` tall.
  public static func blockSize(rows: Int) -> Int {
    max(1, Int(Double(max(0, rows)) * textHeightShare / Double(BitmapFont.cellHeight)))
  }

  /// The whole-number scale of one scene pixel, in points, for a scene of
  /// `sceneHeight` points. Never below 1.
  public static func pixelScale(sceneHeight: Double) -> Int {
    guard sceneHeight.isFinite, sceneHeight > 0 else { return 1 }
    return max(1, Int((sceneHeight / Double(targetRows)).rounded()))
  }

  /// The grid one display draws: whole-number-scaled cells over its bounds,
  /// with the scale taken from the full scene so every display of a
  /// panorama agrees.
  public static func gridSize(
    for logicalSize: CGSize, viewport: IdleScreenRendererViewport
  ) -> (columns: Int, rows: Int) {
    let width = logicalSize.width.isFinite ? max(1, logicalSize.width) : 1
    let height = logicalSize.height.isFinite ? max(1, logicalSize.height) : 1
    let scale = Double(pixelScale(sceneHeight: height / viewport.normalized.height))
    return (max(1, Int(width / scale)), max(1, Int(height / scale)))
  }

  /// "HH:MM" in the 24-hour clock.
  public static func clockText(
    at date: Date, calendar: Calendar = .current
  ) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  /// One frame of palette indices, row-major, `columns * rows` long.
  public struct Frame: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let indices: [UInt8]

    public func index(column: Int, row: Int) -> UInt8 {
      guard (0..<columns).contains(column), (0..<rows).contains(row) else {
        return IdleScreenDemoScroller.fieldIndex
      }
      return indices[row * columns + column]
    }
  }

  /// Renders a frame. Non-finite or negative times read as 0. Text outside
  /// A-Z, 0-9 and `: . ! -` draws as a blank, lowercase draws as uppercase.
  public static func frame(
    columns: Int,
    rows: Int,
    time rawTime: TimeInterval,
    text rawText: String,
    reduceMotion: Bool = false
  ) -> Frame {
    guard columns > 0, rows > 0, columns <= 8192, rows <= 8192 else {
      return Frame(columns: max(0, columns), rows: max(0, rows), indices: [])
    }
    var indices = [UInt8](repeating: fieldIndex, count: columns * rows)
    let characters = Array(rawText.uppercased().prefix(maximumTextLength))
    guard !characters.isEmpty else {
      return Frame(columns: columns, rows: rows, indices: indices)
    }
    let time = reduceMotion ? 0 : (rawTime.isFinite ? max(0, rawTime) : 0)

    // One font pixel is `block` scene pixels square. A still frame shrinks
    // the type until the whole text fits across the scene.
    var block = blockSize(rows: rows)
    if reduceMotion {
      // Letters, slant and shadow: the real extent of the text in font pixels.
      let cells =
        (characters.count - 1) * BitmapFont.advanceCells + BitmapFont.cellWidth
        + BitmapFont.shearCells + 1
      block = max(1, min(block, columns / cells))
    }
    let advance = BitmapFont.advanceCells * block
    let textWidth = characters.count * advance
    let shadowOffset = block
    let bevel = max(1, block / 4)
    let amplitude = Double(rows) * 0.12
    let waveLength = Double(columns) * 0.45
    let baseline = (rows - BitmapFont.cellHeight * block) / 2
    let colorStep = Int((time * colorStepsPerSecond).rounded(.down))

    // Left edge of the first copy of the text.
    var origins: [Int] = []
    if reduceMotion {
      let extent =
        ((characters.count - 1) * BitmapFont.advanceCells + BitmapFont.cellWidth
          + BitmapFont.shearCells + 1) * block
      origins = [(columns - extent) / 2]
    } else {
      let period = textWidth + max(columns / 3, 4 * block)
      let speed = Double(columns) * 0.12
      let offset = Int((time * speed).rounded(.down)) % period
      // Copies march right to left; start with the one entering at the right.
      var origin = columns - offset
      while origin > -textWidth { origin -= period }
      while origin < columns {
        origins.append(origin)
        origin += period
      }
    }

    struct Placed {
      let x: Int
      let y: Int
      let mask: LetterMask
      let hue: UInt8
    }
    var masks: [Character: LetterMask] = [:]
    var placed: [Placed] = []
    for origin in origins {
      for (position, character) in characters.enumerated() {
        let x = origin + position * advance
        // Skip letters wholly off screen, allowing for shear and shadow.
        guard x + advance + BitmapFont.shearCells * block + shadowOffset > 0, x < columns
        else { continue }
        let wave =
          reduceMotion
          ? 0.0
          : amplitude * sin(2 * Double.pi * Double(x) / waveLength + time * 2.4)
        let mask: LetterMask
        if let cached = masks[character] {
          mask = cached
        } else {
          mask = LetterMask(glyph: BitmapFont.glyph(for: character), block: block)
          masks[character] = mask
        }
        placed.append(
          Placed(
            x: x, y: baseline + Int(wave.rounded()), mask: mask,
            hue: hueRing[(position + colorStep) % hueRing.count]))
      }
    }

    func paint(_ item: Placed, dx: Int, dy: Int, color: (Int, Int) -> UInt8?) {
      let mask = item.mask
      for ly in 0..<mask.height {
        let y = item.y + dy + ly
        guard (0..<rows).contains(y) else { continue }
        for lx in 0..<mask.width where mask.isSet(lx, ly) {
          let x = item.x + dx + lx
          guard (0..<columns).contains(x), let value = color(lx, ly) else { continue }
          indices[y * columns + x] = value
        }
      }
    }
    // Every shadow first, so one letter's shadow never covers another letter.
    for item in placed {
      paint(item, dx: shadowOffset, dy: shadowOffset) { _, _ in shadowColor }
    }
    for item in placed {
      let mask = item.mask
      let highlight = highlightIndex(for: item.hue)
      paint(item, dx: 0, dy: 0) { lx, ly in
        mask.isSet(lx - bevel, ly) && mask.isSet(lx, ly - bevel) ? item.hue : highlight
      }
    }
    return Frame(columns: columns, rows: rows, indices: indices)
  }

  /// One letter's solid pixels at a given block size, sheared.
  struct LetterMask {
    let width: Int
    let height: Int
    private let bits: [Bool]

    init(glyph: BitmapFont.Glyph, block: Int) {
      width = (BitmapFont.cellWidth + BitmapFont.shearCells) * block
      height = BitmapFont.cellHeight * block
      var bits = [Bool](repeating: false, count: width * height)
      for cellRow in 0..<BitmapFont.cellHeight {
        let shear = BitmapFont.shear(row: cellRow)
        for cellColumn in 0..<BitmapFont.cellWidth
        where glyph.isBold(column: cellColumn, row: cellRow) {
          for y in (cellRow * block)..<((cellRow + 1) * block) {
            for x in ((cellColumn + shear) * block)..<((cellColumn + shear + 1) * block) {
              bits[y * width + x] = true
            }
          }
        }
      }
      self.bits = bits
    }

    func isSet(_ x: Int, _ y: Int) -> Bool {
      guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
      return bits[y * width + x]
    }
  }

  /// An original 5x7 bitmap face for A-Z, 0-9 and `: . ! -`.
  enum BitmapFont {
    static let width = 5
    static let height = 7
    /// The face is drawn heavy: every lit pixel also fills the pixel to its
    /// right and below, so strokes are two font pixels thick.
    static let cellWidth = width + 1
    static let cellHeight = height + 1
    /// One font pixel of space between letters.
    static let advanceCells = cellWidth + 1
    /// The slant: a row's shift is one font pixel per two rows from the base.
    static let shearCells = (cellHeight - 1) / 2
    static func shear(row: Int) -> Int { (cellHeight - 1 - row) / 2 }

    struct Glyph {
      /// Seven rows, five bits each, most significant bit leftmost.
      let rows: [UInt8]

      /// The heavy form: a cell is lit when any of the four pixels up and to
      /// its left is lit.
      func isBold(column: Int, row: Int) -> Bool {
        isSet(column: column, row: row) || isSet(column: column - 1, row: row)
          || isSet(column: column, row: row - 1) || isSet(column: column - 1, row: row - 1)
      }

      func isSet(column: Int, row: Int) -> Bool {
        guard (0..<BitmapFont.width).contains(column),
          (0..<BitmapFont.height).contains(row)
        else { return false }
        return rows[row] & (1 << UInt8(BitmapFont.width - 1 - column)) != 0
      }
    }

    static func glyph(for character: Character) -> Glyph {
      table[character] ?? blank
    }

    private static let blank = Glyph(rows: [UInt8](repeating: 0, count: height))

    private static func make(_ lines: [String]) -> Glyph {
      Glyph(
        rows: lines.map { line in
          line.reduce(UInt8(0)) { ($0 << 1) | ($1 == "X" ? 1 : 0) }
        })
    }

    private static let table: [Character: Glyph] = {
      let source: [Character: [String]] = [
        "A": [".XXX.", "X...X", "X...X", "XXXXX", "X...X", "X...X", "X...X"],
        "B": ["XXXX.", "X...X", "X...X", "XXXX.", "X...X", "X...X", "XXXX."],
        "C": [".XXXX", "X....", "X....", "X....", "X....", "X....", ".XXXX"],
        "D": ["XXXX.", "X...X", "X...X", "X...X", "X...X", "X...X", "XXXX."],
        "E": ["XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "XXXXX"],
        "F": ["XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "X...."],
        "G": [".XXXX", "X....", "X....", "X.XXX", "X...X", "X...X", ".XXXX"],
        "H": ["X...X", "X...X", "X...X", "XXXXX", "X...X", "X...X", "X...X"],
        "I": ["XXXXX", "..X..", "..X..", "..X..", "..X..", "..X..", "XXXXX"],
        "J": ["..XXX", "...X.", "...X.", "...X.", "...X.", "X..X.", ".XX.."],
        "K": ["X...X", "X..X.", "X.X..", "XX...", "X.X..", "X..X.", "X...X"],
        "L": ["X....", "X....", "X....", "X....", "X....", "X....", "XXXXX"],
        "M": ["X...X", "XX.XX", "X.X.X", "X.X.X", "X...X", "X...X", "X...X"],
        "N": ["X...X", "XX..X", "XX..X", "X.X.X", "X..XX", "X..XX", "X...X"],
        "O": [".XXX.", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX."],
        "P": ["XXXX.", "X...X", "X...X", "XXXX.", "X....", "X....", "X...."],
        "Q": [".XXX.", "X...X", "X...X", "X...X", "X.X.X", "X..X.", ".XX.X"],
        "R": ["XXXX.", "X...X", "X...X", "XXXX.", "X.X..", "X..X.", "X...X"],
        "S": [".XXXX", "X....", "X....", ".XXX.", "....X", "....X", "XXXX."],
        "T": ["XXXXX", "..X..", "..X..", "..X..", "..X..", "..X..", "..X.."],
        "U": ["X...X", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX."],
        "V": ["X...X", "X...X", "X...X", "X...X", "X...X", ".X.X.", "..X.."],
        "W": ["X...X", "X...X", "X...X", "X.X.X", "X.X.X", "XX.XX", "X...X"],
        "X": ["X...X", "X...X", ".X.X.", "..X..", ".X.X.", "X...X", "X...X"],
        "Y": ["X...X", "X...X", ".X.X.", "..X..", "..X..", "..X..", "..X.."],
        "Z": ["XXXXX", "....X", "...X.", "..X..", ".X...", "X....", "XXXXX"],
        "0": [".XXX.", "X...X", "X..XX", "X.X.X", "XX..X", "X...X", ".XXX."],
        "1": ["..X..", ".XX..", "..X..", "..X..", "..X..", "..X..", ".XXX."],
        "2": [".XXX.", "X...X", "....X", "...X.", "..X..", ".X...", "XXXXX"],
        "3": ["XXXX.", "....X", "....X", ".XXX.", "....X", "....X", "XXXX."],
        "4": ["...X.", "..XX.", ".X.X.", "X..X.", "XXXXX", "...X.", "...X."],
        "5": ["XXXXX", "X....", "XXXX.", "....X", "....X", "X...X", ".XXX."],
        "6": [".XXX.", "X....", "X....", "XXXX.", "X...X", "X...X", ".XXX."],
        "7": ["XXXXX", "....X", "...X.", "..X..", ".X...", ".X...", ".X..."],
        "8": [".XXX.", "X...X", "X...X", ".XXX.", "X...X", "X...X", ".XXX."],
        "9": [".XXX.", "X...X", "X...X", ".XXXX", "....X", "....X", ".XXX."],
        ":": [".....", "..X..", "..X..", ".....", "..X..", "..X..", "....."],
        ".": [".....", ".....", ".....", ".....", ".....", ".XX..", ".XX.."],
        "!": ["..X..", "..X..", "..X..", "..X..", "..X..", ".....", "..X.."],
        "-": [".....", ".....", ".....", ".XXX.", ".....", ".....", "....."],
      ]
      return source.mapValues(make)
    }()
  }
}

extension IdleScreenDemoScroller {
  /// The RGBA colour of a palette index, as the renderer draws it. An index
  /// past the palette reads as the field colour.
  public static func color(forIndex index: UInt8) -> SIMD4<Float> {
    let entry = palette[Int(index) < palette.count ? Int(index) : Int(fieldIndex)]
    return SIMD4(
      Float(entry.x) / 255, Float(entry.y) / 255, Float(entry.z) / 255, 1)
  }
}
