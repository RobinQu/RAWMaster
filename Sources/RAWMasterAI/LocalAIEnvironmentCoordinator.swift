import Foundation

public enum LocalAIModelStorage: Codable, Sendable, Equatable {
  case managed(URL), borrowedReadOnly(URL)
  public var root: URL { switch self { case .managed(let root), .borrowedReadOnly(let root): return root } }
  var readOnly: Bool { if case .borrowedReadOnly = self { return true }; return false }
}
public struct LocalAIModelConsent: Codable, Sendable, Equatable {
  public static let requiredLicenseID = "qwen-research-2026-09-20"
  public let licenseID: String
  public let licenseSHA256: String
  public let acceptedAt: Date
  public init(licenseID: String, licenseSHA256: String, acceptedAt: Date) {
    self.licenseID = licenseID; self.licenseSHA256 = licenseSHA256; self.acceptedAt = acceptedAt
  }
  public static func currentLicenseSHA256() throws -> String {
    try RuntimeArtifactFiles.hash(ManagedRuntimeService.resources.appendingPathComponent("ModelLicenses/Qwen2.1-LICENSE.txt"))
  }
  public static func currentLicenseText() throws -> String {
    let file = ManagedRuntimeService.resources.appendingPathComponent("ModelLicenses/Qwen2.1-LICENSE.txt")
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard (1...65_536).contains(size), let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw LocalAISetupError.consentRequired }
    return text
  }
  func validate() throws {
    guard licenseID == Self.requiredLicenseID, RuntimeArtifactFiles.validSHA(licenseSHA256),
          licenseSHA256 == (try Self.currentLicenseSHA256()), acceptedAt.timeIntervalSince1970.isFinite, acceptedAt <= Date() else { throw LocalAISetupError.consentRequired }
  }
}
public struct LocalAISetupRequest: Codable, Sendable, Equatable {
  public let artifactID: String
  public let modelStorage: LocalAIModelStorage
  public let includeTextureFix: Bool
  public let consent: LocalAIModelConsent?
  public init(artifactID: String, modelStorage: LocalAIModelStorage, includeTextureFix: Bool = false, consent: LocalAIModelConsent?) {
    self.artifactID = artifactID; self.modelStorage = modelStorage; self.includeTextureFix = includeTextureFix; self.consent = consent
  }
}
public struct LocalAIReady: Codable, Sendable {
  public let artifactID: String
  public let configuration: ManagedRuntimeConfiguration
  public let runtimeVersion: URL
  public let modelVerificationReceipt: URL
  public let healthValidated: Bool
}
public struct LocalAISetupSnapshot: Sendable {
  public let stage: String
  public let operationID: UUID?
  public let completedBytes: Int64?
  public let totalBytes: Int64?
  public let reusedBytes: Int64
  public let dependenciesReady: Bool
  public let modelsVerified: Bool
  public let healthValidated: Bool
  public let cancellable: Bool
  public let errorCode: String?
  public let message: String
  public init(stage: String = "idle", operationID: UUID? = nil, completedBytes: Int64? = nil, totalBytes: Int64? = nil,
              reusedBytes: Int64 = 0, dependenciesReady: Bool = false, modelsVerified: Bool = false,
              healthValidated: Bool = false, cancellable: Bool = false, errorCode: String? = nil, message: String = "本机 AI 尚未准备") {
    self.stage = stage; self.operationID = operationID; self.completedBytes = completedBytes; self.totalBytes = totalBytes
    self.reusedBytes = reusedBytes; self.dependenciesReady = dependenciesReady; self.modelsVerified = modelsVerified
    self.healthValidated = healthValidated; self.cancellable = cancellable; self.errorCode = errorCode; self.message = message
  }
}

private final class LocalAIProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var value: (String, Int64?, Int64?, Int64) = ("idle", nil, nil, 0)
  func set(_ stage: String, _ completed: Int64?, _ total: Int64?, reused: Int64? = nil) {
    lock.lock(); defer { lock.unlock() }; value = (stage, completed, total, reused ?? value.3)
  }
  func read() -> (String, Int64?, Int64?, Int64) { lock.lock(); defer { lock.unlock() }; return value }
}

