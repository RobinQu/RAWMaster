import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentDefringeEngineV3Tests: XCTestCase {
  private func fixture(_ color:SIMD3<Float>)->CIImage {
    let pixels=(0..<(64*16)).map { index -> SIMD4<Float> in
      let x=index%64,y=index/64,alpha:Float=y==0 ? 0.5:1,c=x<32 ? color:SIMD3<Float>(0.3,0.3,0.3)
      return .init(c.x*alpha,c.y*alpha,c.z*alpha,alpha)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:64*16,size:.init(width:64,height:16),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage)->[Float] {
    var values=[Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4)
    DevelopmentColorEngineV3.context.render(image,toBitmap:&values,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB);return values
  }
  func testPurpleAndGreenBandsRespondAtEdgesAndPreserveAlpha()throws {
    for (color,purple) in [(SIMD3<Float>(0.5,0.1,0.6),true),(SIMD3<Float>(0.1,0.6,0.2),false)] {
      let input=fixture(color),original=read(input)
      var d=DevelopmentDefringeV3(enabled:true);if purple{d.purpleAmount=100}else{d.greenAmount=100}
      let actual=read(try DevelopmentDefringeEngineV3.apply(.init(defringe:d),to:input))
      XCTAssertTrue(zip(actual,original).contains{abs($0.0-$0.1)>1e-5})
      for index in stride(from:3,to:actual.count,by:4){XCTAssertEqual(actual[index],original[index],accuracy:1e-6)}
      if purple{d.purpleHueLower=10;d.purpleHueUpper=80}else{d.greenHueLower=10;d.greenHueUpper=80}
      let excluded=read(try DevelopmentDefringeEngineV3.apply(.init(defringe:d),to:input))
      XCTAssertEqual(excluded.map(\.bitPattern),original.map(\.bitPattern))
    }
  }
  func testOptionalRecipeCommandsAndRangeValidation()throws {
    let original=DevelopmentRecipe(adjustmentsV3:.init())
    let data=try JSONEncoder().encode(original.adjustmentsV3!)
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:data)as? [String:Any])["optics"])
    let active=DevelopmentOpticsV3(defringe:.init(enabled:true,purpleAmount:80))
    let changed=try original.applying(.setParameters(.optics(active)))
    XCTAssertEqual(changed.adjustmentsV3?.optics,active)
    let disabled=try changed.applying(.setEnabled(.optics,false))
    XCTAssertFalse(disabled.adjustmentsV3?.optics?.defringe.enabled == true)
    let reset=try changed.applying(.reset(.optics));XCTAssertNil(reset.adjustmentsV3?.optics)
    XCTAssertThrowsError(try DevelopmentDefringeV3(purpleHueLower:320,purpleHueUpper:310).validate())
  }
}
