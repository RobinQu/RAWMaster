import Darwin
import Foundation
import XCTest
@testable import RAWMasterAI

/// Component integration only. No model inference, product consent, defaults or personal runtime.
/// Root must grant the real install/hash/health run separately from compiling this opt-in test.
final class RealRuntimeProvisioning021Tests: XCTestCase {
  private static let catalogSHA = "6ae90188e67edc237a0a90ac7bf2d5acf26afcbdff697a4355f599dd9e85ec37"
  private static let artifactID = "rawmaster-comfymlx-v4-arm64-py312"
  private static let systemPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
  private static let authorizedModels = "/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/mlx-models"

  func testPinnedArtifactDeferredReadOnlyModelsJoinedHealthCASAndStartup() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RAWMASTER_021_RUNTIME_INTEGRATION"] == "1" else {
      throw XCTSkip("Explicit real artifact install + 32GB read-only hash + owned health opt-in required")
    }
    func requiredURL(_ name: String) throws -> URL {
      guard let value = env[name], value.hasPrefix("/") else { throw Failure.check("Missing absolute " + name) }
      return URL(fileURLWithPath: value).standardizedFileURL
    }
    let repo = try requiredURL("RAWMASTER_021_REPOSITORY").resolvingSymlinksInPath()
    let artifacts = try requiredURL("RAWMASTER_021_RUNTIME_ARTIFACTS").resolvingSymlinksInPath()
    let models = try requiredURL("RAWMASTER_021_MODEL_ROOT").resolvingSymlinksInPath()
    let output = try requiredURL("RAWMASTER_021_RUNTIME_OUTPUT")
    let validation = repo.appendingPathComponent("output/validation/021-photos-editor").resolvingSymlinksInPath()
    try check(env["PATH"] == Self.systemPATH, "Test process PATH must contain only the fixed system directories")
    try check(RuntimeArtifactFiles.pathIdentity(artifacts) == RuntimeArtifactFiles.pathIdentity(validation.appendingPathComponent("RuntimeArtifacts")), "Unexpected artifact directory")
    try check(models.path == Self.authorizedModels, "Only the explicitly authorized read-only Lab models are admitted")
    try check(output.path.hasPrefix(validation.path + "/") && output.path != artifacts.path,
              "Output must be a new independent 021 validation subdirectory")
    try check(RuntimeArtifactFiles.pathIdentity(output.resolvingSymlinksInPath()) == RuntimeArtifactFiles.pathIdentity(output), "Output ancestors must not redirect")
    var absent = stat()
    try check(lstat(output.path, &absent) != 0 && errno == ENOENT, "Output already exists or cannot be inspected")
    let catalog = try RuntimeArtifactCatalog(catalogURL: artifacts.appendingPathComponent("catalog.json"), expectedSHA256: Self.catalogSHA, resourceRoot: artifacts)
    let artifact = try catalog.artifact(Self.artifactID)
    let manifest = ManagedRuntimeService.resources.appendingPathComponent("model-identity.json")
    let identity = try JSONDecoder().decode(ModelIdentity.self, from: Data(contentsOf: manifest))
    try check(identity.files.count == 14, "Unexpected required model set")
    let modelBefore = try modelStamps(root: models, identity: identity)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    let runtimeRoot = output.appendingPathComponent("runtime", isDirectory: true)
    let runtime = ManagedRuntimeService(configuration: .init(runtimeRoot: runtimeRoot, modelRoot: models))
    let progress = ProgressBox()
    var record = Record(catalogSHA256: catalog.identitySHA256, artifact: artifact, paths: ["repository": repo.path,
      "artifacts": artifacts.path, "modelsReadOnly": models.path, "output": output.path, "runtime": runtimeRoot.path],
      modelManifestSHA256: try RuntimeArtifactFiles.hash(manifest), modelBefore: modelBefore)
    let began = ProcessInfo.processInfo.systemUptime
    var mutation: RuntimeEnvironmentMutation?, health: ManagedRuntimeService?
    var failure: Error?
    func save(_ phase: String) throws {
      record.events.append(.init(phase: phase, elapsedSeconds: ProcessInfo.processInfo.systemUptime - began,
                                 resource: Resource.snapshot()))
      record.progress = progress.snapshot()
      try RuntimeArtifactFiles.writeJSON(record, to: output.appendingPathComponent("component-integration.json"))
    }
    do {
      try save("preflightAuthenticatedCatalogOnly")
      // Prove the product gate rejects missing consent; never fabricate an acknowledgement.
      let rejectedRoot = output.appendingPathComponent("consent-must-not-create")
      let coordinator = LocalAIEnvironmentCoordinator(configuration: .init(runtimeRoot: rejectedRoot, modelRoot: models), catalog: catalog)
      do {
        _ = try await coordinator.prepare(.init(artifactID: artifact.id, modelStorage: .borrowedReadOnly(models), consent: nil))
        throw Failure.check("Missing consent was accepted")
      } catch LocalAISetupError.consentRequired { record.consentRejected = true }
      try check(!FileManager.default.fileExists(atPath: rejectedRoot.path), "Consent rejection wrote a runtime root")
      await coordinator.shutdown()
      let lease = try await runtime.beginEnvironmentPreparation(operationID: UUID()); mutation = lease
      try check(lease.expectedActive.target == nil, "Fresh runtime unexpectedly has an active version")
      try save("mutationLeaseAcquired")
      let package = try await RuntimeArtifactPreparation.prepare(artifact, catalog: catalog,
        operationRoot: output.appendingPathComponent("artifact-authentication")) { phase, done, total in
          progress.update(phase, done, total)
        }
      record.package = package.path
      // No package executable has been invoked before native archive + full-tree authentication.
      try save("nativeArchiveAndFullTreeAuthenticatedBeforeBootstrap")
      let candidate = try await runtime.stageRuntime(package: package, artifact: artifact, mutation: lease,
                                                    log: output.appendingPathComponent("install-driver.log"))
      record.candidate = candidate.path
      record.installReceiptSHA256 = try RuntimeArtifactFiles.hash(candidate.appendingPathComponent("receipt.json"))
      try check(!FileManager.default.fileExists(atPath: runtimeRoot.appendingPathComponent("active").path), "Deferred installer activated early")
      try save("deferredCandidateInstalledAndInstallerChildrenJoined")
      let modelReceipt = output.appendingPathComponent("model-verification.json")
      try await runtime.prepareModelsForCandidate(candidate, storage: .borrowedReadOnly(models), includeTextureFix: false,
                                                 receipt: modelReceipt, mutation: lease) { value in
        progress.update(value.phase, value.completedBytes, value.totalBytes)
      }
      let verified = try JSONDecoder().decode(ModelReceipt.self, from: Data(contentsOf: modelReceipt))
      try check(verified.verified && verified.readOnly && !verified.textureFix && verified.identitySHA256 == record.modelManifestSHA256,
                "Model verification receipt differs from actual pinned verification")
      try check(verified.modelRoot == models.path && verified.reusedBytes == identity.files.reduce(Int64(0), { $0 + $1.size }), "Read-only byte accounting mismatch")
      record.modelReceipt = verified; record.modelReceiptSHA256 = try RuntimeArtifactFiles.hash(modelReceipt)
      try save("RequiredModelsActuallyHashedReadOnlyNoInference")
      let healthRoot = output.appendingPathComponent("isolated-health", isDirectory: true)
      try FileManager.default.createDirectory(at: healthRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try FileManager.default.createSymbolicLink(at: healthRoot.appendingPathComponent("versions"), withDestinationURL: runtimeRoot.appendingPathComponent("versions"))
      try FileManager.default.createSymbolicLink(at: healthRoot.appendingPathComponent("active"), withDestinationURL: candidate)
      let probe = ManagedRuntimeService(configuration: .init(runtimeRoot: healthRoot, modelRoot: models)); health = probe
      _ = try await probe.start()
      let probeProof = try await healthProof(probe, expectedRoot: healthRoot, models: models)
      record.health.append(probeProof)
      try save("isolatedCandidateRealOwnedHealthReadyNoWorker")
      let witness = try await probe.stopAfterPreparationHealth()
      let stoppedProbe = await probe.status()
      try check(stoppedProbe.state == "stopped" && stoppedProbe.endpoint == nil && witness.joinedPID == probeProof.pid, "Health did not return a real joined witness")
      try checkProcessGone(witness.joinedPID)
      health = nil; record.joinedPIDs.append(witness.joinedPID)
      try save("candidateHealthActuallyStoppedAndJoined")
      _ = try await runtime.commitPreparedRuntime(candidate, modelRoot: models, mutation: lease, health: witness)
      try check(runtimeRoot.appendingPathComponent("active").resolvingSymlinksInPath().path == candidate.resolvingSymlinksInPath().path, "CAS did not publish candidate")
      record.casCommitted = true
      await runtime.endEnvironmentPreparation(lease); mutation = nil
      try save("expectedActiveCASCommittedThenMutationLeaseReleased")
      _ = try await runtime.start()
      let startupProof = try await healthProof(runtime, expectedRoot: runtimeRoot, models: models)
      record.health.append(startupProof)
      try save("committedRuntimeActuallyStartedNoWorker")
      try await runtime.stop(); try checkProcessGone(startupProof.pid)
      record.joinedPIDs.append(startupProof.pid)
      try save("committedRuntimeActuallyStoppedAndJoined")
    } catch { failure = error; record.failure = String(describing: error).prefix(2048).description }

    // Join owned processes even on error; preserve the new root and all partial evidence.
    if let health {
      do { try await health.stop() } catch { record.cleanupErrors.append(String(describing: error)) }
    }
    if let mutation { await runtime.endEnvironmentPreparation(mutation) }
    do { try await runtime.stop() } catch { record.cleanupErrors.append(String(describing: error)) }
    await runtime.closeAdmission()
    let final = await runtime.status()
    record.finalState = final.state; record.finalEndpointAbsent = final.endpoint == nil
    do {
      record.modelAfter = try modelStamps(root: models, identity: identity)
      try check(record.modelBefore == record.modelAfter, "Borrowed model files/directories changed (atime excluded)")
      try check(final.state == "stopped" && final.endpoint == nil && record.cleanupErrors.isEmpty, "Owned cleanup not confirmed")
    } catch {
      if failure == nil { failure = error }; record.cleanupErrors.append(String(describing: error))
    }
    record.complete = failure == nil && record.casCommitted && record.joinedPIDs.count == 2 && record.consentRejected
    try save("finalCleanupAndReadOnlyIdentityVerified")
    if let failure { throw failure }
    XCTAssertTrue(record.complete)
  }

  private enum Failure: Error { case check(String) }
  private func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.check(message) } }
  private func checkProcessGone(_ pid: Int32) throws {
    errno = 0
    try check(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "Previously owned PID is still observable after join")
  }
  private func healthProof(_ runtime: ManagedRuntimeService, expectedRoot: URL, models: URL) async throws -> Health {
    let response = try await runtime.call(path: "/rawmaster/health")
    try check(response.data.count <= 65_536, "Oversized health response")
    let value = try JSONDecoder().decode(Health.self, from: response.data)
    try check(value.protocolName == "rawmaster-comfy-mlx-v1" && value.pid > 0 && value.workerPID == nil,
              "Health is not a real idle owned host")
    try check(value.runRoot.hasPrefix(expectedRoot.path + "/runs/") && value.modelRoot == models.path, "Health paths mismatch")
    return value // Does not retain or log the ownership token.
  }
  private struct ModelIdentity: Decodable { struct File: Decodable { let path: String; let size: Int64 }; let files: [File] }
  private struct ModelReceipt: Codable {
    let verified: Bool, readOnly: Bool, textureFix: Bool
    let identitySHA256: String, modelRoot: String
    let reusedBytes: Int64
  }
  private struct Stamp: Codable, Equatable {
    let path: String, resolvedPath: String
    let device: Int32, inode: UInt64, size: Int64, mode: UInt16, links: UInt16
    let mtimeSeconds: Int64, mtimeNanoseconds: Int64, ctimeSeconds: Int64, ctimeNanoseconds: Int64
    init(_ url: URL, relative: String) throws {
      var value = stat()
      guard lstat(url.path, &value) == 0 else { throw Failure.check("Missing borrowed model path: " + relative) }
      path = relative; resolvedPath = url.resolvingSymlinksInPath().path
      device = value.st_dev; inode = value.st_ino; size = value.st_size; mode = value.st_mode; links = value.st_nlink
      mtimeSeconds = Int64(value.st_mtimespec.tv_sec); mtimeNanoseconds = Int64(value.st_mtimespec.tv_nsec)
      ctimeSeconds = Int64(value.st_ctimespec.tv_sec); ctimeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
  }
  private func modelStamps(root: URL, identity: ModelIdentity) throws -> [Stamp] {
    var paths: Set<String> = [""]
    for file in identity.files {
      try check(RuntimeArtifactFiles.safeRelativePath(file.path), "Unsafe model manifest path")
      var path = file.path
      while !path.isEmpty {
        paths.insert(path); let next = (path as NSString).deletingLastPathComponent
        if next == path || next == "." { break }; path = next
      }
      let url = root.appendingPathComponent(file.path)
      try check(url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"), "Model file redirects outside borrowed root")
      var value = stat()
      try check(stat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG && value.st_size == file.size, "Model size/type mismatch")
    }
    return try paths.sorted().map { try Stamp($0.isEmpty ? root : root.appendingPathComponent($0), relative: $0) }
  }
  private struct Health: Codable {
    let protocolName: String, pid: Int32, executable: String, runRoot: String, modelRoot: String
    let workerPID: Int32?
    enum CodingKeys: String, CodingKey { case protocolName = "protocol", pid, executable, runRoot, modelRoot, workerPID }
  }
  private struct Resource: Codable {
    let processMaxRSSBytes: Int64, userCPUSeconds: Double, systemCPUSeconds: Double
    static func snapshot() -> Self {
      var value = rusage(); _ = getrusage(RUSAGE_SELF, &value)
      return .init(processMaxRSSBytes: Int64(value.ru_maxrss),
                   userCPUSeconds: Double(value.ru_utime.tv_sec) + Double(value.ru_utime.tv_usec) / 1e6,
                   systemCPUSeconds: Double(value.ru_stime.tv_sec) + Double(value.ru_stime.tv_usec) / 1e6)
    }
  }
  private struct Event: Codable { let phase: String; let elapsedSeconds: Double; let resource: Resource }
  private struct Progress: Codable { let phase: String; let completedBytes: Int64?; let totalBytes: Int64? }
  private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var latest = Progress(phase: "idle", completedBytes: nil, totalBytes: nil)
    func update(_ phase: String, _ done: Int64?, _ total: Int64?) { lock.lock(); defer { lock.unlock() }; latest = .init(phase: phase, completedBytes: done, totalBytes: total) }
    func snapshot() -> Progress { lock.lock(); defer { lock.unlock() }; return latest }
  }
  private struct Record: Codable {
    let scope = "P1B component integration only; not product one-button acceptance or model inference/effect acceptance"
    let pathPolicy = "system PATH only; no user Python/uv; package executable only after native archive/full-tree validation"
    let resourceScope = "Parent process rusage checkpoints only; not child/combined memory peak or continuous sampling"
    let modelPolicy = "Required 14 files actually hashed by pinned prepare_models.py read-only; no download, copy, inference or automatic license acknowledgement"
    let catalogSHA256: String, artifact: RuntimeArtifact, paths: [String: String], modelManifestSHA256: String
    let modelBefore: [Stamp]
    var modelAfter: [Stamp] = [], events: [Event] = [], progress: Progress?
    var package: String?, candidate: String?, installReceiptSHA256: String?, modelReceiptSHA256: String?
    var modelReceipt: ModelReceipt?, health: [Health] = [], joinedPIDs: [Int32] = []
    var consentRejected = false, casCommitted = false, complete = false, finalEndpointAbsent = false
    var finalState: String?, failure: String?, cleanupErrors: [String] = []
  }
}
