import Foundation
import RAWMasterCore

public actor LocalComfyProvider: AIEditingProvider {
  private let runtime: ManagedRuntimeService
  private let outputDirectory: URL
  private var activeRun: String?
  private var cancelledRuns: Set<String> = []
  public init(runtime: ManagedRuntimeService, outputDirectory: URL) { self.runtime = runtime; self.outputDirectory = outputDirectory }
  public func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput {
    try Task.checkCancellation()
    guard attempt.submissionIntentAt != nil, attempt.state == .submitting else { throw AIServiceError.submissionIntentMissing }
    guard activeRun == nil else { throw AIServiceError.busy }
    if AIImageBytes.hasIntent(attempt: attempt, directory: outputDirectory) {
      if let output = try AIImageBytes.recover(request: request, attempt: attempt, directory: outputDirectory) { return output }
      throw AIServiceError.outcomeUnknown
    }
    guard request.profile.kind == .localComfy, request.profile.model == "Qwen-Image-2.1-Turbo", request.profile.experimental,
      request.profile.acceptedForUse, request.profile.configuration["licenseScope"] == "research-evaluation" else {
      throw AIServiceError.invalidConfiguration("本地 Qwen2.1 仅开放已接受研究/评估许可的实验配置")
    }
    let (input, mime) = try AIImageBytes.input(request)
    let decoder = request.profile.configuration["decoder"] ?? "stock"
    guard ["stock", "texture_fix"].contains(decoder) else { throw EditingError.invalidProfile }
    let resolution = Int(request.profile.configuration["resolution"] ?? "1024") ?? 0
    guard (512...2048).contains(resolution), resolution % 32 == 0 else { throw EditingError.invalidProfile }
    try AIImageBytes.prepareIntent(request: request, attempt: attempt, directory: outputDirectory)
    try Task.checkCancellation()
    _ = try await runtime.beginEdit(runID: attempt.runID); activeRun = attempt.runID
    var didSubmit = false
    defer { cancelledRuns.remove(attempt.runID) }
    do {
      let name = UUID().uuidString + (mime == "image/png" ? ".png" : ".jpg")
      let inputURL = try await runtime.inputURL(name: name)
      try input.write(to: inputURL, options: .withoutOverwriting)
      let graph: [String: Any] = [
        "1": ["class_type": "LoadImage", "inputs": ["image": name]],
        "2": ["class_type": "RAWMasterMLXEdit", "inputs": ["image": ["1", 0], "prompt": request.prompt,
          "seed": Int(request.configuration["seed"] ?? "20261030") ?? 20261030, "resolution": resolution, "decoder": decoder, "run_id": attempt.runID]],
        "3": ["class_type": "SaveImage", "inputs": ["images": ["2", 0], "filename_prefix": "RAWMaster/\(attempt.runID)"]]
      ]
      try Task.checkCancellation()
      didSubmit = true
      let submitted = try await runtime.call(path: "/prompt", method: "POST", body: ["prompt": graph, "client_id": attempt.runID])
      guard let json = try JSONSerialization.jsonObject(with: submitted.data) as? [String: Any], let remote = json["prompt_id"] as? String else { throw AIServiceError.invalidResponse }
      didSubmit = true
      progress(.init(state: .running, message: "Qwen2.1 Turbo / MLX q4 / 8步 / CFG1", remoteID: remote))
      for _ in 0..<3600 {
        try Task.checkCancellation()
        guard activeRun == attempt.runID, !cancelledRuns.contains(attempt.runID) else { throw CancellationError() }
        let response = try await runtime.call(path: "/history/\(remote)")
        if let history = try JSONSerialization.jsonObject(with: response.data) as? [String: Any], let record = history[remote] as? [String: Any] {
          guard let status = record["status"] as? [String: Any], status["status_str"] as? String == "success",
            let outputs = record["outputs"] as? [String: Any], let saved = outputs["3"] as? [String: Any],
            let images = saved["images"] as? [[String: Any]], let image = images.first,
            let filename = image["filename"] as? String, let subfolder = image["subfolder"] as? String,
            image["type"] as? String == "output" else { throw AIServiceError.runtimeUnavailable("本地任务未产生完整图像；worker将退出") }
          let url = try await runtime.outputURL(filename: filename, subfolder: subfolder)
          let data = try Data(contentsOf: url)
          var config = request.configuration
          config.merge(["model": request.profile.model, "quantization": "4", "steps": "8", "guidance": "1", "kvCache": "true", "decoder": decoder,
            "workflow": "rawmaster-comfy-mlx-v1", "resolution": String(resolution), "inputTransform": "ComfyLoadImage8bit;ImageOps.fit-Lanczos", "usage": "notApplicable"]) { _, new in new }
          if let node = outputs["2"] as? [String: Any], let texts = node["text"] as? [String], let text = texts.first,
            let receipt = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            for key in ["modelRevision", "modelIdentitySHA256", "decoderWeightsSHA256", "resampling", "referenceInputSHA256", "normalizedInputSHA256", "textEncoderSHA256", "runtimeID", "mfluxVersion", "workerSHA256", "nodeSHA256", "outputSHA256"] { if let value = receipt[key] as? String { config[key] = value } }
            for key in ["inputSize", "normalizedSize", "size", "sigmaSchedule", "transformerWeightSHA256"] { if let value = receipt[key], let json = try? JSONSerialization.data(withJSONObject: value), let text = String(data: json, encoding: .utf8) { config[key] = text } }
          }
          let output = try AIImageBytes.save(data, directory: outputDirectory, configuration: config, remoteID: remote, attempt: attempt)
          activeRun = nil; await runtime.endEdit(runID: attempt.runID)
          return output
        }
        try await Task.sleep(nanoseconds: 500_000_000)
      }
      throw AIServiceError.runtimeUnavailable("本地编辑超时")
    } catch {
      do { try await runtime.cancelEdit(runID: attempt.runID) } catch { activeRun = nil; await runtime.endEdit(runID: attempt.runID); throw AIServiceError.outcomeUnknown }
      activeRun = nil; await runtime.endEdit(runID: attempt.runID)
      if didSubmit, !(error is CancellationError) { throw AIServiceError.outcomeUnknown }
      throw error
    }
  }
  public func cancel(attempt: ProcessingAttempt) async throws {
    guard activeRun == attempt.runID else { return }
    cancelledRuns.insert(attempt.runID)
    try await runtime.cancelEdit(runID: attempt.runID)
  }
  public func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult {
    if let output = try AIImageBytes.recover(request: request, attempt: attempt, directory: outputDirectory) { return .completed(output) }
    if activeRun == attempt.runID { return .running(remoteID: attempt.remoteID) }
    guard try await runtime.recoverPreviousOwnership() else { return .unknown }
    if let recovered = try await runtime.recoveredOutput(attempt: attempt, directory: outputDirectory) { return .completed(recovered) }
    return .noResult
  }
}
