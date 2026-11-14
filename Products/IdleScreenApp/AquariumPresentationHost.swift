import AppKit
import CoreGraphics
import Foundation
import IdleScreenCore
import IdleScreenDisplay
import IdleScreenRenderer
import MetalKit
import Observation
import QuartzCore

struct IdleScreenAquariumPresentationPolicy: Equatable {
  var screensAwake = true
  var sessionActive = true
  var lowPower = false
  var reduceMotion = false
  var renderCost: TimeInterval = 0
  var framesPerSecond: Int {
    guard screensAwake, sessionActive, !reduceMotion else { return 0 }
    let ceiling = lowPower ? 12 : 30
    guard renderCost.isFinite, renderCost >= 0 else { return 0 }
    guard renderCost > 0 else { return ceiling }
    let budget = lowPower ? 0.08 : 0.2
    return max(1, Int(min(Double(ceiling), budget / max(0.000001, renderCost))))
  }
}

struct IdleScreenAquariumSurfacePlan {
  let displayID: String
  let frame: DisplayTopology.Rect
  let tank: IdleScreenAquariumTank
  let configuration: IdleScreenRendererConfiguration
}

enum IdleScreenAquariumPresentationPlanner {
  static func surfaces(library: IdleScreenAquariumLibrary, topology: DisplayTopology) throws
    -> [IdleScreenAquariumSurfacePlan]
  {
    let settings = DisplaySceneSettings(
      policy: library.presentation == .panorama ? .panorama : .perDisplay)
    let plan = try DisplayScenePlanner().makePlan(
      for: .init(generation: 1, topology: topology), settings: settings, sceneEpoch: 1)
    return plan.assignments.filter { !$0.isMirrorFollower }.compactMap { assignment in
      guard
        let display = topology.displays.first(where: {
          $0.persistentIdentifier == assignment.displayIdentifier
        })
      else { return nil }
      let tank = library.tank(for: assignment.representativeIdentifier.rawValue)
      let bounds = library.presentation == .panorama ? assignment.scene?.bounds : nil
      var configuration = IdleScreenAquariumProduct.configuration(
        for: tank, worldAspect: bounds.map { $0.width / $0.height })
      if let crop = assignment.viewport?.normalizedFrame {
        configuration.viewport = .init(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
      }
      return .init(
        displayID: assignment.displayIdentifier.rawValue, frame: display.logicalFrame,
        tank: tank, configuration: configuration)
    }
  }
}

@MainActor
final class IdleScreenAquariumBackgroundWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  init(frame: NSRect) {
    super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    ignoresMouseEvents = true
    isExcludedFromWindowsMenu = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    hasShadow = false
    isOpaque = true
    backgroundColor = .black
    animationBehavior = .none
    title = "IdleScreen Aquarium Desktop"
  }
}

/// AppKit owns presentation only. The collection controller remains the sole
/// simulation writer, and all surfaces in a tick receive the same Date value.
@MainActor
@Observable
final class IdleScreenAquariumPresentationHost: NSObject, NSWindowDelegate {
  static let shared = IdleScreenAquariumPresentationHost(controller: .shared)
  private(set) var errorMessage: String?
  private(set) var desktopWindowCount = 0
  private(set) var isAnimating = false
  @ObservationIgnored private let controller: IdleScreenAquariumController
  @ObservationIgnored private let topology: () throws -> DisplayTopology
  @ObservationIgnored private let clock: () -> Date
  @ObservationIgnored private let reducedMotion: () -> Bool
  @ObservationIgnored private var desktop: [String: Surface] = [:]
  @ObservationIgnored private var windowed: Surface?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var timerRate = 0
  @ObservationIgnored private var started = false
  @ObservationIgnored private var reconciling = false
  @ObservationIgnored private(set) var policy = IdleScreenAquariumPresentationPolicy()
  @ObservationIgnored private var lastReducedFrameRevision: UInt64?

