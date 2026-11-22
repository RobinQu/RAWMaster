import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskDehazeV3Tests:XCTestCase {
  private let context=DevelopmentColorEngineV3.makeContext()
  private let fixture:CIImage={
    let pixels=(0..<64*32).map{i->SIMD4<Float> in
      let x=i%64,y=i/32,v=0.08+0.72*Float(x)/63
      return .init(v,v*0.92,v*0.82,y<3 ? 0.5:1)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:64*16,size:.init(width:64,height:32),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    context.clearCaches()
    var pixels=[SIMD4<Float>](repeating:.zero,count:64*32)
    context.render(image,toBitmap:&pixels,rowBytes:64*16,bounds:.init(x:0,y:0,width:64,height:32),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func mask(_ amount:Double)->DevelopmentMaskLayerV3 {
    .init(kind:.radial,center:.init(x:0.25,y:0.5),radiusX:0.15,radiusY:0.3,feather:0,adjustments:.init(dehaze:amount))
  }
  func testSignedLocalDehazeIsMaskedAndMatchesProxy()throws {
    let original=read(fixture)
    for amount in [0.6,-0.6] {
      let layer=mask(amount),direct=try DevelopmentMaskEngineV3.apply([layer],to:fixture,context:context)
      let actual=read(direct),inside=8+16*64,outside=56+16*64
      XCTAssertNotEqual(actual[inside].x,original[inside].x)
      for c in 0..<4{XCTAssertEqual(actual[outside][c],original[outside][c],accuracy:3e-5)}
      for i in actual.indices{XCTAssertEqual(actual[i].w.bitPattern,original[i].w.bitPattern)}
      var p=DevelopmentAdjustmentsV3();p.masks=[layer]
      let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:64,height:32),scale:1,context:context,check:{})
      let scaled=read(proxy)
      for i in scaled.indices{for c in 0..<4{XCTAssertEqual(scaled[i][c],actual[i][c],accuracy:5e-5)}}
    }
  }
  func testStorageNeutralStateAndValidation()throws {
    let legacy=DevelopmentMaskAdjustmentsV3(exposure:0.2)
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    XCTAssertNil(object["dehaze"]);XCTAssertTrue(legacy.isNeutral == false)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskAdjustmentsV3.self,from:JSONEncoder().encode(legacy)),legacy)
    var layer=mask(0.5);XCTAssertFalse(layer.adjustments.isNeutral)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskLayerV3.self,from:JSONEncoder().encode(layer)),layer)
    layer.adjustments.dehaze=1.1;XCTAssertThrowsError(try layer.validate())
    layer.adjustments.dehaze=0;XCTAssertTrue(layer.adjustments.isNeutral)
  }
}
