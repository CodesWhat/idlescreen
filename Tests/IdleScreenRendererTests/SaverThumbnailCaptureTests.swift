import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import Testing
import UniformTypeIdentifiers

@testable import IdleScreenRenderer

/// Renders the Studio saver-chooser thumbnails with the real Metal renderer, offscreen.
///
/// Gated by `IDLESCREEN_THUMBNAIL_DIR` (pass it through xcodebuild as
/// `TEST_RUNNER_IDLESCREEN_THUMBNAIL_DIR`). Without it the test is a no-op, so normal test
/// runs write nothing. Output is deterministic: fixed scene seed, fixed timestamps, the
/// default Ember palette and the per-pattern settings listed below. See
/// `design/thumbnails/README.md`.
@Suite("Saver thumbnail capture")
struct SaverThumbnailCaptureTests {
  /// 360 x 180 points at 2x, the 2:1 of a Studio tile (no crop).
  private static let width = 720
  private static let height = 360
  /// The renderer lays its glyph grid out in the view's logical size, then draws at the drawable's
  /// resolution. A view well under 320 x 200 gives a coarse grid of big, crisp glyphs.
  private static let logicalWidth = 252.0
  private static let logicalHeight = 126.0

  private final class CompletionCounter: IdleScreenRendererPerformanceObserving,
    @unchecked Sendable
  {
    private let lock = NSLock()
    private var completed = 0
    func rendererDidRecordPerformance(_ event: IdleScreenRendererPerformanceEvent) {
      if case .completed = event {
        lock.lock()
        completed += 1
        lock.unlock()
      }
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return completed
    }
  }

  private struct Shot {
    let name: String
    let configuration: IdleScreenRendererConfiguration
    let frames: Int
    /// Scene time of the first frame, in seconds. Frames advance at 30 fps.
    let time: Double
    /// Frames composited per-pixel by max, `exposureStep` seconds apart (a long exposure: moving
    /// points leave streaks). 1 captures a single frame.
    var exposure: Int = 1
    var exposureStep: Double = 0.25
  }

  /// Per pattern: intensity, speed, scene start time, pattern scale, trailing, exposure. The
  /// glyph scale is always 1 (the coarsest grid), contrast and scene brightness are full.
  /// `exposure` composites that many frames 0.25 s apart so sparse movers (rain, stars) read as
  /// streaks on the coarse grid. Times come from
  /// `IDLESCREEN_THUMBNAIL_SWEEP=1`, picked by mean luminance x edge density and then by eye.
  private static let procedural:
    [(
      name: String, intensity: Double, speed: Double, time: Double,
      scale: Double, trailing: Double, exposure: Int
    )] = [
      ("topograph", 1, 1, 11, 0.5, 1, 20),
      ("perlin", 0.6, 1, 38.5, 0.5, 0.5, 1),
      ("plasma", 0.25, 1, 1, 1, 1, 1),
      ("sweep", 0.25, 1, 36, 1, 0.5, 1),
      ("matrixRain", 1, 1, 21, 1, 0.5, 1),
      ("rainbowCycle", 0.25, 1, 36, 0.5, 0.5, 1),
      ("fireEffect", 0.6, 1, 11, 0.5, 0.5, 1),
      ("ripple", 1, 1, 1, 0.5, 0.5, 1),
      ("voronoi", 0.6, 1, 11, 0.5, 0.5, 1),
      ("warp", 1, 1, 8.5, 0.5, 0.5, 1),
      ("staticNoise", 1, 1, 13.5, 1, 1, 1),
      ("pulse", 1, 1, 38.5, 0.5, 1, 1),
      ("dvdBounce", 1, 1, 16, 0.5, 1, 1),
      ("metaballs", 0.6, 1, 16, 1, 0.5, 1),
      ("starfield", 1, 1, 6, 0.25, 1, 20),
      ("spiral", 0.25, 1, 21, 0.25, 0.5, 1),
      ("terrain", 0, 1, 6, 0.25, 1, 1),
      ("rainOnGlass", 1, 1, 11, 1, 1, 20),
      ("aurora", 1, 1, 11, 0.5, 1, 1),
      ("aquarium", 1, 1, 20, 1, 1, 1),
    ]

