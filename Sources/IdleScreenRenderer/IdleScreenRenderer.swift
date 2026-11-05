import CoreGraphics
import CoreText
import Foundation
import Metal
import MetalKit
import OSLog
import QuartzCore
import simd

/// Camera-independent settings shared by the companion preview and screen saver.
public struct IdleScreenRendererConfiguration: Equatable, Sendable {
  public var glyphScale: Double
  public var contrast: Double
  public var palette: String
  public var patternRawValue: String
  public var cameraIsMirrored: Bool
  public var proceduralSettings: IdleScreenProceduralPatternSettings
  public var viewport: IdleScreenRendererViewport
  public var sceneSeed: UInt64
  public var sceneBrightness: Double
  public var aquariumSettings: IdleScreenAquariumRenderSettings?
  public var pixelMaterialsSettings: IdleScreenPixelMaterialsRendererSettings
  /// Agent sprites drawn into the scene, at most two. Empty leaves the
  /// rendered output untouched.
  public var agentSprites: [IdleScreenAgentSprite]
  /// Composition layer over a procedural pattern, including Topograph.
  public var framing: IdleScreenRendererFraming

  public init(
    glyphScale: Double,
    contrast: Double,
    palette: String,
    patternRawValue: String = "autoCycle",
    cameraIsMirrored: Bool = true,
    proceduralSettings: IdleScreenProceduralPatternSettings = .default,
    viewport: IdleScreenRendererViewport = .full,
    sceneSeed: UInt64 = 0,
    sceneBrightness: Double = 1,
    pixelMaterialsSettings: IdleScreenPixelMaterialsRendererSettings = .init(),
    agentSprites: [IdleScreenAgentSprite] = [],
    framing: IdleScreenRendererFraming = .none,
    aquariumSettings: IdleScreenAquariumRenderSettings? = nil
  ) {
    self.glyphScale = glyphScale
    self.contrast = contrast
    self.palette = palette
    self.patternRawValue = patternRawValue
    self.cameraIsMirrored = cameraIsMirrored
    self.proceduralSettings = proceduralSettings
    self.viewport = viewport
    self.sceneSeed = sceneSeed
    self.sceneBrightness =
      sceneBrightness.isFinite
      ? min(1, max(0, sceneBrightness))
      : 1
    self.pixelMaterialsSettings = pixelMaterialsSettings
    self.agentSprites = Array(
      agentSprites.prefix(IdleScreenAgentSprite.maximumCount)
    )
    self.framing = framing
    self.aquariumSettings = aquariumSettings
  }

  public static let `default` = IdleScreenRendererConfiguration(
    glyphScale: 0.38,
    contrast: 0.58,
    palette: "Cobalt",
    patternRawValue: "autoCycle",
    cameraIsMirrored: true,
    proceduralSettings: .default
  )
}

/// The visual source selected by a renderer host.
///
/// Camera deliberately falls back to the procedural field when no accepted
/// camera frame is present. That keeps failure truthful: a missing camera
/// never masquerades as a frozen or synthetic camera image.
public enum IdleScreenRendererMode: Equatable, Sendable {
  case generative
  case camera
}

/// A bounded, renderer-owned luminance and RGB snapshot sampled synchronously
/// from a BGRA mailbox frame.
///
/// Only this value may cross the mailbox callback boundary. It owns its bytes,
/// is capped at a small fixed size, and never retains the mailbox pointer.
public struct IdleScreenRendererCameraFrame: Equatable, Sendable {
  /// Shared production sampling grid used by every renderer host. Keeping
  /// this independent from any diagnostic glyph grid makes Studio and the
  /// installed screen saver consume the same camera framing and detail.
  public static let productionColumns = 160
  public static let productionRows = 90

  public static let maximumColumns = 192
  public static let maximumRows = 108
  public static let maximumSampleCount = maximumColumns * maximumRows

  public let producerStreamEpoch: UInt64
  public let sequence: UInt64
  public let columns: Int
  public let rows: Int
  public let luminance: [UInt8]
  public let interleavedRGB: [UInt8]
  public let checksum: UInt64

  public var sampledPixelCount: Int { luminance.count }

  private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
  private static let fnvPrime: UInt64 = 1_099_511_628_211

  /// Samples and copies a validated BGRA frame while `pixels` is in scope.
  /// Invalid dimensions or storage return `nil` without retaining anything.
  public static func samplingBGRA(
    producerStreamEpoch: UInt64,
    sequence: UInt64,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    pixels: UnsafeRawBufferPointer,
    columns requestedColumns: Int,
    rows requestedRows: Int
  ) -> Self? {
    guard producerStreamEpoch > 0,
      sequence > 0,
      width > 0,
      height > 0,
      width <= Int.max / 4,
      bytesPerRow >= width * 4,
      requestedColumns > 0,
      requestedRows > 0,
      height <= Int.max / bytesPerRow,
      pixels.count >= bytesPerRow * height
    else {
      return nil
    }

    let columns = min(requestedColumns, maximumColumns)
    let rows = min(requestedRows, maximumRows)
    guard columns <= Int.max / rows else { return nil }

    var luminance = [UInt8]()
    luminance.reserveCapacity(columns * rows)
    var interleavedRGB = [UInt8]()
    interleavedRGB.reserveCapacity(columns * rows * 3)
    var checksum = fnvOffsetBasis

    for row in 0..<rows {
      let sourceY = sampleCoordinate(
        row,
        targetCount: rows,
        sourceCount: height
      )
      for column in 0..<columns {
        let sourceX = sampleCoordinate(
          column,
          targetCount: columns,
          sourceCount: width
        )
        let offset = sourceY * bytesPerRow + sourceX * 4
        let blue = pixels[offset]
        let green = pixels[offset + 1]
        let red = pixels[offset + 2]
        let alpha = pixels[offset + 3]

        checksum = updateChecksum(checksum, byte: blue)
        checksum = updateChecksum(checksum, byte: green)
        checksum = updateChecksum(checksum, byte: red)
        checksum = updateChecksum(checksum, byte: alpha)

        let value =
          (29 * Int(blue)
            + 150 * Int(green)
            + 77 * Int(red)) >> 8
        luminance.append(UInt8(clamping: value))
        interleavedRGB.append(red)
        interleavedRGB.append(green)
        interleavedRGB.append(blue)
      }
    }

    return Self(
      producerStreamEpoch: producerStreamEpoch,
      sequence: sequence,
      columns: columns,
      rows: rows,
      luminance: luminance,
      interleavedRGB: interleavedRGB,
      checksum: checksum
    )
  }

  private init(
    producerStreamEpoch: UInt64,
    sequence: UInt64,
    columns: Int,
    rows: Int,
    luminance: [UInt8],
    interleavedRGB: [UInt8],
    checksum: UInt64
  ) {
    self.producerStreamEpoch = producerStreamEpoch
    self.sequence = sequence
    self.columns = columns
    self.rows = rows
    self.luminance = luminance
    self.interleavedRGB = interleavedRGB
    self.checksum = checksum
  }

  private static func updateChecksum(
    _ checksum: UInt64,
    byte: UInt8
  ) -> UInt64 {
    (checksum ^ UInt64(byte)) &* fnvPrime
  }

  /// Computes `index * sourceCount / targetCount` without an intermediate
  /// multiplication that could overflow for adversarial public inputs.
  private static func sampleCoordinate(
    _ index: Int,
    targetCount: Int,
    sourceCount: Int
  ) -> Int {
    let quotient = sourceCount / targetCount
    let remainder = sourceCount % targetCount
    return index * quotient + index * remainder / targetCount
  }
}

public enum IdleScreenRendererError: Error, Equatable {
  case metalUnavailable
  case commandQueueUnavailable
  case shaderLibraryUnavailable(String)
  case shaderFunctionUnavailable(String)
  case renderPipelineUnavailable(String)
  case characterAtlasUnavailable
}

public struct IdleScreenPixelMaterialsRendererDebugState: Equatable, Sendable {
  public let usesComputePipeline: Bool
  public let worldCellCount: Int
  public let allocatedCellCapacity: Int
  public let tick: UInt64
}

public enum IdleScreenRendererFrameDropReason: String, Codable, CaseIterable,
  Equatable, Sendable
{
  case inFlightSaturated
  case instanceBufferUnavailable
  case renderResourcesUnavailable
  case encodingFailed
}

/// Privacy-minimal timing emitted only when a host supplies an observer.
/// Events never contain configuration, glyph, camera, or material contents.
public enum IdleScreenRendererPerformanceEvent: Equatable, Sendable {
  case submitted(frameID: UInt64, cpuDurationMilliseconds: Double)
  case completed(frameID: UInt64, gpuDurationMilliseconds: Double)
  case dropped(frameID: UInt64, reason: IdleScreenRendererFrameDropReason)

  public var frameID: UInt64 {
    switch self {
    case .submitted(let frameID, _),
      .completed(let frameID, _),
      .dropped(let frameID, _):
      frameID
    }
  }
}

public protocol IdleScreenRendererPerformanceObserving: AnyObject, Sendable {
  func rendererDidRecordPerformance(
    _ event: IdleScreenRendererPerformanceEvent
  )
}

public struct IdleScreenProceduralRendererDebugState: Equatable, Sendable {
  public let usesComputePipeline: Bool
  public let instanceCount: Int

  public init(usesComputePipeline: Bool, instanceCount: Int) {
    self.usesComputePipeline = usesComputePipeline
    self.instanceCount = instanceCount
  }
}

