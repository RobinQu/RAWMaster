import AppKit
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentDehazeTIFFPreviewV1Tests:XCTestCase {
  private func fixture(alpha:UInt16=65535,width:Int=320,height:Int=192)throws->(URL,EditingSourceSnapshot){
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("dehaze-public-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let url=root.appendingPathComponent("source.tiff")
    var values=[UInt16](repeating:alpha,count:width*height*4)
    for y in 0..<height{for x in 0..<width{let i=(y*width+x)*4
      for c in 0..<3{let v=12000+(x*(17+c*6)+y*(11+c*8))%40000;values[i+c]=UInt16(UInt64(v)*UInt64(alpha)/65535)}
    }}
    let data=values.withUnsafeBytes{Data($0)},provider=try XCTUnwrap(CGDataProvider(data:data as CFData))
    let image=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:width*8,
      space:PhotoRenderer.sRGB,bitmapInfo:.byteOrder16Little.union(.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let dest=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:1] as CFDictionary);XCTAssertTrue(CGImageDestinationFinalize(dest))
    let bytes=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)
    return(root,.init(projectID:"dehaze-public",assetID:"source",contentSHA256:try RenderFiles.hash(url),byteCount:bytes.int64Value,
      admissionFingerprint:"real-opaque-tiff",sourceLocation:url))
  }
  private func prepared(_ service:DevelopmentPreviewService,_ lease:PreviewSessionInfo,_ consumer:PreviewConsumerID)async throws->DevelopmentRecipe{
    let facts=try await service.sourceFacts(sessionID:lease.id,sourceGeneration:lease.sourceGeneration)
    let context=try XCTUnwrap(facts.dehazeContextV1),original=DevelopmentRecipe(adjustmentsV3:.init())
    let p=try original.prospectiveDehazeInputV1(context:context,algorithm:.positiveColorGuideV2)
    let preview=DevelopmentPreviewRequest(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,
      role:.primary,revision:1,recipe:p.analysisRecipe,quality:.settled)
    let request=DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry,
      operation:.prepareDehaze,presentedRecipeFingerprint:p.presentedRecipeFingerprint,dehazeInputV1:p.input)
    let result=try await service.analyze(request);await service.cancelAnalysisAndJoin(request)
    guard case .dehaze(let resolved)=result.value else{throw DevelopmentPreviewError.invalidRequest}
    return try original.applying(.applyPreparedDehaze(resolved,wantedAmount:25),context:.init(source:context.source,
      sourceGeneration:context.sourceGeneration,analysisStage:.workingImageBeforeGeometry,dehazeContextV1:context))
  }
  private func request(_ lease:PreviewSessionInfo,_ consumer:PreviewConsumerID,_ recipe:DevelopmentRecipe,_ revision:UInt64,_ quality:PreviewQuality = .settled)->DevelopmentPreviewRequest{
    .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:quality,
      viewport:.init(maxPixel:quality == .detail ? 0:2400))
  }
  private struct Packed{let data:Data,contract:String?,fallback:String?,plane:String?,quality:PreviewQuality,key:String}
  private func packed(_ service:DevelopmentPreviewService,_ r:DevelopmentPreviewRequest)async throws->Packed{
    let f=try await service.render(r)
    let data=try autoreleasepool{try PreviewWindows.compact(XCTUnwrap(f.image.cgImage(forProposedRect:nil,context:nil,hints:nil)))}
    return .init(data:data,contract:f.dehazePreviewContract,fallback:f.dehazePreviewFallback,plane:f.dehazePlaneSHA256,quality:f.quality,key:f.outputKey)
  }
  private func referenceTIFF(_ source:URL,_ recipe:DevelopmentRecipe,_ root:URL)throws->Data{
    try autoreleasepool{
      let context=DevelopmentDehazeTIFFPreviewV1.makeContext();defer{context.clearCaches()}
      let graph=try DevelopmentRendererV3.develop(source,recipe:recipe,context:context)
      let url=root.appendingPathComponent("reference-"+UUID().uuidString+".tiff")
      try TIFF16Output.write(graph.image,context:context,colorSpace:PhotoRenderer.sRGB,to:url,transport:.whole)
      let image=try XCTUnwrap(CIImage(contentsOf:url,options:[.applyOrientationProperty:true]))
      let decoded=DevelopedV3Graph(image:image,sourceDepth:16,sourceSize:image.extent.size,canonicalSize:image.extent.size,graphDescriptor:"actual-native-TIFF-reference")
      let shown=try V3PreviewMaterializer.materialize(decoded,context:context,maxPixel:2400)
      return try PreviewWindows.compact(XCTUnwrap(shown.image.cgImage(forProposedRect:nil,context:nil,hints:nil)))
    }
  }
  private func assertTinyVisible(_ candidate:Data,_ reference:Data){
    XCTAssertEqual(candidate.count,reference.count);guard candidate.count==reference.count else{return}
    var errors=[Int]()
    for i in stride(from:0,to:candidate.count,by:4){XCTAssertEqual(candidate[i+3],reference[i+3]);for c in 0..<3{errors.append(abs(Int(candidate[i+c])-Int(reference[i+c])))}}
    errors.sort();XCTAssertLessThanOrEqual(errors.last ?? 0,2)
    XCTAssertLessThanOrEqual(errors[Int(Double(errors.count-1)*0.99)],1)
  }
  private func assertClosed(_ service:DevelopmentPreviewService)async{
    let stats=await service.statistics(),known=await service.interactiveKnownOwnedForTesting()
    XCTAssertEqual(stats.activeNativeRenders,0);XCTAssertEqual(stats.sourceSnapshotDiskBytes,0)
    XCTAssertTrue(known.values.allSatisfy{$0==0},"actual output aliases must be dropped before final ledger check")
  }
  func testRealServiceIPSTAndNativeTIFFReferenceKeepContractAndActualOwners()async throws{
    let(root,source)=try fixture(width:2560,height:192);defer{try?FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0),qaDehazeTIFFPreview:true)
    do{
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      let recipe=try await prepared(service,lease,consumer)
      let before=try EditingFingerprint.of(recipe)
      let ip=try await packed(service,request(lease,consumer,recipe,2,.interactive)),st=try await packed(service,request(lease,consumer,recipe,3))
      XCTAssertEqual(ip.data,st.data);XCTAssertEqual(ip.quality,.interactive);XCTAssertEqual(st.quality,.settled)
      XCTAssertEqual(ip.contract,DevelopmentDehazeTIFFPreviewV1.version);XCTAssertNil(ip.fallback);XCTAssertEqual(ip.plane?.count,64);XCTAssertEqual(ip.plane,st.plane)
      assertTinyVisible(st.data,try referenceTIFF(source.sourceLocation,recipe,root))
      XCTAssertEqual(try EditingFingerprint.of(recipe),before)
      let rawCapture=await service.capturedFileForTesting(lease.id)
      let captured=try XCTUnwrap(rawCapture)
      XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:captured.url.deletingLastPathComponent().path).contains{$0.hasPrefix("dehaze-rf-")})
      let stats=await service.statistics();XCTAssertEqual(stats.completedRenders,2);XCTAssertEqual(stats.cacheHits,0)
    }catch{await service.closeAll();throw error}
    await service.closeAll();await assertClosed(service)
  }
  func testLegalPartialAlphaFallsBackByteExactlyAndDefaultRouteIsUnchanged()async throws{
    let(root,source)=try fixture(alpha:32768);defer{try?FileManager.default.removeItem(at:root)}
    let candidate=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0),qaDehazeTIFFPreview:true)
    let old=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0))
    do{
      let a=try await candidate.open(source:.raw(source)),b=try await old.open(source:.raw(source)),consumer=PreviewConsumerID()
      let ra=try await prepared(candidate,a,consumer),rb=try await prepared(old,b,consumer)
      let ca=try await packed(candidate,request(a,consumer,ra,2)),cb=try await packed(old,request(b,consumer,rb,2))
      XCTAssertEqual(ca.data,cb.data);XCTAssertEqual(ca.fallback,"legal-nonopaque");XCTAssertNil(ca.plane);XCTAssertNil(cb.contract)
      let rawCapture=await candidate.capturedFileForTesting(a.id)
      let capture=try XCTUnwrap(rawCapture)
      XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:capture.url.deletingLastPathComponent().path).contains{$0.hasPrefix("dehaze-rf-")})
    }catch{await candidate.closeAll();await old.closeAll();throw error}
    await candidate.closeAll();await old.closeAll();await assertClosed(candidate);await assertClosed(old)
  }
  func testActualFloatHDRTIFFInputPreservesOriginalPublicFallbackBytes()async throws{
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("dehaze-hdr-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);defer{try?FileManager.default.removeItem(at:root)}
    let url=root.appendingPathComponent("HDR.tiff"),width=64,height=64
    var values=[Float](repeating:1,count:width*height*4)
    for i in 0..<(width*height){values[i*4]=0.25;values[i*4+1]=2;values[i*4+2]=0.75}
    let provider=try XCTUnwrap(CGDataProvider(data:values.withUnsafeBytes{Data($0)} as CFData))
    let image=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:32,bitsPerPixel:128,bytesPerRow:width*16,
      space:DevelopmentColorEngineV3.linearSRGB,bitmapInfo:[.floatComponents,.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)],
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let check=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil)),decoded=try XCTUnwrap(CGImageSourceCreateImageAtIndex(check,0,nil))
    XCTAssertEqual(decoded.bitsPerComponent,32,"must be a real HDR input, not a clipped16 fixture")
    let size=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)
    let source=EditingSourceSnapshot(projectID:"dehaze",assetID:"hdr",contentSHA256:try RenderFiles.hash(url),byteCount:size.int64Value,admissionFingerprint:"HDR-real",sourceLocation:url)
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0),qaDehazeTIFFPreview:true),old=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0))
    do{
      let a=try await service.open(source:.raw(source)),b=try await old.open(source:.raw(source)),consumer=PreviewConsumerID()
      let ra=try await prepared(service,a,consumer),rb=try await prepared(old,b,consumer)
      let ca=try await packed(service,request(a,consumer,ra,2)),cb=try await packed(old,request(b,consumer,rb,2))
      XCTAssertNil(ca.contract);XCTAssertEqual(ca.data,cb.data)
    }catch{await service.closeAll();await old.closeAll();throw error}
    await service.closeAll();await old.closeAll();await assertClosed(service);await assertClosed(old)
  }
  func testActualF32AdmissionSeparatesLegalTransparencyFromMalformedAndAllowsFiniteOutputHDR()throws{
    let context=DevelopmentDehazeTIFFPreviewV1.makeContext(),scope=PreviewPresentationScope()
    defer{context.clearCaches();scope.closeAndRetire()}
    let r=DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{})
    let cases:[(SIMD4<Float>,DevelopmentDehazeTIFFPreviewV1.Admission?)]=[
      (.init(-0.1,2,0.3,1),.opaque),(.init(0.1,0.2,0.3,0.5),.legalNonopaque),(.init(0,0,0,0),.legalNonopaque),
      (.init(0,0,0,Float(1).nextDown),.legalNonopaque),(.init(0,0,0,Float(1).nextUp),nil),(.init(0,0,0,-0.1),nil),
      (.init(.nan,0,0,1),nil),(.init(0,0,0,.infinity),nil)]
    for (p,expected) in cases{
      var pixel=p
      let image=CIImage(bitmapData:withUnsafeBytes(of:&pixel){Data($0)},bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      if let expected{
        try DevelopmentColorEngineV3.validateFinite(image,context:context)
        XCTAssertEqual(try DevelopmentDehazeTIFFPreviewV1.classify(image,context:context,request:r),expected)
      }else{
        XCTAssertThrowsError(try {try DevelopmentColorEngineV3.validateFinite(image,context:context);_ = try DevelopmentDehazeTIFFPreviewV1.classify(image,context:context,request:r)}())
      }
      context.clearCaches()
    }
  }
  func testOtherAmountAndDetailUseOriginalRouteAndPreparedSourceFenceStillRejects()async throws{
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0),qaDehazeTIFFPreview:true),old=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0))
    do{
      let a=try await service.open(source:.raw(source)),b=try await old.open(source:.raw(source)),consumer=PreviewConsumerID()
      var ra=try await prepared(service,a,consumer),rb=try await prepared(old,b,consumer)
      ra.adjustmentsV3!.advancedDetail.dehaze.amount=50;rb.adjustmentsV3!.advancedDetail.dehaze.amount=50
      let x=try await packed(service,request(a,consumer,ra,2)),y=try await packed(old,request(b,consumer,rb,2))
      XCTAssertNil(x.contract);XCTAssertEqual(x.data,y.data)
      ra.adjustmentsV3!.advancedDetail.dehaze.amount=25
      let detail=try await packed(service,request(a,consumer,ra,3,.detail));XCTAssertNil(detail.contract)
      let stale=DevelopmentPreviewRequest(sessionID:a.id,sourceGeneration:a.sourceGeneration+1,consumerID:consumer,role:.primary,revision:4,recipe:ra,quality:.settled)
      do{_ = try await service.render(stale);XCTFail("stale source admitted")}catch{XCTAssertTrue(error is DevelopmentPreviewError)}
      XCTAssertFalse(DevelopmentDehazeTIFFPreviewV1.bootstrap(bundleIdentifier:"other",environment:["RAWMASTER_QA_DEHAZE_TIFF_PREVIEW_V1":"1"]))
    }catch{await service.closeAll();await old.closeAll();throw error}
    await service.closeAll();await old.closeAll();await assertClosed(service);await assertClosed(old)
  }
  private final class Gate:@unchecked Sendable{
    let entered:XCTestExpectation,release=DispatchSemaphore(value:0)
    let phase:DevelopmentDehazeTIFFPreviewV1.Phase
    private let lock=NSLock();private var used=false
    init(_ phase:DevelopmentDehazeTIFFPreviewV1.Phase,_ entered:XCTestExpectation){self.phase=phase;self.entered=entered}
    func observe(_ p:DevelopmentDehazeTIFFPreviewV1.Phase)throws{
      lock.lock();let hold=p==phase && !used;if hold{used=true};lock.unlock()
      if hold{entered.fulfill();guard release.wait(timeout:.now()+5) == .success else{throw DevelopmentPreviewError.closed}}
    }
  }
  func testActualScalarProviderAndBankCancellationJoinBeforeClosingAndNeverPublishLateFrame()async throws{
    for phase:DevelopmentDehazeTIFFPreviewV1.Phase in [.scalarSubmitted,.providerReady,.bankJoined]{
      let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
      let entered=expectation(description:"real phase"),gate=Gate(phase,entered)
      let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0),qaDehazeTIFFPreview:true,qaDehazeTIFFObserverForTesting:gate.observe)
      do{
        let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID(),r=try await prepared(service,lease,consumer)
        let render=Task{try await service.render(self.request(lease,consumer,r,2))}
        await fulfillment(of:[entered],timeout:5)
        let joined=expectation(description:"close cannot overtake live task");joined.isInverted=true
        let closing=Task{await service.closeAll();joined.fulfill()}
        await fulfillment(of:[joined],timeout:0.05)
        gate.release.signal()
        do{_ = try await render.value;XCTFail("cancelled request published")}catch{}
        await closing.value
      }catch{gate.release.signal();await service.closeAll();throw error}
      await assertClosed(service)
    }
  }
  func testOwnRfProviderShortReadIsStickyAndDoesNotBecomeNonopaqueFallback()throws{
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let scratch=try DehazeRfScratchV1(capture:source.sourceLocation,width:2,height:1),state=DehazeRfStateV1()
    try Data(count:8).write(to:scratch.plane);try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:scratch.plane.path)
    try autoreleasepool{
      let provider=try DehazeRfProviderV1(scratch,state:state)
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:scratch.plane.path)
      let writer=try FileHandle(forWritingTo:scratch.plane);try writer.truncate(atOffset:0);try writer.close()
      var values=[UInt32](repeating:0,count:2)
      values.withUnsafeMutableBytes{provider.provideImageData($0.baseAddress!,bytesPerRow:8,origin:0,0,size:2,1,userInfo:nil)}
      XCTAssertEqual(values,[0x7fc00000,0x7fc00000]);XCTAssertThrowsError(try state.check())
    }
    XCTAssertTrue(state.storageReleased);try scratch.finish();XCTAssertFalse(FileManager.default.fileExists(atPath:scratch.directory.path))
  }
  func testActualEscapedFinalImageRetainsItsTicketUntilLastAliasDrops()async throws{
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0),qaDehazeTIFFPreview:true)
    var image:NSImage?
    do{
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID(),r=try await prepared(service,lease,consumer)
      var frame:DevelopmentPreviewFrame?=try await service.render(request(lease,consumer,r,2))
      autoreleasepool{image=frame?.image;frame=nil}
      await service.closeAll()
      let retained=await service.interactiveKnownOwnedForTesting();XCTAssertGreaterThan(retained["presentationRetiredCPU"] ?? 0,0)
      autoreleasepool{XCTAssertNotNil(image)}
      autoreleasepool{image=nil}
    }catch{autoreleasepool{image=nil};await service.closeAll();throw error}
    await assertClosed(service)
  }
}
