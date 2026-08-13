import MetalKit
import Testing
@testable import IdleScreenRenderer

@Suite("Pixel Materials renderer and scene coordination")
struct PixelMaterialsRendererTests {
    @MainActor
    @Test("matching consumers share one process-wide deterministic scene")
    func sharedScene() throws {
        let coordinator = IdleScreenPixelMaterialsSceneCoordinator()
        let settings = IdleScreenPixelMaterialsRendererSettings(seed: 101)
        let first = coordinator.attach(settings: settings)
        let second = coordinator.attach(settings: settings)

        let firstFrame = try coordinator.snapshot(for: first, at: 1)
        let secondFrame = try coordinator.snapshot(for: second, at: 1)

        #expect(firstFrame == secondFrame)
        #expect(coordinator.activeSceneCount == 1)
        #expect(coordinator.consumerCount == 2)
        coordinator.detach(first)
        #expect(coordinator.activeSceneCount == 1)
        coordinator.detach(second)
        #expect(coordinator.activeSceneCount == 0)
        #expect(coordinator.consumerCount == 0)
    }

    @MainActor
    @Test("different seeds and deliberate resize use independent bounded scenes")
    func independentScenes() throws {
        let coordinator = IdleScreenPixelMaterialsSceneCoordinator()
        let first = coordinator.attach(
            settings: .init(seed: 1, cellScale: 1)
        )
        let second = coordinator.attach(
            settings: .init(seed: 2, cellScale: 2)
        )

        let firstFrame = try coordinator.snapshot(for: first, at: 0)
        let secondFrame = try coordinator.snapshot(for: second, at: 0)

        #expect(firstFrame.width <= 160)
        #expect(firstFrame.height <= 90)
        #expect(secondFrame.width < firstFrame.width)
        #expect(secondFrame.height < firstFrame.height)
        #expect(firstFrame.checksum != secondFrame.checksum)
    }

