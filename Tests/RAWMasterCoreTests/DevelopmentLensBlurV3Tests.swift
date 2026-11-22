import XCTest
@testable import RAWMasterCore

final class DevelopmentLensBlurV3Tests:XCTestCase {
  func testOptionalEffectsStorageAndValidation()throws {
    let legacy=DevelopmentEffectsV3(enabled:true,grain:0.3)
    let data=try JSONEncoder().encode(legacy),object=try XCTUnwrap(JSONSerialization.jsonObject(with:data)as? [String:Any])
    XCTAssertNil(object["lensBlur"]);XCTAssertEqual(try JSONDecoder().decode(DevelopmentEffectsV3.self,from:data),legacy)
    for style in DevelopmentLensBokehStyleV3.allCases {
      let effects=DevelopmentEffectsV3(lensBlur:.init(enabled:true,amount:0.5,focusX:0.4,focusY:0.6,focusRange:0.2,bokehStyle:style))
      XCTAssertEqual(try JSONDecoder().decode(DevelopmentEffectsV3.self,from:JSONEncoder().encode(effects)),effects)
    }
    let refined=DevelopmentLensBlurV3(catEyeAmount:0.6,bokehBoost:0.7)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentLensBlurV3.self,from:JSONEncoder().encode(refined)),refined)
    let payload=try DevelopmentLensBlurDepthPayloadV1(kind:.depth,width:2,height:2,values:[0,0.25,0.75,1])
    let withDepth=DevelopmentLensBlurV3(deviceDepth:payload)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentLensBlurV3.self,from:JSONEncoder().encode(withDepth)),withDepth)
    XCTAssertEqual(try payload.values(),[0,0.25,0.75,1])
    XCTAssertThrowsError(try DevelopmentLensBlurDepthPayloadV1(kind:.depth,width:2,height:2,values:[0]))
    XCTAssertThrowsError(try DevelopmentLensBlurDepthPayloadV1(kind:.depth,width:2,height:2,values:[0,.nan,0.5,1]))
    for invalid in [DevelopmentLensBlurV3(amount:-0.01),.init(amount:1.01),.init(focusX:.nan),.init(focusY:-0.1),.init(focusRange:1.1),
                    .init(catEyeAmount:-0.1),.init(catEyeAmount:1.1),.init(bokehBoost:-0.1),.init(bokehBoost:1.1)] {
      XCTAssertThrowsError(try invalid.validate())
    }
  }
  func testRefinementBrushAndStrokeRoundTripAndLimits()throws {
    let brush=DevelopmentLensBlurRefinementBrushV3(amount:0.8,size:0.12,feather:0.4,flow:0.3,autoMask:true)
    let stroke=DevelopmentLensBlurRefinementStrokeV3(mode:.focus,stroke:.init(points:[.init(position:.init(x:0.2,y:0.3))],radiusInShortEdge:0.12,strength:0.8),feather:0.4,flow:0.3,autoMask:true)
    let value=DevelopmentLensBlurV3(refinementBrush:brush,refinementStrokes:[stroke])
    let encoded=try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentLensBlurV3.self,from:encoded),value)
    let legacy=try JSONEncoder().encode(DevelopmentLensBlurV3())
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:legacy)as? [String:Any])["refinementStrokes"])
    for invalid in [DevelopmentLensBlurRefinementBrushV3(amount:-0.1),.init(amount:1.1),.init(size:0),.init(size:1.1),.init(feather:-0.1),.init(flow:1.1)] {
      XCTAssertThrowsError(try invalid.validate())
    }
    XCTAssertThrowsError(try DevelopmentLensBlurRefinementStrokeV3.validateStrokes(Array(repeating:stroke,count:65)))
  }
}
