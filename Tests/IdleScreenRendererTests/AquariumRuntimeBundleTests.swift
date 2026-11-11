import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit

@testable import IdleScreenRenderer

@Suite("Bundled Three.js aquarium", .timeLimit(.minutes(1)))
@MainActor
struct AquariumRuntimeBundleTests {
  @Test func actualAquariumLoadsAndPreservesItsCoupledLifeAcrossPauses() async throws {
    let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
    #expect(resource.path.contains("IdleScreenRenderer.framework/"))
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    surface.view.configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.frameClock(emulatingVisibleDocument: true), injectionTime: .atDocumentStart,
        forMainFrameOnly: true)
    )
    try await surface.load(sceneURL: resource)
    let initial = try await snapshot(surface)
    #expect(initial.revision == "160")
    #expect(!initial.documentHidden)
    #expect(!initial.scene.motion)
    #expect(initial.pendingFrames == 0)
    #expect(initial.scene.physical.tankCm.width == 60)
    #expect(initial.scene.physical.tankCm.depth == 36)
    #expect(initial.scene.physical.tankCm.height == 36)
    #expect(initial.scene.water.volumeL == 50)
    #expect(initial.scene.condition.mode == "ecosystem")
    #expect(initial.scene.renderedFrames > 0)
    #expect(initial.scene.drawCalls > 0)
    #expect(initial.scene.triangles > 0)
    #expect(!initial.scene.ecology.animals.isEmpty)
    #expect(initial.visibleControls == 0)

    try await surface.resume()
    try await surface.resume()
    let running = try await snapshot(surface, frames: 3)
    #expect(running.pendingFrames == 1)
    #expect(running.scene.renderedFrames > initial.scene.renderedFrames)
    #expect(running.scene.water.elapsedSeconds > initial.scene.water.elapsedSeconds)
    #expect(running.scene.ecology.seconds == running.scene.water.elapsedSeconds)
    #expect(running.scene.ecology.animals.map(\.id) == initial.scene.ecology.animals.map(\.id))

    try await surface.pause()
    let paused = try await snapshot(surface, frames: 3)
    #expect(paused.pendingFrames == 0)
    #expect(paused.scene.clock == running.scene.clock)
    #expect(paused.scene.water.elapsedSeconds == running.scene.water.elapsedSeconds)
    #expect(paused.scene.ecology.animals == running.scene.ecology.animals)

    try await surface.resume()
    let resumed = try await snapshot(surface, frames: 3)
    #expect(resumed.pendingFrames == 1)
    #expect(resumed.scene.clock > paused.scene.clock)
    #expect(resumed.scene.water.elapsedSeconds > paused.scene.water.elapsedSeconds)
    #expect(resumed.scene.ecology.animals.map(\.id) == paused.scene.ecology.animals.map(\.id))
    try await surface.shutdown()
    #expect(surface.state == .stopped)
  }

  @Test func anUnattachedHiddenDocumentDoesNotAdvanceLife() async throws {
    let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
    let surface = IdleScreenAquariumWebSurface()
    surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    surface.view.configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.frameClock(emulatingVisibleDocument: false), injectionTime: .atDocumentStart,
        forMainFrameOnly: true))
    try await surface.load(sceneURL: resource)
    let initial = try await snapshot(surface)
    #expect(initial.documentHidden)
    try await surface.resume()
    let hidden = try await snapshot(surface, frames: 3)
    #expect(hidden.pendingFrames == 0)
    #expect(hidden.scene.clock == initial.scene.clock)
    #expect(hidden.scene.water.elapsedSeconds == initial.scene.water.elapsedSeconds)
    #expect(hidden.scene.ecology.animals == initial.scene.ecology.animals)
    try await surface.shutdown()
  }

  @Test func bundleContainsOnlyDeclaredRuntimeAndPinnedVendor() throws {
    let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
    let directory = resource.deletingLastPathComponent().resolvingSymlinksInPath()
    let manifest = try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("PROVENANCE.json")))
    let entry = try String(contentsOf: resource, encoding: .utf8)
    let scripts = entry.matches(of: /<script src="([^"]+)"/).map { String($0.1) }
    #expect(scripts == manifest.scriptOrder)
    #expect(scripts.allSatisfy { !$0.contains(":") && !$0.hasPrefix("/") && !$0.contains("..") })
    let enumerator = try #require(
      FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    )
    var files: Set<String> = []
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        files.insert(String(url.path.dropFirst(directory.path.count + 1)))
      }
    }
    #expect(files == Set(scripts + ["index.html", "PROVENANCE.json", "vendor/LICENSE"]))
    #expect(
      Set(manifest.importedFiles.map(\.path))
        == Set(scripts.filter { $0 != "native-host.js" } + ["vendor/LICENSE"]))
    #expect(manifest.vendor.revision == "160")
    for (path, expected) in [
      ("vendor/three.min.js", manifest.vendor.sha256),
      ("vendor/LICENSE", manifest.vendor.licenseSha256),
    ] {
      let data = try Data(contentsOf: directory.appendingPathComponent(path))
      #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected)
    }
  }

  @Test func collisionQueriesPreserveContactsWithoutScanningDistantTriangles() async throws {
    let fixture = try #require(
      Bundle(for: AquariumCollisionFixtureBundle.self).url(
        forResource: "collision-check", withExtension: "js", subdirectory: "WebSurfaceProof"))
    let source = try String(contentsOf: fixture, encoding: .utf8)
    let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
    let surface = IdleScreenAquariumWebSurface()
    try await surface.load(sceneURL: resource)
    let script = source + "\nJSON.stringify(runAquariumCollisionCheck(THREE, AquariumCollisions));"
    let json: String = try await withCheckedThrowingContinuation { continuation in
      surface.view.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let text = value as? String {
          continuation.resume(returning: text)
        } else {
          continuation.resume(throwing: CocoaError(.coderValueNotFound))
        }
      }
    }
    let result = try JSONDecoder().decode([String: Int].self, from: Data(json.utf8))
    #expect(result["samples"] == 24)
    #expect(result["bodyQueries"] == 6)
    #expect(try #require(result["maxVertexReads"]) < 500)
    try await surface.shutdown()
  }

  private func snapshot(_ surface: IdleScreenAquariumWebSurface, frames: Int = 0) async throws
    -> Snapshot
  {
    let script = """
      for (let index = 0; index < \(frames); index++) window.aquariumFrameProof.advance();
      JSON.stringify({
        revision: THREE.REVISION,
        documentHidden: document.hidden,
        scene: aquariumStudy.state,
        pendingFrames: window.aquariumFrameProof.pending,
        visibleControls: Array.from(document.querySelectorAll('button')).filter(
          element => element.getClientRects().length > 0).length
      });
      """
    let json: String = try await withCheckedThrowingContinuation { continuation in
      surface.view.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let json = value as? String {
          continuation.resume(returning: json)
        } else {
          continuation.resume(throwing: CocoaError(.coderValueNotFound))
        }
      }
    }
    return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
  }

  private static func frameClock(emulatingVisibleDocument: Bool) -> String {
    """
    (() => {
      // The unattached test view is hidden. Emulate host visibility only here.
      if (\(emulatingVisibleDocument)) Object.defineProperty(document, 'hidden', { get: () => false });
      let nextID = 0;
      let time = 0;
      const callbacks = new Map();
      window.requestAnimationFrame = callback => {
        const id = ++nextID;
        callbacks.set(id, callback);
        return id;
      };
      window.cancelAnimationFrame = id => callbacks.delete(id);
      window.aquariumFrameProof = {
        get pending() { return callbacks.size; },
        advance() {
          time += 50;
          const current = Array.from(callbacks.values());
          callbacks.clear();
          current.forEach(callback => callback(time));
        }
      };
    })();
    """
  }

  private struct Snapshot: Decodable {
    let revision: String
    let documentHidden: Bool
    let scene: Scene
    let pendingFrames: Int
    let visibleControls: Int

    struct Scene: Decodable {
      let motion: Bool
      let clock: Double
      let renderedFrames: Int
      let drawCalls: Int
      let triangles: Int
      let water: Water
      let ecology: Ecology
      let condition: Condition
      let physical: Physical
    }

    struct Water: Decodable {
      let elapsedSeconds: Double
      let volumeL: Double
    }

    struct Ecology: Decodable {
      let seconds: Double
      let animals: [Animal]
    }

    struct Animal: Decodable, Equatable {
      let id: String
      let alive: Bool
      let health: Double
      let hunger: Double
    }

    struct Condition: Decodable { let mode: String }
    struct Physical: Decodable { let tankCm: Dimensions }
    struct Dimensions: Decodable {
      let width: Double
      let depth: Double
      let height: Double
    }
  }

  private struct Manifest: Decodable {
    let scriptOrder: [String]
    let importedFiles: [ImportedFile]
    let vendor: Vendor
    struct ImportedFile: Decodable { let path: String }
    struct Vendor: Decodable {
      let revision: String
      let sha256: String
      let licenseSha256: String
    }
  }
}

private final class AquariumCollisionFixtureBundle {}