/// A small production Metal renderer recovered from the legacy renderer.
///
/// A host supplies an `MTKView`; the renderer configures the view and drives
/// its normal `MTKViewDelegate` callbacks. Camera input is a bounded owned
/// luminance snapshot, so both the companion and saver use this exact path
/// without allowing mailbox memory to escape its scoped read.
@MainActor
public final class IdleScreenRenderer: NSObject, MTKViewDelegate {
  /// Departure Mono ramp. The Menlo fallback keeps the legacy ramp at the
  /// same length so glyph indices mean the same thing for either face.
  private static let glyphRamp = Array(" .,:;+*#%@")
  private static let maximumInFlightFrameCount = 3
  private static let logger = Logger(
    subsystem: "com.idlescreen.renderer",
    category: "Metal"
  )
  private static let performanceSignposter = OSSignposter(
    subsystem: "com.idlescreen.renderer",
    category: "Performance"
  )

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipelineState: MTLRenderPipelineState
  private let cameraComputePipelineState: MTLComputePipelineState?
  private let proceduralComputePipelineState: MTLComputePipelineState?
  private let aquariumComputePipelineState: MTLComputePipelineState?
  private let pixelMaterialsComputePipelineState: MTLComputePipelineState?
  private let agentSpriteComputePipelineState: MTLComputePipelineState?
  private let spriteQuadPipelineState: MTLRenderPipelineState?
  private let pixelMaterialsCoordinator: IdleScreenPixelMaterialsSceneCoordinator
  private let performanceObserver: (any IdleScreenRendererPerformanceObserving)?
  private let atlas: CharacterAtlas
  private let startedAt = CACurrentMediaTime()

  private weak var metalView: MTKView?
  private var configuration: IdleScreenRendererConfiguration
  private var mode: IdleScreenRendererMode
  private var cameraFrame: IdleScreenRendererCameraFrame?
  /// Reference clock for agent sprite poses. Nil means the wall clock; tests
  /// and offscreen captures pin it for deterministic frames.
  var agentSpriteReferenceDate: Date?
  /// Test seam: fill the glyph grid on the CPU even when the GPU procedural
  /// kernel is available, so the CPU sprite path can be compared end to end.
  var forcesCPUGlyphFill = false
  private var spriteClock = AgentSpriteClock()
  /// The grid and sprite layer of the most recent frame, for tests.
  private(set) var lastSpriteFrame: (columns: Int, rows: Int, layer: AgentSpriteLayer)?
  private var agentSpriteBuffers = [MTLBuffer?](
    repeating: nil,
    count: maximumInFlightFrameCount
  )
  private var spriteQuadBuffers = [MTLBuffer?](
    repeating: nil,
    count: maximumInFlightFrameCount
  )
  private var instanceBuffers = [MTLBuffer?](
    repeating: nil,
    count: maximumInFlightFrameCount
  )
  private var aquariumPixelBuffers = [MTLBuffer?](repeating: nil, count: maximumInFlightFrameCount)
  private var aquariumPixelCapacities = [Int](repeating: 0, count: maximumInFlightFrameCount)
  private var instanceCapacities = [Int](
    repeating: 0,
    count: maximumInFlightFrameCount
  )
  private var cameraLuminanceBuffers = [MTLBuffer?](
    repeating: nil,
    count: maximumInFlightFrameCount
  )
  private var cameraRGBBuffers = [MTLBuffer?](
    repeating: nil,
    count: maximumInFlightFrameCount
  )
  private var cameraInputCapacities = [Int](
    repeating: 0,
    count: maximumInFlightFrameCount
  )
  private var pixelMaterialsStateBuffers = [MTLBuffer?](
    repeating: nil,
    count: maximumInFlightFrameCount
  )
  private var pixelMaterialsStateCapacities = [Int](
    repeating: 0,
    count: maximumInFlightFrameCount
  )
  private var pixelMaterialsSceneToken: IdleScreenPixelMaterialsSceneToken?
  private let inFlightSemaphore = DispatchSemaphore(
    value: maximumInFlightFrameCount
  )
  private let instanceBufferSemaphores = (0..<maximumInFlightFrameCount).map {
    _ in DispatchSemaphore(value: 1)
  }
  private var nextInstanceBufferIndex = 0
  private var requestedElapsedTime: TimeInterval?
  private var didSubmitRequestedFrame = false
  private var didReportCameraComputeFailure = false
  private var nextPerformanceFrameID: UInt64 = 1
  private var isShutdown = false
  public private(set) var pixelMaterialsDebugState: IdleScreenPixelMaterialsRendererDebugState?
  public private(set) var proceduralDebugState: IdleScreenProceduralRendererDebugState?

