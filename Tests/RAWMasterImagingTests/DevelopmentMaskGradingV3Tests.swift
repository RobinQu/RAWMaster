import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskGradingV3Tests: XCTestCase {
  private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  private let fixture:CIImage={
    let pixels:[SIMD4<Float>]=[.init(0.1,0.1,0.1,1),.init(0.3,0.3,0.3,1),.init(0.6,0.6,0.6,1),.init(0.8,0.8,0.8,1)]
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32,size:.init(width:2,height:2),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.zero,count:4)
    context.render(image,toBitmap:&pixels,rowBytes:32,bounds:.init(x:0,y:0,width:2,height:2),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func grading()->DevelopmentColorGrading {
    .init(shadows:.init(hueDegrees:30,saturation:40,luminance:10),midtones:.init(hueDegrees:200,saturation:20,luminance:-5),highlights:.init(hueDegrees:300,saturation:30,luminance:8),global:.init(hueDegrees:100,saturation:10),blending:60,balance:20)
  }
  private func mask(_ grading:DevelopmentColorGrading?,full:Bool=true)->DevelopmentMaskLayerV3 {
    .init(kind:.radial,center:.init(x:full ? 0.5:0.25,y:0.5),radiusX:full ? 1:0.2,radiusY:1,feather:0,adjustments:.init(grading:grading))
  }
  func testLocalGradingMatchesGlobalAtFullCoverage()throws {
    let expected=try DevelopmentColorEngineV2.apply(.init(grading:grading()),to:fixture)
    let actual=try DevelopmentMaskEngineV3.apply([mask(grading())],to:fixture,context:context)
    let a=read(actual),b=read(expected);XCTAssertNotEqual(a,read(fixture))
    for index in a.indices { for channel in 0..<4 { XCTAssertEqual(a[index][channel],b[index][channel],accuracy:3e-5) } }
  }
  func testLocalGradingMaskProxyAndRecipe()throws {
    var p=DevelopmentAdjustmentsV3();p.masks=[mask(grading(),full:false)]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:2,height:2),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct))
    let a=read(direct),original=read(fixture);XCTAssertNotEqual(a[0],original[0]);XCTAssertEqual(a[3],original[3])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentAdjustmentsV3.self,from:JSONEncoder().encode(p)),p)
  }
  func testLegacyStorageAndValidation()throws {
    let legacy=DevelopmentMaskAdjustmentsV3()
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any]);XCTAssertNil(object["grading"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskAdjustmentsV3.self,from:JSONEncoder().encode(legacy)),legacy)
    var invalid=grading();invalid.blending=101;XCTAssertThrowsError(try mask(invalid).validate())
  }
}
