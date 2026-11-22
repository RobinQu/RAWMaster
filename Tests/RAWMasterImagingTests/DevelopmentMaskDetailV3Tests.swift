import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskDetailV3Tests: XCTestCase {
  private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  private let fixture:CIImage={
    let pixels=(0..<16*16).map{index->SIMD4<Float> in
      let x=index%16,y=index/16,v:Float=(x+y)%2==0 ? 0.2:0.7
      return .init(v,0.45+Float(x%3)*0.1,0.65-v*0.4,1)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:16*16,size:.init(width:16,height:16),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.zero,count:16*16)
    context.render(image,toBitmap:&pixels,rowBytes:16*16,bounds:.init(x:0,y:0,width:16,height:16),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func mask(_ adjustments:DevelopmentMaskAdjustmentsV3,full:Bool=true)->DevelopmentMaskLayerV3 {
    .init(kind:.radial,center:.init(x:full ? 0.5:0.25,y:0.5),radiusX:full ? 1:0.2,radiusY:full ? 1:0.4,feather:0,adjustments:adjustments)
  }
  func testSharpnessAndNoiseMatchSharedGlobalOperators()throws {
    var sharp=DevelopmentAdjustmentsV3();sharp.sharpen = .init(enabled:true,intensity:0.35)
    var noise=DevelopmentAdjustmentsV3();noise.noiseReduction = .init(enabled:true,sourceCapability:.image,nonRawAmount:2)
    for (global,local) in [(sharp,DevelopmentMaskAdjustmentsV3(sharpness:0.35)),(noise,.init(noiseReduction:0.4))] {
      let expected=try DevelopmentGlobalEngineV3.apply(global,to:fixture,sourceIsRAW:false)
      let actual=try DevelopmentMaskEngineV3.apply([mask(local)],to:fixture,context:context)
      let a=read(actual),b=read(expected)
      for index in a.indices { for channel in 0..<4 { XCTAssertEqual(a[index][channel],b[index][channel],accuracy:4e-5) } }
    }
  }
  func testNegativeSharpnessAndProxy()throws {
    var p=DevelopmentAdjustmentsV3();p.masks=[mask(.init(sharpness:-0.5),full:false)]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:16,height:16),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct));XCTAssertNotEqual(read(direct),read(fixture))
  }
  func testMoirePreservesLumaAndMaskBoundary()throws {
    var p=DevelopmentAdjustmentsV3();p.masks=[mask(.init(moireReduction:0.8),full:false)]
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:fixture,context:context)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:16,height:16),scale:1,context:context,check:{})
    let a=read(direct),original=read(fixture);XCTAssertEqual(read(proxy),a);XCTAssertEqual(a[15+8*16],original[15+8*16])
    for index in a.indices {
      let before=original[index].x*0.2126+original[index].y*0.7152+original[index].z*0.0722
      let after=a[index].x*0.2126+a[index].y*0.7152+a[index].z*0.0722
      XCTAssertEqual(before,after,accuracy:2e-5)
    }
  }
  func testDetailLegacyStorageAndValidation()throws {
    let legacy=DevelopmentMaskAdjustmentsV3()
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    for key in ["sharpness","noiseReduction","moireReduction","defringe"] { XCTAssertNil(object[key]) }
    var layer=mask(.init(sharpness:0.2,noiseReduction:0.3,moireReduction:0.4,defringe:-1))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskLayerV3.self,from:JSONEncoder().encode(layer)),layer)
    layer.adjustments.noiseReduction=1.1;XCTAssertThrowsError(try layer.validate())
    layer.adjustments.noiseReduction=0;layer.adjustments.defringe = -1.1;XCTAssertThrowsError(try layer.validate())
  }
  func testPositiveLocalDefringeMatchesSharedOperator()throws {
    let adjustments=DevelopmentMaskAdjustmentsV3(defringe:0.8)
    let optics=DevelopmentOpticsV3(defringe:.init(enabled:true,purpleAmount:80,greenAmount:80))
    let expected=try DevelopmentDefringeEngineV3.apply(optics,to:fixture)
    let actual=try DevelopmentMaskEngineV3.apply([mask(adjustments)],to:fixture,context:context)
    XCTAssertNotEqual(read(actual),read(fixture))
    let a=read(actual),b=read(expected)
    for index in a.indices { for channel in 0..<4 { XCTAssertEqual(a[index][channel],b[index][channel],accuracy:4e-5) } }
  }
  func testNegativeDefringeRestoresOriginalInsideAndKeepsGlobalOutsideIncludingProxy()throws {
    let optics=DevelopmentOpticsV3(defringe:.init(enabled:true,purpleAmount:100,greenAmount:100))
    var p=DevelopmentAdjustmentsV3();p.optics=optics;p.masks=[mask(.init(defringe:-1),full:false)]
    let globally=try DevelopmentDefringeEngineV3.apply(optics,to:fixture)
    let globalInput=try DevelopmentGlobalEngineV3.apply(p,to:fixture,sourceIsRAW:false)
    XCTAssertTrue(globalInput === fixture,"Local protection defers the global operator without changing the old no-mask path")
    let direct=try DevelopmentMaskEngineV3.apply(p.masks,to:globalInput,context:context,optics:optics)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:16,height:16),scale:1,context:context,check:{})
    let actual=read(direct),expectedOutside=read(globally),original=read(fixture)
    XCTAssertEqual(read(proxy),actual)
    for channel in 0..<4 {
      XCTAssertEqual(actual[8*16+4][channel],original[8*16+4][channel],accuracy:4e-5)
      XCTAssertEqual(actual[8*16+15][channel],expectedOutside[8*16+15][channel],accuracy:4e-5)
    }
    XCTAssertNotEqual(actual,original);XCTAssertNotEqual(actual,expectedOutside)
  }
}
