import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskPointColorV3Tests: XCTestCase {
  private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  private func fixture()->CIImage {
    let pixels:[SIMD4<Float>]=[.init(0.5,0,0,0.5),.init(0,0.5,0,1)]
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32,size:.init(width:2,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.zero,count:2)
    context.render(image,toBitmap:&pixels,rowBytes:32,bounds:.init(x:0,y:0,width:2,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB);return pixels
  }
  func testLocalPointColorOnlyAffectsMaskAndMatchesProxy()throws {
    let sample=DevelopmentPointColorSampleV3(sampledColor:.init(red:0.5,green:0,blue:0),hue:35,saturation:20,variance:25)
    var layer=DevelopmentMaskLayerV3(kind:.radial,center:.init(x:0.25,y:0.5),radiusX:0.2,radiusY:1,feather:0,
      adjustments:.init(pointColor:sample))
    var p=DevelopmentAdjustmentsV3();p.masks=[layer]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture(),context:context)
    let actual=read(direct),original=read(fixture())
    XCTAssertNotEqual(actual[0],original[0]);XCTAssertNotEqual(actual[0].y,original[0].y)
    XCTAssertEqual(actual[0].w,original[0].w,accuracy:1e-6)
    let actualRight=[actual[1].x,actual[1].y,actual[1].z,actual[1].w].map(\.bitPattern)
    let originalRight=[original[1].x,original[1].y,original[1].z,original[1].w].map(\.bitPattern)
    XCTAssertEqual(actualRight,originalRight)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture(),sourceIsRAW:false,nativeSize:.init(width:2,height:1),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),actual)
    let encoded=try JSONEncoder().encode(layer),decoded=try JSONDecoder().decode(DevelopmentMaskLayerV3.self,from:encoded)
    XCTAssertEqual(decoded,layer)
    layer.adjustments.pointColor=nil
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(layer.adjustments))as? [String:Any])["pointColor"])
  }
  func testLocalPointColorComposesWithToneAndGlowOnce()throws {
    let glow=DevelopmentGlowV3(enabled:false,amount:0,style:.halation,range:70,spread:35,warmth:60)
    let layer=DevelopmentMaskLayerV3(kind:.radial,center:.init(x:0.25,y:0.5),radiusX:0.3,radiusY:1,feather:0.2,
      adjustments:.init(exposure:0.2,saturation:0.1,glowAmount:0.3,
        pointColor:.init(sampledColor:.init(red:0.5,green:0,blue:0),hue:20,saturation:10,variance:15)))
    var p=DevelopmentAdjustmentsV3();p.masks=[layer];p.effects = .init(glow:glow)
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture(),context:context,glow:glow)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture(),sourceIsRAW:false,nativeSize:.init(width:2,height:1),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct))
    let pixels=read(direct);XCTAssertNotEqual(pixels[0],read(fixture())[0]);XCTAssertEqual(pixels[0].w,0.5,accuracy:1e-6)
  }
}
