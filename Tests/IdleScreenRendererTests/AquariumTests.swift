import MetalKit
import Testing

@testable import IdleScreenRenderer

@Suite("Shrimp tank")
struct AquariumTests {
  @MainActor
  @Test func aquariumPresentsThroughSharedRenderer() throws {
    let view = MTKView(frame: .init(x: 0, y: 0, width: 768, height: 432))
    let renderer = try IdleScreenRenderer(
      metalView: view,
      configuration: .init(
        glyphScale: 0.5, contrast: 0.5, palette: "Ember",
        patternRawValue: "aquarium"),
      automaticallyDraws: false
    )
    defer { renderer.shutdown() }
    #expect(renderer.draw(at: 0))
    #expect(renderer.draw(at: 12))
    #expect(renderer.pixelMaterialsDebugState == nil)
    #expect(renderer.proceduralDebugState?.instanceCount == 384 * 216)
  }

  @Test func deterministicSceneAndAnimation() {
    let first = IdleScreenAquarium.frame(at: 0, seed: 42)
    #expect(first == IdleScreenAquarium.frame(at: 0, seed: 42))
    #expect(first != IdleScreenAquarium.frame(at: 12, seed: 42))
    #expect(first != IdleScreenAquarium.frame(at: 0, seed: 99))
    #expect(first.count == 384 * 216)
    #expect(first.allSatisfy { $0.w == 1 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
  }

  @Test func habitatAndShrimpHaveDistinctColors() {
    let frame = IdleScreenAquarium.frame(at: 0, seed: 0)
    #expect(frame.contains { $0.x > 0.6 && $0.x > $0.y * 2 })
    #expect(frame.contains { $0.z > $0.y * 1.5 && $0.x > 0.2 })
    #expect(frame[215 * 384].x > frame[0].x)
  }

  @Test func invalidClockFallsBackToStart() {
    #expect(IdleScreenAquarium.frame(at: .nan, seed: 0) == IdleScreenAquarium.frame(at: 0, seed: 0))
    #expect(
      IdleScreenAquarium.frame(at: -.infinity, seed: 0) == IdleScreenAquarium.frame(at: 0, seed: 0))
  }
}
