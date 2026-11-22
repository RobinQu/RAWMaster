import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskEffectsV3Tests: XCTestCase {
  private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  private let fixture:CIImage={
    let pixels=(0..<32*32).map{index->SIMD4<Float> in
      let x=index%32,y=index/32,value:Float=(x+y)%2==0 ? 0.12:0.65
      return .init(value,value*0.9,value*0.8,1)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32*16,size:.init(width:32,height:32),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    let width=Int(image.extent.width),height=Int(image.extent.height)
    var pixels=[SIMD4<Float>](repeating:.zero,count:width*height)
    context.render(image,toBitmap:&pixels,rowBytes:width*16,bounds:image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func mask(_ adjustments:DevelopmentMaskAdjustmentsV3,full:Bool=true)->DevelopmentMaskLayerV3 {
    .init(kind:.radial,center:.init(x:full ? 0.5:0.25,y:0.5),radiusX:full ? 1:0.15,radiusY:full ? 1:0.3,feather:0,adjustments:adjustments)
  }
  func testLocalBandsMatchSharedOperatorsAtFullCoverage()throws {
    let radii=try DevelopmentAdvancedDetailEngineV3.radii(sourceSize:.init(width:32,height:32))
    for (band,amount,adjustments) in [(DevelopmentAdvancedDetailEngineV3.Band.texture,35.0,DevelopmentMaskAdjustmentsV3(texture:0.35)),(.clarity,25.0,.init(clarity:0.25))] {
      let expected=try DevelopmentAdvancedDetailEngineV3.applyBand(band,amount:amount,to:fixture,radius:band == .texture ? radii.texture:radii.clarity)
      let actual=try DevelopmentMaskEngineV3.apply([mask(adjustments)],to:fixture,context:context)
      let a=read(actual),b=read(expected)
      XCTAssertNotEqual(a,read(fixture))
      for index in a.indices { for channel in 0..<4 { XCTAssertEqual(a[index][channel],b[index][channel],accuracy:3e-5) } }
    }
  }
  func testLocalBandsAreMaskedAndMatchProxy()throws {
    var p=DevelopmentAdjustmentsV3();p.masks=[mask(.init(texture:0.3,clarity:0.2),full:false)]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:32,height:32),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct))
    let pixels=read(direct),original=read(fixture)
    XCTAssertNotEqual(pixels[8+16*32],original[8+16*32]);XCTAssertEqual(pixels[30+16*32],original[30+16*32])
  }
  func testLegacyStorageAndValidation()throws {
    let legacy=DevelopmentMaskAdjustmentsV3(exposure:0.2)
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    XCTAssertNil(object["texture"]);XCTAssertNil(object["clarity"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskAdjustmentsV3.self,from:JSONEncoder().encode(legacy)),legacy)
    var layer=mask(.init(texture:0.2,clarity:-0.2));XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskLayerV3.self,from:JSONEncoder().encode(layer)),layer)
    layer.adjustments.texture=1.1;XCTAssertThrowsError(try layer.validate())
  }
  func testLocalGrainIsDeterministicMaskedAndMatchesProxy()throws {
    let layer=mask(.init(grain:0.5,grainSize:0.4,grainRoughness:0.6),full:false)
    let direct=try DevelopmentMaskEngineV3.apply([layer],to:fixture,context:context)
    let pixels=read(direct),original=read(fixture)
    XCTAssertNotEqual(pixels[8+16*32],original[8+16*32]);XCTAssertEqual(pixels[30+16*32],original[30+16*32])
    XCTAssertEqual(read(try DevelopmentMaskEngineV3.apply([layer],to:fixture,context:context)),pixels)
    var p=DevelopmentAdjustmentsV3();p.masks=[layer]
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:32,height:32),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),pixels)
    var sized=layer;sized.adjustments.grainSize=0.9
    XCTAssertNotEqual(read(try DevelopmentMaskEngineV3.apply([sized],to:fixture,context:context)),pixels)
  }
  func testGrainLegacyStorageAndValidation()throws {
    let legacy=DevelopmentMaskAdjustmentsV3()
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    for key in ["grain","grainSize","grainRoughness"] { XCTAssertNil(object[key]) }
    var layer=mask(.init(grain:0.4,grainSize:0.3,grainRoughness:0.7))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskLayerV3.self,from:JSONEncoder().encode(layer)),layer)
    layer.adjustments.grain=1.1;XCTAssertThrowsError(try layer.validate())
  }

  func testFlashRawLocalGrainUsesTheNativeLatticeAtFit() throws {
    let native = CIImage(color: CIColor(red:0.32,green:0.32,blue:0.32,alpha:1)).cropped(to:fixture.extent)
    let layer=mask(.init(grain:0.5,grainSize:0.4,grainRoughness:0.6))
    let reference=read(try DevelopmentMaskEngineV3.apply([layer],to:native,context:context))
    let fused=read(try DevelopmentMaskEngineV3.apply([layer],to:native,context:context,sourceGrainScale:1))
    let fit=native.transformed(by:.init(scaleX:0.5,y:0.5))
    let small=read(try DevelopmentMaskEngineV3.apply([layer],to:fit,context:context,sourceGrainScale:0.5))
    for (a,b) in zip(fused,reference) {
      XCTAssertEqual(a.x,b.x,accuracy:2e-5)
      XCTAssertEqual(a.w,b.w)
    }
    for y in 0..<16 {
      for x in 0..<16 {
        let index=2*y*32+2*x
        let neighbours=[index,index+1,index+32,index+33]
        let expected=neighbours.reduce(Float(0)) { $0+reference[$1].x }/4
        XCTAssertEqual(small[y*16+x].x,expected,accuracy:0.0004)
        XCTAssertEqual(small[y*16+x].w,1)
      }
    }
  }
}
