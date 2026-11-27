import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit

@testable import IdleScreenRenderer

/// These never need a live WebGL context, so they run on every host, including ones the
/// `requiresWebGL` suites skip. They stay under `WebGLSurfaceSuites` for its serialization.
extension WebGLSurfaceSuites {
  @Suite("Aquarium surface without a live WebGL context", .timeLimit(.minutes(1)))
  @MainActor
  struct AquariumWebSurfaceWithoutContextTests {
    @Test func rejectedResourcesNeverStartNavigation() async throws {
      let surface = IdleScreenAquariumWebSurface()
      defer { surface.releaseResources() }
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
        FileManager.default.enumerator(
          at: directory, includingPropertiesForKeys: [.isRegularFileKey])
      )
      var files: Set<String> = []
      for case let url as URL in enumerator {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
          files.insert(
            String(url.resolvingSymlinksInPath().path.dropFirst(directory.path.count + 1)))
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

    @Test func loadReportsWebGLUnavailableDescriptively() async throws {
      let resource = try #require(IdleScreenAquariumRuntime.sceneURL)
      let surface = IdleScreenAquariumWebSurface()
      defer { surface.releaseResources() }
      surface.view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
      surface.view.configuration.userContentController.addUserScript(
        WKUserScript(
          source: """
            (() => {
              const original = HTMLCanvasElement.prototype.getContext;
              HTMLCanvasElement.prototype.getContext = function (type, ...rest) {
                return /webgl/i.test(String(type)) ? null : original.call(this, type, ...rest);
              };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
      do {
        try await surface.load(sceneURL: resource)
        Issue.record("load succeeded without WebGL")
      } catch let error as IdleScreenAquariumWebSurface.SurfaceError {
        let message = error.localizedDescription
        #expect(message.contains("aquarium runtime did not start: WebGL unavailable"))
        #expect(message.contains("could not start"))
      }
      #expect(surface.state == .failed)
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
}
