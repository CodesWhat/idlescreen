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

  public struct PositionCm: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
  }

  public struct PresetObject: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let assetId: String
    public var positionCm: PositionCm
    public var rotationY: Double
  }

  public struct EditorSnapshot: Decodable, Equatable, Sendable {
    public let revision: Int
    public let objects: [PresetObject]
  }

  public enum EditorError: Error, LocalizedError {
    case rejected(String)
    case invalidResponse

    public var errorDescription: String? {
      switch self {
      case .rejected(let message): message
      case .invalidResponse: "The tank editor returned an unreadable response."
      }
    }
  }

  private struct EditRequest: Encodable {
    let expectedRevision: Int
    let objects: [PresetObject]
  }

  private struct EditorResponse: Decodable {
    let revision: Int
    let objects: [PresetObject]?
    let error: String?
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

  public func exportTank(id: String, name: String) async throws -> Data {
    let identity = try JSONEncoder().encode(["id": id, "name": name])
    let json = try await jsonQuery(
      "window.idleScreenScene.exportTank(\(String(decoding: identity, as: UTF8.self)))")
    let data = Data(json.utf8)
    guard data.count <= 4_194_304 else {
      throw EditorError.rejected("Tank checkpoint is too large.")
    }
    return data
  }

  public func restoreTank(from data: Data) async throws -> EditorSnapshot {
    guard state == .paused else { throw SurfaceError.invalidState }
    guard data.count <= 4_194_304, let text = String(data: data, encoding: .utf8) else {
      throw EditorError.rejected("Tank checkpoint must be UTF-8 JSON under 4 MiB.")
    }
    let argument = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    return try await editorQuery("window.idleScreenScene.restoreTankJSON(\(argument))")
  }

  public func beginEditing() async throws -> EditorSnapshot {
    try await editorQuery("window.idleScreenScene.beginEditing()")
  }

  public func editorSnapshot() async throws -> EditorSnapshot {
    try await editorQuery("window.idleScreenScene.editorSnapshot()")
  }

  public func applyPresetObjects(expectedRevision: Int, objects: [PresetObject]) async throws
    -> EditorSnapshot
  {
    let request = EditRequest(expectedRevision: expectedRevision, objects: objects)
    let data = try JSONEncoder().encode(request)
    let json = String(decoding: data, as: UTF8.self)
    return try await editorQuery("window.idleScreenScene.applyPresetObjects(\(json))")
  }

  private func editorQuery(_ expression: String) async throws -> EditorSnapshot {
    let json = try await jsonQuery(expression)
    let response = try JSONDecoder().decode(EditorResponse.self, from: Data(json.utf8))
    if let error = response.error { throw EditorError.rejected(error) }
    guard let objects = response.objects else { throw EditorError.invalidResponse }
    return EditorSnapshot(revision: response.revision, objects: objects)
  }

  private func jsonQuery(_ expression: String) async throws -> String {
    guard state == .paused || state == .running else { throw SurfaceError.invalidState }
    let json: String = try await withCheckedThrowingContinuation { continuation in
      view.evaluateJavaScript("JSON.stringify(\(expression))") { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let json = value as? String {
          continuation.resume(returning: json)
        } else {
          continuation.resume(throwing: EditorError.invalidResponse)
        }
      }
    }
    guard state == .paused || state == .running else { throw SurfaceError.invalidState }
    return json
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
