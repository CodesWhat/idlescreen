import Darwin
import Foundation
import Testing

@testable import IdleScreenRenderer

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
nonisolated(unsafe) private var benchmarkSink: UInt64 = 0

/// State the malloc hook reads. The hook runs on every thread in the process, so
/// it must not touch Swift globals: in Debug each access goes through dynamic
/// exclusivity checking, which isn't safe inside malloc on arbitrary threads.
/// It lives in raw memory instead and is allocated before the hook goes in.
private struct HookState {
  /// Bit pattern of the pthread being measured; 0 when none.
  var measuredThread: UInt = 0
  /// The observer that was installed before ours.
  var previous: MallocLogger?
  var count = 0
  var bytes = 0
}

nonisolated(unsafe) private let hookState: UnsafeMutablePointer<HookState> = {
  let state = UnsafeMutablePointer<HookState>.allocate(capacity: 1)
  state.initialize(to: HookState())
  return state
}()

private let countAllocation: MallocLogger = { type, arg1, size, newSize, result, skip in
  // Forward every thread's event so an existing observer still sees them all.
  hookState.pointee.previous?(type, arg1, size, newSize, result, skip)
  // Only the measured thread counts.
  guard UInt(bitPattern: pthread_self()) == hookState.pointee.measuredThread else { return }
  // stack_logging_type_alloc is bit 1; a realloc sets alloc and dealloc.
  guard type & 2 != 0 else { return }
  hookState.pointee.count += 1
  hookState.pointee.bytes += Int(type & 4 != 0 ? newSize : size)
}

/// Full-frame cost with 12 decorations and 32 mixed animals. It records
/// per-stage CPU time and malloc traffic and only asserts loosely, so the same
/// file measures a baseline and the optimized renderer. Run it in an optimized
/// configuration for numbers worth comparing:
/// `xcodebuild test -scheme IdleScreenRenderer -configuration Release
///  ENABLE_TESTABILITY=YES -only-testing:IdleScreenRendererTests/AquariumFrameBenchmarkTests`
@Suite("Aquarium full-frame benchmark", .serialized)
@MainActor
struct AquariumFrameBenchmarkTests {
  struct Sample {
    var cpuMilliseconds = 0.0
    var allocations = 0
    var bytes = 0
  }

  private static func cpuSeconds() -> Double {
    var spec = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
    return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
  }

  /// Mean per-iteration CPU time and malloc traffic. Each body returns a value
  /// derived from its result so the optimizer cannot drop the work.
  /// Best of three rounds, so a scheduling hiccup doesn't skew the mean.
  private static func measure(iterations: Int, _ body: (Int) -> UInt64) -> Sample {
    var best = measureOnce(iterations: iterations, body)
    for _ in 0..<2 {
      let next = measureOnce(iterations: iterations, body)
      if next.cpuMilliseconds < best.cpuMilliseconds { best = next }
    }
    return best
  }