  @MainActor
  @Test("writes saver thumbnails when IDLESCREEN_THUMBNAIL_DIR is set")
  func writeThumbnails() throws {
    guard
      let directory = ProcessInfo.processInfo.environment["IDLESCREEN_THUMBNAIL_DIR"],
      !directory.isEmpty
    else { return }
    let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(
      at: outputURL, withIntermediateDirectories: true)

    func configuration(
      _ pattern: String, glyph: Double, intensity: Double, speed: Double,
      scale: Double = 1, trailing: Double = 0.5,
      materials: IdleScreenPixelMaterialsRendererSettings = .init()
    ) -> IdleScreenRendererConfiguration {
      var value = IdleScreenRendererConfiguration.default
      value.patternRawValue = pattern
      value.sceneSeed = 7
      value.palette = "Ember"
      value.glyphScale = glyph
      value.contrast = 1
      value.sceneBrightness = 1
      value.proceduralSettings.intensity = intensity
      value.proceduralSettings.speed = speed
      value.proceduralSettings.scale = scale
      value.proceduralSettings.trailing = trailing
      value.pixelMaterialsSettings = materials
      return value
    }

    var shots = Self.procedural.map {
      Shot(
        name: $0.name,
        configuration: configuration(
          $0.name, glyph: 1, intensity: $0.intensity, speed: $0.speed,
          scale: $0.scale, trailing: $0.trailing),
        frames: 1, time: $0.time, exposure: $0.exposure)
    }
    // Sand and water together on terraces, captured mid-flow (frame 480 at 30 fps).
    let sandAndWater = IdleScreenPixelMaterialsRendererSettings(
      material: .sand, terrainStyle: .terraces,
      emitterCount: 3, emitterWidth: 8, emitterRate: 8,
      cellScale: 2, paletteRawValue: "canyon")
    shots.append(
      Shot(
        name: "pixelMaterials",
        configuration: configuration(
          "pixelMaterials", glyph: 1, intensity: 1, speed: 1, materials: sandAndWater),
        frames: 480, time: 0))
    if let sweep = ProcessInfo.processInfo.environment["IDLESCREEN_THUMBNAIL_SWEEP"], !sweep.isEmpty
    {
      try sweepTimestamps(shots, to: outputURL)
      return
    }
    for shot in shots {
      try render(shot, to: outputURL.appendingPathComponent("\(shot.name).png"))
    }
  }

