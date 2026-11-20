import Foundation
import MetalKit
import Testing

@testable import IdleScreenRenderer

@Suite("Aquarium Metal composition")
struct AquariumComputeTests {
  @Test func metalMapsSavedPixelsAndLetterboxingIntoSolidInstances() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let library = try device.makeDefaultLibrary(bundle: Bundle(for: IdleScreenRenderer.self))
    let function = try #require(library.makeFunction(name: "idleScreenAquariumInstances"))
    let pipeline = try device.makeComputePipelineState(function: function)
    let queue = try #require(device.makeCommandQueue())
    let pixels: [SIMD4<Float>] = [
      .init(1, 0, 0, 1), .init(0, 1, 0, 1), .init(0, 0, 1, 1), .init(1, 1, 0, 1),
    ]
    let input = try #require(
      device.makeBuffer(
        bytes: pixels, length: pixels.count * MemoryLayout<SIMD4<Float>>.stride,
        options: .storageModeShared))
    for cropped in [false, true] {
      let output = try #require(
        device.makeBuffer(length: 4 * MemoryLayout<Sample>.stride, options: .storageModeShared))
      var uniforms = Uniforms(
        gridSize: .init(4, 1), worldSize: .init(4, 1), viewport: .init(0, 0, 1, 1),
        contentRect: cropped ? .init(0.25, 0, 0.5, 1) : .init(0, 0, 1, 1), brightness: 0.5)
      let command = try #require(queue.makeCommandBuffer())
      let encoder = try #require(command.makeComputeCommandEncoder())
      encoder.setComputePipelineState(pipeline)
      encoder.setBuffer(input, offset: 0, index: 0)
      encoder.setBuffer(output, offset: 0, index: 1)
      encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
      encoder.dispatchThreads(
        .init(width: 4, height: 1, depth: 1),
        threadsPerThreadgroup: .init(width: 4, height: 1, depth: 1))
      encoder.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      #expect(command.status == .completed)
      let samples = output.contents().bindMemory(to: Sample.self, capacity: 4)
      for index in 0..<4 {
        #expect(samples[index].grid.w == -1)
        #expect(samples[index].foreground.w == 1)
        if cropped && (index == 0 || index == 3) {
          #expect(abs(samples[index].foreground.x - 0.0175) < 0.0001)
        } else {
          let source = cropped ? (index == 1 ? 1 : 3) : index
          #expect(samples[index].foreground.x == pixels[source].x * 0.5)
          #expect(samples[index].foreground.y == pixels[source].y * 0.5)
          #expect(samples[index].foreground.z == pixels[source].z * 0.5)
        }
      }
    }
  }
  private struct Sample {
    let grid: SIMD4<Float>
    let foreground: SIMD4<Float>
  }
  private struct Uniforms {
    let gridSize: SIMD2<UInt32>
    let worldSize: SIMD2<UInt32>
    let viewport: SIMD4<Float>
    let contentRect: SIMD4<Float>
    let brightness: Float
  }
}
