import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskCurvesV3Tests: XCTestCase {
  private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  private let fixture:CIImage={
    let pixels:[SIMD4<Float>]=[.init(0.2,0.1,0.05,1),.init(0.1,0.3,0.5,1),.init(0.5,0.4,0.3,1),.init(0.8,0.7,0.6,1)]
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32,size:.init(width:2,height:2),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.zero,count:4)
    context.render(image,toBitmap:&pixels,rowBytes:32,bounds:.init(x:0,y:0,width:2,height:2),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func curves()->DevelopmentCurvesV3 {
    .init(enabled:true,rgb:.init(curve:.init(points:[.init(x:0,y:0),.init(x:0.25,y:0.4),.init(x:1,y:1)])))
  }
  private func mask(_ curves:DevelopmentCurvesV3?,full:Bool=true)->DevelopmentMaskLayerV3 {
    .init(kind:.radial,center:.init(x:full ? 0.5:0.25,y:0.5),radiusX:full ? 1:0.2,radiusY:1,feather:0,adjustments:.init(curves:curves))
  }
  func testLocalCurvesMatchGlobalAtFullCoverage()throws {
    var global=DevelopmentAdjustmentsV3();global.curves=curves()
    let expected=try DevelopmentColorEngineV3.applyCurvesAndLevels(global,to:fixture)
    let actual=try DevelopmentMaskEngineV3.apply([mask(curves())],to:fixture,context:context)
    let a=read(actual),b=read(expected);XCTAssertNotEqual(a,read(fixture))
    for index in a.indices { for channel in 0..<4 { XCTAssertEqual(a[index][channel],b[index][channel],accuracy:3e-5) } }
  }
  func testLocalCurvesAreMaskedAndMatchProxy()throws {
    var p=DevelopmentAdjustmentsV3();p.masks=[mask(curves(),full:false)]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:2,height:2),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct))
    let a=read(direct),original=read(fixture);XCTAssertNotEqual(a[0],original[0]);XCTAssertEqual(a[3],original[3])
  }
  func testCurveRecipeRoundTripAndLegacyStorage()throws {
    let layer=mask(curves());XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskLayerV3.self,from:JSONEncoder().encode(layer)),layer)
    let legacy=DevelopmentMaskAdjustmentsV3()
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any]);XCTAssertNil(object["curves"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskAdjustmentsV3.self,from:JSONEncoder().encode(legacy)),legacy)
    var invalid=curves();invalid.rgb.inputBlack=0.8;invalid.rgb.inputWhite=0.2
    XCTAssertThrowsError(try mask(invalid).validate())
  }
}