  private static func measureOnce(iterations: Int, _ body: (Int) -> UInt64) -> Sample {
    for index in 0..<2 { benchmarkSink &+= body(index) }
    var hook: UnsafeMutablePointer<MallocLogger?>?
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") {
      hook = symbol.assumingMemoryBound(to: MallocLogger?.self)
    }
    let state = hookState
    let logger = countAllocation
    state.pointee.count = 0
    state.pointee.bytes = 0
    let previous = hook?.pointee
    state.pointee.previous = previous
    state.pointee.measuredThread = UInt(bitPattern: pthread_self())
    hook?.pointee = logger
    let start = cpuSeconds()
    for index in 0..<iterations { benchmarkSink &+= body(index + 2) }
    let elapsed = cpuSeconds() - start
    hook?.pointee = previous
    state.pointee.measuredThread = 0
    return .init(
      cpuMilliseconds: elapsed * 1000 / Double(iterations),
      allocations: state.pointee.count / iterations, bytes: state.pointee.bytes / iterations)
  }

  private static func digest(_ pixels: [SIMD4<Float>]) -> UInt64 {
    UInt64(pixels.count) &+ UInt64(pixels[pixels.count / 2].x.bitPattern)
  }

  private static func time(_ index: Int) -> Double { 100 + Double(index) * 0.37 }

  @Test func recordsPerStageAndTotalFrameCost() {
    var report: [String] = []
    for width in AquariumFrameFixtures.widths {
      let settings = AquariumFrameFixtures.settings(width: width)
      #if DEBUG
        // Unoptimized numbers aren't comparable; just prove the stages run.
        let iterations = 2
      #else
        let iterations = width == 1152 ? 60 : 150
      #endif
      let preparation = IdleScreenAquariumScenePreparation()
      let navigation = preparation.navigation(settings: settings, width: width)
      var results: [(String, Sample)] = []
      results.append(
        (
          "navigation",
          Self.measure(iterations: iterations) { _ in
            let built = preparation.navigation(settings: settings, width: width)
            return UInt64(built.shelters.count) &+ UInt64(built.floor)
          }
        ))
      results.append(
        (
          "poses",
          Self.measure(iterations: iterations) { index in
            var total = 0.0
            for item in settings.inhabitants {
              total +=
                IdleScreenAquarium.savedAnimal(
                  item, at: Self.time(index), seed: 42, settings: settings, worldWidth: width,
                  navigation: navigation
                ).x
            }
            return total.bitPattern
          }
        ))
      let poses = (0..<iterations + 2).map { index in
        settings.inhabitants.map {
          IdleScreenAquarium.savedAnimal(
            $0, at: Self.time(index), seed: 42, settings: settings, worldWidth: width,
            navigation: navigation)
        }
      }
      results.append(
        (
          "sprites",
          Self.measure(iterations: iterations) { index in
            var total = 0
            for (item, pose) in zip(settings.inhabitants, poses[index]) {
              let sprite = IdleScreenAquariumSpriteCache.shared.sprite(
                for: pose, variant: item.variant, eggs: item.carryingEggs)
              total += sprite.width
            }
            for object in settings.objects {
              total +=
                IdleScreenAquarium.objectSprite(
                  kind: object.kind, time: Self.time(index), flow: settings.flow
                ).width
            }
            return UInt64(total)
          }
        ))
      results.append(
        (
          "composition",
          Self.measure(iterations: iterations) { index in
            var canvas = IdleScreenAquarium.Canvas(width: width)
            let time = Self.time(index)
            for item in settings.objects where !item.foreground {
              canvas.object(item, time: time, flow: settings.flow)
            }
            for (item, pose) in zip(settings.inhabitants, poses[index]) {
              let sprite = IdleScreenAquariumSpriteCache.shared.sprite(
                for: pose, variant: item.variant, eggs: item.carryingEggs)
              canvas.sprite(sprite, animal: pose, navigation: navigation)
            }
            for item in settings.objects where item.foreground {
              canvas.object(item, time: time, flow: settings.flow)
            }
            canvas.equipment(settings.equipment)
            return Self.digest(canvas.pixels)
          }
        ))
      var lit = IdleScreenAquarium.Canvas(width: width)
      results.append(
        (
          "lighting",
          Self.measure(iterations: iterations) { _ in
            lit.applyLight(settings, time: 100)
            return Self.digest(lit.pixels)
          }
        ))
      results.append(
        (
          "total",
          Self.measure(iterations: iterations) { index in
            Self.digest(
              IdleScreenAquarium.frame(at: Self.time(index), seed: 42, settings: settings))
          }
        ))
      results.append(
        (
          "total-cache",
          Self.measure(iterations: iterations) { index in
            Self.digest(
              IdleScreenAquariumFrameCache.shared.frame(
                at: Self.time(index), seed: 42, settings: settings))
          }
        ))
      for (stage, sample) in results {
        report.append(
          "BENCH width=\(width) stage=\(stage) cpu_ms=\(String(format: "%.3f", sample.cpuMilliseconds)) allocs=\(sample.allocations) bytes=\(sample.bytes)"
        )
        #expect(sample.cpuMilliseconds.isFinite && sample.cpuMilliseconds >= 0)
        #expect(sample.cpuMilliseconds < 5_000, "\(stage) at \(width) wildly slow")
      }
    }
    IdleScreenAquariumFrameCache.shared.clear()
    for line in report { print(line) }
    #expect(benchmarkSink != 1)
  }
}
