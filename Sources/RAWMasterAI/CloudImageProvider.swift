import Foundation
import RAWMasterCore

public struct ProviderHTTPResponse: Sendable {
  public let data: Data
  public let status: Int
  public let requestID: String?
  public init(data: Data, status: Int, requestID: String? = nil) { self.data = data; self.status = status; self.requestID = requestID }
}
public protocol ProviderHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> ProviderHTTPResponse }
private final class DenyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class ProviderURLSessionTransport: ProviderHTTPTransport, @unchecked Sendable {
  private let session: URLSession
  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 600; config.timeoutIntervalForResource = 660
    session = URLSession(configuration: config, delegate: DenyRedirects(), delegateQueue: nil)
  }
  public func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
    return ProviderHTTPResponse(data: data, status: response.statusCode,
      requestID: response.value(forHTTPHeaderField: "x-request-id") ?? response.value(forHTTPHeaderField: "x-tt-logid"))
  }
}

/// Explicit single-image adapters. No generated-image URL fetch, automatic POST retry or implicit cloud fallback.
public actor CloudImageProvider: AIEditingProvider {
  private let credentials: any ProviderCredentialStore
  private let outputDirectory: URL
  private let transport: any ProviderHTTPTransport
  private var flights: [String: Task<AIEditOutput, Error>] = [:]
  public init(credentials: any ProviderCredentialStore = KeychainCredentialStore(), outputDirectory: URL, transport: any ProviderHTTPTransport = ProviderURLSessionTransport()) {
    self.credentials = credentials; self.outputDirectory = outputDirectory; self.transport = transport
  }
  public func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput {
    try Task.checkCancellation()
    guard attempt.submissionIntentAt != nil, attempt.state == .submitting else { throw AIServiceError.submissionIntentMissing }
    guard flights[attempt.runID] == nil else { throw AIServiceError.busy }
    if AIImageBytes.hasIntent(attempt: attempt, directory: outputDirectory) {
      if let output = try AIImageBytes.recover(request: request, attempt: attempt, directory: outputDirectory) { return output }
      throw AIServiceError.outcomeUnknown
    }
    try ProviderDestination.validate(request.profile)
    guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.prompt.count <= 32000,
      let reference = request.profile.credentialReference else { throw AIServiceError.credentialUnavailable }
    let secret = try credentials.secret(reference: reference, for: request.profile)
    let urlRequest = try Self.makeRequest(request, secret: secret)
    try AIImageBytes.prepareIntent(request: request, attempt: attempt, directory: outputDirectory)
    let transport = self.transport, directory = outputDirectory
    try Task.checkCancellation()
    let task = Task<AIEditOutput, Error> {
      try Task.checkCancellation()
      progress(.init(state: .running, message: "已提交供应商；实际用量与费用待核对"))
      let response: ProviderHTTPResponse
      do { try Task.checkCancellation(); response = try await transport.send(urlRequest) }
      catch { throw AIServiceError.outcomeUnknown }
      guard (200..<300).contains(response.status) else {
        if response.status >= 500 || response.status == 408 || (300..<400).contains(response.status) { throw AIServiceError.outcomeUnknown }
        throw AIServiceError.providerRejected(response.status, "request_rejected")
      }
      guard response.data.count <= 140 * 1024 * 1024,
        let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw AIServiceError.outcomeUnknown }
      let remoteID = response.requestID ?? json["id"] as? String
      progress(.init(state: .archiving, message: "接收候选图像，待完整解码归档", remoteID: remoteID))
      let imageData: Data
      do { imageData = try Self.imageData(json, kind: request.profile.kind) }
      catch { throw AIServiceError.outcomeUnknown }
      var configuration = request.configuration
      configuration["provider"] = request.profile.kind.rawValue; configuration["model"] = request.profile.model
      configuration["endpoint"] = try ProviderDestination.canonical(request.profile.endpoint)
      configuration["capabilityID"] = request.profile.capabilities.capabilityID
      configuration["usage"] = "unknown"; configuration["fee"] = "unknown"
      if let actualModel = json["model"] as? String { configuration["actualModel"] = actualModel }
      do { return try AIImageBytes.save(imageData, directory: directory, configuration: configuration, remoteID: remoteID, attempt: attempt) }
      catch { throw AIServiceError.outcomeUnknown }
    }
    flights[attempt.runID] = task
    defer { flights.removeValue(forKey: attempt.runID) }
    return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }
  public func cancel(attempt: ProcessingAttempt) async throws {
    if let task = flights[attempt.runID] { task.cancel(); _ = try? await task.value }
    // Closing a connection cannot prove provider cancellation or absence of a charge.
    throw AIServiceError.outcomeUnknown
  }
  public func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult {
    if let output = try AIImageBytes.recover(request: request, attempt: attempt, directory: outputDirectory) { return .completed(output) }
    return .unknown
  }

  static func makeRequest(_ input: AIEditRequest, secret: String) throws -> URLRequest {
    let (bytes, mime) = try AIImageBytes.input(input)
    guard bytes.count <= 15 * 1024 * 1024 else { throw AIServiceError.invalidConfiguration("当前适配器输入上限为15 MiB") }
    let base64 = bytes.base64EncodedString(), profile = input.profile
    var body: [String: Any]
    var request = URLRequest(url: URL(string: try ProviderDestination.canonical(profile.endpoint))!)
    request.httpMethod = "POST"; request.timeoutInterval = 600
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    switch profile.kind {
    case .openAI:
      guard profile.capabilities.capabilityID == "openai-images-json-2026-10-30", profile.endpoint.path.hasSuffix("/images/edits") else { throw EditingError.invalidProfile }
      body = ["model": profile.model, "prompt": input.prompt, "images": [["image_url": "data:\(mime);base64,\(base64)"]], "n": 1, "output_format": "png", "background": "opaque"]
      for key in ["size", "quality"] { if let value = profile.configuration[key] { body[key] = value } }
      request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    case .seedream:
      guard profile.capabilities.capabilityID == "ark-images-json-2026-10-30", profile.endpoint.path.hasSuffix("/images/generations") else { throw EditingError.invalidProfile }
      body = ["model": profile.model, "prompt": input.prompt, "image": "data:\(mime);base64,\(base64)", "response_format": "b64_json", "sequential_image_generation": "disabled", "stream": false, "watermark": true]
      if let size = profile.configuration["size"] { body["size"] = size }
      request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    case .gemini:
      guard profile.capabilities.capabilityID == "gemini-interactions-2026-10-30", profile.endpoint.path.hasSuffix("/interactions") else { throw EditingError.invalidProfile }
      body = ["model": profile.model, "input": [["type": "text", "text": input.prompt], ["type": "image", "mime_type": mime, "data": base64]], "store": false]
      request.setValue(secret, forHTTPHeaderField: "x-goog-api-key")
    case .localComfy: throw EditingError.invalidProfile
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
  }
  static func imageData(_ json: [String: Any], kind: ProviderKind) throws -> Data {
    var encoded: String?
    if kind == .gemini {
      if let status = json["status"] as? String, status != "completed" { throw AIServiceError.outcomeUnknown }
      if let image = json["output_image"] as? [String: Any] { encoded = image["data"] as? String }
      if encoded == nil, let steps = json["steps"] as? [[String: Any]] {
        for step in steps where step["type"] as? String == "model_output" {
          for content in step["content"] as? [[String: Any]] ?? [] where content["type"] as? String == "image" { encoded = content["data"] as? String }
        }
      }
      if encoded == nil, let outputs = json["outputs"] as? [[String: Any]] { encoded = outputs.last { $0["type"] as? String == "image" }?["data"] as? String }
    } else {
      let images = json["data"] as? [[String: Any]]
      guard images?.count == 1 else { throw AIServiceError.invalidResponse }
      encoded = images?.first?["b64_json"] as? String
    }
    guard let encoded, encoded.count <= 140 * 1024 * 1024, let data = Data(base64Encoded: encoded), !data.isEmpty else { throw AIServiceError.invalidResponse }
    return data
  }
}
