import CryptoKit
import Darwin
import Foundation
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentVerifiedDehazeCaptureTests: XCTestCase {
  private func withSource(_ body: (EditingSourceSnapshot, Data) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("source.arw")
    let bytes = Data("immutable private capture".utf8)
    try bytes.write(to: file)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try body(.init(projectID: "test", assetID: "original", contentSHA256: digest,
      byteCount: Int64(bytes.count), admissionFingerprint: "test", sourceLocation: file), bytes)
  }

  func testOnlyMatchingWritesIssueAProofForTheFrozenPrivateInode() throws {
    try withSource { source, _ in
      var bad = source
      bad.contentSHA256 = String(repeating: "0", count: 64)
      XCTAssertThrowsError(try RenderFiles.verifiedPreviewCapture(bad))
      bad = source; bad.byteCount += 1
      XCTAssertThrowsError(try RenderFiles.verifiedPreviewCapture(bad))
      let proof = try RenderFiles.verifiedPreviewCapture(source)
      defer { try? FileManager.default.removeItem(at: proof.url.deletingLastPathComponent()) }
      let attributes = try FileManager.default.attributesOfItem(atPath: proof.url.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
      XCTAssertEqual(proof.stamp, try PreviewFileStamp.read(proof.url))
      XCTAssertEqual(proof.stamp.size, source.byteCount)
      XCTAssertEqual(proof.contentSHA256, try RenderFiles.hash(proof.url))
      XCTAssertEqual(proof.contentSHA256, source.contentSHA256)
      XCTAssertNotEqual(proof.stamp.inode, try PreviewFileStamp.read(source.sourceLocation).inode)
      XCTAssertThrowsError(try proof.requireCurrent(at: source.sourceLocation)) {
        XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, proof.id)
      }
      XCTAssertThrowsError(try proof.withCurrent(at: proof.url) { throw CancellationError() }) {
        XCTAssertTrue($0 is CancellationError)
      }
      XCTAssertNoThrow(try proof.requireCurrent(at: proof.url))
    }
  }

  func testAnIdenticalReplacementWinsOverAnOperationErrorAndCannotBeResigned() throws {
    try withSource { source, bytes in
      let proof = try RenderFiles.verifiedPreviewCapture(source)
      let directory = proof.url.deletingLastPathComponent()
      defer { try? FileManager.default.removeItem(at: directory) }
      XCTAssertThrowsError(try proof.withCurrent(at: proof.url) {
        try FileManager.default.moveItem(at: proof.url, to: directory.appendingPathComponent("previous"))
        try bytes.write(to: proof.url, options: .withoutOverwriting)
        throw CancellationError()
      }) { XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, proof.id) }
      XCTAssertEqual(try RenderFiles.hash(proof.url), proof.contentSHA256)
      XCTAssertNotEqual(try PreviewFileStamp.read(proof.url).inode, proof.stamp.inode)
      XCTAssertThrowsError(try PreviewNativeSource.openVerifiedRAW(proof, memoryLimit: 32)) {
        XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, proof.id)
      }
      try FileManager.default.removeItem(at: proof.url)
      try FileManager.default.createSymbolicLink(at: proof.url, withDestinationURL: directory.appendingPathComponent("previous"))
      XCTAssertEqual(try PreviewFileStamp.read(proof.url).inode, proof.stamp.inode)
      XCTAssertThrowsError(try proof.requireCurrent(at: proof.url)) {
        XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, proof.id)
      }
    }
  }

  func testSameInodeSameSizeRewriteWithRestoredMtimeFailsThePostcheck() throws {
    try withSource { source, bytes in
      let proof = try RenderFiles.verifiedPreviewCapture(source)
      defer { try? FileManager.default.removeItem(at: proof.url.deletingLastPathComponent()) }
      XCTAssertThrowsError(try proof.withCurrent(at: proof.url) {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: proof.url.path)
        let writer = try FileHandle(forWritingTo: proof.url)
        defer { try? writer.close() }
        try writer.write(contentsOf: Data(repeating: 0x49, count: bytes.count))
        try writer.synchronize()
        let mtime = timespec(tv_sec: proof.stamp.seconds, tv_nsec: proof.stamp.nanoseconds)
        XCTAssertEqual([mtime, mtime].withUnsafeBufferPointer { Darwin.futimens(writer.fileDescriptor, $0.baseAddress) }, 0)
        XCTAssertEqual(Darwin.fchmod(writer.fileDescriptor, 0o400), 0)
      }) { XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, proof.id) }
      let mutated = try PreviewFileStamp.read(proof.url)
      XCTAssertEqual(mutated.device, proof.stamp.device); XCTAssertEqual(mutated.inode, proof.stamp.inode)
      XCTAssertEqual(mutated.size, proof.stamp.size)
      XCTAssertEqual(mutated.seconds, proof.stamp.seconds); XCTAssertEqual(mutated.nanoseconds, proof.stamp.nanoseconds)
      XCTAssertNotEqual(mutated, proof.stamp)
      XCTAssertNotEqual(try RenderFiles.hash(proof.url), proof.contentSHA256)
    }
  }

  private func qualificationRAW() throws -> EditingSourceSnapshot {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["RAWMASTER_PREVIEW_BENCHMARK_RAW"] ?? environment["RAWMASTER_FLASHRAW_TEST_RAW"] else {
      throw XCTSkip("Set RAWMASTER_PREVIEW_BENCHMARK_RAW to the qualification RAW.")
    }
    let source = URL(fileURLWithPath: path)
    return EditingSourceSnapshot(projectID: "test", assetID: "raw", contentSHA256: try RenderFiles.hash(source),
      byteCount: try PreviewFileStamp.read(source).size, admissionFingerprint: "actual-raw", sourceLocation: source)
  }

  func testRealRAWMatchesFreshDecoderAndRejectsStalePreparationAndForeignCapture() throws {
    let snapshot = try qualificationRAW()
    let source = snapshot.sourceLocation
    let proof = try RenderFiles.verifiedPreviewCapture(snapshot)
    defer { try? FileManager.default.removeItem(at: proof.url.deletingLastPathComponent()) }
    let native = try PreviewNativeSource.openVerifiedRAW(proof, memoryLimit: 32)
    let actual = try native.verifiedDehazeContext(for: proof.url, guideStamp: native.captureStamp)
    XCTAssertEqual(actual, try DevelopmentDehazeContextFactoryV1.fromCapture(proof.url))
    XCTAssertEqual(actual.source.sourceContentID, snapshot.contentSHA256)
    XCTAssertThrowsError(try native.verifiedDehazeContext(for: source, guideStamp: native.captureStamp)) {
      XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, proof.id)
    }
    XCTAssertThrowsError(try native.verifiedDehazeContext(for: proof.url, guideStamp: PreviewFileStamp.read(source))) {
      XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, proof.id)
    }
    var recipe = DevelopmentRecipe(adjustmentsV3: .init())
    recipe.adjustmentsV3!.rawDecoder = .flashRaw031
    let input = try recipe.prospectiveDehazeInputV1(context: actual, algorithm: .positiveColorGuideV2).input
    recipe.adjustmentsV3!.advancedDetail.dehaze = .init(enabled: true, amount: 15)
    recipe.adjustmentsV3!.advancedDetail.preparedDehaze = .init(sourceBinding: actual.source, inputFingerprint: input.inputFingerprint,
      airlight: .init(red: 1, green: 1, blue: 1), algorithmVersion: 2)
    for amount in [15.0, 45.0] {
      recipe.adjustmentsV3!.advancedDetail.dehaze.amount = amount
      try DevelopmentDehazeContextFactoryV1.requirePrepared(recipe, context: actual)
    }
    var foreign = actual.source; foreign.sourceContentID = String(repeating: "0", count: 64)
    for stale in [DevelopmentDehazeContextV1(source: foreign, sourceGeneration: 1, decoderContractFingerprint: actual.decoderContractFingerprint),
                  DevelopmentDehazeContextV1(source: actual.source, sourceGeneration: 1, decoderContractFingerprint: String(repeating: "0", count: 64))] {
      XCTAssertThrowsError(try DevelopmentDehazeContextFactoryV1.requirePrepared(recipe, context: stale))
    }
    let ordinary = try PreviewNativeSource(capture: proof.url, byteCount: snapshot.byteCount, artifact: false, memoryLimit: 32)
    XCTAssertThrowsError(try ordinary.verifiedDehazeContext(for: proof.url, guideStamp: ordinary.captureStamp))
  }

  /// Keep the inode alive while testing for leaks after unlink or replacement.
  /// The private capture has a unique dev/inode. Ignore the witness itself and
  /// match the read-only, nonblocking, close-on-exec flags of the writer's anchor.
  private struct CaptureDescriptors {
    let witness: FileHandle
    let stamp: PreviewFileStamp

    init(at url: URL) throws {
      witness = try FileHandle(forReadingFrom: url)
      stamp = try PreviewFileStamp.read(descriptor: witness.fileDescriptor)
    }

    func anchors() throws -> Set<Int32> {
      let names = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
      var matches = Set<Int32>()
      for name in names {
        guard let fd = Int32(name), fd != witness.fileDescriptor else { continue }
        var status = stat()
        guard Darwin.fstat(fd, &status) == 0, status.st_dev == stamp.device, status.st_ino == stamp.inode else { continue }
        let flags = Darwin.fcntl(fd, F_GETFL), descriptorFlags = Darwin.fcntl(fd, F_GETFD)
        if flags >= 0, descriptorFlags >= 0, flags & O_ACCMODE == O_RDONLY,
           flags & O_NONBLOCK != 0, descriptorFlags & FD_CLOEXEC != 0 { matches.insert(fd) }
      }
      return matches
    }
  }

  private func requireAnchorDevice() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_NATIVE_DEHAZE_GUIDE"] != "0", environment["RAWMASTER_NATIVE_DEHAZE_VERIFIED_CAPTURE"] != "0",
          MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true else {
      throw XCTSkip("The resident capture lifecycle requires an enabled unified-memory device.")
    }
  }

  private func capturedFile(_ lease: PreviewSessionInfo, in service: DevelopmentPreviewService) async throws -> (id: UUID, url: URL) {
    let file = await service.capturedFileForTesting(lease.id)
    return try XCTUnwrap(file)
  }

  func testRealRAWPreviewSharesOneAnchorUntilTheLastLeaseAndReleasesItOnEveryClose() async throws {
    try requireAnchorDevice()
    let source = try qualificationRAW()
    let service = DevelopmentPreviewService(policy: .init(contextMemoryLimitMiB: 511))
    do {
      for (index, expected) in [0, 1, 1].enumerated() {
        if index == 1 { try await service.configure(policy: .init(contextMemoryLimitMiB: 512)) }
        let first = try await service.open(source: .raw(source))
        let capture = try await capturedFile(first, in: service)
        let observation = try CaptureDescriptors(at: capture.url)
        defer { try? observation.witness.close() }
        let live = try observation.anchors()
        XCTAssertEqual(live.count, expected)
        let second = try await service.open(source: .raw(source))
        let shared = try await capturedFile(second, in: service)
        XCTAssertEqual(shared.id, capture.id)
        XCTAssertEqual(try observation.anchors(), live)
        await service.close(first.id)
        _ = try await service.sourceFacts(sessionID: second.id, sourceGeneration: second.sourceGeneration)
        XCTAssertEqual(try observation.anchors(), live)
        await service.close(second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.url.path))
        XCTAssertTrue(try observation.anchors().isEmpty)
      }
      let stats = await service.statistics()
      XCTAssertEqual(stats.sourceCaptures, 3)
      XCTAssertEqual(stats.sourceSnapshotDiskBytes, 0)
    } catch { await service.closeAll(); throw error }
    await service.closeAll()
  }

  func testRealRAWCaptureFaultReleasesAnchorBeforeFreshOpenAndOldLeaseCannotReleaseTheReplacement() async throws {
    try requireAnchorDevice()
    let source = try qualificationRAW()
    let service = DevelopmentPreviewService(policy: .init(contextMemoryLimitMiB: 512))
    do {
      let first = try await service.open(source: .raw(source))
      let old = try await capturedFile(first, in: service)
      let retired = try CaptureDescriptors(at: old.url)
      defer { try? retired.witness.close() }
      XCTAssertEqual(try retired.anchors().count, 1)
      try FileManager.default.removeItem(at: old.url)
      do {
        _ = try await service.sourceFacts(sessionID: first.id, sourceGeneration: first.sourceGeneration)
        XCTFail("Facts survived loss of the private capture.")
      } catch DevelopmentPreviewError.sourceInvalidated {}
      let second = try await service.open(source: .raw(source))
      let replacement = try await capturedFile(second, in: service)
      XCTAssertNotEqual(old.id, replacement.id)
      XCTAssertTrue(try retired.anchors().isEmpty)
      let current = try CaptureDescriptors(at: replacement.url)
      defer { try? current.witness.close() }
      let live = try current.anchors()
      XCTAssertEqual(live.count, 1)
      await service.close(first.id)
      XCTAssertEqual(try current.anchors(), live)
      await service.close(second.id)
      XCTAssertTrue(try current.anchors().isEmpty)
      let stats = await service.statistics()
      XCTAssertEqual(stats.sourceCaptures, 2)
      XCTAssertEqual(stats.sourceSnapshotDiskBytes, 0)
    } catch { await service.closeAll(); throw error }
    await service.closeAll()
  }

  func testIsolatedClassicCatalogReplacementClosesTheOldStoreAndChangesTheLiveStageIdentity() throws {
    guard MTLCreateSystemDefaultDevice()?.supportsDynamicLibraries == true else {
      throw XCTSkip("The Classic stage requires a Metal device with dynamic library support.")
    }
    let bundled = try XCTUnwrap(DevelopmentPhotoFilterResourceStore.bundledRoot)
    let sourceManifest = bundled.appendingPathComponent("catalog-v1.json")
    let data = try Data(contentsOf: sourceManifest)
    let catalog = try DevelopmentPhotoFilterCatalog.decode(data)
    let vivid = try XCTUnwrap(catalog.looks.first { $0.id == .vivid })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifest = directory.appendingPathComponent("catalog-v1.json")
    try data.write(to: manifest)
    for plane in vivid.planes {
      try FileManager.default.copyItem(at: bundled.appendingPathComponent(plane.file), to: directory.appendingPathComponent(plane.file))
    }
    let original = try RenderFiles.hash(manifest)
    let prefix = DevelopmentPhotoFilterEngineV3.operatorVersion + "/catalog:"
    let live = DevelopmentPhotoFilterResourceStore(resourceRoot: directory)
    XCTAssertEqual(try DevelopmentPhotoFilterEngineV3.stageIdentity(resources: live), prefix + original)

    // Keep the shipped Vivid samples and metadata. This second valid manifest
    // declares just that look. Only the test's copied manifest is replaced.
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let looks = try XCTUnwrap(json["looks"] as? [[String: Any]])
    json["looks"] = looks.filter { ($0["id"] as? String) == vivid.id.rawValue }
    let revised = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    try revised.write(to: manifest, options: .atomic)
    let replacement = try RenderFiles.hash(manifest)
    XCTAssertNotEqual(original, replacement)
    XCTAssertEqual(try DevelopmentPhotoFilterEngineV3.stageIdentity(resources: live), "photo-filter-closed-v1")
    let reopened = DevelopmentPhotoFilterResourceStore(resourceRoot: directory)
    XCTAssertEqual(try DevelopmentPhotoFilterEngineV3.stageIdentity(resources: reopened), prefix + replacement)
    XCTAssertEqual(try DevelopmentPhotoFilterEngineV3.stageIdentity(resources: live), "photo-filter-closed-v1")
    XCTAssertEqual(try RenderFiles.hash(sourceManifest), original)
  }
}
