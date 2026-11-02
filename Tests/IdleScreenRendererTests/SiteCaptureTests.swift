import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import Testing
import UniformTypeIdentifiers

@testable import IdleScreenRenderer

/// Renders the marketing-site screenshots with the real Metal renderer, offscreen.
///
/// Gated by `IDLESCREEN_SITE_CAPTURE_DIR` (pass it through xcodebuild as
/// `TEST_RUNNER_IDLESCREEN_SITE_CAPTURE_DIR`). Without it the test is a no-op, so
/// normal test runs write nothing. Output is deterministic: default palette and
/// configuration, fixed scene seed, fixed timestamps. See `website/README.md`.
@Suite("Site capture")
struct SiteCaptureTests {
  private static let width = 1_600
  private static let height = 1_000

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
    let camera: Bool
  }

  @MainActor
  @Test("writes site captures when IDLESCREEN_SITE_CAPTURE_DIR is set")
  func writeSiteCaptures() throws {
    guard
      let directory = ProcessInfo.processInfo.environment[
        "IDLESCREEN_SITE_CAPTURE_DIR"]
    else { return }
    let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(
      at: outputURL, withIntermediateDirectories: true)

    func configuration(
      _ pattern: String,
      materials: IdleScreenPixelMaterialsRendererSettings = .init()
    ) -> IdleScreenRendererConfiguration {
      var value = IdleScreenRendererConfiguration.default
      value.patternRawValue = pattern
      value.sceneSeed = 7
      // Larger, higher-contrast glyphs than the app default (a 2x drawable over an
      // 800x500 view) so the frames stay legible at thumbnail size. The palette stays the default.
      value.glyphScale = 0.9
      value.contrast = 1
      value.pixelMaterialsSettings = materials
      return value
    }

    let shots = [
      Shot(name: "aurora", configuration: configuration("aurora"), frames: 1, camera: false),
      Shot(
        name: "pixel-materials-sand",
        configuration: configuration("pixelMaterials", materials: .init(material: .sand)),
        frames: 420, camera: false),
      Shot(
        name: "camera-synthetic", configuration: configuration("perlin"), frames: 1, camera: true),
    ]
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
      mode: shot.camera ? .camera : .generative,
      automaticallyDraws: false,
      pixelMaterialsCoordinator: .init(),
      performanceObserver: counter
    )
    defer { renderer.shutdown() }
    view.drawableSize = .init(width: Self.width, height: Self.height)
    #expect(Int(view.drawableSize.width) == Self.width)
    (view.layer as? CAMetalLayer)?.drawableSize = .init(width: Self.width, height: Self.height)

    if shot.camera {
      let pixels = Self.syntheticPortrait(width: 1_280, height: 720)
      let frame = pixels.withUnsafeBytes { buffer in
        IdleScreenRendererCameraFrame.samplingBGRA(
          producerStreamEpoch: 1, sequence: 1, width: 1_280, height: 720,
          bytesPerRow: 1_280 * 4, pixels: buffer,
          columns: IdleScreenRendererCameraFrame.productionColumns,
          rows: IdleScreenRendererCameraFrame.productionRows)
      }
      renderer.submit(cameraFrame: try #require(frame))
    }

    var lastTexture: (any MTLTexture)?
    for index in 0..<shot.frames {
      let drawable = try #require(view.currentDrawable)
      lastTexture = drawable.texture
      #expect(
        drawable.texture.width == Self.width,
        "drawable \(drawable.texture.width)x\(drawable.texture.height)")
      let before = counter.count
      let time = shot.frames == 1 ? 30.0 : Double(index) / 30
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

  /// A generated head-and-shoulders luminance image: a lit ellipse for the head,
  /// a wider one for the shoulders, a soft window glow behind. Not a real person.
  private static func syntheticPortrait(width: Int, height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
    for y in 0..<height {
      for x in 0..<width {
        let u = Double(x) / Double(width - 1)
        let v = Double(y) / Double(height - 1)
        var light = 0.10 + 0.22 * exp(-(pow(u - 0.82, 2) / 0.02 + pow(v - 0.25, 2) / 0.05))
        let head = pow((u - 0.5) / 0.14, 2) + pow((v - 0.38) / 0.24, 2)
        let shoulders = pow((u - 0.5) / 0.34, 2) + pow((v - 1.02) / 0.34, 2)
        let side = 0.75 + 0.25 * (1 - clamp((u - 0.38) / 0.24))
        if head < 1 {
          light = 0.35 + 0.55 * side * clamp(1.2 - head)
        } else if shoulders < 1 {
          light = 0.25 + 0.35 * clamp(1.2 - shoulders)
        }
        let value = UInt8(clamp(light) * 255)
        let offset = (y * width + x) * 4
        pixels[offset] = value
        pixels[offset + 1] = value
        pixels[offset + 2] = value
        pixels[offset + 3] = 255
      }
    }
    return pixels
  }
}
