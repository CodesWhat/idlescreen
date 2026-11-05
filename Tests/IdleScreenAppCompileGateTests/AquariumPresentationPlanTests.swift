import AppKit
import Foundation
import IdleScreenCore
import IdleScreenDisplay
import MetalKit
import SwiftUI
import Testing

@Suite("Aquarium display presentation planning")
@MainActor
struct AquariumPresentationPlanTests {
  @Test func mirrorsDoNotCreateExtraWindowsAndAssignmentsSurviveReorder() throws {
    var library = IdleScreenAquariumLibrary.starter
    let secondID = UUID()
    try library.duplicateLayout(of: library.selectedTankID, id: secondID, name: "Other tank")
    try library.assign(tankID: library.tanks[0].id, to: "left")
    try library.assign(tankID: secondID, to: "right")
    let topology = try DisplayTopology(displays: [
      display("right", x: 1_000), display("mirror", x: 0, mirror: "left"),
      display("left", x: 0, primary: true),
    ])
    let plan = try IdleScreenAquariumPresentationPlanner.surfaces(
      library: library, topology: topology)
    #expect(plan.count == 2)
    #expect(plan.first { $0.displayID == "left" }?.tank.id == library.tanks[0].id)
    #expect(plan.first { $0.displayID == "right" }?.tank.id == secondID)
    #expect(plan.allSatisfy { $0.configuration.viewport == .full })
    library.presentation = .panorama
    let panorama = try IdleScreenAquariumPresentationPlanner.surfaces(
      library: library, topology: topology)
    #expect(panorama.allSatisfy { $0.tank.id == secondID })
    #expect(panorama[0].configuration.aquariumSettings?.worldWidth ?? 0 > 384)
    #expect(
      panorama[0].configuration.aquariumSettings?.epoch
        == panorama[1].configuration.aquariumSettings?.epoch)
    #expect(panorama[0].configuration.viewport.width == 0.5)
  }

  @Test func savedLayoutPolicyAndWorldAreSharedByEveryHost() {
    var configuration = IdleScreenConfiguration.default
    configuration.creative.pattern = .aquarium
    configuration.revision = 7
    var library = IdleScreenAquariumLibrary.starter
    library.revision = 9
    library.presentation = .perDisplay
    #expect(
      IdleScreenAquariumProduct.displaySettings(configuration: configuration, library: library)
        .policy == .perDisplay)
    #expect(
      IdleScreenAquariumProduct.presentationRevision(configuration: configuration, library: library)
        == 16)
    configuration.creative.pattern = .plasma
    #expect(
      IdleScreenAquariumProduct.displaySettings(configuration: configuration, library: library)
        == configuration.display)
    #expect(
      IdleScreenAquariumProduct.presentationRevision(configuration: configuration, library: library)
        == 16)
    let settings = IdleScreenAquariumProduct.settings(for: library.tanks[0], worldAspect: 3.5)
    #expect(settings.worldWidth == 756)
  }

  @Test func productMappingPropagatesReducedMotionForStudioAndSaver() {
    let library = IdleScreenAquariumLibrary.starter
    let mapped = IdleScreenRendererConfigurationBridge.configuration(
      for: .default, assignment: nil, aquarium: library, reduceMotion: true)
    #expect(mapped.aquariumSettings?.reduceMotion == true)
  }

  @Test func lifecycleAndEnergyPolicyHaveExplicitStopConditions() {
    var policy = IdleScreenAquariumPresentationPolicy()
    #expect(policy.framesPerSecond == 30)
    policy.lowPower = true
    #expect(policy.framesPerSecond == 12)
    policy.lowPower = false
    policy.renderCost = 0.1
    #expect(policy.framesPerSecond == 2)
    policy.renderCost = 0
    policy.reduceMotion = true
    #expect(policy.framesPerSecond == 0)
    policy.reduceMotion = false
    policy.sessionActive = false
    #expect(policy.framesPerSecond == 0)
    policy.sessionActive = true
    policy.screensAwake = false
    #expect(policy.framesPerSecond == 0)
  }

  @Test func reducedMotionPreviewDoesNotRunAContinuousMetalClock() throws {
    let tank = try #require(IdleScreenAquariumLibrary.starter.selectedTank)
    let host = NSHostingView(
      rootView: IdleScreenAquariumMetalPreview(tank: tank, reduceMotion: true)
        .frame(width: 384, height: 216))
    host.frame = .init(x: 0, y: 0, width: 384, height: 216)
    host.layoutSubtreeIfNeeded()
    func metalView(in view: NSView) -> MTKView? {
      if let view = view as? MTKView { return view }
      return view.subviews.compactMap { metalView(in: $0) }.first
    }
    let metal = try #require(metalView(in: host))
    #expect(metal.device != nil)
    #expect(metal.isPaused)
  }

  @Test func studioAquariumAlsoStopsItsContinuousClockForReducedMotion() throws {
    var configuration = IdleScreenAquariumProduct.configuration(
      for: try #require(IdleScreenAquariumLibrary.starter.selectedTank))
    configuration.aquariumSettings?.reduceMotion = true
    let host = NSHostingView(
      rootView: IdleScreenMetalPreview(
        configuration: configuration, mode: .generative, cameraFrame: nil))
    host.frame = .init(x: 0, y: 0, width: 384, height: 216)
    host.layoutSubtreeIfNeeded()
    func metalView(in view: NSView) -> MTKView? {
      if let view = view as? MTKView { return view }
      return view.subviews.compactMap { metalView(in: $0) }.first
    }
    let metal = try #require(metalView(in: host))
    #expect(metal.device != nil)
    #expect(metal.isPaused)
  }

  @Test func desktopWindowCannotStealKeyboardOrDesktopMouseInput() {
    let window = IdleScreenAquariumBackgroundWindow(
      frame: .init(x: 0, y: 0, width: 300, height: 200))
    defer { window.close() }
    #expect(!window.canBecomeKey)
    #expect(!window.canBecomeMain)
    #expect(window.ignoresMouseEvents)
    #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(window.collectionBehavior.contains(.ignoresCycle))
  }

  private func display(_ name: String, x: Double, primary: Bool = false, mirror: String? = nil)
    -> DisplayTopology.Display
  {
    .init(
      persistentIdentifier: .init(rawValue: name),
      logicalFrame: .init(x: x, y: 0, width: 1_000, height: 600),
      nativePixelSize: .init(width: 1_000, height: 600), backingScale: 1, rotationDegrees: 0,
      refreshRateRange: nil, safeAreaInsets: .zero, isPrimary: primary,
      mirrorTargetIdentifier: mirror.map { .init(rawValue: $0) })
  }
}
