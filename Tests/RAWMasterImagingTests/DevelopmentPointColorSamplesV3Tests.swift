import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentPointColorSamplesV3Tests: XCTestCase {
  func testIndependentSamplesHaveActualGPUResponseAndDeterministicOrder()throws {
    let values:[Float]=[1,0,0,1, 0,0,1,1]
    let input=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:32,size:.init(width:2,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let red=DevelopmentPointColorSampleV3(sampledColor:.init(red:1,green:0,blue:0),hue:25,saturation:20,range:0.5)
    let blue=DevelopmentPointColorSampleV3(sampledColor:.init(red:0,green:0,blue:1),hue:-30,luminance:25,range:0.5)
    var p=DevelopmentAdjustmentsV3();p.selectiveColor.enabled=true;p.selectiveColor.pointColors=[red,blue]
    let output=try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false)
    var actual=[SIMD4<Float>](repeating:.zero,count:2)
    DevelopmentColorEngineV3.context.render(output,toBitmap:&actual,rowBytes:32,bounds:.init(x:0,y:0,width:2,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    XCTAssertNotEqual(actual[0],SIMD4<Float>(1,0,0,1));XCTAssertNotEqual(actual[1],SIMD4<Float>(0,0,1,1))
    p.selectiveColor.pointColors=[blue,red]
    var reordered=[SIMD4<Float>](repeating:.zero,count:2)
    DevelopmentColorEngineV3.context.render(try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false),toBitmap:&reordered,rowBytes:32,bounds:.init(x:0,y:0,width:2,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    XCTAssertEqual(actual,reordered)
  }
  func testOptionalWireEightSampleLimitAndUniqueIDs()throws {
    let legacy=DevelopmentSelectiveColorV3(),data=try JSONEncoder().encode(legacy)
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:data)as? [String:Any])["pointColors"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentSelectiveColorV3.self,from:data),legacy)
    let sample=DevelopmentPointColorSampleV3(sampledColor:.init(red:1,green:0,blue:0),variance:20)
    let value=DevelopmentSelectiveColorV3(pointColors:[sample])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentSelectiveColorV3.self,from:JSONEncoder().encode(value)),value)
    XCTAssertThrowsError(try DevelopmentSelectiveColorV3(pointColors:Array(repeating:sample,count:9)).validate())
    XCTAssertThrowsError(try DevelopmentSelectiveColorV3(pointColors:[sample,sample]).validate())
  }
}
