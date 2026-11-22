import Darwin
import Foundation

public enum GroupPixelRenderer {
  struct Failure: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
  }

  static func helper() throws -> URL {
    let name = "rawmaster-group-render"
    var candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").appendingPathComponent(name)
    ]
    #if SWIFT_PACKAGE
      if let bundled = Bundle.module.url(forResource: name, withExtension: nil) {
        candidates.append(bundled)
      }
    #endif
    if let override = ProcessInfo.processInfo.environment["RAWMASTER_GROUP_RENDER_HELPER"] {
      candidates.insert(URL(fileURLWithPath: override), at: 0)
    }
    guard
      let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    else { throw Failure(detail: "找不到分组合成组件。") }
    return found
  }

  public static func render(_ request: GroupRenderRequest) async throws -> GroupRenderReceipt {
    try Task.checkCancellation()
    guard ["starTrail", "hdr", "panorama"].contains(request.operation), request.outputURL.isFileURL
    else { throw Failure(detail: "这项合成需要照片配方和本地暂存位置。") }
    let scratch = request.outputURL.deletingLastPathComponent()
      .appendingPathComponent(".pixels-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let input = scratch.appendingPathComponent("request.json")
    let receipt = scratch.appendingPathComponent("receipt.json")
    let diagnostic = scratch.appendingPathComponent("worker.log")
    try JSONEncoder().encode(request).write(to: input, options: .withoutOverwriting)
    try Data().write(to: diagnostic, options: .withoutOverwriting)
    let errors = try FileHandle(forWritingTo: diagnostic)
    defer { try? errors.close() }
    let child = Process()
    child.executableURL = try helper()
    child.arguments = [input.path, receipt.path]
    var environment = ProcessInfo.processInfo.environment
    environment["RAWMASTER_GROUP_SCRATCH"] = scratch.path
    child.environment = environment
    child.standardError = errors
    child.standardOutput = FileHandle.nullDevice
    try child.run()
    do {
      while child.isRunning { try await Task.sleep(for: .milliseconds(120)) }
      try Task.checkCancellation()
    } catch {
      if child.isRunning { child.terminate() }
      for _ in 0..<15 where child.isRunning {
        await Task.detached { try? await Task.sleep(for: .milliseconds(40)) }.value
      }
      if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
      child.waitUntilExit()
      throw error
    }
    guard child.terminationStatus == 0 else {
      let handle = try? FileHandle(forReadingFrom: diagnostic)
      defer { try? handle?.close() }
      let bytes = try? handle?.read(upToCount: 8192)
      let message = bytes.flatMap { String(data: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw Failure(detail: message?.isEmpty == false ? message! : "分组合成失败。")
    }
    let result = try JSONDecoder().decode(GroupRenderReceipt.self, from: Data(contentsOf: receipt))
    guard result.mediaKind == "derivedPhoto", result.format == "tiff32f",
      result.frameCount == 1, result.width > 0, result.height > 0
    else { throw Failure(detail: "分组母版格式或尺寸无效。") }
    return result
  }
}
