import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentOpticsEngineV3Tests: XCTestCase {
  private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  private let fixture:CIImage={
    let pixels=(0..<32*16).map{index->SIMD4<Float> in
      let x=index%32,y=index/32
      if x<15{return .init(0.15,0.2,0.25,1)}
      if x==15{return .init(0.8,0.1,0.15,1)}
      return .init(0.1,0.2,0.7,1)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32*16,size:.init(width:32,height:16),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.zero,count:32*16)
    context.render(image,toBitmap:&pixels,rowBytes:32*16,bounds:.init(x:0,y:0,width:32,height:16),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  func testDistortionAndAutomaticCAHaveRealGPUEffects()throws {
    let distorted=try DevelopmentOpticsEngineV3.apply(.init(distortion:0.35),to:fixture)
    let ca=try DevelopmentOpticsEngineV3.apply(.init(removeChromaticAberration:true),to:fixture)
    XCTAssertNotEqual(read(distorted),read(fixture))
    let before=read(fixture),after=read(ca)
    XCTAssertNotEqual(after,before)
    XCTAssertEqual(read(try DevelopmentOpticsEngineV3.apply(.init(removeChromaticAberration:true),to:fixture)),read(ca))
  }
  func testOpticsProxyAndRecipeRoundTrip()throws {
    var p=DevelopmentAdjustmentsV3();p.optics = .init(removeChromaticAberration:true,distortion:0.2)
    let direct=try DevelopmentOpticsEngineV3.apply(p.optics,to:fixture)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:32,height:16),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentAdjustmentsV3.self,from:JSONEncoder().encode(p)),p)
  }
  func testLegacyOpticsStorageAndValidation()throws {
    let legacy=DevelopmentOpticsV3()
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    XCTAssertNil(object["removeChromaticAberration"]);XCTAssertNil(object["distortion"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentOpticsV3.self,from:JSONEncoder().encode(legacy)),legacy)
    var invalid=legacy;invalid.distortion=1.1;XCTAssertThrowsError(try invalid.validate())
  }
  func testLensProfileCatalogMatchesOnlyExactEXIFLens()throws {
    let metadata=DevelopmentLensMetadata(cameraMake:"SONY",cameraModel:"ILCE-7RM5",lensModel:"FE 24-70mm F2.8 GM")
    XCTAssertEqual(DevelopmentLensProfileCatalogV3.match(metadata)?.id,"sony-fe-24-70-gm")
    XCTAssertNil(DevelopmentLensProfileCatalogV3.match(.init(lensModel:"Unknown Lens")))
    for profile in DevelopmentLensProfileCatalogV3.profiles{try profile.validate()}
  }
  func testLensProfileCorrectionAmountsProxyAndLegacyStorage()throws {
    let profile=try XCTUnwrap(DevelopmentLensProfileCatalogV3.profile(id:"generic-wide"))
    var p=DevelopmentAdjustmentsV3();p.optics = .init(lensProfileEnabled:true,lensProfile:profile,profileDistortionAmount:0.8,profileVignettingAmount:0.7)
    let direct=try DevelopmentOpticsEngineV3.apply(p.optics,to:fixture);XCTAssertNotEqual(read(direct),read(fixture))
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:32,height:16),scale:1,context:context,check:{})
    XCTAssertEqual(read(proxy),read(direct))
    p.optics?.profileVignettingAmount=0.3
    XCTAssertNotEqual(read(try DevelopmentOpticsEngineV3.apply(p.optics,to:fixture)),read(direct))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentAdjustmentsV3.self,from:JSONEncoder().encode(p)),p)
    let legacy=DevelopmentOpticsV3(),object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))as? [String:Any])
    for key in ["lensProfileEnabled","lensProfile","profileDistortionAmount","profileVignettingAmount","lensVignettingAmount","lensVignettingMidpoint"]{XCTAssertNil(object[key])}
    var manual=DevelopmentAdjustmentsV3();manual.optics = .init(lensVignettingAmount:0.4,lensVignettingMidpoint:0.6)
    let manualDirect=try DevelopmentOpticsEngineV3.apply(manual.optics,to:fixture);XCTAssertNotEqual(read(manualDirect),read(fixture))
    let manualProxy=try PreviewInteractiveProxyV3.suffix(manual,source:fixture,sourceIsRAW:false,nativeSize:.init(width:32,height:16),scale:1,context:context,check:{})
    XCTAssertEqual(read(manualProxy),read(manualDirect))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentAdjustmentsV3.self,from:JSONEncoder().encode(manual)),manual)
    p.optics?.profileDistortionAmount=2.1;XCTAssertThrowsError(try p.validate())
  }
  func testRealRAWLensMetadataDiagnostic()throws {
    guard let path=ProcessInfo.processInfo.environment["RAWMASTER_INTERACTIVE_PERF_SOURCE"] else{throw XCTSkip("Opt-in real RAW")}
    guard let metadata=DevelopmentLensMetadata.read(URL(fileURLWithPath:path)) else{throw XCTSkip("ImageIO exposed no camera/lens metadata")}
    print("LENS-METADATA",metadata.cameraMake ?? "nil",metadata.cameraModel ?? "nil",metadata.lensModel ?? "nil")
    print("LENS-MATCH",DevelopmentLensProfileCatalogV3.match(metadata)?.id ?? "none")
  }
}
