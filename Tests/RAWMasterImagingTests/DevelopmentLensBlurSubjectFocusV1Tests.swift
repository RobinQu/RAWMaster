import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentLensBlurSubjectFocusV1Tests:XCTestCase {
  func testMaskPixelsProduceCenterCoverageAndTopLeftFocusY()throws {
    let width=64,height=40
    var pixels=[UInt8](repeating:0,count:width*height*4)
    for y in 0..<height { for x in 0..<width {
      let i=(y*width+x)*4;pixels[i+3]=255
      if (16..<48).contains(x) && (8..<24).contains(y){pixels[i]=255}
    } }
    let image=CIImage(bitmapData:Data(pixels),bytesPerRow:width*4,size:.init(width:width,height:height),format:.RGBA8,colorSpace:nil)
    let context=CIContext();let png=try XCTUnwrap(context.pngRepresentation(of:image,format:.RGBA8,colorSpace:DevelopmentColorEngineV3.linearSRGB))
    let estimate=try DevelopmentLensBlurSubjectFocusV1.estimate(maskPNG:png)
    XCTAssertEqual(estimate.focusX,0.5,accuracy:0.02);XCTAssertEqual(estimate.focusY,0.6,accuracy:0.03)
    XCTAssertGreaterThan(estimate.focusRange,0.2);XCTAssertLessThanOrEqual(estimate.focusRange,1)
    XCTAssertEqual(estimate.weightedPixelCount,512,accuracy:1)
    var empty=pixels;for i in stride(from:0,to:empty.count,by:4){empty[i]=0}
    let emptyImage=CIImage(bitmapData:Data(empty),bytesPerRow:width*4,size:.init(width:width,height:height),format:.RGBA8,colorSpace:nil)
    let emptyPNG=try XCTUnwrap(context.pngRepresentation(of:emptyImage,format:.RGBA8,colorSpace:DevelopmentColorEngineV3.linearSRGB))
    XCTAssertThrowsError(try DevelopmentLensBlurSubjectFocusV1.estimate(maskPNG:emptyPNG))
    XCTAssertThrowsError(try DevelopmentLensBlurSubjectFocusV1.estimate(maskPNG:Data()))
  }
}
