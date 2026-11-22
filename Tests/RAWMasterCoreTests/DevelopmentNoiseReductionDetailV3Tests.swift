import XCTest
@testable import RAWMasterCore

final class DevelopmentNoiseReductionDetailV3Tests:XCTestCase {
  func testOptionalDetailControlsRoundTripWithoutChangingLegacyBytesOrNativeMapping()throws {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let legacy=DevelopmentNoiseReductionV3(enabled:true,sourceCapability:.raw,luminanceNoise:0.2,colorNoise:0.3,detail:0.8)
    let data=try encoder.encode(legacy),object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    XCTAssertNil(object["luminanceContrast"]);XCTAssertNil(object["colorDetail"])
    XCTAssertEqual(try encoder.encode(JSONDecoder().decode(DevelopmentNoiseReductionV3.self,from:data)),data)
    var advanced=legacy;advanced.luminanceContrast=0.4;advanced.colorDetail=0.6
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentNoiseReductionV3.self,from:encoder.encode(advanced)),advanced)
    let defaults=DevelopmentRAWNoiseReductionDefaultsV3(luminance:0.1,color:0.2,detail:0.7,luminanceSupported:true,colorSupported:true,detailSupported:true)
    XCTAssertEqual(try defaults.resolving(advanced),try defaults.resolving(legacy),"Image-domain controls must not alter native RAW decoder keys")
  }
  func testDetailControlValidationIncludesDisabledRememberedValues()throws {
    for value in [DevelopmentNoiseReductionV3(luminanceContrast:-0.01),.init(luminanceContrast:1.01),.init(luminanceContrast:.nan),
                  .init(colorDetail:-0.01),.init(colorDetail:1.01),.init(colorDetail:.infinity)] {
      XCTAssertThrowsError(try value.validate());XCTAssertThrowsError(try JSONEncoder().encode(value))
    }
    XCTAssertNoThrow(try DevelopmentNoiseReductionV3(luminanceContrast:0,colorDetail:1).validate())
  }
}
