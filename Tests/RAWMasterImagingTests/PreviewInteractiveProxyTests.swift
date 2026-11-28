import XCTest
import AppKit
import CoreImage
import CryptoKit
import ImageIO
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

private actor PreviewJoinGate {
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

final class PreviewInteractiveProxyTests:XCTestCase {
  private func fixture(orientation:Int=1)throws->(URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-I1-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file=root.appendingPathComponent("source.tiff")
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:28,pixelsHigh:18,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:112,bitsPerPixel:32))
    for y in 0..<18{for x in 0..<28{let i=y*112+x*4;bitmap.bitmapData![i]=UInt8(x*7+12);bitmap.bitmapData![i+1]=UInt8(y*11+9);bitmap.bitmapData![i+2]=UInt8((x*3+y*5)%170+20);bitmap.bitmapData![i+3]=255}}
    let writer=try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(writer,try XCTUnwrap(bitmap.cgImage),[kCGImagePropertyOrientation:orientation]as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(writer))
    let bytes=try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber
    let source=EditingSourceSnapshot(projectID:"I1",assetID:"asymmetric",contentSHA256:try RenderFiles.hash(file),byteCount:try XCTUnwrap(bytes).int64Value,admissionFingerprint:"owned-tiny",sourceLocation:file)
    return(root,source)
  }
  private func neutral()->DevelopmentRecipe{DevelopmentRecipe(adjustmentsV3:.init())}
  private func request(_ lease:PreviewSessionInfo,_ consumer:PreviewConsumerID,_ recipe:DevelopmentRecipe,_ revision:UInt64,quality:PreviewQuality = .interactive,role:PreviewConsumerRole = .primary)->DevelopmentPreviewRequest {
    .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:role,revision:revision,recipe:recipe,quality:quality,viewport:.init(maxPixel:quality == .detail ? 0:2400))
  }
  private func bytes(_ image:NSImage)throws->[UInt8] {
    guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),let context=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)else{throw DevelopmentError.unreadable}
    context.setBlendMode(.copy);context.interpolationQuality = .none;context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return Array(UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self),count:cg.width*cg.height*4))
  }
  func testPolicyDefaultOffAndSupportNeverDropsUnsupportedWholeRecipe()throws {
    XCTAssertEqual(PreviewResourcePolicy.default.interactiveEvaluation,.canonical)
    let n=neutral();XCTAssertEqual(try PreviewInteractiveProxyV3.support(n,sourceIsRAW:false),.eligible)
    var p=n.adjustmentsV3!
    p.definition = .init(enabled:true,amount:0.5)
    XCTAssertEqual(try PreviewInteractiveProxyV3.support(.init(adjustmentsV3:p),sourceIsRAW:false),.canonical(.definition))
    p=n.adjustmentsV3!;p.filter = .init(enabled:true,selection:.vivid,intensity:37)
    XCTAssertEqual(try PreviewInteractiveProxyV3.support(.init(adjustmentsV3:p),sourceIsRAW:false),.eligible)
    p=n.adjustmentsV3!;p.geometry.version = .projectiveV3_1;p.geometry.verticalPerspective=5
    XCTAssertEqual(try PreviewInteractiveProxyV3.support(.init(adjustmentsV3:p),sourceIsRAW:false),.canonical(.projective))
    p=n.adjustmentsV3!;p.blackAndWhite = .init(enabled:true,grain:0.1)
    XCTAssertEqual(try PreviewInteractiveProxyV3.support(.init(adjustmentsV3:p),sourceIsRAW:false),.canonical(.grain))
    p=n.adjustmentsV3!;p.color.saturation = .nan
    XCTAssertThrowsError(try PreviewInteractiveProxyV3.support(.init(adjustmentsV3:p),sourceIsRAW:false))
  }
  func testUniformScaleAndNativeGeometryConjugationPreserveLandmarkPhase()throws {
    let size=CGSize(width:9504,height:6336),s=try PreviewInteractiveProxyV3.scale(size)
    let input=try PreviewInteractiveProxyV3.inputLayout(size)
    XCTAssertEqual(s,2400.0/9504);XCTAssertEqual(input.width,2400);XCTAssertEqual(input.height,1600)
    for q in 0..<4{for reflect in [false,true]{
      var g=DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:7,crop:.init(x:0.12,y:0.08,width:0.7,height:0.8))
      g.clockwiseQuarterTurns=q;g.flipHorizontal=reflect
      g=try g.applyingLateOperation(.rotateClockwise)
      let sampled=try PreviewInteractiveProxyV3.geometry(g,nativeSize:size,inputScale:s,maxPixel:2400)
      var observed=0
      for source in [DevelopmentSourcePoint(x:0.35,y:0.35),.init(x:0.5,y:0.5),.init(x:0.6,y:0.55)] {
        guard let out=try sampled.mapping.outputPoint(fromSource:source)else{continue}
        observed+=1
        let inputCI=CGPoint(x:source.x*size.width*s,y:(1-source.y)*size.height*s)
        let actual=inputCI.applying(sampled.transform)
        let expected=CGPoint(x:out.x*Double(sampled.mapping.outputSize.width)*sampled.outputScale,y:(1-out.y)*Double(sampled.mapping.outputSize.height)*sampled.outputScale)
        XCTAssertEqual(actual.x,expected.x,accuracy:1e-9);XCTAssertEqual(actual.y,expected.y,accuracy:1e-9)
      }
      XCTAssertGreaterThan(observed,0)
      XCTAssertLessThanOrEqual(max(sampled.layout.width,sampled.layout.height),2400)
      XCTAssertLessThanOrEqual(sampled.outputScale,s)
    }}
    let radius=max(1,Double(3)*DevelopmentSpatialEngineV3.radiusFraction)*0.25
    XCTAssertEqual(radius,0.25) // A proxy below native minimum must not clamp back to1.
  }
  func testAtomicKnownPeakReservationRejectsBeforeAnyPartialAllocation()throws {
    let ledger=PreviewPresentationLedger(cpuBudget:100,gpuBudget:90),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    XCTAssertThrowsError(try scope.reserveSharedOperation(bytes:[50,41]))
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
    let tickets=try scope.reserveSharedOperation(bytes:[50,40]);XCTAssertEqual(ledger.statistics.chargedCPUBytes,90)
    scope.closeAndRetire();XCTAssertEqual(ledger.statistics.retiredCPUBytes,90)
    for ticket in tickets{ticket.releaseAfterStorageReleased()}
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
  func testActualFloatStoragePaddingRowsHDRAlphaAndHiddenNonfiniteGate()throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    let ctx=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    defer{ctx.clearCaches();scope.closeAndRetire()}
    try autoreleasepool {
      let width=7,height=5,layout=try PreviewInteractiveLayout.make(width:width,height:height,float:true)
      XCTAssertGreaterThanOrEqual(layout.rowBytes,width*16);XCTAssertGreaterThanOrEqual(layout.bytes,layout.rowBytes*height)
      var samples=[SIMD4<Float>]()
      for y in 0..<height{for x in 0..<width{samples.append(.init(Float(x)*0.1-0.2,Float(y)*0.2,2.0,1))}}
      samples[3] = .init(0.1,0.2,0.3,0.5);samples[7] = .init(0,0,0,0)
      let image=CIImage(bitmapData:samples.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      let ticket=try scope.reserveSharedOperation(bytes:[layout.bytes])[0]
      let storage=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:device)
      try storage.fill(image,context:ctx,check:{});try storage.validateAllRGBA()
      try storage.withPixels{p,row in for y in 0..<height{for x in 0..<width{
        let actual=p.loadUnaligned(fromByteOffset:y*row+x*16,as:SIMD4<Float>.self)
        for c in 0..<4{XCTAssertEqual(actual[c],samples[y*width+x][c],accuracy:2e-6)}
      }}}
      ctx.clearCaches()
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
    // Actual joined input, not a fake writer/no-write seam. The transparent NaN must fail.
    try autoreleasepool {
      let layout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
      let ticket=try scope.reserveSharedOperation(bytes:[layout.bytes])[0]
      let storage=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:device)
      let values:[SIMD4<Float>]=[.init(.nan,0,0,0)]
      let image=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:16,size:.init(width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      XCTAssertThrowsError(try storage.fill(image,context:ctx,check:{}))
      XCTAssertThrowsError(try storage.withPixels{_,_ in ()}) // A rejected joined write is never readable as a prior valid result.
      ctx.clearCaches()
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
  func testCheckedMaximumPoisonRejectsNoWritePartialAndMalformedRGBA()throws {
    var pixel=SIMD4<Float>(0,0,0,1)
    try withUnsafeMutableBytes(of:&pixel){bytes in
      let address=try XCTUnwrap(bytes.baseAddress)
      XCTAssertEqual(try PreviewInteractiveProxyStorage.readCheckedPixel(UnsafeRawPointer(address)),SIMD4<Float>(0,0,0,1))
      PreviewInteractiveProxyStorage.poisonCheckedPixel(address)
      XCTAssertThrowsError(try PreviewInteractiveProxyStorage.readCheckedPixel(UnsafeRawPointer(address))) // No write after prior successful zero.
      address.storeBytes(of:Float(0),as:Float.self)
      XCTAssertThrowsError(try PreviewInteractiveProxyStorage.readCheckedPixel(UnsafeRawPointer(address))) // Red-only write must not pass.
      for component in 0..<4{for malformed in [Float.nan,Float.infinity,-Float.infinity]{
        var value=SIMD4<Float>(0,0,0,1);value[component]=malformed
        address.storeBytes(of:value,as:SIMD4<Float>.self)
        XCTAssertThrowsError(try PreviewInteractiveProxyStorage.readCheckedPixel(UnsafeRawPointer(address)))
      }}
      let clear=SIMD4<Float>(repeating:0)
      address.storeBytes(of:clear,as:SIMD4<Float>.self)
      XCTAssertEqual(try PreviewInteractiveProxyStorage.readCheckedPixel(UnsafeRawPointer(address)),clear) // Genuine fully-written transparent zero is valid.
      PreviewInteractiveProxyStorage.poisonCheckedPixel(address)
      // Scalar stores model exactly three channels, leaving the alpha poison.
      for component in 0..<3{address.storeBytes(of:Float(0),toByteOffset:component*4,as:Float.self)}
      XCTAssertThrowsError(try PreviewInteractiveProxyStorage.readCheckedPixel(UnsafeRawPointer(address)))
    }
  }
  func testActualMaximumScratchReusedTaskChecksCompleteRGBA()throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    defer{context.clearCaches();scope.closeAndRetire()}
    try autoreleasepool{
      let layout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
      let ticket=try scope.reserveSharedOperation(bytes:[layout.bytes])[0]
      let scratch=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:device)
      for invalid in [false,true,false]{
        let source=CIImage(color:CIColor(red:0.2,green:0.3,blue:0.4,alpha:1)).cropped(to:CGRect(x:0,y:0,width:3,height:2))
        let input=invalid ? CIImage(color:CIColor(red:1,green:0,blue:0,alpha:1)).cropped(to:source.extent):source
        let mask:CIImage
        if invalid{mask=input}
        else{
          let kernel=try DevelopmentLocalEngineV3.kernel("rmLocalInvalid")
          mask=try XCTUnwrap(kernel.apply(extent:input.extent,roiCallback:{_,r in r},arguments:[input.samplingNearest()]))
        }
        let maximum=mask.applyingFilter("CIAreaMaximum",parameters:[kCIInputExtentKey:CIVector(cgRect:mask.extent)]).cropped(to:CGRect(x:0,y:0,width:1,height:1))
        try scratch.fill(maximum,context:context,check:{})
        try scratch.withPixels{address,_ in
          let value=try PreviewInteractiveProxyStorage.readCheckedPixel(address)
          XCTAssertEqual(value.x,invalid ? 1:0);XCTAssertEqual(value.w,invalid ? 1:0)
        }
      }
      context.clearCaches()
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
  }
  func testParallelInvalidReductionChecksEveryEdgeTileAndPreservesValidHDRAlpha()throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    defer{context.clearCaches();scope.closeAndRetire()}
    let width=130,height=70,layout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
    let ticket=try scope.reserveSharedOperation(bytes:[layout.bytes])[0]
    let scratch=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:device)
    func image(_ pixels:[SIMD4<Float>])->CIImage {
      .init(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    }
    var valid=(0..<(width*height)).map{i->SIMD4<Float> in
      let a:Float=i%17==0 ? 0:(i%19==0 ? 0.5:1)
      return .init((i%11==0 ? 3.5:0.2)*a,(i%13==0 ? -0.5:0.3)*a,0.4*a,a)
    }
    XCTAssertNoThrow(try PreviewInteractiveProxyV3.validate(image(valid),using:scratch,context:context,check:{}))
    for (point,bad) in [(0,SIMD4<Float>(.nan,0,0,0)),(31*width+31,.init(0,.infinity,0,1)),
                        (32*width+32,.init(0,0,0,1.01)),(63*width+63,.init(0,0,0,-0.01)),
                        (64*width+64,.init(0,0,0,.nan)),(69*width+129,.init(.nan,0,0,1))] {
      valid[point] = bad
      XCTAssertThrowsError(try PreviewInteractiveProxyV3.validate(image(valid),using:scratch,context:context,check:{})) {
        XCTAssertEqual($0 as? DevelopmentError,.invalidEncoding)
      }
      valid[point] = .init(0.2,0.3,0.4,1)
    }
    XCTAssertNoThrow(try PreviewInteractiveProxyV3.validate(image(valid),using:scratch,context:context,check:{}))
  }
  func testActualImageProxyWarmHitNativeDescriptorAndSettledCanonicalSeparation()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:1024*1024,interactiveEvaluation:.proxyV1))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID(),n=neutral()
      let first=try await service.render(request(lease,consumer,n,1))
      XCTAssertTrue(first.approximate);XCTAssertEqual(first.approximation?.version,PreviewInteractiveProxyV3.version)
      XCTAssertEqual(first.approximation?.nativeInputSize,CGSize(width:28,height:18))
      XCTAssertEqual(first.canonicalPixelSize,CGSize(width:28,height:18))
      var changed=n;changed.adjustmentsV3!.color = .init(enabled:true,saturation:0.1)
      let next=try await service.render(request(lease,consumer,changed,2))
      XCTAssertTrue(next.approximate);XCTAssertNotEqual(first.outputKey,next.outputKey)
      let reused=await service.interactiveProxyStatisticsForTesting();XCTAssertEqual(reused.fills,1);XCTAssertEqual(reused.hits,1)
      let settled=try await service.render(request(lease,consumer,n,3,quality:.settled))
      XCTAssertFalse(settled.approximate);XCTAssertNil(settled.approximation);XCTAssertNotEqual(first.outputKey,settled.outputKey)
      let actual=try bytes(first.image),expected=try bytes(settled.image)
      XCTAssertEqual(actual.count,expected.count)
      for i in actual.indices{XCTAssertLessThanOrEqual(abs(Int(actual[i])-Int(expected[i])),2)}
      let stats=await service.statistics();XCTAssertEqual(stats.maximumObservedNativeRenders,1)
    }catch{await service.closeAll();throw error}
    await service.closeAll()
    let closed=await service.interactiveProxyStatisticsForTesting();XCTAssertEqual(closed.residentBytes,0);XCTAssertEqual(closed.pinnedBytes,0)
  }
  func testRevisitingSettledRecipeDeliversExactManagedPixels() async throws {
    let (root,source) = try fixture()
    defer { try? FileManager.default.removeItem(at:root) }
    let service = DevelopmentPreviewService(policy:.init(bitmapCacheBytes:1024*1024,interactiveEvaluation:.proxyV1))
    let session = try await service.open(source:.raw(source)), consumer = PreviewConsumerID()
    let a = neutral()
    var b = a
    b.adjustmentsV3!.color = .init(enabled:true,saturation:0.2)
    let exact = try await service.render(request(session,consumer,a,1,quality:.settled))
    let fresh = try await service.render(request(session,consumer,b,2))
    XCTAssertTrue(fresh.approximate)
    let replay = try await service.render(request(session,consumer,a,3))
    XCTAssertFalse(replay.approximate)
    XCTAssertEqual(replay.outputKey,exact.outputKey)
    XCTAssertEqual(replay.quality,.interactive)
    XCTAssertEqual(try bytes(replay.image), try bytes(exact.image))
    XCTAssertNotEqual(try bytes(replay.image), try bytes(fresh.image))
    await service.closeAll()
    XCTAssertEqual(try bytes(replay.image), try bytes(exact.image))
  }

  func testSettledLocalGrainReplayRequiresACompletedSameState() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RAWMASTER_QA_SETTLED_LOCAL_GRAIN_REPLAY"] != "0", let path = env["RAWMASTER_PANEL_READBACK_RAW"] else {
      throw XCTSkip("Requires local grain replay and the paired photo operators RAW")
    }
    let url = URL(fileURLWithPath: path)
    let sha = try RenderFiles.hash(url)
    guard sha == "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c" else {
      return XCTFail("Expected the fixed paired photo operators RAW")
    }
    let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let source = EditingSourceSnapshot(projectID: "local-grain-replay", assetID: "sony", contentSHA256: sha,
      byteCount: Int64(size), admissionFingerprint: "canonical-grain", sourceLocation: url)
    let joined = expectation(description: "The real settled frame joined before delivery")
    let gate = PreviewJoinGate()
    let service = DevelopmentPreviewService(policy: .init(interactiveEvaluation: .proxyV1, settledTransport: .canonical),
      nativePreviewDidJoinForTesting: { request in
        guard request.quality == .settled, request.revision == 2 else { return }
        joined.fulfill()
        await gate.wait()
      })
    let consumer = PreviewConsumerID()
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 2400 * 1600 * 4, alignment: 64)
    defer { buffer.deallocate() }
    func digest(_ frame: DevelopmentPreviewFrame) throws -> SHA256.Digest {
      try frame.copyDisplayRGBA8(into: buffer)
      return SHA256.hash(data: Data(bytesNoCopy: buffer.baseAddress!, count: buffer.count, deallocator: .none))
    }
    do {
      let lease = try await service.open(source: .raw(source))
      var parameters = DevelopmentAdjustmentsV3()
      parameters.rawDecoder = .flashRaw031
      parameters.masks = [.init(kind: .radial, radiusX: 0.35, radiusY: 0.30, feather: 0,
        adjustments: .init(grain: 0.15, grainSize: 0.25, grainRoughness: 0.5))]
      let a = DevelopmentRecipe(adjustmentsV3: parameters)
      parameters.masks[0].adjustments.grain = 0.55
      let b = DevelopmentRecipe(adjustmentsV3: parameters)

      let firstDigest: SHA256.Digest
      do {
        let first = try await service.render(request(lease, consumer, a, 1))
        XCTAssertTrue(first.approximate)
        firstDigest = try digest(first)
      }
      let newStateKey: String
      do {
        let interrupted = Task { try await service.render(request(lease, consumer, a, 2, quality: .settled)) }
        await fulfillment(of: [joined], timeout: 10)
        let replacement = Task { try await service.render(request(lease, consumer, b, 3)) }
        do {
          _ = try await interrupted.value
          XCTFail("The superseded request delivered its joined frame")
        } catch DevelopmentPreviewError.superseded {}
        await gate.release()
        let newState = try await replacement.value
        XCTAssertTrue(newState.approximate)
        newStateKey = newState.outputKey
      }
      do {
        let afterSupersession = try await service.render(request(lease, consumer, a, 4))
        XCTAssertTrue(afterSupersession.approximate)
        XCTAssertEqual(try digest(afterSupersession), firstDigest)
      }
      let settledKey: String
      let settledDigest: SHA256.Digest
      do {
        let settled = try await service.render(request(lease, consumer, a, 5, quality: .settled))
        XCTAssertFalse(settled.approximate)
        settledKey = settled.outputKey
        settledDigest = try digest(settled)
        XCTAssertNotEqual(firstDigest, settledDigest)
        XCTAssertNotEqual(newStateKey, settledKey)
        let replay = try await service.render(request(lease, consumer, a, 6))
        XCTAssertFalse(replay.approximate)
        XCTAssertEqual(replay.quality, .interactive)
        XCTAssertEqual(replay.outputKey, settledKey)
        XCTAssertEqual(replay.outputPixelSize, settled.outputPixelSize)
        XCTAssertEqual(try digest(replay), settledDigest)
      }

      let otherLease = try await service.open(source: .raw(source))
      do {
        let otherFirst = try await service.render(request(otherLease, PreviewConsumerID(), a, 1))
        XCTAssertTrue(otherFirst.approximate)
      }
      await service.close(otherLease.id)

      let revalidated = try await service.revalidate(lease.id, source: .raw(source))
      XCTAssertEqual(revalidated.id, lease.id)
      XCTAssertNotEqual(revalidated.sourceGeneration, lease.sourceGeneration)
      do {
        let renewedFirst = try await service.render(request(revalidated, consumer, a, 7))
        XCTAssertTrue(renewedFirst.approximate)
      }
      do {
        let renewedSettled = try await service.render(request(revalidated, consumer, a, 8, quality: .settled))
        XCTAssertEqual(renewedSettled.outputKey, settledKey)
        XCTAssertEqual(try digest(renewedSettled), settledDigest)
        let renewedReplay = try await service.render(request(revalidated, consumer, a, 9))
        XCTAssertFalse(renewedReplay.approximate)
        XCTAssertEqual(try digest(renewedReplay), settledDigest)
      }

      await service.handleMemoryPressure()
      let afterEviction = try await service.render(request(revalidated, consumer, a, 10))
      XCTAssertTrue(afterEviction.approximate)
      XCTAssertEqual(try digest(afterEviction), firstDigest)

      await service.invalidate(revalidated.id)
      do {
        _ = try await service.render(request(revalidated, consumer, a, 11))
        XCTFail("An invalidated source supplied a preview")
      } catch DevelopmentPreviewError.sourceInvalidated {}
    } catch {
      await gate.release()
      await service.closeAll()
      throw error
    }
    await service.closeAll()
  }

  func testCanonicalLocalGrainTilesRequireAnOpaquePrimarySource() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["RAWMASTER_PANEL_READBACK_RAW"],
          let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
          ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024 else {
      throw XCTSkip("Requires the paired photo operators RAW and a supported Metal device")
    }
    let url = URL(fileURLWithPath: path)
    let sha = try RenderFiles.hash(url)
    XCTAssertEqual(sha, "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c")
    let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let source = EditingSourceSnapshot(projectID: "local-grain-finite", assetID: "sony", contentSHA256: sha,
      byteCount: Int64(size), admissionFingerprint: "local-grain-finite", sourceLocation: url)
    var parameters = DevelopmentAdjustmentsV3()
    parameters.rawDecoder = .flashRaw031
    parameters.masks = [.init(kind: .radial, radiusX: 0.35, radiusY: 0.30, feather: 0,
      adjustments: .init(grain: 0.55, grainSize: 0.25, grainRoughness: 0.5))]
    let recipe = DevelopmentRecipe(adjustmentsV3: parameters)
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 2400 * 1600 * 4, alignment: 64)
    defer { buffer.deallocate() }
    var digests = [SHA256.Digest]()
    for role in [PreviewConsumerRole.primary, .comparison] {
      let service = DevelopmentPreviewService(policy: .init(interactiveEvaluation: .proxyV1, settledTransport: .canonical))
      do {
        let lease = try await service.open(source: .raw(source))
        let start = DispatchTime.now().uptimeNanoseconds
        let frame = try await service.render(request(lease, PreviewConsumerID(), recipe, 1, quality: .settled, role: role))
        XCTAssertFalse(frame.approximate)
        try frame.copyDisplayRGBA8(into: buffer)
        digests.append(SHA256.hash(data: Data(bytesNoCopy: buffer.baseAddress!, count: buffer.count, deallocator: .none)))
        let scans = ImagePerformanceTelemetry.shared.snapshot().recent.filter {
          $0.startedAtNanoseconds >= start && $0.operation == "显影有限值检查" &&
            $0.boundary == .gpuCompletion && $0.outcome == .succeeded
        }
        let expectedRegion = role == .primary && FlashRawNativeFiniteCheck.enabled &&
          PreviewPortableHalfFIT.supports(lease.orientedNativeSize, device: device) &&
          environment["RAWMASTER_QA_CANONICAL_GRAIN_MASK_TILES"] != "0" &&
          environment["RAWMASTER_CANONICAL_SPATIAL_MASK_TILES"] != "0"
        if expectedRegion {
          XCTAssertEqual(scans.filter { $0.stage == "原生局部归约" }.map(\.pixelCount), [29_360_128])
        } else {
          XCTAssertFalse(scans.contains { $0.stage == "原生局部归约" })
          XCTAssertTrue(scans.contains { $0.stage == "全域归约" && $0.pixelCount == 60_217_344 })
        }
      } catch {
        await service.closeAll()
        throw error
      }
      await service.closeAll()
    }
    XCTAssertEqual(digests[0], digests[1])
  }

  func testActualEXIFCropStraightenAndLateD4StayRegisteredAgainstCanonical()async throws {
    for orientation in [1,6,8] {
      let(root,source)=try fixture(orientation:orientation);defer{try? FileManager.default.removeItem(at:root)}
      let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:1024*1024,interactiveEvaluation:.proxyV1))
      do {
        let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
        var r=neutral(),g=DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:7,crop:.init(x:0.1,y:0.1,width:0.8,height:0.8))
        g.flipHorizontal=true;g=try g.applyingLateOperation(.rotateClockwise);r.adjustmentsV3!.geometry=g
        let candidate=try await service.render(request(lease,consumer,r,1))
        let reference=try await service.render(request(lease,consumer,r,2,quality:.settled))
        XCTAssertTrue(candidate.approximate);XCTAssertEqual(candidate.canonicalPixelSize,reference.canonicalPixelSize)
        XCTAssertEqual(candidate.outputPixelSize,reference.outputPixelSize)
        let a=try bytes(candidate.image),b=try bytes(reference.image)
        XCTAssertEqual(a.count,b.count)
        for i in a.indices{XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),2)}
      }catch{await service.closeAll();throw error}
      await service.closeAll()
    }
  }
  func testWholeRecipeFilterProxyIsChargedApproximateAndSeparatedFromSettledCanonical()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:1024*1024,interactiveEvaluation:.proxyV1))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      var r=neutral();r.adjustmentsV3!.filter = .init(enabled:true,selection:.vivid,intensity:37)
      let frame=try await service.render(request(lease,consumer,r,1))
      XCTAssertTrue(frame.approximate);XCTAssertNotNil(frame.approximation)
      let independent=try await DevelopmentService().preview(source:source,recipe:r,maxPixel:2400)
      let actual=try bytes(frame.image),expected=try bytes(independent.image)
      XCTAssertEqual(actual.count,expected.count)
      for i in actual.indices{XCTAssertLessThanOrEqual(abs(Int(actual[i])-Int(expected[i])),2)}
      let settled=try await service.render(request(lease,consumer,r,2,quality:.settled))
      XCTAssertFalse(settled.approximate);XCTAssertNotEqual(frame.outputKey,settled.outputKey)
      let settledBytes=try bytes(settled.image);XCTAssertEqual(actual.count,settledBytes.count)
      for i in actual.indices{XCTAssertLessThanOrEqual(abs(Int(actual[i])-Int(settledBytes[i])),2)}
      let stats=await service.statistics();XCTAssertEqual(stats.interactiveProxyCanonicalFallbacks,0)
      let pool=await service.interactiveProxyStatisticsForTesting();XCTAssertEqual(pool.fills,1);XCTAssertGreaterThan(pool.owned.chargedCPUBytes,0)
    }catch{await service.closeAll();throw error}
    await service.closeAll()
  }
  func testFilterAndTextureUseInteractiveProxyAndMatchSettledWithinDisplayTolerance()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:1024*1024,interactiveEvaluation:.proxyV1))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      var r=neutral();r.adjustmentsV3!.filter = .init(enabled:true,selection:.vivid,intensity:37)
      r.adjustmentsV3!.advancedDetail.texture = .init(enabled:true,amount:25)
      let frame=try await service.render(request(lease,consumer,r,1))
      XCTAssertTrue(frame.approximate)
      let settled=try await service.render(request(lease,consumer,r,2,quality:.settled))
      let a=try bytes(frame.image),b=try bytes(settled.image);XCTAssertEqual(a.count,b.count)
      for i in a.indices{XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),3)}
      let stats=await service.statistics();XCTAssertEqual(stats.interactiveProxyCanonicalFallbacks,0)
    }catch{await service.closeAll();throw error}
    await service.closeAll()
  }
  func testProviderRemainsChargedAcrossScopeCloseUntilActualImageRelease()throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    let ctx=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    var held:NSImage?
    try autoreleasepool {
      let layout=try PreviewInteractiveLayout.make(width:17,height:11,float:false)
      let ticket=try scope.reserveSharedOperation(bytes:[layout.bytes])[0]
      let output=PreviewInteractiveManagedOutput(layout:layout,ticket:ticket,device:device)
      let image=CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6,alpha:1)).cropped(to:CGRect(x:0,y:0,width:17,height:11))
      held=try output.materialize(image,context:ctx,nativeSize:.init(width:17,height:11),check:{}).image
      ctx.clearCaches()
    }
    scope.closeAndRetire();XCTAssertGreaterThan(ledger.statistics.retiredCPUBytes,0)
    XCTAssertGreaterThan(ledger.statistics.chargedGPUBytes,0)
    try autoreleasepool{XCTAssertFalse(try bytes(try XCTUnwrap(held)).isEmpty)}
    autoreleasepool{held=nil;ctx.clearCaches()}
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
  }
  func testNativeDescriptorUsesOrientedFactsAndIgnoresOnlyImageSuffixValues()throws {
    for orientation in [1,6,8] {
      let(root,source)=try fixture(orientation:orientation);defer{try? FileManager.default.removeItem(at:root)}
      let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
      let a=try native.interactivePlan(recipe:neutral(),sourceKey:"source",generation:1,verifiedContentID:source.contentSHA256,maxPixel:2400)
      var changed=neutral();changed.adjustmentsV3!.color = .init(enabled:true,saturation:0.4)
      changed.adjustmentsV3!.light = .init(enabled:true,exposure:0.5,brightness:0.2)
      let b=try native.interactivePlan(recipe:changed,sourceKey:"source",generation:1,verifiedContentID:source.contentSHA256,maxPixel:2400)
      XCTAssertEqual(try a.descriptor?.fingerprint(),try b.descriptor?.fingerprint())
      XCTAssertEqual(a.descriptor?.orientation,orientation)
      let expected=orientation==1 ? CGSize(width:28,height:18):CGSize(width:18,height:28)
      XCTAssertEqual(a.descriptor?.nativeSize,expected)
      let newEpoch=try native.interactivePlan(recipe:neutral(),sourceKey:"source",generation:2,verifiedContentID:source.contentSHA256,maxPixel:2400)
      XCTAssertNotEqual(try a.descriptor?.fingerprint(),try newEpoch.descriptor?.fingerprint())
    }
  }
  func testBuildRetirementFenceCannotPublishIntoInvalidatedSource()throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let plan=try native.interactivePlan(recipe:neutral(),sourceKey:"source",generation:1,verifiedContentID:source.contentSHA256,maxPixel:2400)
    let descriptor=try XCTUnwrap(plan.descriptor),pool=PreviewInteractiveProxyPool()
    let build=try pool.beginBuild(descriptor);defer{pool.endBuild(build)}
    pool.retire(sourceKey:"source")
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    try autoreleasepool {
      let layout=try PreviewInteractiveLayout.make(width:descriptor.proxyWidth,height:descriptor.proxyHeight,float:true)
      let ticket=try scope.reserveSharedOperation(bytes:[layout.bytes])[0]
      let storage=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
      XCTAssertThrowsError(try pool.attachBuildingStorage(storage,id:build))
      XCTAssertThrowsError(try pool.publish(descriptor,storage,buildID:build))
      XCTAssertEqual(pool.statistics(ledger:ledger).fills,0)
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
  func testCancelledBeforeFillCreatesNoProxyAndNoSecondWorker()throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let plan=try native.interactivePlan(recipe:neutral(),sourceKey:"source",generation:1,verifiedContentID:source.contentSHA256,maxPixel:2400)
    let pool=PreviewInteractiveProxyPool(),ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    let cancellation=DevelopmentAnalysisCancellation();cancellation.cancel()
    XCTAssertThrowsError(try native.renderInteractiveProxy(recipe:neutral(),maxPixel:2400,plan:plan,pool:pool,programs:PreviewPortableMetalPrograms(),scope:scope,rawBasePool:nil,memoryLimit:512,cancellation:cancellation))
    XCTAssertEqual(pool.statistics(ledger:ledger).fills,0);XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
  func testInteractiveDehazeRequiresCurrentPreparationBeforeProxyRendering()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,interactiveEvaluation:.proxyV1))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      let context=try DevelopmentDehazeContextFactoryV1.fromCapture(source.sourceLocation,generation:lease.sourceGeneration)
      let projection=try neutral().prospectiveDehazeInputV1(context:context)
      var p=DevelopmentAdjustmentsV3();p.advancedDetail.dehaze = .init(enabled:true,amount:25)
      p.advancedDetail.preparedDehaze = .init(sourceBinding:context.source,inputFingerprint:projection.input.inputFingerprint,
        airlight:.init(red:0.5,green:0.75,blue:1))
      let recipe=DevelopmentRecipe(adjustmentsV3:p)
      let frame=try await service.render(request(lease,consumer,recipe,1))
      XCTAssertTrue(frame.approximate)
      var stale=recipe;let old=try XCTUnwrap(p.advancedDetail.preparedDehaze)
      stale.adjustmentsV3!.advancedDetail.preparedDehaze = .init(sourceBinding:old.sourceBinding,
        inputFingerprint:String(repeating:"e",count:64),airlight:old.airlight)
      do {
        _=try await service.render(request(lease,consumer,stale,2));XCTFail("Stale preparation must not render")
      }catch{ XCTAssertEqual(error as? DevelopmentDehazePreparationError,.preparationRequired) }
      await service.closeAll()
    }catch{await service.closeAll();throw error}
  }
  func testPreparedDehazeUsesActualProxyScaleForBothAlgorithms()throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let context=DevelopmentColorEngineV3.makeContext();defer{context.clearCaches()}
    let dehazeContext=try DevelopmentDehazeContextFactoryV1.fromCapture(source.sourceLocation)
    let input=try XCTUnwrap(CIImage(contentsOf:source.sourceLocation,options:[.applyOrientationProperty:true]))
    for algorithm in [DevelopmentDehazeAlgorithm.v1,.positiveColorGuideV2] {
      let projection=try neutral().prospectiveDehazeInputV1(context:dehazeContext,algorithm:algorithm)
      var p=DevelopmentAdjustmentsV3();p.advancedDetail.dehaze = .init(enabled:true,amount:25)
      p.advancedDetail.preparedDehaze = .init(sourceBinding:dehazeContext.source,inputFingerprint:projection.input.inputFingerprint,
        airlight:.init(red:0.5,green:0.75,blue:1),algorithmVersion:algorithm.rawValue)
      let recipe=DevelopmentRecipe(adjustmentsV3:p)
      XCTAssertEqual(try PreviewInteractiveProxyV3.support(recipe,sourceIsRAW:false),.canonical(.advanced))
      XCTAssertEqual(try PreviewInteractiveProxyV3.support(recipe,sourceIsRAW:false,allowAdvancedDetail:true),.eligible)
      let output=try PreviewInteractiveProxyV3.suffix(p,source:input,sourceIsRAW:false,nativeSize:CGSize(width:28,height:18),scale:1,context:context,check:{})
      XCTAssertEqual(output.extent,input.extent)
      try DevelopmentLocalEngineV3.validatePixels(output,context:context)
    }
  }
}
