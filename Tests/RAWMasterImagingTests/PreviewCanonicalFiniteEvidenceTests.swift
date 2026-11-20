import XCTest
import AppKit
import CoreImage
import ImageIO
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewCanonicalFiniteEvidenceTests: XCTestCase {
  private func fixture(alpha:UInt8=255) throws -> (URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-CanonicalProof-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file=root.appendingPathComponent("source.tiff")
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:28,pixelsHigh:18,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:112,bitsPerPixel:32))
    for y in 0..<18 { for x in 0..<28 {
      let i=y*112+x*4;bitmap.bitmapData![i]=UInt8(12+x*5);bitmap.bitmapData![i+1]=UInt8(9+y*8)
      bitmap.bitmapData![i+2]=UInt8(20+(x*3+y*4)%100);bitmap.bitmapData![i+3]=alpha
    }}
    let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(destination,try XCTUnwrap(bitmap.cgImage),nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let size=try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber
    return (root,.init(projectID:"canonical-proof",assetID:"owned",contentSHA256:try RenderFiles.hash(file),
      byteCount:try XCTUnwrap(size).int64Value,admissionFingerprint:"tiny",sourceLocation:file))
  }
  private func recipe(_ saturation:Double=0.4) throws -> DevelopmentRecipe {
    try DevelopmentRecipe().applying(.promoteToV3).applying(.setParameters(.color(.init(enabled:true,saturation:saturation))))
  }
  private func policy(proof:Bool=true,bitmap:Int=0)->PreviewResourcePolicy {
    .init(bitmapCacheBytes:bitmap,rawBaseCacheBytes:1_073_741_824,interactiveEvaluation:.nativePointwiseCertificateV1,
      nativePointwiseProfile:true,nativeCanonicalFiniteProof:proof)
  }
  private func request(_ lease:PreviewSessionInfo,_ c:PreviewConsumerID,_ r:DevelopmentRecipe,_ revision:UInt64,
                       _ quality:PreviewQuality = .interactive)->DevelopmentPreviewRequest {
    .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:c,role:.primary,
      revision:revision,recipe:r,quality:quality,viewport:.init(maxPixel:2400))
  }
  private func bytes(_ image:NSImage)throws->[UInt8] {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    let c=try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
      space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
    c.setBlendMode(.copy);c.interpolationQuality = .none;c.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:cg.width*cg.height*4))
  }
  private struct Owned {
    let native:PreviewNativeSource,pool:PreviewRawBasePool,scope:PreviewPresentationScope
    let descriptor:PreviewNativePointwiseBaseDescriptorV1,grid:PreviewNativePointwiseCertificateV1.Grid
    let pin:RawBasePin,base:CIImage,context:PreviewCanonicalFiniteContextV1,recipe:DevelopmentRecipe
    func evidence<T>(_ recipe:DevelopmentRecipe?=nil,_ body:(PreviewCanonicalFiniteEvidenceV1?)throws->T)throws->T {
      try PreviewCanonicalFiniteEvidenceV1.withEvidence(native:native,pin:pin,base:base,contextOwner:context,
        descriptor:descriptor,grid:grid,recipe:recipe ?? self.recipe,check:{},body)
    }
    func consume(_ evidence:PreviewCanonicalFiniteEvidenceV1,recipe:DevelopmentRecipe?=nil,
                 context:CIContext?=nil,base:CIImage?=nil)throws->Bool {
      try evidence.consumeGlobalOutput(recipe:recipe ?? self.recipe,capture:native.capture,
        context:context ?? self.context.context,suppliedBase:base ?? self.base,
        sourceIsRAW:native.hasRAWFilter,sourceSize:native.nativeSize,check:nil)
    }
  }
  /// No synthetic sampler success: the original real IP renderer runs its joined veto on an owned TIFF.
  private func withOwned(_ r:DevelopmentRecipe?=nil,_ body:(Owned)throws->Void)throws {
    let (root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try r ?? recipe(),plan=try native.nativePointwisePlan(recipe:r,sourceKey:"owned-proof",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400)
    let d=try XCTUnwrap(plan.descriptor),grid=try XCTUnwrap(plan.grid)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824),ledger=PreviewPresentationLedger()
    let scope=PreviewPresentationScope(ledgerForTesting:ledger)
    defer{scope.closeAndRetire()}
    try pool.withWorker {
      try autoreleasepool {
        let result=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{throw PreviewPresentationError.allocationProtocol})
        XCTAssertTrue(try XCTUnwrap(result.nativePointwise).certified)
      }
      do {
        let pin=try XCTUnwrap(pool.acquirePointwiseResident(d));defer{pin.releaseAfterJoinedPipeline()}
        let context=PreviewCanonicalFiniteContextV1.make(device:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer{context.context.clearCaches()}
        try body(.init(native:native,pool:pool,scope:scope,descriptor:d,grid:grid,pin:pin,base:pin.image,context:context,recipe:r))
      }
      let final=try pool.drain();XCTAssertEqual(final.residentBytes,0);XCTAssertEqual(final.pinnedBytes,0)
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
  }
  func testDefaultOffExactBootstrapAndThreeSeparateKeyNamespaces() throws {
    XCTAssertFalse(PreviewResourcePolicy.default.nativeCanonicalFiniteProof)
    let flags=["RAWMASTER_QA_NATIVE_POINTWISE_V1":"1","RAWMASTER_QA_CANONICAL_FINITE_V1":"1"]
    XCTAssertTrue(PreviewCanonicalFiniteEvidenceV1.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:flags))
    for id in [nil,"io.robinqu.RAWMaster","io.robinqu.RAWMaster.preview021","io.robinqu.RAWMaster.preview022.extra"] {
      XCTAssertFalse(PreviewCanonicalFiniteEvidenceV1.bootstrap(bundleIdentifier:id,environment:flags))
    }
    for key in flags.keys {for value in ["0","true","01",""] {
      var changed=flags;changed[key]=value
      XCTAssertFalse(PreviewCanonicalFiniteEvidenceV1.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:changed))
    }}
    try withOwned { owned in
      var plan=try owned.native.nativePointwisePlan(recipe:owned.recipe,sourceKey:owned.descriptor.sourceKey,generation:1,
        verifiedContentID:owned.descriptor.verifiedContentID,maxPixel:2400)
      let interactive=try plan.keySuffix();plan.canonicalFullChecks=true;let scanned=try plan.keySuffix()
      plan.canonicalGlobalFiniteProofEnabled=true
      plan.canonicalGlobalRecipeBinding=try .init(owned.recipe);let proven=try plan.keySuffix()
      var changed=owned.recipe;changed.adjustmentsV3!.color.saturation=0.4.nextUp
      plan.canonicalGlobalRecipeBinding=try .init(changed);XCTAssertNotEqual(try plan.keySuffix(),proven)
      plan.canonicalGlobalRecipeBinding=try .init(owned.recipe)
      XCTAssertNotEqual(interactive,scanned);XCTAssertNotEqual(interactive,proven);XCTAssertNotEqual(scanned,proven)
      plan.canonicalGlobalFiniteProofEnabled=false;XCTAssertEqual(try plan.keySuffix(),scanned)
    }
  }
  func testActualWitnessBindingsRejectContextBaseRecipeGenerationAndEverySamplerField() throws {
    let tiny=try recipe(Double.leastNonzeroMagnitude),zero=try recipe(0)
    XCTAssertEqual(try PreviewNativePointwiseCertificateV2.Binding(tiny).floatBits,
      try PreviewNativePointwiseCertificateV2.Binding(zero).floatBits)
    XCTAssertTrue(try PreviewNativePointwiseCertificateV2.Binding(tiny).pointwiseActive)
    XCTAssertFalse(try PreviewNativePointwiseCertificateV2.Binding(zero).pointwiseActive)
    try withOwned { o in
      let real=try XCTUnwrap(o.pin.pointwiseSamplerCertificate)
      o.pin.pointwiseSamplerCertificate=nil
      try o.evidence { XCTAssertNil($0) };o.pin.pointwiseSamplerCertificate=real
      var changedRecipe=o.recipe;changedRecipe.adjustmentsV3!.color.saturation += 0.1
      var sameFloat=o.recipe;sameFloat.adjustmentsV3!.color.saturation=0.4.nextUp
      XCTAssertEqual(try PreviewNativePointwiseCertificateV2.Binding(sameFloat).floatBits,
        try PreviewNativePointwiseCertificateV2.Binding(o.recipe).floatBits)
      let otherContext=PreviewCanonicalFiniteContextV1.make(device:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
      defer{otherContext.context.clearCaches()}
      try o.evidence { e in
        let e=try XCTUnwrap(e)
        XCTAssertFalse(try o.consume(e,context:otherContext.context))
        XCTAssertFalse(try o.consume(e,base:o.base.transformed(by:.init(translationX:1,y:0))))
        XCTAssertFalse(try o.consume(e,recipe:changedRecipe));XCTAssertFalse(try o.consume(e,recipe:sameFloat))
        XCTAssertFalse(e.consumed);XCTAssertTrue(try o.consume(e));XCTAssertTrue(e.consumed)
        XCTAssertFalse(try o.consume(e))
      }
      typealias Sampler=PreviewNativePointwiseCertificateV1.Sampler
      func variant(owner:UUID?=nil,authority:String?=nil,grid:PreviewNativePointwiseCertificateV1.Grid?=nil,
                   device:UInt64?=nil,point:String?=nil,witness:String?=nil,abi:String?=nil,os:String?=nil,options:String?=nil)->Sampler {
        .init(owner:owner ?? real.owner,authority:authority ?? real.authority,grid:grid ?? real.grid,device:device ?? real.device,
          pointSHA256:point ?? real.pointSHA256,witnessSHA256:witness ?? real.witnessSHA256,samplerABI:abi ?? real.samplerABI,
          os:os ?? real.os,optionsVersion:options ?? real.optionsVersion)
      }
      let wrongGrid=try PreviewNativePointwiseCertificateV1.grid(width:14,height:9)
      for bad in [variant(owner:UUID()),variant(authority:"bad"),variant(grid:wrongGrid),variant(device:real.device ^ 1),
                  variant(point:"bad"),variant(witness:"bad"),variant(abi:"bad"),variant(os:"bad"),variant(options:"bad")] {
        o.pin.pointwiseSamplerCertificate=bad;try o.evidence {XCTAssertNil($0)}
      }
      o.pin.pointwiseSamplerCertificate=real
      let changed=try PreviewNativePointwiseBaseV1.descriptor(o.native,sourceKey:o.descriptor.sourceKey,generation:2,
        verifiedContentID:o.descriptor.verifiedContentID)
      try PreviewCanonicalFiniteEvidenceV1.withEvidence(native:o.native,pin:o.pin,base:o.base,contextOwner:o.context,
        descriptor:changed,grid:o.grid,recipe:o.recipe,check:{}) {XCTAssertNil($0)}
      let other=try PreviewNativeSource(capture:o.native.capture,byteCount:o.native.captureStamp.size,artifact:false,memoryLimit:512)
      try PreviewCanonicalFiniteEvidenceV1.withEvidence(native:other,pin:o.pin,base:o.base,contextOwner:o.context,
        descriptor:o.descriptor,grid:o.grid,recipe:o.recipe,check:{}) {XCTAssertNil($0)}
    }
  }
  func testEvidenceExpiresAndReleasedOrRetiredInputCannotAuthorize() throws {
    try withOwned { o in
      var escaped:PreviewCanonicalFiniteEvidenceV1?
      try o.evidence { escaped=try XCTUnwrap($0) }
      XCTAssertFalse(try o.consume(try XCTUnwrap(escaped)))
      try o.evidence { e in
        let e=try XCTUnwrap(e);o.pool.retire(sourceKey:o.descriptor.sourceKey)
        XCTAssertFalse(try o.consume(e));XCTAssertNil(o.pin.pointwiseInputCertificate)
        XCTAssertGreaterThan(o.pool.statistics.pinnedBytes,0)
        o.pin.releaseAfterJoinedPipeline();XCTAssertFalse(try o.consume(e))
      }
    }
  }
  func testActualSourceMutationAndCancellationCannotBecomeSuccessfulEvidence() throws {
    enum Stop:Error {case cancelled}
    try withOwned { o in
      try o.evidence { e in
        let e=try XCTUnwrap(e)
        XCTAssertThrowsError(try e.consumeGlobalOutput(recipe:o.recipe,capture:o.native.capture,context:o.context.context,
          suppliedBase:o.base,sourceIsRAW:o.native.hasRAWFilter,sourceSize:o.native.nativeSize,
          check:{throw Stop.cancelled})) {error in
            if case Stop.cancelled=error {} else {XCTFail("Wrong cancellation: \(error)")}
          }
        XCTAssertFalse(e.consumed)
        let file=try FileHandle(forWritingTo:o.native.capture)
        try file.seekToEnd();try file.write(contentsOf:Data([0]));try file.synchronize();try file.close()
        XCTAssertThrowsError(try o.consume(e));XCTAssertFalse(e.consumed)
      }
    }
  }
  func testActualInputScanRejectsPartialAlphaBoundsAndNonfiniteBeforeProof() throws {
    try withOwned { o in
      let realSampler=try XCTUnwrap(o.pin.pointwiseSamplerCertificate)
      for pixel in [SIMD4<Float>(0.2,0.3,0.4,0.5),SIMD4<Float>(Float(0x1p20).nextUp,0,0,1)] {
        let values=[SIMD4<Float>](repeating:pixel,count:28*18)
        let image=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:28*16,size:.init(width:28,height:18),
          format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
        let storage=try RawBaseStorage(width:28,height:18)
        try storage.fill(image,context:o.context.context,pointwiseAuthority:o.descriptor.fingerprint())
        XCTAssertFalse(try XCTUnwrap(storage.pointwiseInputCertificate).eligible)
        let pin=RawBasePin(owner:storage,release:{});defer{pin.releaseAfterJoinedPipeline()}
        // Correct matching sampler fields cannot override a real ineligible input scan.
        pin.pointwiseSamplerCertificate = .init(owner:storage.ownerIncarnation,authority:realSampler.authority,grid:realSampler.grid,
          device:realSampler.device,pointSHA256:realSampler.pointSHA256,witnessSHA256:realSampler.witnessSHA256,
          samplerABI:realSampler.samplerABI,os:realSampler.os,optionsVersion:realSampler.optionsVersion)
        try PreviewCanonicalFiniteEvidenceV1.withEvidence(native:o.native,pin:pin,base:pin.image,contextOwner:o.context,
          descriptor:o.descriptor,grid:o.grid,recipe:o.recipe,check:{}) {XCTAssertNil($0)}
      }
      // Same real scan routine used after the joined native fill; all NaN/Inf variants reject.
      for value in [Float.nan,Float.infinity,-Float.infinity] {
        var pixel=SIMD4<Float>(value,0,0,1)
        try withUnsafeBytes(of:&pixel) { bytes in
          XCTAssertThrowsError(try PreviewNativePointwiseCertificateV1.scan(address:bytes.baseAddress!,width:1,height:1,
            rowBytes:16,owner:UUID(),authority:"invalid"))
        }
      }
    }
  }
  func testExcludedStagesAndNewCurveMetadataKeepOriginalDomain() throws {
    try withOwned { o in
      var recipes=[DevelopmentRecipe]()
      var r=o.recipe;r.adjustmentsV3!.light = .init(enabled:true,exposure:0.2);recipes.append(r)
      r=o.recipe;r.adjustmentsV3!.light = .init(enabled:true,highlights:0.2);recipes.append(r)
      r=o.recipe;r.adjustmentsV3!.blackAndWhite.grain=Double.leastNonzeroMagnitude;recipes.append(r)
      r=o.recipe;r.adjustmentsV3!.curves.enabled=true;r.adjustmentsV3!.curves.rgb.curve = .init(points:[.init(x:0,y:1),.init(x:1,y:0)]);recipes.append(r)
      r=o.recipe;r.adjustmentsV3!.curves.algorithm = .naturalCubicGamma512LumaV1;recipes.append(r)
      r=o.recipe;r.adjustmentsV3!.geometry.straightenDegrees=1;recipes.append(r)
      for r in recipes {
        XCTAssertNotNil(try PreviewNativePointwiseV1.routeEligibility(r,size:o.native.nativeSize))
        try o.evidence(r) {XCTAssertNil($0)}
      }
    }
  }
  func testNamedScanOnlyOnceAndProjectiveGeometryStillJoinsItsOriginalCheck() throws {
    enum Stop:Error {case afterJoinedGeometry,afterJoinedRepeatedGlobal}
    var r=try recipe();r.adjustmentsV3!.geometry.version = .projectiveV3_1
    try withOwned(r) { o in
      try o.evidence { value in
        let e=try XCTUnwrap(value);var afterConsumption=0
        XCTAssertThrowsError(try DevelopmentRendererV3.develop(o.native.capture,recipe:o.recipe,
          suppliedImageBase:.init(image:o.base,sourceDepth:8),context:o.context.context,canonicalFiniteEvidence:e,
          checkCancellation:{if e.consumed {afterConsumption+=1;if afterConsumption==2 {throw Stop.afterJoinedGeometry}}})) {error in
            if case Stop.afterJoinedGeometry=error {} else {XCTFail("Wrong geometry boundary: \(error)")}
          }
        XCTAssertTrue(e.consumed);XCTAssertEqual(afterConsumption,2)
        // Evidence cannot skip the named global scan a second time, even inside its original scope.
        var checks=0
        XCTAssertThrowsError(try DevelopmentRendererV3.develop(o.native.capture,recipe:o.recipe,applyGeometry:false,
          suppliedImageBase:.init(image:o.base,sourceDepth:8),context:o.context.context,canonicalFiniteEvidence:e,
          checkCancellation:{checks+=1;if checks==2 {throw Stop.afterJoinedRepeatedGlobal}})) {error in
            if case Stop.afterJoinedRepeatedGlobal=error {} else {XCTFail("Wrong repeated global boundary: \(error)")}
          }
        XCTAssertEqual(checks,2)
      }
    }
  }
  func testCanonicalOnlyColdBuildsSamplerThenWarmProofMatchesScannedPixelsAndReplays() async throws {
    let (root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:policy(bitmap:1_048_576))
    let control=DevelopmentPreviewService(policy:policy(proof:false))
    do {
      let lease=try await service.open(source:.raw(source)),c=PreviewConsumerID(),r=try recipe(0.6)
      let cold=try await service.render(request(lease,c,recipe(),1,.settled))
      let observedCold=await service.nativePointwiseReceiptForTesting(),coldReceipt=try XCTUnwrap(observedCold)
      XCTAssertTrue(coldReceipt.sourceCold);XCTAssertTrue(coldReceipt.samplerCold)
      XCTAssertFalse(coldReceipt.canonicalFullChecks);XCTAssertEqual(coldReceipt.canonicalGlobalFiniteProofID,PreviewCanonicalFiniteEvidenceV1.version)
      let interactive=try await service.render(request(lease,c,r,2))
      XCTAssertTrue(interactive.approximate);XCTAssertNotEqual(cold.outputKey,interactive.outputKey)
      let final=try await service.render(request(lease,c,r,3,.settled))
      let observed=await service.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(observed)
      XCTAssertFalse(final.approximate);XCTAssertNotEqual(final.frameID,interactive.frameID)
      XCTAssertNotEqual(final.outputKey,interactive.outputKey);XCTAssertNotEqual(final.outputKey,cold.outputKey)
      XCTAssertFalse(receipt.certified);XCTAssertFalse(receipt.canonicalFullChecks);XCTAssertNil(receipt.fullNativeChecks)
      XCTAssertFalse(receipt.samplerCold)
      XCTAssertEqual(receipt.canonicalGlobalFiniteProofID,PreviewCanonicalFiniteEvidenceV1.version)
      XCTAssertEqual(receipt.canonicalGlobalFiniteStage,PreviewCanonicalFiniteEvidenceV1.stage)
      XCTAssertTrue(receipt.canonicalProofFITChecked);XCTAssertTrue(EditingFingerprint.isSHA256(try XCTUnwrap(receipt.canonicalGlobalFiniteBinding)))
      XCTAssertEqual(receipt.owner,coldReceipt.owner);XCTAssertFalse(receipt.sourceCold)
      let controlLease=try await control.open(source:.raw(source))
      let scanned=try await control.render(request(controlLease,PreviewConsumerID(),r,1,.settled))
      XCTAssertEqual(try bytes(final.image),try bytes(scanned.image))
      let scannedObserved=await control.nativePointwiseReceiptForTesting(),scannedReceipt=try XCTUnwrap(scannedObserved)
      XCTAssertTrue(scannedReceipt.canonicalFullChecks);XCTAssertNil(scannedReceipt.canonicalGlobalFiniteProofID)
      let replay=try await service.render(request(lease,c,r,4,.settled))
      XCTAssertEqual(replay.outputKey,final.outputKey);XCTAssertNotEqual(replay.frameID,final.frameID);XCTAssertEqual(replay.revision,4)
      let stats=await service.statistics(),old=await control.statistics()
      XCTAssertEqual(stats.rawBaseFills,1);XCTAssertEqual(stats.nativeProfileCanonicalValidatedOutputs,0)
      XCTAssertEqual(stats.nativeProfileCanonicalProvenGlobalOutputs,2);XCTAssertEqual(stats.nativeProfileCanonicalProvenBitmapHits,1);XCTAssertEqual(stats.nativeProfileLastRoute,8)
      XCTAssertEqual(old.nativeProfileCanonicalValidatedOutputs,1);XCTAssertEqual(old.nativeProfileCanonicalProvenGlobalOutputs,0)
      var common=r;common.adjustmentsV3!.light = .init(enabled:true,brightness:0.15,contrast:0.2,blackPoint:0.05)
      common.adjustmentsV3!.color = .init(enabled:true,saturation:0.25,vibrance:0.2,cast:-0.1)
      common.adjustmentsV3!.blackAndWhite = .init(enabled:true,intensity:0.6,neutrals:0.3,tone:0.2,grain:0)
      _=try await service.render(request(lease,c,common,5)) // Actual common-v2.1 sampler veto replaces the sat witness.
      let commonFinal=try await service.render(request(lease,c,common,6,.settled))
      let commonObserved=await service.nativePointwiseReceiptForTesting(),commonReceipt=try XCTUnwrap(commonObserved)
      XCTAssertEqual(commonReceipt.proofID,PreviewNativePointwiseCertificateV2.version)
      XCTAssertEqual(commonReceipt.canonicalGlobalFiniteProofID,PreviewCanonicalFiniteEvidenceV1.version)
      XCTAssertFalse(commonReceipt.canonicalFullChecks);XCTAssertTrue(commonReceipt.canonicalProofFITChecked)
      let commonScanned=try await control.render(request(controlLease,PreviewConsumerID(),common,2,.settled))
      XCTAssertEqual(try bytes(commonFinal.image),try bytes(commonScanned.image))
    } catch {await service.closeAll();await control.closeAll();throw error}
    await service.closeAll();await control.closeAll()
    let final=await service.statistics()
    XCTAssertEqual(final.rawBaseResidentBytes,0);XCTAssertEqual(final.rawBasePinnedBytes,0)
    XCTAssertEqual(final.activeNativeRenders,0);XCTAssertEqual(final.sourceSnapshotDiskBytes,0)
  }
  func testWarmCanonicalSharedFITReusesCheckedNodeAndKeepsColdReplaySeparate() async throws {
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:policy(bitmap:1_048_576),qaSharedFITIntermediate:true)
    let control=DevelopmentPreviewService(policy:policy(bitmap:1_048_576))
    do {
      let lease=try await service.open(source:.raw(source)),other=try await control.open(source:.raw(source))
      let consumer=PreviewConsumerID(),reference=PreviewConsumerID(),coldRecipe=try recipe(0.4),warmRecipe=try recipe(0.6)
      let cold=try await service.render(request(lease,consumer,coldRecipe,1,.settled))
      let coldObserved=await service.nativePointwiseReceiptForTesting(),coldReceipt=try XCTUnwrap(coldObserved)
      let oldCold=try await control.render(request(other,reference,coldRecipe,1,.settled))
      XCTAssertTrue(coldReceipt.sourceCold);XCTAssertTrue(coldReceipt.samplerCold)
      XCTAssertTrue(coldReceipt.canonicalProofFITChecked);XCTAssertFalse(coldReceipt.sharedFITIntermediateInserted)
      XCTAssertNil(coldReceipt.canonicalGlobalFITTransport);XCTAssertEqual(try bytes(cold.image),try bytes(oldCold.image))
      let warm=try await service.render(request(lease,consumer,warmRecipe,2,.settled))
      let warmObserved=await service.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(warmObserved)
      let oldWarm=try await control.render(request(other,reference,warmRecipe,2,.settled))
      let controlObserved=await control.nativePointwiseReceiptForTesting(),controlReceipt=try XCTUnwrap(controlObserved)
      XCTAssertEqual(receipt.owner,coldReceipt.owner);XCTAssertFalse(receipt.sourceCold);XCTAssertFalse(receipt.samplerCold)
      XCTAssertEqual(receipt.canonicalGlobalFiniteProofID,PreviewCanonicalFiniteEvidenceV1.version)
      XCTAssertTrue(receipt.canonicalProofFITChecked);XCTAssertFalse(receipt.canonicalFullChecks)
      XCTAssertTrue(receipt.sharedFITIntermediateInserted)
      XCTAssertEqual(receipt.canonicalGlobalFITTransport,PreviewNativePointwiseV1.canonicalSharedFITVersion)
      XCTAssertFalse(controlReceipt.sharedFITIntermediateInserted);XCTAssertNil(controlReceipt.canonicalGlobalFITTransport)
      XCTAssertEqual(try bytes(warm.image),try bytes(oldWarm.image))
      XCTAssertNotEqual(warm.outputKey,oldWarm.outputKey)
      let beforeReplay=await service.statistics()
      let replay=try await service.render(request(lease,consumer,warmRecipe,3,.settled))
      let afterReplay=await service.statistics()
      XCTAssertEqual(replay.outputKey,warm.outputKey);XCTAssertEqual(try bytes(replay.image),try bytes(warm.image))
      XCTAssertEqual(afterReplay.completedRenders,beforeReplay.completedRenders)
      XCTAssertEqual(afterReplay.cacheHits,beforeReplay.cacheHits+1)
      // Requested ON cannot adopt a cold OFF bitmap even for the exact same recipe.
      let beforeColdRetry=await service.statistics()
      let retry=try await service.render(request(lease,consumer,coldRecipe,4,.settled))
      let afterColdRetry=await service.statistics()
      let retryObserved=await service.nativePointwiseReceiptForTesting(),retryReceipt=try XCTUnwrap(retryObserved)
      XCTAssertEqual(afterColdRetry.completedRenders,beforeColdRetry.completedRenders+1)
      XCTAssertEqual(afterColdRetry.cacheHits,beforeColdRetry.cacheHits)
      XCTAssertNotEqual(retry.outputKey,cold.outputKey);XCTAssertTrue(retryReceipt.sharedFITIntermediateInserted)
      XCTAssertEqual(try bytes(retry.image),try bytes(cold.image))
      var bad=receipt;bad.canonicalGlobalFITTransport=nil
      XCTAssertFalse(PreviewNativePointwiseV1.canonicalSharedFITReplayMatches(bad,requested:true))
      bad=receipt;bad.sharedFITIntermediateInserted=false
      XCTAssertFalse(PreviewNativePointwiseV1.canonicalSharedFITReplayMatches(bad,requested:true))
      XCTAssertFalse(PreviewNativePointwiseV1.canonicalSharedFITReplayMatches(receipt,requested:false))
      XCTAssertFalse(PreviewNativePointwiseV1.canonicalSharedFITReplayMatches(coldReceipt,requested:true))
      XCTAssertFalse(PreviewNativePointwiseV1.canonicalSharedFITEligible(requested:true,proven:false,sourceCold:false,samplerCold:false))
      XCTAssertFalse(PreviewNativePointwiseV1.canonicalSharedFITEligible(requested:true,proven:true,sourceCold:true,samplerCold:false))
      XCTAssertFalse(PreviewNativePointwiseV1.canonicalSharedFITEligible(requested:true,proven:true,sourceCold:false,samplerCold:true))
    } catch {await service.closeAll();await control.closeAll();throw error}
    await service.closeAll();await control.closeAll()
    for value in [service,control] {
      let stats=await value.statistics(),owned=await value.interactiveKnownOwnedForTesting()
      XCTAssertEqual(stats.rawBasePinnedBytes,0);XCTAssertEqual(stats.rawBaseResidentBytes,0)
      XCTAssertEqual(stats.activeNativeRenders,0);XCTAssertEqual(stats.cachedBitmapBytes,0)
      XCTAssertTrue(owned.values.allSatisfy{$0==0})
    }
  }
  func testProvenPipelineCancellationRetainsActualWorkerAndPinUntilJoinedRelease() async throws {
    final class Gate:@unchecked Sendable {
      let lock=NSLock(),wait=DispatchSemaphore(value:0);var armed=false
      func arm(){lock.lock();armed=true;lock.unlock()}
      func isArmed()->Bool{lock.lock();defer{lock.unlock()};return armed}
    }
    let (root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let entered=expectation(description:"proven actual output joined before pin release"),gate=Gate()
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{label in
      if label=="pointwise-post/output-joined",gate.isArmed(){entered.fulfill();gate.wait.wait()}
    })
    let service=DevelopmentPreviewService(policy:policy(),rawBasePoolForTesting:pool,qaSharedFITIntermediate:true)
    do {
      let lease=try await service.open(source:.raw(source)),c=PreviewConsumerID(),r=try recipe()
      _=try await service.render(request(lease,c,r,1));gate.arm()
      let render=Task{try await service.render(request(lease,c,r,2,.settled))}
      await fulfillment(of:[entered],timeout:10)
      await service.cancel(consumerID:c)
      let during=await service.statistics();XCTAssertEqual(during.activeNativeRenders,1)
      let closing=Task{await service.close(lease.id)}
      var revoked=false
      for _ in 0..<100 {
        do{_=try await service.sourceFacts(sessionID:lease.id,sourceGeneration:lease.sourceGeneration)}
        catch{revoked=(error as? DevelopmentPreviewError) == .closed;break}
        await Task.yield()
      }
      gate.wait.signal();XCTAssertTrue(revoked)
      do{_=try await render.value;XCTFail("Canceled proven frame must not publish")}catch{}
      await closing.value;await service.closeAll()
      let final=await service.statistics()
      XCTAssertEqual(final.maximumObservedNativeRenders,1);XCTAssertEqual(final.activeNativeRenders,0)
      XCTAssertEqual(final.nativeProfileCanonicalProvenGlobalOutputs,0)
      XCTAssertEqual(final.rawBasePinnedBytes,0);XCTAssertEqual(final.rawBaseResidentBytes,0);XCTAssertEqual(final.sourceSnapshotDiskBytes,0)
    }catch{gate.wait.signal();await service.closeAll();throw error}
  }

  func testCanonicalOnlyPartialInputStillScansWithoutPublishingSamplerProof() async throws {
    let(root,source)=try fixture(alpha:128);defer{try?FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:policy(),qaSharedFITIntermediate:true),control=DevelopmentPreviewService(policy:policy(proof:false))
    do {
      let lease=try await service.open(source:.raw(source)),other=try await control.open(source:.raw(source))
      let consumer=PreviewConsumerID(),reference=PreviewConsumerID(),r=try recipe()
      for revision:UInt64 in [1,2] {
        let actual=try await service.render(request(lease,consumer,r,revision,.settled))
        let expected=try await control.render(request(other,reference,r,revision,.settled))
        let observed=await service.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(observed)
        XCTAssertTrue(receipt.canonicalFullChecks);XCTAssertFalse(receipt.samplerCold)
        XCTAssertFalse(receipt.sharedFITIntermediateInserted);XCTAssertNil(receipt.canonicalGlobalFITTransport)
        XCTAssertNil(receipt.canonicalGlobalFiniteProofID);XCTAssertEqual(try bytes(actual.image),try bytes(expected.image))
      }
      let stats=await service.statistics();XCTAssertEqual(stats.nativeProfileCanonicalValidatedOutputs,2)
      XCTAssertEqual(stats.nativeProfileCanonicalProvenGlobalOutputs,0)
    }catch{await service.closeAll();await control.closeAll();throw error}
    await service.closeAll();await control.closeAll()
    let stats=await service.statistics();XCTAssertEqual(stats.rawBasePinnedBytes,0);XCTAssertEqual(stats.rawBaseResidentBytes,0)
  }

  func testCanonicalOnlySamplerCancellationWaitsForJoinedGuardBeforePublishing() async throws {
    final class Gate:@unchecked Sendable {
      let lock=NSLock(),release=DispatchSemaphore(value:0);var observed=false,heldBytes=0
      func mark(_ bytes:Int){lock.lock();heldBytes=bytes;observed=true;lock.unlock()}
      var entered:Bool{lock.lock();defer{lock.unlock()};return observed}
      var pinnedBytes:Int{lock.lock();defer{lock.unlock()};return heldBytes}
    }
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let entered=expectation(description:"canonical-only actual sampler guard joined before certificate publication"),gate=Gate()
    weak var actualPool:PreviewRawBasePool?
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{label in
      if label=="canonical-sampler-veto/joined"{
        gate.mark(actualPool?.statistics.pinnedBytes ?? 0);entered.fulfill();gate.release.wait()
      }
    })
    actualPool=pool
    let service=DevelopmentPreviewService(policy:policy(),rawBasePoolForTesting:pool)
    let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID(),r=try recipe()
    let render=Task{try await service.render(request(lease,consumer,r,1,.settled))}
    await fulfillment(of:[entered],timeout:10)
    guard gate.entered else {
      gate.release.signal();render.cancel();_ = try? await render.value;await service.closeAll()
      return XCTFail("sampler guard did not actually reach its joined boundary")
    }
    await service.cancel(consumerID:consumer)
    let during=await service.statistics();XCTAssertEqual(during.activeNativeRenders,1)
    XCTAssertGreaterThan(gate.pinnedBytes,0)
    // Actor cancellation revokes delivery. It does not release the native worker or input pin.
    do{_=try await render.value;XCTFail("Cancelled canonical guard published a frame")}catch{}
    gate.release.signal();await service.closeAll()
    let final=await service.statistics()
    XCTAssertEqual(final.nativeProfileCanonicalProvenGlobalOutputs,0);XCTAssertEqual(final.activeNativeRenders,0)
    XCTAssertEqual(final.rawBasePinnedBytes,0);XCTAssertEqual(final.rawBaseResidentBytes,0)
    XCTAssertEqual(final.sourceSnapshotDiskBytes,0)
  }
}


