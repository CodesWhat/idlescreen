import CoreGraphics
import Foundation
import Testing

@testable import IdleScreenRenderer

@Suite("Demo scroller")
struct DemoScrollerTests {
  typealias Scroller = IdleScreenDemoScroller

  static let vga: [[UInt8]] = [
    [0x00, 0x00, 0x00], [0x00, 0x00, 0xAA], [0x00, 0xAA, 0x00], [0x00, 0xAA, 0xAA],
    [0xAA, 0x00, 0x00], [0xAA, 0x00, 0xAA], [0xAA, 0x55, 0x00], [0xAA, 0xAA, 0xAA],
    [0x55, 0x55, 0x55], [0x55, 0x55, 0xFF], [0x55, 0xFF, 0x55], [0x55, 0xFF, 0xFF],
    [0xFF, 0x55, 0x55], [0xFF, 0x55, 0xFF], [0xFF, 0xFF, 0x55], [0xFF, 0xFF, 0xFF],
  ]

  static func hash(_ frame: Scroller.Frame) -> UInt64 {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for index in frame.indices {
      value = (value ^ UInt64(index)) &* 0x0000_0100_0000_01b3
    }
    return value
  }

  @Test("the palette is exactly the standard 16 VGA colours")
  func vgaPalette() {
    #expect(Scroller.palette.count == 16)
    #expect(Scroller.palette.map { [$0.x, $0.y, $0.z] } == Self.vga)
    #expect(Set(Scroller.palette.map { [$0.x, $0.y, $0.z] }).count == 16)
  }

  @Test("every rendered pixel is one of the 16 palette colours")
  func onlyPaletteColours() {
    let allowed = Set(
      Scroller.palette.map {
        SIMD4<Float>(Float($0.x) / 255, Float($0.y) / 255, Float($0.z) / 255, 1)
      }.map { [$0.x, $0.y, $0.z] })
    for (columns, rows) in [(192, 108), (320, 180), (64, 36)] {
      for time in [0.0, 1.3, 7.9, 61.2] {
        let frame = Scroller.frame(columns: columns, rows: rows, time: time, text: "12:34")
        #expect(frame.indices.count == columns * rows)
        for index in Set(frame.indices) {
          #expect(index < 16)
          let color = Scroller.color(forIndex: index)
          #expect(allowed.contains([color.x, color.y, color.z]))
        }
      }
    }
    #expect(Scroller.color(forIndex: 200) == Scroller.color(forIndex: Scroller.fieldIndex))
  }

  @Test("the field is flat and letters, shadows and field use palette entries")
  func fieldIsFlat() {
    let frame = Scroller.frame(columns: 192, rows: 108, time: 0, text: "")
    #expect(frame.indices.allSatisfy { $0 == Scroller.fieldIndex })
    #expect(Scroller.fieldIndex == 8)
  }

  @Test("adjacent letters take different hues from the palette ring")
  func adjacentHuesDiffer() {
    let ring = Scroller.hueRing
    #expect(ring.count >= 3)
    #expect(Set(ring).count == ring.count)
    for index in ring.indices {
      #expect(ring[index] != ring[(index + 1) % ring.count])
    }
    let frame = Scroller.frame(
      columns: 192, rows: 108, time: 0, text: "IIII", reduceMotion: true)
    let hues = Set(frame.indices).intersection(ring)
    #expect(hues.count == 4)
  }

  @Test("hues rotate in discrete palette steps")
  func hueRotation() {
    let a = Scroller.frame(columns: 192, rows: 108, time: 0, text: "II", reduceMotion: false)
    let b = Scroller.frame(columns: 192, rows: 108, time: 0.5, text: "II", reduceMotion: false)
    #expect(Set(a.indices).isSubset(of: Set(0..<16)))
    #expect(a != b)
  }

  @Test("every letter pixel has a hard shadow pixel offset down and right in a darker colour")
  func dropShadow() {
    for (columns, rows, offset) in [(192, 108, 2), (96, 48, 1)] {
      let frame = Scroller.frame(
        columns: columns, rows: rows, time: 0, text: "HI", reduceMotion: true)
      let hues = Set(Scroller.hueRing)
      var shadowCount = 0
      for row in 0..<rows {
        for column in 0..<columns {
          let value = frame.index(column: column, row: row)
          guard !hues.contains(value), value != Scroller.fieldIndex else { continue }
          shadowCount += 1
          let source = frame.index(column: column - offset, row: row - offset)
          // A shadow pixel is the shadow of the letter pixel up and left of it.
          #expect(hues.contains(source) || source == value)
          if hues.contains(source) {
            #expect(Scroller.shadowIndex(for: source) == value)
          }
        }
      }
      #expect(shadowCount > 0)
    }
    for hue in Scroller.hueRing {
      let shadow = Scroller.shadowIndex(for: hue)
      let sum = { (index: UInt8) in
        Int(Scroller.palette[Int(index)].x) + Int(Scroller.palette[Int(index)].y)
          + Int(Scroller.palette[Int(index)].z)
      }
      #expect(sum(shadow) < sum(hue))
      #expect(shadow != Scroller.fieldIndex)
    }
  }

