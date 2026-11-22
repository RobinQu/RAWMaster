import XCTest
import CoreImage
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentSharpeningDetailV3Tests: XCTestCase {
  private let context=DevelopmentColorEngineV3.makeContext()
  private func chart() -> CIImage {
    let width=192,height=96
    let pixels=(0..<(width*height)).map { i -> SIMD4<Float> in
      let x=i%width,y=i/width,a:Float=y<8 ? 0.5:1
      let edge:Float=x<96 ? 0.12:0.55
      let fine=Float(x%4<2 ? 0.018:-0.018)
      return .init((edge+fine)*a,(edge*0.8+fine)*a,(edge*0.6+fine)*a,a)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.init(),count:Int(image.extent.width*image.extent.height))
    context.render(image,toBitmap:&pixels,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func render(_ sharpen:DevelopmentSharpenV3,to input:CIImage)throws->[SIMD4<Float>] {
    read(try DevelopmentGlobalEngineV3.apply(.init(sharpen:sharpen),to:input,sourceIsRAW:false))
  }
  func testLegacyAndExplicitDefaultAdvancedPathRemainDeterministicAndPreserveAlpha() throws {
    let input=chart(),original=read(input)
    let legacy=DevelopmentSharpenV3(enabled:true,intensity:0.8,edges:0.22,falloff:0.69)
    let first=try render(legacy,to:input),second=try render(legacy,to:input)
    XCTAssertEqual(first.map(\.x.bitPattern),second.map(\.x.bitPattern))
    XCTAssertTrue(zip(first,original).contains{$0.0.x != $0.1.x})
    for (a,b) in zip(first,original){XCTAssertEqual(a.w.bitPattern,b.w.bitPattern)}
    let explicit=DevelopmentSharpenV3(enabled:true,intensity:0.8,edges:0.22,falloff:0.69,radius:1,detail:0,masking:0)
    XCTAssertNotEqual(first.map(\.x.bitPattern),try render(explicit,to:input).map(\.x.bitPattern),"Explicit native Radius changes the support even when Detail/Masking are zero")
  }
  func testRadiusDetailAndMaskingEachHaveDistinctRealGPUResponse() throws {
    let input=chart()
    let base=DevelopmentSharpenV3(enabled:true,intensity:0.8,radius:1,detail:0.25,masking:0)
    let baseline=try render(base,to:input)
    var detail=base;detail.detail=0.9
    var masked=base;masked.masking=0.9
    var wide=base;wide.radius=2.8
    for changed in [detail,masked,wide] {
      let actual=try render(changed,to:input)
      XCTAssertTrue(zip(actual,baseline).contains{abs($0.0.x-$0.1.x)>1e-5})
      try DevelopmentColorEngineV3.validateFinite(DevelopmentGlobalEngineV3.apply(.init(sharpen:changed),to:input,sourceIsRAW:false))
    }
    var disabled=base;disabled.enabled=false
    XCTAssertTrue(try DevelopmentGlobalEngineV3.apply(.init(sharpen:disabled),to:input,sourceIsRAW:false) === input)
  }
  func testMaskingPreviewIsFinalGrayscaleAndDoesNotApplySharpening() throws {
    let input=chart(),original=read(input)
    var preview=DevelopmentSharpenV3(enabled:true,intensity:0,radius:1,detail:0.25,masking:0.35,visualiseMasking:true)
    let parameters=DevelopmentAdjustmentsV3(sharpen:preview)
    XCTAssertTrue(try DevelopmentGlobalEngineV3.apply(parameters,to:input,sourceIsRAW:false) === input)
    let actual=read(try DevelopmentGlobalEngineV3.applySharpenMaskPreview(parameters,to:input))
    for (index,pixel) in actual.enumerated() {
      XCTAssertEqual(pixel.x,pixel.y,accuracy:1e-6);XCTAssertEqual(pixel.y,pixel.z,accuracy:1e-6)
      XCTAssertEqual(pixel.w.bitPattern,original[index].w.bitPattern)
    }
    XCTAssertLessThan(actual.map(\.x).min() ?? 1,0.05);XCTAssertGreaterThan(actual.map(\.x).max() ?? 0,0.5)
    preview.masking=0.9
    let moreSelective=read(try DevelopmentGlobalEngineV3.applySharpenMaskPreview(.init(sharpen:preview),to:input))
    XCTAssertNotEqual(actual.map(\.x.bitPattern),moreSelective.map(\.x.bitPattern))
    preview.visualiseMasking=nil
    XCTAssertTrue(try DevelopmentGlobalEngineV3.applySharpenMaskPreview(.init(sharpen:preview),to:input) === input)
  }
  func testSingleChannelMaskPreservesNativeThresholdsAndNonIntegralReduction() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let input = chart()
    let opaque = input.composited(over: CIImage(color:.black).cropped(to:input.extent))
    let response = try DevelopmentGlobalEngineV3.nativeSharpResponse(opaque,radius:1.4,context:context,device:device,check:{})
    let offset = response.transformed(by:.init(translationX:19,y:7))
    let transform = CGAffineTransform(scaleX:0.37,y:0.37)
    let area = CGRect(x:10,y:5,width:45,height:22)
    for threshold in [0.0,0.35,0.9] {
      let sharpen = DevelopmentSharpenV3(enabled:true,radius:1.4,detail:0.65,masking:threshold,visualiseMasking:true)
      let original = try DevelopmentGlobalEngineV3.nativeSharpMask(sharpen,response:offset)
      let scalar = try PreviewNativeSharpMaskScalar.scaled(sharpen,response:offset,transform:transform)
      let expected = read(original.transformed(by:transform).cropped(to:area))
      let actual = read(scalar.cropped(to:area))
      XCTAssertTrue(expected.contains { $0.x > 0.01 })
      XCTAssertTrue(actual.allSatisfy { $0.x.isFinite && $0.x == $0.y && $0.y == $0.z && $0.w == 1 })
      XCTAssertLessThan(zip(expected,actual).map { abs($0.x-$1.x) }.max() ?? 1,0.0001)
    }
  }
  func testOpaqueNativeResponseCanBeReusedAtSeveralMaskingThresholds() throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let input=chart()
    let source=input.composited(over:CIImage(color:.black).cropped(to:input.extent))
    let response=try DevelopmentGlobalEngineV3.nativeSharpResponse(source,radius:1.4,context:context,device:device,check:{})
    var previous:[SIMD4<Float>]?
    for amount in [0.0,0.35,0.8] {
      let settings=DevelopmentSharpenV3(enabled:true,radius:1.4,detail:0.65,masking:amount,visualiseMasking:true)
      let expected=read(try DevelopmentGlobalEngineV3.applySharpenMaskPreview(.init(sharpen:settings),to:source))
      XCTAssertTrue(expected.allSatisfy{$0.w==1})
      let actual=read(try DevelopmentGlobalEngineV3.nativeSharpMask(settings,response:response))
      let maximum=zip(expected,actual).map{abs($0.0.x-$0.1.x)}.max() ?? 1
      XCTAssertLessThan(maximum,1e-4)
      XCTAssertTrue(actual.allSatisfy{$0.w==1})
      if let previous { XCTAssertNotEqual(previous,actual) }
      previous=actual
    }
  }
}