  public init(
    metalView: MTKView,
    configuration: IdleScreenRendererConfiguration = .default,
    mode: IdleScreenRendererMode = .generative,
    automaticallyDraws: Bool = true,
    pixelMaterialsCoordinator: IdleScreenPixelMaterialsSceneCoordinator = .shared,
    performanceObserver:
      (any IdleScreenRendererPerformanceObserving)? = nil
  ) throws {
    guard let device = metalView.device ?? MTLCreateSystemDefaultDevice() else {
      throw IdleScreenRendererError.metalUnavailable
    }
    guard let commandQueue = device.makeCommandQueue() else {
      throw IdleScreenRendererError.commandQueueUnavailable
    }

    let library: MTLLibrary
    do {
      library = try device.makeDefaultLibrary(
        bundle: Bundle(for: IdleScreenRenderer.self)
      )
    } catch {
      throw IdleScreenRendererError.shaderLibraryUnavailable(
        error.localizedDescription
      )
    }
    guard
      let vertexFunction = library.makeFunction(
        name: "idleScreenCharacterVertex"
      )
    else {
      throw IdleScreenRendererError.shaderFunctionUnavailable(
        "idleScreenCharacterVertex"
      )
    }
    guard
      let fragmentFunction = library.makeFunction(
        name: "idleScreenCharacterFragment"
      )
    else {
      throw IdleScreenRendererError.shaderFunctionUnavailable(
        "idleScreenCharacterFragment"
      )
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "IdleScreen procedural glyph pipeline"
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor =
      .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor =
      .oneMinusSourceAlpha

    do {
      pipelineState = try device.makeRenderPipelineState(
        descriptor: descriptor
      )
    } catch {
      throw IdleScreenRendererError.renderPipelineUnavailable(
        error.localizedDescription
      )
    }

    if let spriteVertex = library.makeFunction(name: "idleScreenSpriteVertex"),
      let spriteFragment = library.makeFunction(name: "idleScreenSpriteFragment")
    {
      let spriteDescriptor = MTLRenderPipelineDescriptor()
      spriteDescriptor.label = "IdleScreen sprite lattice pipeline"
      spriteDescriptor.vertexFunction = spriteVertex
      spriteDescriptor.fragmentFunction = spriteFragment
      spriteDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      do {
        spriteQuadPipelineState = try device.makeRenderPipelineState(
          descriptor: spriteDescriptor
        )
      } catch {
        spriteQuadPipelineState = nil
        Self.logger.error(
          "Sprite lattice pipeline unavailable: \(error.localizedDescription, privacy: .public)"
        )
      }
    } else {
      spriteQuadPipelineState = nil
      Self.logger.error("Sprite lattice shader functions are missing")
    }

    if let cameraFunction = library.makeFunction(
      name: "idleScreenCameraInstances"
    ) {
      do {
        cameraComputePipelineState = try device.makeComputePipelineState(
          function: cameraFunction
        )
      } catch {
        cameraComputePipelineState = nil
        Self.logger.error(
          "Camera compute pipeline unavailable: \(error.localizedDescription, privacy: .public)"
        )
      }
    } else {
      cameraComputePipelineState = nil
      Self.logger.error(
        "Camera compute function idleScreenCameraInstances is missing"
      )
    }

    if let proceduralFunction = library.makeFunction(
      name: "idleScreenProceduralInstances"
    ) {
      do {
        proceduralComputePipelineState =
          try device
          .makeComputePipelineState(function: proceduralFunction)
      } catch {
        proceduralComputePipelineState = nil
        Self.logger.error(
          "Procedural compute pipeline unavailable: \(error.localizedDescription, privacy: .public)"
        )
      }
    } else {
      proceduralComputePipelineState = nil
      Self.logger.error(
        "Procedural compute function idleScreenProceduralInstances is missing"
      )
    }

    aquariumComputePipelineState = library.makeFunction(name: "idleScreenAquariumInstances").flatMap
    {
      try? device.makeComputePipelineState(function: $0)
    }

    if let materialsFunction = library.makeFunction(
      name: "idleScreenPixelMaterialInstances"
    ) {
      do {
        pixelMaterialsComputePipelineState =
          try device
          .makeComputePipelineState(function: materialsFunction)
      } catch {
        pixelMaterialsComputePipelineState = nil
        Self.logger.error(
          "Pixel Materials compute pipeline unavailable: \(error.localizedDescription, privacy: .public)"
        )
      }
    } else {
      pixelMaterialsComputePipelineState = nil
      Self.logger.error(
        "Pixel Materials compute function idleScreenPixelMaterialInstances is missing"
      )
    }

    if let spriteFunction = library.makeFunction(
      name: "idleScreenAgentSpriteOverrides"
    ) {
      do {
        agentSpriteComputePipelineState =
          try device
          .makeComputePipelineState(function: spriteFunction)
      } catch {
        agentSpriteComputePipelineState = nil
        Self.logger.error(
          "Agent sprite compute pipeline unavailable: \(error.localizedDescription, privacy: .public)"
        )
      }
    } else {
      agentSpriteComputePipelineState = nil
      Self.logger.error(
        "Agent sprite compute function idleScreenAgentSpriteOverrides is missing"
      )
    }

    guard
      let atlas = CharacterAtlas(
        device: device,
        glyphCount: Self.glyphRamp.count
      )
    else {
      throw IdleScreenRendererError.characterAtlasUnavailable
    }

    self.device = device
    self.commandQueue = commandQueue
    self.atlas = atlas
    self.pixelMaterialsCoordinator = pixelMaterialsCoordinator
    self.performanceObserver = performanceObserver
    self.configuration = configuration.normalized
    self.mode = mode
    self.metalView = metalView
    super.init()

    metalView.device = device
    metalView.colorPixelFormat = .bgra8Unorm
    metalView.depthStencilPixelFormat = .invalid
    metalView.framebufferOnly = true
    metalView.preferredFramesPerSecond = 30
    metalView.enableSetNeedsDisplay = false
    metalView.isPaused = !automaticallyDraws
    metalView.clearColor = self.configuration.paletteColors.clearColor
    metalView.delegate = self
  }

  deinit {
    guard let pixelMaterialsSceneToken else { return }
    MainActor.assumeIsolated {
      pixelMaterialsCoordinator.detach(pixelMaterialsSceneToken)
    }
  }

  public func update(configuration: IdleScreenRendererConfiguration) {
    guard !isShutdown else { return }
    if self.configuration.patternRawValue == "pixelMaterials",
      configuration.patternRawValue != "pixelMaterials"
        || self.configuration.effectivePixelMaterialsSettings
          != configuration.effectivePixelMaterialsSettings
        || self.configuration.viewport.normalized
          != configuration.viewport.normalized
    {
      releasePixelMaterialsScene()
    }
    self.configuration = configuration.normalized
    metalView?.clearColor = self.configuration.paletteColors.clearColor
  }

  public func update(mode: IdleScreenRendererMode) {
    guard !isShutdown else { return }
    self.mode = mode
  }

  /// Accepts a new producer epoch or a strictly newer frame in the current
  /// epoch. Producer epochs are random process identities, not counters.
  public func submit(cameraFrame newFrame: IdleScreenRendererCameraFrame) {
    guard !isShutdown else { return }
    if let cameraFrame {
      guard
        newFrame.producerStreamEpoch != cameraFrame.producerStreamEpoch
          || newFrame.sequence > cameraFrame.sequence
      else {
        return
      }
    }
    cameraFrame = newFrame
  }

  public func clearCameraFrame() {
    cameraFrame = nil
  }

  /// Synchronously detaches the renderer from its host view and prevents any
  /// further submissions. In-flight Metal commands retain their own resource
  /// references and signal completion asynchronously; the main actor never
  /// waits for GPU work during teardown.
  public func shutdown() {
    guard !isShutdown else { return }
    isShutdown = true
    cameraFrame = nil
    requestedElapsedTime = nil
    if let metalView {
      metalView.isPaused = true
      if metalView.delegate === self {
        metalView.delegate = nil
      }
    }
    metalView = nil
    instanceBuffers = Array(
      repeating: nil,
      count: Self.maximumInFlightFrameCount
    )
    instanceCapacities = Array(
      repeating: 0,
      count: Self.maximumInFlightFrameCount
    )
    cameraLuminanceBuffers = Array(
      repeating: nil,
      count: Self.maximumInFlightFrameCount
    )
    cameraRGBBuffers = Array(
      repeating: nil,
      count: Self.maximumInFlightFrameCount
    )
    cameraInputCapacities = Array(
      repeating: 0,
      count: Self.maximumInFlightFrameCount
    )
    releasePixelMaterialsScene()
    pixelMaterialsStateBuffers = Array(
      repeating: nil,
      count: Self.maximumInFlightFrameCount
    )
    pixelMaterialsStateCapacities = Array(
      repeating: 0,
      count: Self.maximumInFlightFrameCount
    )
    proceduralDebugState = nil
    if configuration.patternRawValue == "aquarium" { IdleScreenAquariumFrameCache.shared.clear() }
    aquariumPixelBuffers = .init(repeating: nil, count: Self.maximumInFlightFrameCount)
    aquariumPixelCapacities = .init(repeating: 0, count: Self.maximumInFlightFrameCount)
  }

  /// Draw one frame using a host-owned lifecycle clock.
  ///
  /// ScreenSaverView already supplies its own animation callback, so its host
  /// creates the renderer with `automaticallyDraws: false` and calls this
  /// method from `animateOneFrame()`.
  @discardableResult
  public func draw(at elapsedTime: TimeInterval) -> Bool {
    guard !isShutdown, let metalView else { return false }
    requestedElapsedTime = elapsedTime.isFinite ? max(0, elapsedTime) : 0
    didSubmitRequestedFrame = false
    metalView.draw()
    return didSubmitRequestedFrame
  }

  /// Present rate the current scene needs. Hosts apply it to their display
  /// link or animation timer; camera frames always run at 30.
  public func preferredFramesPerSecond(at elapsedTime: TimeInterval) -> Int {
    if mode == .camera, cameraFrame != nil { return 30 }
    let patternRate = IdleScreenProceduralPatterns.framesPerSecond(
      patternRawValue: configuration.patternRawValue,
      at: elapsedTime,
      autoCycleInterval: configuration.proceduralSettings.normalized
        .autoCycleInterval
    )
    guard !configuration.agentSprites.isEmpty else { return patternRate }
    let now = agentSpriteReferenceDate ?? Date()
    let sprites = resolvedAgentSprites(now: now)
    guard sprites.contains(where: { $0.isAnimating(at: now) }) else { return patternRate }
    return max(patternRate, IdleScreenAgentSprite.animatingFramesPerSecond)
  }

  /// The configured sprites with their pose clocks started at first sight. A
  /// pinned reference date (tests, offscreen captures) is used as given.
  private func resolvedAgentSprites(now: Date) -> [IdleScreenAgentSprite] {
    guard agentSpriteReferenceDate == nil else { return configuration.agentSprites }
    return spriteClock.resolve(configuration.agentSprites, now: now)
  }

  public func mtkView(
    _ view: MTKView,
    drawableSizeWillChange size: CGSize
  ) {
    // Instance storage is rebuilt only after acquiring a free ring slot in
    // draw(in:), never while a GPU command may still read that slot.
  }

  public func draw(in view: MTKView) {
    let signpostState = Self.performanceSignposter.beginInterval(
      "RendererFrame"
    )
    defer {
      Self.performanceSignposter.endInterval(
        "RendererFrame",
        signpostState
      )
    }
    let frameID = nextPerformanceFrameID
    nextPerformanceFrameID &+= 1
    if nextPerformanceFrameID == 0 { nextPerformanceFrameID = 1 }
    let cpuStartedAt = CACurrentMediaTime()
    guard !isShutdown else { return }
    guard inFlightSemaphore.wait(timeout: .now()) == .success else {
      performanceObserver?.rendererDidRecordPerformance(
        .dropped(frameID: frameID, reason: .inFlightSaturated)
      )
      return
    }

    var submitted = false
    var acquiredBufferSemaphore: DispatchSemaphore?
    var dropReason = IdleScreenRendererFrameDropReason
      .renderResourcesUnavailable
    defer {
      if !submitted {
        acquiredBufferSemaphore?.signal()
        inFlightSemaphore.signal()
        performanceObserver?.rendererDidRecordPerformance(
          .dropped(frameID: frameID, reason: dropReason)
        )
      }
    }

    autoreleasepool {
      let automaticElapsed = CACurrentMediaTime() - startedAt
      let aquariumElapsed = IdleScreenAquariumFrameClock.resolve(
        explicit: requestedElapsedTime, automatic: automaticElapsed,
        settings: configuration.aquariumSettings, now: Date())
      let elapsed = Float(requestedElapsedTime ?? automaticElapsed)
      requestedElapsedTime = nil
      let framesPerSecond = preferredFramesPerSecond(
        at: TimeInterval(elapsed)
      )
      if view.preferredFramesPerSecond != framesPerSecond {
        view.preferredFramesPerSecond = framesPerSecond
      }
      guard let bufferIndex = acquireInstanceBufferIndex() else {
        dropReason = .instanceBufferUnavailable
        return
      }
      let bufferSemaphore = instanceBufferSemaphores[bufferIndex]
      acquiredBufferSemaphore = bufferSemaphore
      let prepared = prepareInstances(
        for: view.bounds.size,
        elapsed: elapsed,
        aquariumElapsed: aquariumElapsed,
        bufferIndex: bufferIndex
      )
      let grid = prepared.dimensions
      guard grid.count > 0,
        let instanceBuffer = instanceBuffers[bufferIndex],
        let drawable = view.currentDrawable,
        let renderPassDescriptor = view.currentRenderPassDescriptor,
        let commandBuffer = commandQueue.makeCommandBuffer()
      else {
        return
      }
      if let cameraInput = prepared.cameraInput,
        !encodeCameraInstances(
          cameraInput,
          grid: grid,
          bufferIndex: bufferIndex,
          instanceBuffer: instanceBuffer,
          commandBuffer: commandBuffer
        )
      {
        dropReason = .encodingFailed
        return
      }
      if let materialsInput = prepared.pixelMaterialsInput,
        !encodePixelMaterialInstances(
          materialsInput,
          grid: grid,
          bufferIndex: bufferIndex,
          instanceBuffer: instanceBuffer,
          commandBuffer: commandBuffer
        )
      {
        dropReason = .encodingFailed
        return
      }
      if let input = prepared.aquariumInput,
        !encodeAquariumInstances(
          input, grid: grid, bufferIndex: bufferIndex,
          instanceBuffer: instanceBuffer, commandBuffer: commandBuffer)
      {
        dropReason = .encodingFailed
        return
      }
      if prepared.usesProceduralCompute,
        !encodeProceduralInstances(
          grid: grid,
          elapsed: elapsed,
          instanceBuffer: instanceBuffer,
          commandBuffer: commandBuffer
        )
      {
        dropReason = .encodingFailed
        return
      }
      let framingActive =
        configuration.framing == .horizon
        && prepared.cameraInput == nil && prepared.pixelMaterialsInput == nil
      let overlay = sceneOverlay(
        for: prepared,
        viewSize: view.bounds.size,
        framingActive: framingActive
      )
      let spriteOverrides = overlay.layer.halo
      var usesSpriteBuffer = false
      if !spriteOverrides.isEmpty {
        if prepared.populatesOnGPU {
          if agentSpriteComputePipelineState != nil {
            guard
              encodeAgentSpriteOverrides(
                spriteOverrides,
                bufferIndex: bufferIndex,
                instanceBuffer: instanceBuffer,
                commandBuffer: commandBuffer
              )
            else {
              dropReason = .encodingFailed
              return
            }
            usesSpriteBuffer = true
          }
        } else {
          applyAgentSpriteOverridesOnCPU(
            spriteOverrides,
            grid: grid,
            instanceBuffer: instanceBuffer
          )
        }
      }
      guard
        let encoder = commandBuffer.makeRenderCommandEncoder(
          descriptor: renderPassDescriptor
        )
      else {
        dropReason = .encodingFailed
        return
      }

      var geometry = SIMD4<Float>(
        Float(grid.columns),
        Float(grid.rows),
        1 / Float(grid.columns),
        1 / Float(grid.rows)
      )

      encoder.label = "IdleScreen procedural glyph frame"
      encoder.setRenderPipelineState(pipelineState)
      encoder.setVertexBytes(
        &geometry,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 0
      )
      encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
      encoder.setVertexBuffer(atlas.glyphBuffer, offset: 0, index: 2)
      encoder.setFragmentTexture(atlas.texture, index: 0)
      encoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: 6,
        instanceCount: grid.count
      )
      let usesQuadBuffer = encodeSpriteQuads(
        overlay.quads,
        bufferIndex: bufferIndex,
        viewSize: view.bounds.size,
        encoder: encoder
      )
      encoder.endEncoding()
      commandBuffer.present(drawable)
      let inFlightSemaphore = self.inFlightSemaphore
      var retainedBuffers: [any MTLBuffer] = [instanceBuffer]
      if prepared.cameraInput != nil,
        let luminanceBuffer = cameraLuminanceBuffers[bufferIndex],
        let rgbBuffer = cameraRGBBuffers[bufferIndex]
      {
        retainedBuffers.append(luminanceBuffer)
        retainedBuffers.append(rgbBuffer)
      }
      if prepared.pixelMaterialsInput != nil,
        let stateBuffer = pixelMaterialsStateBuffers[bufferIndex]
      {
        retainedBuffers.append(stateBuffer)
      }
      if usesSpriteBuffer,
        let spriteBuffer = agentSpriteBuffers[bufferIndex]
      {
        retainedBuffers.append(spriteBuffer)
      }
      if usesQuadBuffer,
        let quadBuffer = spriteQuadBuffers[bufferIndex]
      {
        retainedBuffers.append(quadBuffer)
      }
      if prepared.aquariumInput != nil, let pixels = aquariumPixelBuffers[bufferIndex] {
        retainedBuffers.append(pixels)
      }
      let bufferRetention = InFlightBufferRetention(retainedBuffers)
      let performanceObserver = self.performanceObserver
      commandBuffer.addCompletedHandler { completedBuffer in
        // Retain the exact ring resource until the GPU is finished,
        // even if the host calls shutdown and releases the renderer.
        withExtendedLifetime(bufferRetention) {}
        let gpuDurationMilliseconds = max(
          0,
          (completedBuffer.gpuEndTime - completedBuffer.gpuStartTime)
            * 1_000
        )
        performanceObserver?.rendererDidRecordPerformance(
          .completed(
            frameID: frameID,
            gpuDurationMilliseconds: gpuDurationMilliseconds
          )
        )
        bufferSemaphore.signal()
        inFlightSemaphore.signal()
      }
      commandBuffer.commit()
      submitted = true
      didSubmitRequestedFrame = true
      performanceObserver?.rendererDidRecordPerformance(
        .submitted(
          frameID: frameID,
          cpuDurationMilliseconds: max(
            0,
            (CACurrentMediaTime() - cpuStartedAt) * 1_000
          )
        )
      )
    }
  }

