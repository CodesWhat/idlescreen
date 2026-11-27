import Foundation

@testable import IdleScreenRenderer

extension IdleScreenAquariumWebSurface {
  /// Hosted runners' GPU sometimes refuses a WebGL context on first try. Retries the load once, and
  /// only for that context-creation failure, so "scene did not initialize" and every other
  /// deterministic regression fails on the first attempt.
  func loadRetryingTransientWebGLFailure(sceneURL: URL) async throws {
    do {
      try await load(sceneURL: sceneURL)
    } catch SurfaceError.runtimeUnavailable(let detail) where detail.hasPrefix("WebGL unavailable")
    {
      guard await resetFailedLoad() else { throw SurfaceError.runtimeUnavailable(detail) }
      print("IdleScreen test: WebGL context refused (\(detail)); retrying load once")
      try await Task.sleep(for: .milliseconds(500))
      try await load(sceneURL: sceneURL)
    }
  }
}
