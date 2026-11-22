import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskColorV3Tests: XCTestCase {
  private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  private let fixture:CIImage={
    let pixels:[SIMD4<Float>]=[.init(0.4,0.2,0.1,1),.init(0.1,0.3,0.5,1),.init(0.2,0.5,0.2,1),.init(0.5,0.4,0.3,1)]
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:64,size:.init(width:4,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.zero,count:4)
    context.render(image,toBitmap:&pixels,rowBytes:64,bounds:.init(x:0,y:0,width:4,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func mask(_ adjustments:DevelopmentMaskAdjustmentsV3,full:Bool=true)->DevelopmentMaskLayerV3 {
    .init(kind:.radial,center:.init(x:full ? 0.5:0.25,y:0.5),radiusX:full ? 1:0.2,radiusY:1,feather:0,adjustments:adjustments)
  }
  private func expectedWB(_ temperature:Double,_ tint:Double)->CIImage {
    fixture.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:6500+5000*temperature,y:150*tint)])
  }
  func testTemperatureTintMatchesWorkingReferenceAtFullCoverage()throws {
    for (temperature,tint) in [(0.35,0.0),(0.0,-0.25),(0.2,0.3)] {
      let actual=try DevelopmentMaskEngineV3.apply([mask(.init(temperature:temperature,tint:tint))],to:fixture,context:context)
      let a=read(actual),b=read(expectedWB(temperature,tint))
      for index in a.indices { for channel in 0..<4 { XCTAssertEqual(a[index][channel],b[index][channel],accuracy:3e-5) } }
    }
  }
  func testLocalWBMaskProxyAndLegacyRecipe()throws {
    let layer=mask(.init(temperature:0.25,tint:-0.2),full:false)
    let actual=read(try DevelopmentMaskEngineV3.apply([layer],to:fixture,context:context)),original=read(fixture)
    XCTAssertNotEqual(actual[0],original[0]);XCTAssertEqual(actual[3],original[3])
    var p=DevelopmentAdjustmentsV3();p.masks=[layer]
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:4,height:1),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),actual)
    let legacy=DevelopmentMaskAdjustmentsV3(exposure:0.2)
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    XCTAssertNil(object["temperature"]);XCTAssertNil(object["tint"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskAdjustmentsV3.self,from:JSONEncoder().encode(legacy)),legacy)
    var invalid=layer;invalid.adjustments.temperature=1.1;XCTAssertThrowsError(try invalid.validate())
  }
  func testLocalWBComposesWithPointLightAndGlow()throws {
    let glow=DevelopmentGlowV3(enabled:false,amount:0,style:.halation,range:70,spread:35,warmth:60)
    let layer=mask(.init(exposure:0.1,glowAmount:0.2,pointColor:.init(sampledColor:.init(red:0.4,green:0.2,blue:0.1),hue:15,variance:10),contrast:0.2,whites:0.1,blacks:-0.1,temperature:0.2,tint:0.15))
    var p=DevelopmentAdjustmentsV3();p.masks=[layer];p.effects = .init(glow:glow)
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context,glow:glow)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:4,height:1),scale:1,context:context,check:{})
    let a=read(direct);XCTAssertEqual(read(proxy),a);XCTAssertTrue(a.contains{$0.w>0});XCTAssertNotEqual(a[0],read(fixture)[0])
  }
  func testLocalHueFineAdjustmentAndProxy()throws {
    let original=read(fixture)
    let coarse=read(try DevelopmentMaskEngineV3.apply([mask(.init(hue:0.25))],to:fixture,context:context))
    let fine=read(try DevelopmentMaskEngineV3.apply([mask(.init(hue:0.25,fineAdjustment:true))],to:fixture,context:context))
    func distance(_ pixels:[SIMD4<Float>])->Double{pixels.indices.reduce(0){$0+Double(abs(pixels[$1].x-original[$1].x)+abs(pixels[$1].y-original[$1].y)+abs(pixels[$1].z-original[$1].z))}}
    XCTAssertGreaterThan(distance(fine),0);XCTAssertLessThan(distance(fine),distance(coarse))
    var p=DevelopmentAdjustmentsV3();p.masks=[mask(.init(hue:0.2,fineAdjustment:true))]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:4,height:1),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct))
  }
  func testColorizeAfterBlackAndWhiteAndLegacyStorage()throws {
    let color=DevelopmentSampledColorV3(red:0.8,green:0.1,blue:0.05)
    var p=DevelopmentAdjustmentsV3();p.blackAndWhite = .init(enabled:true)
    p.masks=[mask(.init(hue:0.1,colorize:color,colorizeAmount:0.7))]
    let output=read(try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:4,height:1),scale:1,context:context,check:{}))
    XCTAssertTrue(output.allSatisfy{$0.x>$0.y && $0.x>$0.z && $0.w==1})
    let decoded=try JSONDecoder().decode(DevelopmentAdjustmentsV3.self,from:JSONEncoder().encode(p));XCTAssertEqual(decoded,p)
    let legacy=DevelopmentMaskAdjustmentsV3()
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    for key in ["hue","fineAdjustment","colorize","colorizeAmount"] { XCTAssertNil(object[key]) }
    var invalid=p.masks[0];invalid.adjustments.colorizeAmount=1.1;XCTAssertThrowsError(try invalid.validate())
  }
}
