import XCTest
import AppKit
import ImageIO
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewNativeInputProfileTests: XCTestCase {
  private func fixture() throws -> (URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-Profile-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file=root.appendingPathComponent("source.tiff")
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:28,pixelsHigh:18,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:112,bitsPerPixel:32))
    for y in 0..<18 { for x in 0..<28 {
      let i=y*112+x*4;bitmap.bitmapData![i]=UInt8(12+x*5);bitmap.bitmapData![i+1]=UInt8(9+y*8)
      bitmap.bitmapData![i+2]=UInt8(20+(x*3+y*4)%100);bitmap.bitmapData![i+3]=255
    }}
    let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(destination,try XCTUnwrap(bitmap.cgImage),nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let size=try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber
    return (root,.init(projectID:"profile",assetID:"owned",contentSHA256:try RenderFiles.hash(file),
      byteCount:try XCTUnwrap(size).int64Value,admissionFingerprint:"tiny",sourceLocation:file))
  }
  private func policy(bitmap: Int=0) -> PreviewResourcePolicy {
    .init(bitmapCacheBytes:bitmap,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1,nativePointwiseProfile:true)
  }
  private func recipe(_ s: Double=0.4) throws -> DevelopmentRecipe {
    try DevelopmentRecipe().applying(.promoteToV3).applying(.setParameters(.color(.init(enabled:true,saturation:s))))
  }
  private func request(_ lease:PreviewSessionInfo,_ consumer:PreviewConsumerID,_ r:DevelopmentRecipe,_ revision:UInt64,
                       _ quality:PreviewQuality = .interactive) -> DevelopmentPreviewRequest {
    .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,
      revision:revision,recipe:r,quality:quality,viewport:.init(maxPixel:2400))
  }
  private func bytes(_ image:NSImage) throws -> [UInt8] {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    let c=try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
      space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
    c.setBlendMode(.copy);c.interpolationQuality = .none;c.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:cg.width*cg.height*4))
  }
  func testBootstrapIsExactQAOnlyAndDomainNeverMutatesActualRecipe() throws {
    XCTAssertFalse(PreviewResourcePolicy.default.nativePointwiseProfile)
    let key="RAWMASTER_QA_NATIVE_POINTWISE_V1"
    for bundle in ["io.robinqu.RAWMaster.preview021","io.robinqu.RAWMaster.preview022"] {
      XCTAssertTrue(PreviewNativeInputProfileV1.bootstrap(bundleIdentifier:bundle,environment:[key:"1"]))
      XCTAssertFalse(PreviewNativeInputProfileV1.bootstrap(bundleIdentifier:bundle,environment:[:]))
      for value in ["true","01","0",""] {
        XCTAssertFalse(PreviewNativeInputProfileV1.bootstrap(bundleIdentifier:bundle,environment:[key:value]))
      }
    }
    for id in [nil,"io.robinqu.RAWMaster","io.robinqu.RAWMaster.preview020final",
               "io.robinqu.RAWMaster.focusqa022","io.robinqu.RAWMaster.preview022.extra",
               "io.robinqu.RAWMaster.preview022 ","io.robinqu.RAWMaster.Preview022"] {
      XCTAssertFalse(PreviewNativeInputProfileV1.bootstrap(bundleIdentifier:id,environment:[key:"1"]))
    }
    for s in [-1.0,0,0.4,2] {
      let r=try recipe(s),fp=try EditingFingerprint.of(r)
      XCTAssertTrue(try PreviewNativeInputProfileV1.domain(r,size:.init(width:28,height:18)))
      XCTAssertEqual(try EditingFingerprint.of(r),fp)
    }
    var r=try recipe();r.adjustmentsV3!.light = .init(enabled:true,exposure:0.1)
    XCTAssertFalse(try PreviewNativeInputProfileV1.domain(r,size:.init(width:28,height:18)))
    XCTAssertFalse(try PreviewNativeInputProfileV1.domain(DevelopmentRecipe(),size:.init(width:28,height:18)))
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let descriptor=try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:"authority",generation:1,verifiedContentID:source.contentSHA256)
    XCTAssertNoThrow(try PreviewNativeInputProfileV1.verify(recipe(),native:native,descriptor:descriptor))
    XCTAssertEqual(descriptor.sourceDepth,8)
    let otherCapture=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    XCTAssertThrowsError(try PreviewNativeInputProfileV1.verify(recipe(),native:otherCapture,descriptor:descriptor))
    XCTAssertThrowsError(try PreviewNativeInputProfileV1.verify(r,native:native,descriptor:descriptor)) // Actual non-default request, not an FP alias.
  }
  func testSharedFITBootstrapRequiresExactPreview022AndBothFlags() {
    let profile="RAWMASTER_QA_NATIVE_POINTWISE_V1", fit="RAWMASTER_QA_SHARED_FIT_V1"
    let bundle="io.robinqu.RAWMaster.preview022"
    XCTAssertTrue(PreviewNativeInputProfileV1.sharedFITBootstrap(bundleIdentifier:bundle,environment:[profile:"1",fit:"1"]))
    for other in [nil,"io.robinqu.RAWMaster","io.robinqu.RAWMaster.preview021",bundle+".extra"] {
      XCTAssertFalse(PreviewNativeInputProfileV1.sharedFITBootstrap(bundleIdentifier:other,environment:[profile:"1",fit:"1"]))
    }
    for env in [[profile:"1"],[fit:"1"],[profile:"1",fit:"true"],[profile:"0",fit:"1"]] {
      XCTAssertFalse(PreviewNativeInputProfileV1.sharedFITBootstrap(bundleIdentifier:bundle,environment:env))
    }
  }
  func testSharedFITServiceWarmPixelsAndBitmapReplay() async throws {
    let (root,source)=try fixture()
    defer { try? FileManager.default.removeItem(at:root) }
    let control=DevelopmentPreviewService(policy:policy(bitmap:1_048_576))
    let candidate=DevelopmentPreviewService(policy:policy(bitmap:1_048_576),qaSharedFITIntermediate:true)
    do {
      let cold=try recipe(0.2), warm=try recipe(0.3)
      let a=try await control.open(source:.raw(source)), b=try await candidate.open(source:.raw(source))
      let ca=PreviewConsumerID(),cb=PreviewConsumerID()
      _=try await control.render(request(a,ca,cold,1))
      _=try await candidate.render(request(b,cb,cold,1))
      let coldReceipt=await candidate.nativePointwiseReceiptForTesting()
      XCTAssertEqual(coldReceipt?.sourceCold,true)
      XCTAssertEqual(coldReceipt?.sharedFITIntermediateInserted,false)
      let off=try await control.render(request(a,ca,warm,2))
      let on=try await candidate.render(request(b,cb,warm,2))
      let offReceipt=await control.nativePointwiseReceiptForTesting()
      let onReceipt=await candidate.nativePointwiseReceiptForTesting()
      XCTAssertEqual(offReceipt?.sharedFITIntermediateInserted,false)
      XCTAssertEqual(onReceipt?.sharedFITIntermediateInserted,true)
      XCTAssertEqual(onReceipt?.sourceCold,false)
      XCTAssertEqual(onReceipt?.samplerCold,false)
      XCTAssertEqual(onReceipt?.owner,coldReceipt?.owner)
      XCTAssertEqual(onReceipt?.proofID,coldReceipt?.proofID)
      XCTAssertTrue(PreviewQALifecycleTrace.freshSharedFITInsertion(receipt:onReceipt,bitmapReplay:false))
      XCTAssertEqual(try bytes(off.image),try bytes(on.image))
      let before=await candidate.statistics()
      let replay=try await candidate.render(request(b,cb,warm,3))
      let after=await candidate.statistics()
      XCTAssertEqual(replay.outputKey,on.outputKey)
      XCTAssertEqual(try bytes(replay.image),try bytes(on.image))
      XCTAssertEqual(after.cacheHits,before.cacheHits+1)
      XCTAssertEqual(after.completedRenders,before.completedRenders)
      let replayReceipt=await candidate.nativePointwiseReceiptForTesting()
      XCTAssertFalse(PreviewQALifecycleTrace.freshSharedFITInsertion(receipt:replayReceipt,bitmapReplay:true))
    } catch { await candidate.closeAll();await control.closeAll();throw error }
    await control.closeAll()
    await candidate.closeAll()
    for service in [control,candidate] {
      let final=await service.statistics()
      XCTAssertEqual(final.rawBaseResidentBytes,0)
      XCTAssertEqual(final.rawBasePinnedBytes,0)
      XCTAssertEqual(final.cachedBitmapBytes,0)
      XCTAssertEqual(final.activeNativeRenders,0)
      let owned=await service.interactiveKnownOwnedForTesting()
      XCTAssertTrue(owned.values.allSatisfy { $0 == 0 })
    }
  }
  func testClosedCauseUpgradeAndPublicationAuthority() throws {
    let signal=DevelopmentAnalysisCancellation();signal.cancel(cause:.frameSuperseded)
    XCTAssertThrowsError(try signal.check());XCTAssertNoThrow(try signal.checkInputAuthority())
    var published=0
    try signal.withInputPublication { published+=1 }
    XCTAssertEqual(published,1);XCTAssertTrue(signal.recordPreservedInputIfFrameOnly())
    signal.cancel(cause:.consumerClosing);signal.cancel(cause:.frameSuperseded)
    XCTAssertThrowsError(try signal.checkInputAuthority())
    XCTAssertThrowsError(try signal.withInputPublication { published+=1 })
    XCTAssertEqual(published,1);XCTAssertFalse(signal.recordPreservedInputIfFrameOnly())
    let unknown=DevelopmentAnalysisCancellation();unknown.cancel()
    XCTAssertThrowsError(try unknown.checkInputAuthority())
  }
  func testInteractiveSettledInteractiveUsesOneInputAndActualFullCanonicalRenderer() async throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let service=DevelopmentPreviewService(policy:policy()),control=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0))
    do {
      let lease=try await service.open(source:.raw(source)),c=PreviewConsumerID(),r=try recipe()
      let fast=try await service.render(request(lease,c,r,1))
      let observedFirst=await service.nativePointwiseReceiptForTesting(),first=try XCTUnwrap(observedFirst)
      let settled=try await service.render(request(lease,c,r,2,.settled))
      let observedFull=await service.nativePointwiseReceiptForTesting(),full=try XCTUnwrap(observedFull)
      XCTAssertTrue(fast.approximate);XCTAssertFalse(settled.approximate)
      XCTAssertTrue(first.certified);XCTAssertTrue(full.canonicalFullChecks);XCTAssertFalse(full.certified)
      XCTAssertEqual(first.owner,full.owner);XCTAssertFalse(full.sourceCold)
      let controlLease=try await control.open(source:.raw(source))
      let baseline=try await control.render(request(controlLease,PreviewConsumerID(),r,1,.settled))
      let a=try bytes(settled.image),b=try bytes(baseline.image)
      XCTAssertEqual(a.count,b.count)
      for i in a.indices { XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),2) }
      _=try await service.render(request(lease,c,recipe(0.6),3))
      let stats=await service.statistics()
      XCTAssertEqual(stats.rawBaseFills,1);XCTAssertEqual(stats.rawBaseHits,2)
      XCTAssertEqual(stats.nativeProfileCanonicalJobs,1);XCTAssertEqual(stats.nativeProfileCanonicalValidatedOutputs,1)
      XCTAssertEqual(stats.maximumObservedNativeRenders,1)
    } catch { await service.closeAll();await control.closeAll();throw error }
    await service.closeAll();await control.closeAll()
    let final=await service.statistics();XCTAssertEqual(final.rawBaseResidentBytes,0);XCTAssertEqual(final.rawBasePinnedBytes,0)
  }
  func testSemanticZeroRejectsUnmanagedThenReusesManagedWithFreshMetadataAndKeepsInput() async throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let service=DevelopmentPreviewService(policy:policy(bitmap:1_048_576))
    do {
      let lease=try await service.open(source:.raw(source)),c=PreviewConsumerID(),zero=try recipe(0)
      let ordinary=try await service.render(request(lease,c,DevelopmentRecipe(),1,.settled))
      let managed=try await service.render(request(lease,c,zero,2))
      XCTAssertEqual(ordinary.outputKey,managed.outputKey);XCTAssertNotEqual(ordinary.frameID,managed.frameID)
      let initial=await service.statistics();XCTAssertEqual(initial.cacheHits,0) // No unmanaged adoption.
      _=try await service.render(request(lease,c,recipe(0.4),3))
      _=try await service.render(request(lease,c,recipe(0.4),4,.settled))
      let replay=try await service.render(request(lease,c,zero,5))
      XCTAssertEqual(replay.outputKey,managed.outputKey);XCTAssertEqual(replay.revision,5)
      XCTAssertEqual(replay.quality,.interactive);XCTAssertFalse(replay.approximate)
      XCTAssertEqual(replay.sourceGeneration,lease.sourceGeneration);XCTAssertNotEqual(replay.frameID,managed.frameID)
      _=try await service.render(request(lease,c,recipe(0.6),6))
      let stats=await service.statistics()
      XCTAssertEqual(stats.nativeProfileSemanticBitmapHits,1);XCTAssertEqual(stats.rawBaseFills,1)
      XCTAssertEqual(stats.rawBaseHits,2) // Zero semantic replay did NOT evict or create native work.
      XCTAssertEqual(try bytes(managed.image),try bytes(replay.image))
    } catch { await service.closeAll();throw error }
    await service.closeAll()
  }
  func testOutsideSatDomainSettledKeepsOriginalRoute() async throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let service=DevelopmentPreviewService(policy:policy())
    do {
      let lease=try await service.open(source:.raw(source));var r=try recipe()
      r.adjustmentsV3!.light = .init(enabled:true,exposure:0.2)
      let frame=try await service.render(request(lease,PreviewConsumerID(),r,1,.settled))
      XCTAssertFalse(frame.approximate)
      let stats=await service.statistics();XCTAssertEqual(stats.nativeProfileCanonicalJobs,0);XCTAssertEqual(stats.rawBaseFills,0)
    } catch { await service.closeAll();throw error }
    await service.closeAll()
  }
  func testFrameOnlyColdCancellationPublishesVerifiedInputWithoutPostThenWarmReuses() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe();var plan=try native.nativePointwisePlan(recipe:r,sourceKey:"frame",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400);plan.preserveVerifiedInput=true
    let cancellation=DevelopmentAnalysisCancellation();var labels=[String]()
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{ label in
      labels.append(label);if label=="base-native-fill-joined" { cancellation.cancel(cause:.frameSuperseded) }
    })
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    try pool.withWorker {
      try autoreleasepool {
        XCTAssertThrowsError(try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,
          memoryLimit:512,cancellation:cancellation,canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol }))
      }
      XCTAssertTrue(cancellation.didPreserveInput);XCTAssertFalse(labels.contains("pointwise-post/prepare-before"))
      XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(pool.statistics.pinnedBytes,0)
      try autoreleasepool {
        let warm=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol })
        XCTAssertFalse(try XCTUnwrap(warm.nativePointwise).sourceCold)
      }
      XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(pool.statistics.hits,1);_ = try pool.drain()
    }
    scope.closeAndRetire();XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
  func testDestructiveUpgradeAfterFrameCancelPreventsLatePublication() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe();var plan=try native.nativePointwisePlan(recipe:r,sourceKey:"revoked",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400);plan.preserveVerifiedInput=true
    let cancellation=DevelopmentAnalysisCancellation()
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{ label in
      if label=="base-native-fill-joined" { cancellation.cancel(cause:.frameSuperseded) }
      if label=="base-CPU-finite-complete" { cancellation.cancel(cause:.sourceInvalidated) }
    })
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    try pool.withWorker {
      try autoreleasepool {
        XCTAssertThrowsError(try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,
          memoryLimit:512,cancellation:cancellation,canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol }))
      }
      XCTAssertFalse(cancellation.didPreserveInput);XCTAssertEqual(pool.statistics.fills,0)
      XCTAssertEqual(pool.statistics.buildingBytes,0);XCTAssertEqual(pool.statistics.residentBytes,0)
      _ = try pool.drain()
    }
    scope.closeAndRetire();XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
  func testRealCanonicalRendererChecksCancellationAfterItsActualJoinedFiniteTask() throws {
    enum JoinedStop:Error { case stopped }
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
      .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    defer { context.clearCaches() }
    var checks=0
    XCTAssertThrowsError(try DevelopmentRendererV3.develop(source.sourceLocation,recipe:recipe(),context:context,
      checkCancellation:{ checks+=1;if checks==2 { throw JoinedStop.stopped } })) { error in
      if case JoinedStop.stopped=error {} else { XCTFail("Expected joined finite boundary, got \(error)") }
    }
    // The strict sat path's first callbacks are S3 before writer / after actual wait+pool drain.
    XCTAssertEqual(checks,2)
  }
  func testCloseUpgradesAlreadyDisabledFrameAndNoLateInputPublishes() async throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let entered=expectation(description:"actual input task joined"),gate=DispatchSemaphore(value:0)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{ label in
      if label=="base-native-fill-joined" { entered.fulfill();gate.wait() }
    })
    let service=DevelopmentPreviewService(policy:policy(bitmap:1_048_576),rawBasePoolForTesting:pool)
    let lease:PreviewSessionInfo
    do { lease=try await service.open(source:.raw(source)) }
    catch { await service.closeAll();throw error }
    do {
    let consumer=PreviewConsumerID(),r=try recipe(),zero=try recipe(0)
    _ = try await service.render(request(lease,consumer,zero,1)) // Managed semantic entry exists.
    let render=Task { try await service.render(request(lease,consumer,r,2)) }
    await fulfillment(of:[entered],timeout:10)
    await service.cancel(consumerID:consumer) // Disables delivery with a frame-only cause first.
    await service.handleMemoryPressure(critical:true) // Upgrade and retire cached ticket while worker remains owned.
    do {
      _ = try await service.render(request(lease,consumer,zero,3))
      XCTFail("Retired semantic bitmap must not cross critical-pressure admission")
    } catch { XCTAssertEqual(error as? DevelopmentPreviewError,.memoryBudgetExceeded) }
    let closing=Task { await service.close(lease.id) }
    var revoked=false
    for _ in 0..<100 {
      do { _ = try await service.sourceFacts(sessionID:lease.id,sourceGeneration:lease.sourceGeneration) }
      catch { revoked=(error as? DevelopmentPreviewError) == .closed;break }
      await Task.yield()
    }
    gate.signal() // Always release the real worker, including an assertion/timeout failure.
    XCTAssertTrue(revoked)
    do { _ = try await render.value;XCTFail("Revoked frame must not deliver") } catch {}
    await closing.value;await service.closeAll()
    let stats=await service.statistics()
    XCTAssertEqual(stats.rawBaseFills,0);XCTAssertEqual(stats.nativeProfilePreservedInputs,0)
    XCTAssertEqual(stats.rawBaseResidentBytes,0);XCTAssertEqual(stats.rawBaseReservedBytes,0)
    XCTAssertEqual(stats.activeNativeRenders,0);XCTAssertEqual(stats.sourceSnapshotDiskBytes,0)
    } catch { gate.signal();await service.closeAll();throw error }
  }
}
