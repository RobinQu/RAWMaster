import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentClippingPreviewV3Tests:XCTestCase {
  private let context=DevelopmentColorEngineV3.makeContext()
  private let fixture:CIImage={
    let pixels:[SIMD4<Float>]=[.init(0,0,0,1),.init(0.5,0.5,0.5,1),.init(1,1,1,1),.init(0,0,0,0.5)]
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:4*16,size:.init(width:4,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    context.clearCaches();var pixels=[SIMD4<Float>](repeating:.zero,count:4)
    context.render(image,toBitmap:&pixels,rowBytes:4*16,bounds:.init(x:0,y:0,width:4,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  func testShadowHighlightAndBothOverlaysPreserveMidtonesAndAlpha()throws {
    for mode in [DevelopmentClippingPreviewV3.shadows,.highlights,.both] {
      var p=DevelopmentAdjustmentsV3();p.light.clippingPreview=mode
      let direct=try DevelopmentGlobalEngineV3.applyClippingPreview(p,to:fixture)
      let actual=read(direct),original=read(fixture)
      if mode != .highlights { XCTAssertGreaterThan(actual[0].z,actual[0].x) }
      if mode != .shadows { XCTAssertGreaterThan(actual[2].x,actual[2].z) }
      for c in 0..<3{XCTAssertEqual(actual[1][c],original[1][c],accuracy:3e-5)}
      XCTAssertEqual(actual[3].w,original[3].w)
      let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:4,height:1),scale:1,context:context,check:{})
      let scaled=read(proxy)
      for i in scaled.indices{for c in 0..<4{XCTAssertEqual(scaled[i][c],actual[i][c],accuracy:5e-5)}}
      let encoded=try JSONEncoder().encode(p.light)
      XCTAssertEqual(try JSONDecoder().decode(DevelopmentLightV3.self,from:encoded),p.light)
    }
    let legacy=DevelopmentLightV3()
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    XCTAssertNil(object["clippingPreview"])
  }
}
