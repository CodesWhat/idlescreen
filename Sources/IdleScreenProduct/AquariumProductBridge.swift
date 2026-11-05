import Foundation
import IdleScreenCore
import IdleScreenRenderer

/// Both product hosts resolve the same immutable saved snapshot. Only the
/// companion controller calls the transaction and simulation APIs.
enum IdleScreenAquariumProduct {
  static func previewTank(
    for species: IdleScreenAquariumSpeciesKind, variant: IdleScreenAquariumVariant,
    sex: IdleScreenAquariumSex, in tank: IdleScreenAquariumTank
  ) -> IdleScreenAquariumTank {
    var preview = tank
    preview.animals = [.init(id: tank.id, species: species, variant: variant, sex: sex)]
    preview.broods = []
    preview.nursery = []
    return preview
  }

  static func storeURL(bundle: Bundle = .main) -> URL {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if let index = arguments.firstIndex(of: "--aquarium-store-path"), index + 1 < arguments.count
      {
        return URL(fileURLWithPath: arguments[index + 1])
      }
    #endif
    let enabled = String(
      describing: bundle.object(forInfoDictionaryKey: "IdleScreenSharedContainerEnabled") ?? "NO"
    ).uppercased()
    if ["YES", "TRUE", "1"].contains(enabled),
      let identifier = bundle.object(forInfoDictionaryKey: "IdleScreenAppGroupIdentifier")
        as? String,
      let paths = IdleScreenSharedContainer.locate(appGroupIdentifier: identifier)
    {
      return paths.rootURL.appending(path: "aquariums-v1.json")
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return support.appending(path: "IdleScreen Development", directoryHint: .isDirectory).appending(
      path: "aquariums-v1.json")
  }

  static func settings(for tank: IdleScreenAquariumTank, worldAspect: Double? = nil)
    -> IdleScreenAquariumRenderSettings
  {
    var settings = IdleScreenAquariumRenderSettings()
    settings.worldWidth = tank.worldWidth
    if let worldAspect, worldAspect.isFinite, worldAspect > 0 {
      settings.worldWidth = min(
        1152, max(tank.worldWidth, Int((216 * min(12, worldAspect)).rounded())))
    }
    settings.seed = tank.seed
    settings.epoch = tank.presentationEpoch.timeIntervalSince1970
    settings.lastFeedingElapsed = tank.lastFedAt?.timeIntervalSince(tank.presentationEpoch)
    settings.substrate = tank.substrate.rawValue
    settings.substrateDepth = tank.substrateDepth
    settings.light = tank.lighting.preset.rawValue
    settings.brightness = tank.lighting.brightness
    settings.lightStartHour = tank.lighting.startsAtHour
    settings.lightDurationHours = tank.lighting.durationHours
    settings.hourOffset = TimeZone.current.secondsFromGMT()
    settings.equipment = Set(tank.automation.equipment.map(\.rawValue))
    settings.flow = tank.automation.flow
    settings.cloudiness =
      tank.keeperMode ? min(0.25, tank.water.waste * 0.15 + tank.water.algae * 0.1) : 0
    settings.objects = tank.decorations.map {
      .init(
        kind: $0.kind.rawValue, x: $0.x, y: $0.y, scale: $0.scale, flipped: $0.flipped,
        foreground: $0.foreground, tiltDegrees: $0.tilt?.degrees ?? 0)
    }
    settings.inhabitants = tank.animals.map { animal in
      let bytes = withUnsafeBytes(of: animal.id.uuid) { Array($0) }
      let identity = bytes.reduce(UInt64(0xcbf2_9ce4_8422_2325)) {
        ($0 ^ UInt64($1)) &* 0x100_0000_01b3
      }
      return .init(
        identity: identity, species: animal.species.rawValue, variant: animal.variant.rawValue,
        juvenile: !animal.isAdult, carryingEggs: tank.broods.contains { $0.motherID == animal.id })
    }
    return settings
  }

  static func displaySettings(
    configuration: IdleScreenConfiguration, library: IdleScreenAquariumLibrary?
  ) -> DisplaySceneSettings {
    guard configuration.source == .generative, configuration.creative.pattern == .aquarium,
      let library
    else { return configuration.display }
    let base = configuration.display
    return .init(
      policy: library.presentation == .panorama ? .panorama : .perDisplay,
      focalDisplayIdentifier: base.focalDisplayIdentifier, quietTreatment: base.quietTreatment,
      outerBoundaryBehavior: base.outerBoundaryBehavior, baseSeed: base.baseSeed)
  }

  static func presentationRevision(
    configuration: IdleScreenConfiguration, library: IdleScreenAquariumLibrary?
  ) -> UInt64 {
    let (sum, overflow) = configuration.revision.addingReportingOverflow(library?.revision ?? 0)
    return overflow ? .max : sum
  }

  static func configuration(for tank: IdleScreenAquariumTank) -> IdleScreenRendererConfiguration {
    .init(
      glyphScale: 0.5, contrast: 0.5, palette: "Ember", patternRawValue: "aquarium",
      sceneSeed: tank.seed, aquariumSettings: settings(for: tank))
  }
}
