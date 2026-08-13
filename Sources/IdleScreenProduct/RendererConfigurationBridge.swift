import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer

/// The single product-edge mapping used by the Studio and screen saver. Core
/// owns persistence, Renderer owns execution, and this source is compiled into
/// both hosts so neither can silently omit a new visual setting.
enum IdleScreenRendererConfigurationBridge {
    static func configuration(
        for configuration: IdleScreenConfiguration,
        assignment: DisplaySceneAssignment?
    ) -> IdleScreenRendererConfiguration {
        let creative = configuration.creative
        let settings = creative.settings
        let materials = configuration.materials.normalized
        let viewport = assignment?.viewport?.normalizedFrame
        let sceneBrightness: Double
        switch assignment?.role {
        case .quiet(.black): sceneBrightness = 0
        case .quiet(.subdued): sceneBrightness = 0.18
        case .none, .panorama, .independent, .focus:
            sceneBrightness = 1
        }
        return IdleScreenRendererConfiguration(
            glyphScale: configuration.appearance.glyphScale,
            contrast: configuration.appearance.contrast,
            palette: configuration.appearance.palette,
            patternRawValue: creative.pattern.rawValue,
            cameraIsMirrored: configuration.camera.isMirrored,
            proceduralSettings: IdleScreenProceduralPatternSettings(
                speed: settings.speed,
                scale: settings.scale,
                intensity: settings.intensity,
                trailing: settings.trailing,
                autoCycleInterval: settings.autoCycleInterval,
                matrixTrailLength: settings.matrixTrailLength,
                rainbowAmplitude: settings.rainbowAmplitude,
                fireDecay: settings.fireDecay,
                qualityLevel: settings.qualityLevel
            ),
            viewport: viewport.map {
                .init(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            } ?? .full,
            sceneSeed: assignment?.scene?.seed ?? 0,
            sceneBrightness: sceneBrightness,
            pixelMaterialsSettings: .init(
                material: IdleScreenRenderedMaterial(
                    rawValue: materials.material.rawValue
                ) ?? .water,
                terrainStyle: IdleScreenPixelTerrainStyle(
                    rawValue: materials.terrainFamily.rawValue
                ) ?? .watershed,
                seed: materials.seed,
                basinCount: materials.basinCount,
                basinDepth: materials.basinDepth,
                minimumBasinCapacity: materials.minimumBasinCapacity,
                channelConnectivity: materials.channelConnectivity,
                channelWidth: materials.channelWidth,
                rockRatio: materials.rockRatio,
                soilRatio: materials.soilRatio,
                emitterCount: materials.emitterCount,
                emitterPosition: materials.emitterPosition,
                emitterWidth: materials.emitterWidth,
                emitterRate: materials.emitterRate,
                gravity: materials.gravity,
                cellScale: materials.cellScale,
                waterLateralFlow: materials.waterLateralFlow,
                waterEqualization: materials.waterEqualization,
                waterPressure: materials.waterPressure,
                spillRate: materials.spillRate,
                drainRate: materials.drainRate,
                evaporationRate: materials.evaporationRate,
                obstacleDensity: materials.obstacleDensity,
                paletteRawValue: materials.palette.rawValue,
                persistence: materials.persistence,
                outerBoundaryBehavior: IdleScreenPixelBoundaryBehavior(
                    rawValue: configuration.display.outerBoundaryBehavior.rawValue
                ) ?? .wall,
                phaseDurations: .init(
                    quiet: materials.phaseDurations.quiet,
                    filling: materials.phaseDurations.filling,
                    settled: materials.phaseDurations.settled,
                    draining: materials.phaseDurations.draining
                ),
                regenerationCadence: materials.regenerationCadence
            )
        )
    }
}