  /// What the scene draws on top of the glyph grid this frame: the sprite
  /// layer, plus the horizon line when the scene is framed. Camera mode parks
  /// the sprites off-centre so they stay clear of the face. Sprites stand on
  /// the horizon when there is one in view, on the bottom edge otherwise.
  private func sceneOverlay(
    for prepared: PreparedGrid,
    viewSize: CGSize,
    framingActive: Bool
  ) -> (layer: AgentSpriteLayer, quads: [AgentSpriteQuad]) {
    let columns = prepared.dimensions.columns
    let rows = prepared.dimensions.rows
    guard columns > 0, rows > 0, viewSize.width > 0, viewSize.height > 0 else {
      return (AgentSpriteLayer(), [])
    }
    let colors = configuration.paletteColors
    var horizonRow: Double?
    if framingActive {
      let row = Double(
        IdleScreenSceneFramingMask.horizonRow(
          viewport: configuration.viewport,
          columns: columns,
          rows: rows
        ))
      if row > 0, row <= Double(rows) { horizonRow = row }
    }
    var layer = AgentSpriteLayer()
    if !configuration.agentSprites.isEmpty {
      let now = agentSpriteReferenceDate ?? Date()
      layer = AgentSpriteLayout.layer(
        sprites: resolvedAgentSprites(now: now),
        now: now,
        columns: columns,
        rows: rows,
        viewSize: (Double(viewSize.width), Double(viewSize.height)),
        groundRow: horizonRow ?? Double(rows),
        parkFraction: prepared.cameraInput == nil
          ? AgentSpriteLayout.centerParkFraction
          : AgentSpriteLayout.cameraParkFraction,
        seed: configuration.sceneSeed,
        viewport: configuration.viewport,
        sceneBrightness: configuration.sceneBrightness,
        background: colors.background
      )
      lastSpriteFrame = (columns, rows, layer)
    }
    var quads: [AgentSpriteQuad] = []
    if let horizonRow {
      // The line is the one thing drawn at the horizon, a point thick, under
      // the sprites' feet. Palettes without an accent draw it in foreground.
      let y = Float(horizonRow * Double(viewSize.height) / Double(rows))
      let level = Float(configuration.sceneBrightness) * Self.horizonLineLevel
      let background = colors.background
      let line = background + (colors.accent - background) * level
      quads.append(
        AgentSpriteQuad(
          edges: SIMD4(0, y, Float(viewSize.width), y + 1),
          color: SIMD4(line, 1)
        ))
    }
    quads.append(contentsOf: layer.quads)
    return (layer, quads)
  }

  /// How far the horizon line sits from the background toward the accent.
  private static let horizonLineLevel: Float = 1.0

  private func encodeSpriteQuads(
    _ quads: [AgentSpriteQuad],
    bufferIndex: Int,
    viewSize: CGSize,
    encoder: any MTLRenderCommandEncoder
  ) -> Bool {
    guard !quads.isEmpty, let pipeline = spriteQuadPipelineState else { return false }
    let capacity = AgentSpriteLayout.hardCap + 1
    if spriteQuadBuffers[bufferIndex] == nil {
      spriteQuadBuffers[bufferIndex] = device.makeBuffer(
        length: capacity * MemoryLayout<AgentSpriteQuad>.stride,
        options: .storageModeShared
      )
    }
    guard let buffer = spriteQuadBuffers[bufferIndex] else { return false }
    let count = min(quads.count, capacity)
    quads.withUnsafeBytes { source in
      buffer.contents().copyMemory(
        from: source.baseAddress!,
        byteCount: count * MemoryLayout<AgentSpriteQuad>.stride
      )
    }
    var size = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
    encoder.drawPrimitives(
      type: .triangle,
      vertexStart: 0,
      vertexCount: 6,
      instanceCount: count
    )
    return true
  }

