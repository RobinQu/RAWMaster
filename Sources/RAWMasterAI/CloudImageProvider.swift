import Foundation
import CoreGraphics
import ImageIO
import RAWMasterCore

public struct ProviderHTTPResponse: Sendable {
  public let data: Data
  public let status: Int
  public let requestID: String?
  public init(data: Data, status: Int, requestID: String? = nil) { self.data = data; self.status = status; self.requestID = requestID }
}
public protocol ProviderHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> ProviderHTTPResponse }
private final class BoundedProviderResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let limit = 140 * 1024 * 1024
  private var data = Data()
  private var oversized = false
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var cancelled = false
  private var completion: CheckedContinuation<ProviderHTTPResponse, Error>?

  func send(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> ProviderHTTPResponse {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        lock.lock()
        self.completion = continuation
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { task.cancel() } else { task.resume() }
      }
    } onCancel: {
      self.lock.lock()
      self.cancelled = true
      let task = self.task
      self.lock.unlock()
      task?.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    oversized = response.expectedContentLength > limit
    completionHandler(oversized ? .cancel : .allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
    guard !oversized, bytes.count <= limit - data.count else { oversized = true; dataTask.cancel(); return }
    data.append(bytes)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let completion = self.completion
    self.completion = nil
    self.task = nil
    lock.unlock()
    defer { session.finishTasksAndInvalidate() }
    if oversized { completion?.resume(throwing: AIServiceError.invalidResponse); return }
    if let error { completion?.resume(throwing: error); return }
    guard let response = task.response as? HTTPURLResponse else { completion?.resume(throwing: AIServiceError.invalidResponse); return }
    completion?.resume(returning: ProviderHTTPResponse(data: data, status: response.statusCode,
      requestID: response.value(forHTTPHeaderField: "x-request-id") ?? response.value(forHTTPHeaderField: "x-tt-logid")))
  }
}

public final class ProviderURLSessionTransport: ProviderHTTPTransport, @unchecked Sendable {
  public init() {}
  public func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 600
    config.timeoutIntervalForResource = 660
    return try await BoundedProviderResponse().send(request, configuration: config)
  }
}

public enum Seedream55Adapter {
  public static let capabilityID = "rawmaster-seedream-5-5-261028-v1"
  public static let modelID = "doubao-seedream-5-5-261028"
  public static let endpoint = URL(string: "https://ark.cn-beijing.volces.com/api/v3/images/generations")!

  public static func matches(_ profile: AIProviderProfile) -> Bool {
    profile.kind == .seedream && profile.model == modelID && profile.capabilities.capabilityID == capabilityID &&
      (try? ProviderDestination.canonical(profile.endpoint)) == endpoint.absoluteString
  }

  static func size(_ request: AIEditRequest) throws -> (width: Int, height: Int, label: String) {
    let input = request.inputArtifact
    let size = request.configuration["size"] ?? request.profile.configuration["size"] ?? "\(input.pixelWidth)x\(input.pixelHeight)"
    let parts = size.split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
      (1...65536).contains(width), (1...65536).contains(height), size == "\(width)x\(height)",
      (921600...4624220).contains(width * height), width <= 16 * height, height <= 16 * width else {
      throw AIServiceError.invalidConfiguration("Seedream 5.5 需要明确的宽×高，921600 至 4624220 像素，宽高比 1:16 至 16:1")
    }
    return (width, height, size)
  }
}

// Proof is written before received bytes. A crash between the image and generic receipt must retain the actual model and usage.
struct QuickPromptProviderEvidence: Codable {
  let runID: String
  let attemptID: String
  let inputSHA256: String
  let outputSHA256: String
  let configuration: [String: String]
  let remoteID: String?

  static func url(_ directory: URL, _ attempt: ProcessingAttempt) -> URL {
    directory.appendingPathComponent(AIImageBytes.hash(Data(attempt.runID.utf8)) + ".provider.json")
  }

