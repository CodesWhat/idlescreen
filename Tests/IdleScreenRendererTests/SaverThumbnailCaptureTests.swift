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
  /// 320 x 200 points at 2x.
  private static let width = 640
  private static let height = 400

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
  }

  /// Per pattern: glyph scale, intensity, speed, scene start time, frames rendered, pattern scale, trailing. Tuned so each reads at 320 x 200.
  private static let procedural:
    [(
      name: String, glyph: Double, intensity: Double, speed: Double, time: Double, frames: Int,
      scale: Double, trailing: Double
    )] = [
      ("perlin", 0.8, 1, 1, 20, 1, 1, 0.5),
      ("plasma", 1, 0, 1, 3, 1, 3, 1),
      ("sweep", 0.8, 1, 1, 20, 1, 1, 0.5),
      ("matrixRain", 1, 0.3, 1, 10, 1, 1, 0.5),
      ("rainbowCycle", 0.8, 1, 1, 20, 1, 1, 0.5),
      ("fireEffect", 0.8, 1, 1, 20, 1, 1, 0.5),
      ("ripple", 0.2, 0.2, 1, 3, 1, 1, 0.5),
      ("voronoi", 0.8, 1, 1, 20, 1, 1, 0.5),
      ("warp", 0.8, 1, 1, 20, 1, 1, 0.5),
      ("staticNoise", 1, 1, 1, 20, 1, 1, 1),
      ("pulse", 0.8, 0.3, 1, 5, 1, 1, 1),
      ("dvdBounce", 1, 1, 1, 20, 1, 0.5, 1),
      ("metaballs", 0.8, 1, 1, 20, 1, 1, 0.5),
      ("starfield", 1, 0, 1, 20, 1, 4, 1),
      ("spiral", 1, 1, 1, 6, 1, 0.4, 0),
      ("terrain", 1, 0.2, 1, 6, 1, 0.5, 1),
      ("rainOnGlass", 1, 1, 1, 3, 1, 1, 1),
      ("aurora", 1, 1, 1, 6, 1, 0.5, 1),
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
          $0.name, glyph: $0.glyph, intensity: $0.intensity, speed: $0.speed,
          scale: $0.scale, trailing: $0.trailing),
        frames: $0.frames, time: $0.time)
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
          "pixelMaterials", glyph: 0.9, intensity: 0.5, speed: 1, materials: sandAndWater),
        frames: 480, time: 0))
    for shot in shots {
      try render(shot, to: outputURL.appendingPathComponent("\(shot.name).png"))
    }
  }

  @MainActor
  private func render(_ shot: Shot, to url: URL) throws {
    let view = MTKView(
      frame: .init(x: 0, y: 0, width: Self.width / 2, height: Self.height / 2))
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
    for index in 0..<shot.frames {
      let drawable = try #require(view.currentDrawable)
      lastTexture = drawable.texture
      #expect(
        drawable.texture.width == Self.width,
        "drawable \(drawable.texture.width)x\(drawable.texture.height)")
      let before = counter.count
      let time = shot.time + Double(index) / 30
      #expect(renderer.draw(at: time))
      let deadline = Date().addingTimeInterval(10)
      while counter.count == before, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.002)
      }
      #expect(counter.count > before)
    }
    try write(texture: try #require(lastTexture), to: url)
  }

  private func write(texture: any MTLTexture, to url: URL) throws {
    let width = texture.width
    let height = texture.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(
      &bytes, bytesPerRow: width * 4,
      from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    // BGRA to opaque RGBA so the PNG is independent of the drawable's alpha.
    for index in stride(from: 0, to: bytes.count, by: 4) {
      bytes.swapAt(index, index + 2)
      bytes[index + 3] = 255
    }
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
  }
}
