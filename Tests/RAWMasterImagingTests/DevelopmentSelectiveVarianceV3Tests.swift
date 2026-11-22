import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentSelectiveVarianceV3Tests: XCTestCase {
  private func parameters(_ variance:Double?)->DevelopmentAdjustmentsV3 {
    var p=DevelopmentAdjustmentsV3()
    p.selectiveColor.colors[0].sampledColor = .init(red:1,green:0,blue:0)
    p.selectiveColor.colors[0].variance=variance;p.selectiveColor.enabled=true
    return p
  }
  private func render(_ variance:Double?)throws->SIMD3<Double> {
    let values:[Float]=[0.225,0.06,0.04,0.5]
    let source=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:16,size:.init(width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let output=try DevelopmentGlobalEngineV3.apply(parameters(variance),to:source,sourceIsRAW:false)
    var p=SIMD4<Float>.zero
    withUnsafeMutableBytes(of:&p){bytes in DevelopmentColorEngineV3.context.render(output,toBitmap:bytes.baseAddress!,rowBytes:16,bounds:.init(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)}
    return .init(DevelopmentColorEngineV2.encode(Double(p.x/p.w)),DevelopmentColorEngineV2.encode(Double(p.y/p.w)),DevelopmentColorEngineV2.encode(Double(p.z/p.w)))
  }
  private func saturation(_ c:SIMD3<Double>)->Double { let hi=max(c.x,max(c.y,c.z)),lo=min(c.x,min(c.y,c.z));return hi>0 ? (hi-lo)/hi:0 }
  private func redDistance(_ c:SIMD3<Double>)->Double { min(DevelopmentGlobalEngineV3.hue(c),1-DevelopmentGlobalEngineV3.hue(c)) }
  func testVarianceConvergesAndDivergesWithoutOtherShifts()throws {
    let base=try render(nil),toward=try render(100),away=try render(-100)
    XCTAssertGreaterThan(saturation(toward),saturation(base))
    XCTAssertLessThan(redDistance(toward),redDistance(base))
    XCTAssertLessThan(saturation(away),saturation(base))
    XCTAssertGreaterThan(redDistance(away),redDistance(base))
    XCTAssertNil(try DevelopmentRendererV3.legacyEquivalent(.init(adjustmentsV3:parameters(20))))
  }
  func testVarianceIsOptionalValidatedAndRoundTrips()throws {
    let legacy=DevelopmentSelectiveColorAdjustmentV3(slot:.red)
    let data=try JSONEncoder().encode(legacy)
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:data)as? [String:Any])["variance"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentSelectiveColorAdjustmentV3.self,from:data),legacy)
    let active=DevelopmentSelectiveColorAdjustmentV3(slot:.red,variance:35)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentSelectiveColorAdjustmentV3.self,from:JSONEncoder().encode(active)),active)
    XCTAssertThrowsError(try DevelopmentSelectiveColorAdjustmentV3(slot:.red,variance:101).validate())
  }
  func testVisualiseRangeShowsSelectedBandAndIsNotInLegacyWire()throws {
    let values:[Float]=[1,0,0,1, 0,0,1,1]
    let input=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:32,size:.init(width:2,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    var p=DevelopmentAdjustmentsV3();p.selectiveColor.enabled=true;p.selectiveColor.visualiseRange = .red
    let output=try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false)
    var pixels=[SIMD4<Float>](repeating:.zero,count:2)
    DevelopmentColorEngineV3.context.render(output,toBitmap:&pixels,rowBytes:32,bounds:.init(x:0,y:0,width:2,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    XCTAssertEqual(pixels[0].x,1,accuracy:1e-5);XCTAssertEqual(pixels[0].w,1)
    XCTAssertEqual(pixels[1].x,0,accuracy:1e-5);XCTAssertEqual(pixels[1].w,1)
    XCTAssertNil(try DevelopmentRendererV3.legacyEquivalent(.init(adjustmentsV3:p)))

    let legacy=DevelopmentSelectiveColorV3()
    let data=try JSONEncoder().encode(legacy)
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:data)as? [String:Any])["visualiseRange"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentSelectiveColorV3.self,from:data),legacy)
    p.selectiveColor.visualiseRange=nil
    XCTAssertNil(p.selectiveColor.visualiseRange)
  }
}
