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

    public init(x: Double, y: Double, z: Double) {
      self.x = x
      self.y = y
      self.z = z
    }
  }

  public struct PresetObject: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let assetId: String
    public var positionCm: PositionCm
    public var rotationY: Double

    public init(id: String, assetId: String, positionCm: PositionCm, rotationY: Double) {
      self.id = id
      self.assetId = assetId
      self.positionCm = positionCm
      self.rotationY = rotationY
    }
  }

  public struct CatalogAsset: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let placement: String
  }

  public struct StockRemoval: Sendable {
    public let checkpoint: Data
    public let archive: Data
  }

  public struct StockAsset: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let kind: String
    public let variant: String
  }

  public struct StockAnimal: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let species: String
    public let variant: String?
    public let alive: Bool
  }

  public struct StockUpdate: Decodable, Sendable {
    public let revision: Int
    public let animals: [StockAnimal]
  }

  public struct TankSettings: Codable, Equatable, Sendable {
    public struct Light: Codable, Equatable, Sendable {
      public var preset: String
      public var count: Int
      public var output: Double
      public var spread: String
    }
    public struct Room: Codable, Equatable, Sendable {
      public var mode: String
      public var finish: String
      public var manualLevel: Double?
    }
    public var light: Light
    public var room: Room
    public var surface: String
    public var pump: Double
    public var rasterHeight: Int
  }

  public struct EditorSnapshot: Decodable, Equatable, Sendable {
    public let revision: Int
    public let stockRevision: Int
    public let settings: TankSettings
    public let objects: [PresetObject]
    public let placedObjects: [PresetObject]
    public let catalog: [CatalogAsset]
    public let equipmentObjects: [PresetObject]
    public let animals: [StockAnimal]
    public let stockCatalog: [StockAsset]

    public func updatingStock(_ update: StockUpdate) -> Self {
      guard update.revision > stockRevision else { return self }
      return Self(
        revision: revision, stockRevision: update.revision, settings: settings, objects: objects,
        placedObjects: placedObjects, catalog: catalog, equipmentObjects: equipmentObjects,
        animals: update.animals, stockCatalog: stockCatalog)
    }
  }

  public enum EditorTool: String, Codable, Sendable {
    case select, place, move
  }

  public struct EditorPick: Decodable, Equatable, Sendable {
    public let revision: Int
    public let tool: EditorTool
    public let toolGeneration: Int
    public let id: String?
    public let positionCm: PositionCm?

    public init(
      revision: Int, tool: EditorTool, id: String?, positionCm: PositionCm?, toolGeneration: Int = 0
    ) {
      self.revision = revision
      self.tool = tool
      self.toolGeneration = toolGeneration
      self.id = id
      self.positionCm = positionCm
    }
  }

  private struct ToolRequest: Encodable {
    let tool: EditorTool
    let generation: Int
    let selectedId: String?
    let assetId: String?
  }

  public private(set) var toolGeneration = 0
  public var onEditorPick: (@MainActor (EditorPick) -> Void)?
  public var onStockChange: (@MainActor (StockUpdate) -> Void)?
  private var latestStockUpdate: StockUpdate?

  private final class EditorMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: IdleScreenAquariumWebSurface?

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      if message.name == "idleScreenStock" {
        owner?.receiveStockChange(message)
      } else {
        owner?.receiveEditorPick(message)
      }
    }
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

  private struct StockResponse: Decodable {
    let checkpointJSON: String?
    let archive: String?
    let error: String?
  }

  private struct EditorResponse: Decodable {
    let revision: Int
    let stockRevision: Int?
    let settings: TankSettings?
    let objects: [PresetObject]?
    let placedObjects: [PresetObject]?
    let catalog: [CatalogAsset]?
    let equipmentObjects: [PresetObject]?
    let animals: [StockAnimal]?
    let stockCatalog: [StockAsset]?
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
    let handler = EditorMessageHandler()
    handler.owner = self
    configuration.userContentController.add(handler, name: "idleScreenEditor")
    configuration.userContentController.add(handler, name: "idleScreenStock")
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

  public func stageStockAddition(assetID: String, id: String) async throws -> EditorSnapshot {
    guard state == .paused else { throw SurfaceError.invalidState }
    let request = try JSONEncoder().encode(["assetID": assetID, "id": id])
    return try await editorQuery(
      "window.idleScreenScene.addStock(\(String(decoding: request, as: UTF8.self)))")
  }

  public func prepareStockRemovalHistory(animalID: String, id: String, name: String) async throws
    -> StockRemoval
  {
    guard state == .paused else { throw SurfaceError.invalidState }
    let request = try JSONEncoder().encode(["animalID": animalID, "id": id, "name": name])
    let result = try await stockQuery(
      "window.idleScreenScene.prepareStockRemovalHistory(\(String(decoding: request, as: UTF8.self)))"
    )
    guard let archive = result.archive else { throw EditorError.invalidResponse }
    return StockRemoval(checkpoint: result.checkpoint, archive: archive)
  }

  public func prepareStockRestoration(archive: Data, id: String, name: String) async throws -> Data
  {
    guard state == .paused else { throw SurfaceError.invalidState }
    guard archive.count <= 65_536, let text = String(data: archive, encoding: .utf8) else {
      throw EditorError.rejected("Animal history must be UTF-8 JSON under 64 KiB.")
    }
    let request = try JSONEncoder().encode(["archive": text, "id": id, "name": name])
    return try await stockQuery(
      "window.idleScreenScene.prepareStockRestoration(\(String(decoding: request, as: UTF8.self)))"
    ).checkpoint
  }

  public func reconcileStockPose(id: String) async throws -> EditorSnapshot {
    guard state == .paused else { throw SurfaceError.invalidState }
    let argument = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
    return try await editorQuery("window.idleScreenScene.reconcileStockPose(\(argument))")
  }

  public func prepareSettings(_ settings: TankSettings, id: String, name: String) async throws
    -> Data
  {
    guard state == .paused else { throw SurfaceError.invalidState }
    struct Request: Encodable {
      let settings: TankSettings
      let id: String
      let name: String
    }
    let request = try JSONEncoder().encode(Request(settings: settings, id: id, name: name))
    return try await stockQuery(
      "window.idleScreenScene.prepareSettings(\(String(decoding: request, as: UTF8.self)))"
    ).checkpoint
  }

  private func stockQuery(_ expression: String) async throws -> (checkpoint: Data, archive: Data?) {
    let json = try await jsonQuery(expression)
    let response = try JSONDecoder().decode(StockResponse.self, from: Data(json.utf8))
    if let error = response.error { throw EditorError.rejected(error) }
    guard let text = response.checkpointJSON else { throw EditorError.invalidResponse }
    let checkpoint = Data(text.utf8)
    let archive = response.archive.map { Data($0.utf8) }
    guard checkpoint.count <= 4_194_304, (archive?.count ?? 0) <= 65_536 else {
      throw EditorError.rejected("Stock change data is too large.")
    }
    return (checkpoint, archive)
  }

  public func prepareStockRemoval(animalID: String, id: String, name: String) async throws -> Data {
    guard state == .paused else { throw SurfaceError.invalidState }
    let request = try JSONEncoder().encode(["animalID": animalID, "id": id, "name": name])
    let json = try await jsonQuery(
      "window.idleScreenScene.prepareStockRemoval(\(String(decoding: request, as: UTF8.self)))")
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

  public func applyPlacedObjects(expectedRevision: Int, objects: [PresetObject]) async throws
    -> EditorSnapshot
  {
    let request = EditRequest(expectedRevision: expectedRevision, objects: objects)
    let data = try JSONEncoder().encode(request)
    let json = String(decoding: data, as: UTF8.self)
    return try await editorQuery("window.idleScreenScene.applyPlacedObjects(\(json))")
  }

  public func applyEquipmentObjects(expectedRevision: Int, objects: [PresetObject]) async throws
    -> EditorSnapshot
  {
    let request = EditRequest(expectedRevision: expectedRevision, objects: objects)
    let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    return try await editorQuery("window.idleScreenScene.applyEquipmentObjects(\(json))")
  }

  public func setEditorTool(_ tool: EditorTool, selectedID: String? = nil, assetID: String? = nil)
    async throws -> EditorSnapshot
  {
    toolGeneration += 1
    let request = ToolRequest(
      tool: tool, generation: toolGeneration, selectedId: selectedID, assetId: assetID)
    let argument = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    return try await editorQuery("window.idleScreenScene.setEditorTool(\(argument))")
  }

  private func receiveEditorPick(_ message: WKScriptMessage) {
    guard state == .paused || state == .running,
      message.webView === view, message.frameInfo.isMainFrame,
      let url = message.frameInfo.request.url, url.isFileURL, let resourceDirectory,
      url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
        resourceDirectory.path + "/"),
      let body = message.body as? String, body.utf8.count <= 4096,
      let pick = try? JSONDecoder().decode(EditorPick.self, from: Data(body.utf8)),
      pick.revision >= 0, pick.toolGeneration == toolGeneration
    else { return }
    onEditorPick?(pick)
  }

  private func receiveStockChange(_ message: WKScriptMessage) {
    guard state == .paused || state == .running,
      message.webView === view, message.frameInfo.isMainFrame,
      let url = message.frameInfo.request.url, url.isFileURL, let resourceDirectory,
      url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
        resourceDirectory.path + "/"),
      let body = message.body as? String, body.utf8.count <= 65_536,
      let update = try? JSONDecoder().decode(StockUpdate.self, from: Data(body.utf8)),
      update.revision > (latestStockUpdate?.revision ?? 0),
      update.revision <= 9_007_199_254_740_991, update.animals.count <= 80,
      Set(update.animals.map(\.id)).count == update.animals.count,
      update.animals.allSatisfy({
        !$0.id.isEmpty && !$0.species.isEmpty && ["fish", "shrimp", "snail"].contains($0.kind)
      })
    else { return }
    latestStockUpdate = update
    onStockChange?(update)
  }

  private func editorQuery(_ expression: String) async throws -> EditorSnapshot {
    let json = try await jsonQuery(expression)
    let response = try JSONDecoder().decode(EditorResponse.self, from: Data(json.utf8))
    if let error = response.error { throw EditorError.rejected(error) }
    guard let objects = response.objects, let placedObjects = response.placedObjects,
      let catalog = response.catalog, let equipmentObjects = response.equipmentObjects,
      let animals = response.animals, let stockCatalog = response.stockCatalog,
      let settings = response.settings, let stockRevision = response.stockRevision,
      stockRevision >= 0,
      stockRevision <= 9_007_199_254_740_991
    else { throw EditorError.invalidResponse }
    let snapshot = EditorSnapshot(
      revision: response.revision, stockRevision: stockRevision, settings: settings,
      objects: objects,
      placedObjects: placedObjects, catalog: catalog,
      equipmentObjects: equipmentObjects, animals: animals, stockCatalog: stockCatalog)
    if let latestStockUpdate, latestStockUpdate.revision > stockRevision {
      return snapshot.updatingStock(latestStockUpdate)
    }
    latestStockUpdate = StockUpdate(revision: stockRevision, animals: animals)
    return snapshot
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
      view.configuration.userContentController.removeScriptMessageHandler(
        forName: "idleScreenEditor")
      onEditorPick = nil
      view.configuration.userContentController.removeScriptMessageHandler(
        forName: "idleScreenStock")
      onStockChange = nil
      latestStockUpdate = nil
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