  private struct Surface {
    let window: NSWindow
    let view: MTKView
    let renderer: IdleScreenRenderer
    var tank: IdleScreenAquariumTank
  }

  init(
    controller: IdleScreenAquariumController,
    topology: @escaping () throws -> DisplayTopology = {
      try MacDisplayTopologyReader().readTopology()
    },
    clock: @escaping () -> Date = { Date() },
    reducedMotion: @escaping () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
  ) {
    self.controller = controller
    self.topology = topology
    self.clock = clock
    self.reducedMotion = reducedMotion
    super.init()
  }

  func start() {
    guard !started else { return }
    started = true
    controller.didChange = { [weak self] in self?.reconcile() }
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(screenChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    center.addObserver(
      self, selector: #selector(visibilityChanged),
      name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    center.addObserver(
      self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(
      self, selector: #selector(screensSleep), name: NSWorkspace.screensDidSleepNotification,
      object: nil)
    workspace.addObserver(
      self, selector: #selector(screensWake), name: NSWorkspace.screensDidWakeNotification,
      object: nil)
    workspace.addObserver(
      self, selector: #selector(sessionInactive),
      name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    workspace.addObserver(
      self, selector: #selector(sessionActive),
      name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    workspace.addObserver(
      self, selector: #selector(screenChanged), name: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil)
    workspace.addObserver(
      self, selector: #selector(powerChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    powerChanged()
    reconcile()
  }

  func toggleDesktop() {
    start()
    controller.perform { $0.desktopEnabled.toggle() }
  }

  func showWindowed() {
    start()
    if let surface = windowed {
      surface.window.makeKeyAndOrderFront(nil)
      return
    }
    do {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.title = controller.selectedTank.name
      window.minSize = .init(width: 384, height: 240)
      window.center()
      windowed = try makeSurface(
        window: window, tank: controller.selectedTank,
        configuration: IdleScreenAquariumProduct.configuration(for: controller.selectedTank))
      window.makeKeyAndOrderFront(nil)
      renderAll(at: clock(), includingOccluded: true)
      updateTimer()
    } catch { errorMessage = error.localizedDescription }
  }

  func shutdown() {
    started = false
    controller.didChange = nil
    timer?.invalidate()
    timer = nil
    timerRate = 0
    isAnimating = false
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    reconciling = true
    for surface in desktop.values {
      surface.renderer.shutdown()
      surface.window.close()
    }
    desktop = [:]
    desktopWindowCount = 0
    if let surface = windowed {
      surface.renderer.shutdown()
      surface.window.close()
    }
    windowed = nil
    reconciling = false
  }

  func windowWillClose(_ notification: Notification) {
    guard !reconciling, let window = notification.object as? NSWindow, windowed?.window === window
    else { return }
    windowed?.renderer.shutdown()
    windowed = nil
    updateTimer()
  }

  private func makeSurface(
    window: NSWindow, tank: IdleScreenAquariumTank,
    configuration: IdleScreenRendererConfiguration
  ) throws -> Surface {
    let view = MTKView(frame: window.contentView?.bounds ?? .zero)
    view.autoresizingMask = [.width, .height]
    var effective = configuration
    effective.aquariumSettings?.reduceMotion = policy.reduceMotion
    let renderer = try IdleScreenRenderer(
      metalView: view, configuration: effective, automaticallyDraws: false)
    window.contentView = view
    return Surface(window: window, view: view, renderer: renderer, tank: tank)
  }

  private func reconcile() {
    guard started, !reconciling else { return }
    reconciling = true
    defer {
      reconciling = false
      updateTimer()
    }
    do {
      let plans =
        controller.library.desktopEnabled
        ? try IdleScreenAquariumPresentationPlanner.surfaces(
          library: controller.library, topology: topology()) : []
      let wanted = Set(plans.map(\.displayID))
      for key in desktop.keys.filter({ !wanted.contains($0) }) {
        desktop[key]?.renderer.shutdown()
        desktop[key]?.window.close()
        desktop[key] = nil
      }
      for plan in plans {
        let rect = NSRect(
          x: plan.frame.x, y: plan.frame.y, width: plan.frame.width, height: plan.frame.height)
        var configuration = plan.configuration
        configuration.aquariumSettings?.reduceMotion = policy.reduceMotion
        if var surface = desktop[plan.displayID] {
          surface.window.setFrame(rect, display: true)
          surface.tank = plan.tank
          surface.renderer.update(configuration: configuration)
          desktop[plan.displayID] = surface
        } else {
          let window = IdleScreenAquariumBackgroundWindow(frame: rect)
          let surface = try makeSurface(
            window: window, tank: plan.tank, configuration: configuration)
          desktop[plan.displayID] = surface
          window.orderFrontRegardless()
        }
      }
      desktopWindowCount = desktop.count
      if var surface = windowed {
        surface.tank = controller.selectedTank
        surface.window.title = surface.tank.name
        var configuration = IdleScreenAquariumProduct.configuration(for: surface.tank)
        configuration.aquariumSettings?.reduceMotion = policy.reduceMotion
        surface.renderer.update(configuration: configuration)
        windowed = surface
      }
      errorMessage = nil
      if !policy.reduceMotion || lastReducedFrameRevision != controller.library.revision {
        renderAll(at: clock(), includingOccluded: true)
        lastReducedFrameRevision = controller.library.revision
      }
    } catch { errorMessage = error.localizedDescription }
  }

  private var visibleSurfaces: [Surface] {
    (Array(desktop.values) + (windowed.map { [$0] } ?? [])).filter {
      $0.window.isVisible && !$0.window.isMiniaturized
        && $0.window.occlusionState.contains(.visible)
    }
  }

  private func renderAll(at date: Date, includingOccluded: Bool = false) {
    guard policy.screensAwake, policy.sessionActive else { return }
    let surfaces =
      includingOccluded ? Array(desktop.values) + (windowed.map { [$0] } ?? []) : visibleSurfaces
    guard !surfaces.isEmpty else { return }
    let began = CACurrentMediaTime()
    defer {
      let cost = max(0.000001, CACurrentMediaTime() - began)
      policy.renderCost = policy.renderCost == 0 ? cost : policy.renderCost * 0.8 + cost * 0.2
      updateTimer()
    }
    for surface in surfaces {
      let elapsed = max(0, date.timeIntervalSince(surface.tank.presentationEpoch))
      surface.renderer.draw(at: elapsed)
    }
  }

  private func updateTimer() {
    let rate = started && !visibleSurfaces.isEmpty ? policy.framesPerSecond : 0
    if rate == timerRate { return }
    timer?.invalidate()
    timer = nil
    timerRate = rate
    isAnimating = rate > 0
    guard rate > 0 else { return }
    timer = Timer(timeInterval: 1 / Double(rate), repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.renderAll(at: self.clock())
      }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, windowed?.window === window else { return }
    renderAll(at: clock(), includingOccluded: true)
  }
  @objc private func screenChanged() {
    lastReducedFrameRevision = nil
    reconcile()
  }
  @objc private func visibilityChanged() { if !reconciling { updateTimer() } }
  @objc private func powerChanged() {
    policy.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    policy.reduceMotion = reducedMotion()
    lastReducedFrameRevision = nil
    reconcile()
  }
  @objc private func screensSleep() {
    policy.screensAwake = false
    updateTimer()
  }
  @objc private func screensWake() {
    policy.screensAwake = true
    lastReducedFrameRevision = nil
    reconcile()
  }
  @objc private func sessionInactive() {
    policy.sessionActive = false
    updateTimer()
  }
  @objc private func sessionActive() {
    policy.sessionActive = true
    lastReducedFrameRevision = nil
    reconcile()
  }
}
