import XCTest
import AppKit
import CoreImage
import ImageIO
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewNativePointwiseTests: XCTestCase {
  private func recipe(_ s: Double=0.4) throws -> DevelopmentRecipe {
    // The actual existing UI transaction preserves legacy geometry, even with basis=nil.
    try DevelopmentRecipe().applying(.promoteToV3).applying(.setParameters(.color(.init(enabled:true,saturation:s))))
  }
  private func fixture(alpha: UInt8=255) throws -> (URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-NativePoint-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file=root.appendingPathComponent("asymmetric.tiff")
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:28,pixelsHigh:18,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:112,bitsPerPixel:32))
    for y in 0..<18 { for x in 0..<28 {
      let i=y*112+x*4
      bitmap.bitmapData![i]=UInt8(x*5+10);bitmap.bitmapData![i+1]=UInt8(y*7+8)
      bitmap.bitmapData![i+2]=UInt8((x*3+y*5)%100+10);bitmap.bitmapData![i+3]=alpha
    }}
    let writer=try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(writer,try XCTUnwrap(bitmap.cgImage),nil)
    XCTAssertTrue(CGImageDestinationFinalize(writer))
    let count=try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber
    return (root,.init(projectID:"native-point",assetID:"literal",contentSHA256:try RenderFiles.hash(file),
      byteCount:try XCTUnwrap(count).int64Value,admissionFingerprint:"owned-tiny",sourceLocation:file))
  }
  private func request(_ lease: PreviewSessionInfo,_ consumer: PreviewConsumerID,_ r: DevelopmentRecipe,
                       revision: UInt64,quality: PreviewQuality = .interactive) -> DevelopmentPreviewRequest {
    .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,
      revision:revision,recipe:r,quality:quality,viewport:.init(maxPixel:2400))
  }
  private func bytes(_ image: NSImage) throws -> [UInt8] {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    let c=try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
      space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
    c.setBlendMode(.copy);c.interpolationQuality = .none;c.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:cg.width*cg.height*4))
  }
  private func literal(_ values: [SIMD4<Float>],width: Int,height: Int) -> CIImage {
    CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),
      format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func context() -> CIContext {
    CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,
      .cacheIntermediates:false,.memoryTarget:512])
  }
  func testDefaultOffAndActualUITransactionsPreserveFingerprintAndNoOpDelegate() throws {
    XCTAssertEqual(PreviewResourcePolicy.default.interactiveEvaluation,.canonical)
    for original in [DevelopmentRecipe(),try DevelopmentRecipe().promotingToV2()] {
      let promoted=try original.applying(.promoteToV3)
      XCTAssertNotEqual(promoted.adjustmentsV3!.geometry.version,.adjustV3)
      let changed=try promoted.applying(.setParameters(.color(.init(enabled:true,saturation:0.4))))
      let before=try EditingFingerprint.of(changed)
      XCTAssertNil(try PreviewNativePointwiseV1.eligibility(changed,size:.init(width:28,height:18)))
      XCTAssertEqual(try EditingFingerprint.of(changed),before)
      XCTAssertEqual(changed.adjustmentsV3!.geometry,promoted.adjustmentsV3!.geometry)
      for zero in [0.0,-0.0] {
        let noOp=try promoted.applying(.setParameters(.color(.init(enabled:true,saturation:zero))))
        XCTAssertEqual(try PreviewNativePointwiseV1.eligibility(noOp,size:.init(width:28,height:18)),.legacyDelegate)
        XCTAssertNotNil(try DevelopmentRendererV3.legacyEquivalent(noOp))
      }
    }
    var p=try recipe().adjustmentsV3!
    p.legacyBasis = .init(version:.v1,exposureEV:-0.0)
    let remembered=DevelopmentRecipe(adjustmentsV3:p),before=try EditingFingerprint.of(remembered)
    XCTAssertNil(try PreviewNativePointwiseV1.eligibility(remembered,size:.init(width:28,height:18)))
    XCTAssertEqual(try EditingFingerprint.of(remembered),before)
    XCTAssertEqual(remembered.adjustmentsV3!.legacyBasis!.exposureEV.bitPattern,(-0.0 as Double).bitPattern)
  }
  func testEveryActualFlagAndNonDefaultGeometryIsStrictEvenIfMatrixCancels() throws {
    let r=try recipe(),size=CGSize(width:28,height:18)
    for group in DevelopmentAdjustmentID.allCases where group != .color {
      var p=r.adjustmentsV3!;p.setEnabled(true,for:group)
      // Some enabled defaults remain pixel neutral; the whitelist still must reject them.
      XCTAssertNotNil(try PreviewNativePointwiseV1.eligibility(.init(adjustmentsV3:p),size:size),group.rawValue)
    }
    var p=r.adjustmentsV3!;p.geometry.version = .projectiveV3_1
    p.geometry.clockwiseQuarterTurns=2;p.geometry.flipHorizontal=true;p.geometry.flipVertical=true
    XCTAssertEqual(try p.geometry.mapping(sourceSize:.init(width:28,height:18)).forwardMatrix,[1,0,0,0,1,0,0,0,1])
    XCTAssertNotNil(try PreviewNativePointwiseV1.eligibility(.init(adjustmentsV3:p),size:size))
    p=r.adjustmentsV3!;p.blackAndWhite.intensity=0
    XCTAssertNotNil(try PreviewNativePointwiseV1.eligibility(.init(adjustmentsV3:p),size:size))
    p=r.adjustmentsV3!;p.color.enabled=false
    XCTAssertNotNil(try PreviewNativePointwiseV1.eligibility(.init(adjustmentsV3:p),size:size))
    p=r.adjustmentsV3!;p.legacyBasis = .init(version:.v1,exposureEV:0.1)
    XCTAssertNotNil(try PreviewNativePointwiseV1.eligibility(.init(adjustmentsV3:p),size:size))
    p=r.adjustmentsV3!;p.color.saturation = .nan
    XCTAssertThrowsError(try PreviewNativePointwiseV1.eligibility(.init(adjustmentsV3:p),size:size))
  }
  func testEnvelopeUsesActualBitsAndRejectsOpenRoundingWithoutEpsilon() throws {
    for (w,h) in [(9504,6336),(5760,8640),(4800,96),(28,18)] {
      let g=try PreviewNativePointwiseCertificateV1.grid(width:w,height:h)
      XCTAssertTrue(g.envelopeClosed)
      if g.scale<1 { XCTAssertLessThan(g.roundoffBound,g.edgeInset) }
      else { XCTAssertEqual(g.roundoffBound,0) }
      for (n,out) in [(w,g.width),(h,g.height)] {
        for j in [0,out/2,out-1] {
          let q=(Double(j)+0.5)/g.scale
          XCTAssertGreaterThanOrEqual(q,0.5);XCTAssertLessThanOrEqual(q,Double(n)-0.5)
        }
      }
    }
    let nearIdentity=try PreviewNativePointwiseCertificateV1.grid(width:2401,height:2401)
    XCTAssertFalse(nearIdentity.envelopeClosed)
    XCTAssertGreaterThan(nearIdentity.roundoffBound,nearIdentity.edgeInset)
    XCTAssertThrowsError(try PreviewNativePointwiseCertificateV1.grid(width:2401,height:17)) // fractional FIT: no integralize.
    XCTAssertEqual(DevelopmentColorEngineV3.sourceSHA256,PreviewNativePointwiseCertificateV1.pointSourceSHA256)
  }
  func testLogicalRGBAOwnerScanPaddingAlphaBoundsAndPoisonRejectsPartialWrite() throws {
    let width=2,height=2,row=48,owner=UUID(),memory=UnsafeMutableRawPointer.allocate(byteCount:row*height,alignment:16)
    defer { memory.deallocate() }
    memory.initializeMemory(as:UInt8.self,repeating:0xff,count:row*height) // Padding is intentionally NaN bytes.
    let boundary=SIMD4<Float>(0x1p20,-0x1p20,Float.leastNonzeroMagnitude,1)
    for y in 0..<height { for x in 0..<width { memory.storeBytes(of:boundary,toByteOffset:y*row+x*16,as:SIMD4<Float>.self) } }
    let valid=try PreviewNativePointwiseCertificateV1.scan(address:memory,width:width,height:height,rowBytes:row,owner:owner,authority:"a")
    XCTAssertTrue(valid.eligible);XCTAssertEqual(valid.owner,owner);XCTAssertEqual(valid.pixels,4)
    for alpha in [Float(0),0.5,Float.leastNonzeroMagnitude] {
      memory.storeBytes(of:SIMD4<Float>(0,0,0,alpha),as:SIMD4<Float>.self)
      XCTAssertFalse(try PreviewNativePointwiseCertificateV1.scan(address:memory,width:width,height:height,rowBytes:row,owner:owner,authority:"a").eligible)
    }
    memory.storeBytes(of:SIMD4<Float>(Float(0x1p20).nextUp,0,0,1),as:SIMD4<Float>.self)
    XCTAssertFalse(try PreviewNativePointwiseCertificateV1.scan(address:memory,width:width,height:height,rowBytes:row,owner:owner,authority:"a").eligible)
    PreviewNativePointwiseCertificateV1.poison(address:memory,width:width,height:height,rowBytes:row)
    memory.storeBytes(of:SIMD4<Float>(0,0,0,1),as:SIMD4<Float>.self)
    XCTAssertThrowsError(try PreviewNativePointwiseCertificateV1.scan(address:memory,width:width,height:height,rowBytes:row,owner:owner,authority:"a"))
    for bad in [Float.nan,Float.infinity,-Float.infinity] {
      memory.storeBytes(of:SIMD4<Float>(bad,0,0,0),as:SIMD4<Float>.self)
      XCTAssertThrowsError(try PreviewNativePointwiseCertificateV1.scan(address:memory,width:width,height:height,rowBytes:row,owner:owner,authority:"a"))
    }
  }
  func testSamePoolClosedNamespaceRetirementABAAndCapacityKeepActualOwners() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let d=try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:"one",generation:1,verifiedContentID:source.contentSHA256)
    let nextGeneration=try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:"one",generation:2,verifiedContentID:source.contentSHA256)
    XCTAssertNotEqual(d,nextGeneration)
    let old=RawBaseDescriptor(sourceKey:"one",decoder:"image-io",nativeContract:"legacy",exposureBits:0,
      whiteBalanceMode:"asShot",temperatureBits:0,tintBits:0,orientation:1,width:28,height:18)
    let layout=try RawBaseStorage.layout(width:28,height:18),pool=PreviewRawBasePool(byteBudget:layout.bytes,maximumEntries:2)
    let ctx=context();defer { ctx.clearCaches() }
    try pool.withWorker {
      let a=try pool.acquire(old){ _ in },oldOwner=try XCTUnwrap(a.ownerIncarnation)
      XCTAssertNil(pool.acquirePointwiseResident(d))
      XCTAssertThrowsError(try pool.acquirePointwise(d){ _ in }) // The pinned old owner remains charged.
      pool.retire(sourceKey:"one");XCTAssertGreaterThan(pool.statistics.retiredBytes,0)
      a.releaseAfterJoinedPipeline()
      let b=try pool.acquirePointwise(d) { storage in
        let image=CIImage(color:CIColor(red:0.2,green:0.3,blue:0.4,alpha:1)).cropped(to:CGRect(x:0,y:0,width:28,height:18))
        try storage.fill(image,context:ctx,pointwiseAuthority:d.fingerprint())
      }
      XCTAssertNotEqual(b.ownerIncarnation,oldOwner);XCTAssertTrue(try XCTUnwrap(b.pointwiseInputCertificate).eligible)
      let owner=b.ownerIncarnation;b.releaseAfterJoinedPipeline()
      let hit=try XCTUnwrap(pool.acquirePointwiseResident(d));XCTAssertEqual(hit.ownerIncarnation,owner)
      pool.retire(sourceKey:"one")
      XCTAssertThrowsError(try pool.acquirePointwise(d){ _ in }) // No same-key replacement while old pin is live.
      hit.releaseAfterJoinedPipeline();XCTAssertEqual(try pool.drain().residentBytes,0)
    }
  }
  func testActualColdVetoEdgeFractionHDRAndOriginalPointAllFinite() throws {
    let ctx=context(),device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    defer { ctx.clearCaches();scope.closeAndRetire() }
    try autoreleasepool {
      let width=64,height=48
      var values=[SIMD4<Float>]()
      for y in 0..<height { for x in 0..<width {
        let r: Float=x==0 ? -0x1p20:(x==width-1 ? 0x1p20:Float(x)*0.03)
        let g: Float=y==0 ? 0x1p20:(y==height-1 ? -0x1p20:Float(y)*0.02)
        values.append(.init(r,g,Float((x+y)%9)*0.1,1))
      }}
      let image=literal(values,width:width,height:height),owner=try RawBaseStorage(width:width,height:height)
      try owner.fill(image,context:ctx,pointwiseAuthority:"literal-edge")
      XCTAssertTrue(try XCTUnwrap(owner.pointwiseInputCertificate).eligible)
      let grid=try PreviewNativePointwiseCertificateV1.grid(width:width,height:height)
      var guardOwner: PreviewNativePointwiseGuardV1?
      try autoreleasepool {
        let ticket=try scope.reserveSharedOperation(bytes:[RawBaseStorage.layout(width:width,height:height).bytes])[0]
        guardOwner=try .init(grid:grid,ticket:ticket)
        XCTAssertTrue(try guardOwner!.veto(PreviewNativePointwiseCertificateV1.vetoImage(owner.image()),context:ctx,check:{}))
        ctx.clearCaches()
      }
      guardOwner=nil
      let scratchLayout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
      let scratchTicket=try scope.reserveSharedOperation(bytes:[scratchLayout.bytes])[0]
      let scratch=try PreviewInteractiveProxyStorage(layout:scratchLayout,ticket:scratchTicket,device:device)
      let saturation21=(0...20).map { -1.0+Double($0)*0.1 }
      for s in saturation21+[2,Double.leastNonzeroMagnitude] {
        let p=try recipe(s).adjustmentsV3!
        let point=try DevelopmentColorEngineV3.applyPointwise(p,to:owner.image())
        try PreviewInteractiveProxyV3.validate(point,using:scratch,context:ctx,check:{})
      }
      // Fixed fraction bilinear samples: pure positive affine, no filter/negative lobes.
      let fractionImage=owner.image().transformed(by:.init(translationX:0.25,y:0.375))
        .cropped(to:CGRect(x:1,y:1,width:width-2,height:height-2))
      let point=try DevelopmentColorEngineV3.applyPointwise(try recipe(2).adjustmentsV3!,to:fractionImage)
      try PreviewInteractiveProxyV3.validate(point,using:scratch,context:ctx,check:{})
      ctx.clearCaches()
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
  }
  func testPublicCanonicalFITAgainstNativeCertificateColdWarmAndSettledSeparation() async throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      var revision: UInt64=0
      for s in [-1.0,-0.5,Double.leastNonzeroMagnitude,0.5,1,2] {
        let r=try recipe(s);revision+=1
        let control=try await service.render(request(lease,consumer,r,revision:revision,quality:.settled));revision+=1
        let candidate=try await service.render(request(lease,consumer,r,revision:revision))
        let observed=await service.nativePointwiseReceiptForTesting()
        let receipt=try XCTUnwrap(observed)
        XCTAssertTrue(receipt.certified);XCTAssertEqual(receipt.fullNativeChecks,0)
        XCTAssertTrue(candidate.approximate);XCTAssertFalse(control.approximate)
        XCTAssertEqual(candidate.approximation?.nativeToProxyScale,1)
        XCTAssertEqual(candidate.approximation?.proxyInputSize,lease.orientedNativeSize)
        XCTAssertNotEqual(candidate.outputKey,control.outputKey)
        let a=try bytes(candidate.image),b=try bytes(control.image)
        XCTAssertEqual(a.count,b.count)
        for i in a.indices { XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),2) }
      }
      let stats=await service.statistics()
      XCTAssertEqual(stats.rawBaseFills,1);XCTAssertEqual(stats.rawBaseHits,5)
      XCTAssertEqual(stats.maximumObservedNativeRenders,1)
    } catch { await service.closeAll();throw error }
    await service.closeAll()
    let closed=await service.statistics();XCTAssertEqual(closed.rawBaseResidentBytes,0);XCTAssertEqual(closed.rawBasePinnedBytes,0)
  }
  func testActualLegacyZeroUsesSamePolicyCanonicalResidencyAndNextRequestReusesOwner() async throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      _=try await service.render(request(lease,consumer,recipe(0.4),revision:1))
      let firstObserved=await service.nativePointwiseReceiptForTesting(),filled=try XCTUnwrap(firstObserved)
      XCTAssertTrue(filled.certified);XCTAssertTrue(filled.sourceCold);XCTAssertNotNil(filled.owner)
      let beforeZero=await service.statistics()
      XCTAssertEqual(beforeZero.rawBaseFills,1);XCTAssertEqual(beforeZero.rawBaseHits,0)
      XCTAssertGreaterThan(beforeZero.rawBaseResidentBytes,0)
      let result=try await service.render(request(lease,consumer,recipe(0),revision:2))
      XCTAssertFalse(result.approximate)
      let observed=await service.nativePointwiseReceiptForTesting()
      let receipt=try XCTUnwrap(observed)
      XCTAssertEqual(receipt.reason,"legacyDelegate");XCTAssertFalse(receipt.sourceCold);XCTAssertFalse(receipt.certified)
      XCTAssertNil(receipt.fullNativeChecks) // The untouched original body is not instrumented.
      let atZero=await service.statistics()
      XCTAssertEqual(atZero.rawBaseFills,beforeZero.rawBaseFills);XCTAssertEqual(atZero.rawBaseHits,beforeZero.rawBaseHits)
      XCTAssertEqual(atZero.rawBaseResidentBytes,beforeZero.rawBaseResidentBytes)
      XCTAssertEqual(atZero.rawBaseEvictions,beforeZero.rawBaseEvictions);XCTAssertEqual(atZero.rawBasePinnedBytes,0)
      // Profile is off: settled zero takes the SAME service/pool's ordinary canonical operation.
      let baseline=try await service.render(request(lease,consumer,recipe(0),revision:3,quality:.settled))
      let a=try bytes(result.image),b=try bytes(baseline.image)
      XCTAssertEqual(a.count,b.count)
      for i in a.indices { XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),2) }
      let ordinary=await service.statistics()
      XCTAssertEqual(ordinary.rawBaseFills,atZero.rawBaseFills);XCTAssertEqual(ordinary.rawBaseHits,atZero.rawBaseHits)
      XCTAssertEqual(ordinary.rawBaseResidentBytes,atZero.rawBaseResidentBytes)
      XCTAssertEqual(ordinary.rawBaseEvictions,atZero.rawBaseEvictions);XCTAssertEqual(ordinary.rawBasePinnedBytes,0)
      _=try await service.render(request(lease,consumer,recipe(0.4),revision:4))
      let next=await service.nativePointwiseReceiptForTesting()
      let reused=try XCTUnwrap(next)
      XCTAssertFalse(reused.sourceCold);XCTAssertEqual(reused.owner,filled.owner);XCTAssertTrue(reused.certified)
      let after=await service.statistics()
      XCTAssertEqual(after.rawBaseFills,ordinary.rawBaseFills);XCTAssertEqual(after.rawBaseHits,ordinary.rawBaseHits+1)
      XCTAssertEqual(after.rawBaseEvictions,ordinary.rawBaseEvictions);XCTAssertEqual(after.maximumObservedNativeRenders,1)
    } catch { await service.closeAll();throw error }
    await service.closeAll()
    let closed=await service.statistics()
    XCTAssertEqual(closed.rawBaseResidentBytes,0);XCTAssertEqual(closed.rawBasePinnedBytes,0)
    XCTAssertEqual(closed.rawBaseRetiredBytes,0);XCTAssertEqual(closed.rawBaseBuildingBytes,0);XCTAssertEqual(closed.rawBaseReservedBytes,0)
  }
  func testActualAlphaDomainRejectsCertificateAndUsesSameFilledPinFullChecks() async throws {
    let (root,source)=try fixture(alpha:128);defer { try? FileManager.default.removeItem(at:root) }
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      _=try await service.render(request(lease,consumer,recipe(),revision:1))
      let observed=await service.nativePointwiseReceiptForTesting()
        let receipt=try XCTUnwrap(observed)
      XCTAssertFalse(receipt.certified);XCTAssertEqual(receipt.reason,"certificateDomain");XCTAssertEqual(receipt.fullNativeChecks,1)
      let stats=await service.statistics();XCTAssertEqual(stats.rawBaseFills,1);XCTAssertEqual(stats.rawBaseMisses,1)
    } catch { await service.closeAll();throw error }
    await service.closeAll()
  }
  func testCurveInvertIsWholeCanonicalFallbackAndNeverConsumesNativeCertificate() async throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      var r=try recipe()
      r.adjustmentsV3!.curves.enabled=true
      r.adjustmentsV3!.curves.rgb.curve = .init(points:[.init(x:0,y:1),.init(x:1,y:0)])
      let candidate=try await service.render(request(lease,consumer,r,revision:1))
      let observed=await service.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(observed)
      XCTAssertFalse(candidate.approximate);XCTAssertEqual(receipt.reason,"recipe")
      let baseline=try await service.render(request(lease,consumer,r,revision:2,quality:.settled))
      let a=try bytes(candidate.image),b=try bytes(baseline.image)
      XCTAssertEqual(a.count,b.count)
      for i in a.indices { XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),2) }
      let stats=await service.statistics();XCTAssertEqual(stats.rawBaseFills,0)
    } catch { await service.closeAll();throw error }
    await service.closeAll()
  }
  func testHeldProviderChargeAndSameWorkerCloseJoinReleaseOnlyAfterActualOwner() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(),plan=try native.nativePointwisePlan(recipe:r,sourceKey:"source",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824),ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    var held: NSImage?
    try pool.withWorker {
      try autoreleasepool {
        let pixels=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol })
        held=pixels.image;XCTAssertTrue(try XCTUnwrap(pixels.nativePointwise).certified)
        native.context.clearCaches()
      }
      scope.closeAndRetire();XCTAssertEqual(try pool.drain().residentBytes,0)
    }
    XCTAssertGreaterThan(ledger.statistics.chargedCPUBytes,0);XCTAssertGreaterThan(ledger.statistics.retiredCPUBytes,0)
    try autoreleasepool { XCTAssertFalse(try bytes(XCTUnwrap(held)).isEmpty) }
    autoreleasepool { held=nil }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
  }
  func testCancellationBeforeFillHasNoOwnerAndKnownPeakCapacityDoesNotFallThrough() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(),plan=try native.nativePointwisePlan(recipe:r,sourceKey:"source",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824),ledger=PreviewPresentationLedger(cpuBudget:1,gpuBudget:1)
    let scope=PreviewPresentationScope(ledgerForTesting:ledger),cancel=DevelopmentAnalysisCancellation();cancel.cancel()
    try pool.withWorker {
      XCTAssertThrowsError(try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,cancellation:cancel,canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol }))
      XCTAssertThrowsError(try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol }))
      XCTAssertEqual(pool.statistics.fills,0);XCTAssertEqual(pool.statistics.pinnedBytes,0)
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
  func testColdLifecycleMarkersDrainBeforePostAndWarmDoesNotRefill() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(),plan=try native.nativePointwisePlan(recipe:r,sourceKey:"lifecycle",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400)
    var labels=[String]()
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{ labels.append($0) })
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    try pool.withWorker {
      try autoreleasepool {
        let first=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol })
        XCTAssertTrue(try XCTUnwrap(first.nativePointwise).sourceCold)
        XCTAssertTrue(try XCTUnwrap(first.nativePointwise).certified)
      }
      XCTAssertEqual(labels.filter{$0.hasPrefix("pointwise-")},[
        "pointwise-native-fill/before","pointwise-native-fill/joined-scanned",
        "pointwise-cold-context/retire-before","pointwise-cold-context/retire-after",
        "pointwise-post/prepare-before","pointwise-post/output-joined"])
      labels.removeAll()
      try autoreleasepool {
        let warm=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol })
        XCTAssertFalse(try XCTUnwrap(warm.nativePointwise).sourceCold)
        XCTAssertFalse(try XCTUnwrap(warm.nativePointwise).samplerCold)
        XCTAssertTrue(try XCTUnwrap(warm.nativePointwise).certified)
      }
      XCTAssertEqual(labels.filter{$0.hasPrefix("pointwise-")},["pointwise-post/prepare-before","pointwise-post/output-joined"])
      XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(pool.statistics.hits,1)
      XCTAssertEqual(try pool.drain().residentBytes,0)
    }
    scope.closeAndRetire();XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
  }
  func testColdAbortAfterActualJoinDoesNotEnterPostOrPublishOwner() throws {
    enum ProbeAbort: Error { case stopped }
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(),plan=try native.nativePointwisePlan(recipe:r,sourceKey:"abort",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400)
    var labels=[String]()
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{ label in
      labels.append(label)
      if label=="pointwise-native-fill/joined-scanned" { throw ProbeAbort.stopped }
    })
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    try pool.withWorker {
      try autoreleasepool {
        XCTAssertThrowsError(try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,
          memoryLimit:512,cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Eligible native path unexpectedly delegated");throw PreviewPresentationError.allocationProtocol }))
      }
      XCTAssertTrue(labels.contains("base-native-fill-joined"));XCTAssertTrue(labels.contains("base-CPU-finite-complete"))
      XCTAssertFalse(labels.contains{$0.hasPrefix("pointwise-post/")})
      XCTAssertEqual(pool.statistics.fills,0);XCTAssertEqual(pool.statistics.buildingBytes,0)
      XCTAssertEqual(pool.statistics.reservedBytes,0);XCTAssertEqual(pool.statistics.residentBytes,0)
    }
    scope.closeAndRetire();XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
  }
  func testEveryCanonicalFallbackUsesTheSuppliedOperationOnceAndNeverRetriesItsFailure() throws {
    enum CanonicalStop: Error { case stopped }
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(),layout=try PreviewNativePointwiseV1.layout(recipe:r,size:native.nativeSize,maxPixel:2400)
    let reasons:[PreviewNativePointwiseV1.Reason]=[.recipe,.geometry,.legacyDelegate,.viewport,.nativePoolDisabled,.sourceProfile,.certificateDomain,.grainCanonical]
    for reason in reasons {
      let plan=PreviewNativePointwisePlanV1(descriptor:nil,grid:nil,outputLayout:layout,fallback:reason)
      let pool=PreviewRawBasePool(byteBudget:1),ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
      var calls=0
      try pool.withWorker {
        XCTAssertThrowsError(try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ calls+=1;throw CanonicalStop.stopped })) { error in
          guard case CanonicalStop.stopped=error else { return XCTFail("Canonical failure must propagate without a second render: \(error)") }
        }
        XCTAssertEqual(calls,1,"Every canonical reason must call the service-owned operation exactly once: \(reason)")
        XCTAssertEqual(pool.statistics.fills,0);XCTAssertEqual(pool.statistics.hits,0)
        XCTAssertEqual(try pool.drain().residentBytes,0)
      }
      scope.closeAndRetire();XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
    }
  }

  func testColdBuildReleasesIdleCanonicalContextBeforeFillAndWarmKeepsItsIdentity() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(),plan=try native.nativePointwisePlan(recipe:r,sourceKey:"idle-context",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400)
    // Exercise the ordinary V3 context owner first, then drain its complete output
    // graph/CG scope. Legacy nil-marker image grain remains a normal canonical path.
    let grain=try DevelopmentRecipe().applying(.promoteToV3)
      .applying(.setParameters(.blackAndWhite(.init(enabled:true,grain:0.3))))
    try autoreleasepool { _ = try native.render(recipe:grain,maxPixel:2400) }
    weak var oldCanonical: CIContext? = native.context
    XCTAssertNotNil(oldCanonical)
    var retirement=[String](),fillsObserved=0
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{ label in
      if label.hasPrefix("idle-canonical-context/") {
        retirement.append(label)
        if label=="idle-canonical-context/retire-before" { XCTAssertNotNil(oldCanonical) }
        if label=="idle-canonical-context/retire-after" { XCTAssertNil(oldCanonical) }
      }
      if label=="pointwise-native-fill/before" {
        fillsObserved+=1
        XCTAssertNil(oldCanonical,"The old canonical instance must end BEFORE native cold fill")
        XCTAssertEqual(retirement,["idle-canonical-context/retire-before","idle-canonical-context/retire-after"])
      }
    })
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    defer { scope.closeAndRetire() }
    try pool.withWorker {
      defer { XCTAssertNoThrow(try pool.drain()) }
      try autoreleasepool {
        let first=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Eligible cold path delegated");throw PreviewPresentationError.allocationProtocol })
        XCTAssertTrue(try XCTUnwrap(first.nativePointwise).sourceCold)
      }
      XCTAssertNil(oldCanonical);XCTAssertEqual(fillsObserved,1)
      let idleIdentity=ObjectIdentifier(native.context)
      retirement.removeAll()
      try autoreleasepool {
        let warm=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Eligible warm path delegated");throw PreviewPresentationError.allocationProtocol })
        XCTAssertFalse(try XCTUnwrap(warm.nativePointwise).sourceCold)
      }
      XCTAssertEqual(ObjectIdentifier(native.context),idleIdentity)
      XCTAssertTrue(retirement.isEmpty);XCTAssertEqual(fillsObserved,1)
      XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(pool.statistics.hits,1)
      XCTAssertEqual(pool.statistics.pinnedBytes,0)
    }
    scope.closeAndRetire()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
  }


  func testHistogramReleasesIdleCanonicalContextBeforeValidationAndPreservesExactBins() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(),fingerprint=try EditingFingerprint.of(r)
    let preview=DevelopmentPreviewRequest(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:.primary,
      revision:1,recipe:r,quality:.settled,viewport:.init(maxPixel:2400))
    let valid=DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:fingerprint,
      stage:.workingImageBeforeGeometry,operation:.histogram)
    let invalid=DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:String(repeating:"0",count:64),
      stage:.workingImageBeforeGeometry,operation:.histogram)
    // A validation failure occurs before the analysis engine creates its CIContext
    // or graph, so this weak lifetime check proves retirement precedes analysis work.
    try autoreleasepool { _ = try native.render(recipe:r,maxPixel:2400) }
    weak var beforeInvalid:CIContext?=native.context
    XCTAssertNotNil(beforeInvalid)
    XCTAssertThrowsError(try native.analyze(invalid,sourceContentID:source.contentSHA256)) { error in
      guard case DevelopmentPreviewError.invalidRequest = error else { return XCTFail("Expected invalid analysis request") }
    }
    XCTAssertNil(beforeInvalid,"Idle canonical context must retire before independent analysis validation")
    let binding=DevelopmentLocalEditSourceBinding(sourceContentID:source.contentSHA256,
      exifOrientation:native.originalEXIFOrientation,orientedWidth:Int(native.nativeSize.width),orientedHeight:Int(native.nativeSize.height))
    var referenceCache:DevelopmentAnalysisCacheEntry?
    let expected=try autoreleasepool {
      try DevelopmentAnalysisEngine.run(capture:source.sourceLocation,request:valid,sourceBinding:binding,
        memoryHint:512,cache:&referenceCache,localDecoderContractFingerprint:native.localDecoderContractFingerprint)
    }
    try autoreleasepool { _ = try native.render(recipe:r,maxPixel:2400) }
    weak var beforeHistogram:CIContext?=native.context
    XCTAssertNotNil(beforeHistogram)
    let actual=try autoreleasepool { try native.analyze(valid,sourceContentID:source.contentSHA256) }
    XCTAssertNil(beforeHistogram)
    XCTAssertEqual(actual,expected,"All original bins, sample counts, metadata and bindings must remain identical")
    guard case .histogram(let histogram)=actual.value else{return XCTFail("Actual histogram required")}
    XCTAssertGreaterThan(histogram.visibleSamples,0)
    weak var beforeCachedHistogram:CIContext?=native.context
    let cached=try autoreleasepool { try native.analyze(valid,sourceContentID:source.contentSHA256) }
    XCTAssertNil(beforeCachedHistogram)
    XCTAssertEqual(cached,expected,"The existing scalar-cache result remains identical")
    XCTAssertEqual(try EditingFingerprint.of(r),fingerprint)
  }


  func testActualWarmIPTimingOnOffPreservesPixelsAndReleasesCollectorWhileFrameLives() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let sourcePre=try RenderFiles.hash(source.sourceLocation)
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe();var plan=try native.nativePointwisePlan(recipe:r,sourceKey:"ip-on-off",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400)
    plan.preserveVerifiedInput=true
    XCTAssertNil(plan.fallback)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824)
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    defer { scope.closeAndRetire() }
    var held:PreviewPixels?
    weak var weakTiming:PreviewQALifecycleTrace.IPTiming?
    var packet:PreviewQALifecycleTrace.IPPacket?
    var offBytes=[UInt8](),onBytes=[UInt8](),warmOwner:UUID?
    try pool.withWorker {
      defer {
        do {
          let final=try pool.drain()
          XCTAssertEqual(final.residentBytes,0);XCTAssertEqual(final.reservedBytes,0)
          XCTAssertEqual(final.buildingBytes,0);XCTAssertEqual(final.pinnedBytes,0)
          XCTAssertEqual(final.retiredBytes,0)
        } catch { XCTFail("Actual pool drain failed: \(error)") }
      }
      try autoreleasepool {
        let cold=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Cold warmup delegated");throw PreviewPresentationError.allocationProtocol })
        XCTAssertTrue(try XCTUnwrap(cold.nativePointwise).sourceCold)
      }
      try autoreleasepool {
        let off=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Warm OFF delegated");throw PreviewPresentationError.allocationProtocol })
        let receipt=try XCTUnwrap(off.nativePointwise)
        XCTAssertFalse(receipt.sourceCold);XCTAssertFalse(receipt.samplerCold);XCTAssertTrue(receipt.certified)
        XCTAssertEqual(receipt.fullNativeChecks,0);warmOwner=receipt.owner
        XCTAssertEqual(off.outputSize,CGSize(width:28,height:18))
        offBytes=try bytes(off.image)
      } // OFF image/provider released before ON; only tiny tight RGBA8 bytes remain.
      try autoreleasepool {
        var timing:PreviewQALifecycleTrace.IPTiming? = .init(id:UUID(),ordinal:3)
        weakTiming=timing
        held=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),qaIPTiming:timing,
          canonicalRender:{ XCTFail("Warm ON delegated");throw PreviewPresentationError.allocationProtocol })
        let receipt=try XCTUnwrap(held?.nativePointwise)
        XCTAssertFalse(receipt.sourceCold);XCTAssertFalse(receipt.samplerCold);XCTAssertTrue(receipt.certified)
        XCTAssertEqual(receipt.fullNativeChecks,0);XCTAssertEqual(receipt.owner,warmOwner)
        XCTAssertEqual(held?.outputSize,CGSize(width:28,height:18))
        packet=timing?.finish(successful:true)
        timing=nil
        XCTAssertNil(weakTiming,"Returned image/provider must not retain the worker-local collector")
        XCTAssertNotNil(held)
        XCTAssertGreaterThan(ledger.statistics.chargedCPUBytes,0,"ON image is intentionally still alive")
        onBytes=try bytes(try XCTUnwrap(held).image)
      }
      XCTAssertNil(weakTiming)
      XCTAssertEqual(offBytes.count,28*18*4);XCTAssertEqual(onBytes.count,offBytes.count)
      XCTAssertEqual(onBytes,offBytes,"Instrumentation ON/OFF same warm path must have zero RGBA8 differences, including alpha")
      let observed=try XCTUnwrap(packet)
      XCTAssertTrue(observed.successful);XCTAssertEqual(observed.sourceCold,false)
      XCTAssertEqual(observed.samplerCold,false);XCTAssertEqual(observed.certified,true)
      XCTAssertEqual(observed.fitTask.count,1);XCTAssertEqual(observed.outputTask.count,1)
      XCTAssertEqual(observed.fitTask.failures,0);XCTAssertEqual(observed.outputTask.failures,0)
      XCTAssertFalse(observed.timingOverflow)
      // Missing CIRenderInfo remains unavailable; no kernel-time or nonnull-info assertion.
      try autoreleasepool { held=nil }
      XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(pool.statistics.hits,2)
      XCTAssertEqual(pool.statistics.pinnedBytes,0)
    }
    scope.closeAndRetire()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
    XCTAssertEqual(ledger.statistics.retiredCPUBytes,0);XCTAssertEqual(ledger.statistics.retiredGPUBytes,0)
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
    XCTAssertEqual(try RenderFiles.hash(source.sourceLocation),sourcePre)
  }

  func testWarmIPOneClearOptInPreservesExactPixelsTasksOwnerAndJoinedCleanup() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let sourcePre=try RenderFiles.hash(source.sourceLocation)
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(0.3);var plan=try native.nativePointwisePlan(recipe:r,sourceKey:"ip-one-clear",generation:1,
      verifiedContentID:source.contentSHA256,maxPixel:2400)
    plan.preserveVerifiedInput=true
    XCTAssertNil(plan.fallback)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824)
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    defer { scope.closeAndRetire() }
    var expected=[UInt8](),actual=[UInt8](),owner:UUID?
    var controlPacket:PreviewQALifecycleTrace.IPPacket?,candidatePacket:PreviewQALifecycleTrace.IPPacket?
    try pool.withWorker {
      defer {
        do {
          let final=try pool.drain()
          XCTAssertEqual(final.residentBytes,0);XCTAssertEqual(final.reservedBytes,0)
          XCTAssertEqual(final.buildingBytes,0);XCTAssertEqual(final.pinnedBytes,0);XCTAssertEqual(final.retiredBytes,0)
        } catch { XCTFail("Actual pool drain failed: \(error)") }
      }
      try autoreleasepool {
        let cold=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),canonicalRender:{ XCTFail("Cold warmup delegated");throw PreviewPresentationError.allocationProtocol })
        XCTAssertTrue(try XCTUnwrap(cold.nativePointwise).sourceCold)
      }
      for skip in [false,true] {
        try autoreleasepool {
          let timing=PreviewQALifecycleTrace.IPTiming(id:UUID(),ordinal:skip ? 4:3)
          let pixels=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
            cancellation:DevelopmentAnalysisCancellation(),qaIPTiming:timing,qaSkipJoinedOutputClear:skip,
            canonicalRender:{ XCTFail("Warm paired path delegated");throw PreviewPresentationError.allocationProtocol })
          let receipt=try XCTUnwrap(pixels.nativePointwise),packet=timing.finish(successful:true)
          XCTAssertTrue(receipt.certified);XCTAssertFalse(receipt.sourceCold);XCTAssertFalse(receipt.samplerCold)
          XCTAssertEqual(receipt.fullNativeChecks,0);XCTAssertEqual(pixels.outputSize,CGSize(width:28,height:18))
          if skip { XCTAssertEqual(receipt.owner,owner);actual=try bytes(pixels.image);candidatePacket=packet }
          else { owner=receipt.owner;XCTAssertNotNil(owner);expected=try bytes(pixels.image);controlPacket=packet }
          XCTAssertEqual(pool.statistics.pinnedBytes,0,"Both task joins and original input-pin retirement occurred before return")
          XCTAssertGreaterThan(ledger.statistics.chargedCPUBytes,0,"Returned display owner is still live")
        }
        XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
      }
      XCTAssertEqual(expected.count,28*18*4);XCTAssertEqual(actual,expected,"Exact RGBA8 including alpha, no tolerance")
      for observed in [try XCTUnwrap(controlPacket),try XCTUnwrap(candidatePacket)] {
        XCTAssertTrue(observed.successful);XCTAssertEqual(observed.sourceCold,false)
        XCTAssertEqual(observed.samplerCold,false);XCTAssertEqual(observed.certified,true)
        XCTAssertEqual(observed.fitTask.count,1);XCTAssertEqual(observed.outputTask.count,1)
        XCTAssertEqual(observed.fitTask.failures,0);XCTAssertEqual(observed.outputTask.failures,0)
        XCTAssertEqual(observed.contextCreateCount,1);XCTAssertFalse(observed.timingOverflow)
      }
      // These are timed cleanup-site counts, not assertions that the final nil
      // outer defer performed a CI clear. Candidate must not count its skipped site.
      XCTAssertEqual(try XCTUnwrap(controlPacket).contextClearCount,3)
      XCTAssertEqual(try XCTUnwrap(candidatePacket).contextClearCount,2)
      XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(pool.statistics.hits,2)
    }
    scope.closeAndRetire()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
    XCTAssertEqual(ledger.statistics.retiredCPUBytes,0);XCTAssertEqual(ledger.statistics.retiredGPUBytes,0)
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
    XCTAssertEqual(try RenderFiles.hash(source.sourceLocation),sourcePre)
  }
  func testWarmSharedFITIntermediateKeepsExactPixelsChecksAndJoinedOwners() throws {
    let (root,source)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let pre=try RenderFiles.hash(source.sourceLocation)
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let r=try recipe(0.3);var plan=try native.nativePointwisePlan(recipe:r,sourceKey:"shared-fit",generation:1,verifiedContentID:source.contentSHA256,maxPixel:2400)
    plan.preserveVerifiedInput=true;XCTAssertNil(plan.fallback)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824),ledger=PreviewPresentationLedger()
    let scope=PreviewPresentationScope(ledgerForTesting:ledger);defer{scope.closeAndRetire()}
    var reference=[UInt8](),owner:UUID?
    try pool.withWorker {
      defer{do{let s=try pool.drain();XCTAssertEqual(s.residentBytes+s.pinnedBytes+s.reservedBytes+s.buildingBytes+s.retiredBytes,0)}catch{XCTFail("Actual pool drain failed: \(error)")}}
      try autoreleasepool {
        let cold=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
          cancellation:DevelopmentAnalysisCancellation(),qaSkipJoinedOutputClear:false,qaSharedFITIntermediate:true,
          canonicalRender:{throw PreviewPresentationError.allocationProtocol})
        let receipt=try XCTUnwrap(cold.nativePointwise)
        XCTAssertTrue(receipt.sourceCold);XCTAssertFalse(receipt.sharedFITIntermediateInserted,"Cold opt-in cannot insert the node")
      }
      for enabled in [false,true] {
        try autoreleasepool {
          let timing=PreviewQALifecycleTrace.IPTiming(id:UUID(),ordinal:enabled ? 4:3)
          let pixels=try native.renderNativePointwise(recipe:r,maxPixel:2400,plan:plan,pool:pool,scope:scope,memoryLimit:512,
            cancellation:DevelopmentAnalysisCancellation(),qaIPTiming:timing,qaSkipJoinedOutputClear:false,qaSharedFITIntermediate:enabled,
            canonicalRender:{throw PreviewPresentationError.allocationProtocol})
          let receipt=try XCTUnwrap(pixels.nativePointwise),packet=timing.finish(successful:true)
          XCTAssertTrue(receipt.certified);XCTAssertFalse(receipt.sourceCold);XCTAssertFalse(receipt.samplerCold)
          XCTAssertEqual(receipt.fullNativeChecks,0);XCTAssertEqual(receipt.sharedFITIntermediateInserted,enabled)
          XCTAssertEqual(pixels.outputSize,CGSize(width:28,height:18));XCTAssertEqual(pixels.nativeSize,CGSize(width:28,height:18))
          XCTAssertEqual(pixels.approximation?.version.contains(PreviewNativePointwiseV1.sharedFITIntermediateVersion),enabled)
          if enabled{XCTAssertEqual(receipt.owner,owner);XCTAssertEqual(try bytes(pixels.image),reference,"RGBA8 must be byte exact, alpha included")}
          else{owner=receipt.owner;XCTAssertNotNil(owner);reference=try bytes(pixels.image)}
          XCTAssertTrue(packet.successful);XCTAssertEqual(packet.fitTask.count,1);XCTAssertEqual(packet.outputTask.count,1)
          XCTAssertEqual(packet.fitTask.failures,0);XCTAssertEqual(packet.outputTask.failures,0)
          XCTAssertEqual(packet.contextCreateCount,1);XCTAssertEqual(packet.contextClearCount,3,"The separate one-clear candidate is OFF")
          XCTAssertFalse(packet.timingOverflow);XCTAssertEqual(pool.statistics.pinnedBytes,0)
        }
        XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
      }
      XCTAssertEqual(reference.count,28*18*4);XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(pool.statistics.hits,2)
    }
    scope.closeAndRetire();XCTAssertEqual(ledger.statistics.chargedCPUBytes+ledger.statistics.chargedGPUBytes,0)
    XCTAssertEqual(ledger.statistics.retiredCPUBytes+ledger.statistics.retiredGPUBytes,0);XCTAssertEqual(ledger.statistics.cleanupFailures,0)
    XCTAssertEqual(try RenderFiles.hash(source.sourceLocation),pre)
  }

  /// Actual joined F32 transport, deliberately bypassing the RGBA8 output/clamping path.
  private func sharedFITObservedFloat(_ image:CIImage,context:CIContext,width:Int,height:Int)throws->[SIMD4<Float>] {
    var observed=Array(repeating:SIMD4<Float>(repeating:12345),count:width*height)
    try observed.withUnsafeMutableBytes { raw in
      let destination=CIRenderDestination(bitmapData:raw.baseAddress!,width:width,height:height,bytesPerRow:width*16,format:.RGBAf)
      destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
      destination.isFlipped=true;destination.isClamped=false;destination.isDithered=false
      let task=try context.startTask(toRender:image,to:destination)
      do{_ = try task.waitUntilCompleted()}catch{let original=error;_ = try? task.waitUntilCompleted();throw original}
    }
    return observed
  }
  func testSharedFITIntermediateRejectsActuallyObservedMalformedFloatInput() throws {
    let c=context(),device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=PreviewPresentationLedger()
    let scope=PreviewPresentationScope(ledgerForTesting:ledger);defer{c.clearCaches();scope.closeAndRetire()}
    let values:[SIMD4<Float>]=[.init(.nan,0,0,1),.init(0,.infinity,0,1),.init(0,0,-.infinity,1),.init(0,0,0,.nan),.init(0,0,0,-0.125),.init(0,0,0,1.125)]
    for (index,value) in values.enumerated() {
      try autoreleasepool {
        let input=literal(Array(repeating:value,count:8*6),width:8,height:6)
        let observed=try sharedFITObservedFloat(input,context:c,width:8,height:6)
        let observable=observed.allSatisfy { pixel in
          // Every component was written; unrelated RGB may propagate nonfinite values.
          guard (0..<4).allSatisfy({pixel[$0] != 12345}) else{return false}
          switch index {
          case 0:return pixel.x.isNaN && pixel.w==1
          case 1:return pixel.y == .infinity && pixel.w==1
          case 2:return pixel.z == -.infinity && pixel.w==1
          case 3:return pixel.w.isNaN
          case 4:return pixel.w == -0.125
          case 5:return pixel.w == 1.125
          default:return false
          }
        }
        guard observable else {
          XCTFail("STOP: malformed case \(index) was not observable through actual joined F32 transport; fixture is not qualified")
          throw NSError(domain:"RAWMaster.SharedFIT.UnobservableFixture",code:index)
        }
        c.clearCaches()
        let layout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
        let ticket=try scope.reserveSharedOperation(bytes:[layout.bytes])[0]
        let scratch=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:device)
        for enabled in [false,true] {
          let actual=PreviewNativePointwiseV1.joinedFITImage(input,insertingIntermediate:enabled)
          do {
            try PreviewInteractiveProxyV3.validate(actual,using:scratch,context:c,check:{})
            XCTFail("STOP: original/candidate must reject observed invalid F32 case \(index), enabled=\(enabled)")
            throw NSError(domain:"RAWMaster.SharedFIT.InvalidAccepted",code:index)
          } catch DevelopmentError.invalidEncoding {
            // Exact old validator rejection; a backend error or an accepted result is not a pass.
          }
          c.clearCaches()
        }
      }
      XCTAssertEqual(ledger.statistics.chargedCPUBytes+ledger.statistics.chargedGPUBytes,0)
    }
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
  }

  func testSharedFITIntermediatePreservesHDRTransparentAndFractionalFITOutput() throws {
    let c=context(),device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=PreviewPresentationLedger()
    let scope=PreviewPresentationScope(ledgerForTesting:ledger);defer{c.clearCaches();scope.closeAndRetire()}
    // Reuse the existing 64x48 literal family; transparent, partial alpha and finite HDR are all explicit.
    var values=[SIMD4<Float>]()
    for y in 0..<48{for x in 0..<64{
      if x<8{values.append(.zero)}
      else if x<16{values.append(.init(0.125,0.25,0.375,0.5))}
      else if x>55{values.append(.init(-0.25,2,4,1))}
      else{values.append(.init(Float(x)/64,Float(y)/48,0.25,1))}
    }}
    let native=literal(values,width:64,height:48).transformed(by:.init(scaleX:2,y:2))
    let fitted=native.transformed(by:.init(scaleX:0.75,y:0.75)),size=CGSize(width:128,height:96)
    XCTAssertEqual(fitted.extent,CGRect(x:0,y:0,width:96,height:72))
    var reference=[UInt8]()
    for enabled in [false,true] {
      try autoreleasepool {
        let joined=PreviewNativePointwiseV1.joinedFITImage(fitted,insertingIntermediate:enabled)
        XCTAssertEqual(joined.extent,fitted.extent)
        let checkLayout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
        let outputLayout=try PreviewInteractiveLayout.make(width:96,height:72,float:false)
        let tickets=try scope.reserveSharedOperation(bytes:[checkLayout.bytes,outputLayout.bytes])
        let scratch=try PreviewInteractiveProxyStorage(layout:checkLayout,ticket:tickets[0],device:device)
        try PreviewInteractiveProxyV3.validate(joined,using:scratch,context:c,check:{})
        let output=PreviewInteractiveManagedOutput(layout:outputLayout,ticket:tickets[1],device:device)
        let graph=DevelopedV3Graph(image:enabled ? joined:native,sourceDepth:32,sourceSize:size,canonicalSize:size,graphDescriptor:"shared-fit-tiny-boundaries")
        let pixels=try V3PreviewMaterializer.materialize(graph,context:c,maxPixel:96,managedOutput:output,managedCheck:{})
        XCTAssertEqual(pixels.nativeSize,size);XCTAssertEqual(pixels.outputSize,CGSize(width:96,height:72))
        let actual=try bytes(pixels.image)
        if enabled{XCTAssertEqual(actual,reference,"Transparent/HDR/fractional FIT output must be byte exact")}
        else{reference=actual;XCTAssertEqual(actual.count,96*72*4)}
        c.clearCaches()
      }
      XCTAssertEqual(ledger.statistics.chargedCPUBytes+ledger.statistics.chargedGPUBytes,0)
    }
    scope.closeAndRetire();XCTAssertEqual(ledger.statistics.retiredCPUBytes+ledger.statistics.retiredGPUBytes,0)
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
  }
  func testFITCoverageAdmissionAndVersionedKeyOnlyForBoundRAWLegacyDownscale() throws {
    let grid=try PreviewNativePointwiseCertificateV1.grid(width:9504,height:6336)
    let layout=try PreviewInteractiveLayout.make(width:grid.width,height:grid.height,float:false)
    var p=try XCTUnwrap(recipe().adjustmentsV3)
    p.geometry.version = .legacyV1
    p.blackAndWhite = .init(enabled:true,intensity:0.6)
    let r=DevelopmentRecipe(adjustmentsV3:p)
    let binding=try XCTUnwrap(PreviewNativePointwiseCertificateV2.binding(r,size:CGSize(width:9504,height:6336)))
    let stamp=PreviewNativePointwiseStampV1(.init(device:1,inode:2,size:3,seconds:4,nanoseconds:5,changedSeconds:6,changedNanoseconds:7))
    let capture=UUID()
    func descriptor(_ source:PreviewNativePointwiseBaseDescriptorV1.Source) -> PreviewNativePointwiseBaseDescriptorV1 {
      .init(source:source,sourceKey:"source",verifiedContentID:"hash",captureID:capture,generation:1,stamp:stamp,
            decoder:"fixture",os:"fixture",contract:PreviewNativePointwiseBaseDescriptorV1.contract,deviceRegistryID:1,
            orientation:1,width:9504,height:6336,extentXBits:0,extentYBits:0,sourceDepth:nil,originalNoiseFingerprint:"fixture")
    }
    func plan(source:PreviewNativePointwiseBaseDescriptorV1.Source = .rawDefaults(originalDefaults:"default"),
              grid:PreviewNativePointwiseCertificateV1.Grid? = nil, geometry:DevelopmentGeometryVersionV3? = .legacyV1,
              canonical:Bool = false, fallback:PreviewNativePointwiseV1.Reason? = nil,
              common:Bool = true) throws -> PreviewNativePointwisePlanV1 {
      let actualGrid=try grid ?? PreviewNativePointwiseCertificateV1.grid(width:9504,height:6336)
      var value=PreviewNativePointwisePlanV1(descriptor:descriptor(source),grid:actualGrid,outputLayout:layout,fallback:fallback)
      value.commonPointBinding=common ? binding:nil
      value.canonicalFullChecks=canonical
      value.fitCoverageGeometryVersion=geometry
      return value
    }
    let eligible=try plan(grid:grid)
    let old=try plan(grid:grid,geometry:nil)
    XCTAssertEqual(PreviewFITCoverageV1.version,"native-fit-upper-coverage-straight-rgb-v2")
    XCTAssertTrue(eligible.mayNormalizeFITCoverage)
    XCTAssertTrue(try plan(geometry:.legacyV2).mayNormalizeFITCoverage)
    XCTAssertNotEqual(try eligible.keySuffix(),try old.keySuffix())
    let wrongGeometry=try plan(geometry:.projectiveV3_1)
    XCTAssertFalse(wrongGeometry.mayNormalizeFITCoverage)
    XCTAssertEqual(try wrongGeometry.keySuffix(),try old.keySuffix())
    XCTAssertFalse(try plan(source:.imageOrientedDecode(colorProfile:"icc")).mayNormalizeFITCoverage)
    XCTAssertFalse(try plan(grid:PreviewNativePointwiseCertificateV1.grid(width:28,height:18)).mayNormalizeFITCoverage)
    XCTAssertFalse(try plan(grid:PreviewNativePointwiseCertificateV1.grid(width:2401,height:2401)).mayNormalizeFITCoverage)
    XCTAssertFalse(try plan(canonical:true).mayNormalizeFITCoverage)
    XCTAssertFalse(try plan(fallback:.viewport).mayNormalizeFITCoverage)
    XCTAssertFalse(try plan(common:false).mayNormalizeFITCoverage)
  }

  func testActualNativeFITCoveragePreservesStraightRGBAndRejectsNegativeOrNonfiniteSamples() throws {
    let c=context(),device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=PreviewPresentationLedger()
    let scope=PreviewPresentationScope(ledgerForTesting:ledger)
    defer{c.clearCaches();scope.closeAndRetire()}
    let extent=CGRect(x:0,y:0,width:8,height:6)
    func read(_ image:CIImage) throws -> [SIMD4<Float>] {
      let values=try sharedFITObservedFloat(image,context:c,width:8,height:6)
      XCTAssertTrue(values.allSatisfy { pixel in (0..<4).allSatisfy{pixel[$0] != 12345} })
      return values
    }
    func rejects(_ check:()throws->Void) {
      do{try check();XCTFail("The original strict encoding error was required")}
      catch DevelopmentError.invalidEncoding {}
      catch{XCTFail("Expected invalidEncoding, received \(error)")}
    }

    let layout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
    try autoreleasepool {
      let ticket=try scope.reserveSharedOperation(bytes:[layout.bytes])[0]
      let scratch=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:device)
      defer{c.clearCaches()}
      let legal:[SIMD4<Float>]=[.zero,.init(0.125,0.25,0.375,0.5),.init(-0.25,2,4,1)]
      for pixel in legal {
        let image=literal(Array(repeating:pixel,count:48),width:8,height:6)
        let observed=try read(image)
        XCTAssertTrue(observed.allSatisfy{$0==pixel})
        try DevelopmentLocalEngineV3.validatePixels(image,context:c)
        let repaired=try PreviewFITCoverageV1.normalize(image,extent:extent)
        XCTAssertEqual(try read(repaired),observed)
        try PreviewInteractiveProxyV3.validate(repaired,using:scratch,context:c,check:{})
      }

      // Division by 1.125 has exact expected results for these premultiplied inputs.
      let overshoot=SIMD4<Float>(-0.28125,1.6875,4.5,1.125)
      let overshot=literal(Array(repeating:overshoot,count:48),width:8,height:6)
      XCTAssertTrue(try read(overshot).allSatisfy{$0==overshoot})
      rejects{try DevelopmentLocalEngineV3.validatePixels(overshot,context:c)}
      rejects{try PreviewInteractiveProxyV3.validate(overshot,using:scratch,context:c,check:{})}
      let repaired=try PreviewFITCoverageV1.normalize(overshot,extent:extent)
      XCTAssertTrue(try read(repaired).allSatisfy{$0 == .init(-0.25,1.5,4,1)})
      try DevelopmentLocalEngineV3.validatePixels(repaired,context:c)
      try PreviewInteractiveProxyV3.validate(repaired,using:scratch,context:c,check:{})

      let malformed:[(SIMD4<Float>,(SIMD4<Float>)->Bool)]=[
        (.init(0,0,0,-0.125),{$0.w == -0.125}),
        (.init(0,0,0,.nan),{$0.w.isNaN}),
        (.init(0,0,0,.infinity),{$0.w == .infinity}),
        (.init(.nan,0,0,1.125),{$0.x.isNaN && $0.w == 1.125}),
        (.init(0,-.infinity,0,1),{$0.y == -.infinity && $0.w == 1})
      ]
      for (value,observable) in malformed {
        let image=literal(Array(repeating:value,count:48),width:8,height:6)
        guard try read(image).allSatisfy(observable) else {
          XCTFail("Malformed native value was not observable in the original F32 fixture")
          throw DevelopmentError.invalidEncoding
        }
        rejects{try DevelopmentLocalEngineV3.validatePixels(image,context:c)}
        let uncorrected=try PreviewFITCoverageV1.normalize(image,extent:extent)
        XCTAssertTrue(try read(uncorrected).allSatisfy(observable))
        rejects{try DevelopmentLocalEngineV3.validatePixels(uncorrected,context:c)}
        rejects{try PreviewInteractiveProxyV3.validate(uncorrected,using:scratch,context:c,check:{})}
      }
    }
    scope.closeAndRetire()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes+ledger.statistics.chargedGPUBytes,0)
    XCTAssertEqual(ledger.statistics.retiredCPUBytes+ledger.statistics.retiredGPUBytes,0)
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
  }

  func testActualFITCoverageLeavesTransparentHDRCanonicalManagedPixelsExact() throws {
    let c=context(),device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=PreviewPresentationLedger()
    let scope=PreviewPresentationScope(ledgerForTesting:ledger)
    defer{c.clearCaches();scope.closeAndRetire()}
    var values=[SIMD4<Float>]()
    for y in 0..<96{for x in 0..<128{
      let chartX=x/2,chartY=y/2
      if chartX<8{values.append(.zero)}
      else if chartX<16{values.append(.init(0.125,0.25,0.375,0.5))}
      else if chartX>55{values.append(.init(-0.25,2,4,1))}
      else{values.append(.init(Float(chartX)/64,Float(chartY)/48,0.25,1))}
    }}
    let native=literal(values,width:128,height:96)
    let size=CGSize(width:128,height:96),extent=CGRect(x:0,y:0,width:96,height:72)
    var reference=[UInt8]()
    for normalized in [false,true] {
      try autoreleasepool {
        defer{c.clearCaches()}
        let nativeInput=normalized ? try PreviewFITCoverageV1.normalize(native,extent:native.extent):native
        if normalized { try DevelopmentLocalEngineV3.validatePixels(nativeInput,context:c) }
        let fitted=nativeInput.transformed(by:.init(scaleX:0.75,y:0.75))
        XCTAssertEqual(fitted.extent,extent)
        let checked=normalized ? try PreviewFITCoverageV1.normalize(fitted,extent:extent):fitted
        let checkLayout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
        let outputLayout=try PreviewInteractiveLayout.make(width:96,height:72,float:false)
        let tickets=try scope.reserveSharedOperation(bytes:[checkLayout.bytes,outputLayout.bytes])
        let scratch=try PreviewInteractiveProxyStorage(layout:checkLayout,ticket:tickets[0],device:device)
        try PreviewInteractiveProxyV3.validate(checked,using:scratch,context:c,check:{})
        let output=PreviewInteractiveManagedOutput(layout:outputLayout,ticket:tickets[1],device:device)
        let graph=DevelopedV3Graph(image:normalized ? checked:native,sourceDepth:32,
          sourceSize:size,canonicalSize:size,graphDescriptor:"fit-coverage-tiny")
        let result=try V3PreviewMaterializer.materialize(graph,context:c,maxPixel:96,managedOutput:output)
        XCTAssertEqual(result.nativeSize,size)
        XCTAssertEqual(result.outputSize,extent.size)
        let observed=try bytes(result.image)
        if normalized { XCTAssertEqual(observed,reference,"Legal alpha, edges and HDR must retain the original FIT bytes") }
        else {
          reference=observed
          XCTAssertEqual(reference.count,96*72*4)
          let alpha=stride(from:3,to:reference.count,by:4).map{reference[$0]}
          XCTAssertTrue(alpha.contains(0))
          XCTAssertTrue(alpha.contains{$0>0 && $0<255})
          XCTAssertTrue(alpha.contains(255))
        }
      }
      XCTAssertEqual(ledger.statistics.chargedCPUBytes+ledger.statistics.chargedGPUBytes,0)
    }
    scope.closeAndRetire()
    XCTAssertEqual(ledger.statistics.retiredCPUBytes+ledger.statistics.retiredGPUBytes,0)
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
  }

}