/// App-owned, independent of photo focus and windows. Progress is a single copied value; callers
/// may inspect at UI cadence, without spawning a MainActor task for every downloaded chunk.
public actor LocalAIEnvironmentCoordinator {
  public nonisolated let runtime: ManagedRuntimeService
  private let catalog: RuntimeArtifactCatalog?
  private let runtimeRoot: URL
  private let progress = LocalAIProgress()
  private var task: Task<LocalAIReady, Error>?
  private var operationID: UUID?
  private var admissionClosed = false
  private var shuttingDown = false
  private var dependenciesReady = false, modelsVerified = false, healthValidated = false
  private var errorCode: String?
  private var message = "本机 AI 尚未准备"
  private var restoredJournal = false
  private struct Journal: Codable {
    let operationID: UUID
    let catalogSHA256: String
    let request: LocalAISetupRequest
    var stage: String
    var ready: LocalAIReady?
    var candidate: URL?
  }
  private var journalURL: URL { runtimeRoot.appendingPathComponent("preparation-journal.json") }

  public init(configuration: ManagedRuntimeConfiguration, catalog: RuntimeArtifactCatalog?) {
    runtime = ManagedRuntimeService(configuration: configuration)
    runtimeRoot = configuration.runtimeRoot.resolvingSymlinksInPath(); self.catalog = catalog
  }
  init(runtime: ManagedRuntimeService, configuration: ManagedRuntimeConfiguration, catalog: RuntimeArtifactCatalog?) {
    self.runtime = runtime; runtimeRoot = configuration.runtimeRoot.resolvingSymlinksInPath(); self.catalog = catalog
  }
  public func inspect() async -> LocalAISetupSnapshot {
    if !restoredJournal {
      restoredJournal = true
      if let data = try? Data(contentsOf: journalURL), data.count < 65_536,
         let old = try? JSONDecoder().decode(Journal.self, from: data) {
        operationID = old.operationID
        progress.set(old.stage == "ready" ? "needsVerification" : "interrupted", nil, nil)
        message = "发现上次准备记录；准备时将重新核对身份并复用已验证文件和断点"
      } else if catalog == nil { progress.set("unavailable", nil, nil); message = LocalAISetupError.unavailable.localizedDescription }
    }
    let value = progress.read()
    return .init(stage: value.0, operationID: operationID, completedBytes: value.1, totalBytes: value.2, reusedBytes: value.3,
                 dependenciesReady: dependenciesReady, modelsVerified: modelsVerified, healthValidated: healthValidated,
                 cancellable: task != nil && !admissionClosed, errorCode: errorCode, message: message)
  }
  public func prepare(_ request: LocalAISetupRequest) async throws -> LocalAIReady {
    guard !admissionClosed, !shuttingDown, task == nil else { throw AIServiceError.busy }
    guard let catalog else { throw LocalAISetupError.unavailable }
    guard let consent = request.consent else { throw LocalAISetupError.consentRequired }; try consent.validate()
    let artifact = try catalog.artifact(request.artifactID)
    let id = UUID(); operationID = id; restoredJournal = true
    dependenciesReady = false; modelsVerified = false; healthValidated = false; errorCode = nil
    progress.set("preflighting", nil, nil, reused: 0); message = "正在准备固定本机 AI 环境"
    let work = Task { try await self.perform(request, artifact: artifact, catalog: catalog, id: id) }
    task = work
    do {
      let result = try await work.value
      if operationID == id { task = nil }; return result
    } catch {
      if operationID == id {
        task = nil
        if progress.read().0 == "preflighting" {
          progress.set(Task.isCancelled ? "cancelled" : "failed", nil, nil)
          errorCode = error is CancellationError ? "cancelled" : "busy"
          message = "运行环境正在使用或准备已取消，请稍后重试"
        }
      }
      throw error
    }
  }
  public func cancelAndJoinPreparation() async {
    admissionClosed = true
    let current = task, id = operationID; current?.cancel()
    _ = try? await current?.value
    if operationID == id { task = nil }
    if !shuttingDown { admissionClosed = false }
  }
  public func shutdown() async {
    shuttingDown = true; admissionClosed = true; restoredJournal = true
    progress.set("shuttingDown", nil, nil)
    await runtime.closeAdmission() // Latch first: releasing an old preparation lease cannot reopen this instance.
    await cancelAndJoinPreparation()
    do {
      try await runtime.stop()
      progress.set("stopped", nil, nil); message = "准备任务与自有本机服务已停止"
    } catch {
      progress.set("shutdownNeedsVerification", nil, nil); errorCode = "shutdownJoinUnconfirmed"
      message = "环境已关闭新任务入口；停止结果需要核对"
    }
  }
  private func save(_ journal: Journal) throws {
    guard operationID == journal.operationID else { throw LocalAISetupError.operationRevoked }
    try RuntimeArtifactFiles.writeJSON(journal, to: journalURL)
  }
  private func perform(_ request: LocalAISetupRequest, artifact: RuntimeArtifact, catalog: RuntimeArtifactCatalog, id: UUID) async throws -> LocalAIReady {
    try Task.checkCancellation()
    let mutation = try await runtime.beginEnvironmentPreparation(operationID: id)
    let parent = runtimeRoot.appendingPathComponent("provisioning", isDirectory: true)
    let root = parent.appendingPathComponent(id.uuidString, isDirectory: true)
    var health: ManagedRuntimeService?, candidate: URL?, committed = false
    var journal = Journal(operationID: id, catalogSHA256: catalog.identitySHA256, request: request, stage: "preflighting", ready: nil, candidate: nil)
    do {
      try Task.checkCancellation()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard RuntimeArtifactFiles.pathIdentity(parent.resolvingSymlinksInPath()) == RuntimeArtifactFiles.pathIdentity(parent) else { throw LocalAISetupError.unsafeArtifact }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try RuntimeArtifactFiles.writeJSON(["operationID": id.uuidString], to: root.appendingPathComponent("owner.json"))
      try save(journal)
      let box = progress
      let package = try await RuntimeArtifactPreparation.prepare(artifact, catalog: catalog, operationRoot: root.appendingPathComponent("artifact")) { stage, bytes, total in box.set(stage, bytes, total) }
      journal.stage = "installing"; try save(journal); progress.set("installing", nil, nil)
      candidate = try await runtime.stageRuntime(package: package, artifact: artifact, mutation: mutation, log: root.appendingPathComponent("install-driver.log"))
      guard let candidate else { throw LocalAISetupError.preparationFailed }
      journal.candidate = candidate
      dependenciesReady = true
      journal.stage = request.modelStorage.readOnly ? "verifyingModels" : "preparingModels"; try save(journal)
      progress.set(journal.stage, nil, nil)
      let modelReceipt = runtimeRoot.appendingPathComponent("model-verifications", isDirectory: true).appendingPathComponent(id.uuidString + ".json")
      try FileManager.default.createDirectory(at: modelReceipt.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try await runtime.prepareModelsForCandidate(candidate, storage: request.modelStorage, includeTextureFix: request.includeTextureFix,
                                                 receipt: modelReceipt, mutation: mutation) { update in
        box.set(update.phase, update.completedBytes, update.totalBytes, reused: update.reusedBytes)
      }
      modelsVerified = true; journal.stage = "checkingHealth"; try save(journal); progress.set("checkingHealth", nil, nil)
      let healthRoot = root.appendingPathComponent("health", isDirectory: true)
      try FileManager.default.createDirectory(at: healthRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try FileManager.default.createSymbolicLink(at: healthRoot.appendingPathComponent("versions"), withDestinationURL: runtimeRoot.appendingPathComponent("versions"))
      try FileManager.default.createSymbolicLink(at: healthRoot.appendingPathComponent("active"), withDestinationURL: candidate)
      let probe = ManagedRuntimeService(configuration: .init(runtimeRoot: healthRoot, modelRoot: request.modelStorage.root))
      health = probe; _ = try await probe.start(); try Task.checkCancellation()
      let joinedHealth = try await probe.stopAfterPreparationHealth(); health = nil
      healthValidated = true; journal.stage = "committing"; try save(journal); progress.set("committing", nil, nil)
      let config = try await runtime.commitPreparedRuntime(candidate, modelRoot: request.modelStorage.root, mutation: mutation, health: joinedHealth)
      committed = true
      let ready = LocalAIReady(artifactID: artifact.id, configuration: config, runtimeVersion: candidate,
                               modelVerificationReceipt: modelReceipt, healthValidated: true)
      journal.stage = "ready"; journal.ready = ready; try save(journal)
      progress.set("ready", nil, nil); message = "依赖、模型与自有服务能力已校验；模型在首次编辑时载入"
      await runtime.endEnvironmentPreparation(mutation)
      try? cleanup(root, id: id)
      return ready
    } catch {
      if let health { try? await health.stop() }
      if let candidate, await runtime.preparedRuntimeIsActive(candidate, mutation: mutation) { committed = true }
      if !committed, let candidate { try? await runtime.discardPreparedRuntime(candidate, mutation: mutation) }
      if operationID == id {
        journal.stage = committed ? "needsVerification" : (Task.isCancelled ? "cancelled" : "failed")
        try? save(journal)
        errorCode = String(describing: error is CancellationError ? LocalAISetupError.operationRevoked : (error as? LocalAISetupError ?? .preparationFailed))
        progress.set(journal.stage, nil, nil)
        message = committed ? "已观察到激活；持久记录需要重新核对，不自动回滚" : "准备未完成；旧活动版本保留，已下载断点可复用"
      }
      await runtime.endEnvironmentPreparation(mutation)
      try? cleanup(root, id: id)
      throw error
    }
  }
  private func cleanup(_ root: URL, id: UUID) throws {
    guard operationID == id, root.lastPathComponent == id.uuidString,
          RuntimeArtifactFiles.pathIdentity(root.resolvingSymlinksInPath()) == RuntimeArtifactFiles.pathIdentity(root),
          let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("owner.json"))) as? [String: String],
          object["operationID"] == id.uuidString else { throw LocalAISetupError.operationRevoked }
    try FileManager.default.removeItem(at: root)
  }
}
