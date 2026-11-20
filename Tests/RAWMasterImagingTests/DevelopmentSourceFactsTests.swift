import XCTest
import AppKit
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentSourceFactsTests: XCTestCase {
  private func fixture() throws -> (URL, EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-source-facts-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let url = root.appendingPathComponent("source.png")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:12,pixelsHigh:8,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:48,bitsPerPixel:32)!
    for i in 0..<(12*8) {
      bitmap.bitmapData![i*4] = UInt8(i); bitmap.bitmapData![i*4+1] = 64
      bitmap.bitmapData![i*4+2] = 128; bitmap.bitmapData![i*4+3] = 255
    }
    let data = bitmap.representation(using:.png,properties:[:])!; try data.write(to:url)
    let digest = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    return (root,.init(projectID:"facts",assetID:"source",contentSHA256:digest,byteCount:Int64(data.count),
      admissionFingerprint:"admitted",sourceLocation:url))
  }
  func testFactsUseAdmittedImageAndDoNotRenderRecaptureOrRehash() async throws {
    let (root,source) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let service = DevelopmentPreviewService()
    let info = try await service.open(source:.raw(source))
    let before = await service.statistics()
    let facts = try await service.sourceFacts(sessionID:info.id,sourceGeneration:info.sourceGeneration)
    let again = try await service.sourceFacts(sessionID:info.id,sourceGeneration:info.sourceGeneration)
    XCTAssertEqual(facts,again)
    XCTAssertEqual(facts.sourceKind,.image) // .raw admission is not proof of a RAW decoder.
    XCTAssertEqual(facts.sourceBinding,.init(sourceContentID:source.contentSHA256,exifOrientation:1,orientedWidth:12,orientedHeight:8))
    XCTAssertEqual(facts.sourceGeneration,info.sourceGeneration); XCTAssertEqual(facts.decoderVersion,"image-io")
    XCTAssertEqual(facts.noiseReduction.sourceCapability,.image); XCTAssertNil(facts.noiseReduction.raw)
    XCTAssertEqual(facts.supportedPhotoFilters,Set(DevelopmentPhotoFilterV3.allCases))
    XCTAssertEqual(facts.photoFilterResourceVersion,"0a8a0e9aa4fb7dacdf6ad20d12d5f24dda4132c4b7880acd7fab1c28fa6c61f9")
    XCTAssertNil(facts.asShotWhiteBalance)
    XCTAssertEqual(facts.implementedAdjustments,Set([.light,.color,.blackAndWhite,.curves,.levels,.whiteBalance,.definition,.selectiveColor,.noiseReduction,.sharpen,.vignette,.retouch,.redEye,.texture,.clarity,.dehaze,.filter]))
    XCTAssertFalse(facts.automaticAdjustments.contains(.selectiveColor)); XCTAssertTrue(facts.automaticAdjustments.contains(.definition))
    XCTAssertTrue(facts.implementedAdjustments.contains(.dehaze))
    XCTAssertEqual(facts.dehazeContextV1?.source,facts.sourceBinding)
    XCTAssertEqual(facts.dehazeContextV1?.sourceGeneration,facts.sourceGeneration)
    XCTAssertNotEqual(facts.dehazeContextV1?.decoderContractFingerprint,facts.localDecoderContractFingerprint)
    XCTAssertTrue(facts.automaticAdjustments.isDisjoint(with:[.texture,.clarity,.dehaze,.retouch,.redEye]))
    XCTAssertNotNil(facts.initialWhiteBalanceState)
    let after = await service.statistics()
    XCTAssertEqual(after.sourceCaptures,before.sourceCaptures); XCTAssertEqual(after.sourceFullHashPasses,before.sourceFullHashPasses)
    XCTAssertEqual(after.sourceHashBytes,before.sourceHashBytes); XCTAssertEqual(after.completedRenders,0)
    let analysis = await service.analysisStatistics(); XCTAssertEqual(analysis.submitted,0)
    await service.closeAll()
  }
  func testWrongGenerationAndClosedLeaseRejectDespiteSharedCapture() async throws {
    let (root,source) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let service = DevelopmentPreviewService()
    let a = try await service.open(source:.raw(source)), b = try await service.open(source:.raw(source))
    do {
      _ = try await service.sourceFacts(sessionID:a.id,sourceGeneration:b.sourceGeneration)
      XCTFail("Foreign generation admitted")
    } catch DevelopmentPreviewError.sourceInvalidated {}
    await service.close(a.id)
    do {
      _ = try await service.sourceFacts(sessionID:a.id,sourceGeneration:a.sourceGeneration)
      XCTFail("Closed lease admitted")
    } catch DevelopmentPreviewError.closed {}
    let facts = try await service.sourceFacts(sessionID:b.id,sourceGeneration:b.sourceGeneration)
    XCTAssertEqual(facts.sourceBinding.sourceContentID,source.contentSHA256)
    await service.closeAll()
  }
  func testRevalidateRevokesOldGenerationAndSourceMutationRejectsFacts() async throws {
    let (root,source) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let service = DevelopmentPreviewService(), info = try await service.open(source:.raw(source))
    await service.invalidate(info.id)
    let fresh = try await service.revalidate(info.id,source:.raw(source))
    XCTAssertGreaterThan(fresh.sourceGeneration,info.sourceGeneration)
    do {
      _ = try await service.sourceFacts(sessionID:info.id,sourceGeneration:info.sourceGeneration)
      XCTFail("Old generation admitted after revalidation")
    } catch DevelopmentPreviewError.sourceInvalidated {}
    _ = try await service.sourceFacts(sessionID:fresh.id,sourceGeneration:fresh.sourceGeneration)
    try Data("changed source".utf8).write(to:source.sourceLocation)
    do {
      _ = try await service.sourceFacts(sessionID:fresh.id,sourceGeneration:fresh.sourceGeneration)
      XCTFail("Mutated original admitted")
    } catch DevelopmentPreviewError.sourceInvalidated {}
    await service.closeAll()
  }
  func testCaptureAuthorityAndArtifactKindAreCheckedWithoutNativeWork() async throws {
    let (root,source) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let service = DevelopmentPreviewService()
    do {
      let artifact = RenderArtifact(sha256:source.contentSHA256,byteCount:source.byteCount,pixelWidth:12,pixelHeight:8,
        encoding:"png",bitDepth:8,colorSpace:"sRGB")
      let info = try await service.open(source:.artifact(fileURL:source.sourceLocation,artifact:artifact))
      let facts = try await service.sourceFacts(sessionID:info.id,sourceGeneration:info.sourceGeneration)
      XCTAssertEqual(facts.sourceKind,.generatedArtifact); XCTAssertTrue(facts.implementedAdjustments.isEmpty); XCTAssertNil(facts.dehazeContextV1)
      XCTAssertEqual(facts.supportedPhotoFilters,[.original]); XCTAssertNil(facts.photoFilterResourceVersion)
      XCTAssertEqual(facts.sourceBinding.sourceContentID,artifact.sha256); XCTAssertNil(facts.asShotWhiteBalance)
      let captured = await service.capturedFileForTesting(info.id)
      let capture = try XCTUnwrap(captured)
      let file = capture.url.standardizedFileURL.resolvingSymlinksInPath()
      let directory = file.deletingLastPathComponent()
      let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
      let prefix = "RAWMaster-render-"
      // Permission changes are confined to this service's own test capture, never the source fixture.
      guard directory.deletingLastPathComponent().path == temporary.path,
        directory.lastPathComponent.hasPrefix(prefix),
        UUID(uuidString:String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
        file.lastPathComponent == "source.png",
        file != source.sourceLocation.standardizedFileURL.resolvingSymlinksInPath(),
        (try FileManager.default.attributesOfItem(atPath:file.path))[.type] as? FileAttributeType == .typeRegular,
        (try FileManager.default.attributesOfItem(atPath:directory.path))[.type] as? FileAttributeType == .typeDirectory else {
        throw NSError(domain:"DevelopmentSourceFactsTests.captureScope",code:1)
      }
      try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
      try Data("changed capture".utf8).write(to:file)
      do {
        _ = try await service.sourceFacts(sessionID:info.id,sourceGeneration:info.sourceGeneration)
        XCTFail("Mutated immutable capture admitted")
      } catch DevelopmentPreviewError.sourceInvalidated {}
      XCTAssertEqual(try RenderFiles.hash(source.sourceLocation),source.contentSHA256)
      let stats = await service.statistics(); XCTAssertEqual(stats.completedRenders,0)
    } catch {
      // Async cleanup must actually join before throwing and before the outer fixture defer runs.
      await service.closeAll()
      throw error
    }
    await service.closeAll()
  }
}
