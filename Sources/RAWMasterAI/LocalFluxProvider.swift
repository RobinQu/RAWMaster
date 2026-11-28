import Darwin
import Foundation
import RAWMasterCore

/// Single, pinned Apple-Silicon MLX image-editing runtime. LocalComfy is the persisted local execution slot.
public actor LocalFluxProvider: AIEditingProvider {
  public static let capabilityID = "rawmaster-flux3-klein-mlx-v1"
  public static let modelID = "black-forest-labs/flux-3-image-klein"
  public static let modelRevision = "1755314e2216b2a2c5cc0dd899d4e49ee3404d2c"
  public static let weightsRevision = "d9790a1ceaba200e8b773fb236f7c9fa754283a7"
  public static let runtimeRevision = "rawmaster-flux-rust-mlx-v1"
  public static let legacyRuntimeRevisions = ["a8a400745949770d4de3b18c31684169da4b0af5"]

  private let outputDirectory: URL
  private var flights: [String: Task<AIEditOutput, Error>] = [:]

  public init(outputDirectory: URL) { self.outputDirectory = outputDirectory }

  public nonisolated static func matches(_ profile: AIProviderProfile) -> Bool {
    profile.kind == .localComfy && profile.model == modelID && profile.capabilities.capabilityID == capabilityID
  }

  public nonisolated static func weightsDirectory(_ profile: AIProviderProfile) -> URL {
    if let path = profile.configuration["weightsDirectory"], path.hasPrefix("/") {
      return URL(fileURLWithPath: path)
    }
    return FluxModelManager.defaultRoot
  }

  public nonisolated static func validateConfiguration(_ profile: AIProviderProfile) throws {
    guard matches(profile) else { throw AIServiceError.invalidConfiguration("请选择本机 FLUX.3 Klein 模型") }
    let fm = FileManager.default
    let root = weightsDirectory(profile)
    guard fm.isReadableFile(atPath: root.appendingPathComponent("q8/manifest.json").path),
      fm.isReadableFile(atPath: root.appendingPathComponent("vae-fp32/vae.safetensors").path),
      fm.isReadableFile(atPath: root.appendingPathComponent("assets/tokenizer.json").path) else {
      throw AIServiceError.runtimeUnavailable("本机 FLUX.3 Klein 模型尚未下载完整")
    }
    guard profile.acceptedForUse else { throw AIServiceError.invalidConfiguration("请先接受 FLUX Kommunity License 并启用本机模型") }
    guard workerExecutable(profile) != nil else { throw AIServiceError.runtimeUnavailable("本机 FLUX 执行器未安装") }
  }

  nonisolated static func workerExecutable(_ profile: AIProviderProfile) -> URL? {
    #if RAWMASTER_LOCAL_RAW_VALIDATION
    return nil
    #else
    let fm = FileManager.default
    var candidates: [URL] = []
    if let path = profile.configuration["workerExecutable"], path.hasPrefix("/") {
      candidates.append(URL(fileURLWithPath: path))
    }
    if let path = ProcessInfo.processInfo.environment["RAWMASTER_FLUX_WORKER"], path.hasPrefix("/") {
      candidates.append(URL(fileURLWithPath: path))
    }
    if let resources = Bundle.module.resourceURL {
      candidates.append(resources.appendingPathComponent("Resources/FluxWorker/flux-worker"))
    }
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appendingPathComponent("FluxWorker/flux-worker"))
    }
    let source = URL(fileURLWithPath: #filePath)
    let repo = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    candidates.append(repo.appendingPathComponent("Modules/FluxWorker/target/release/flux-worker"))
    return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    #endif
  }

  public func edit(_ request: AIEditRequest, attempt: ProcessingAttempt,
                   progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput {
    try Task.checkCancellation()
    guard attempt.submissionIntentAt != nil, attempt.state == .submitting else { throw AIServiceError.submissionIntentMissing }
    guard Self.matches(request.profile) else { throw EditingError.invalidProfile }
    let paths = LocalFluxFiles(outputDirectory, attempt)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard flights[attempt.runID] == nil, let owner = try ProviderAttemptLease.acquire(paths.owner) else { throw AIServiceError.busy }
    defer { owner.close() }
    if AIImageBytes.hasIntent(attempt: attempt, directory: outputDirectory) {
      if let result = try Self.recover(request, attempt: attempt, paths: paths) { return result }
      throw AIServiceError.outcomeUnknown
    }
    try Self.validateConfiguration(request.profile)
    let width = request.inputArtifact.pixelWidth, height = request.inputArtifact.pixelHeight
    guard [width,height].allSatisfy({ (64...4096).contains($0) && $0.isMultiple(of: 16) }),
      width * height <= 4_194_304, !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      request.prompt.count <= 32000, request.configuration["size"].map({ $0 == "\(width)x\(height)" }) ?? true else {
      throw AIServiceError.invalidConfiguration("FLUX 输入须为不超过 4 MP 的 16 像素对齐画幅，宽高 64–4096，并包含提示文字")
    }
    guard let seed = Int64(request.configuration["seed"] ?? "8521"), seed >= 0 else { throw AIServiceError.invalidConfiguration("FLUX 种子须为非负整数") }
    let actualSize = try request.inputFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard (1...15 * 1024 * 1024).contains(actualSize), request.inputArtifact.byteCount == Int64(actualSize) else { throw AIServiceError.invalidConfiguration("FLUX 输入上限为 15 MiB") }
    let (bytes, _) = try AIImageBytes.input(request)
    try QuickPromptProviderEvidence.validatePNG(bytes, width: width, height: height)
    try AIImageBytes.prepareIntent(request: request, attempt: attempt, directory: outputDirectory)
    if FileManager.default.fileExists(atPath: paths.cancel.path) { throw CancellationError() }
    let task = Task<AIEditOutput, Error> {
      try Self.prepare(request, seed: seed, bytes: bytes, paths: paths)
      do {
        progress(.init(state: .running, message: "本机正在校验固定 Q8 权重并生成候选"))
        try await Self.runWorker(request.profile, paths: paths)
        progress(.init(state: .archiving, message: "本机模型已释放，正在校验候选"))
        let result = try Self.publish(request, attempt: attempt, paths: paths)
        try? FileManager.default.removeItem(at: paths.scratch)
        return result
      } catch {
        // Retain a completed candidate if disk/receipt publication failed. Reconcile can finish without inference.
        if !FileManager.default.fileExists(atPath: paths.workerReceipt.path) { try? FileManager.default.removeItem(at: paths.scratch) }
        throw error
      }
    }
    flights[attempt.runID] = task
    defer { flights.removeValue(forKey: attempt.runID) }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  public func cancel(attempt: ProcessingAttempt) async throws {
    let paths = LocalFluxFiles(outputDirectory, attempt)
    guard FileManager.default.fileExists(atPath: outputDirectory.path) else { return }
    try Data().write(to: paths.cancel, options: .atomic)
    if let task = flights[attempt.runID] { task.cancel(); _ = await task.result }
    // Another controller or a surviving supervisor can still own the slot after a library is reopened.
    try await Task.detached {
      while try ProviderAttemptLease.held(paths.owner) || ProviderAttemptLease.held(paths.workerLock) {
        try await Task.sleep(for: .milliseconds(60))
      }
    }.value
  }

  public func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult {
    let paths = LocalFluxFiles(outputDirectory, attempt)
    guard Self.matches(request.profile) else { throw EditingError.invalidProfile }
    if flights[attempt.runID] != nil { return .running(remoteID: nil) }
    guard FileManager.default.fileExists(atPath: outputDirectory.path) else { return .noResult }
    guard let lease = try ProviderAttemptLease.acquire(paths.owner) else { return .running(remoteID: nil) }
    defer { lease.close() }
    if try ProviderAttemptLease.held(paths.workerLock) { return .running(remoteID: nil) }
    if let output = try Self.recover(request, attempt: attempt, paths: paths) { return .completed(output) }
    try? FileManager.default.removeItem(at: paths.scratch)
    return .noResult
  }

  private static func prepare(_ request: AIEditRequest, seed: Int64, bytes: Data, paths: LocalFluxFiles) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: paths.scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      let values: [String: Any] = ["prompt": request.prompt, "seed": seed, "width": request.inputArtifact.pixelWidth,
        "height": request.inputArtifact.pixelHeight, "weightsDirectory": weightsDirectory(request.profile).path]
      try bytes.write(to: paths.scratch.appendingPathComponent("input.png"), options: .withoutOverwriting)
      try JSONSerialization.data(withJSONObject: values).write(to: paths.scratch.appendingPathComponent("request.json"), options: .withoutOverwriting)
    } catch {
      try? fm.removeItem(at: paths.scratch)
      throw error
    }
  }

  private static func runWorker(_ profile: AIProviderProfile, paths: LocalFluxFiles) async throws {
    let fm = FileManager.default
    guard let worker = Self.workerExecutable(profile) else {
      throw AIServiceError.runtimeUnavailable("本机 FLUX 执行器未安装")
    }
    let process = Process()
    process.executableURL = worker
    process.currentDirectoryURL = paths.scratch
    process.arguments = ["--worker"]
    // Do not forward cloud credentials or unrelated user environment.
    var environment = ["PATH": "/usr/bin:/bin", "HOME": fm.homeDirectoryForCurrentUser.path,
      "TMPDIR": paths.scratch.path, "MLX_ENABLE_TF32": "0", "LC_ALL": "C"]
    if let metallib = Bundle.module.resourceURL?.appendingPathComponent("Resources/FluxWorker/mlx.metallib"),
       fm.isReadableFile(atPath: metallib.path) {
      environment["RAWMASTER_MLX_METALLIB"] = metallib.path
    }
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try Task.checkCancellation()
    if fm.fileExists(atPath: paths.cancel.path) { throw CancellationError() }
    try process.run()
    do {
      while process.isRunning { try await Task.sleep(for: .milliseconds(75)) }
    } catch {
      if process.isRunning { process.terminate() }
      await Task.detached { process.waitUntilExit() }.value
      throw error
    }
    switch process.terminationStatus {
    case 0: return
    case 75: throw AIServiceError.busy
    case 130: throw CancellationError()
    default: throw AIServiceError.runtimeUnavailable("FLUX 运行失败，请核对模型文件、可用内存或查看脱敏运行日志")
    }
  }

  private struct WorkerReceipt: Decodable {
    let runtimeRevision, weightsRevision, modelRevision, mlxVersion, rng, preset, outputSHA256: String
    let steps: Int, seed: Int64, elapsedSeconds: Double, pipelineSeconds: Double, peakMLXBytes: Int64
  }

  private static func recover(_ request: AIEditRequest, attempt: ProcessingAttempt, paths: LocalFluxFiles) throws -> AIEditOutput? {
    guard AIImageBytes.hasIntent(attempt: attempt, directory: paths.output) else { return nil }
    if let result = try QuickPromptProviderEvidence.recover(request, attempt: attempt, directory: paths.output) {
      try? FileManager.default.removeItem(at: paths.scratch)
      return result
    }
    if try !ProviderAttemptLease.held(paths.workerLock), FileManager.default.fileExists(atPath: paths.workerReceipt.path) {
      let result = try publish(request, attempt: attempt, paths: paths)
      try? FileManager.default.removeItem(at: paths.scratch)
      return result
    }
    return nil
  }

  private static func publish(_ request: AIEditRequest, attempt: ProcessingAttempt, paths: LocalFluxFiles) throws -> AIEditOutput {
    let receipt = try JSONDecoder().decode(WorkerReceipt.self, from: Data(contentsOf: paths.workerReceipt))
    let candidate = paths.scratch.appendingPathComponent("candidate.png")
    let byteCount = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard (1...100 * 1024 * 1024).contains(byteCount), receipt.modelRevision == modelRevision, receipt.weightsRevision == weightsRevision,
      receipt.runtimeRevision == runtimeRevision, receipt.mlxVersion == "0.32.2",
      receipt.rng == "chacha12+standardnormal+bf16", receipt.preset == "q8-16", receipt.steps == 16,
      receipt.seed == Int64(request.configuration["seed"] ?? "8521") else { throw AIServiceError.invalidResponse }
    let data = try Data(contentsOf: candidate, options: .mappedIfSafe)
    guard receipt.outputSHA256 == AIImageBytes.hash(data) else { throw EditingError.archiveMismatch }
    try QuickPromptProviderEvidence.validatePNG(data, width: request.inputArtifact.pixelWidth, height: request.inputArtifact.pixelHeight)
    var configuration = request.configuration
    configuration.merge(["provider": ProviderKind.localComfy.rawValue, "capabilityID": capabilityID, "actualModel": modelID, "model": modelID,
      "modelRevision": modelRevision, "weightsRevision": weightsRevision, "runtimeRevision": runtimeRevision, "mlxVersion": receipt.mlxVersion,
      "preset": receipt.preset, "steps": String(receipt.steps), "seed": String(receipt.seed), "rng": receipt.rng, "usage": "local",
      "pipelineSeconds": String(receipt.pipelineSeconds), "workerSeconds": String(receipt.elapsedSeconds),
      "peakMLXBytes": String(receipt.peakMLXBytes), "size": "\(request.inputArtifact.pixelWidth)x\(request.inputArtifact.pixelHeight)"]) { _, actual in actual }
    return try QuickPromptProviderEvidence.save(data, request: request, attempt: attempt, directory: paths.output, configuration: configuration, remoteID: nil)
  }
}

