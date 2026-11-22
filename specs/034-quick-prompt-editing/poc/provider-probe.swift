import CryptoKit
import Darwin
import Foundation
import ImageIO
import RAWMasterCore
#if !RAWMASTER_INLINE_AI
import RAWMasterAI
#endif

private struct ProbeError: Error { let description: String; init(_ message: String) { description = message } }

private struct InMemoryCredential: ProviderCredentialStore {
  let value: String
  func secret(reference: String, for profile: AIProviderProfile) throws -> String {
    guard reference == "transient-ark", Seedream55Adapter.matches(profile), !value.isEmpty else { throw AIServiceError.credentialUnavailable }
    return value
  }
  func save(_ secret: String, for profile: AIProviderProfile) throws -> String { throw AIServiceError.credentialUnavailable }
  func delete(reference: String) throws {}
}

private actor SinglePOST: ProviderHTTPTransport {
  private let captured: ProviderHTTPResponse?
  private(set) var count = 0
  init(captured: ProviderHTTPResponse?) { self.captured = captured }
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    guard count == 0, request.url == Seedream55Adapter.endpoint else { throw ProbeError("重复提交或目标不符") }
    count += 1
    if let captured { return captured }
    return try await ProviderURLSessionTransport().send(request)
  }
}

@main private enum QuickPromptProviderProbe {
  static func main() async {
    do { try await run() }
    catch {
      let reason: String
      if let denied = error as? ProbeError { reason = denied.description }
      else if let service = error as? AIServiceError { reason = service.localizedDescription }
      else { reason = "请查看本机输入材料及任务输出目录" }
      FileHandle.standardError.write(Data(("验收失败，" + reason + "\n").utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    let args = CommandLine.arguments
    guard args.count == 5 || args.count == 6,
      ["flux", "seedream", "seedream-replay"].contains(args[1]),
      ["whole", "region", "both"].contains(args[4]) else {
      throw ProbeError("用法为 provider-probe flux|seedream|seedream-replay 输入目录 新输出目录 whole|region|both [FLUX环境根目录]")
    }
    let mode = args[1], fixtures = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
    let fm = FileManager.default
    let profile: AIProviderProfile
    var credential = InMemoryCredential(value: "offline-protocol-fixture")
    if mode == "flux" {
      guard args.count == 6 else { throw ProbeError("请指定已安装的 FLUX 环境根目录") }
      let root = URL(fileURLWithPath: args[5])
      profile = AIProviderProfile(id: "probe-flux", kind: .localComfy, displayName: "FLUX.3 Klein Q8", model: LocalFluxProvider.modelID,
        endpoint: URL(string: "http://127.0.0.1")!, capabilities: .init(capabilityID: LocalFluxProvider.capabilityID,
        supportsCancellation: true, supportsReconciliation: true), acceptedForUse: true, configuration: [
          "pythonExecutable": root.appendingPathComponent("venv/bin/python").path,
          "runtimeDirectory": root.appendingPathComponent("mlx").path,
          "weightsDirectory": root.appendingPathComponent("models/q8").path])
      try LocalFluxProvider.validateConfiguration(profile)
    } else {
      profile = AIProviderProfile(id: "probe-seedream", kind: .seedream, displayName: "Seedream 5.5", model: Seedream55Adapter.modelID,
        endpoint: Seedream55Adapter.endpoint, region: "cn-beijing", credentialReference: "transient-ark",
        capabilities: .init(capabilityID: Seedream55Adapter.capabilityID, supportsReconciliation: true), acceptedForUse: true)
      if mode == "seedream" {
        guard isatty(STDIN_FILENO) == 0, let raw = try FileHandle.standardInput.read(upToCount: 4097), (1...4096).contains(raw.count),
          let text = String(data: raw, encoding: .utf8) else { throw ProbeError("请通过受保护的标准输入传递已授权的方舟凭证") }
        let secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, secret.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
          throw ProbeError("标准输入中的凭证格式无效")
        }
        credential = InMemoryCredential(value: secret)
      }
    }
    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard mkdir(output.path, 0o700) == 0 else { throw ProbeError("输出目录须为新目录，已有尝试请核对原收据") }
    for scope in args[4] == "both" ? ["whole", "region"] : [args[4]] {
      let input: URL, prompt: String, capture: ProviderHTTPResponse?
      var expectedInputSHA: String?
      if mode == "flux" {
        let folder = fixtures.appendingPathComponent(scope == "region" ? "local" : "whole")
        input = folder.appendingPathComponent("input.png")
        prompt = try String(contentsOf: folder.appendingPathComponent("prompt.txt"), encoding: .utf8)
        capture = nil
      } else {
        input = fixtures.appendingPathComponent(scope + "-input.png")
        guard let source = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(scope + ".json"))) as? [String: Any],
          let frozenPrompt = source["prompt"] as? String else { throw ProbeError("未找到冻结的提示内容") }
        prompt = frozenPrompt
        expectedInputSHA = source["inputSHA256"] as? String
        guard expectedInputSHA != nil else { throw ProbeError("冻结输入缺少摘要") }
        if mode == "seedream-replay" {
          let bytes = try Data(contentsOf: fixtures.appendingPathComponent(scope + "-result.png"))
          guard let model = source["modelReturned"] as? String, let usage = source["usage"] as? [String: Any],
            let hash = source["outputSHA256"] as? String, hash == digest(bytes) else { throw ProbeError("既有实图与其收据不一致") }
          let payload: [String: Any] = ["model": model, "usage": usage, "data": [["b64_json": bytes.base64EncodedString()]]]
          capture = ProviderHTTPResponse(data: try JSONSerialization.data(withJSONObject: payload), status: 200,
                                         requestID: source["requestId"] as? String)
        } else { capture = nil }
      }
      let bytes = try Data(contentsOf: input), inputHash = digest(bytes)
      if let expectedInputSHA, expectedInputSHA != inputHash { throw ProbeError("冻结输入照片已改变") }
      guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
        let details = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = details[kCGImagePropertyPixelWidth] as? Int, let height = details[kCGImagePropertyPixelHeight] as? Int else {
        throw ProbeError("冻结输入图像无法解码")
      }
      let sourceRecord = EditingSourceSnapshot(projectID: "public-fixtures", assetID: scope, contentSHA256: inputHash,
        byteCount: Int64(bytes.count), admissionFingerprint: "spec034-probe", sourceLocation: input)
      let artifact = RenderArtifact(sha256: inputHash, byteCount: Int64(bytes.count), pixelWidth: width, pixelHeight: height,
        encoding: "image/png", bitDepth: 8, colorSpace: "sRGB", alphaPolicy: .opaque)
      let request = AIEditRequest(workID: "probe-" + scope, inputVersionID: "frozen", source: sourceRecord, inputFileURL: input,
        inputArtifact: artifact, recipe: .init(), profile: profile, prompt: prompt,
        configuration: mode == "flux" ? ["size": "\(width)x\(height)", "seed": "8521"] : ["size": "\(width)x\(height)"])
      var attempt = ProcessingAttempt()
      attempt.submissionIntentAt = Date()
      attempt.state = .submitting
      let directory = output.appendingPathComponent(scope + "-private", isDirectory: true)
      let transport = SinglePOST(captured: capture)
      func provider() -> any AIEditingProvider {
        if mode == "flux" { return LocalFluxProvider(outputDirectory: directory) }
        return CloudImageProvider(credentials: credential, outputDirectory: directory, transport: transport)
      }
      let started = ProcessInfo.processInfo.systemUptime
      let result = try await provider().edit(request, attempt: attempt, progress: { _ in })
      let seconds = ProcessInfo.processInfo.systemUptime - started
      guard case .completed(let restored) = try await provider().reconcile(request, attempt: attempt),
        restored.artifact == result.artifact, restored.configuration == result.configuration, restored.remoteID == result.remoteID else {
        throw ProbeError("重开后恢复的回执不一致")
      }
      let same = try await provider().edit(request, attempt: attempt, progress: { _ in })
      let calls = await transport.count
      guard same.artifact == result.artifact, calls == (mode == "flux" ? 0 : 1) else { throw ProbeError("重放同一尝试触发了新的模型请求") }
      let report: [String: Any] = ["mode": mode, "scope": scope, "elapsedSeconds": seconds, "calls": calls, "reconciled": true,
        "inputSHA256": inputHash, "promptSHA256": digest(Data(prompt.utf8)), "outputSHA256": result.artifact.sha256,
        "width": result.artifact.pixelWidth, "height": result.artifact.pixelHeight, "configuration": result.configuration,
        "candidate": directory.lastPathComponent + "/" + result.fileURL.lastPathComponent]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent(scope + ".json"), options: .atomic)
      print(scope, String(format: "%.3f s", seconds), "恢复通过")
    }
  }

  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