  private func encodeAgentSpriteOverrides(
    _ overrides: [AgentSpriteCellOverride],
    bufferIndex: Int,
    instanceBuffer: any MTLBuffer,
    commandBuffer: any MTLCommandBuffer
  ) -> Bool {
    guard let pipeline = agentSpriteComputePipelineState else { return false }
    let length =
      AgentSpriteLayout.hardCap
      * MemoryLayout<AgentSpriteCellOverride>.stride
    if agentSpriteBuffers[bufferIndex] == nil {
      agentSpriteBuffers[bufferIndex] = device.makeBuffer(
        length: length,
        options: .storageModeShared
      )
    }
    guard let spriteBuffer = agentSpriteBuffers[bufferIndex],
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else {
      return false
    }
    let count = min(overrides.count, AgentSpriteLayout.hardCap)
    overrides.withUnsafeBytes { source in
      spriteBuffer.contents().copyMemory(
        from: source.baseAddress!,
        byteCount: count * MemoryLayout<AgentSpriteCellOverride>.stride
      )
    }
    var limits = SIMD2<UInt32>(
      UInt32(count),
      UInt32(
        instanceBuffer.length
          / MemoryLayout<GlyphInstance>.stride))
    encoder.label = "IdleScreen agent sprite overrides"
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(instanceBuffer, offset: 0, index: 0)
    encoder.setBuffer(spriteBuffer, offset: 0, index: 1)
    encoder.setBytes(
      &limits,
      length: MemoryLayout<SIMD2<UInt32>>.stride,
      index: 2
    )
    let width = max(1, min(count, pipeline.threadExecutionWidth))
    encoder.dispatchThreadgroups(
      MTLSize(width: (count + width - 1) / width, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
    )
    encoder.endEncoding()
    return true
  }

  private func applyAgentSpriteOverridesOnCPU(
    _ overrides: [AgentSpriteCellOverride],
    grid: GridDimensions,
    instanceBuffer: any MTLBuffer
  ) {
    let instances = instanceBuffer.contents().bindMemory(
      to: GlyphInstance.self,
      capacity: grid.count
    )
    for override in overrides where Int(override.cell) < grid.count {
      let index = Int(override.cell)
      let current = instances[index]
      let result = override.applied(
        brightness: current.gridBrightnessGlyph.z,
        glyph: current.gridBrightnessGlyph.w,
        color: current.foreground
      )
      instances[index] = GlyphInstance(
        gridBrightnessGlyph: SIMD4<Float>(
          current.gridBrightnessGlyph.x,
          current.gridBrightnessGlyph.y,
          result.brightness,
          result.glyph
        ),
        foreground: result.color
      )
    }
  }

  private func encodeAquariumInstances(
    _ input: AquariumComputeInput, grid: GridDimensions,
    bufferIndex: Int, instanceBuffer: any MTLBuffer,
    commandBuffer: any MTLCommandBuffer
  ) -> Bool {
    guard let pipeline = aquariumComputePipelineState,
      let pixels = aquariumPixelBuffers[bufferIndex],
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else { return false }
    let viewport = configuration.viewport.normalized
    var uniforms = AquariumComputeUniforms(
      gridSize: .init(UInt32(grid.columns), UInt32(grid.rows)),
      worldSize: .init(UInt32(input.worldWidth), 216),
      viewport: .init(
        Float(viewport.x), Float(viewport.y), Float(viewport.width), Float(viewport.height)),
      contentRect: .init(
        Float(input.contentRect.minX), Float(input.contentRect.minY),
        Float(input.contentRect.width), Float(input.contentRect.height)),
      brightness: Float(configuration.sceneBrightness))
    encoder.label = "IdleScreen aquarium composition"
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(pixels, offset: 0, index: 0)
    encoder.setBuffer(instanceBuffer, offset: 0, index: 1)
    encoder.setBytes(&uniforms, length: MemoryLayout<AquariumComputeUniforms>.stride, index: 2)
    encoder.dispatchThreads(
      .init(width: grid.columns, height: grid.rows, depth: 1),
      threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
    encoder.endEncoding()
    return true
  }

  private func acquireInstanceBufferIndex() -> Int? {
    for offset in 0..<Self.maximumInFlightFrameCount {
      let index = (nextInstanceBufferIndex + offset) % Self.maximumInFlightFrameCount
      if instanceBufferSemaphores[index].wait(timeout: .now())
        == .success
      {
        nextInstanceBufferIndex = (index + 1) % Self.maximumInFlightFrameCount
        return index
      }
    }
    return nil
  }

  private func prepareInstances(
    for logicalSize: CGSize,
    elapsed: Float,
    aquariumElapsed: TimeInterval,
    bufferIndex: Int
  ) -> PreparedGrid {
    guard logicalSize.width >= 1, logicalSize.height >= 1 else {
      return .empty
    }

    let glyphPointSize = 8 + configuration.glyphScale * 12
    let cellWidth = max(
      4,
      glyphPointSize * IdleScreenProceduralPatterns.cellAspect
    )
    let cellHeight = max(6, glyphPointSize)
    let isAquarium = configuration.patternRawValue == "aquarium" && mode != .camera
    let aquariumFraming = IdleScreenAquariumFraming(
      logicalSize: logicalSize, viewport: configuration.viewport,
      worldWidth: configuration.aquariumSettings?.worldWidth ?? 384)
    let columns = isAquarium ? aquariumFraming.columns : max(1, Int(logicalSize.width / cellWidth))
    let rows = isAquarium ? aquariumFraming.rows : max(1, Int(logicalSize.height / cellHeight))
    let count = columns * rows

    if instanceBuffers[bufferIndex] == nil
      || instanceCapacities[bufferIndex] < count
    {
      instanceBuffers[bufferIndex] = device.makeBuffer(
        length: count * MemoryLayout<GlyphInstance>.stride,
        options: .storageModeShared
      )
      instanceCapacities[bufferIndex] =
        instanceBuffers[bufferIndex] == nil ? 0 : count
    }
    guard let instanceBuffer = instanceBuffers[bufferIndex] else {
      return .empty
    }

    let instances = instanceBuffer.contents().bindMemory(
      to: GlyphInstance.self,
      capacity: count
    )
    let configuration = self.configuration
    let contrast = Float(0.6 + configuration.contrast * 1.6)
    let paletteForeground = configuration.paletteColors.foregroundRGBA
    let activeCameraFrame: IdleScreenRendererCameraFrame?
    if mode == .camera,
      let cameraFrame,
      cameraFrame.columns > 0,
      cameraFrame.rows > 0,
      cameraFrame.luminance.count
        == cameraFrame.columns * cameraFrame.rows,
      cameraFrame.interleavedRGB.count
        == cameraFrame.luminance.count * 3
    {
      activeCameraFrame = cameraFrame
    } else {
      activeCameraFrame = nil
    }
    if let activeCameraFrame {
      guard cameraComputePipelineState != nil,
        prepareCameraInput(
          activeCameraFrame,
          bufferIndex: bufferIndex
        )
      else {
        reportCameraComputeFailureOnce(
          "Camera frame dropped because the GPU input path is unavailable"
        )
        return .empty
      }
      return PreparedGrid(
        dimensions: GridDimensions(columns: columns, rows: rows),
        cameraInput: CameraComputeInput(
          columns: activeCameraFrame.columns,
          rows: activeCameraFrame.rows
        ),
        pixelMaterialsInput: nil,
        usesProceduralCompute: false
      )
    }
    if configuration.patternRawValue == "aquarium", mode != .camera {
      proceduralDebugState = .init(usesComputePipeline: false, instanceCount: count)
      let pixels = IdleScreenAquariumFrameCache.shared.frame(
        at: aquariumElapsed * configuration.proceduralSettings.normalized.speed,
        seed: configuration.aquariumSettings?.seed ?? configuration.sceneSeed,
        settings: configuration.aquariumSettings
      )
      if aquariumComputePipelineState != nil, !forcesCPUGlyphFill {
        proceduralDebugState = .init(usesComputePipeline: true, instanceCount: count)
        let byteCount = pixels.count * MemoryLayout<SIMD4<Float>>.stride
        if aquariumPixelCapacities[bufferIndex] < byteCount {
          aquariumPixelBuffers[bufferIndex] = device.makeBuffer(
            length: byteCount, options: .storageModeShared)
          aquariumPixelCapacities[bufferIndex] =
            aquariumPixelBuffers[bufferIndex] == nil ? 0 : byteCount
        }
        guard let inputBuffer = aquariumPixelBuffers[bufferIndex] else { return .empty }
        pixels.withUnsafeBytes { bytes in
          if let address = bytes.baseAddress {
            memcpy(inputBuffer.contents(), address, bytes.count)
          }
        }
        return PreparedGrid(
          dimensions: GridDimensions(columns: columns, rows: rows), cameraInput: nil,
          pixelMaterialsInput: nil, usesProceduralCompute: false,
          aquariumInput: .init(
            worldWidth: min(1152, max(384, configuration.aquariumSettings?.worldWidth ?? 384)),
            contentRect: aquariumFraming.contentRect))
      }
      for row in 0..<rows {
        for column in 0..<columns {
          let coordinate = aquariumFraming.coordinate(
            u: (Double(column) + 0.5) / Double(columns),
            v: (Double(row) + 0.5) / Double(rows))
          let worldWidth = min(1152, max(384, configuration.aquariumSettings?.worldWidth ?? 384))
          var color =
            coordinate.map { pixels[$0.y * worldWidth + $0.x] }
            ?? SIMD4<Float>(0.035, 0.12, 0.19, 1)
          color *= Float(configuration.sceneBrightness)
          color.w = 1
          instances[row * columns + column] = GlyphInstance(
            gridBrightnessGlyph: SIMD4(Float(column), Float(row), 1, -1),
            foreground: color
          )
        }
      }
      return PreparedGrid(
        dimensions: GridDimensions(columns: columns, rows: rows),
        cameraInput: nil, pixelMaterialsInput: nil, usesProceduralCompute: false
      )
    }
    if configuration.patternRawValue == "pixelMaterials",
      let input = preparePixelMaterialsInput(
        elapsed: TimeInterval(elapsed),
        bufferIndex: bufferIndex
      )
    {
      return PreparedGrid(
        dimensions: GridDimensions(columns: columns, rows: rows),
        cameraInput: nil,
        pixelMaterialsInput: input,
        usesProceduralCompute: false
      )
    }
    if proceduralComputePipelineState != nil, !forcesCPUGlyphFill {
      proceduralDebugState = .init(
        usesComputePipeline: true,
        instanceCount: count
      )
      return PreparedGrid(
        dimensions: GridDimensions(columns: columns, rows: rows),
        cameraInput: nil,
        pixelMaterialsInput: nil,
        usesProceduralCompute: true
      )
    }
    proceduralDebugState = .init(
      usesComputePipeline: false,
      instanceCount: count
    )
    let framing = configuration.framing == .horizon
    let horizonRow = IdleScreenSceneFramingMask.horizonRow(
      viewport: configuration.viewport,
      columns: columns,
      rows: rows
    )
    let sceneOriginRow = configuration.viewport.coordinate(
      column: 0, row: 0, columns: columns, rows: rows
    ).row
    let paletteColors = configuration.paletteColors
    let accent = paletteColors.accentRGBA
    for row in 0..<rows {
      for column in 0..<columns {
        var brightness: Float
        var glyphIndex: Int?
        let proceduralSample = IdleScreenProceduralPatterns.cellSample(
          patternRawValue: configuration.patternRawValue,
          settings: configuration.proceduralSettings,
          column: column,
          row: row,
          columns: columns,
          rows: rows,
          glyphCount: Self.glyphRamp.count,
          time: TimeInterval(elapsed),
          viewport: configuration.viewport,
          sceneSeed: configuration.sceneSeed,
          sceneBrightness: 1
        )
        brightness = proceduralSample.brightness
        glyphIndex = proceduralSample.glyphIndex
        let sourceBrightness = brightness
        brightness = min(
          1,
          max(0, (brightness - 0.5) * contrast + 0.5)
        )
        if framing {
          let mask = IdleScreenSceneFramingMask.mask(
            row: row, horizonRow: horizonRow, originRow: sceneOriginRow)
          brightness *= mask
          // A glyph picked by brightness follows the mask; a shuffled glyph
          // (matrix rain) is left alone.
          if glyphIndex == Int(sourceBrightness * Float(Self.glyphRamp.count - 1)) {
            glyphIndex = min(
              Self.glyphRamp.count - 1,
              Int(sourceBrightness * mask * Float(Self.glyphRamp.count - 1))
            )
          }
        }
        var cellForeground = paletteForeground
        if accent.w > 0, IdleScreenSceneFramingMask.isAccent(brightness) {
          cellForeground = accent
        }
        brightness *= Float(configuration.sceneBrightness)
        let renderedGlyphIndex =
          glyphIndex
          ?? min(
            Self.glyphRamp.count - 1,
            Int(brightness * Float(Self.glyphRamp.count))
          )
        instances[row * columns + column] = GlyphInstance(
          gridBrightnessGlyph: SIMD4<Float>(
            Float(column),
            Float(row),
            brightness,
            Float(renderedGlyphIndex)
          ),
          foreground: cellForeground
        )
      }
    }

    return PreparedGrid(
      dimensions: GridDimensions(columns: columns, rows: rows),
      cameraInput: nil,
      pixelMaterialsInput: nil,
      usesProceduralCompute: false
    )
  }

  private func encodeProceduralInstances(
    grid: GridDimensions,
    elapsed: Float,
    instanceBuffer: any MTLBuffer,
    commandBuffer: any MTLCommandBuffer
  ) -> Bool {
    guard let pipeline = proceduralComputePipelineState,
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else {
      return false
    }
    let settings = configuration.proceduralSettings.normalized
    let origin = configuration.viewport.coordinate(
      column: 0,
      row: 0,
      columns: grid.columns,
      rows: grid.rows
    )
    let variation = IdleScreenSceneVariation(
      seed: configuration.sceneSeed
    )
    let patternRawValues = IdleScreenProceduralPatterns.patternRawValues
    let resolvedPattern: String
    let nextPattern: String
    let blend: Float
    if configuration.patternRawValue == "autoCycle" {
      let state = IdleScreenProceduralPatterns.autoCycleState(
        at: TimeInterval(elapsed),
        autoCycleInterval: settings.autoCycleInterval
      )
      resolvedPattern = state.current
      nextPattern = state.next
      blend = state.blend
    } else {
      resolvedPattern =
        IdleScreenProceduralPatterns
        .resolvedPatternRawValue(configuration.patternRawValue)
      nextPattern = resolvedPattern
      blend = 0
    }
    let patternIndex = UInt32(
      patternRawValues.firstIndex(of: resolvedPattern) ?? 0
    )
    let nextPatternIndex = UInt32(
      patternRawValues.firstIndex(of: nextPattern) ?? 0
    )
    var uniforms = ProceduralComputeUniforms(
      gridSize: SIMD2(UInt32(grid.columns), UInt32(grid.rows)),
      sceneSize: SIMD2(UInt32(origin.columns), UInt32(origin.rows)),
      sceneOrigin: SIMD2(UInt32(origin.column), UInt32(origin.row)),
      patternIndex: patternIndex,
      glyphCount: UInt32(Self.glyphRamp.count),
      timestamp: elapsed,
      contrast: Float(0.6 + configuration.contrast * 1.6),
      sceneBrightness: Float(configuration.sceneBrightness),
      speed: Float(settings.speed),
      scale: Float(settings.scale),
      intensity: Float(settings.intensity * settings.qualityLevel),
      trailing: Float(settings.trailing),
      matrixTrailLength: Float(settings.matrixTrailLength),
      rainbowAmplitude: Float(settings.rainbowAmplitude),
      fireDecay: Float(settings.fireDecay),
      nextPatternIndex: nextPatternIndex,
      blend: blend,
      foreground: configuration.paletteColors.foregroundRGBA,
      seedOffset: variation.offset,
      seedCenter: variation.center,
      sceneAspect: Float(
        Double(origin.columns) * IdleScreenProceduralPatterns.cellAspect
          / Double(origin.rows)
      ),
      horizonRow: IdleScreenSceneFramingMask.horizonRow(
        viewport: configuration.viewport,
        columns: grid.columns,
        rows: grid.rows
      ),
      framingEnabled: configuration.framing == .horizon ? 1 : 0,
      accent: configuration.paletteColors.accentRGBA
    )
    encoder.label = "IdleScreen procedural glyph compute"
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(instanceBuffer, offset: 0, index: 0)
    encoder.setBytes(
      &uniforms,
      length: MemoryLayout<ProceduralComputeUniforms>.stride,
      index: 1
    )
    let threadWidth = max(
      1,
      min(grid.columns, pipeline.threadExecutionWidth)
    )
    let threadHeight = max(
      1,
      min(
        grid.rows,
        pipeline.maxTotalThreadsPerThreadgroup / threadWidth
      )
    )
    encoder.dispatchThreadgroups(
      MTLSize(
        width: (grid.columns + threadWidth - 1) / threadWidth,
        height: (grid.rows + threadHeight - 1) / threadHeight,
        depth: 1
      ),
      threadsPerThreadgroup: MTLSize(
        width: threadWidth,
        height: threadHeight,
        depth: 1
      )
    )
    encoder.endEncoding()
    return true
  }

  private func preparePixelMaterialsInput(
    elapsed: TimeInterval,
    bufferIndex: Int
  ) -> PixelMaterialsComputeInput? {
    guard pixelMaterialsComputePipelineState != nil else { return nil }
    let token: IdleScreenPixelMaterialsSceneToken
    if let pixelMaterialsSceneToken {
      token = pixelMaterialsSceneToken
    } else {
      token = pixelMaterialsCoordinator.attach(
        settings: configuration.effectivePixelMaterialsSettings,
        viewport: configuration.viewport
      )
      pixelMaterialsSceneToken = token
    }
    guard
      let snapshot = try? pixelMaterialsCoordinator.snapshot(
        for: token,
        at: elapsed
      ), !snapshot.cells.isEmpty
    else {
      return nil
    }
    let count = snapshot.cells.count
    if pixelMaterialsStateBuffers[bufferIndex] == nil
      || pixelMaterialsStateCapacities[bufferIndex] < count
    {
      pixelMaterialsStateBuffers[bufferIndex] = device.makeBuffer(
        length: count * MemoryLayout<UInt32>.stride,
        options: .storageModeShared
      )
      pixelMaterialsStateCapacities[bufferIndex] =
        pixelMaterialsStateBuffers[bufferIndex] == nil ? 0 : count
    }
    guard let buffer = pixelMaterialsStateBuffers[bufferIndex] else {
      return nil
    }
    let encoded = buffer.contents().bindMemory(
      to: UInt32.self,
      capacity: count
    )
    for index in snapshot.cells.indices {
      let cell = snapshot.cells[index]
      encoded[index] =
        UInt32(cell.terrain.rawValue)
        | UInt32(cell.sand) << 8
        | UInt32(cell.water) << 16
    }
    pixelMaterialsDebugState = .init(
      usesComputePipeline: true,
      worldCellCount: count,
      allocatedCellCapacity: pixelMaterialsStateCapacities[bufferIndex],
      tick: snapshot.tick
    )
    return .init(columns: snapshot.width, rows: snapshot.height)
  }

  private func encodePixelMaterialInstances(
    _ input: PixelMaterialsComputeInput,
    grid: GridDimensions,
    bufferIndex: Int,
    instanceBuffer: any MTLBuffer,
    commandBuffer: any MTLCommandBuffer
  ) -> Bool {
    guard let pipeline = pixelMaterialsComputePipelineState,
      let stateBuffer = pixelMaterialsStateBuffers[bufferIndex],
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else {
      return false
    }
    let viewport = configuration.viewport.normalized
    let materialColors = configuration.pixelMaterialColors
    var uniforms = PixelMaterialsComputeUniforms(
      gridSize: SIMD2(UInt32(grid.columns), UInt32(grid.rows)),
      worldSize: SIMD2(UInt32(input.columns), UInt32(input.rows)),
      viewport: SIMD4(
        Float(viewport.x),
        Float(viewport.y),
        Float(viewport.width),
        Float(viewport.height)
      ),
      glyphCount: UInt32(Self.glyphRamp.count),
      sceneBrightness: Float(configuration.sceneBrightness),
      rockColor: materialColors.rock,
      soilColor: materialColors.soil,
      sandColor: materialColors.sand,
      waterColor: materialColors.water
    )
    encoder.label = "IdleScreen Pixel Materials glyph compute"
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(stateBuffer, offset: 0, index: 0)
    encoder.setBuffer(instanceBuffer, offset: 0, index: 1)
    encoder.setBytes(
      &uniforms,
      length: MemoryLayout<PixelMaterialsComputeUniforms>.stride,
      index: 2
    )
    let threadWidth = max(1, min(grid.columns, pipeline.threadExecutionWidth))
    let threadHeight = max(
      1,
      min(grid.rows, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
    )
    encoder.dispatchThreadgroups(
      MTLSize(
        width: (grid.columns + threadWidth - 1) / threadWidth,
        height: (grid.rows + threadHeight - 1) / threadHeight,
        depth: 1
      ),
      threadsPerThreadgroup: MTLSize(
        width: threadWidth,
        height: threadHeight,
        depth: 1
      )
    )
    encoder.endEncoding()
    return true
  }

  private func releasePixelMaterialsScene() {
    if let pixelMaterialsSceneToken {
      pixelMaterialsCoordinator.detach(pixelMaterialsSceneToken)
      self.pixelMaterialsSceneToken = nil
    }
    pixelMaterialsDebugState = nil
  }

  private func prepareCameraInput(
    _ frame: IdleScreenRendererCameraFrame,
    bufferIndex: Int
  ) -> Bool {
    let sampleCount = frame.luminance.count
    guard sampleCount > 0,
      frame.interleavedRGB.count == sampleCount * 3
    else {
      return false
    }
    if cameraLuminanceBuffers[bufferIndex] == nil
      || cameraRGBBuffers[bufferIndex] == nil
      || cameraInputCapacities[bufferIndex] < sampleCount
    {
      cameraLuminanceBuffers[bufferIndex] = device.makeBuffer(
        length: sampleCount,
        options: .storageModeShared
      )
      cameraRGBBuffers[bufferIndex] = device.makeBuffer(
        length: sampleCount * 3,
        options: .storageModeShared
      )
      cameraInputCapacities[bufferIndex] =
        cameraLuminanceBuffers[bufferIndex] != nil
          && cameraRGBBuffers[bufferIndex] != nil
        ? sampleCount : 0
    }
    guard let luminanceBuffer = cameraLuminanceBuffers[bufferIndex],
      let rgbBuffer = cameraRGBBuffers[bufferIndex]
    else {
      return false
    }
    frame.luminance.withUnsafeBytes { bytes in
      if let baseAddress = bytes.baseAddress {
        memcpy(luminanceBuffer.contents(), baseAddress, bytes.count)
      }
    }
    frame.interleavedRGB.withUnsafeBytes { bytes in
      if let baseAddress = bytes.baseAddress {
        memcpy(rgbBuffer.contents(), baseAddress, bytes.count)
      }
    }
    return true
  }

  private func encodeCameraInstances(
    _ input: CameraComputeInput,
    grid: GridDimensions,
    bufferIndex: Int,
    instanceBuffer: any MTLBuffer,
    commandBuffer: any MTLCommandBuffer
  ) -> Bool {
    guard let pipeline = cameraComputePipelineState,
      let luminanceBuffer = cameraLuminanceBuffers[bufferIndex],
      let rgbBuffer = cameraRGBBuffers[bufferIndex],
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else {
      reportCameraComputeFailureOnce(
        "Camera frame dropped because Metal could not create its compute encoder"
      )
      return false
    }
    var uniforms = CameraComputeUniforms(
      gridSize: SIMD2(UInt32(grid.columns), UInt32(grid.rows)),
      cameraSize: SIMD2(UInt32(input.columns), UInt32(input.rows)),
      contrast: Float(0.6 + configuration.contrast * 1.6),
      glyphCount: UInt32(Self.glyphRamp.count),
      mirrored: configuration.cameraIsMirrored ? 1 : 0,
      usesCameraColor: configuration.usesCameraColor ? 1 : 0,
      paletteForeground: configuration.paletteColors.foregroundRGBA
    )
    encoder.label = "IdleScreen camera glyph compute"
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(luminanceBuffer, offset: 0, index: 0)
    encoder.setBuffer(rgbBuffer, offset: 0, index: 1)
    encoder.setBuffer(instanceBuffer, offset: 0, index: 2)
    encoder.setBytes(
      &uniforms,
      length: MemoryLayout<CameraComputeUniforms>.stride,
      index: 3
    )
    let threadWidth = max(
      1,
      min(grid.columns, pipeline.threadExecutionWidth)
    )
    let threadHeight = max(
      1,
      min(
        grid.rows,
        pipeline.maxTotalThreadsPerThreadgroup / threadWidth
      )
    )
    let threads = MTLSize(
      width: threadWidth,
      height: threadHeight,
      depth: 1
    )
    let groups = MTLSize(
      width: (grid.columns + threads.width - 1) / threads.width,
      height: (grid.rows + threads.height - 1) / threads.height,
      depth: 1
    )
    encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    encoder.endEncoding()
    return true
  }

  private func reportCameraComputeFailureOnce(_ message: String) {
    guard !didReportCameraComputeFailure else { return }
    didReportCameraComputeFailure = true
    Self.logger.error("\(message, privacy: .public)")
  }

  private static func sampledCameraPixel(
    in cameraFrame: IdleScreenRendererCameraFrame,
    u: Float,
    v: Float,
    mirrored: Bool
  ) -> CameraPixelSample {
    let unmirroredColumn = min(
      cameraFrame.columns - 1,
      max(0, Int(u * Float(cameraFrame.columns)))
    )
    let column =
      if mirrored {
        cameraFrame.columns - 1 - unmirroredColumn
      } else {
        unmirroredColumn
      }
    let row = min(
      cameraFrame.rows - 1,
      max(0, Int(v * Float(cameraFrame.rows)))
    )
    let sampleIndex = row * cameraFrame.columns + column
    let rgbIndex = sampleIndex * 3
    return CameraPixelSample(
      brightness: Float(cameraFrame.luminance[sampleIndex]) / 255,
      rgb: SIMD3<Float>(
        Float(cameraFrame.interleavedRGB[rgbIndex]) / 255,
        Float(cameraFrame.interleavedRGB[rgbIndex + 1]) / 255,
        Float(cameraFrame.interleavedRGB[rgbIndex + 2]) / 255
      )
    )
  }

}

private struct AquariumComputeInput {
  let worldWidth: Int
  let contentRect: CGRect
}
private struct AquariumComputeUniforms {
  let gridSize: SIMD2<UInt32>
  let worldSize: SIMD2<UInt32>
  let viewport: SIMD4<Float>
  let contentRect: SIMD4<Float>
  let brightness: Float
}

private struct GlyphInstance {
  let gridBrightnessGlyph: SIMD4<Float>
  let foreground: SIMD4<Float>
}

private struct CameraComputeUniforms {
  let gridSize: SIMD2<UInt32>
  let cameraSize: SIMD2<UInt32>
  let contrast: Float
  let glyphCount: UInt32
  let mirrored: UInt32
  let usesCameraColor: UInt32
  let paletteForeground: SIMD4<Float>
}

private struct CameraComputeInput {
  let columns: Int
  let rows: Int
}

private struct PixelMaterialsComputeInput {
  let columns: Int
  let rows: Int
}

private struct PixelMaterialsComputeUniforms {
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

struct ProceduralComputeUniforms {
  let gridSize: SIMD2<UInt32>
  let sceneSize: SIMD2<UInt32>
  let sceneOrigin: SIMD2<UInt32>
  let patternIndex: UInt32
  let glyphCount: UInt32
  let timestamp: Float
  let contrast: Float
  let sceneBrightness: Float
  let speed: Float
  let scale: Float
  let intensity: Float
  let trailing: Float
  let matrixTrailLength: Float
  let rainbowAmplitude: Float
  let fireDecay: Float
  let nextPatternIndex: UInt32
  let blend: Float
  let foreground: SIMD4<Float>
  let seedOffset: SIMD2<Float>
  let seedCenter: SIMD2<Float>
  let sceneAspect: Float
  /// The horizon in this grid's row coordinates when `framingEnabled` is 1.
  var horizonRow: Float = 0
  var framingEnabled: UInt32 = 0
  /// Alpha 0 disables the accent band.
  var accent: SIMD4<Float> = .zero
}

private struct CameraPixelSample {
  let brightness: Float
  let rgb: SIMD3<Float>
}

private struct GridDimensions {
  let columns: Int
  let rows: Int

  var count: Int { columns * rows }

  static let empty = GridDimensions(columns: 0, rows: 0)
}

private struct PreparedGrid {
  let dimensions: GridDimensions
  let cameraInput: CameraComputeInput?
  let pixelMaterialsInput: PixelMaterialsComputeInput?
  let usesProceduralCompute: Bool
  var aquariumInput: AquariumComputeInput? = nil

  /// True when a GPU kernel fills the instance buffer, so sparse overrides
  /// must follow it on the GPU rather than touch the buffer from the CPU.
  var populatesOnGPU: Bool {
    cameraInput != nil || pixelMaterialsInput != nil || aquariumInput != nil
      || usesProceduralCompute
  }

  static let empty = PreparedGrid(
    dimensions: .empty,
    cameraInput: nil,
    pixelMaterialsInput: nil,
    usesProceduralCompute: false
  )
}

/// Metal resources are designed to be referenced by asynchronous command
/// buffers. This narrow wrapper makes that lifetime guarantee explicit to
/// Swift's strict-concurrency checker without weakening the whole Metal import.
private final class InFlightBufferRetention: @unchecked Sendable {
  let buffers: [any MTLBuffer]

  init(_ buffers: [any MTLBuffer]) {
    self.buffers = buffers
  }
}

extension IdleScreenRendererConfiguration {
  fileprivate var normalized: Self {
    Self(
      glyphScale: min(1, max(0, glyphScale)),
      contrast: min(1, max(0, contrast)),
      palette: palette,
      patternRawValue: patternRawValue,
      cameraIsMirrored: cameraIsMirrored,
      proceduralSettings: proceduralSettings,
      viewport: viewport,
      sceneSeed: sceneSeed,
      sceneBrightness: sceneBrightness,
      pixelMaterialsSettings: pixelMaterialsSettings,
      agentSprites: agentSprites,
      framing: framing,
      aquariumSettings: aquariumSettings
    )
  }

  fileprivate var effectivePixelMaterialsSettings: IdleScreenPixelMaterialsRendererSettings {
    var settings = pixelMaterialsSettings
    settings.seed ^= sceneSeed
    if settings.seed == 0 {
      settings.seed = 0x4944_4C45_504D_0001
    }
    return settings
  }

  fileprivate var pixelMaterialColors: PixelMaterialColors {
    switch pixelMaterialsSettings.paletteRawValue.lowercased() {
    case "tidal":
      .init(
        rock: SIMD4(0.18, 0.32, 0.38, 1),
        soil: SIMD4(0.25, 0.48, 0.48, 1),
        sand: SIMD4(0.78, 0.76, 0.52, 1),
        water: SIMD4(0.08, 0.72, 0.92, 1)
      )
    case "monochrome":
      .init(
        rock: SIMD4(0.36, 0.36, 0.38, 1),
        soil: SIMD4(0.52, 0.52, 0.54, 1),
        sand: SIMD4(0.82, 0.82, 0.80, 1),
        water: SIMD4(0.66, 0.72, 0.78, 1)
      )
    default:
      .init(
        rock: SIMD4(0.52, 0.38, 0.25, 1),
        soil: SIMD4(0.68, 0.43, 0.22, 1),
        sand: SIMD4(0.96, 0.72, 0.28, 1),
        water: SIMD4(0.18, 0.62, 1, 1)
      )
    }
  }

  fileprivate var usesCameraColor: Bool {
    palette.caseInsensitiveCompare("Camera Color") == .orderedSame
  }

  fileprivate var paletteColors: PaletteColors {
    let colors =
      switch palette.lowercased() {
      case "camera color":
        // A neutral monochrome treatment is the deterministic fallback for
        // Generative mode and for camera modes before a frame is available.
        PaletteColors(background: (0.008, 0.008, 0.008), foreground: (0.92, 0.92, 0.92))
      case "phosphor":
        PaletteColors(background: (0.01, 0.04, 0.01), foreground: (0.28, 1, 0.38))
      case "ivory":
        PaletteColors(background: (0.04, 0.035, 0.025), foreground: (1, 0.94, 0.78))
      case "blueprint":
        PaletteColors(background: (0.01, 0.04, 0.12), foreground: (0.35, 0.78, 1))
      case "signal":
        PaletteColors(background: (0.06, 0.01, 0.01), foreground: (1, 0.22, 0.14))
      case "cobalt":
        PaletteColors(
          background: (0.016, 0.02, 0.035), foreground: (0.70, 0.74, 0.82),
          accent: (0.231, 0.424, 0.941))
      default:
        PaletteColors(background: (0.043, 0.031, 0.012), foreground: (1, 0.75, 0.42))
      }
    return colors.scaled(by: Float(sceneBrightness))
  }
}

private struct PaletteColors {
  let background: SIMD3<Float>
  let foreground: SIMD3<Float>
  /// A third colour for the top of the brightness range and the horizon line.
  /// Palettes without one repeat the foreground.
  let accent: SIMD3<Float>
  let hasAccent: Bool

  init(
    background: (Float, Float, Float),
    foreground: (Float, Float, Float),
    accent: (Float, Float, Float)? = nil
  ) {
    hasAccent = accent != nil
    let accent = accent ?? foreground
    self.accent = SIMD3<Float>(accent.0, accent.1, accent.2)
    self.background = SIMD3<Float>(
      background.0,
      background.1,
      background.2
    )
    self.foreground = SIMD3<Float>(
      foreground.0,
      foreground.1,
      foreground.2
    )
  }

  var clearColor: MTLClearColor {
    MTLClearColor(
      red: Double(background.x),
      green: Double(background.y),
      blue: Double(background.z),
      alpha: 1
    )
  }

  var foregroundRGBA: SIMD4<Float> {
    SIMD4<Float>(foreground.x, foreground.y, foreground.z, 1)
  }

  /// Alpha 0 means the palette has no accent and the kernel never uses it.
  var accentRGBA: SIMD4<Float> {
    SIMD4<Float>(accent.x, accent.y, accent.z, hasAccent ? 1 : 0)
  }

  func scaled(by brightness: Float) -> Self {
    let scale = min(1, max(0, brightness))
    return Self(
      background: (
        background.x * scale,
        background.y * scale,
        background.z * scale
      ),
      foreground: (
        foreground.x * scale,
        foreground.y * scale,
        foreground.z * scale
      ),
      accent: hasAccent ? (accent.x * scale, accent.y * scale, accent.z * scale) : nil
    )
  }
}

private struct PixelMaterialColors {
  let rock: SIMD4<Float>
  let soil: SIMD4<Float>
  let sand: SIMD4<Float>
  let water: SIMD4<Float>
}

private final class CharacterAtlas {
  let texture: MTLTexture
  let glyphBuffer: MTLBuffer

  init?(device: MTLDevice, glyphCount: Int) {
    let face = IdleScreenGlyphFace.resolve()
    let glyphs = face.ramp
    guard glyphs.count == glyphCount else { return nil }
    let cellHeight = 96
    let cellWidth = Int(
      (Double(cellHeight) * IdleScreenProceduralPatterns.cellAspect)
        .rounded()
    )
    let width = cellWidth * glyphs.count
    let height = cellHeight
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](
      repeating: 0,
      count: bytesPerRow * height
    )

    let bitmapInfo = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let rendered = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo.rawValue
        )
      else {
        return false
      }

      context.setFillColor(CGColor(gray: 0, alpha: 0))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      // Size the face so one advance fills the atlas cell exactly, then
      // centre its ascent/descent box vertically.
      let probe = CTFontCreateWithFontDescriptor(face.descriptor, 100, nil)
      var probeGlyph = CGGlyph(0)
      var character = UniChar(0x30)
      CTFontGetGlyphsForCharacters(probe, &character, &probeGlyph, 1)
      let advance100 = CTFontGetAdvancesForGlyphs(
        probe,
        .horizontal,
        &probeGlyph,
        nil,
        1
      )
      let advanceRatio = advance100 > 0 ? advance100 / 100 : 0.6
      var pointSize = CGFloat(cellWidth) / advanceRatio
      var font = CTFontCreateWithFontDescriptor(
        face.descriptor,
        pointSize,
        nil
      )
      let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
      if lineHeight > CGFloat(cellHeight) {
        pointSize *= CGFloat(cellHeight) / lineHeight
        font = CTFontCreateWithFontDescriptor(
          face.descriptor,
          pointSize,
          nil
        )
      }
      let baseline =
        (CGFloat(cellHeight)
          - (CTFontGetAscent(font) + CTFontGetDescent(font))) / 2
        + CTFontGetDescent(font)
      for (index, glyph) in glyphs.enumerated() {
        let attributed = NSAttributedString(
          string: String(glyph),
          attributes: [
            NSAttributedString.Key(
              kCTFontAttributeName as String
            ): font,
            NSAttributedString.Key(
              kCTForegroundColorAttributeName as String
            ): CGColor(gray: 1, alpha: 1),
          ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(
          x: CGFloat(index * cellWidth),
          y: baseline
        )
        CTLineDraw(line, context)
      }
      return true
    }
    guard rendered else { return nil }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      return nil
    }
    texture.label = "IdleScreen character atlas"
    pixels.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: baseAddress,
        bytesPerRow: bytesPerRow
      )
    }

    let glyphRects = glyphs.indices.map { index in
      SIMD4<Float>(
        Float(index * cellWidth) / Float(width),
        0,
        Float(cellWidth) / Float(width),
        1
      )
    }
    guard
      let glyphBuffer = device.makeBuffer(
        bytes: glyphRects,
        length: glyphRects.count * MemoryLayout<SIMD4<Float>>.stride,
        options: .storageModeShared
      )
    else {
      return nil
    }
    glyphBuffer.label = "IdleScreen glyph UV table"

    self.texture = texture
    self.glyphBuffer = glyphBuffer
  }
}
