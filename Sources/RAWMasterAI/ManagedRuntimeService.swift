import CryptoKit
import Foundation
import Darwin
import RAWMasterCore

public struct ManagedRuntimeConfiguration: Codable, Sendable {
  public var runtimeRoot: URL
  public var modelRoot: URL
  public init(runtimeRoot: URL, modelRoot: URL) { self.runtimeRoot = runtimeRoot; self.modelRoot = modelRoot }
}

struct RuntimeActiveIdentity: Codable, Sendable, Equatable {
  let target: String?
  let device: UInt64
  let inode: UInt64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
}
struct RuntimeEnvironmentMutation: Sendable {
  let operationID: UUID
  let expectedActive: RuntimeActiveIdentity
}
struct RuntimeJoinedHealth: Sendable {
  let candidate: URL
  let modelRoot: URL
  let joinedPID: Int32
  fileprivate init(candidate: URL, modelRoot: URL, joinedPID: Int32) {
    self.candidate = candidate; self.modelRoot = modelRoot; self.joinedPID = joinedPID
  }
}

extension ManagedRuntimeService {
  /// Reserve admission before the first await. The root lock spans extraction, install, model
  /// verification, candidate health/actual join and commit; it is never a per-substep lock.
  func beginEnvironmentPreparation(operationID: UUID) async throws -> RuntimeEnvironmentMutation {
    try requireOpenAdmission(); try Task.checkCancellation()
    guard environmentMutationID == nil, !installing, !editing, state != "starting" else { throw AIServiceError.busy }
    environmentMutationID = operationID
    do {
      try await stopOwnedRuntime()
      try requireOpenAdmission(); try Task.checkCancellation()
      preparationFileLease = try RuntimeEnvironmentFileLease(root: configuration.runtimeRoot)
      preparationCandidates = []
      preparedModelReceipts = [:]
      return .init(operationID: operationID, expectedActive: try activeIdentity())
    } catch {
      environmentMutationID = nil; preparationFileLease = nil; throw error
    }
  }
  func endEnvironmentPreparation(_ mutation: RuntimeEnvironmentMutation) {
    guard environmentMutationID == mutation.operationID else { return }
    preparationCandidates = []; preparedModelReceipts = [:]; preparationFileLease = nil; environmentMutationID = nil
  }
  private func require(_ mutation: RuntimeEnvironmentMutation) throws {
    guard environmentMutationID == mutation.operationID, preparationFileLease != nil else { throw LocalAISetupError.operationRevoked }
  }
  func closeAdmission() { admissionPermanentlyClosed = true }
  private func requireOpenAdmission() throws {
    guard !admissionPermanentlyClosed else { throw LocalAISetupError.operationRevoked }
  }
  private func requireNewWork(_ mutation: RuntimeEnvironmentMutation) throws {
    try require(mutation); try requireOpenAdmission()
  }
  private func activeIdentity() throws -> RuntimeActiveIdentity {
    let path = configuration.runtimeRoot.appendingPathComponent("active")
    var value = stat()
    if lstat(path.path, &value) != 0 {
      guard errno == ENOENT else { throw LocalAISetupError.unsafeArtifact }
      return .init(target: nil, device: 0, inode: 0, modifiedSeconds: 0, modifiedNanoseconds: 0)
    }
    guard value.st_mode & S_IFMT == S_IFLNK else { throw LocalAISetupError.unsafeArtifact }
    let target = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
    let versions = configuration.runtimeRoot.appendingPathComponent("versions").resolvingSymlinksInPath().path + "/"
    guard path.resolvingSymlinksInPath().path.hasPrefix(versions) else { throw LocalAISetupError.unsafeArtifact }
    return .init(target: target, device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
                 modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
  }
  func stageRuntime(package: URL, artifact: RuntimeArtifact, mutation: RuntimeEnvironmentMutation, log: URL) async throws -> URL {
    try requireNewWork(mutation); try Task.checkCancellation()
    let name = artifact.id + "-" + mutation.operationID.uuidString
    let versions = configuration.runtimeRoot.resolvingSymlinksInPath().appendingPathComponent("versions")
    if FileManager.default.fileExists(atPath: versions.path) {
      guard RuntimeArtifactFiles.pathIdentity(versions.resolvingSymlinksInPath()) == RuntimeArtifactFiles.pathIdentity(versions) else { throw LocalAISetupError.unsafeArtifact }
    }
    let candidate = versions.appendingPathComponent(name)
    preparationCandidates.insert(candidate)
    // Only the app's new installer is executable here. The archive's old copy is inert data.
    do { try await RuntimeArtifactFiles.run(package.appendingPathComponent("python/bin/python3.12"), arguments: ["-B",
      Self.resources.appendingPathComponent("install_runtime.py").path, "--package", package.path,
      "--destination", configuration.runtimeRoot.path, "--defer-activate", "--candidate-name", name,
      "--operation-id", mutation.operationID.uuidString, "--owner-pid", String(ProcessInfo.processInfo.processIdentifier)], log: log,
      environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": log.deletingLastPathComponent().path, "PYTHONDONTWRITEBYTECODE": "1"])
    try requireNewWork(mutation); try Task.checkCancellation()
    let data = try Data(contentsOf: candidate.appendingPathComponent("receipt.json"))
    guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          receipt["id"] as? String == artifact.id, receipt["operationID"] as? String == mutation.operationID.uuidString,
          receipt["deferredActivation"] as? Bool == true, receipt["nodeHealth"] as? Bool == true,
          receipt["mlxOperatorHealth"] as? Bool == true else { throw LocalAISetupError.preparationFailed }
    guard try RuntimeArtifactFiles.hash(candidate.appendingPathComponent("resources/model-identity.json")) == RuntimeArtifactFiles.hash(Self.resources.appendingPathComponent("model-identity.json")) else { throw LocalAISetupError.modelMismatch }
    return candidate
    } catch { try? discardPreparedRuntime(candidate, mutation: mutation); throw error }
  }
  func prepareModelsForCandidate(_ candidate: URL, storage: LocalAIModelStorage, includeTextureFix: Bool, receipt: URL,
                                mutation: RuntimeEnvironmentMutation, progress: @escaping @Sendable (ManagedModelProgress) -> Void) async throws {
    try requireNewWork(mutation); guard preparationCandidates.contains(candidate) else { throw LocalAISetupError.operationRevoked }
    try Task.checkCancellation()
    let child = Process(), pipe = Pipe()
    child.executableURL = candidate.appendingPathComponent("python/bin/python3.12")
    child.arguments = ["-B", Self.resources.appendingPathComponent("prepare_models.py").path,
      "--manifest", Self.resources.appendingPathComponent("model-identity.json").path,
      "--model-root", storage.root.path, "--receipt", receipt.path,
      "--owner-pid", String(ProcessInfo.processInfo.processIdentifier)] + (storage.readOnly ? ["--read-only"] : []) + (includeTextureFix ? ["--texture-fix"] : [])
    child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": receipt.deletingLastPathComponent().path, "PYTHONDONTWRITEBYTECODE": "1"]
    let fd = Darwin.open(receipt.deletingPathExtension().appendingPathExtension("log").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LocalAISetupError.unsafeArtifact }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
    child.standardOutput = pipe; child.standardError = handle; try child.run()
    try await withTaskCancellationHandler(operation: {
      let reader = Task.detached {
        var buffer = Data()
        do {
          while let bytes = try pipe.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {
            buffer.append(bytes)
            guard buffer.count <= 65_536 else { throw LocalAISetupError.preparationFailed }
            while let newline = buffer.firstIndex(of: 10) {
              let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
              guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let phase = object["phase"] as? String, phase.utf8.count <= 64 else { throw LocalAISetupError.preparationFailed }
              progress(.init(phase: phase, completedBytes: (object["completedBytes"] as? NSNumber)?.int64Value ?? 0,
                totalBytes: (object["totalBytes"] as? NSNumber)?.int64Value ?? 0, message: "",
                reusedBytes: (object["reusedBytes"] as? NSNumber)?.int64Value))
            }
          }
          child.waitUntilExit()
        } catch {
          if child.isRunning { child.terminate() }; child.waitUntilExit(); throw error
        }
      }
      try await reader.value
      try Task.checkCancellation()
      guard child.terminationStatus == 0 else { throw LocalAISetupError.modelMismatch }
    }, onCancel: { if child.isRunning { child.terminate() } })
    try requireNewWork(mutation)
    let data = try Data(contentsOf: receipt)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["verified"] as? Bool == true,
          object["identitySHA256"] as? String == (try RuntimeArtifactFiles.hash(Self.resources.appendingPathComponent("model-identity.json"))),
          object["readOnly"] as? Bool == storage.readOnly else { throw LocalAISetupError.modelMismatch }
    preparedModelReceipts[candidate] = (storage.root.resolvingSymlinksInPath(), receipt, RuntimeArtifactFiles.digest(data))
  }
  func stopAfterPreparationHealth() async throws -> RuntimeJoinedHealth {
    guard state == "ready", let child = process, child.isRunning else { throw LocalAISetupError.preparationFailed }
    try await health()
    let version = configuration.runtimeRoot.appendingPathComponent("active").resolvingSymlinksInPath()
    let model = configuration.modelRoot.resolvingSymlinksInPath(), pid = child.processIdentifier
    try await stopOwnedRuntime()
    guard process == nil, endpoint == nil, token == nil else { throw EditingError.workerNotJoined }
    return .init(candidate: version, modelRoot: model, joinedPID: pid)
  }
  func commitPreparedRuntime(_ candidate: URL, modelRoot: URL, mutation: RuntimeEnvironmentMutation, health: RuntimeJoinedHealth? = nil) throws -> ManagedRuntimeConfiguration {
    try requireNewWork(mutation); try Task.checkCancellation()
    guard preparationCandidates.contains(candidate), try activeIdentity() == mutation.expectedActive else { throw LocalAISetupError.activeChanged }
    guard let health, RuntimeArtifactFiles.pathIdentity(health.candidate) == RuntimeArtifactFiles.pathIdentity(candidate), RuntimeArtifactFiles.pathIdentity(health.modelRoot) == RuntimeArtifactFiles.pathIdentity(modelRoot.resolvingSymlinksInPath()), health.joinedPID > 0,
          let model = preparedModelReceipts[candidate], RuntimeArtifactFiles.pathIdentity(model.root) == RuntimeArtifactFiles.pathIdentity(modelRoot.resolvingSymlinksInPath()),
          try RuntimeArtifactFiles.hash(model.receipt) == model.sha256 else { throw LocalAISetupError.preparationFailed }
    let canonical = candidate.resolvingSymlinksInPath()
    let versions = configuration.runtimeRoot.appendingPathComponent("versions").resolvingSymlinksInPath()
    guard RuntimeArtifactFiles.pathIdentity(canonical.deletingLastPathComponent()) == RuntimeArtifactFiles.pathIdentity(versions),
          let owner = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate.appendingPathComponent("preparation-owner.json"))) as? [String: String],
          owner["operationID"] == mutation.operationID.uuidString else { throw LocalAISetupError.operationRevoked }
    let pointer = configuration.runtimeRoot.appendingPathComponent("active-" + mutation.operationID.uuidString)
    try FileManager.default.createSymbolicLink(atPath: pointer.path, withDestinationPath: "versions/" + candidate.lastPathComponent)
    defer { try? FileManager.default.removeItem(at: pointer) }
    // All legitimate mutators hold the same root flock; check+rename is one non-suspending actor
    // turn. Never rollback in catch: a later operation may already own the active pointer.
    try Task.checkCancellation()
    guard try activeIdentity() == mutation.expectedActive, rename(pointer.path, configuration.runtimeRoot.appendingPathComponent("active").path) == 0 else { throw LocalAISetupError.activeChanged }
    configuration.modelRoot = modelRoot.resolvingSymlinksInPath()
    state = "installed"; message = "环境准备完成，服务按需启动"
    let root = Darwin.open(configuration.runtimeRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if root >= 0 { _ = fsync(root); Darwin.close(root) }
    return configuration
  }
  func discardPreparedRuntime(_ candidate: URL, mutation: RuntimeEnvironmentMutation) throws {
    try require(mutation)
    guard preparationCandidates.contains(candidate), RuntimeArtifactFiles.pathIdentity(candidate.resolvingSymlinksInPath()) == RuntimeArtifactFiles.pathIdentity(candidate),
          candidate.lastPathComponent.hasSuffix(mutation.operationID.uuidString),
          RuntimeArtifactFiles.pathIdentity(configuration.runtimeRoot.appendingPathComponent("active").resolvingSymlinksInPath()) != RuntimeArtifactFiles.pathIdentity(candidate) else { return }
    guard let data = try? Data(contentsOf: candidate.appendingPathComponent("preparation-owner.json")),
          let owner = try JSONSerialization.jsonObject(with: data) as? [String: String], owner["operationID"] == mutation.operationID.uuidString else { return }
    try FileManager.default.removeItem(at: candidate)
  }
  func preparedRuntimeIsActive(_ candidate: URL, mutation: RuntimeEnvironmentMutation) -> Bool {
    environmentMutationID == mutation.operationID && RuntimeArtifactFiles.pathIdentity(configuration.runtimeRoot.appendingPathComponent("active").resolvingSymlinksInPath()) == RuntimeArtifactFiles.pathIdentity(candidate)
  }
}
public struct ManagedRuntimeStatus: Sendable {
  public let state: String
  public let message: String
  public let endpoint: URL?
}
public actor ManagedRuntimeService {
  private var configuration: ManagedRuntimeConfiguration
  private let transport: any ProviderHTTPTransport
  private var admissionPermanentlyClosed = false
  private var environmentMutationID: UUID?
  private var preparationFileLease: RuntimeEnvironmentFileLease?
  private var runtimeUseLease: RuntimeEnvironmentFileLease?
  private var preparationCandidates: Set<URL> = []
  private var preparedModelReceipts: [URL: (root: URL, receipt: URL, sha256: String)] = [:]
  private var process: Process?
  private var logHandle: FileHandle?
  private var token: String?
  private var runRoot: URL?
  private var endpoint: URL?
  private var installing = false
  private var idleTask: Task<Void, Never>?
  private var pressureMonitor: RuntimePressureMonitor?
  private var criticalPressure = false
  private let idleUnloadSeconds: Double
  private var editing = false
  private var activeLease: String?
  private struct Ownership: Codable {
    let pid: Int32
    let endpoint: URL
    let token: String
    let executable: URL
    let runRoot: URL
    let workerScript: URL
  }
  private var recoveredOwnership: Ownership?
  private var ownershipURL: URL { configuration.runtimeRoot.appendingPathComponent("last-owned-run.json") }
  private var state = "stopped"
  private var message = "本地运行时尚未启动"
  public init(configuration: ManagedRuntimeConfiguration, idleUnloadSeconds: Double = 120) { self.configuration = configuration; self.transport = ProviderURLSessionTransport(); self.idleUnloadSeconds = max(0.05, idleUnloadSeconds) }
  public func status() -> ManagedRuntimeStatus {
    if let process, !process.isRunning { return .init(state: "failed", message: "本地服务已退出，可重新启动", endpoint: nil) }
    return .init(state: state, message: message, endpoint: endpoint)
  }
  public func configurationSnapshot() -> ManagedRuntimeConfiguration { configuration }
  public func updateConfiguration(_ value: ManagedRuntimeConfiguration) throws {
    try requireOpenAdmission()
    guard environmentMutationID == nil, !installing, !editing, process?.isRunning != true else { throw AIServiceError.busy }
    guard RuntimeArtifactFiles.pathIdentity(value.runtimeRoot.resolvingSymlinksInPath()) == RuntimeArtifactFiles.pathIdentity(configuration.runtimeRoot.resolvingSymlinksInPath()) else {
      throw AIServiceError.invalidConfiguration("更换运行目录前须关闭并 join 旧应用环境，再创建新协调器")
    }
    let admission = try RuntimeEnvironmentFileLease(root: configuration.runtimeRoot)
    defer { withExtendedLifetime(admission) {} }
    configuration = value
  }
  public func install(package: URL) async throws {
    try requireOpenAdmission()
    guard environmentMutationID == nil, !installing, process?.isRunning != true, !editing else { throw AIServiceError.busy }
    let admission = try RuntimeEnvironmentFileLease(root: configuration.runtimeRoot)
    defer { withExtendedLifetime(admission) {} }
    installing = true; state = "installing"; message = "校验离线包并安装固定依赖"
    defer { installing = false }
    let python = package.appendingPathComponent("python/bin/python3.12")
    let script = Self.resources.appendingPathComponent("install_runtime.py")
    let root = configuration.runtimeRoot
    do {
      try await Self.runProcess(executable: python, arguments: ["-B", script.path, "--package", package.path, "--destination", root.path], log: root.appendingPathComponent("install-driver.log"))
      state = "installed"; message = "离线依赖与节点健康检查通过；真实模型验收另行进行"
    } catch { state = "failed"; message = "安装失败，旧活动版本保留"; throw error }
  }
  public func start() async throws -> URL {
    try requireOpenAdmission()
    guard environmentMutationID == nil else { throw AIServiceError.busy }
    if let process, process.isRunning, let endpoint { try await health(); return endpoint }
    guard !installing, state != "starting" else { throw AIServiceError.busy }
    let admission = try RuntimeEnvironmentFileLease(root: configuration.runtimeRoot)
    defer { withExtendedLifetime(admission) {} }
    if FileManager.default.fileExists(atPath: ownershipURL.path) { guard try await recoverPreviousOwnership() else { throw EditingError.workerNotJoined } }
    try requireOpenAdmission()
    let active = configuration.runtimeRoot.appendingPathComponent("active").resolvingSymlinksInPath()
    let versions = configuration.runtimeRoot.appendingPathComponent("versions").resolvingSymlinksInPath().path + "/"
    guard active.path.hasPrefix(versions), FileManager.default.fileExists(atPath: active.appendingPathComponent("receipt.json").path),
      FileManager.default.isExecutableFile(atPath: active.appendingPathComponent(".venv/bin/python").path),
      FileManager.default.isExecutableFile(atPath: active.appendingPathComponent(".mlx/bin/python").path) else { throw AIServiceError.runtimeUnavailable("请先安装完整离线 Comfy / MLX 运行时包") }
    if pressureMonitor == nil { pressureMonitor = RuntimePressureMonitor { [weak self] critical in Task { await self?.memoryPressureChanged(critical: critical) } } }
    state = "starting"; message = "启动自有 loopback 服务并核对身份"
    let root = configuration.runtimeRoot.appendingPathComponent("runs").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["custom_nodes", "input", "output", "user", "temp"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
    let resources = active.appendingPathComponent("resources")
    let yaml = "rawmaster:\n  base_path: \"\(resources.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\n  custom_nodes: custom_nodes\n"
    try yaml.write(to: root.appendingPathComponent("paths.yaml"), atomically: true, encoding: .utf8)
    let port = Int.random(in: 20000...60000)
    let address = URL(string: "http://127.0.0.1:\(port)")!
    let ownership = UUID().uuidString + UUID().uuidString
    let child = Process(); child.executableURL = active.appendingPathComponent(".venv/bin/python")
    child.arguments = [active.appendingPathComponent("ComfyUI/main.py").path, "--listen", "127.0.0.1", "--port", String(port), "--base-directory", root.path,
      "--models-directory", configuration.modelRoot.path, "--extra-model-paths-config", root.appendingPathComponent("paths.yaml").path,
      "--disable-all-custom-nodes", "--whitelist-custom-nodes", "rawmaster_mlx", "--offline", "--cpu", "--cache-none", "--disable-auto-launch"]
    child.currentDirectoryURL = active.appendingPathComponent("ComfyUI")
    let home = configuration.runtimeRoot.appendingPathComponent("private-home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "LANG": "en_US.UTF-8"]
    environment.merge(["RAWMASTER_RUN_ROOT": root.path, "RAWMASTER_MODEL_ROOT": configuration.modelRoot.path,
      "RAWMASTER_OWNERSHIP_TOKEN": ownership, "RAWMASTER_WORKER_SCRIPT": resources.appendingPathComponent("mlx_worker.py").path,
      "RAWMASTER_MLX_PYTHON": active.appendingPathComponent(".mlx/bin/python").path,
      "RAWMASTER_OWNER_PID": String(ProcessInfo.processInfo.processIdentifier), "RAWMASTER_RUNTIME_ID": active.lastPathComponent,
      "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
    child.environment = environment
    let log = root.appendingPathComponent("server.log"); FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log); child.standardOutput = handle; child.standardError = handle
    try child.run(); runtimeUseLease = admission; process = child; logHandle = handle; token = ownership; runRoot = root; endpoint = address
    let receipt = Ownership(pid: child.processIdentifier, endpoint: address, token: ownership, executable: child.executableURL!, runRoot: root, workerScript: resources.appendingPathComponent("mlx_worker.py"))
    do {
      try JSONEncoder().encode(receipt).write(to: ownershipURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownershipURL.path)
    } catch { try? await stopOwnedRuntime(); throw error }
    do {
      for _ in 0..<240 {
        try Task.checkCancellation()
        guard child.isRunning else { throw AIServiceError.runtimeUnavailable("Comfy 服务启动失败；请查看脱敏运行日志") }
        do { try await health(); try requireOpenAdmission(); state = "ready"; message = "Comfy / MLX 节点就绪；模型按任务加载"; return address }
        catch { try await Task.sleep(nanoseconds: 250_000_000) }
      }
      throw AIServiceError.runtimeUnavailable("本地服务健康检查超时")
    } catch { try? await stop(); state = "failed"; message = "本地服务启动失败"; throw error }
  }
  public func unload() async throws {
    try requireOpenAdmission()
    guard environmentMutationID == nil, !editing else { throw AIServiceError.busy }
    try await joinWorker()
  }
  private func joinWorker() async throws {
    guard process?.isRunning == true else { return }
    let response = try await call(path: "/rawmaster/unload", method: "POST", body: [:])
    guard let data = try JSONSerialization.jsonObject(with: response.data) as? [String: Any], data["workerJoined"] as? Bool == true else { throw EditingError.workerNotJoined }
    message = "模型 worker 已退出，内存已释放"
  }
  public func stop() async throws {
    guard environmentMutationID == nil else { throw AIServiceError.busy }
    try await stopOwnedRuntime()
  }
  private func stopOwnedRuntime() async throws {
    let child = process
    var unloadError: Error?
    idleTask?.cancel(); idleTask = nil
    if child?.isRunning == true { do { try await joinWorker() } catch { unloadError = error } }
    if let child, child.isRunning {
      child.terminate()
      for _ in 0..<40 { if !child.isRunning { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
      if child.isRunning {
        // Only terminate this live Process object; never signal a PID read from a stale receipt.
        let killer = Process(); killer.executableURL = URL(fileURLWithPath: "/bin/kill"); killer.arguments = ["-KILL", String(child.processIdentifier)]; try killer.run(); killer.waitUntilExit()
      }
      await Task.detached { child.waitUntilExit() }.value
    }
    process = nil; runtimeUseLease = nil; try? logHandle?.close(); logHandle = nil; token = nil; endpoint = nil; editing = false; activeLease = nil
    state = "stopped"; message = "本地服务与 worker 已停止"
    if let unloadError { throw unloadError }
  }
  func beginEdit(runID: String) async throws -> URL {
    try requireOpenAdmission()
    guard environmentMutationID == nil, !editing else { throw AIServiceError.busy }
    guard !criticalPressure else { throw AIServiceError.runtimeUnavailable("系统内存压力过高，请释放内存后再开始本地编辑") }
    idleTask?.cancel(); idleTask = nil
    let endpoint = try await start()
    try requireOpenAdmission()
    guard !editing, !criticalPressure else { throw AIServiceError.busy }; editing = true; activeLease = runID; return endpoint
  }
  func endEdit(runID: String) {
    guard activeLease == runID else { return }
    editing = false; activeLease = nil; scheduleIdleUnload()
  }
  func cancelEdit(runID: String) async throws { if activeLease == runID { try await joinWorker() } }
  private func scheduleIdleUnload() {
    idleTask?.cancel()
    let delay = criticalPressure ? 0.05 : idleUnloadSeconds
    idleTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); try Task.checkCancellation(); await self?.unloadIfIdle() } catch {}
    }
  }
  private func unloadIfIdle() async {
    guard !editing, process?.isRunning == true else { return }
    do { try await joinWorker() } catch { message = "空闲模型释放未确认，请停止本地服务后重试" }
  }
  private func memoryPressureChanged(critical: Bool) async {
    criticalPressure = critical
    if critical { message = "系统内存压力过高，暂缓新任务"; if !editing { await unloadIfIdle() } }
  }
  func testingSetCriticalPressure(_ critical: Bool) async { await memoryPressureChanged(critical: critical) }
  func inputURL(name: String) throws -> URL {
    guard let runRoot, !name.contains("/"), !name.contains("..") else { throw EditingError.unsafePath }
    let directory = runRoot.appendingPathComponent("input"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
  }
  func outputURL(filename: String, subfolder: String) throws -> URL {
    guard let runRoot, !filename.contains("/"), !filename.contains(".."), !subfolder.hasPrefix("/"), !subfolder.split(separator: "/").contains("..") else { throw EditingError.unsafePath }
    let root = runRoot.appendingPathComponent("output").resolvingSymlinksInPath()
    let path = root.appendingPathComponent(subfolder).appendingPathComponent(filename).resolvingSymlinksInPath()
    guard path.path.hasPrefix(root.path + "/") else { throw EditingError.unsafePath }
    return path
  }
  func call(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> ProviderHTTPResponse {
    guard let endpoint, let token, process?.isRunning == true else { throw AIServiceError.runtimeUnavailable("自有运行时未启动") }
    var request = URLRequest(url: endpoint.appendingPathComponent(path)); request.httpMethod = method; request.timeoutInterval = 30
    request.setValue(token, forHTTPHeaderField: "X-RAWMaster-Token")
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let response = try await transport.send(request)
    guard (200..<300).contains(response.status) else { throw AIServiceError.runtimeUnavailable("自有服务拒绝请求（\(response.status)）") }
    return response
  }
  private func health() async throws {
    let response = try await call(path: "/rawmaster/health")
    guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
      value["protocol"] as? String == "rawmaster-comfy-mlx-v1", (value["pid"] as? NSNumber)?.int32Value == process?.processIdentifier,
      value["runRoot"] as? String == runRoot?.resolvingSymlinksInPath().path,
      value["modelRoot"] as? String == configuration.modelRoot.resolvingSymlinksInPath().path,
      let executable = value["executable"] as? String,
      URL(fileURLWithPath: executable).resolvingSymlinksInPath() == process?.executableURL?.resolvingSymlinksInPath() else { throw AIServiceError.runtimeUnavailable("运行时所有权检查失败") }
  }
  /// Authenticate the previous owned host before asking it to join its worker. Never signal a PID from disk.
  public func recoverPreviousOwnership() async throws -> Bool {
    try requireOpenAdmission()
    guard process?.isRunning != true, !editing, !installing else { return false }
    guard let data = try? Data(contentsOf: ownershipURL), let receipt = try? JSONDecoder().decode(Ownership.self, from: data) else { return false }
    let runs = configuration.runtimeRoot.appendingPathComponent("runs").resolvingSymlinksInPath().path + "/"
    guard receipt.runRoot.resolvingSymlinksInPath().path.hasPrefix(runs), receipt.endpoint.host == "127.0.0.1", receipt.endpoint.scheme == "http" else { throw EditingError.unsafePath }
    var request = URLRequest(url: receipt.endpoint.appendingPathComponent("rawmaster/health")); request.timeoutInterval = 2
    request.setValue(receipt.token, forHTTPHeaderField: "X-RAWMaster-Token")
    if let response = try? await transport.send(request), response.status == 200 {
      guard let health = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
        (health["pid"] as? NSNumber)?.int32Value == receipt.pid,
        health["runRoot"] as? String == receipt.runRoot.resolvingSymlinksInPath().path,
        health["executable"] as? String == receipt.executable.resolvingSymlinksInPath().path else { throw EditingError.workerNotJoined }
      request.url = receipt.endpoint.appendingPathComponent("rawmaster/shutdown"); request.httpMethod = "POST"
      let stopped = try await transport.send(request)
      guard stopped.status == 200, let joined = try JSONSerialization.jsonObject(with: stopped.data) as? [String: Any], joined["workerJoined"] as? Bool == true else { throw EditingError.workerNotJoined }
    }
    // Parent/worker watchdogs operate within 0.5s. Independently verify matching host/child command records disappeared.
    for _ in 0..<30 {
      let alive = await Task.detached { Self.previousProcessesAlive(receipt) }.value
      if !alive { recoveredOwnership = receipt; return true }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    return false
  }
  private static func previousProcessesAlive(_ receipt: Ownership) -> Bool {
    let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,command="]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    do {
      try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
      guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return true }
      for line in text.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3 else { continue }
        if Int32(fields[0]) == receipt.pid && fields[2].contains(receipt.runRoot.path) { return true }
        if fields[2].contains(receipt.workerScript.path + " --parent-pid " + String(receipt.pid)) { return true }
      }
      return false
    } catch { return true }
  }
  func recoveredOutput(attempt: ProcessingAttempt, directory: URL) throws -> AIEditOutput? {
    guard let ownership = recoveredOwnership, !attempt.runID.contains("/"), !attempt.runID.contains("..") else { return nil }
    let job = ownership.runRoot.appendingPathComponent("jobs").appendingPathComponent(attempt.runID)
    let receiptURL = job.appendingPathComponent("worker-result.json"), output = job.appendingPathComponent("native.png")
    guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]
    let bytes = try Data(contentsOf: output)
    guard json?["outputSHA256"] as? String == AIImageBytes.hash(bytes) else { throw EditingError.archiveMismatch }
    var config = ["recovered": "owned-worker-result", "workflow": "rawmaster-comfy-mlx-v1"]
    for key in ["model", "modelRevision", "modelIdentitySHA256", "decoder", "decoderWeightsSHA256"] { if let value = json?[key] as? String { config[key] = value } }
    return try AIImageBytes.save(bytes, directory: directory, configuration: config, remoteID: attempt.remoteID)
  }
  public func installedRuntimeVersions() throws -> [String] {
    let directory = configuration.runtimeRoot.appendingPathComponent("versions")
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("receipt.json").path) && FileManager.default.fileExists(atPath: $0.appendingPathComponent("installed-package-manifest.json").path) }
      .map(\.lastPathComponent).sorted()
  }
  public func rollback(version: String) async throws {
    try requireOpenAdmission()
    guard environmentMutationID == nil, !editing, !installing, process?.isRunning != true, !version.isEmpty,
      version.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).contains($0) }), !version.contains(" ") else { throw AIServiceError.busy }
    let admission = try RuntimeEnvironmentFileLease(root: configuration.runtimeRoot)
    defer { withExtendedLifetime(admission) {} }
    let candidate = configuration.runtimeRoot.appendingPathComponent("versions").appendingPathComponent(version).resolvingSymlinksInPath()
    guard try installedRuntimeVersions().contains(version) else { throw AIServiceError.runtimeUnavailable("没有可回滚的已验收运行时版本") }
    installing = true; state = "verifyingRollback"; message = "校验旧版本文件身份和节点健康"
    defer { installing = false }
    try await Task.detached {
      let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate.appendingPathComponent("installed-package-manifest.json"))) as? [String: Any]
      guard let items = manifest?["files"] as? [[String: Any]] else { throw EditingError.archiveMismatch }
      for item in items {
        try Task.checkCancellation()
        guard let relative = item["path"] as? String, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw EditingError.unsafePath }
        let path = candidate.appendingPathComponent(relative)
        guard path.resolvingSymlinksInPath().path.hasPrefix(candidate.path + "/") else { throw EditingError.unsafePath }
        if item["type"] as? String == "symlink" {
          guard try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == item["target"] as? String else { throw EditingError.archiveMismatch }
        } else {
          let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
          var hash = SHA256()
          while true { let count = try autoreleasepool { let bytes = try handle.read(upToCount: 1024*1024) ?? Data(); hash.update(data: bytes); return bytes.count }; if count == 0 { break }; try Task.checkCancellation() }
          guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == item["sha256"] as? String else { throw EditingError.archiveMismatch }
        }
      }
    }.value
    let healthRoot = configuration.runtimeRoot.appendingPathComponent("rollback-health-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: healthRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: healthRoot) }
    try FileManager.default.createSymbolicLink(at: healthRoot.appendingPathComponent("versions"), withDestinationURL: configuration.runtimeRoot.appendingPathComponent("versions"))
    try FileManager.default.createSymbolicLink(at: healthRoot.appendingPathComponent("active"), withDestinationURL: candidate)
    let health = ManagedRuntimeService(configuration: .init(runtimeRoot: healthRoot, modelRoot: configuration.modelRoot))
    do { _ = try await health.start(); try await health.stop() } catch { try? await health.stop(); throw error }
    let pointer = configuration.runtimeRoot.appendingPathComponent("active-" + UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: candidate)
    defer { try? FileManager.default.removeItem(at: pointer) }
    try await Self.runProcess(executable: candidate.appendingPathComponent("python/bin/python3.12"), arguments: ["-B", "-c", "import os,sys; os.replace(sys.argv[1],sys.argv[2])", pointer.path, configuration.runtimeRoot.appendingPathComponent("active").path], log: configuration.runtimeRoot.appendingPathComponent("rollback.log"))
    state = "installed"; message = "旧版本身份和健康检查通过，已原子切换"
  }
  func prepareModelProcess(includeTextureFix: Bool, progress: @escaping @Sendable (ManagedModelProgress) -> Void) async throws {
    try requireOpenAdmission()
    guard environmentMutationID == nil, !installing, !editing, process?.isRunning != true else { throw AIServiceError.busy }
    let admission = try RuntimeEnvironmentFileLease(root: configuration.runtimeRoot)
    defer { withExtendedLifetime(admission) {} }
    let active = configuration.runtimeRoot.appendingPathComponent("active").resolvingSymlinksInPath()
    let python = active.appendingPathComponent("python/bin/python3.12")
    guard FileManager.default.isExecutableFile(atPath: python.path) else { throw AIServiceError.runtimeUnavailable("请先安装离线运行时") }
    installing = true; state = "preparingModels"; message = "校验、复用或断点下载固定模型文件"
    defer { installing = false }
    let child = Process(), pipe = Pipe()
    child.executableURL = python
    child.arguments = ["-B", Self.resources.appendingPathComponent("prepare_models.py").path, "--manifest", Self.resources.appendingPathComponent("model-identity.json").path, "--model-root", configuration.modelRoot.path] + (includeTextureFix ? ["--texture-fix"] : [])
    child.standardOutput = pipe
    let log = configuration.runtimeRoot.appendingPathComponent("model-preparation.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
    child.standardError = handle
    try child.run()
    do {
      try await withTaskCancellationHandler(operation: {
        try await Task.detached {
          var buffer = Data()
          while let bytes = try pipe.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {
            buffer.append(bytes)
            while let newline = buffer.firstIndex(of: 10) {
              let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
              if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let phase = json["phase"] as? String {
                progress(.init(phase: phase, completedBytes: (json["completedBytes"] as? NSNumber)?.int64Value ?? 0,
                  totalBytes: (json["totalBytes"] as? NSNumber)?.int64Value ?? 0, message: json["message"] as? String ?? ""))
              }
            }
          }
          child.waitUntilExit()
        }.value
        try Task.checkCancellation()
        guard child.terminationStatus == 0 else { throw AIServiceError.runtimeUnavailable("模型准备失败；已验证文件和断点保留，请检查模型日志") }
      }, onCancel: { if child.isRunning { child.terminate() } })
      state = "installed"; message = "模型文件已按固定身份校验，可开始研究评估"
    } catch { state = "failed"; message = "模型准备未完成；可继续断点下载"; throw error }
  }
  static var resources: URL { Bundle.module.resourceURL!.appendingPathComponent("Resources") }
  private static func runProcess(executable: URL, arguments: [String], log: URL) async throws {
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
    let process = Process(); process.executableURL = executable; process.arguments = arguments; process.standardOutput = handle; process.standardError = handle
    try process.run()
    try await withTaskCancellationHandler(operation: {
      await Task.detached { process.waitUntilExit() }.value
      try Task.checkCancellation()
      guard process.terminationStatus == 0 else { throw AIServiceError.runtimeUnavailable("离线安装失败，请检查安装日志；旧活动版本保留") }
    }, onCancel: { if process.isRunning { process.terminate() } })
  }
}