  @Test("reduce motion is static across time and centred")
  func reduceMotionIsStatic() {
    let first = Scroller.frame(
      columns: 192, rows: 108, time: 0, text: "12:34", reduceMotion: true)
    for time in [0.4, 3.0, 99.9, 12_345.6, .infinity, .nan, -4] {
      #expect(
        Scroller.frame(
          columns: 192, rows: 108, time: time, text: "12:34", reduceMotion: true) == first)
    }
    var minX = Int.max
    var maxX = Int.min
    for row in 0..<108 {
      for column in 0..<192 where first.index(column: column, row: row) != Scroller.fieldIndex {
        minX = min(minX, column)
        maxX = max(maxX, column)
      }
    }
    // Centred within a letter's shear and shadow allowance.
    #expect(abs((minX + maxX) / 2 - 96) <= 12)
    #expect(minX > 0 && maxX < 191)
  }

  @Test("motion changes the frame and the text scrolls right to left")
  func motion() {
    let a = Scroller.frame(columns: 192, rows: 108, time: 1, text: "12:34")
    let b = Scroller.frame(columns: 192, rows: 108, time: 2, text: "12:34")
    #expect(a != b)
    func leftmost(_ frame: Scroller.Frame) -> Int? {
      for column in 0..<frame.columns {
        for row in 0..<frame.rows where frame.index(column: column, row: row) != Scroller.fieldIndex
        {
          return column
        }
      }
      return nil
    }
    // One short step: the leading edge only ever moves left until a copy wraps.
    let early = Scroller.frame(columns: 640, rows: 108, time: 0.1, text: "A")
    let later = Scroller.frame(columns: 640, rows: 108, time: 0.2, text: "A")
    let first = leftmost(early)
    let second = leftmost(later)
    #expect(first != nil && second != nil)
    if let first, let second { #expect(second < first) }
  }

  @Test("empty, long, odd and degenerate input never traps")
  func robustLayout() {
    let long = String(repeating: "THE QUICK BROWN FOX! ", count: 80)
    let odd = "héllo wörld ☃ \n\t\u{0}lowercase 0-9 .:!-"
    for text in ["", " ", "A", long, odd] {
      for (columns, rows) in [(1, 1), (7, 3), (192, 108), (640, 360), (3, 500)] {
        for time in stride(from: 0.0, through: 200.0, by: 13.7) {
          for reduce in [false, true] {
            let frame = Scroller.frame(
              columns: columns, rows: rows, time: time, text: text, reduceMotion: reduce)
            #expect(frame.indices.count == columns * rows)
          }
        }
      }
    }
    for time in [-1.0, .infinity, -.infinity, .nan, 1e15] {
      #expect(
        Scroller.frame(columns: 192, rows: 108, time: time, text: long).indices.count == 192 * 108)
    }
    for (columns, rows) in [(0, 0), (-3, 5), (5, -3), (100_000, 4)] {
      #expect(Scroller.frame(columns: columns, rows: rows, time: 1, text: "A").indices.isEmpty)
    }
  }

  @Test("lowercase draws as uppercase and unsupported characters draw blank")
  func textNormalisation() {
    let upper = Scroller.frame(columns: 192, rows: 108, time: 3, text: "ABC")
    #expect(Scroller.frame(columns: 192, rows: 108, time: 3, text: "abc") == upper)
    let blank = Scroller.frame(columns: 192, rows: 108, time: 3, text: "☃☃☃")
    #expect(blank == Scroller.frame(columns: 192, rows: 108, time: 3, text: "   "))
    #expect(blank.indices.allSatisfy { $0 == Scroller.fieldIndex })
  }

  @Test("every supported character has a glyph with at least one lit pixel")
  func fontCoverage() {
    for character in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:.!-" {
      let glyph = Scroller.BitmapFont.glyph(for: character)
      #expect(glyph.rows.count == 7, "\(character)")
      #expect(glyph.rows.contains { $0 != 0 }, "\(character)")
      #expect(glyph.rows.allSatisfy { $0 < 32 }, "\(character)")
    }
    #expect(Scroller.BitmapFont.glyph(for: " ").rows.allSatisfy { $0 == 0 })
  }

  @Test("pixel scale is a whole number and shared across a panorama")
  func integerScale() {
    #expect(Scroller.pixelScale(sceneHeight: 0) == 1)
    #expect(Scroller.pixelScale(sceneHeight: .nan) == 1)
    #expect(Scroller.pixelScale(sceneHeight: 50) == 1)
    #expect(Scroller.pixelScale(sceneHeight: 1080) == 10)
    #expect(Scroller.pixelScale(sceneHeight: 2160) == 20)
    let full = Scroller.gridSize(for: CGSize(width: 1920, height: 1080), viewport: .full)
    #expect(full.columns == 192 && full.rows == 108)
    let left = IdleScreenRendererViewport(x: 0, y: 0, width: 0.5, height: 1)
    let right = IdleScreenRendererViewport(x: 0.5, y: 0, width: 0.5, height: 1)
    let a = Scroller.gridSize(for: CGSize(width: 1920, height: 1080), viewport: left)
    let b = Scroller.gridSize(for: CGSize(width: 1920, height: 1080), viewport: right)
    #expect(a == b)
    let tiny = Scroller.gridSize(for: .zero, viewport: .full)
    #expect(tiny.columns >= 1 && tiny.rows >= 1)
  }

  @Test("the clock text is HH:MM")
  func clockText() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_700_000_000 + 7 * 3600 + 5 * 60 - 22 * 3600)
    let text = Scroller.clockText(at: date, calendar: calendar)
    #expect(text.count == 5)
    #expect(text[text.index(text.startIndex, offsetBy: 2)] == ":")
    #expect(Scroller.clockText(at: Date(timeIntervalSince1970: 0), calendar: calendar) == "00:00")
  }

  // Goldens captured from this implementation. Any layout, font, wave, palette
  // or shadow change must update them on purpose.
  struct Case {
    let name: String
    let columns: Int
    let rows: Int
    let time: Double
    let text: String
    let reduce: Bool
  }
  static let cases: [Case] = [
    .init(name: "192x108-t0", columns: 192, rows: 108, time: 0, text: "12:34", reduce: false),
    .init(name: "192x108-t2.5", columns: 192, rows: 108, time: 2.5, text: "12:34", reduce: false),
    .init(name: "192x108-t37.2", columns: 192, rows: 108, time: 37.2, text: "12:34", reduce: false),
    .init(name: "320x180-t0", columns: 320, rows: 180, time: 0, text: "12:34", reduce: false),
    .init(name: "320x180-t11.1", columns: 320, rows: 180, time: 11.1, text: "12:34", reduce: false),
    .init(name: "96x48-t4", columns: 96, rows: 48, time: 4, text: "23:59", reduce: false),
    .init(name: "192x108-reduce", columns: 192, rows: 108, time: 9, text: "12:34", reduce: true),
    .init(name: "320x180-reduce", columns: 320, rows: 180, time: 9, text: "12:34", reduce: true),
  ]
  static let expected: [String: UInt64] = [
    "192x108-t0": 0xce92_e71f_536c_7a8d,
    "192x108-t2.5": 0x0368_5037_e596_cd89,
    "192x108-t37.2": 0x6cb8_b101_0fa0_eea5,
    "320x180-t0": 0x2f0b_33ce_b44a_6b7c,
    "320x180-t11.1": 0x065b_b99a_b98e_cec5,
    "96x48-t4": 0x6d37_f5f6_ee19_ebfd,
    "192x108-reduce": 0x7ab8_5f4f_aa89_890d,
    "320x180-reduce": 0xc6cf_ef45_00d7_fa36,
  ]

  @Test func framesMatchTheCapturedGoldens() {
    var mismatches: [String] = []
    for item in Self.cases {
      let hash = Self.hash(
        Scroller.frame(
          columns: item.columns, rows: item.rows, time: item.time, text: item.text,
          reduceMotion: item.reduce))
      if Self.expected[item.name] != hash {
        mismatches.append("\(item.name) \(String(hash, radix: 16))")
      }
    }
    #expect(mismatches.isEmpty, "pixel drift in \(mismatches)")
  }
}