extension PreviewCanonicalFiniteEvidenceTests {
  func testCanonicalGestureCapabilityUsesActualImageLeaseAndKeepsCanonicalPixelsAndAuthority() async throws {
    let environment=["RAWMASTER_QA_NATIVE_POINTWISE_V1":"1","RAWMASTER_QA_CANONICAL_GESTURE_V1":"1"]
    XCTAssertTrue(PreviewCanonicalGestureCapability.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:environment))
    XCTAssertFalse(PreviewCanonicalGestureCapability.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster",environment:environment))
    XCTAssertFalse(PreviewCanonicalGestureCapability.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:[:]))
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let pre=try RenderFiles.hash(source.sourceLocation)
    let candidate=DevelopmentPreviewService(policy:policy(),qaSharedFITIntermediate:true,qaCanonicalGesture:true)
    let control=DevelopmentPreviewService(policy:policy(),qaSharedFITIntermediate:true)
    let ordinary=DevelopmentPreviewService(qaCanonicalGesture:true)
    do {
      let admitted=try await candidate.open(source:.raw(source)),reference=try await control.open(source:.raw(source))
      let legacy=try await ordinary.open(source:.raw(source))
      let capability=try XCTUnwrap(admitted.canonicalGesture)
      XCTAssertNil(reference.canonicalGesture);XCTAssertNil(legacy.canonicalGesture)
      XCTAssertEqual(capability.sessionID,admitted.id);XCTAssertEqual(capability.sourceGeneration,admitted.sourceGeneration)
      XCTAssertEqual(capability.sourceIdentity,admitted.sourceIdentity)
      XCTAssertTrue(try capability.supports(recipe(0.2)))
      XCTAssertFalse(try capability.supports(DevelopmentRecipe()))
      var grain=try recipe();grain.adjustmentsV3?.blackAndWhite.grain=0.3
      XCTAssertFalse(try capability.supports(grain))
      var spatial=try recipe();spatial.adjustmentsV3?.light = .init(enabled:true,brilliance:0.2)
      XCTAssertFalse(try capability.supports(spatial))
      var crop=try recipe();crop.adjustmentsV3?.geometry.crop = .init(x:0.1,y:0,width:0.9,height:1)
      XCTAssertFalse(try capability.supports(crop))
      let c=PreviewConsumerID(),other=PreviewConsumerID()
      // Return only independent CPU bytes; never carry an NSImage/provider alias through closeAll.
      func output(_ service:DevelopmentPreviewService,_ lease:PreviewSessionInfo,_ consumer:PreviewConsumerID,
                  _ value:Double,_ revision:UInt64)async throws->[UInt8] {
        let frame=try await service.render(request(lease,consumer,recipe(value),revision,.settled))
        XCTAssertEqual(frame.quality,.settled);XCTAssertFalse(frame.approximate)
        XCTAssertEqual(frame.canonicalPixelSize,CGSize(width:28,height:18))
        XCTAssertEqual(frame.outputPixelSize,CGSize(width:28,height:18))
        let result=try autoreleasepool{try bytes(frame.image)}
        return result
      }
      for (offset,value) in [0.2,0.4].enumerated() {
        let actual=try await output(candidate,admitted,c,value,UInt64(offset+1))
        let expected=try await output(control,reference,other,value,UInt64(offset+1))
        XCTAssertEqual(actual,expected)
        let observed=await candidate.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(observed)
        XCTAssertEqual(receipt.canonicalGlobalFiniteProofID,PreviewCanonicalFiniteEvidenceV1.version)
        XCTAssertTrue(receipt.canonicalProofFITChecked);XCTAssertFalse(receipt.certified)
        let stats=await candidate.statistics();XCTAssertEqual(stats.completedRenders,UInt64(offset+1));XCTAssertEqual(stats.cacheHits,0)
      }
      // A stale policy value is not an authorization token; actual Service validation still rejects it.
      await candidate.close(admitted.id)
      do {_ = try await candidate.render(request(admitted,c,recipe(0.2),3,.settled));XCTFail("Closed lease must reject")}
      catch {XCTAssertEqual(error as? DevelopmentPreviewError,.closed)}
      let reopened=try await candidate.open(source:.raw(source))
      XCTAssertNotEqual(reopened.id,capability.sessionID)
      XCTAssertNotEqual(reopened.sourceGeneration,capability.sourceGeneration)
      await candidate.close(reopened.id)
    }catch {await candidate.closeAll();await control.closeAll();await ordinary.closeAll();throw error}
    for service in [candidate,control,ordinary] {
      await service.closeAll()
      let stats=await service.statistics(),owned=await service.interactiveKnownOwnedForTesting()
      XCTAssertEqual(stats.activeNativeRenders,0);XCTAssertEqual(stats.pendingRequests,0)
      XCTAssertEqual(stats.rawBasePinnedBytes,0);XCTAssertEqual(stats.rawBaseResidentBytes,0)
      XCTAssertEqual(stats.sourceSnapshotDiskBytes,0);XCTAssertTrue(owned.values.allSatisfy{$0==0})
    }
    XCTAssertEqual(try RenderFiles.hash(source.sourceLocation),pre)
  }
}
