import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import RAWMasterAI

final class RuntimeProvisioningTests: XCTestCase {
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("runtime-provision-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
  }
  private func catalog(_ root: URL, manifest: Data, zip: Data, count: Int, bytes: Int64) throws -> RuntimeArtifactCatalog {
    try zip.write(to: root.appendingPathComponent("tiny.zip"))
    let document: [String: Any] = ["schemaVersion": 1, "artifacts": [["id": "tiny", "platform": "macos-arm64", "minimumMacOS": "15.0",
      "archivePath": "tiny.zip", "archiveByteCount": zip.count, "archiveSHA256": RuntimeArtifactFiles.digest(zip),
      "innerManifestSHA256": RuntimeArtifactFiles.digest(manifest), "manifestEntryCount": count, "unpackedByteCount": bytes]]]
    let data = try JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
    let file = root.appendingPathComponent("catalog.json"); try data.write(to: file)
    return try RuntimeArtifactCatalog(catalogURL: file, expectedSHA256: RuntimeArtifactFiles.digest(data), resourceRoot: root)
  }
  func testCatalogFailsClosedBeforeExecutingAnyBootstrap() throws {
    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let data = Data("{}".utf8), file = base.appendingPathComponent("catalog.json"); try data.write(to: file)
    XCTAssertThrowsError(try RuntimeArtifactCatalog(catalogURL: file, expectedSHA256: String(repeating: "0", count: 64), resourceRoot: base))
    XCTAssertThrowsError(try RuntimeArtifactCatalog(catalogURL: file, expectedSHA256: RuntimeArtifactFiles.digest(data), resourceRoot: base))
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("active").path))
  }
  func testDirectoryURLPresentationIsNotLocationIdentityAndRedirectStillDiffers() throws {
    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let fileHint = URL(fileURLWithPath: base.path, isDirectory: false)
    let directoryHint = URL(fileURLWithPath: base.path, isDirectory: true)
    XCTAssertNotEqual(fileHint.absoluteString, directoryHint.absoluteString)
    XCTAssertEqual(RuntimeArtifactFiles.pathIdentity(fileHint), RuntimeArtifactFiles.pathIdentity(directoryHint))
    let link = base.appendingPathComponent("redirect", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
    XCTAssertNotEqual(RuntimeArtifactFiles.pathIdentity(link), RuntimeArtifactFiles.pathIdentity(link.resolvingSymlinksInPath()))
  }
  func testZipAdmissionPreservesInternalLinksAndRejectsTraversalAndAliases() throws {
    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appendingPathComponent("fixture.zip")
    func check(_ entries: [ZipEntry]) throws -> [RuntimeZipAdmission.Entry] {
      try makeZip(entries).write(to: file); return try RuntimeZipAdmission.entries(file)
    }
    let valid = try check([.init("python/bin/python3.12", "inert"), .init("python/bin/python3", "python3.12", link: true)])
    XCTAssertEqual(valid.count, 2); XCTAssertEqual(valid[1].link, "python3.12")
    for entries in [[ZipEntry("../outside", "x")], [.init("python/link", "../../../outside", link: true)],
                    [.init("a", "x"), .init("A", "y")], [.init("link", "inside", link: true), .init("link/child", "x")]] {
      XCTAssertThrowsError(try check(entries))
    }
  }
  func testActualTinyZIP64LocalHeadersExtractThenFullTreeIdentityBeforeBootstrap() async throws {
    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let payload = Data("inert fixture; never executable".utf8), node = Data("node-data".utf8)
    let entries: [[String: Any]] = [
      ["path": "python/bin/python3.12", "size": payload.count, "sha256": RuntimeArtifactFiles.digest(payload)],
      ["path": "python/bin/python3", "type": "symlink", "target": "python3.12"],
      ["path": "resources/node.txt", "size": node.count, "sha256": RuntimeArtifactFiles.digest(node)]]
    let manifest = try JSONSerialization.data(withJSONObject: ["id": "tiny", "files": entries], options: .sortedKeys)
    let archive = makeZip([.init("manifest.json", data: manifest), .init("python/bin/python3.12", data: payload),
                           .init("python/bin/python3", "python3.12", link: true), .init("resources/node.txt", data: node)])
    let source = try catalog(base, manifest: manifest, zip: archive, count: 3, bytes: Int64(payload.count + node.count))
    let item = try source.artifact("tiny", checkPlatform: false)
    let package: URL
    do {
      package = try await RuntimeArtifactPreparation.prepare(item, catalog: source, operationRoot: base.appendingPathComponent("stage")) { phase, _, _ in
        print("tiny trusted archive phase:", phase)
      }
    } catch {
      let candidate = base.appendingPathComponent("stage/package", isDirectory: true)
      print("tiny package path:", candidate.path, "canonical:", candidate.resolvingSymlinksInPath().path)
      if let items = FileManager.default.enumerator(at: candidate, includingPropertiesForKeys: nil) {
        for case let file as URL in items {
          var value = stat(); _ = lstat(file.path, &value)
          print("tiny entry:", file.path, "mode:", value.st_mode, "size:", value.st_size,
                "link:", (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) ?? "none")
        }
      }
      throw error
    }
    XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("python/bin/python3.12")), payload)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: package.appendingPathComponent("python/bin/python3").path), "python3.12")
    try Data("bad".utf8).write(to: package.appendingPathComponent("resources/node.txt"))
    XCTAssertThrowsError(try RuntimeArtifactPreparation.validateTree(package, artifact: item) { _, _, _ in })
  }
  func testEnvironmentMutationBlocksAllLegacyAdmissionsAndStaleReleaseCannotUnlockNext() async throws {
    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let config = ManagedRuntimeConfiguration(runtimeRoot: base, modelRoot: base.appendingPathComponent("models"))
    let service = ManagedRuntimeService(configuration: config), other = ManagedRuntimeService(configuration: config)
    let first = try await service.beginEnvironmentPreparation(operationID: UUID())
    func busy(_ work: () async throws -> Void) async {
      do { try await work(); XCTFail("must reject admission") } catch { XCTAssertEqual(error as? AIServiceError, .busy) }
    }
    await busy { _ = try await service.start() }; await busy { try await service.stop() }
    await busy { try await service.unload() }; await busy { try await service.install(package: base) }
    await busy { try await service.rollback(version: "old") }; await busy { try await service.updateConfiguration(config) }
    await busy { _ = try await other.beginEnvironmentPreparation(operationID: UUID()) }
    await service.endEnvironmentPreparation(first)
    let second = try await service.beginEnvironmentPreparation(operationID: UUID())
    await service.endEnvironmentPreparation(first)
    await busy { _ = try await service.start() }
    await service.endEnvironmentPreparation(second)
  }
  func testDeferredCandidateDoesNotActivateUntilCASAndChangedActiveIsNeverRolledBack() async throws {
    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let versions = base.appendingPathComponent("versions"); try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
    for name in ["old", "newer"] { try FileManager.default.createDirectory(at: versions.appendingPathComponent(name), withIntermediateDirectories: false) }
    let active = base.appendingPathComponent("active"); try FileManager.default.createSymbolicLink(atPath: active.path, withDestinationPath: "versions/old")
    let package = base.appendingPathComponent("fake-package"); try FileManager.default.createDirectory(at: package.appendingPathComponent("python/bin"), withIntermediateDirectories: true)
    let fake = package.appendingPathComponent("python/bin/python3.12")
    // Fake bootstrap protocol, not Python/uv/health acceptance. Exercises the real stage/commit gates.
    let script = """
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --destination) dest="$2"; shift 2;;
        --candidate-name) name="$2"; shift 2;;
        --operation-id) op="$2"; shift 2;;
        */install_runtime.py) scripts="${1%/*}"; shift;;
        *) shift;;
      esac
    done
    mkdir -p "$dest/versions/$name"
    mkdir -p "$dest/versions/$name/resources"
    cp "$scripts/model-identity.json" "$dest/versions/$name/resources/model-identity.json"
    printf '{"operationID":"%s","artifactID":"tiny"}' "$op" > "$dest/versions/$name/preparation-owner.json"
    printf '{"id":"tiny","operationID":"%s","deferredActivation":true,"nodeHealth":true,"mlxOperatorHealth":true}' "$op" > "$dest/versions/$name/receipt.json"
    """
    try Data(script.utf8).write(to: fake); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
    let service = ManagedRuntimeService(configuration: .init(runtimeRoot: base, modelRoot: base.appendingPathComponent("models")))
    let mutation = try await service.beginEnvironmentPreparation(operationID: UUID())
    let artifact = RuntimeArtifact(id: "tiny", platform: "macos-arm64", minimumMacOS: "15.0", archivePath: "tiny.zip", archiveByteCount: 1,
      archiveSHA256: String(repeating: "0", count: 64), innerManifestSHA256: String(repeating: "0", count: 64), manifestEntryCount: 1, unpackedByteCount: 1)
    let candidate = try await service.stageRuntime(package: package, artifact: artifact, mutation: mutation, log: base.appendingPathComponent("fake.log"))
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: active.path), "versions/old")
    do { _ = try await service.commitPreparedRuntime(candidate, modelRoot: base, mutation: mutation); XCTFail("install alone cannot activate without model verification + joined health") }
    catch { XCTAssertEqual(error as? LocalAISetupError, .preparationFailed) }
    try FileManager.default.removeItem(at: active); try FileManager.default.createSymbolicLink(atPath: active.path, withDestinationPath: "versions/newer")
    do { _ = try await service.commitPreparedRuntime(candidate, modelRoot: base, mutation: mutation); XCTFail("stale active must reject") }
    catch { XCTAssertEqual(error as? LocalAISetupError, .activeChanged) }
    await service.closeAdmission()
    do { _ = try await service.commitPreparedRuntime(candidate, modelRoot: base, mutation: mutation); XCTFail("old lease cannot commit after shutdown admission closes") }
    catch { XCTAssertEqual(error as? LocalAISetupError, .operationRevoked) }
    // A current active candidate must never be deleted because URL directory hints differ.
    try FileManager.default.removeItem(at: active)
    try FileManager.default.createSymbolicLink(atPath: active.path, withDestinationPath: "versions/" + candidate.lastPathComponent)
    let isActive = await service.preparedRuntimeIsActive(candidate, mutation: mutation)
    XCTAssertTrue(isActive)
    try await service.discardPreparedRuntime(candidate, mutation: mutation)
    XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    try FileManager.default.removeItem(at: active)
    try FileManager.default.createSymbolicLink(atPath: active.path, withDestinationPath: "versions/newer")
    // Existing ownership is still usable for cleanup and actual resource release after closure.
    try await service.discardPreparedRuntime(candidate, mutation: mutation)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: active.path), "versions/newer")
    XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
    await service.endEnvironmentPreparation(mutation)
  }
  func testCoordinatorShutdownPermanentlyClosesTheSameRuntimeAndCannotBeReopenedByCancel() async throws {
    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let config = ManagedRuntimeConfiguration(runtimeRoot: base.appendingPathComponent("unused"), modelRoot: base)
    let environment = LocalAIEnvironmentCoordinator(configuration: config, catalog: nil)
    let sameRuntime = environment.runtime
    await environment.shutdown(); await environment.cancelAndJoinPreparation(); await environment.shutdown()
    let snapshot = await environment.inspect(); XCTAssertEqual(snapshot.stage, "stopped"); XCTAssertFalse(snapshot.cancellable)
    func closed(_ work: () async throws -> Void) async {
      do { try await work(); XCTFail("closed instance must reject new work") }
      catch { XCTAssertEqual(error as? LocalAISetupError, .operationRevoked) }
    }
    await closed { _ = try await sameRuntime.start() }
    await closed { _ = try await sameRuntime.beginEdit(runID: "must-not-start") }
    await closed { try await sameRuntime.install(package: base) }
    await closed { try await sameRuntime.rollback(version: "old") }
    await closed { try await sameRuntime.updateConfiguration(config) }
    await closed { try await sameRuntime.prepareModels(acceptedResearchLicense: true) { _ in } }
    await closed { _ = try await sameRuntime.beginEnvironmentPreparation(operationID: UUID()) }
    try await sameRuntime.stop() // Idempotent owned cleanup remains admitted.
    XCTAssertFalse(FileManager.default.fileExists(atPath: config.runtimeRoot.path))
  }
  func testUnavailableCoordinatorAndConsentRemainReadOnly() async throws {
    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let environment = LocalAIEnvironmentCoordinator(configuration: .init(runtimeRoot: base.appendingPathComponent("not-created"), modelRoot: base), catalog: nil)
    let snapshot = await environment.inspect(); XCTAssertEqual(snapshot.stage, "unavailable")
    do { _ = try await environment.prepare(.init(artifactID: "none", modelStorage: .borrowedReadOnly(base), consent: nil)); XCTFail() }
    catch { XCTAssertEqual(error as? LocalAISetupError, .unavailable) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("not-created").path))
    let text = try LocalAIModelConsent.currentLicenseText(); XCTAssertFalse(text.isEmpty); XCTAssertLessThanOrEqual(text.utf8.count, 65_536)
    XCTAssertThrowsError(try LocalAIModelConsent(licenseID: "other", licenseSHA256: String(repeating: "0", count: 64), acceptedAt: Date()).validate())
    await environment.shutdown(); await environment.shutdown()
  }
  func testCancellationWaitsForNativeIOWorkerAndOwnedProcessJoin() async throws {
    final class Flag: @unchecked Sendable {
      private let lock = NSLock(); private var value = false
      func set() { lock.lock(); value = true; lock.unlock() }
      func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    let entered = expectation(description: "owned native IO entered"), joined = Flag()
    let io = Task<Void, Error> {
      try await RuntimeArtifactFiles.background { () throws -> Void in
        entered.fulfill(); defer { joined.set() }
        while true { try Task.checkCancellation(); usleep(1_000) }
      }
    }
    await fulfillment(of: [entered], timeout: 2)
    io.cancel(); _ = try? await io.value; XCTAssertTrue(joined.get())

    let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
    let pidFile = base.appendingPathComponent("owned.pid")
    let quoted = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let child = Task {
      try await RuntimeArtifactFiles.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '%s' \"$$\" > " + quoted + "; exec /bin/sleep 30"], log: base.appendingPathComponent("child.log"))
    }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: pidFile.path) { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    guard let text = try? String(contentsOf: pidFile), let pid = Int32(text) else {
      child.cancel(); _ = try? await child.value; return XCTFail("owned child did not enter")
    }
    child.cancel(); _ = try? await child.value
    XCTAssertEqual(Darwin.kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
  }

  private struct ZipEntry {
    let path: String, data: Data; let link: Bool
    init(_ path: String, _ text: String, link: Bool = false) { self.init(path, data: Data(text.utf8), link: link) }
    init(_ path: String, data: Data, link: Bool = false) { self.path = path; self.data = data; self.link = link }
  }
  private func makeZip(_ entries: [ZipEntry]) -> Data {
    var local = Data(), central = Data()
    func le(_ value: UInt64, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    func crc(_ data: Data) -> UInt32 {
      var value: UInt32 = 0xffffffff
      for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) } }
      return value ^ 0xffffffff
    }
    for entry in entries {
      let name = Data(entry.path.utf8), start = local.count, checksum = crc(entry.data)
      var extra = le(1, 2) + le(16, 2); extra += le(UInt64(entry.data.count), 8) + le(UInt64(entry.data.count), 8)
      local += le(0x04034b50, 4) + le(45, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(UInt64(checksum), 4)
      local += le(0xffffffff, 4) + le(0xffffffff, 4) + le(UInt64(name.count), 2) + le(UInt64(extra.count), 2) + name + extra + entry.data
      central += le(0x02014b50, 4) + le(0x0314, 2) + le(45, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(UInt64(checksum), 4)
      central += le(UInt64(entry.data.count), 4) + le(UInt64(entry.data.count), 4) + le(UInt64(name.count), 2)
      central += le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(UInt64((entry.link ? 0o120777 : 0o100644) << 16), 4) + le(UInt64(start), 4) + name
    }
    let end = le(0x06054b50, 4) + le(0, 2) + le(0, 2) + le(UInt64(entries.count), 2) + le(UInt64(entries.count), 2) + le(UInt64(central.count), 4) + le(UInt64(local.count), 4) + le(0, 2)
    return local + central + end
  }
}
