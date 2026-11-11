import AppKit
import WebKit

@MainActor
public final class IdleScreenAquariumWebSurface: NSObject, WKNavigationDelegate {
  public enum State: Equatable {
    case unloaded
    case loading
    case paused
    case running
    case failed
    case stopped
  }

  public enum SurfaceError: Error {
    case invalidLocalResource
    case invalidState
    case stopped
  }

  public let view: WKWebView
  public private(set) var state = State.unloaded
  private var resourceDirectory: URL?
  private var loading: CheckedContinuation<Void, any Error>?

  public override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    view = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    view.navigationDelegate = self
  }

  public func load(sceneURL: URL) async throws {
    guard state == .unloaded else { throw SurfaceError.invalidState }
    guard sceneURL.isFileURL,
      FileManager.default.isReadableFile(atPath: sceneURL.path)
    else { throw SurfaceError.invalidLocalResource }

    let resource = sceneURL.resolvingSymlinksInPath().standardizedFileURL
    resourceDirectory = resource.deletingLastPathComponent()
    state = .loading
    do {
      try await withCheckedThrowingContinuation { continuation in
        loading = continuation
        if view.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
          == nil
        {
          finishLoading(.failure(SurfaceError.invalidLocalResource))
        }
      }
      guard state == .loading else { throw SurfaceError.stopped }
      try await command("window.idleScreenScene.setAnimating(false)")
      guard state == .loading else { throw SurfaceError.stopped }
      state = .paused
    } catch {
      if state != .stopped { state = .failed }
      throw error
    }
  }

  public func resume() async throws {
    if state == .running { return }
    guard state == .paused else { throw SurfaceError.invalidState }
    state = .running
    try await command("window.idleScreenScene.setAnimating(true)")
  }

  public func pause() async throws {
    if state == .paused { return }
    guard state == .running else { throw SurfaceError.invalidState }
    state = .paused
    try await command("window.idleScreenScene.setAnimating(false)")
  }

  public func shutdown() async throws {
    if state == .stopped { return }
    let wasRunning = state == .running
    state = .stopped
    finishLoading(.failure(SurfaceError.stopped))
    defer {
      view.stopLoading()
      view.navigationDelegate = nil
      view.loadHTMLString("", baseURL: nil)
      resourceDirectory = nil
    }
    if wasRunning {
      try await command("window.idleScreenScene.setAnimating(false)")
    }
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finishLoading(.success(()))
  }

  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
    finishLoading(.failure(error))
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    finishLoading(.failure(error))
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url,
      url.isFileURL,
      let resourceDirectory,
      url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
        resourceDirectory.path + "/")
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard state != .stopped else { return }
    state = .failed
    finishLoading(.failure(SurfaceError.invalidState))
  }

  private func finishLoading(_ result: Result<Void, any Error>) {
    let continuation = loading
    loading = nil
    continuation?.resume(with: result)
  }

  private func command(_ script: String) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      view.evaluateJavaScript(script) { _, error in
        if let error {
          if self.state != .stopped { self.state = .failed }
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}