private struct LocalFluxFiles: Sendable {
  let output: URL, scratch: URL, owner: URL, cancel: URL
  var workerReceipt: URL { scratch.appendingPathComponent("worker-receipt.json") }
  var workerLock: URL { scratch.appendingPathComponent("worker.lock") }
  init(_ directory: URL, _ attempt: ProcessingAttempt) {
    output = directory
    let stem = AIImageBytes.hash(Data(attempt.runID.utf8))
    scratch = directory.appendingPathComponent(stem + ".fluxwork", isDirectory: true)
    owner = directory.appendingPathComponent(stem + ".flux-owner.lock")
    cancel = directory.appendingPathComponent(stem + ".cancel")
  }
}

struct ProviderAttemptLease {
  let descriptor: Int32

  static func acquire(_ path: URL) throws -> Self? {
    let fd = Darwin.open(path.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return Self(descriptor: fd) }
    let code = errno
    Darwin.close(fd)
    if code == EWOULDBLOCK { return nil }
    throw POSIXError(.init(rawValue: code) ?? .EIO)
  }

  static func held(_ path: URL) throws -> Bool {
    let fd = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd < 0 {
      if errno == ENOENT { return false }
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { _ = Darwin.close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
    if errno == EWOULDBLOCK { return true }
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
  }

  func close() { _ = Darwin.close(descriptor) }
}
