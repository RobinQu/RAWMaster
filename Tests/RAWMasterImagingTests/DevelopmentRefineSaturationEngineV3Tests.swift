import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentRefineSaturationEngineV3Tests: XCTestCase {
  private let input=CIImage(bitmapData:[Float]([0.2,0.1,0.05,0.5]).withUnsafeBytes{Data($0)},bytesPerRow:16,size:.init(width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  private func pixel(_ image:CIImage)->SIMD4<Float> {
    var p=SIMD4<Float>.zero
    withUnsafeMutableBytes(of:&p){bytes in DevelopmentColorEngineV3.context.render(image,toBitmap:bytes.baseAddress!,rowBytes:16,bounds:.init(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)};return p
  }
  private func saturation(_ p:SIMD4<Float>)->Double {
    let e=SIMD3<Double>(DevelopmentColorEngineV2.encode(Double(p.x/p.w)),DevelopmentColorEngineV2.encode(Double(p.y/p.w)),DevelopmentColorEngineV2.encode(Double(p.z/p.w)))
    let hi=max(e.x,max(e.y,e.z)),lo=min(e.x,min(e.y,e.z));return hi>0 ? (hi-lo)/hi:0
  }
  func testRefineSaturationChangesResponseAndPreservesAlpha()throws {
    var p=DevelopmentAdjustmentsV3();p.curves.enabled=true
    let base=pixel(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:input))
    p.curves.refineSaturation=50
    let richer=pixel(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:input))
    XCTAssertGreaterThan(saturation(richer),saturation(base));XCTAssertEqual(richer.w,base.w,accuracy:1e-6)
    p.curves.refineSaturation = -50
    let weaker=pixel(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:input))
    XCTAssertLessThan(saturation(weaker),saturation(base))
  }
  func testParametricRecursionAppliesRefineExactlyOnceAndLegacyWireStaysClosed()throws {
    var p=DevelopmentAdjustmentsV3();p.curves.enabled=true
    p.curves.parametric = .init(highlights:20,lights:10,darks:-10,shadows:-20)
    p.curves.refineSaturation=30
    var without=p;without.curves.refineSaturation=nil
    let developed=try DevelopmentColorEngineV3.applyCurvesAndLevels(without,to:input)
    let expected=pixel(try DevelopmentRefineSaturationEngineV3.apply(p.curves,to:developed))
    let actual=pixel(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:input))
    XCTAssertEqual(actual,expected)
    let legacy=DevelopmentCurvesV3(enabled:true)
    let data=try JSONEncoder().encode(legacy)
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:data)as? [String:Any])["refineSaturation"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentCurvesV3.self,from:data),legacy)
    XCTAssertThrowsError(try DevelopmentCurvesV3(refineSaturation:101).validate())
  }
}
