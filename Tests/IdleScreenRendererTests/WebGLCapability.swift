import AppKit
import Foundation
import Testing
import WebKit

@testable import IdleScreenRenderer

/// Whether this host can create a WebGL context at all. Hosted macOS runners sometimes have none
/// for the whole test process, which fails every WebGL-dependent test the same way no matter what
/// the code does. The probe loads the bundled aquarium once per process and caches the answer.
///
/// Suites gate with `.enabled("WebGL is unavailable on this runner") { await WebGLCapability.shouldRun() }`.
///
/// - `IDLESCREEN_REQUIRE_WEBGL=1`: an unavailable probe doesn't skip, so the suites run and fail.
/// - `IDLESCREEN_FORCE_NO_WEBGL=1`: test-only hook that hides WebGL from every page the helper loads.
enum WebGLCapability {
  private actor Probe {
    private var result: Bool?

    func isAvailable() async -> Bool {
      if let result { return result }
      let value = await Self.run()
      result = value
      if !value {
        print(
          "IdleScreen test: WebGL unavailable on this host; "
            + (WebGLCapability.requireWebGL
              ? "IDLESCREEN_REQUIRE_WEBGL=1 so the WebGL suites run and will fail"
              : "WebGL suites skipped (set IDLESCREEN_REQUIRE_WEBGL=1 to fail instead)"))
      }
      return value
    }

    @MainActor
    private static func run() async -> Bool {
      guard let sceneURL = IdleScreenAquariumRuntime.sceneURL else { return false }
      let surface = IdleScreenAquariumWebSurface()
      defer { surface.releaseResources() }
      surface.view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
      do {
        // Same transient-refusal retry the suites use, so one bad first context isn't a verdict.
        try await surface.loadRetryingTransientWebGLFailure(sceneURL: sceneURL)
        try await surface.shutdown()
        return true
      } catch {
        return !WebGLCapability.isWebGLUnavailable(error)
      }
    }
  }

  /// Only the specific WebGL-context failure counts as "unavailable". Any other failure (a scene
  /// that doesn't initialize, a navigation error) leaves the suites enabled so their own loads
  /// report it instead of being skipped.
  static func isWebGLUnavailable(_ error: any Error) -> Bool {
    guard case IdleScreenAquariumWebSurface.SurfaceError.runtimeUnavailable(let detail) = error
    else { return false }
    return detail.hasPrefix("WebGL unavailable")
  }

  private static let probe = Probe()

  static var forcedUnavailable: Bool {
    ProcessInfo.processInfo.environment["IDLESCREEN_FORCE_NO_WEBGL"] == "1"
  }

  /// Hides WebGL from a page the way a runner without it does, so every load fails with the real
  /// "WebGL unavailable" error. Applied by the test load helper when `IDLESCREEN_FORCE_NO_WEBGL=1`.
  @MainActor static var hideWebGLScript: WKUserScript {
    WKUserScript(
      source: """
        (() => {
          const original = HTMLCanvasElement.prototype.getContext;
          HTMLCanvasElement.prototype.getContext = function (type, ...rest) {
            return /webgl/i.test(String(type)) ? null : original.call(this, type, ...rest);
          };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
  }

  static var requireWebGL: Bool {
    ProcessInfo.processInfo.environment["IDLESCREEN_REQUIRE_WEBGL"] == "1"
  }

  /// True when the dependent tests should run: WebGL works, or the host demands it so a missing
  /// context must show up as failures.
  static func shouldRun() async -> Bool {
    let available = await probe.isAvailable()
    return available || requireWebGL
  }
}

@Suite("WebGL capability classification")
struct WebGLCapabilityClassificationTests {
  @Test func onlyTheWebGLContextFailureIsUnavailable() {
    typealias Failure = IdleScreenAquariumWebSurface.SurfaceError
    #expect(
      WebGLCapability.isWebGLUnavailable(
        Failure.runtimeUnavailable("WebGL unavailable: no context")))
    #expect(
      !WebGLCapability.isWebGLUnavailable(Failure.runtimeUnavailable("scene did not initialize")))
    #expect(!WebGLCapability.isWebGLUnavailable(URLError(.badURL)))
  }
}