    @MainActor
    @Test("desktop gaps become walls instead of array-adjacent material bridges")
    func gappedViewportCoverage() throws {
        let coordinator = IdleScreenPixelMaterialsSceneCoordinator()
        let settings = IdleScreenPixelMaterialsRendererSettings(
            seed: 404,
            outerBoundaryBehavior: .wall
        )
        let left = coordinator.attach(
            settings: settings,
            viewport: .init(x: 0, y: 0, width: 0.4, height: 1)
        )
        let right = coordinator.attach(
            settings: settings,
            viewport: .init(x: 0.6, y: 0, width: 0.4, height: 1)
        )
        let snapshot = try coordinator.snapshot(for: left, at: 0)
        let gapStart = Int(Double(snapshot.width) * 0.4)
        let gapEnd = Int(Double(snapshot.width) * 0.6)

        for row in 0..<snapshot.height {
            for column in gapStart..<gapEnd {
                let terrain = snapshot.cells[
                    row * snapshot.width + column
                ].terrain
                #expect(terrain == IdleScreenPixelTerrainCell.rock)
            }
        }
        #expect(snapshot.cells[10].terrain == IdleScreenPixelTerrainCell.air)
        #expect(
            snapshot.cells[snapshot.width - 11].terrain
                == IdleScreenPixelTerrainCell.air
        )
        coordinator.detach(left)
        coordinator.detach(right)
    }

    @Test("short sand water and mixed golden sequences replay exactly")
    func goldenSequences() throws {
        let materials: [IdleScreenRenderedMaterial] = [.sand, .water, .mixed]
        var checksums: [UInt64] = []
        for material in materials {
            var first = try IdleScreenPixelMaterialsReferenceModel(
                settings: .init(material: material, seed: 0x5151),
                width: 48,
                height: 30
            )
            var replay = try IdleScreenPixelMaterialsReferenceModel(
                settings: .init(material: material, seed: 0x5151),
                width: 48,
                height: 30
            )
            var sequence: [UInt64] = []
            var replaySequence: [UInt64] = []
            for _ in 0..<45 {
                first.step(emitting: true)
                replay.step(emitting: true)
                if first.tick.isMultiple(of: 15) {
                    sequence.append(first.snapshot.checksum)
                    replaySequence.append(replay.snapshot.checksum)
                }
            }
            #expect(sequence == replaySequence)
            checksums.append(sequence.last ?? 0)
        }
        #expect(Set(checksums).count == materials.count)
        #expect(checksums == [
            16_321_355_229_027_015_481,
            52_583_477_813_980_873,
            17_207_644_226_724_717_797,
        ])
    }

    @Test("panorama crops join at exact material cells")
    func panoramaCrops() throws {
        var model = try IdleScreenPixelMaterialsReferenceModel(
            settings: .init(material: .mixed, seed: 202),
            width: 80,
            height: 40
        )
        for _ in 0..<30 { model.step(emitting: true) }
        let snapshot = model.snapshot
        let left = IdleScreenPixelMaterialsRenderHarness.samples(
            snapshot: snapshot,
            viewport: .init(x: 0, y: 0, width: 0.5, height: 1),
            columns: 40,
            rows: 40
        )
        let right = IdleScreenPixelMaterialsRenderHarness.samples(
            snapshot: snapshot,
            viewport: .init(x: 0.5, y: 0, width: 0.5, height: 1),
            columns: 40,
            rows: 40
        )
        let full = IdleScreenPixelMaterialsRenderHarness.samples(
            snapshot: snapshot,
            viewport: .full,
            columns: 80,
            rows: 40
        )

        let expectedLeft = left.indices.map { index in
            full[(index / 40) * 80 + index % 40]
        }
        let expectedRight = right.indices.map { index in
            full[(index / 40) * 80 + 40 + index % 40]
        }
        #expect(left == expectedLeft)
        #expect(right == expectedRight)
    }

    @MainActor
    @Test("Metal presentation allocates one bounded compute input and tears it down")
    func boundedMetalResources() throws {
        let coordinator = IdleScreenPixelMaterialsSceneCoordinator()
        let view = MTKView(
            frame: .init(x: 0, y: 0, width: 320, height: 180)
        )
        let renderer = try IdleScreenRenderer(
            metalView: view,
            configuration: .init(
                glyphScale: 0.5,
                contrast: 0.5,
                palette: "Ember",
                patternRawValue: "pixelMaterials",
                pixelMaterialsSettings: .init(seed: 303)
            ),
            automaticallyDraws: false,
            pixelMaterialsCoordinator: coordinator
        )

        _ = renderer.draw(at: 1)
        let state = try #require(renderer.pixelMaterialsDebugState)
        #expect(state.usesComputePipeline)
        #expect(state.worldCellCount > 0)
        #expect(state.worldCellCount <= 160 * 90)
        #expect(state.allocatedCellCapacity <= 160 * 90)
        #expect(coordinator.consumerCount == 1)

        renderer.shutdown()
        #expect(renderer.pixelMaterialsDebugState == nil)
        #expect(coordinator.consumerCount == 0)
    }

    @Test("Metal kernel maps synthetic air rock sand and water exactly")
    func syntheticMetalKernel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(
            bundle: Bundle(for: IdleScreenRenderer.self)
        )
        let function = try #require(
            library.makeFunction(name: "idleScreenPixelMaterialInstances")
        )
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try #require(device.makeCommandQueue())
        let state: [UInt32] = [
            0,
            UInt32(IdleScreenPixelTerrainCell.rock.rawValue),
            1 << 8,
            8 << 16,
        ]
        let stateBuffer = try #require(device.makeBuffer(
            bytes: state,
            length: state.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ))
        let outputBuffer = try #require(device.makeBuffer(
            length: 4 * MemoryLayout<TestMaterialGlyphInstance>.stride,
            options: .storageModeShared
        ))
        var uniforms = TestMaterialUniforms(
            gridSize: SIMD2(4, 1),
            worldSize: SIMD2(4, 1),
            viewport: SIMD4(0, 0, 1, 1),
            glyphCount: 10,
            sceneBrightness: 1,
            rockColor: SIMD4(0.5, 0.4, 0.3, 1),
            soilColor: SIMD4(0.6, 0.4, 0.2, 1),
            sandColor: SIMD4(0.9, 0.7, 0.2, 1),
            waterColor: SIMD4(0.1, 0.6, 1, 1)
        )
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(stateBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<TestMaterialUniforms>.stride,
            index: 2
        )
        encoder.dispatchThreads(
            MTLSize(width: 4, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        #expect(commandBuffer.status == .completed)
        let output = outputBuffer.contents().bindMemory(
            to: TestMaterialGlyphInstance.self,
            capacity: 4
        )
        #expect(output[0].gridBrightnessGlyph.z == 0)
        #expect(output[1].gridBrightnessGlyph.z == 0.58)
        #expect(output[2].gridBrightnessGlyph.z == 0.92)
        #expect(output[3].gridBrightnessGlyph.z == 1)
        #expect(output[1].foreground == uniforms.rockColor)
        #expect(output[2].foreground == uniforms.sandColor)
        #expect(output[3].foreground == uniforms.waterColor)
    }

    @MainActor
    @Test("switching away from Pixel Materials releases its scene immediately")
    func switchingPatternReleasesScene() throws {
        let coordinator = IdleScreenPixelMaterialsSceneCoordinator()
        let view = MTKView(frame: .init(x: 0, y: 0, width: 128, height: 128))
        let renderer = try IdleScreenRenderer(
            metalView: view,
            configuration: .init(
                glyphScale: 0.5,
                contrast: 0.5,
                palette: "Ember",
                patternRawValue: "pixelMaterials"
            ),
            automaticallyDraws: false,
            pixelMaterialsCoordinator: coordinator
        )
        _ = renderer.draw(at: 0)
        #expect(coordinator.consumerCount == 1)

        renderer.update(configuration: .init(
            glyphScale: 0.5,
            contrast: 0.5,
            palette: "Ember",
            patternRawValue: "plasma"
        ))

        #expect(coordinator.consumerCount == 0)
        #expect(renderer.pixelMaterialsDebugState == nil)
        renderer.shutdown()
    }

    @MainActor
    @Test("renderer deallocation cannot orphan a materials scene")
    func deallocationReleasesScene() throws {
        let coordinator = IdleScreenPixelMaterialsSceneCoordinator()
        var renderer: IdleScreenRenderer? = try IdleScreenRenderer(
            metalView: MTKView(
                frame: .init(x: 0, y: 0, width: 128, height: 128)
            ),
            configuration: .init(
                glyphScale: 0.5,
                contrast: 0.5,
                palette: "Ember",
                patternRawValue: "pixelMaterials"
            ),
            automaticallyDraws: false,
            pixelMaterialsCoordinator: coordinator
        )
        _ = renderer?.draw(at: 0)
        #expect(coordinator.consumerCount == 1)

        renderer = nil

        #expect(coordinator.consumerCount == 0)
        #expect(coordinator.activeSceneCount == 0)
    }
}

private struct TestMaterialGlyphInstance {
    let gridBrightnessGlyph: SIMD4<Float>
    let foreground: SIMD4<Float>
}

private struct TestMaterialUniforms {
    let gridSize: SIMD2<UInt32>
    let worldSize: SIMD2<UInt32>
    let viewport: SIMD4<Float>
    let glyphCount: UInt32
    let sceneBrightness: Float
    let rockColor: SIMD4<Float>
    let soilColor: SIMD4<Float>
    let sandColor: SIMD4<Float>
    let waterColor: SIMD4<Float>
}
