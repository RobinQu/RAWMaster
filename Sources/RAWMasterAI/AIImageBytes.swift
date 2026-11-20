import CryptoKit
import Foundation
import RAWMasterCore

/// Header inspection records actual encoded precision; Imaging performs full decode/ICC validation before archive.
enum AIImageBytes {
  static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func input(_ request: AIEditRequest) throws -> (Data, String) {
    let data = try Data(contentsOf: request.inputFileURL, options: .mappedIfSafe)
    guard Int64(data.count) == request.inputArtifact.byteCount, hash(data) == request.inputArtifact.sha256 else { throw AIServiceError.inputChanged }
    let meta = try metadata(data)
    guard request.inputArtifact.pixelWidth == meta.width, request.inputArtifact.pixelHeight == meta.height,
      request.inputArtifact.bitDepth == meta.depth else { throw AIServiceError.inputChanged }
    if let max = request.profile.capabilities.maxInputPixels, meta.width * meta.height > max { throw AIServiceError.invalidConfiguration("输入像素超过此供应商配置限制") }
    return (data, meta.mime)
  }
  struct Metadata { let width: Int; let height: Int; let depth: Int; let alpha: ArtifactAlphaPolicy; let mime: String }
  static func metadata(_ data: Data) throws -> Metadata {
    let b = [UInt8](data)
    if b.count >= 33, Array(b[0..<8]) == [137,80,78,71,13,10,26,10], String(bytes: b[12..<16], encoding: .ascii) == "IHDR" {
      func n(_ start: Int) -> Int { b[start..<start+4].reduce(0) { ($0 << 8) | Int($1) } }
      let w = n(16), h = n(20), depth = Int(b[24]), color = b[25]
      guard w > 0, h > 0, w <= 65536, h <= 65536, [8,16].contains(depth), [0,2,4,6].contains(color) else { throw AIServiceError.unsupportedImage }
      return Metadata(width: w, height: h, depth: depth, alpha: [4,6].contains(color) ? .straight : .opaque, mime: "image/png")
    }
    if b.count > 4, b[0] == 255, b[1] == 216 {
      var index = 2
      while index+4 < b.count {
        guard b[index] == 255 else { throw AIServiceError.unsupportedImage }
        let marker = b[index+1]; index += 2
        if marker == 255 { index -= 1; continue }
        if marker == 216 || marker == 1 { continue }
        if marker == 217 || marker == 218 { break }
        let length = Int(b[index]) << 8 | Int(b[index+1])
        guard length >= 2, index + length <= b.count else { throw AIServiceError.unsupportedImage }
        if [192,193,194].contains(marker), length >= 8 {
          let h = Int(b[index+3]) << 8 | Int(b[index+4]), w = Int(b[index+5]) << 8 | Int(b[index+6])
          guard w > 0, h > 0 else { throw AIServiceError.unsupportedImage }
          return Metadata(width: w, height: h, depth: Int(b[index+2]), alpha: .opaque, mime: "image/jpeg")
        }
        index += length
      }
    }
    throw AIServiceError.unsupportedImage
  }
  private struct OutputIntent: Codable, Equatable {
    let requestFingerprint: String
    let attemptID: String
    let runID: String
  }
  private static func stem(_ attempt: ProcessingAttempt) -> String { hash(Data(attempt.runID.utf8)) }
  static func hasIntent(attempt: ProcessingAttempt, directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem(attempt) + ".intent.json").path)
  }
  private static func semanticFingerprint(_ request: AIEditRequest) throws -> String {
    var value = request
    value.source.sourceLocation = URL(fileURLWithPath: "/immutable-source")
    value.inputFileURL = URL(fileURLWithPath: "/immutable-rendered-input")
    value.inputArtifact.relativePath = "immutable-input"
    return try value.fingerprint
  }
  static func prepareIntent(request: AIEditRequest, attempt: ProcessingAttempt, directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let intent = OutputIntent(requestFingerprint: try semanticFingerprint(request), attemptID: attempt.id, runID: attempt.runID)
    let path = directory.appendingPathComponent(stem(attempt) + ".intent.json")
    if FileManager.default.fileExists(atPath: path.path) {
      guard try JSONDecoder().decode(OutputIntent.self, from: Data(contentsOf: path)) == intent else { throw EditingError.commandConflict }
    } else { try JSONEncoder().encode(intent).write(to: path, options: .withoutOverwriting) }
  }
  static func recover(request: AIEditRequest, attempt: ProcessingAttempt, directory: URL) throws -> AIEditOutput? {
    let path = directory.appendingPathComponent(stem(attempt) + ".intent.json")
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let intent = try JSONDecoder().decode(OutputIntent.self, from: Data(contentsOf: path))
    guard intent == (try OutputIntent(requestFingerprint: semanticFingerprint(request), attemptID: attempt.id, runID: attempt.runID)) else { throw EditingError.commandConflict }
    let receipt = directory.appendingPathComponent(stem(attempt) + ".receipt.json")
    if FileManager.default.fileExists(atPath: receipt.path) {
      var output = try JSONDecoder().decode(AIEditOutput.self, from: Data(contentsOf: receipt))
      guard [stem(attempt) + ".png", stem(attempt) + ".jpg"].contains(output.fileURL.lastPathComponent) else { throw EditingError.archiveMismatch }
      output.fileURL = directory.appendingPathComponent(output.fileURL.lastPathComponent)
      guard hash(try Data(contentsOf: output.fileURL)) == output.artifact.sha256 else { throw EditingError.archiveMismatch }
      return output
    }
    // Bytes are exclusively published only after complete write+fsync. A full disk may prevent the later receipt.
    for ext in ["png", "jpg"] {
      let output = directory.appendingPathComponent(stem(attempt)).appendingPathExtension(ext)
      if FileManager.default.fileExists(atPath: output.path) {
        return try save(Data(contentsOf: output), directory: directory, configuration: ["recovered": "durable-submit-intent", "model": request.profile.model], remoteID: attempt.remoteID, attempt: attempt)
      }
    }
    return nil
  }
  static func save(_ data: Data, directory: URL, configuration: [String: String], remoteID: String?, attempt: ProcessingAttempt? = nil) throws -> AIEditOutput {
    guard data.count <= 100 * 1024 * 1024 else { throw AIServiceError.invalidResponse }
    let meta = try metadata(data)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = attempt.map(Self.stem) ?? UUID().uuidString
    let path = directory.appendingPathComponent(stem).appendingPathExtension(meta.mime == "image/png" ? "png" : "jpg")
    if FileManager.default.fileExists(atPath: path.path) {
      guard hash(try Data(contentsOf: path)) == hash(data) else { throw EditingError.commandConflict }
    } else {
      let stage = directory.appendingPathComponent(".rawmaster-return-" + UUID().uuidString + ".partial")
      defer { try? FileManager.default.removeItem(at: stage) }
      try data.write(to: stage, options: .withoutOverwriting)
      let handle = try FileHandle(forWritingTo: stage); try handle.synchronize(); try handle.close()
      try FileManager.default.moveItem(at: stage, to: path)
    }
    let artifact = RenderArtifact(sha256: hash(data), byteCount: Int64(data.count), pixelWidth: meta.width, pixelHeight: meta.height,
      encoding: meta.mime, bitDepth: meta.depth, colorSpace: "unprofiled-provider-output", alphaPolicy: meta.alpha)
    let output = AIEditOutput(fileURL: path, artifact: artifact, configuration: configuration, remoteID: remoteID)
    if attempt != nil {
      // If this receipt cannot be written, the previously saved intent still identifies the complete bytes.
      try? JSONEncoder().encode(output).write(to: directory.appendingPathComponent(stem + ".receipt.json"), options: .atomic)
    }
    return output
  }
}
