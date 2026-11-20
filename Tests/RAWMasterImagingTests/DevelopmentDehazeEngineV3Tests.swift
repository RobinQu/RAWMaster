import Foundation
import AppKit
import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentDehazeEngineV3Tests:XCTestCase {
  private let context=DevelopmentColorEngineV3.context
  private let air=DevelopmentDehazeAirlightV1(red:1,green:1,blue:1)
  private func image(_ p:[SIMD4<Float>],width:Int,height:Int)->CIImage {
    .init(bitmapData:p.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage)throws->[SIMD4<Float>] {
    var result=[SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(image,rect:image.extent,context:context){result=Array($0)};return result
  }
  private func parameters(_ amount:Double,enabled:Bool=true,size:DevelopmentPixelSize = .init(width:16,height:16),algorithmVersion:Int=1)->DevelopmentAdvancedDetailV3 {
    .init(dehaze:.init(enabled:enabled,amount:amount),preparedDehaze:.init(sourceBinding:.init(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:size.width,orientedHeight:size.height),inputFingerprint:String(repeating:"b",count:64),airlight:air,algorithmVersion:algorithmVersion))
  }
  func testOffZeroExactBypassDoesNotNeedPreparation()throws {
    let input=image([.init(0.2,0.3,0.4,0.5)],width:1,height:1)
    for p in [DevelopmentAdvancedDetailV3(),.init(dehaze:.init(enabled:true,amount:0)),.init(dehaze:.init(enabled:false,amount:100))] {
      XCTAssertTrue(try DevelopmentDehazeEngineV3.apply(p,to:input,sourceSize:.init(width:1,height:1),context:context) === input)
    }
    XCTAssertThrowsError(try DevelopmentDehazeEngineV3.apply(.init(dehaze:.init(enabled:true,amount:1)),to:input,sourceSize:.init(width:1,height:1),context:context))
  }
  func testFixedTransmissionCPUHasSignedDirectionHDRNoClampAndLowAlphaPolicy()throws {
    let p=SIMD4<Double>(0.4,0.5,2,1)
    let positive=try DevelopmentDehazeEngineV3.referencePixel(p,airlight:air,dark:1,amount:100)
    let negative=try DevelopmentDehazeEngineV3.referencePixel(p,airlight:air,dark:1,amount:-100)
    XCTAssertEqual(positive.x,-2,accuracy:1e-12);XCTAssertEqual(positive.z,6,accuracy:1e-12)
    XCTAssertGreaterThan(negative.x,p.x);XCTAssertLessThan(negative.z,p.z)
    for alpha in [0.0,1e-8,0.5/65535] {
      let tiny=SIMD4<Double>(0.9,0.3,-0.4,alpha)
      XCTAssertEqual(try DevelopmentDehazeEngineV3.referencePixel(tiny,airlight:air,dark:0.8,amount:75),tiny)
    }
    XCTAssertThrowsError(try DevelopmentDehazeEngineV3.referencePixel(.init(.nan,0,0,0),airlight:air,dark:0.5,amount:50))
    XCTAssertThrowsError(try DevelopmentDehazeEngineV3.referencePixel(.init(0,0,0,-0.1),airlight:air,dark:0.5,amount:50))
  }
  func testActualKernelMatchesDoubleFormulaAlphaHDRAndOriginalTinyAlpha()throws {
    let row:[SIMD4<Float>]=[.init(0.2,0.3,0.4,1),.init(0.1,0.15,0.2,0.5),.init(2,-0.25,4,1),
      .init(0.4,0.2,0.3,0),.init(1e-8,2e-8,-1e-8,1e-8),.init(0.2,0.3,0.4,0.000001)]
    let input=image(row+row,width:row.count,height:2),source=try read(input)
    // Explicit linear F32 guide: CIColor(.7) is encoded sRGB and would decode to .447988.
    let guide=image(Array(repeating:SIMD4<Float>(0.7,0,0,1),count:row.count*2),width:row.count,height:2)
    for amount in [-100.0,25,100] {
      let actual=try read(DevelopmentDehazeEngineV3.applyGuide(to:input,guide:guide,airlight:air,amount:amount))
      for i in actual.indices {
        let p=source[i],d=SIMD4<Double>(Double(p.x),Double(p.y),Double(p.z),Double(p.w))
        let expected=try DevelopmentDehazeEngineV3.referencePixel(d,airlight:air,dark:Double(Float(0.7)),amount:amount)
        for c in 0..<3 { XCTAssertEqual(Double(actual[i][c]),expected[c],accuracy:3e-5) }
        XCTAssertEqual(actual[i].w.bitPattern,p.w.bitPattern)
        if p.w<1.0/65535 { XCTAssertEqual(actual[i],p) }
      }
    }
  }
  func testGuideIgnoresInvisibleAsNeutralAndRejectsNonfiniteBeforeBypass()throws {
    let row:[SIMD4<Float>]=[.init(0.4,0.5,0.6,1),.init(0.1,0.2,0.3,0),.init(0.001,0.002,0.003,1e-8),.init(-0.1,2,3,1)]
    let actual=try read(DevelopmentDehazeEngineV3.makeGuide(image(row,width:4,height:1),airlight:air))
    XCTAssertEqual(actual[0].x,0.4,accuracy:1e-6);XCTAssertEqual(actual[1].x,1);XCTAssertEqual(actual[2].x,1);XCTAssertEqual(actual[3].x,0)
    for invalid in [SIMD4<Float>(.nan,0,0,0),.init(.infinity,0,0,0),.init(0,0,0,-0.1),.init(0,0,0,1.1)] {
      XCTAssertThrowsError(try DevelopmentDehazeEngineV3.apply(parameters(50,size:.init(width:1,height:1)),to:image([invalid],width:1,height:1),sourceSize:.init(width:1,height:1),context:context)) {
        if case DevelopmentError.invalidEncoding=$0 {} else { XCTFail("Expected finite/domain rejection, got \($0)") }
      }
    }
  }
  func testActualPositiveV2ChangesOnlyItsSignedRouteAndRetainsAlphaHDR() throws {
    let size=DevelopmentPixelSize(width:16,height:16)
    let row:[SIMD4<Float>]=[.zero,.init(0,0,0,1e-8),.init(0.25,0.375,0.625,0.5),.init(-0.25,0.7,1.6,1)]
    let input=image((0..<256).map{row[$0%row.count]},width:16,height:16)
    let actualInput=try read(input)
    func output(_ amount:Double,_ algorithm:Int) throws -> CIImage {
      try DevelopmentDehazeEngineV3.apply(parameters(amount,size:size,algorithmVersion:algorithm),to:input,sourceSize:size,context:context)
    }
    XCTAssertTrue(try output(0,2) === input)
    XCTAssertEqual(try read(output(-25,2)),try read(output(-25,1)))
    let positive=try read(output(25,2))
    XCTAssertNotEqual(positive,try read(output(25,1)))
    XCTAssertEqual(positive.map{$0.w.bitPattern},actualInput.map{$0.w.bitPattern})
    XCTAssertTrue(positive.contains{$0.x<0 && $0.z>1},"Negative and extended RGB remain representable")
    for i in positive.indices where actualInput[i].w<1.0/65535 { XCTAssertEqual(positive[i],actualInput[i]) }
    for invalid in [SIMD4<Float>(.nan,0,0,0),.init(.infinity,0,0,1),.init(0,0,0,-0.125),.init(0,0,0,1.125)] {
      let invalidImage=image([invalid],width:1,height:1)
      XCTAssertThrowsError(try DevelopmentDehazeEngineV3.apply(parameters(25,size:.init(width:1,height:1),algorithmVersion:2),
        to:invalidImage,sourceSize:.init(width:1,height:1),context:context)) {
        if case DevelopmentError.invalidEncoding=$0 {} else { XCTFail("Expected original strict validation") }
      }
    }
  }
  func testNativeGuideRadiusExtentsUniformFormulaAndSizeAuthority()throws {
    let input=image(Array(repeating:SIMD4<Float>(0.4,0.6,0.8,1),count:16*16),width:16,height:16)
    let output=try DevelopmentDehazeEngineV3.apply(parameters(50),to:input,sourceSize:.init(width:16,height:16),context:context)
    let actual=try read(output)
    let expected=try DevelopmentDehazeEngineV3.referencePixel(.init(0.4,0.6,0.8,1),airlight:air,dark:0.4,amount:50)
    for pixel in actual { for c in 0..<3 { XCTAssertEqual(Double(pixel[c]),expected[c],accuracy:3e-5) };XCTAssertEqual(pixel.w,1) }
    XCTAssertEqual(output.extent,input.extent)
    XCTAssertThrowsError(try DevelopmentDehazeEngineV3.apply(parameters(50),to:input,sourceSize:.init(width:9504,height:6336),context:context))
  }

  private func rgbaBits(_ pixels:[SIMD4<Float>])->[UInt32] {
    pixels.flatMap { pixel in (0..<4).map { pixel[$0].bitPattern } }
  }
  /// A bounded F32 observation without the finite gate, used only to prove malformed fixtures.
  private func uncheckedRead(_ image:CIImage)throws->[SIMD4<Float>] {
    let width=Int(image.extent.width),height=Int(image.extent.height)
    var pixels=[SIMD4<Float>](repeating:.init(repeating:12345),count:width*height)
    try pixels.withUnsafeMutableBytes { bytes in
      let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:width,height:height,bytesPerRow:width*16,format:.RGBAf)
      destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
      destination.isClamped=false;destination.isDithered=false;destination.isFlipped=true
      let task=try context.startTask(toRender:image,from:image.extent,to:destination,at:.zero)
      do { _=try task.waitUntilCompleted() }
      catch { let primary=error;_=try? task.waitUntilCompleted();throw primary }
    }
    return pixels
  }
  func testRAWPositiveV2CoverageMatchesIndependentF32Projection()throws {
    let size=DevelopmentPixelSize(width:16,height:16)
    // Multiples of these finite alpha values have exactly representable quotients.
    let alphas:[Float]=[Float(1).nextUp,Float(bitPattern:1065353219),1.125]
    let upper=alphas.map { SIMD4<Float>(-0.25*$0,2*$0,4*$0,$0) }
    let row:[SIMD4<Float>]=[.zero,.init(0,0,0,1e-8),.init(0.125,0.25,0.375,0.5),.init(-0.25,2,4,1)]+upper+[.init(0.25,0.5,0.75,1)]
    let original=(0..<256).map { row[$0%row.count] }
    let input=image(original,width:16,height:16),observed=try read(input)
    XCTAssertEqual(rgbaBits(observed),rgbaBits(original),"The actual fixture must retain the witnessed upper alpha bits")
    // This CPU reference does not call either product normalization helper.
    let expected=observed.map { p -> SIMD4<Float> in
      p.w>1 ? .init(p.x/p.w,p.y/p.w,p.z/p.w,1):p
    }
    for i in expected.indices where observed[i].w>1 {
      XCTAssertEqual(expected[i],.init(-0.25,2,4,1))
    }
    let normalized=try PreviewFITCoverageV1.normalize(input,extent:input.extent)
    XCTAssertEqual(rgbaBits(try read(normalized)),rgbaBits(expected),"All four F32 channels must match the independent projection")
    let controlInput=image(expected,width:16,height:16)
    let controlGuide=try DevelopmentDehazeColorGuideV2.guide(controlInput,airlight:air,sourceSize:size)
    let control=try DevelopmentDehazeColorGuideV2.restore(controlInput,guide:controlGuide,airlight:air,amount:25)
    let actual=try DevelopmentDehazeEngineV3.apply(parameters(25,size:size,algorithmVersion:2),to:input,
      sourceSize:size,sourceIsRAW:true,context:context)
    XCTAssertEqual(actual.extent,input.extent)
    let output=try read(actual)
    XCTAssertEqual(rgbaBits(output),rgbaBits(try read(control)),"The unchanged guide and restore must both consume the projected image")
    XCTAssertEqual(output.map{$0.w.bitPattern},expected.map{$0.w.bitPattern})
    XCTAssertTrue(output.contains{$0.x<0 && $0.z>1},"Extended and negative RGB remain representable")
    XCTAssertTrue(output.allSatisfy{p in (0..<4).allSatisfy{p[$0].isFinite}})
  }
  func testRAWPositiveV2KeepsLegalBytesAndStrictSourceDomain()throws {
    let size=DevelopmentPixelSize(width:16,height:16)
    let row:[SIMD4<Float>]=[.init(0.25,0.5,-0.125,0),.init(1e-8,2e-8,-1e-8,1e-8),.init(0.125,0.25,0.375,0.5),.init(-0.25,2,4,1)]
    let input=image((0..<256).map{row[$0%row.count]},width:16,height:16)
    let originalGuide=try DevelopmentDehazeColorGuideV2.guide(input,airlight:air,sourceSize:size)
    let original=try DevelopmentDehazeColorGuideV2.restore(input,guide:originalGuide,airlight:air,amount:25)
    let raw=try DevelopmentDehazeEngineV3.apply(parameters(25,size:size,algorithmVersion:2),to:input,
      sourceSize:size,sourceIsRAW:true,context:context)
    XCTAssertEqual(rgbaBits(try read(raw)),rgbaBits(try read(original)),"Legal alpha/RGB must retain the original v2 bytes")
    func rejects(_ operation:()throws->CIImage,file:StaticString=#filePath,line:UInt=#line) {
      do { _=try operation();XCTFail("Expected original strict rejection",file:file,line:line) }
      catch DevelopmentError.invalidEncoding {}
      catch { XCTFail("Expected invalidEncoding, received \(error)",file:file,line:line) }
    }
    let one=DevelopmentPixelSize(width:1,height:1)
    let upper=image([.init(-0.28125,2.25,4.5,1.125)],width:1,height:1)
    rejects { try DevelopmentDehazeEngineV3.apply(parameters(25,size:one,algorithmVersion:2),to:upper,sourceSize:one,context:context) }
    for (algorithm,amount,isRAW) in [(1,25.0,true),(2,-25.0,true),(2,25.0,false)] {
      rejects { try DevelopmentDehazeEngineV3.apply(parameters(amount,size:one,algorithmVersion:algorithm),to:upper,
        sourceSize:one,sourceIsRAW:isRAW,context:context) }
    }
    for p in [parameters(0,size:one,algorithmVersion:2),parameters(25,enabled:false,size:one,algorithmVersion:2)] {
      XCTAssertTrue(try DevelopmentDehazeEngineV3.apply(p,to:upper,sourceSize:one,sourceIsRAW:true,context:context) === upper)
    }
    let malformed:[(SIMD4<Float>,(SIMD4<Float>)->Bool)]=[
      (.init(0,0,0,-0.125),{$0.w.bitPattern == Float(-0.125).bitPattern}),
      (.init(0,0,0,.nan),{$0.w.isNaN}),
      (.init(0,0,0,.infinity),{$0.w == .infinity}),
      (.init(.nan,0,0,1.125),{$0.x.isNaN && $0.w == 1.125}),
      (.init(0,-.infinity,0,1.125),{$0.y == -.infinity && $0.w == 1.125})
    ]
    for (pixel,isMalformed) in malformed {
      let invalid=image([pixel],width:1,height:1)
      let before=try uncheckedRead(invalid)
      guard before.count==1,isMalformed(before[0]) else { return XCTFail("The invalid F32 fixture was not actually observable") }
      let after=try uncheckedRead(PreviewFITCoverageV1.normalize(invalid,extent:invalid.extent))
      XCTAssertEqual(after.count,1);XCTAssertTrue(isMalformed(after[0]),"The helper must not repair invalid values")
      for isRAW in [false,true] {
        rejects { try DevelopmentDehazeEngineV3.apply(parameters(25,size:one,algorithmVersion:2),to:invalid,
          sourceSize:one,sourceIsRAW:isRAW,context:context) }
      }
    }
    let cancellation=DevelopmentAnalysisCancellation();cancellation.cancel()
    XCTAssertThrowsError(try DevelopmentDehazeEngineV3.apply(parameters(25,size:size,algorithmVersion:2),to:input,
      sourceSize:size,sourceIsRAW:true,context:context,checkCancellation:{try cancellation.check()}))
  }
  func testRAWPositiveV2RenderAndBitmapSuffixKeepsPreparedRecipeIdentity()throws {
    let p=parameters(25,algorithmVersion:2)
    var recipe=DevelopmentRecipe(adjustmentsV3:.init());recipe.adjustmentsV3!.advancedDetail=p
    let fingerprint=try EditingFingerprint.of(recipe),prepared=recipe.adjustmentsV3!.advancedDetail.preparedDehaze
    let suffix=DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(p,sourceIsRAW:true)
    XCTAssertEqual(suffix,"/raw-positive-v2/native-upper-coverage-v1/"+PreviewFITCoverageV1.version)
    XCTAssertFalse(suffix.isEmpty)
    XCTAssertEqual(DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(parameters(50,algorithmVersion:2),sourceIsRAW:true),suffix)
    XCTAssertEqual(DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(parameters(-25,algorithmVersion:2),sourceIsRAW:true),
      "/"+DevelopmentDehazeRAWCoverageV1.version)
    for (value,isRAW) in [(p,false),(parameters(-25,algorithmVersion:2),false),
      (parameters(0,algorithmVersion:2),true),(parameters(25,enabled:false,algorithmVersion:2),true)] {
      XCTAssertEqual(DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(value,sourceIsRAW:isRAW),"")
    }
    XCTAssertEqual(DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(nil,sourceIsRAW:true),"")
    XCTAssertEqual(try EditingFingerprint.of(recipe),fingerprint)
    XCTAssertEqual(recipe.adjustmentsV3!.advancedDetail.preparedDehaze,prepared)
    XCTAssertEqual(prepared?.algorithmVersion,2)
  }
  func testRAWV1BoundedCoverageUsesIndependentProjectionForBothSigns()throws {
    let size=DevelopmentPixelSize(width:16,height:16)
    let alphas:[Float]=[Float(1).nextUp,Float(bitPattern:1065353218),Float(bitPattern:1065353219)]
    let row:[SIMD4<Float>]=[.zero,.init(0.125,0.25,0.375,0.5),.init(-0.25,2,4,1)] +
      alphas.map{SIMD4<Float>(-0.25*$0,2*$0,4*$0,$0)}
    let original=(0..<256).map{row[$0%row.count]},input=image(original,width:16,height:16)
    let observed=try read(input)
    XCTAssertEqual(rgbaBits(observed),rgbaBits(original),"Fixture must retain actual upper F32 values")
    // Independent CPU projection: neither product normalizer is used by this expectation.
    let expected=observed.map{p -> SIMD4<Float> in p.w>1 ? .init(p.x/p.w,p.y/p.w,p.z/p.w,1):p}
    XCTAssertEqual(rgbaBits(try read(DevelopmentDehazeRAWCoverageV1.normalize(input))),rgbaBits(expected))
    let control=image(expected,width:16,height:16)
    for amount in [-100.0,-25,25,100] {
      let p=parameters(amount,size:size)
      let actual=try DevelopmentDehazeEngineV3.apply(p,to:input,sourceSize:size,sourceIsRAW:true,context:context)
      let oldValid=try DevelopmentDehazeEngineV3.apply(p,to:control,sourceSize:size,sourceIsRAW:false,context:context)
      XCTAssertEqual(rgbaBits(try read(actual)),rgbaBits(try read(oldValid)),"Original v1 guide AND restore consume the projected image")
    }
  }
  func testRAWV1LegalBytesSourceFenceInvalidAndCancelRemainStrict()throws {
    let size=DevelopmentPixelSize(width:16,height:16)
    let row:[SIMD4<Float>]=[.zero,.init(0.25,0.5,-0.125,0),.init(0.125,0.25,0.375,0.5),.init(-0.25,2,4,1)]
    let input=image((0..<256).map{row[$0%row.count]},width:16,height:16)
    for amount in [-100.0,-25,25,100] {
      let p=parameters(amount,size:size)
      let actual=try DevelopmentDehazeEngineV3.apply(p,to:input,sourceSize:size,sourceIsRAW:true,context:context)
      let old=try DevelopmentDehazeEngineV3.apply(p,to:input,sourceSize:size,sourceIsRAW:false,context:context)
      XCTAssertEqual(rgbaBits(try read(actual)),rgbaBits(try read(old)),"Legal alpha has original v1 bytes")
    }
    let one=DevelopmentPixelSize(width:1,height:1)
    for pixel in [SIMD4<Float>(1,2,3,Float(bitPattern:1065353220)),.init(1,2,3,1.125),
      .init(1,2,3,-0.125),.init(.nan,2,3,1),.init(1,2,3,.infinity)] {
      let bad=image([pixel],width:1,height:1)
      for amount in [-100.0,100] {
        XCTAssertThrowsError(try DevelopmentDehazeEngineV3.apply(parameters(amount,size:one),to:bad,sourceSize:one,sourceIsRAW:true,context:context))
      }
    }
    let a=Float(bitPattern:1065353219),upper=image([.init(a,2*a,4*a,a)],width:1,height:1)
    for amount in [-25.0,25] {
      XCTAssertThrowsError(try DevelopmentDehazeEngineV3.apply(parameters(amount,size:one),to:upper,sourceSize:one,sourceIsRAW:false,context:context))
    }
    for p in [parameters(0,size:one),parameters(25,enabled:false,size:one)] {
      XCTAssertTrue(try DevelopmentDehazeEngineV3.apply(p,to:upper,sourceSize:one,sourceIsRAW:true,context:context) === upper)
    }
    let cancellation=DevelopmentAnalysisCancellation();cancellation.cancel()
    XCTAssertThrowsError(try DevelopmentDehazeEngineV3.apply(parameters(25,size:size),to:input,sourceSize:size,sourceIsRAW:true,context:context,checkCancellation:{try cancellation.check()}))
  }
  func testRAWV1RenderAndBitmapIdentitySeparateWithoutRecipeMutation()throws {
    for amount in [-100.0,-25,25,100] {
      let p=parameters(amount),suffix=DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(p,sourceIsRAW:true)
      XCTAssertEqual(suffix,"/"+DevelopmentDehazeRAWCoverageV1.version)
      XCTAssertEqual(DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(p,sourceIsRAW:false),"")
      var r=DevelopmentRecipe(adjustmentsV3:.init());r.adjustmentsV3!.advancedDetail=p
      let before=try EditingFingerprint.of(r),prepared=r.adjustmentsV3!.advancedDetail.preparedDehaze
      _=DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(p,sourceIsRAW:true)
      XCTAssertEqual(try EditingFingerprint.of(r),before);XCTAssertEqual(r.adjustmentsV3!.advancedDetail.preparedDehaze,prepared)
    }
  }

  func testOwnedV1DehazeContextAdmissionKeepsOtherRoutes() {
    for amount in [-100.0,-25,25,100] {
      let recipe=DevelopmentRecipe(adjustmentsV3:.init(advancedDetail:parameters(amount)))
      XCTAssertTrue(PreviewNativeSource.usesOwnedV1DehazeContexts(recipe,sourceIsRAW:true))
      XCTAssertFalse(PreviewNativeSource.usesOwnedV1DehazeContexts(recipe,sourceIsRAW:false))
      let v2=DevelopmentRecipe(adjustmentsV3:.init(advancedDetail:parameters(amount,algorithmVersion:2)))
      XCTAssertFalse(PreviewNativeSource.usesOwnedV1DehazeContexts(v2,sourceIsRAW:true))
    }
    for p in [parameters(0),parameters(25,enabled:false),DevelopmentAdvancedDetailV3(dehaze:.init(enabled:true,amount:25))] {
      XCTAssertFalse(PreviewNativeSource.usesOwnedV1DehazeContexts(DevelopmentRecipe(adjustmentsV3:.init(advancedDetail:p)),sourceIsRAW:true))
    }
    XCTAssertFalse(PreviewNativeSource.usesOwnedV1DehazeContexts(DevelopmentRecipe(),sourceIsRAW:true))
  }
  func testOwnedCanonicalContextRetiresAfterRealJoinAndOriginalFailure()throws {
    let input=image(Array(repeating:SIMD4<Float>(0.25,0.5,0.75,1),count:16*16),width:16,height:16)
    weak var completed:CIContext?
    let result=try PreviewNativeSource.withOwnedV3Context(memoryLimit:32) { owned in
      completed=owned
      try DevelopmentColorEngineV3.validateFinite(input,context:owned)
      return input
    }
    XCTAssertTrue(result === input);XCTAssertNil(completed)
    enum Injected:Error {case afterJoinedTask}
    weak var failed:CIContext?
    XCTAssertThrowsError(try PreviewNativeSource.withOwnedV3Context(memoryLimit:32) { owned -> Void in
      failed=owned
      try DevelopmentColorEngineV3.validateFinite(input,context:owned)
      throw Injected.afterJoinedTask
    }) { error in
      guard case Injected.afterJoinedTask=error else{return XCTFail("Original error changed: \(error)")}
    }
    XCTAssertNil(failed)
    weak var cancelled:CIContext?
    XCTAssertThrowsError(try PreviewNativeSource.withOwnedV3Context(memoryLimit:32) { owned -> Void in
      cancelled=owned
      try DevelopmentColorEngineV3.validateFinite(input,context:owned)
      throw CancellationError()
    }) {XCTAssertTrue($0 is CancellationError)}
    XCTAssertNil(cancelled)
    // A body that tries to escape its context cannot be accepted as a retired owner.
    XCTAssertThrowsError(try PreviewNativeSource.withOwnedV3Context(memoryLimit:32) {$0}) { error in
      guard case PreviewPresentationError.allocationProtocol=error else{return XCTFail("Escaped context admitted")}
    }
  }
  func testSplitCanonicalDehazeContextFITMatchesOriginalSharedContext()throws {
    let width=96,height=64,size=DevelopmentPixelSize(width:96,height:64)
    let input=image((0..<(width*height)).map { i in
      SIMD4<Float>(Float(i%23)/31,Float(i%17)/23,Float(i%11)/17,1)
    },width:width,height:height)
    func graph(_ context:CIContext,_ amount:Double)throws->DevelopedV3Graph {
      let output=try DevelopmentDehazeEngineV3.apply(parameters(amount,size:size),to:input,sourceSize:size,sourceIsRAW:true,context:context)
      return .init(image:output,sourceDepth:nil,sourceSize:input.extent.size,canonicalSize:output.extent.size,graphDescriptor:"same-test-canonical-v1")
    }
    func bytes(_ value:PreviewPixels)throws->Data {
      try autoreleasepool {
        let cg=try XCTUnwrap(value.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
        let bitmap=NSBitmapImageRep(cgImage:cg),pointer=try XCTUnwrap(bitmap.bitmapData)
        XCTAssertEqual(value.outputSize,CGSize(width:cg.width,height:cg.height))
        return Data(bytes:pointer,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
      }
    }
    for amount in [-100.0,-25,25,100] {
      let original=try PreviewNativeSource.withOwnedV3Context(memoryLimit:32) { shared in
        try V3PreviewMaterializer.materialize(graph(shared,amount),context:shared,maxPixel:64)
      }
      let prepared=try PreviewNativeSource.withOwnedV3Context(memoryLimit:32) {try graph($0,amount)}
      let split=try PreviewNativeSource.withOwnedV3Context(memoryLimit:32) {try V3PreviewMaterializer.materialize(prepared,context:$0,maxPixel:64)}
      XCTAssertEqual(original.nativeSize,split.nativeSize);XCTAssertEqual(original.outputSize,split.outputSize)
      XCTAssertEqual(try bytes(original),try bytes(split),"same original FIT bytes at \(amount)")
    }
  }

}
