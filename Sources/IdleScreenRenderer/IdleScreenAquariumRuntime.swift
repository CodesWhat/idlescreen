import Foundation

public enum IdleScreenAquariumRuntime {
  public static var sceneURL: URL? {
    Bundle(for: AquariumRuntimeBundle.self).url(
      forResource: "index", withExtension: "html", subdirectory: "AquariumRuntime")
  }
}

private final class AquariumRuntimeBundle: NSObject {}
