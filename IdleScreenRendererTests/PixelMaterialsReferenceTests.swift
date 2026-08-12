import Foundation
import Testing
@testable import IdleScreenRenderer

@Suite("Pixel Materials deterministic reference model")
struct PixelMaterialsReferenceTests {
    @Test("seeded terrain is replayable and different seeds change its checksum")
    func seededTerrainReplay() throws {
        let first = try IdleScreenPixelMaterialsTerrain.generate(
            width: 48,
            height: 30,
            settings: .init(seed: 41, basinCount: 3)
        )
        let replay = try IdleScreenPixelMaterialsTerrain.generate(
            width: 48,
            height: 30,
            settings: .init(seed: 41, basinCount: 3)
        )
        let different = try IdleScreenPixelMaterialsTerrain.generate(
            width: 48,
            height: 30,
            settings: .init(seed: 42, basinCount: 3)
        )

        #expect(first == replay)
        #expect(first.checksum == replay.checksum)
        #expect(first.checksum != different.checksum)
    }

    @Test("each terrain family produces a distinct deterministic structure")
    func terrainFamilies() throws {
        let styles: [IdleScreenPixelTerrainStyle] = [
            .watershed,
            .terraces,
            .caverns,
        ]
        let checksums = try styles.map { style in
            try IdleScreenPixelMaterialsTerrain.generate(
                width: 64,
                height: 36,
                settings: .init(terrainStyle: style, seed: 42)
            ).checksum
        }

        #expect(Set(checksums).count == styles.count)
    }

    @Test("advanced terrain controls materially shape deterministic topology")
    func advancedTerrainControls() throws {
        func terrain(
            connectivity: Double = 1,
            channelWidth: Int = 1,
            soilRatio: Double = 0.5,
            obstacleDensity: Double = 0
        ) throws -> IdleScreenPixelMaterialsTerrain {
            try .generate(
                width: 72,
                height: 40,
                settings: .init(
                    seed: 0xC0FFEE,
                    basinCount: 3,
                    basinDepth: 10,
                    minimumBasinCapacity: 8,
                    channelConnectivity: connectivity,
                    channelWidth: channelWidth,
                    rockRatio: 0.5,
                    soilRatio: soilRatio,
                    obstacleDensity: obstacleDensity
                )
            )
        }

        let disconnected = try terrain(connectivity: 0)
        let connected = try terrain(connectivity: 1)
        #expect(disconnected.basins.compactMap(\.downstreamBasinID).isEmpty)
        #expect(
            connected.basins.compactMap(\.downstreamBasinID).count
                == connected.basins.count - 1
        )

