import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentLensBlurEngineV3Tests:XCTestCase {
  private let context=DevelopmentColorEngineV3.makeContext()
  private let size=CGSize(width:128,height:80)
  private var fixture:CIImage {
    let pixels=(0..<(128*80)).map{i->SIMD4<Float> in
      let x=i%128,y=i/128,a:Float=y<8 ? 0.5:1
      let v=Float((x%8<4 ? 0.2:0.7)+Double(y%3)*0.01)
      return .init(v*a,(0.8-v*0.4)*a,(0.3+v*0.2)*a,a)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:128*16,size:size,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    context.clearCaches()
    var pixels=[SIMD4<Float>](repeating:.zero,count:128*80)
    context.render(image,toBitmap:&pixels,rowBytes:128*16,bounds:.init(origin:.zero,size:size),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  func testFocusStaysSharpWhileDefocusedPixelsBlurAndAlphaIsPreserved()throws {
    let input=fixture,original=read(input)
    let blur=DevelopmentLensBlurV3(enabled:true,amount:0.8,focusX:0.5,focusY:0.5,focusRange:0.15)
    let actual=read(try DevelopmentLensBlurEngineV3.apply(blur,to:input))
    for channel in 0..<3 { XCTAssertEqual(actual[40*128+64][channel],original[40*128+64][channel],accuracy:2e-5) }
    XCTAssertNotEqual(actual.map(\.x.bitPattern),original.map(\.x.bitPattern))
    for i in actual.indices { XCTAssertEqual(actual[i].w.bitPattern,original[i].w.bitPattern) }
    try DevelopmentColorEngineV3.validateFinite(DevelopmentLensBlurEngineV3.apply(blur,to:input),context:context)
  }
  func testAmountFocusAndRangeHaveDistinctResponsesAndZeroBypasses()throws {
    let input=fixture,base=DevelopmentLensBlurV3(enabled:true,amount:0.5,focusRange:0.2)
    let baseline=read(try DevelopmentLensBlurEngineV3.apply(base,to:input))
    for changed in [DevelopmentLensBlurV3(enabled:true,amount:1,focusRange:0.2),
                    .init(enabled:true,amount:0.5,focusX:0.2,focusY:0.4,focusRange:0.2),
                    .init(enabled:true,amount:0.5,focusRange:0.6)] {
      XCTAssertNotEqual(read(try DevelopmentLensBlurEngineV3.apply(changed,to:input)).map(\.x.bitPattern),baseline.map(\.x.bitPattern))
    }
    XCTAssertTrue(try DevelopmentLensBlurEngineV3.apply(nil,to:input) === input)
    XCTAssertTrue(try DevelopmentLensBlurEngineV3.apply(.init(enabled:false),to:input) === input)
    XCTAssertEqual(read(try DevelopmentLensBlurEngineV3.apply(.init(enabled:true,amount:1,focusRange:1),to:input)).map(\.x.bitPattern),read(input).map(\.x.bitPattern))
  }
  func testSameSizeProxyUsesTheSameOperator()throws {
    let input=fixture
    var p=DevelopmentAdjustmentsV3();p.effects = .init(lensBlur:.init(enabled:true,amount:0.7,focusX:0.4,focusY:0.6,focusRange:0.25))
    let direct=try DevelopmentLensBlurEngineV3.apply(p.effects?.lensBlur,to:input)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:input,sourceIsRAW:false,nativeSize:size,scale:1,context:context,check:{})
    let a=read(direct),b=read(proxy)
    for i in a.indices { for c in 0..<4 { XCTAssertEqual(a[i][c],b[i][c],accuracy:5e-5) } }
    XCTAssertTrue(DevelopmentRendererV3.hasNewEffects(p))
  }
  func testDepthPreviewShowsFocusGreenAndDefocusBlueWithoutBlurring()throws {
    let input=fixture,original=read(input)
    let blur=DevelopmentLensBlurV3(enabled:true,amount:0.8,focusRange:0.2,visualiseDepth:true)
    XCTAssertTrue(try DevelopmentLensBlurEngineV3.apply(blur,to:input) === input)
    let preview=read(try DevelopmentLensBlurEngineV3.applyDepthPreview(blur,to:input))
    let center=preview[40*128+64],corner=preview[0]
    XCTAssertGreaterThan(center.y,center.x);XCTAssertGreaterThan(center.y,center.z)
    XCTAssertGreaterThan(corner.z,corner.x);XCTAssertGreaterThan(corner.z,corner.y)
    for i in preview.indices { XCTAssertEqual(preview[i].w.bitPattern,original[i].w.bitPattern) }
    XCTAssertTrue(try DevelopmentLensBlurEngineV3.applyDepthPreview(nil,to:input) === input)
  }
  func testAllFiveBokehStylesHaveDistinctGPUResponsesAndPreserveFocusAndAlpha()throws {
    let input=fixture,original=read(input);var outputs:[DevelopmentLensBokehStyleV3:[SIMD4<Float>]]=[:]
    for style in DevelopmentLensBokehStyleV3.allCases {
      let actual=read(try DevelopmentLensBlurEngineV3.apply(.init(enabled:true,amount:1,focusRange:0.15,bokehStyle:style),to:input))
      for c in 0..<3 { XCTAssertEqual(actual[40*128+64][c],original[40*128+64][c],accuracy:3e-5, "\(style) focus") }
      for i in actual.indices { XCTAssertEqual(actual[i].w.bitPattern,original[i].w.bitPattern,"\((style)) alpha") }
      XCTAssertNotEqual(actual.map(\.x.bitPattern),original.map(\.x.bitPattern),"\(style) defocus")
      outputs[style]=actual
    }
    for a in DevelopmentLensBokehStyleV3.allCases { for b in DevelopmentLensBokehStyleV3.allCases where a != b {
      XCTAssertNotEqual(outputs[a]?.map(\.x.bitPattern),outputs[b]?.map(\.x.bitPattern),"\(a) vs \(b)")
    } }
  }
  func testCatEyeAndBoostHaveIndependentResponsesWithoutChangingFocus()throws {
    let input=fixture,original=read(input)
    let base=DevelopmentLensBlurV3(enabled:true,amount:1,focusRange:0.15,bokehStyle:.ring)
    let cat=DevelopmentLensBlurV3(enabled:true,amount:1,focusRange:0.15,bokehStyle:.ring,catEyeAmount:0.8)
    let boost=DevelopmentLensBlurV3(enabled:true,amount:1,focusRange:0.15,bokehStyle:.ring,bokehBoost:0.8)
    let baseline=read(try DevelopmentLensBlurEngineV3.apply(base,to:input)),catOutput=read(try DevelopmentLensBlurEngineV3.apply(cat,to:input)),boosted=read(try DevelopmentLensBlurEngineV3.apply(boost,to:input))
    XCTAssertNotEqual(catOutput.map(\.x.bitPattern),baseline.map(\.x.bitPattern))
    XCTAssertNotEqual(boosted.map(\.x.bitPattern),baseline.map(\.x.bitPattern))
    func energy(_ pixels:[SIMD4<Float>])->Double{pixels.reduce(0){$0+Double($1.x*0.2126+$1.y*0.7152+$1.z*0.0722)}}
    XCTAssertGreaterThan(energy(boosted),energy(baseline))
    for output in [catOutput,boosted] {
      for c in 0..<3 { XCTAssertEqual(output[40*128+64][c],original[40*128+64][c],accuracy:3e-5) }
      for i in output.indices { XCTAssertEqual(output[i].w.bitPattern,original[i].w.bitPattern) }
    }
  }
  func testDeviceDepthDrivesActualDefocusAndNearFarFocusPreview()throws {
    let width=16,height=8,values=(0..<(width*height)).map{Float($0%width<width/2 ? 0.1:0.9)}
    let payload=try DevelopmentLensBlurDepthPayloadV1(kind:.depth,width:width,height:height,values:values)
    let input=fixture,original=read(input)
    for style in [DevelopmentLensBokehStyleV3.circle,.ring] {
      let blur=DevelopmentLensBlurV3(enabled:true,amount:1,focusX:0.25,focusY:0.5,focusRange:0.05,bokehStyle:style,deviceDepth:payload)
      let actual=read(try DevelopmentLensBlurEngineV3.apply(blur,to:input))
      for c in 0..<3 {
        XCTAssertEqual(actual[40*128+32][c],original[40*128+32][c],accuracy:4e-5,"\(style) focus")
        XCTAssertNotEqual(actual[40*128+96][c],original[40*128+96][c],"\(style) defocus")
      }
      for i in actual.indices { XCTAssertEqual(actual[i].w.bitPattern,original[i].w.bitPattern) }
    }
    let focusLeft=DevelopmentLensBlurV3(enabled:true,amount:0,focusX:0.25,focusY:0.5,focusRange:0.05,deviceDepth:payload,visualiseDepth:true)
    let preview=read(try DevelopmentLensBlurEngineV3.applyDepthPreview(focusLeft,to:input))
    XCTAssertGreaterThan(preview[40*128+32].y,preview[40*128+32].z)
    XCTAssertGreaterThan(preview[40*128+96].z,preview[40*128+96].x)
    let focusRight=DevelopmentLensBlurV3(enabled:true,amount:0,focusX:0.75,focusY:0.5,focusRange:0.05,deviceDepth:payload,visualiseDepth:true)
    let reversed=read(try DevelopmentLensBlurEngineV3.applyDepthPreview(focusRight,to:input))
    XCTAssertGreaterThan(reversed[40*128+32].x,reversed[40*128+32].z)
    XCTAssertGreaterThan(reversed[40*128+32].x,reversed[40*128+32].y)
  }
}
