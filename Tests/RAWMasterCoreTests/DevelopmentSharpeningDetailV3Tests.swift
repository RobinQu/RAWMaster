import XCTest
@testable import RAWMasterCore

final class DevelopmentSharpeningDetailV3Tests: XCTestCase {
  func testExplicitRadiusDetailMaskingRoundTripAndLegacyBytesStayUnchanged() throws {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let legacy=DevelopmentSharpenV3(enabled:true,intensity:0.8,edges:0.22,falloff:0.69)
    let data=try encoder.encode(legacy)
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    XCTAssertNil(object["radius"]);XCTAssertNil(object["detail"]);XCTAssertNil(object["masking"]);XCTAssertNil(object["visualiseMasking"])
    XCTAssertEqual(try encoder.encode(JSONDecoder().decode(DevelopmentSharpenV3.self,from:data)),data)
    let advanced=DevelopmentSharpenV3(enabled:true,intensity:0.8,radius:1.4,detail:0.65,masking:0.35,visualiseMasking:true)
    let advancedData=try encoder.encode(advanced)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentSharpenV3.self,from:advancedData),advanced)
    let advancedObject=try XCTUnwrap(JSONSerialization.jsonObject(with:advancedData) as? [String:Any])
    XCTAssertEqual(advancedObject["radius"] as? Double,1.4);XCTAssertEqual(advancedObject["detail"] as? Double,0.65);XCTAssertEqual(advancedObject["masking"] as? Double,0.35);XCTAssertEqual(advancedObject["visualiseMasking"] as? Bool,true)
  }
  func testNewSharpeningParametersValidateEvenWhenDisabled() throws {
    for value in [DevelopmentSharpenV3(radius:0.49),.init(radius:3.01),.init(radius:.nan),
                  .init(detail:-0.01),.init(detail:1.01),.init(masking:-0.01),.init(masking:1.01)] {
      XCTAssertThrowsError(try value.validate());XCTAssertThrowsError(try JSONEncoder().encode(value))
    }
    XCTAssertNoThrow(try DevelopmentSharpenV3(radius:0.5,detail:0,masking:0).validate())
    XCTAssertNoThrow(try DevelopmentSharpenV3(radius:3,detail:1,masking:1).validate())
  }
}
