import Foundation
import CoreImage
import ImageIO
import Darwin
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentNaturalCurvePickerV1Tests: XCTestCase {
  typealias E=DevelopmentNaturalCubicCurvesV1
  typealias P=DevelopmentNaturalCurvePickerV1
  private let channels:[DevelopmentCurveChannelV3ID]=[.rgb,.red,.green,.blue]
  private let points:[DevelopmentCurvePickerPointV3]=[.black,.midtone,.white,.addPoint]
  private func curves(enabled:Bool=true)->DevelopmentCurvesV3 {
    let red=DevelopmentCurveChannelV3(curve:.init(points:[.init(x:0,y:0),.init(x:0.4,y:0.3),.init(x:1,y:1)]),inputBlack:0.04,inputWhite:0.96)
    let green=DevelopmentCurveChannelV3(curve:.init(points:[.init(x:0,y:0),.init(x:0.6,y:0.7),.init(x:1,y:1)]),inputBlack:0.03,inputWhite:0.97)
    return .init(enabled:enabled,rgb:.init(curve:.init(points:[.init(x:0,y:0),.init(x:0.55,y:0.65),.init(x:1,y:1)]),inputBlack:0.02,inputWhite:0.98),
      red:red,green:green,blue:.init(inputBlack:0.01,inputWhite:0.99),algorithm:.naturalCubicGamma512LumaV1)
  }
  private func binding(_ c:DevelopmentCurvesV3)throws->DevelopmentAnalysisBinding {
    .init(sourceContentID:String(repeating:"a",count:64),sourceGeneration:7,
      expectedRecipeFingerprint:try EditingFingerprint.of(DevelopmentRecipe(adjustmentsV3:.init(curves:c))),stage:.workingImageBeforeGeometry)
  }
  private func channel(_ c:DevelopmentCurvesV3,_ id:DevelopmentCurveChannelV3ID)->DevelopmentCurveChannelV3 {
    switch id {case .rgb:return c.rgb;case .red:return c.red;case .green:return c.green;case .blue:return c.blue}
  }
  private func result(_ c:DevelopmentCurvesV3,_ pixel:SIMD4<Float>,_ id:DevelopmentCurveChannelV3ID,_ point:DevelopmentCurvePickerPointV3)throws->DevelopmentCurvesV3 {
    let b=try binding(c),value=try P.command(curves:c,pixel:pixel,channel:id,point:point,binding:b)
    XCTAssertEqual(value.binding,b);XCTAssertEqual(value.purpose,.curvesPicker);XCTAssertEqual(value.parameters.count,1)
    guard case .curves(let out)=try XCTUnwrap(value.parameters.first) else { throw DevelopmentV3Error.invalidGraph }
    return out
  }
  func testPureAllSixteenPickerCommandsUseNaturalDomainsAndPreserveOtherChannels()throws {
    let straight=SIMD3<Float>(0.18,0.31,0.52),alpha:Float=0.5,pixel=SIMD4<Float>(straight.x*alpha,straight.y*alpha,straight.z*alpha,alpha)
    for enabled in [false,true] {
      let original=curves(enabled:enabled),tables=try E.tables(original)
      let rgb=SIMD3<Float>(try E.sample(tables.rows[0],straight.x),try E.sample(tables.rows[1],straight.y),try E.sample(tables.rows[2],straight.z))
      let luma=(rgb.x*Float(0.30)+rgb.y*Float(0.59))+rgb.z*Float(0.11)
      XCTAssertGreaterThan(abs(luma-((straight.x*0.30+straight.y*0.59)+straight.z*0.11)),0.005)
      for id in channels {
        let linear:Float
        switch id {case .rgb:linear=luma;case .red:linear=straight.x;case .green:linear=straight.y;case .blue:linear=straight.z}
        let u=Darwin.powf(linear,Float(1.0/2.2)),old=channel(original,id)
        XCTAssertGreaterThan(abs(Double(u)-DevelopmentColorEngineV2.encode(Double(linear))),0.001)
        let x=(u-Float(old.inputBlack))/(Float(old.inputWhite)-Float(old.inputBlack))
        for point in points {
          let out=try result(original,pixel,id,point),target=channel(out,id)
          XCTAssertTrue(out.enabled);XCTAssertEqual(out.algorithm,original.algorithm)
          for other in channels where other != id {XCTAssertEqual(channel(out,other),channel(original,other))}
          switch point {
          case .black:XCTAssertEqual(target.inputBlack,Double(u));XCTAssertEqual(target.inputWhite,old.inputWhite);XCTAssertEqual(target.curve,old.curve)
          case .white:XCTAssertEqual(target.inputWhite,Double(u));XCTAssertEqual(target.inputBlack,old.inputBlack);XCTAssertEqual(target.curve,old.curve)
          case .midtone,.addPoint:
            let added=try XCTUnwrap(target.curve.points.first(where:{$0.x==Double(x)}))
            let y=point == .midtone ? Float(0.5):try E.evaluate(E.model(old.curve),x)
            XCTAssertEqual(added.y,Double(y));XCTAssertEqual(target.inputBlack,old.inputBlack);XCTAssertEqual(target.inputWhite,old.inputWhite)
          }
        }
      }
    }
    // A channel pick must not first apply the stored master curve.
    var masterChanged=curves();masterChanged.rgb.curve = .init(points:[.init(x:0,y:0.1),.init(x:1,y:0.8)])
    XCTAssertEqual(try result(masterChanged,pixel,.red,.black).red,try result(curves(),pixel,.red,.black).red)
  }
  func testPureInvalidPixelsAndCollapsedRangesNeverProduceCommands()throws {
    let c=curves()
    for pixel in [SIMD4<Float>]([.init(.nan,0.2,0.3,1),.init(.infinity,0.2,0.3,1),.init(-.infinity,0.2,0.3,1),.init(0.2,0.3,0.4,.nan),.init(0.2,0.3,0.4,.infinity),
      .init(0.2,0.3,0.4,-0.1),.init(0.2,0.3,0.4,1.1),.init(-0.1,0.3,0.4,1),.init(1.1,0.3,0.4,1),
      .init(Float.greatestFiniteMagnitude,0.2,0.3,Float.leastNonzeroMagnitude)]) {
      XCTAssertThrowsError(try result(c,pixel,.red,.black))
    }
    XCTAssertThrowsError(try result(c,.zero,.red,.black)){XCTAssertEqual($0 as? DevelopmentAnalysisError,.noVisibleSamples)}
    // A nonselected finite HDR channel is not spuriously rejected or sRGB-clamped.
    XCTAssertNoThrow(try result(c,.init(0.2,1.8,0.4,1),.red,.black))
    XCTAssertNoThrow(try result(c,.init(0.2,0.3,1.2,1),.rgb,.black))
    var collapsed=c;collapsed.red.inputBlack=0.8;collapsed.red.inputWhite=0.8000000000000001
    XCTAssertNoThrow(try collapsed.validate());XCTAssertThrowsError(try result(collapsed,.init(0.2,0.3,0.4,1),.red,.black))
    var otherCollapsed=c;otherCollapsed.green=collapsed.red
    XCTAssertThrowsError(try result(otherCollapsed,.init(0.2,0.3,0.4,1),.red,.black)) // full group table validation
  }
  func testPureEndpointNearPointLimitAndNaturalOvershootRules()throws {
    let base=DevelopmentCurvesV3(enabled:true,algorithm:.naturalCubicGamma512LumaV1)
    for v in [Float(0),Float(1)] {for point in [DevelopmentCurvePickerPointV3.midtone,.addPoint] {
      XCTAssertThrowsError(try result(base,.init(v,0.3,0.4,1),.red,point))
    }}
    XCTAssertThrowsError(try result(base,.init(1,0.3,0.4,1),.red,.black))
    XCTAssertThrowsError(try result(base,.init(0,0.3,0.4,1),.red,.white))
    var full=base;full.red.curve = .init(points:(0..<16).map{.init(x:Double($0)/15,y:Double($0)/15)})
    let existing:Float=Float(7.0/15.0),encoded=Darwin.powf(existing,Float(2.2))
    let replaced=try result(full,.init(encoded,0.3,0.4,1),.red,.midtone)
    XCTAssertEqual(replaced.red.curve.points.count,16)
    XCTAssertEqual(replaced.red.curve.points[7].y,0.5)
    XCTAssertThrowsError(try result(full,.init(Darwin.powf(0.5,Float(2.2)),0.3,0.4,1),.red,.addPoint))
    var overshoot=base;overshoot.red.curve = .init(points:[.init(x:0,y:0),.init(x:0.1,y:1),.init(x:1,y:1)])
    XCTAssertGreaterThan(try E.evaluate(E.model(overshoot.red.curve),0.5),1)
    XCTAssertThrowsError(try result(overshoot,.init(Darwin.powf(0.5,Float(2.2)),0.3,0.4,1),.red,.addPoint))
    overshoot.red.curve = .init(points:[.init(x:0,y:0),.init(x:0.9,y:0),.init(x:1,y:1)])
    XCTAssertLessThan(try E.evaluate(E.model(overshoot.red.curve),0.5),0)
    XCTAssertThrowsError(try result(overshoot,.init(Darwin.powf(0.5,Float(2.2)),0.3,0.4,1),.red,.addPoint))
  }
  func testPureAdmissionMatchesActiveSuffixAndAllowsZeroDisabledAndUpstream()throws {
    let base=DevelopmentAdjustmentsV3(curves:curves())
    var variants:[DevelopmentAdjustmentsV3]=[]
    func add(_ edit:(inout DevelopmentAdjustmentsV3)->Void){var p=base;edit(&p);variants.append(p)}
    add{$0.levels = .init(enabled:true,rgb:.manual(.init(black:0.1,shadows:0.25,midtones:0.5,highlights:0.75,white:0.9,outputBlack:0,outputWhite:1)))}
    add{$0.definition = .init(enabled:true,amount:0.2)}
    add{$0.selectiveColor.enabled=true;$0.selectiveColor.colors[0].saturation=20}
    add{$0.noiseReduction = .init(enabled:true,sourceCapability:.image,nonRawAmount:0.2)}
    add{$0.sharpen.enabled=true;$0.sharpen.intensity=0.2}
    add{$0.vignette.enabled=true;$0.vignette.strength=0.2}
    add{$0.filter = .init(enabled:true,selection:.vivid,intensity:20)}
    for band in [0,1,2] {add{p in
      if band==0{p.advancedDetail.texture = .init(enabled:true,amount:20)}
      else if band==1{p.advancedDetail.clarity = .init(enabled:true,amount:20)}
      else{p.advancedDetail.dehaze = .init(enabled:true,amount:20)}
    }}
    let source=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:16,orientedHeight:12)
    add{$0.localEdits = .init(sourceBinding:source,redEyeEnabled:true,operations:[.init(sourceContentID:source.sourceContentID,tool:.redEye,
      stroke:.init(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:0.1,strength:0.5))])}
    for var p in variants {
      XCTAssertFalse(P.supports(p,sourceIsRAW:false))
      p.levels.enabled=false;p.definition.enabled=false;p.selectiveColor.enabled=false;p.noiseReduction.enabled=false
      p.sharpen.enabled=false;p.vignette.enabled=false;p.filter.enabled=false
      p.advancedDetail.texture.enabled=false;p.advancedDetail.clarity.enabled=false;p.advancedDetail.dehaze.enabled=false
      p.localEdits.redEyeEnabled=false;p.localEdits.retouchEnabled=false
      XCTAssertTrue(P.supports(p,sourceIsRAW:false))
    }
    var zero=base;zero.levels.enabled=true;zero.definition.enabled=true;zero.selectiveColor.enabled=true
    zero.noiseReduction = .init(enabled:true,sourceCapability:.image);zero.sharpen.enabled=true;zero.vignette.enabled=true
    zero.filter = .init(enabled:true,selection:.vivid,intensity:0)
    zero.advancedDetail.texture.enabled=true;zero.advancedDetail.clarity.enabled=true;zero.advancedDetail.dehaze.enabled=true
    zero.localEdits=variants.last!.localEdits;zero.localEdits.operations[0].stroke.strength=0
    XCTAssertTrue(P.supports(zero,sourceIsRAW:false))
    zero.localEdits.operations[0].stroke.strength=0.5;zero.localEdits.operations[0].stroke.points[0].pressure=0
    XCTAssertTrue(P.supports(zero,sourceIsRAW:false))
    var upstream=base;upstream.light = .init(enabled:true,exposure:0.2,brightness:0.1)
    upstream.color = .init(enabled:true,saturation:0.3);upstream.blackAndWhite.enabled=true
    upstream.whiteBalance = .init(enabled:true,adjustment:.temperatureTint(temperature:5600,tint:12))
    upstream.legacyBasis = .init(version:.v1,exposureEV:0.25)
    upstream.geometry = .init(clockwiseQuarterTurns:1,flipHorizontal:true)
    upstream.noiseReduction = .init(enabled:true,sourceCapability:.raw,luminanceNoise:0.2,colorNoise:0.3,detail:1)
    XCTAssertTrue(P.supports(upstream,sourceIsRAW:true));XCTAssertFalse(P.supports(upstream,sourceIsRAW:false))
  }
  func testTinyActualPrecurveSamplePreservesUpstreamAndSourceCoordinates()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("natural-picker-tiny-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer{try? FileManager.default.removeItem(at:root)}
    let width=16,height=12;var bytes=[UInt8]()
    for y in 0..<height {for x in 0..<width {bytes += [UInt8(40+x*8),UInt8(30+y*10),UInt8(20+x*3+y*4),255]}}
    let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
    let cg=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
      space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:.init(rawValue:CGImageAlphaInfo.last.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let url=root.appendingPathComponent("asymmetric.png"),writer=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(writer,cg,nil);XCTAssertTrue(CGImageDestinationFinalize(writer))
    let source=DevelopmentLocalEditSourceBinding(sourceContentID:try RenderFiles.hash(url),exifOrientation:1,orientedWidth:width,orientedHeight:height)
    var parameters=DevelopmentAdjustmentsV3(curves:curves(enabled:false),geometry:.init(crop:.init(x:0.1,y:0.1,width:0.8,height:0.8),clockwiseQuarterTurns:1,flipHorizontal:true))
    parameters.light = .init(enabled:true,exposure:0.1,blackPoint:0.2)
    let recipe=DevelopmentRecipe(adjustmentsV3:parameters),fp=try EditingFingerprint.of(recipe)
    let sx=3,sy=8,point=DevelopmentSourcePoint(x:(Double(sx)+0.5)/Double(width),y:(Double(sy)+0.5)/Double(height))
    let request=DevelopmentAnalysisRequest(preview:.init(sessionID:.init(),sourceGeneration:7,consumerID:.init(),role:.primary,revision:1,
      recipe:recipe,quality:.settled,viewport:.init(maxPixel:2400)),expectedRecipeFingerprint:fp,stage:.workingImageBeforeGeometry,
      operation:.curvePicker(channel:.red,point:.black,sourcePoint:point))
    var cache:DevelopmentAnalysisCacheEntry?
    let output=try DevelopmentAnalysisEngine.run(capture:url,request:request,sourceBinding:source,memoryHint:512,cache:&cache)
    XCTAssertNil(cache);XCTAssertEqual(output.samplingVersion,P.samplingVersion);XCTAssertEqual(output.samplingRecipeFingerprint,fp)
    XCTAssertEqual(output.actualRecipe,recipe);XCTAssertEqual(output.geometryMapping,try parameters.geometry.mapping(sourceSize:source.sourceSize))
    guard case .resolved(let command)=output.value,command.parameters.count==1,case .curves(let changed)=command.parameters[0] else {return XCTFail("Expected one natural command")}
    let sourceLinear=Float(DevelopmentColorEngineV2.decode(Double(bytes[(sy*width+sx)*4])/255))
    let exposed=sourceLinear*Darwin.powf(2,0.2),precurve=(exposed-0.01)/0.99
    let expected=Darwin.powf(precurve,Float(1.0/2.2))
    XCTAssertEqual(changed.red.inputBlack,Double(expected),accuracy:3e-4)
    XCTAssertGreaterThan(abs(changed.red.inputBlack-Double(Darwin.powf(sourceLinear,Float(1.0/2.2)))),0.002)
    XCTAssertEqual(changed.green,parameters.curves.green);XCTAssertEqual(changed.rgb,parameters.curves.rgb)
    XCTAssertTrue(P.acceptsCommand(command,request:request));XCTAssertTrue(changed.enabled)
    // Explicitly neutral/disabled natural metadata must still stop at V3, never exact-legacy.
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    defer{context.clearCaches()}
    let neutral=DevelopmentRecipe(adjustmentsV3:.init(curves:.init(algorithm:.naturalCubicGamma512LumaV1),geometry:.init(version:.legacyV1)))
    let prefix=try DevelopmentRendererV3.develop(url,recipe:neutral,applyGeometry:false,context:context,preparingNaturalCurvePicker:true)
    XCTAssertTrue(prefix.graphDescriptor.hasSuffix("/"+P.samplingVersion));XCTAssertFalse(prefix.graphDescriptor.contains("exact-legacy"))
    XCTAssertEqual(prefix.sourceSize,CGSize(width:width,height:height));XCTAssertEqual(prefix.image.extent.size,prefix.sourceSize)
    var cancelCalls=0
    XCTAssertThrowsError(try P.sample(prefix.image,position:point,context:context,checkCancellation:{cancelCalls+=1;if cancelCalls==2{throw CancellationError()}}))
    XCTAssertEqual(cancelCalls,2) // cancellation observed after the checked read has joined
  }
}
