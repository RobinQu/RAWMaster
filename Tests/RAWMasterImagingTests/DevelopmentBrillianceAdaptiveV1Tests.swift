import AppKit
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentBrillianceAdaptiveV1Tests:XCTestCase {
  private func light(_ amount:Double)->DevelopmentLightV3 {
    .init(enabled:true,brilliance:amount,brillianceVersion:.adaptiveLocalV1)
  }
  private func image(alpha:Float=1,hdr:Bool=false,width:Int=256,height:Int=192)->CIImage {
    var pixels=[Float](repeating:0,count:width*height*4)
    for y in 0..<height {for x in 0..<width {
      let i=(y*width+x)*4,t=Float(x)/Float(max(1,width-1)),u=Float(y)/Float(max(1,height-1))
      let rgb:SIMD3<Float> = hdr ? SIMD3(-0.15,1.6,0.3):SIMD3(0.05+0.7*t,0.08+0.6*u,0.1+0.5*t*u)
      pixels[i]=rgb.x*alpha;pixels[i+1]=rgb.y*alpha;pixels[i+2]=rgb.z*alpha;pixels[i+3]=alpha
    }}
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func pixels(_ image:CIImage,context:CIContext)throws->[Float] {
    let e=image.extent,w=Int(e.width),h=Int(e.height)
    var result=[Float](repeating:.nan,count:w*h*4)
    try result.withUnsafeMutableBytes {bytes in
      let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:w,height:h,bytesPerRow:w*16,format:.RGBAf)
      destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
      destination.isClamped=false;destination.isDithered=false;destination.isFlipped=true
      let task=try context.startTask(toRender:image,from:e,to:destination,at:.zero)
      do {_ = try task.waitUntilCompleted()}catch {let primary=error;_ = try? task.waitUntilCompleted();throw primary}
    }
    return result
  }
  func testOwnedFiniteContextJoinsRetiresAndPreservesFailures()throws {
    let source=image(width:16,height:16)
    for isRAW in [false,true] {
      weak var succeeded:CIContext?
      try DevelopmentBrillianceAdaptiveV1.withOwnedFiniteValidationContext(sourceIsRAW:isRAW) { context in
        succeeded=context
        try DevelopmentColorEngineV3.validateFinite(source,context:context)
      }
      XCTAssertNil(succeeded)
    }
    let values:[Float] = [.nan,0,0,1]
    let invalid=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:16,
      size:.init(width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    weak var failed:CIContext?
    XCTAssertThrowsError(try DevelopmentBrillianceAdaptiveV1.withOwnedFiniteValidationContext(sourceIsRAW:false) { context in
      failed=context
      try DevelopmentColorEngineV3.validateFinite(invalid,context:context)
    }) { error in
      guard case DevelopmentError.invalidEncoding=error else{return XCTFail("Original finite-validation error changed: \(error)")}
    }
    XCTAssertNil(failed)
    weak var cancelled:CIContext?
    XCTAssertThrowsError(try DevelopmentBrillianceAdaptiveV1.withOwnedFiniteValidationContext(sourceIsRAW:false) { context in
      cancelled=context
      try DevelopmentColorEngineV3.validateFinite(source,context:context)
      throw CancellationError()
    }) {XCTAssertTrue($0 is CancellationError)}
    XCTAssertNil(cancelled)
    var escaped:CIContext?
    XCTAssertThrowsError(try DevelopmentBrillianceAdaptiveV1.withOwnedFiniteValidationContext(sourceIsRAW:false) { context in
      escaped=context
      try DevelopmentColorEngineV3.validateFinite(source,context:context)
    }) { error in
      guard case PreviewPresentationError.allocationProtocol=error else{return XCTFail("Escaped validation context admitted")}
    }
    XCTAssertNotNil(escaped);escaped=nil
  }
  func testMaskBandsMatchOriginalFiniteRuleAtEdgesTailAndTranslatedOrigin()throws {
    let width=17,height=129,context=DevelopmentBrillianceAdaptiveV1.makeContext()
    defer{context.clearCaches()}
    func source(badIndex:Int?=nil)->CIImage {
      var values=[SIMD4<Float>](repeating:.init(-0.25,1.8,0.4,0.5),count:width*height)
      values[1] = .init(-0.7,2.1,0.6,0) // Finite hidden RGB and HDR remain legal.
      if let badIndex{values[badIndex] = .init(.nan,0,0,0)}
      return CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:width*16,
        size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    }
    for offset in [CGPoint.zero,CGPoint(x:11,y:-7)] {
      let valid=source().transformed(by:.init(translationX:offset.x,y:offset.y))
      var rects=[CGRect](),count=0
      try DevelopmentColorEngineV3.validateFinite(valid,context:context)
      try DevelopmentBrillianceAdaptiveV1.validateFinite(valid,context:context,observeBandForTesting:{rect,n in rects.append(rect);count += n})
      XCTAssertEqual(count,width*height)
      XCTAssertEqual(rects,[CGRect(x:offset.x,y:offset.y,width:CGFloat(width),height:64),
        CGRect(x:offset.x,y:offset.y+64,width:CGFloat(width),height:64),CGRect(x:offset.x,y:offset.y+128,width:CGFloat(width),height:1)])
      for index in [0,width*64-1,width*64,width*height-1] {
        let invalid=source(badIndex:index).transformed(by:.init(translationX:offset.x,y:offset.y))
        XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(invalid,context:context))
        XCTAssertThrowsError(try DevelopmentBrillianceAdaptiveV1.validateFinite(invalid,context:context))
      }
    }
    XCTAssertTrue(DevelopmentBrillianceAdaptiveV1.supportsFiniteMaskBands(.init(x:0,y:0,width:16_384,height:129)))
    XCTAssertFalse(DevelopmentBrillianceAdaptiveV1.supportsFiniteMaskBands(.init(x:0.25,y:0,width:17,height:129)))
    XCTAssertFalse(DevelopmentBrillianceAdaptiveV1.supportsFiniteMaskBands(.init(x:0,y:0,width:Double(DevelopmentBrillianceAdaptiveV1.maximumMaskBandWidth)+1,height:1)))
    final class FractionalImage:CIImage,@unchecked Sendable {
      override var extent:CGRect {CGRect(x:0.25,y:0,width:17,height:129)}
    }
    let fractional=FractionalImage(color:.white)
    var bandCalls=0
    XCTAssertNoThrow(try DevelopmentColorEngineV3.validateFinite(fractional,context:context))
    XCTAssertNoThrow(try DevelopmentBrillianceAdaptiveV1.validateFinite(fractional,context:context,observeBandForTesting:{_,_ in bandCalls += 1}))
    XCTAssertEqual(bandCalls,0,"Fractional domains retain the original maximum transport")
  }
  func testMaskBandPoisonThresholdAndFailureCancellationKeepOriginalError()throws {
    func run(_ values:[Float])throws {
      try DevelopmentBrillianceAdaptiveV1.checkedFiniteMaskBand(width:4,rows:1){pointer in
        for (i,value) in values.enumerated(){pointer.assumingMemoryBound(to:Float.self)[i]=value}
      }
    }
    XCTAssertNoThrow(try run([0,0,0,0]))
    let invalidValues:[[Float]]=[[0,0,0],[0,0,0,.nan],[0,0,0,.infinity],[0,0,0,0.5],[0,0,0,1]]
    for values in invalidValues {
      XCTAssertThrowsError(try run(values))
    }
    enum Stop:Error{case primary}
    XCTAssertThrowsError(try DevelopmentBrillianceAdaptiveV1.checkedFiniteMaskBand(width:4,rows:1){_ in throw Stop.primary}) {error in
      guard case Stop.primary=error else{return XCTFail("Primary writer failure changed")}
    }
    var checks=0,wrote=false
    XCTAssertThrowsError(try DevelopmentBrillianceAdaptiveV1.checkedFiniteMaskBand(width:4,rows:1,checkCancellation:{
      checks += 1;if checks==2{throw CancellationError()}
    }){pointer in
      for i in 0..<4{pointer.assumingMemoryBound(to:Float.self)[i]=0};wrote=true
    }){XCTAssertTrue($0 is CancellationError)}
    XCTAssertTrue(wrote);XCTAssertEqual(checks,2)
    let source=image(width:17,height:129)
    weak var witness:CIContext?
    var joinedBands=0
    XCTAssertThrowsError(try DevelopmentBrillianceAdaptiveV1.withOwnedFiniteValidationContext(sourceIsRAW:true){context in
      witness=context
      try DevelopmentBrillianceAdaptiveV1.validateFinite(source,context:context,observeBandForTesting:{_,_ in
        joinedBands += 1;throw CancellationError()
      })
    }){XCTAssertTrue($0 is CancellationError)}
    XCTAssertEqual(joinedBands,1);XCTAssertNil(witness)
  }
  func testZeroIdentityAndSourceDimensionFallbackAreDeterministic()throws {
    let source=image(alpha:0.5,hdr:true,width:8,height:6)
    XCTAssertTrue(try DevelopmentBrillianceAdaptiveV1.apply(light(0),to:source) === source)
    XCTAssertFalse(DevelopmentBrillianceAdaptiveV1.nativeGraphSupported(source.extent))
    XCTAssertTrue(DevelopmentBrillianceAdaptiveV1.nativeGraphSupported(image().extent))
    let context=DevelopmentColorEngineV3.makeContext();defer{context.clearCaches()}
    var old=light(-0.3);old.brillianceVersion=nil
    XCTAssertEqual(try pixels(DevelopmentBrillianceAdaptiveV1.apply(light(-0.3),to:source),context:context),
      try pixels(DevelopmentSpatialEngineV3.applyLight(old,to:source),context:context))
  }
  func testFullStrengthRangeAndZeroNeighborhoodRemainFiniteAndContinuous()throws {
    let source=image(),context=DevelopmentColorEngineV3.makeContext();defer{context.clearCaches()}
    let original=try pixels(source,context:context)
    for amount in [-2.0,-0.5,-0.0001,0.0001,0.5,1,2] {
      let output=try pixels(DevelopmentBrillianceAdaptiveV1.apply(light(amount),to:source),context:context)
      XCTAssertTrue(output.allSatisfy(\.isFinite))
      XCTAssertTrue(stride(from:3,to:output.count,by:4).allSatisfy{output[$0]==1})
      let change=zip(original,output).map{abs($0.0-$0.1)}.max()!
      if abs(amount)<0.001 {XCTAssertLessThan(change,0.001)}else{XCTAssertGreaterThan(change,0.001)}
      context.clearCaches()
    }
  }
  func testStraightAlphaAndNegativeHDRArePreservedWithoutClippingToSDR()throws {
    let context=DevelopmentColorEngineV3.makeContext();defer{context.clearCaches()}
    let opaque=try pixels(DevelopmentBrillianceAdaptiveV1.apply(light(0.5),to:image(hdr:true)),context:context)
    let partial=try pixels(DevelopmentBrillianceAdaptiveV1.apply(light(0.5),to:image(alpha:0.5,hdr:true)),context:context)
    let clear=image(alpha:0,hdr:true)
    let transparent=try pixels(DevelopmentBrillianceAdaptiveV1.apply(light(0.5),to:clear),context:context)
    XCTAssertEqual(transparent,try pixels(clear,context:context))
    for i in stride(from:0,to:opaque.count,by:4) {
      XCTAssertLessThan(opaque[i],0);XCTAssertGreaterThan(opaque[i+1],1)
      XCTAssertEqual(partial[i+3],0.5)
      for c in 0..<3 {XCTAssertEqual(partial[i+c]*2,opaque[i+c],accuracy:0.000002)}
    }
  }
  func testAdaptiveUsesCanonicalPreviewAndDoesNotActivateFixedQA()throws {
    var p=DevelopmentAdjustmentsV3();p.light=light(0.25);p.light.exposure=0.2;p.light.shadows=0.3
    let recipe=DevelopmentRecipe(adjustmentsV3:p)
    XCTAssertFalse(DevelopmentBrilliancePublicV1.active(recipe))
    XCTAssertEqual(try PreviewInteractiveProxyV3.support(recipe,sourceIsRAW:true),.canonical(.adaptiveBrilliance))
    XCTAssertEqual(try PreviewInteractiveProxyV3.support(recipe,sourceIsRAW:false),.canonical(.adaptiveBrilliance))
    XCTAssertNotNil(try PreviewNativePointwiseV1.routeEligibility(recipe,size:.init(width:256,height:192)))
    XCTAssertNoThrow(try DevelopmentThumbnailEngine.checkSupport(recipe,sourceIsRAW:true))
    let context=DevelopmentColorEngineV3.makeContext();defer{context.clearCaches()}
    XCTAssertThrowsError(try PreviewInteractiveProxyV3.suffix(p,source:image(),sourceIsRAW:false,nativeSize:.init(width:256,height:192),scale:1,context:context,check:{}))
    let illustrated=try PreviewInteractiveProxyV3.suffix(p,source:image(),sourceIsRAW:false,nativeSize:.init(width:256,height:192),scale:1,context:context,check:{},illustrativeAdaptiveBrilliance:true)
    XCTAssertTrue(try pixels(illustrated,context:context).allSatisfy(\.isFinite))
  }
  func testNewLightSummaryExplicitlySelectsAdaptive()throws {
    var bins=[UInt64](repeating:0,count:256);bins[128]=100
    let scalars=DevelopmentAnalysisScalars(histogram:.init(red:bins,green:bins,blue:bins,luminance:bins,
      visibleSamples:100,transparentSamples:0,sampledSize:.init(width:10,height:10)),meanLinearRGB:.init(0.3,0.4,0.5),meanSaturation:0.2)
    guard case .light(let value)=try DevelopmentAnalysisEngine.resolvedSummary(.light,amount:0.5,scalars:scalars) else {return XCTFail("light summary")}
    XCTAssertEqual(value.brillianceVersion,.adaptiveLocalV1);XCTAssertGreaterThan(value.brilliance,0)
  }
  private func fixture()throws->(URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("brilliance-adaptive-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let url=root.appendingPathComponent("source.tiff"),context=DevelopmentColorEngineV3.makeContext()
    defer{context.clearCaches()}
    let cg=try XCTUnwrap(context.createCGImage(image(),from:image().extent,format:.RGBA16,colorSpace:PhotoRenderer.sRGB))
    let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.tiff"as CFString,1,nil))
    CGImageDestinationAddImage(destination,cg,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let size=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:url.path)[.size]as?NSNumber)
    return(root,.init(projectID:"adaptive",assetID:"fixture",contentSHA256:try RenderFiles.hash(url),byteCount:size.int64Value,admissionFingerprint:"adaptive-native",sourceLocation:url))
  }
  func testCanonicalMixedPreviewDetailAndPNGAndTIFFReopen()async throws {
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    var p=DevelopmentAdjustmentsV3();p.light=light(0.4);p.light.exposure=0.1;p.light.shadows=0.2;p.light.highlights = -0.15
    p.light.contrast=0.1;p.color = .init(enabled:true,saturation:0.1)
    let recipe=DevelopmentRecipe(adjustmentsV3:p),service=DevelopmentService()
    let encoded=try JSONEncoder().encode(recipe),reopened=try JSONDecoder().decode(DevelopmentRecipe.self,from:encoded)
    XCTAssertEqual(recipe,reopened)
    let previews=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0))
    do {
      let info=try await previews.open(source:.raw(source)),consumer=PreviewConsumerID()
      var outputs=[Data]()
      for (i,quality) in [PreviewQuality.interactive,.settled,.detail].enumerated() {
        let request=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,
          revision:UInt64(i+1),recipe:reopened,quality:quality,viewport:.init(maxPixel:quality == .detail ? 0:2400))
        let frame=try await previews.render(request)
        let cg=try XCTUnwrap(frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
        outputs.append(try PreviewWindows.compact(cg))
        XCTAssertNil(frame.brillianceTransportVersion)
      }
      XCTAssertEqual(outputs[0],outputs[1]);XCTAssertEqual(outputs[1],outputs[2])
      let context=DevelopmentColorEngineV3.makeContext();defer{context.clearCaches()}
      var exported=[[Float]]()
      for format in [PhotoRenderFormat.png16,.tiff16] {
        let url=root.appendingPathComponent("output."+format.filenameExtension)
        _ = try await service.render(source:source,recipe:reopened,format:format,destination:url)
        let decoded=try XCTUnwrap(CIImage(contentsOf:url))
        exported.append(try pixels(decoded,context:context))
      }
      XCTAssertEqual(exported[0],exported[1])
      // All spatial controls share the same canonical order. Omitting Brilliance changes the
      // result, while shadows/highlights remain present after the new operator.
      var noBrilliance=p;noBrilliance.light.brilliance=0
      let graph=try DevelopmentRendererV3.develop(source.sourceLocation,recipe:recipe,context:context)
      let baseline=try DevelopmentRendererV3.develop(source.sourceLocation,recipe:.init(adjustmentsV3:noBrilliance),context:context)
      XCTAssertNotEqual(try pixels(graph.image,context:context),try pixels(baseline.image,context:context))
      var noSHHL=p;noSHHL.light.shadows=0;noSHHL.light.highlights=0
      let noSpatial=try DevelopmentRendererV3.develop(source.sourceLocation,recipe:.init(adjustmentsV3:noSHHL),context:context)
      XCTAssertNotEqual(try pixels(graph.image,context:context),try pixels(noSpatial.image,context:context))
    } catch {await previews.closeAll();throw error}
    await previews.closeAll()
    let stats=await previews.statistics();XCTAssertEqual(stats.activeNativeRenders,0)
  }
  func testAuthorizedActualRAWHasFiniteMixedAdaptivePreview()async throws {
    guard let path=ProcessInfo.processInfo.environment["RAWMASTER_TEST_RAW"] else {throw XCTSkip("Explicit authorized RAW path required")}
    let url=URL(fileURLWithPath:path),size=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:path)[.size]as?NSNumber)
    let source=EditingSourceSnapshot(projectID:"adaptive",assetID:"authorized-raw",contentSHA256:try RenderFiles.hash(url),byteCount:size.int64Value,admissionFingerprint:"adaptive-raw",sourceLocation:url)
    var p=DevelopmentAdjustmentsV3();p.light=light(0.5);p.light.exposure=0.1;p.light.shadows=0.2;p.light.highlights = -0.1
    let output=try await DevelopmentService().preview(source:source,recipe:.init(adjustmentsV3:p),maxPixel:320)
    XCTAssertGreaterThan(output.pixelWidth,0);XCTAssertGreaterThan(output.pixelHeight,0)
    let cg=try XCTUnwrap(output.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    XCTAssertEqual(try PreviewWindows.compact(cg).count,output.pixelWidth*output.pixelHeight*4)
    try RenderFiles.verify(source)
  }
}
