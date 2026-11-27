import AppKit
import Foundation
import Testing
import WebKit

@testable import IdleScreenRenderer

/// Hosted runners cap live WebGL contexts per process, so a surface that outlives its test starves
/// every later one (PR #81: after the first "WebGL unavailable", every later case failed).
extension WebGLSurfaceSuites {
  @Suite("Aquarium WebGL context lifecycle", .timeLimit(.minutes(5)))
  @MainActor
  struct AquariumWebGLLifecycleTests {
    @Test func disposeLosesTheLiveWebGLContext() async throws {
      let surface = IdleScreenAquariumWebSurface()
      defer { surface.releaseResources() }
      try await surface.loadRetryingTransientWebGLFailure(
        sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
      let before = try await surface.view.evaluateJavaScript(
        """
        (() => {
          const canvas = document.querySelector('canvas');
          window.__probe = canvas.getContext('webgl2') || canvas.getContext('webgl');
          return window.__probe ? (window.__probe.isContextLost() ? 'lost' : 'live') : 'none';
        })()
        """)
      #expect(before as? String == "live")
      let after = try await surface.view.evaluateJavaScript(
        "window.idleScreenScene.dispose(); window.__probe.isContextLost()")
      #expect(after as? Bool == true)
    }

    @Test func fiftySurfacesReleaseEveryWebViewAndContext() async throws {
      var released: [WeakView] = []
      for _ in 0..<50 {
        let surface = IdleScreenAquariumWebSurface()
        released.append(WeakView(surface.view))
        try await surface.loadRetryingTransientWebGLFailure(
          sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
        try await surface.shutdown()
      }
      for _ in 0..<40 where released.contains(where: { $0.view != nil }) {
        try await Task.sleep(for: .milliseconds(50))
      }
      #expect(released.filter { $0.view != nil }.count == 0)
    }

    @Test func surfaceDroppedWithoutReleaseStillFreesItsWebView() async throws {
      var probe = WeakView(nil)
      do {
        let surface = IdleScreenAquariumWebSurface()
        probe = WeakView(surface.view)
        try await surface.loadRetryingTransientWebGLFailure(
          sceneURL: #require(IdleScreenAquariumRuntime.sceneURL))
        try await surface.resume()
      }
      for _ in 0..<40 where probe.view != nil {
        try await Task.sleep(for: .milliseconds(50))
      }
      #expect(probe.view == nil)
    }

    @Test func retryHelperOnlyRetriesWebGLContextFailures() async throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "idlescreen-webgl-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let page = directory.appendingPathComponent("index.html")
      try "<!doctype html><title>no scene</title>".write(
        to: page, atomically: true, encoding: .utf8)
      let baseline = IdleScreenAquariumWebSurface()
      defer { baseline.releaseResources() }
      let plainStart = ContinuousClock.now
      await #expect(throws: IdleScreenAquariumWebSurface.SurfaceError.self) {
        try await baseline.load(sceneURL: page)
      }
      let plain = ContinuousClock.now - plainStart

      let surface = IdleScreenAquariumWebSurface()
      defer { surface.releaseResources() }
      let started = ContinuousClock.now
      await #expect(throws: IdleScreenAquariumWebSurface.SurfaceError.self) {
        try await surface.loadRetryingTransientWebGLFailure(sceneURL: page)
      }
      // A retry would add the 500 ms back-off plus a second load.
      #expect(
        ContinuousClock.now - started < plain + .milliseconds(400),
        "a non-WebGL failure was retried")
      #expect(surface.state == .failed)
    }

    private struct WeakView {
      weak var view: WKWebView?
      init(_ view: WKWebView?) { self.view = view }
    }
  }
}
