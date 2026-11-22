import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskLightV3Tests: XCTestCase {
  private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  private let fixture:CIImage={
    let pixels:[SIMD4<Float>]=[.init(0.05,0.1,0.15,1),.init(0.2,0.25,0.3,1),.init(0.5,0.55,0.6,1),.init(0.8,0.85,0.9,1)]
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32,size:.init(width:2,height:2),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.zero,count:4)
    context.render(image,toBitmap:&pixels,rowBytes:32,bounds:.init(x:0,y:0,width:2,height:2),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func fullMask(_ adjustments:DevelopmentMaskAdjustmentsV3)->DevelopmentMaskLayerV3 {
    .init(kind:.radial,center:.init(x:0.5,y:0.5),radiusX:1,radiusY:1,feather:0,adjustments:adjustments)
  }
  func testExtendedLightMatchesGlobalOperatorAtFullCoverage()throws {
    let cases:[(DevelopmentMaskAdjustmentsV3,DevelopmentLightV3)]=[
      (.init(contrast:0.45),.init(enabled:true,contrast:0.45)),
      (.init(whites:0.4),.init(enabled:true,whites:0.4)),
      (.init(blacks:-0.35),.init(enabled:true,blackPoint:-0.35))
    ]
    for (local,light) in cases {
      let actual=try DevelopmentMaskEngineV3.apply([fullMask(local)],to:fixture,context:context)
      var p=DevelopmentAdjustmentsV3();p.light=light
      let expected=try DevelopmentColorEngineV3.applyPointwise(p,to:fixture)
      let a=read(actual),b=read(expected)
      for index in a.indices {
        for channel in 0..<4 { XCTAssertEqual(a[index][channel],b[index][channel],accuracy:2e-5) }
      }
    }
  }
  func testExtendedLightProxyAndLegacyRecipeRoundTrip()throws {
    let adjustments=DevelopmentMaskAdjustmentsV3(exposure:0.1,contrast:0.25,whites:0.2,blacks:-0.15)
    var p=DevelopmentAdjustmentsV3();p.masks=[fullMask(adjustments)]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:2,height:2),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskLayerV3.self,from:JSONEncoder().encode(p.masks[0])),p.masks[0])
    let legacy=DevelopmentMaskAdjustmentsV3(exposure:0.2)
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    for key in ["contrast","whites","blacks"] { XCTAssertNil(object[key]) }
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskAdjustmentsV3.self,from:JSONEncoder().encode(legacy)),legacy)
    var invalid=adjustments;invalid.contrast=2.01;XCTAssertThrowsError(try invalid.validate())
  }
  func testPointColorThenExtendedLightDoesNotProduceEmptyGraph()throws {
    let point=fullMask(.init(pointColor:.init(sampledColor:.init(red:0.5,green:0.25,blue:0.15),hue:20,saturation:15,variance:20)))
    let light=fullMask(.init(contrast:0.25,whites:0.2,blacks:-0.15))
    var p=DevelopmentAdjustmentsV3();p.masks=[point,light]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context)
    let pixels=read(direct);XCTAssertTrue(pixels.contains{$0.w>0});XCTAssertTrue(pixels.contains{$0.x>0 || $0.y>0 || $0.z>0})
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:2,height:2),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),pixels)
  }
  func testExtendedLightChangesGlowPath()throws {
    let baseline=read(try DevelopmentMaskEngineV3.apply([fullMask(.init(glowAmount:0.25))],to:fixture,context:context,glow:.init()))
    for adjustments in [DevelopmentMaskAdjustmentsV3(glowAmount:0.25,contrast:0.4),.init(glowAmount:0.25,whites:0.4),.init(glowAmount:0.25,blacks:-0.3)] {
      let changed=read(try DevelopmentMaskEngineV3.apply([fullMask(adjustments)],to:fixture,context:context,glow:.init()))
      XCTAssertNotEqual(changed,baseline)
    }
  }
}