  static func save(_ data: Data, request: AIEditRequest, attempt: ProcessingAttempt, directory: URL,
                   configuration: [String: String], remoteID: String?) throws -> AIEditOutput {
    let proof = Self(runID: attempt.runID, attemptID: attempt.id, inputSHA256: request.inputArtifact.sha256,
                     outputSHA256: AIImageBytes.hash(data), configuration: configuration, remoteID: remoteID)
    let proofURL = url(directory, attempt)
    if FileManager.default.fileExists(atPath: proofURL.path) {
      let old = try JSONDecoder().decode(Self.self, from: Data(contentsOf: proofURL))
      guard old.runID == proof.runID, old.attemptID == proof.attemptID, old.inputSHA256 == proof.inputSHA256,
        old.outputSHA256 == proof.outputSHA256, old.configuration == configuration, old.remoteID == remoteID else { throw EditingError.archiveMismatch }
    } else {
      try JSONEncoder().encode(proof).write(to: proofURL, options: .atomic)
    }
    return try AIImageBytes.save(data, directory: directory, configuration: configuration, remoteID: remoteID, attempt: attempt)
  }

  static func recover(_ request: AIEditRequest, attempt: ProcessingAttempt, directory: URL) throws -> AIEditOutput? {
    guard var output = try AIImageBytes.recover(request: request, attempt: attempt, directory: directory) else { return nil }
    let proof = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url(directory, attempt)))
    guard proof.runID == attempt.runID, proof.attemptID == attempt.id, proof.inputSHA256 == request.inputArtifact.sha256,
      proof.outputSHA256 == output.artifact.sha256, proof.configuration["actualModel"] == request.profile.model,
      proof.configuration["capabilityID"] == request.profile.capabilities.capabilityID else { throw EditingError.archiveMismatch }
    let width: Int, height: Int
    if Seedream55Adapter.matches(request.profile) {
      let size = try Seedream55Adapter.size(request)
      width = size.width; height = size.height
      guard let remoteID = proof.remoteID, !remoteID.isEmpty else { throw EditingError.archiveMismatch }
    } else {
      width = request.inputArtifact.pixelWidth; height = request.inputArtifact.pixelHeight
      guard proof.configuration["modelRevision"] == LocalFluxProvider.modelRevision,
        proof.configuration["weightsRevision"] == LocalFluxProvider.weightsRevision,
        proof.configuration["runtimeRevision"] == LocalFluxProvider.runtimeRevision else { throw EditingError.archiveMismatch }
    }
    let receivedBytes = try output.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard proof.configuration["size"] == "\(width)x\(height)", output.artifact.pixelWidth == width, output.artifact.pixelHeight == height,
      output.artifact.bitDepth == 8, output.artifact.encoding == "image/png",
      output.artifact.byteCount == Int64(receivedBytes) else { throw EditingError.archiveMismatch }
    output.configuration = proof.configuration
    output.remoteID = proof.remoteID
    return output
  }

  static func validatePNG(_ data: Data, width: Int, height: Int) throws {
    guard (1...65536).contains(width), (1...65536).contains(height), width * height <= 36_000_000,
      data.count <= 100 * 1024 * 1024, data.suffix(8).elementsEqual([73,69,78,68,174,66,96,130]) else { throw AIServiceError.invalidResponse }
    let header = try AIImageBytes.metadata(data)
    guard header.mime == "image/png", header.depth == 8, header.width == width, header.height == height,
      let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
      CGImageSourceGetStatus(source) == .statusComplete,
      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      image.width == width, image.height == height, image.bitsPerComponent == 8, image.colorSpace?.model == .rgb,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw AIServiceError.invalidResponse }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    guard (properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else { throw AIServiceError.invalidResponse }
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: break
    default:
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      let opaque = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 }
      }
      guard opaque else { throw AIServiceError.invalidResponse }
    }
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
    var owner: ProviderAttemptLease?
    if Seedream55Adapter.matches(request.profile) {
      try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let path = outputDirectory.appendingPathComponent(AIImageBytes.hash(Data(attempt.runID.utf8)) + ".seedream-owner.lock")
      guard let lease = try ProviderAttemptLease.acquire(path) else { throw AIServiceError.outcomeUnknown }
      owner = lease
    }
    defer { owner?.close() }
    if AIImageBytes.hasIntent(attempt: attempt, directory: outputDirectory) {
      if let output = try Self.recover(request, attempt: attempt, directory: outputDirectory) { return output }
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
      do {
        if Seedream55Adapter.matches(request.profile) {
          let size = try Seedream55Adapter.size(request)
          guard let remoteID, !remoteID.isEmpty, remoteID.utf8.count <= 256,
            remoteID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            json["model"] as? String == Seedream55Adapter.modelID, json["error"] == nil,
            let item = (json["data"] as? [[String: Any]])?.first, item["error"] == nil,
            item["url"] == nil, item["size"] == nil || item["size"] as? String == size.label else { throw AIServiceError.invalidResponse }
          try QuickPromptProviderEvidence.validatePNG(imageData, width: size.width, height: size.height)
          if let usage = json["usage"] as? [String: Any] {
            for key in ["input_images", "generated_images", "output_tokens", "total_tokens"] {
              if let value = usage[key] as? Int, value >= 0 { configuration["usage." + key] = String(value) }
            }
            if let count = configuration["usage.generated_images"], count != "1" { throw AIServiceError.invalidResponse }
            if let count = configuration["usage.input_images"], count != "1" { throw AIServiceError.invalidResponse }
            if configuration.keys.contains(where: { $0.hasPrefix("usage.") }) { configuration["usage"] = "reported" }
          }
          configuration["size"] = size.label
          configuration["watermark"] = "false"
          configuration["background"] = "opaque"
          configuration["outputFormat"] = "png"
          return try QuickPromptProviderEvidence.save(imageData, request: request, attempt: attempt, directory: directory,
                                                      configuration: configuration, remoteID: remoteID)
        }
        return try AIImageBytes.save(imageData, directory: directory, configuration: configuration, remoteID: remoteID, attempt: attempt)
      } catch { throw AIServiceError.outcomeUnknown }
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
    if let output = try Self.recover(request, attempt: attempt, directory: outputDirectory) { return .completed(output) }
    return .unknown
  }

  private static func recover(_ request: AIEditRequest, attempt: ProcessingAttempt, directory: URL) throws -> AIEditOutput? {
    if Seedream55Adapter.matches(request.profile) {
      return try QuickPromptProviderEvidence.recover(request, attempt: attempt, directory: directory)
    }
    return try AIImageBytes.recover(request: request, attempt: attempt, directory: directory)
  }

  static func makeRequest(_ input: AIEditRequest, secret: String) throws -> URLRequest {
    let actualSize = try input.inputFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard actualSize <= 15 * 1024 * 1024 else { throw AIServiceError.invalidConfiguration("当前适配器输入上限为15 MiB") }
    guard input.inputArtifact.byteCount == Int64(actualSize) else { throw AIServiceError.inputChanged }
    let (bytes, mime) = try AIImageBytes.input(input)
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
      if profile.model.hasPrefix("doubao-seedream-5-5") || profile.capabilities.capabilityID == Seedream55Adapter.capabilityID {
        guard Seedream55Adapter.matches(profile) else { throw EditingError.invalidProfile }
        let width = input.inputArtifact.pixelWidth, height = input.inputArtifact.pixelHeight
        guard mime == "image/png", min(width, height) > 14, width <= height * 16, height <= width * 16 else { throw AIServiceError.unsupportedImage }
        try QuickPromptProviderEvidence.validatePNG(bytes, width: width, height: height)
        body = ["model": Seedream55Adapter.modelID, "prompt": input.prompt, "image": "data:image/png;base64,\(base64)",
                "size": try Seedream55Adapter.size(input).label, "response_format": "b64_json", "output_format": "png",
                "background": "opaque", "watermark": false]
      } else {
        guard profile.capabilities.capabilityID == "ark-images-json-2026-10-30", profile.endpoint.path.hasSuffix("/images/generations") else { throw EditingError.invalidProfile }
        body = ["model": profile.model, "prompt": input.prompt, "image": "data:\(mime);base64,\(base64)", "response_format": "b64_json", "sequential_image_generation": "disabled", "stream": false, "watermark": true]
        if let size = profile.configuration["size"] { body["size"] = size }
      }
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
