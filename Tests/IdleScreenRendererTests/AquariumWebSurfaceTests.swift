import AppKit
import Foundation
import Testing
import WebKit

@testable import IdleScreenRenderer

@Suite("Local aquarium WebKit surface", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AquariumWebSurfaceTests {
  @Test func bundledSceneLoadsPausedAndRunsOnlyOneAnimationLoop() async throws {
    let surface = IdleScreenAquariumWebSurface()
    let resource = try #require(
      Bundle(for: FixtureBundle.self).url(
        forResource: "index", withExtension: "html", subdirectory: "WebSurfaceProof"))
    try await surface.load(sceneURL: resource)
    #expect(surface.state == .paused)
    #expect(surface.view.url == resource)

    try await surface.resume()
    try await surface.resume()
    #expect(surface.state == .running)
    let running = try await status(surface.view)
    #expect(running.resourceLoaded)
    #expect(running.graphicsAPI == "webgl2")
    #expect(running.backgroundPixel == [6, 27, 41, 255])
    #expect(running.running)
    #expect(running.pendingFrames == 1)
    #expect(running.starts == 1)
    #expect(running.draws > 0)

    try await surface.pause()
    try await surface.pause()
    let paused = try await status(surface.view)
    #expect(surface.state == .paused)
    #expect(!paused.running)
    #expect(paused.pendingFrames == 0)
    #expect(paused.stops == 1)

    try await surface.resume()
    let resumed = try await status(surface.view)
    #expect(resumed.starts == 2)
    #expect(resumed.pendingFrames == 1)

    try await surface.shutdown()
    try await surface.shutdown()
    #expect(surface.state == .stopped)
    #expect(surface.view.navigationDelegate == nil)
    await #expect(throws: IdleScreenAquariumWebSurface.SurfaceError.self) {
      try await surface.resume()
    }
  }

  @Test func rejectedResourcesNeverStartNavigation() async throws {
    let surface = IdleScreenAquariumWebSurface()
    let remote = try #require(URL(string: "https://example.invalid/scene.html"))
    await #expect(throws: IdleScreenAquariumWebSurface.SurfaceError.self) {
      try await surface.load(sceneURL: remote)
    }
    await #expect(throws: IdleScreenAquariumWebSurface.SurfaceError.self) {
      try await surface.resume()
    }
    #expect(surface.state == .unloaded)
    #expect(surface.view.url == nil)
    try await surface.shutdown()
  }

  @Test func sceneCommandFailureDoesNotClaimItIsRunning() async throws {
    let surface = IdleScreenAquariumWebSurface()
    let resource = try #require(
      Bundle(for: FixtureBundle.self).url(
        forResource: "index", withExtension: "html", subdirectory: "WebSurfaceProof"))
    try await surface.load(sceneURL: resource)
    let _: String = try await evaluate(
      "window.idleScreenScene = undefined; 'removed'", in: surface.view)
    await #expect(throws: (any Error).self) { try await surface.resume() }
    #expect(surface.state == .failed)
    try await surface.shutdown()
    #expect(surface.state == .stopped)
  }

  private func status(_ view: WKWebView) async throws -> SceneStatus {
    let json = try await evaluate("JSON.stringify(window.idleScreenScene.status())", in: view)
    return try JSONDecoder().decode(SceneStatus.self, from: Data(json.utf8))
  }

  private func evaluate(_ script: String, in view: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      view.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let json = value as? String {
          continuation.resume(returning: json)
        } else {
          continuation.resume(throwing: CocoaError(.coderValueNotFound))
        }
      }
    }
  }

  private struct SceneStatus: Decodable {
    let resourceLoaded: Bool
    let graphicsAPI: String
    let backgroundPixel: [Int]
    let running: Bool
    let pendingFrames: Int
    let starts: Int
    let stops: Int
    let draws: Int
  }
}

private final class FixtureBundle: NSObject {}