  /// Dev aid for choosing each pattern's `time`: renders every single-frame shot at a spread of
  /// timestamps, writes them under `sweep/` and scores each as mean luminance x edge density.
  /// Not part of the normal run; set `IDLESCREEN_THUMBNAIL_SWEEP=1` to use it.
  @MainActor
  private func sweepTimestamps(_ shots: [Shot], to outputURL: URL) throws {
    let directory = outputURL.appendingPathComponent("sweep", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var report = "pattern,time,score\n"
    if ProcessInfo.processInfo.environment["IDLESCREEN_THUMBNAIL_SWEEP"] == "params" {
      for shot in shots where shot.frames == 1 {
        for intensity in [0.25, 0.6, 1.0] {
          for scale in [0.5, 1.0, 2.0, 4.0] {
            var configuration = shot.configuration
            configuration.proceduralSettings.intensity = intensity
            configuration.proceduralSettings.scale = scale
            let candidate = Shot(
              name: shot.name, configuration: configuration, frames: 1, time: 20,
              exposure: shot.exposure)
            let name = "\(shot.name)_i\(intensity)_s\(scale)"
            try render(candidate, to: directory.appendingPathComponent("\(name).png"))
          }
        }
      }
      return
    }
    for shot in shots where shot.frames == 1 {
      for step in 0..<16 {
        let time = 1 + Double(step) * 2.5
        let candidate = Shot(
          name: shot.name, configuration: shot.configuration, frames: 1, time: time,
          exposure: shot.exposure)
        let name = "\(shot.name)_\(String(format: "%05.1f", time))"
        let value = try render(candidate, to: directory.appendingPathComponent("\(name).png"))
        report += "\(shot.name),\(time),\(value)\n"
      }
    }
    try report.write(
      to: directory.appendingPathComponent("scores.csv"), atomically: true, encoding: .utf8)
  }

  /// Mean luminance x fraction of pixels whose right or lower neighbour differs by more than 0.15.
  private func score(bytes: [UInt8], width: Int, height: Int) -> Double {
    func luma(_ index: Int) -> Double {
      (0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1])
        + 0.0722 * Double(bytes[index + 2])) / 255
    }
    var total = 0.0
    var edges = 0
    for y in 0..<(height - 1) {
      for x in 0..<(width - 1) {
        let here = luma((y * width + x) * 4)
        total += here
        if abs(here - luma((y * width + x + 1) * 4)) > 0.15
          || abs(here - luma(((y + 1) * width + x) * 4)) > 0.15
        {
          edges += 1
        }
      }
    }
    let count = Double((width - 1) * (height - 1))
    return (total / count) * (Double(edges) / count)
  }

  @MainActor
  @discardableResult
  private func render(_ shot: Shot, to url: URL) throws -> Double {
    let view = MTKView(
      frame: .init(x: 0, y: 0, width: Self.logicalWidth, height: Self.logicalHeight))
    view.autoResizeDrawable = false
    view.drawableSize = .init(width: Self.width, height: Self.height)
    view.framebufferOnly = false
    let counter = CompletionCounter()
    let renderer = try IdleScreenRenderer(
      metalView: view,
      configuration: shot.configuration,
      mode: .generative,
      automaticallyDraws: false,
      pixelMaterialsCoordinator: .init(),
      performanceObserver: counter
    )
    defer { renderer.shutdown() }
    view.drawableSize = .init(width: Self.width, height: Self.height)
    #expect(Int(view.drawableSize.width) == Self.width)
    (view.layer as? CAMetalLayer)?.drawableSize = .init(width: Self.width, height: Self.height)

    var lastTexture: (any MTLTexture)?
    var composite: [UInt8]?
    let frames = shot.exposure > 1 ? shot.exposure : shot.frames
    for index in 0..<frames {
      let drawable = try #require(view.currentDrawable)
      lastTexture = drawable.texture
      #expect(
        drawable.texture.width == Self.width,
        "drawable \(drawable.texture.width)x\(drawable.texture.height)")
      let before = counter.count
      let time =
        shot.time + (shot.exposure > 1 ? Double(index) * shot.exposureStep : Double(index) / 30)
      #expect(renderer.draw(at: time))
      let deadline = Date().addingTimeInterval(10)
      while counter.count == before, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.002)
      }
      #expect(counter.count > before)
      if shot.exposure > 1 {
        let frame = pixels(of: drawable.texture)
        if let current = composite {
          composite = zip(current, frame).map { max($0, $1) }
        } else {
          composite = frame
        }
      }
    }
    if let composite {
      return try write(bytes: composite, width: Self.width, height: Self.height, to: url)
    }
    let texture = try #require(lastTexture)
    return try write(
      bytes: pixels(of: texture), width: texture.width, height: texture.height, to: url)
  }

  /// BGRA to opaque RGBA so the PNG is independent of the drawable's alpha.
  private func pixels(of texture: any MTLTexture) -> [UInt8] {
    let width = texture.width
    let height = texture.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(
      &bytes, bytesPerRow: width * 4,
      from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    for index in stride(from: 0, to: bytes.count, by: 4) {
      bytes.swapAt(index, index + 2)
      bytes[index + 3] = 255
    }
    return bytes
  }

  private func write(bytes input: [UInt8], width: Int, height: Int, to url: URL) throws -> Double {
    var bytes = input
    let image = try #require(
      bytes.withUnsafeMutableBytes { buffer in
        CGContext(
          data: buffer.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage()
      })
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return score(bytes: bytes, width: width, height: height)
  }
}
