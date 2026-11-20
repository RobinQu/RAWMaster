import Foundation
import XCTest
import AppKit
import CoreImage
import ImageIO
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentDehazeAnalysisV3Tests:XCTestCase {
  private func pixels(_ width:Int,_ height:Int,value:SIMD4<Float> = .init(0.5,0.75,1,1))->[Float] {
    var result=[Float](repeating:0,count:width*height*4)
    for i in 0..<(width*height) { for c in 0..<4 { result[i*4+c]=value[c] } };return result
  }
  func testProxyGeometryNativeRadiusAndUnionBudgetAreClosed()throws {
    let l=try DevelopmentDehazeAnalysisV3.proxyLayout(sourceSize:.init(width:9504,height:6336))
    XCTAssertEqual(l.width,512);XCTAssertEqual(l.height,341);XCTAssertEqual(l.rx,2);XCTAssertEqual(l.ry,2)
    XCTAssertLessThanOrEqual(l.scratchBytes,32*1024*1024)
    let tiny=try DevelopmentDehazeAnalysisV3.proxyLayout(sourceSize:.init(width:8,height:8))
    XCTAssertEqual(tiny.rx,1);XCTAssertEqual(tiny.ry,1)
    XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.scratchBytes(width:Int.max,height:512))
    XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.scratchBytes(width:513,height:1))
    XCTAssertLessThanOrEqual(try DevelopmentDehazeAnalysisV3.scratchBytes(width:512,height:512),DevelopmentDehazeAnalysisV3.maximumScratchBytes)
  }
  func testQuantHalfStepAndInvisibleNeutralNeighbors()throws {
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.quantize(.init(repeating:0.5)),32768)
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.quantize(.init(-4,2,1)),0)
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.quantize(.init(repeating:30)),65535)
    var p=pixels(10,10)
    for i in 0..<36 { for c in 0..<4 { p[i*4+c]=0 } }
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.estimate(p,width:10,height:10,sourceSize:.init(width:10,height:10)),
      .airlight(.init(red:0.5,green:0.75,blue:1))) // exactly64 visible, zero-alpha holes are not dark0.
    p[36*4+3]=0
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.estimate(p,width:10,height:10,sourceSize:.init(width:10,height:10)),.noResult(.insufficientVisibleSamples))
  }
  func testTopFractionRowTiesAndEvenComponentMedianAreExact()throws {
    var p=pixels(20,20,value:.init(0.5,0.5,0.5,1)) // N400 => exactly2, all dark minima equal.
    p[0]=1;p[1]=0.5;p[2]=0.75
    p[4]=3;p[5]=0.5;p[6]=1.25
    // Equal guide score must choose first two top-row pixels, not every tied pixel.
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.estimate(p,width:20,height:20,sourceSize:.init(width:20,height:20)),
      .airlight(.init(red:2,green:0.5,blue:1)))
  }
  func testDarkMinimumUsesInclusiveRectAndBorder()throws {
    var p=pixels(10,10,value:.init(repeating:0.8));for i in 0..<100 { p[i*4+3]=1 }
    // Low dark sample at the first corner suppresses [0...1]x[0...1].
    p[0]=0.01;p[1]=0.01;p[2]=0.01
    p[2*4]=1.5 // first surviving top-row score is x2; G/B remain0.8.
    let expected=DevelopmentDehazeAirlightV1(red:1.5,green:Double(Float(0.8)),blue:Double(Float(0.8)))
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.estimate(p,width:10,height:10,sourceSize:.init(width:10,height:10)),.airlight(expected))
  }
  func testFiniteAlphaDomainOutOfRangeEstimateAndCancellation()throws {
    for invalid in [Float.nan,Float.infinity] {
      var p=pixels(8,8);p[0]=invalid;p[3]=0
      XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.estimate(p,width:8,height:8,sourceSize:.init(width:8,height:8)))
    }
    for alpha:Float in [-0.1,Float(1).nextUp,1.1] {
      XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.estimate(pixels(8,8,value:.init(0,0,0,alpha)),width:8,height:8,sourceSize:.init(width:8,height:8)))
    }
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.estimate(pixels(8,8,value:.init(17,1,1,1)),width:8,height:8,sourceSize:.init(width:8,height:8)),.noResult(.airlightOutsideDomain))
    let cancellation=DevelopmentAnalysisCancellation();cancellation.cancel()
    XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.estimate(pixels(8,8),width:8,height:8,sourceSize:.init(width:8,height:8),cancellation:cancellation))
  }
  func testJoinedRAWProxyRepairsUpperCoverageAndPreservesStraightHDR()throws {
    let a=Float(1).nextUp
    let unchanged:[Float]=[0.25,0.5,0.75,0.5, -0.0,0,0,0, 1,2,3,-0.125, .nan,2,3,a, 1,2,3,.infinity]
    var samples=[-0.5*a,2*a,4*a,a]+unchanged
    try DevelopmentDehazeAnalysisV3.normalizeRAWProxyCoverage(&samples,width:6,height:1)
    XCTAssertEqual(Array(samples.prefix(4)),[-0.5,2,4,1])
    XCTAssertEqual(samples.dropFirst(4).map(\.bitPattern),unchanged.map(\.bitPattern))

    let source=DevelopmentPixelSize(width:8,height:8)
    let canonical=pixels(8,8,value:.init(0.5,2,4,1))
    var proxy=pixels(8,8,value:.init(0.5*a,2*a,4*a,a))
    XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.estimate(proxy,width:8,height:8,sourceSize:source))
    try DevelopmentDehazeAnalysisV3.normalizeRAWProxyCoverage(&proxy,width:8,height:8)
    XCTAssertEqual(proxy,canonical)
    XCTAssertEqual(try DevelopmentDehazeAnalysisV3.estimate(proxy,width:8,height:8,sourceSize:source),
      .airlight(.init(red:0.5,green:2,blue:4)))
  }
  func testInPlaceRankSorterMatchesClosedTotalOrder()throws {
    var values=[7,4,1,9,0,3,8,5,6,2]
    try DevelopmentDehazeAnalysisV3.heapSort(&values,by:<)
    XCTAssertEqual(values,Array(0..<10))
    try DevelopmentDehazeAnalysisV3.heapSort(&values,by:>)
    XCTAssertEqual(values,Array((0..<10).reversed()))
  }
  func testActualImageOrientationSixEightHasIndependentPreDehazeContext()throws {
    for orientation in [6,8] {
      let root=FileManager.default.temporaryDirectory.appendingPathComponent("Dehaze-EXIF-"+UUID().uuidString)
      try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try?FileManager.default.removeItem(at:root)}
      let b=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64,bitsPerPixel:32))
      for i in 0..<192 { b.bitmapData![i*4]=UInt8(i);b.bitmapData![i*4+1]=120;b.bitmapData![i*4+2]=190;b.bitmapData![i*4+3]=255 }
      let url=root.appendingPathComponent("source.tiff")
      let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.tiff" as CFString,1,nil))
      CGImageDestinationAddImage(destination,try XCTUnwrap(b.cgImage),[kCGImagePropertyOrientation:orientation] as CFDictionary)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      let current=try DevelopmentDehazeContextFactoryV1.fromCapture(url,generation:3)
      XCTAssertEqual(current.source.exifOrientation,orientation);XCTAssertEqual(current.source.sourceSize,.init(width:12,height:16))
      let native=try PreviewNativeSource(capture:url,byteCount:Int64(try Data(contentsOf:url).count),artifact:false,memoryLimit:32)
      XCTAssertEqual(try native.dehazeContext(source:current.source,generation:3),current)
      XCTAssertNotEqual(native.localDecoderContractFingerprint,current.decoderContractFingerprint)
    }
  }
  private func fixture()throws->(URL,URL) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("Dehaze-prepare-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let url=root.appendingPathComponent("source.png")
    let b=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64,bitsPerPixel:32))
    for i in 0..<256 { b.bitmapData![i*4]=180;b.bitmapData![i*4+1]=190;b.bitmapData![i*4+2]=200;b.bitmapData![i*4+3]=255 }
    try XCTUnwrap(b.representation(using:.png,properties:[:])).write(to:url);return(root,url)
  }
  func testActiveUnpreparedDedicatedProjectionDoesNotUseOrdinaryGuardAndActualContextFences()throws {
    let(root,url)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let actual=try DevelopmentDehazeContextFactoryV1.fromCapture(url,generation:7)
    var original=try DevelopmentRecipe().promotingToV3();original.adjustmentsV3!.advancedDetail.dehaze = .init(enabled:true,amount:25)
    let p=try original.prospectiveDehazeInputV1(context:actual)
    let preview=DevelopmentPreviewRequest(sessionID:.init(),sourceGeneration:7,consumerID:.init(),role:.primary,revision:1,recipe:p.analysisRecipe,quality:.settled)
    let request=DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry,
      operation:.prepareDehaze,presentedRecipeFingerprint:p.presentedRecipeFingerprint,dehazeInputV1:p.input)
    XCTAssertThrowsError(try DevelopmentRendererV3.validateSupport(original,sourceIsRAW:false))
    XCTAssertNoThrow(try DevelopmentRendererV3.validateSupport(DevelopmentAnalysisEngine.samplingSupportRecipe(request),sourceIsRAW:false))
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
    defer{context.clearCaches()}
    var cache:DevelopmentAnalysisCacheEntry?
    let result=try DevelopmentAnalysisEngine.run(capture:url,request:request,sourceBinding:actual.source,memoryHint:32,cache:&cache,dehazeContext:actual)
    try DevelopmentDehazeAnalysisV3.validateResult(request:request,result:result,current:actual)
    guard case .dehaze(let resolution)=result.value,case .prepared=resolution.resolution else { return XCTFail("No actual prepared value") }
    let committed=try original.applying(.applyPreparedDehaze(resolution,wantedAmount:25),context:.init(source:actual.source,sourceGeneration:7,analysisStage:.workingImageBeforeGeometry,dehazeContextV1:actual))
    XCTAssertEqual(try committed.dehazePreparationStatusV1(context:actual),.ready)
    let stale=DevelopmentDehazeContextV1(source:actual.source,sourceGeneration:7,decoderContractFingerprint:String(repeating:"e",count:64))
    XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.validateResult(request:request,result:result,current:stale))
    XCTAssertThrowsError(try DevelopmentDehazeContextFactoryV1.requirePrepared(committed,context:stale))
    XCTAssertNotEqual(actual.decoderContractFingerprint,try DevelopmentRendererV3.localDecoderFingerprint(decoder:"image-io",originalDefaults:nil,orientation:1,size:.init(width:16,height:16)))
  }
  func testActualV2PreparationKeepsAirlightAndRejectsCrossVersionResults() async throws {
    let (root,url)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let source=EditingSourceSnapshot(projectID:"dehaze-v2",assetID:"tiny",contentSHA256:try RenderFiles.hash(url),
      byteCount:Int64(try Data(contentsOf:url).count),admissionFingerprint:"tiny-admitted",sourceLocation:url)
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:0))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      let facts=try await service.sourceFacts(sessionID:lease.id,sourceGeneration:lease.sourceGeneration)
      let current=try XCTUnwrap(facts.dehazeContextV1),original=DevelopmentRecipe(adjustmentsV3:.init())
      func request(_ algorithm:DevelopmentDehazeAlgorithm) throws -> DevelopmentAnalysisRequest {
        let p=try original.prospectiveDehazeInputV1(context:current,algorithm:algorithm)
        let preview=DevelopmentPreviewRequest(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,
          role:.primary,revision:1,recipe:p.analysisRecipe,quality:.settled)
        return .init(preview:preview,expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry,
          operation:.prepareDehaze,presentedRecipeFingerprint:p.presentedRecipeFingerprint,dehazeInputV1:p.input)
      }
      let r1=try request(.v1),r2=try request(.positiveColorGuideV2)
      let a1=try await service.analyze(r1);await service.cancelAnalysisAndJoin(r1)
      let a2=try await service.analyze(r2);await service.cancelAnalysisAndJoin(r2)
      XCTAssertEqual(a1.samplingVersion,DevelopmentDehazeAnalysisV3.v1CoverageResultVersion)
      XCTAssertFalse(try r1.matchesSamplingVersion(DevelopmentDehazeAnalysisV3.estimatorVersion))
      XCTAssertEqual(a2.samplingVersion,DevelopmentDehazeAnalysisV3.estimatorVersion+"/prepared-model-v2/raw-proxy-straight-coverage-v1")
      XCTAssertTrue(try r1.matchesSamplingVersion(a1.samplingVersion))
      XCTAssertTrue(try r2.matchesSamplingVersion(a2.samplingVersion))
      XCTAssertFalse(try r1.matchesSamplingVersion(a2.samplingVersion))
      XCTAssertFalse(try r2.matchesSamplingVersion(a1.samplingVersion))
      XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.validateResult(request:r2,result:a1,current:current))
      XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.validateResult(request:r1,result:a2,current:current))
      guard case .dehaze(let v1)=a1.value,case .dehaze(let v2)=a2.value,
            case .prepared(let p1)=v1.resolution,case .prepared(let p2)=v2.resolution else {
        throw DevelopmentDehazePreparationError.invalidPreparation
      }
      XCTAssertEqual(p1.airlight,p2.airlight)
      XCTAssertEqual(p1.algorithmVersion,1);XCTAssertEqual(p2.algorithmVersion,2)
      XCTAssertNotEqual(p1.inputFingerprint,p2.inputFingerprint)
      let context=DevelopmentAdjustmentCommandContext(source:current.source,sourceGeneration:current.sourceGeneration,
        analysisStage:.workingImageBeforeGeometry,dehazeContextV1:current)
      // Persisted preparation identity is independent of the in-memory sampling-result version.
      let storedV1=try original.applying(.applyPreparedDehaze(v1,wantedAmount:25),context:context)
      let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
      let encoded=try encoder.encode(storedV1)
      let reopened=try JSONDecoder().decode(DevelopmentRecipe.self,from:encoded)
      XCTAssertEqual(try encoder.encode(reopened),encoded)
      XCTAssertEqual(try reopened.dehazePreparationStatusV1(context:current),.ready)
      XCTAssertEqual(reopened.adjustmentsV3!.advancedDetail.preparedDehaze,p1)
      func preview(_ v:DevelopmentResolvedDehazeV1) throws -> DevelopmentPreviewRequest {
        .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,
          revision:2,recipe:try original.applying(.applyPreparedDehaze(v,wantedAmount:25),context:context),quality:.settled)
      }
      let k1=try await service.bitmapCacheKeyForTesting(preview(v1),sourceKey:source.contentSHA256)
      let k2=try await service.bitmapCacheKeyForTesting(preview(v2),sourceKey:source.contentSHA256)
      XCTAssertNotEqual(k1,k2)
    } catch { await service.closeAll();throw error }
    await service.closeAll()
    let ownership=await service.interactiveKnownOwnedForTesting(),stats=await service.analysisStatistics()
    XCTAssertTrue(ownership.values.allSatisfy{$0==0})
    XCTAssertEqual(stats.submitted,2);XCTAssertEqual(stats.completed,2)
    XCTAssertEqual(stats.active+stats.pendingUser+stats.pendingHistogram,0)
  }

  func testPublicPrepareAdmitsMissingAirlightThenStrictRenderAndCloseJoin()async throws {
    let(root,url)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let data=try Data(contentsOf:url)
    let source=EditingSourceSnapshot(projectID:"dehaze",assetID:"tiny",contentSHA256:try RenderFiles.hash(url),byteCount:Int64(data.count),admissionFingerprint:"tiny-admitted",sourceLocation:url)
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:1024*1024))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      let facts=try await service.sourceFacts(sessionID:lease.id,sourceGeneration:lease.sourceGeneration)
      let current=try XCTUnwrap(facts.dehazeContextV1)
      var original=DevelopmentRecipe(adjustmentsV3:.init());original.adjustmentsV3!.advancedDetail.dehaze = .init(enabled:true,amount:25)
      func preview(_ recipe:DevelopmentRecipe,_ revision:UInt64)->DevelopmentPreviewRequest {
        .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:.settled)
      }
      do { _=try await service.render(preview(original,1));XCTFail("Unprepared ordinary request rendered") }
      catch DevelopmentDehazePreparationError.preparationRequired {}
      let p=try original.prospectiveDehazeInputV1(context:current)
      let request=DevelopmentAnalysisRequest(preview:preview(p.analysisRecipe,1),expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry,
        operation:.prepareDehaze,presentedRecipeFingerprint:p.presentedRecipeFingerprint,dehazeInputV1:p.input)
      let result=try await service.analyze(request)
      guard case .dehaze(let resolved)=result.value else { throw DevelopmentPreviewError.invalidRequest }
      let committed=try original.applying(.applyPreparedDehaze(resolved,wantedAmount:25),context:.init(source:current.source,sourceGeneration:current.sourceGeneration,analysisStage:.workingImageBeforeGeometry,dehazeContextV1:current))
      let frame=try await service.render(preview(committed,2))
      XCTAssertEqual(frame.outputPixelSize,CGSize(width:16,height:16))
      var stale=committed
      let old=try XCTUnwrap(stale.adjustmentsV3!.advancedDetail.preparedDehaze)
      stale.adjustmentsV3!.advancedDetail.preparedDehaze = .init(sourceBinding:old.sourceBinding,inputFingerprint:String(repeating:"e",count:64),airlight:old.airlight)
      do { _=try await service.render(preview(stale,3));XCTFail("Stale prepared value passed public/cache admission") }
      catch DevelopmentDehazePreparationError.preparationRequired {}
      let stats=await service.statistics();XCTAssertEqual(stats.maximumObservedNativeRenders,1)
      await service.closeAll()
      let closed=await service.statistics();XCTAssertEqual(closed.activeNativeRenders,0)
    } catch { await service.closeAll();throw error }
  }

  func testV1BoundedRAWProxyCoverageKeepsOldStrictEstimatorAndAirlight()throws {
    let maximum=Float(bitPattern:1065353219),source=DevelopmentPixelSize(width:8,height:8)
    XCTAssertEqual(DevelopmentDehazeRAWCoverageV1.maximumAlpha.bitPattern,maximum.bitPattern)
    for a in [Float(1).nextUp,Float(bitPattern:1065353218),maximum] {
      var actual=pixels(8,8,value:.init(0.5*a,2*a,4*a,a))
      XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.estimate(actual,width:8,height:8,sourceSize:source))
      try DevelopmentDehazeAnalysisV3.normalizeRAWProxyCoverage(&actual,width:8,height:8,maximumAlpha:maximum)
      XCTAssertEqual(actual.map(\.bitPattern),pixels(8,8,value:.init(0.5,2,4,1)).map(\.bitPattern))
      XCTAssertEqual(try DevelopmentDehazeAnalysisV3.estimate(actual,width:8,height:8,sourceSize:source),.airlight(.init(red:0.5,green:2,blue:4)))
    }
    for pixel in [SIMD4<Float>(1,2,3,maximum.nextUp),.init(1,2,3,1.125),.init(1,2,3,-0.125),.init(.nan,2,3,maximum),.init(1,2,3,.infinity)] {
      var actual=pixels(8,8,value:pixel);let before=actual.map(\.bitPattern)
      try DevelopmentDehazeAnalysisV3.normalizeRAWProxyCoverage(&actual,width:8,height:8,maximumAlpha:maximum)
      XCTAssertEqual(actual.map(\.bitPattern),before)
      XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.estimate(actual,width:8,height:8,sourceSize:source))
    }
    var legal=pixels(8,8,value:.init(0.25,1,2,0.5));let before=legal.map(\.bitPattern)
    try DevelopmentDehazeAnalysisV3.normalizeRAWProxyCoverage(&legal,width:8,height:8,maximumAlpha:maximum)
    XCTAssertEqual(legal.map(\.bitPattern),before)
    let cancellation=DevelopmentAnalysisCancellation();cancellation.cancel()
    XCTAssertThrowsError(try DevelopmentDehazeAnalysisV3.normalizeRAWProxyCoverage(&legal,width:8,height:8,cancellation:cancellation,maximumAlpha:maximum))
  }

}
