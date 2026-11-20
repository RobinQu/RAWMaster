import Foundation
import XCTest
import RAWMasterCore
@testable import RAWMasterAI

final class ManagedRuntimeIntegrationTests: XCTestCase {
  /// Opt-in real model test; default suite never starts Python/GPU or spends provider credits.
  func testOwnedComfyMLXRealEditUnloadAndCancellation() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let runtimePath = env["RAWMASTER_TEST_RUNTIME_ROOT"], let modelPath = env["RAWMASTER_TEST_MODEL_ROOT"],
      let inputPath = env["RAWMASTER_TEST_INPUT"], let evidencePath = env["RAWMASTER_TEST_EVIDENCE"] else { throw XCTSkip("Explicit isolated runtime/model/input paths required") }
    let directory = URL(fileURLWithPath: evidencePath)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = URL(fileURLWithPath: inputPath), bytes = try Data(contentsOf: input), meta = try AIImageBytes.metadata(bytes)
    let runtime = ManagedRuntimeService(configuration: .init(runtimeRoot: URL(fileURLWithPath: runtimePath), modelRoot: URL(fileURLWithPath: modelPath)), idleUnloadSeconds: 1)
    let provider = LocalComfyProvider(runtime: runtime, outputDirectory: directory)
    let endpoint = try await runtime.start()
    let denied = try await ProviderURLSessionTransport().send(URLRequest(url: endpoint.appendingPathComponent("rawmaster/health")))
    XCTAssertEqual(denied.status, 403)
    let source = EditingSourceSnapshot(projectID: "isolated-runtime-evaluation", assetID: "rendered-input", contentSHA256: AIImageBytes.hash(bytes), byteCount: Int64(bytes.count), admissionFingerprint: "test", sourceLocation: input)
    let artifact = RenderArtifact(sha256: AIImageBytes.hash(bytes), byteCount: Int64(bytes.count), pixelWidth: meta.width, pixelHeight: meta.height, encoding: meta.mime, bitDepth: meta.depth, colorSpace: "rendered-input", alphaPolicy: meta.alpha)
    let profile = AIProviderProfile(kind: .localComfy, displayName: "Local evaluation", model: "Qwen-Image-2.1-Turbo", endpoint: endpoint,
      capabilities: .init(capabilityID: "rawmaster-comfy-mlx-v1", supportsReferences: true, supportsCancellation: true), experimental: true, acceptedForUse: true,
      configuration: ["licenseScope": "research-evaluation", "decoder": env["RAWMASTER_TEST_DECODER"] ?? "stock", "resolution": "1024"])
    let request = AIEditRequest(workID: "w", inputVersionID: "v", source: source, inputFileURL: input, inputArtifact: artifact, recipe: .init(), profile: profile,
      prompt: "Subtle natural photographic enhancement. Preserve the exact subject count, composition and identity. Improve tonal balance gently.")
    var attempt = ProcessingAttempt(); attempt.state = .submitting; attempt.submissionIntentAt = Date()
    do {
      let output = try await provider.edit(request, attempt: attempt, progress: { _ in })
      XCTAssertTrue(FileManager.default.fileExists(atPath: output.fileURL.path)); XCTAssertGreaterThan(output.artifact.pixelWidth, 500)
      try JSONEncoder().encode(output).write(to: directory.appendingPathComponent("real-output.json"), options: .atomic)
      let loaded = try await runtime.call(path: "/rawmaster/health")
      let loadedJSON = try JSONSerialization.jsonObject(with: loaded.data) as! [String: Any]
      XCTAssertNotNil(loadedJSON["workerPID"] as? Int)
      try loaded.data.write(to: directory.appendingPathComponent("loaded-health.json"))
      try await Task.sleep(nanoseconds: 1_500_000_000)
      let unloaded = try await runtime.call(path: "/rawmaster/health")
      let unloadedJSON = try JSONSerialization.jsonObject(with: unloaded.data) as! [String: Any]
      XCTAssertTrue(unloadedJSON["workerPID"] is NSNull)
      try unloaded.data.write(to: directory.appendingPathComponent("unloaded-health.json"))
      var cancelled = ProcessingAttempt(); cancelled.state = .submitting; cancelled.submissionIntentAt = Date()
      let runningAttempt = cancelled
      let task = Task { try await provider.edit(request, attempt: runningAttempt, progress: { _ in }) }
      try await Task.sleep(nanoseconds: 3_000_000_000)
      try await provider.cancel(attempt: runningAttempt)
      task.cancel(); _ = try? await task.value
      let afterCancel = try await runtime.call(path: "/rawmaster/health")
      let cancelJSON = try JSONSerialization.jsonObject(with: afterCancel.data) as! [String: Any]
      XCTAssertTrue(cancelJSON["workerPID"] is NSNull)
      try afterCancel.data.write(to: directory.appendingPathComponent("cancelled-health.json"))
      try await runtime.stop()
      let finalStatus = await runtime.status()
      XCTAssertEqual(finalStatus.state, "stopped")
    } catch { try? await runtime.stop(); throw error }
  }
  func testCriticalPressureRefusesBeforeStartingAnyRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = ManagedRuntimeService(configuration: .init(runtimeRoot: root, modelRoot: root))
    await service.testingSetCriticalPressure(true)
    do { _ = try await service.beginEdit(runID: "pressure-fixture"); XCTFail("must refuse before startup") }
    catch AIServiceError.runtimeUnavailable(let message) { XCTAssertTrue(message.contains("内存压力")) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

}
