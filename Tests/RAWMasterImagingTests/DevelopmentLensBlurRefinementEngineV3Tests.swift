import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentLensBlurRefinementEngineV3Tests:XCTestCase {
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
  private func refinement(_ mode:DevelopmentLensBlurRefinementModeV3,at point:DevelopmentSourcePoint,
                          amount:Double=1,size:Double=0.2,feather:Double=0,flow:Double=1)->DevelopmentLensBlurRefinementStrokeV3 {
    .init(mode:mode,stroke:.init(points:[.init(position:point)],radiusInShortEdge:size,strength:amount),feather:feather,flow:flow)
  }
  func testFocusAndBlurStrokesDriveDefocusAndPreserveAlpha()throws {
    let input=fixture,original=read(input)
    let base=DevelopmentLensBlurV3(enabled:true,amount:1,focusX:0.5,focusY:0.5,focusRange:0)
    let focused=refinement(.focus,at:.init(x:0.25,y:0.5))
    let blurred=refinement(.blur,at:.init(x:0.5,y:0.5))
    var a=base;a.refinementStrokes=[focused]
    let focusOutput=read(try DevelopmentLensBlurEngineV3.apply(a,to:input))
    for c in 0..<3{XCTAssertEqual(focusOutput[40*128+32][c],original[40*128+32][c],accuracy:4e-5)}
    var b=base;b.refinementStrokes=[blurred]
    let blurOutput=read(try DevelopmentLensBlurEngineV3.apply(b,to:input))
    for c in 0..<3{XCTAssertNotEqual(blurOutput[40*128+64][c],original[40*128+64][c])}
    for output in [focusOutput,blurOutput]{for i in output.indices{XCTAssertEqual(output[i].w.bitPattern,original[i].w.bitPattern)}}
  }
  func testAmountSizeFeatherAndFlowHaveIndependentResponses()throws {
    let input=fixture
    let base=DevelopmentLensBlurV3(enabled:true,amount:1,focusX:0.5,focusY:0.5,focusRange:0,bokehStyle:.ring)
    func output(_ stroke:DevelopmentLensBlurRefinementStrokeV3)throws->[SIMD4<Float>] {
      var value=base;value.refinementStrokes=[stroke]
      return read(try DevelopmentLensBlurEngineV3.apply(value,to:input))
    }
    let point=DevelopmentSourcePoint(x:0.1,y:0.5)
    let full=try output(refinement(.focus,at:point))
    let amountHalf=try output(refinement(.focus,at:point,amount:0.5,flow:1))
    let flowLow=try output(refinement(.focus,at:point,amount:1,flow:0.2))
    XCTAssertNotEqual(amountHalf.map(\.x.bitPattern),full.map(\.x.bitPattern))
    XCTAssertNotEqual(flowLow.map(\.x.bitPattern),full.map(\.x.bitPattern))
    XCTAssertNotEqual(amountHalf.map(\.x.bitPattern),flowLow.map(\.x.bitPattern))
    let small=try output(refinement(.focus,at:point,size:0.05))
    let feathered=try output(refinement(.focus,at:point,feather:0.8))
    XCTAssertNotEqual(small.map(\.x.bitPattern),full.map(\.x.bitPattern))
    XCTAssertNotEqual(feathered.map(\.x.bitPattern),full.map(\.x.bitPattern))
  }
  func testRefinementsAffectDeviceDepthAndVisualization()throws {
    let values=(0..<(16*8)).map{Float($0%16<8 ? 0.1:0.9)}
    let depth=try DevelopmentLensBlurDepthPayloadV1(kind:.depth,width:16,height:8,values:values)
    var value=DevelopmentLensBlurV3(enabled:true,amount:1,focusX:0.25,focusY:0.5,focusRange:0,deviceDepth:depth)
    value.refinementStrokes=[refinement(.blur,at:.init(x:0.25,y:0.5))]
    let actual=read(try DevelopmentLensBlurEngineV3.apply(value,to:fixture)),original=read(fixture)
    XCTAssertNotEqual(actual[40*128+32].x,original[40*128+32].x)
    value.amount=0;value.visualiseDepth=true
    let preview=read(try DevelopmentLensBlurEngineV3.applyDepthPreview(value,to:fixture))
    XCTAssertGreaterThan(preview[40*128+32].z,preview[40*128+32].x)
    XCTAssertGreaterThan(preview[40*128+32].z,preview[40*128+32].y)
  }
  func testAutoMaskConstrainsFocusBrushToTheDabColor()throws {
    let pixels=(0..<(128*80)).map{i->SIMD4<Float> in
      let red=i%128<64
      return red ? .init(0.8,0.1,0.1,1):.init(0.1,0.8,0.1,1)
    }
    let input=CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:128*16,size:size,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let original=read(input)
    let base=DevelopmentLensBlurV3(enabled:true,amount:1,focusX:0.5,focusY:0.5,focusRange:0)
    let baseline=read(try DevelopmentLensBlurEngineV3.apply(base,to:input))
    var stroke=refinement(.focus,at:.init(x:0.25,y:0.5),size:1)
    var plain=base;plain.refinementStrokes=[stroke]
    let plainOutput=read(try DevelopmentLensBlurEngineV3.apply(plain,to:input))
    stroke.autoMask=true;var masked=base;masked.refinementStrokes=[stroke]
    let maskedOutput=read(try DevelopmentLensBlurEngineV3.apply(masked,to:input))
    let left=40*128+32,right=40*128+96
    for c in 0..<3 {
      XCTAssertEqual(plainOutput[right][c],original[right][c],accuracy:4e-5)
      XCTAssertEqual(maskedOutput[left][c],original[left][c],accuracy:4e-5)
      XCTAssertEqual(maskedOutput[right][c],baseline[right][c],accuracy:4e-5)
    }
  }
}