        #expect(
            try terrain(channelWidth: 1).checksum
                != terrain(channelWidth: 5).checksum
        )
        #expect(
            try terrain(soilRatio: 0.1).cells
                != terrain(soilRatio: 0.9).cells
        )
        #expect(
            try terrain(obstacleDensity: 0).checksum
                != terrain(obstacleDensity: 1).checksum
        )
    }

    @Test("watershed generation guarantees measured reachable connected basins")
    func watershedGuarantees() throws {
        let terrain = try IdleScreenPixelMaterialsTerrain.generate(
            width: 72,
            height: 40,
            settings: .init(
                seed: 99,
                basinCount: 4,
                basinDepth: 8,
                minimumBasinCapacity: 24,
                channelConnectivity: 1,
                channelWidth: 2
            )
        )

        #expect(terrain.basins.count == 4)
        #expect(terrain.emitters.count >= 1)
        #expect(terrain.terminalSinks.count == 1)
        for (index, basin) in terrain.basins.enumerated() {
            #expect(basin.floorRow > basin.lipRow)
            #expect(basin.capacity >= 24)
            #expect(basin.isReachableFromEmitter)
            if index < terrain.basins.count - 1 {
                #expect(basin.downstreamBasinID == terrain.basins[index + 1].id)
                #expect(basin.spillway != nil)
            }
        }
    }

    @Test("terrain rejects malformed dimensions and storage")
    func terrainValidation() {
        #expect(throws: IdleScreenPixelMaterialsError.invalidDimensions) {
            try IdleScreenPixelMaterialsTerrain(
                width: 1,
                height: 1,
                cells: [.air]
            )
        }
        #expect(throws: IdleScreenPixelMaterialsError.invalidCellStorage) {
            try IdleScreenPixelMaterialsTerrain(
                width: 8,
                height: 8,
                cells: [.air]
            )
        }
    }

    @Test("sand falls onto solids then forms a stable unbiased pile")
    func sandGravityAndAvalanche() throws {
        let terrain = try floorTerrain(width: 7, height: 7)
        var model = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(material: .sand, seed: 3),
            terrain: terrain
        )

        for _ in 0..<3 {
            let injected = model.inject(
                .sand,
                at: .init(column: 3, row: 0)
            )
            #expect(injected)
            model.step(emitting: false)
        }
        for _ in 0..<8 { model.step(emitting: false) }

        let snapshot = model.snapshot
        #expect(snapshot.totalSand == 3)
        #expect(snapshot.sandAmount(at: .init(column: 3, row: 5)) == 1)
        #expect(
            snapshot.sandAmount(at: .init(column: 2, row: 5))
                + snapshot.sandAmount(at: .init(column: 4, row: 5)) == 2
        )
        #expect(model.accounting.isConserved)
    }

    @Test("water falls, spreads, and equalizes without crossing solid walls")
    func waterEqualizationAndWalls() throws {
        var cells = floorCells(width: 9, height: 7)
        for row in 2..<6 {
            cells[row * 9 + 4] = .rock
        }
        let terrain = try IdleScreenPixelMaterialsTerrain(
            width: 9,
            height: 7,
            cells: cells
        )
        var model = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(material: .water, seed: 4),
            terrain: terrain
        )
        for _ in 0..<12 {
            _ = model.inject(.water, at: .init(column: 2, row: 0))
            model.step(emitting: false)
        }
        for _ in 0..<30 { model.step(emitting: false) }

        let leftAmounts = (0..<4).map {
            model.snapshot.waterAmount(at: .init(column: $0, row: 5))
        }
        let rightWater = (5..<9).reduce(0) { total, column in
            total + model.snapshot.waterAmount(
                at: .init(column: column, row: 5)
            )
        }
        #expect((leftAmounts.max() ?? 0) - (leftAmounts.min() ?? 0) <= 1)
        #expect(leftAmounts == [3, 3, 3, 3])
        #expect(rightWater == 0)
        #expect(model.accounting.isConserved)
    }

    @Test("drain boundaries remove only accounted material")
    func drainAccounting() throws {
        let terrain = try IdleScreenPixelMaterialsTerrain(
            width: 8,
            height: 8,
            cells: Array(repeating: .air, count: 64)
        )
        var model = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(
                material: .water,
                seed: 5,
                outerBoundaryBehavior: .drain
            ),
            terrain: terrain
        )
        for _ in 0..<5 {
            let injected = model.inject(
                .water,
                at: .init(column: 3, row: 0)
            )
            #expect(injected)
        }
        for _ in 0..<12 { model.step(emitting: false) }

        #expect(model.snapshot.totalWater == 0)
        #expect(model.accounting.injectedWater == 5)
        #expect(model.accounting.drainedWater == 5)
        #expect(model.accounting.isConserved)
    }

    @Test("a fixed-step host clock caps catch-up and does not advance while paused")
    func fixedStepAndPause() throws {
        let terrain = try floorTerrain(width: 16, height: 12)
        var model = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(seed: 6, fixedStep: 1.0 / 30, maximumSubsteps: 4),
            terrain: terrain
        )

        #expect(model.advance(to: 0) == 0)
        #expect(model.advance(to: 1) == 4)
        #expect(model.tick == 4)
        model.pause()
        #expect(model.advance(to: 2) == 0)
        #expect(model.tick == 4)
        model.resume(at: 2)
        #expect(model.advance(to: 2 + 1.0 / 30) == 1)
        #expect(model.tick == 5)
    }

    @Test("reset and resize deliberately regenerate deterministic state")
    func resetAndResize() throws {
        var model = try IdleScreenPixelMaterialsReferenceModel(
            settings: .init(seed: 77, basinCount: 2),
            width: 32,
            height: 24
        )
        let initial = model.snapshot
        for _ in 0..<20 { model.step(emitting: true) }
        #expect(model.snapshot != initial)

        model.reset()
        #expect(model.snapshot == initial)
        try model.resize(width: 40, height: 28)
        let resized = model.snapshot
        #expect(resized.width == 40)
        #expect(resized.height == 28)
        try model.resize(width: 32, height: 24)
        #expect(model.snapshot == initial)
    }

    @Test("scene phases form a deterministic readable loop")
    func scenePhases() {
        let settings = IdleScreenPixelMaterialsRendererSettings(
            phaseDurations: .init(
                quiet: 1,
                filling: 2,
                settled: 1,
                draining: 1
            ),
            regenerationCadence: 5
        )

        #expect(settings.phase(at: 0) == .quiet)
        #expect(settings.phase(at: 1.5) == .filling)
        #expect(settings.phase(at: 3.5) == .settled)
        #expect(settings.phase(at: 4.5) == .draining)
        #expect(settings.phase(at: 5) == .quiet)
    }

    @Test("shutdown releases state and fences future advancement")
    func shutdown() throws {
        let terrain = try floorTerrain(width: 8, height: 8)
        var model = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(seed: 8),
            terrain: terrain
        )
        model.shutdown()

        #expect(model.isShutdown)
        #expect(model.snapshot.cells.isEmpty)
        #expect(model.advance(to: 10) == 0)
        let injected = model.inject(.water, at: .init(column: 2, row: 0))
        #expect(!injected)
    }

    @Test("zero gravity and zero lateral flow disable only those motions")
    func controlEffects() throws {
        let terrain = try floorTerrain(width: 9, height: 8)
        var noGravity = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(material: .water, seed: 9, gravity: 0),
            terrain: terrain
        )
        _ = noGravity.inject(.water, at: .init(column: 4, row: 0))
        for _ in 0..<8 { noGravity.step(emitting: false) }
        let topRowWater = (0..<9).reduce(0) { total, column in
            total + noGravity.snapshot.waterAmount(
                at: .init(column: column, row: 0)
            )
        }
        let lowerWater = (1..<8).reduce(0) { total, row in
            total + (0..<9).reduce(0) { rowTotal, column in
                rowTotal + noGravity.snapshot.waterAmount(
                    at: .init(column: column, row: row)
                )
            }
        }
        #expect(topRowWater == 1)
        #expect(lowerWater == 0)

        var noLateral = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(
                material: .water,
                seed: 10,
                waterLateralFlow: 0,
                waterEqualization: 0
            ),
            terrain: terrain
        )
        for _ in 0..<8 {
            _ = noLateral.inject(.water, at: .init(column: 4, row: 0))
            noLateral.step(emitting: false)
        }
        for _ in 0..<12 { noLateral.step(emitting: false) }
        let otherColumns = (0..<9).filter { $0 != 4 }.reduce(0) { total, column in
            total + noLateral.snapshot.waterAmount(
                at: .init(column: column, row: 6)
            )
        }
        #expect(otherColumns == 0)
        #expect(noLateral.accounting.isConserved)
    }

    @Test("water pressure and spill rate bound lateral expansion")
    func pressureAndSpillControls() throws {
        let terrain = try floorTerrain(width: 9, height: 8)
        func evolved(
            pressure: Double,
            spillRate: Double
        ) -> IdleScreenPixelMaterialsSnapshot {
            var model = IdleScreenPixelMaterialsReferenceModel(
                settings: .init(
                    material: .water,
                    seed: 0x5151,
                    gravity: 1,
                    waterLateralFlow: 1,
                    waterEqualization: 1,
                    waterPressure: pressure,
                    spillRate: spillRate
                ),
                terrain: terrain
            )
            for _ in 0..<8 {
                _ = model.inject(.water, at: .init(column: 4, row: 0))
                model.step(emitting: false)
            }
            return model.snapshot
        }

        let noPressure = evolved(pressure: 0, spillRate: 1)
        let pressured = evolved(pressure: 1, spillRate: 1)
        let spillClosed = evolved(pressure: 1, spillRate: 0)
        #expect(noPressure != pressured)
        #expect(spillClosed != pressured)
        #expect(pressured.totalWater == noPressure.totalWater)
        #expect(pressured.totalWater == spillClosed.totalWater)
    }

    @Test("a one-cell spillway carries water without leaking through rock")
    func oneCellChannel() throws {
        var cells = Array(
            repeating: IdleScreenPixelTerrainCell.rock,
            count: 12 * 10
        )
        for row in 0..<9 {
            cells[row * 12 + 2] = .air
        }
        for column in 2...9 {
            cells[7 * 12 + column] = .air
        }
        for row in 7..<9 {
            cells[row * 12 + 9] = .air
        }
        let terrain = try IdleScreenPixelMaterialsTerrain(
            width: 12,
            height: 10,
            cells: cells
        )
        var model = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(material: .water, seed: 11),
            terrain: terrain
        )
        for _ in 0..<24 {
            _ = model.inject(.water, at: .init(column: 2, row: 0))
            model.step(emitting: false)
        }
        for _ in 0..<30 { model.step(emitting: false) }

        #expect(model.snapshot.waterAmount(
            at: .init(column: 9, row: 8)
        ) > 0)
        #expect(model.snapshot.waterAmount(
            at: .init(column: 6, row: 6)
        ) == 0)
        #expect(model.accounting.isConserved)
    }

    @Test("zero channel connectivity erects a real barrier between basins")
    func disconnectedBasinsDoNotLeak() throws {
        let settings = IdleScreenPixelMaterialsRendererSettings(
            material: .water,
            seed: 0xD15C0,
            basinCount: 2,
            basinDepth: 3,
            minimumBasinCapacity: 8,
            channelConnectivity: 0,
            emitterWidth: 6,
            emitterRate: 8
        )
        let terrain = try IdleScreenPixelMaterialsTerrain.generate(
            width: 32,
            height: 20,
            settings: settings
        )
        var model = IdleScreenPixelMaterialsReferenceModel(
            settings: settings,
            terrain: terrain
        )
        for _ in 0..<900 { model.step(emitting: true) }
        let downstream = terrain.basins[1]
        let downstreamWater = downstream.columns.reduce(0) { total, column in
            total + (0..<terrain.height).reduce(0) { rowTotal, row in
                rowTotal + model.snapshot.waterAmount(
                    at: .init(column: column, row: row)
                )
            }
        }

        #expect(downstreamWater == 0)
        #expect(model.overflowedBasinIDs.isEmpty)
        let manuallySeeded = model.inject(
            .water,
            at: .init(column: downstream.columns.lowerBound, row: 0)
        )
        #expect(manuallySeeded)
        model.step(emitting: false)
        #expect(model.overflowedBasinIDs.isEmpty)
        #expect(model.accounting.isConserved)
    }

    @Test("generated watershed records real overflow into a downstream basin")
    func watershedOverflow() throws {
        var model = try IdleScreenPixelMaterialsReferenceModel(
            settings: .init(
                material: .water,
                seed: 12,
                basinCount: 2,
                basinDepth: 3,
                minimumBasinCapacity: 8,
                emitterWidth: 6,
                emitterRate: 8
            ),
            width: 32,
            height: 20
        )
        for _ in 0..<900 where model.overflowedBasinIDs.isEmpty {
            model.step(emitting: true)
        }

        #expect(model.overflowedBasinIDs.contains(0))
        #expect(model.accounting.isConserved)
    }

    @Test("drain phase accounts every removed unit and reaches a dry tableau")
    func explicitDrainPhase() throws {
        let terrain = try floorTerrain(width: 10, height: 8)
        var model = IdleScreenPixelMaterialsReferenceModel(
            settings: .init(material: .mixed, seed: 13, drainRate: 1),
            terrain: terrain
        )
        for _ in 0..<20 {
            _ = model.inject(.water, at: .init(column: 5, row: 0))
            if model.tick.isMultiple(of: 2) {
                _ = model.inject(.sand, at: .init(column: 4, row: 0))
            }
            model.step(emitting: false)
        }
        for _ in 0..<120 where
            model.snapshot.totalWater + model.snapshot.totalSand > 0 {
            model.step(emitting: false, draining: true)
        }

        #expect(model.snapshot.totalWater == 0)
        #expect(model.snapshot.totalSand == 0)
        #expect(model.accounting.drainedWater > 0)
        #expect(model.accounting.drainedSand > 0)
        #expect(model.accounting.isConserved)
    }

    @Test("regeneration cadence advances generation and creates a replayable new terrain")
    func regeneration() throws {
        let settings = IdleScreenPixelMaterialsRendererSettings(
            seed: 14,
            phaseDurations: .init(
                quiet: 0.25,
                filling: 0.25,
                settled: 0.25,
                draining: 0.25
            ),
            regenerationCadence: 1,
            maximumSubsteps: 16
        )
        var first = try IdleScreenPixelMaterialsReferenceModel(
            settings: settings,
            width: 32,
            height: 20
        )
        var replay = try IdleScreenPixelMaterialsReferenceModel(
            settings: settings,
            width: 32,
            height: 20
        )
        let dryChecksum = first.snapshot.checksum
        _ = first.advance(to: 0)
        _ = replay.advance(to: 0)
        _ = first.advance(to: 1.01)
        _ = replay.advance(to: 1.01)

        #expect(first.sceneGeneration == 1)
        #expect(first.snapshot == replay.snapshot)
        #expect(first.snapshot.checksum != dryChecksum)
        #expect(first.accounting.isConserved)
    }

    @Test("persistence carries a deterministic bounded fraction across regeneration")
    func persistenceAcrossRegeneration() throws {
        func regenerated(persistence: Double) throws
            -> IdleScreenPixelMaterialsReferenceModel
        {
            let settings = IdleScreenPixelMaterialsRendererSettings(
                material: .water,
                seed: 0xABCD,
                persistence: persistence,
                phaseDurations: .init(
                    quiet: 0.25,
                    filling: 0.25,
                    settled: 0.25,
                    draining: 0.25
                ),
                regenerationCadence: 1
            )
            var model = try IdleScreenPixelMaterialsReferenceModel(
                settings: settings,
                width: 32,
                height: 20
            )
            let injected = model.inject(
                .water,
                at: .init(column: 2, row: 0)
            )
            #expect(injected)
            _ = model.advance(to: 0)
            _ = model.advance(to: 1.01)
            return model
        }

        let cleared = try regenerated(persistence: 0)
        let retained = try regenerated(persistence: 1)
        #expect(cleared.snapshot.totalWater == 0)
        #expect(retained.snapshot.totalWater == 1)
        #expect(retained.accounting.isConserved)
    }

    private func floorTerrain(
        width: Int,
        height: Int
    ) throws -> IdleScreenPixelMaterialsTerrain {
        try IdleScreenPixelMaterialsTerrain(
            width: width,
            height: height,
            cells: floorCells(width: width, height: height)
        )
    }

    private func floorCells(width: Int, height: Int) -> [IdleScreenPixelTerrainCell] {
        var cells = Array(
            repeating: IdleScreenPixelTerrainCell.air,
            count: width * height
        )
        for column in 0..<width {
            cells[(height - 1) * width + column] = .rock
        }
        return cells
    }
}
