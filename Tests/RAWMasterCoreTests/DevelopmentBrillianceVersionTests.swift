import Foundation
import XCTest
@testable import RAWMasterCore

final class DevelopmentBrillianceVersionTests:XCTestCase {
  private func canonical<T:Encodable>(_ value:T)throws->Data {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(value)}
  func testAbsentVersionRetainsExactOldLightBytesAndRecipeFingerprint()throws {
    let old=Data(#"{"blackPoint":0,"brightness":0,"brilliance":0,"contrast":0,"enabled":false,"exposure":0,"highlights":0,"shadows":0}"#.utf8)
    let decoded=try JSONDecoder().decode(DevelopmentLightV3.self,from:old)
    XCTAssertNil(decoded.brillianceVersion);XCTAssertEqual(try canonical(decoded),old)
    var a=DevelopmentAdjustmentsV3(),b=a;b.light=decoded
    let first=DevelopmentRecipe(adjustmentsV3:a),second=DevelopmentRecipe(adjustmentsV3:b)
    XCTAssertEqual(try EditingFingerprint.of(first),try EditingFingerprint.of(second))
    a.light.brillianceVersion = .publicTiledJointFixed050V1
    XCTAssertNotEqual(try EditingFingerprint.of(DevelopmentRecipe(adjustmentsV3:a)),try EditingFingerprint.of(first))
  }
  func testNamedFixedAmountRoundtripAndUnsupportedAmountFailClosed()throws {
    let value=DevelopmentLightV3(enabled:true,brilliance:0.5,brillianceVersion:.publicTiledJointFixed050V1)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentLightV3.self,from:canonical(value)),value)
    var bad=value;bad.brilliance=0.25;XCTAssertThrowsError(try bad.validate())
    bad=value;bad.shadows=0.1;XCTAssertThrowsError(try bad.validate())
    let bytes=try canonical(value),text=String(decoding:bytes,as:UTF8.self)
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentLightV3.self,from:Data(text.replacingOccurrences(of:"publicTiledJointFixed050V1",with:"future-unknown").utf8)))
  }
  func testAdaptiveAmountsAndCombinedLightRoundtripWithoutChangingFixedDomain()throws {
    for amount in [-2.0,-0.5,-0.0001,0,0.0001,0.5,1,2] {
      let value=DevelopmentLightV3(enabled:true,brilliance:amount,brillianceVersion:.adaptiveLocalV1,
        exposure:0.25,highlights:-0.3,shadows:0.4,brightness:0.1,contrast:0.2,blackPoint:0.1)
      XCTAssertNoThrow(try value.validate())
      XCTAssertEqual(try JSONDecoder().decode(DevelopmentLightV3.self,from:canonical(value)),value)
    }
    var invalid=DevelopmentLightV3(enabled:true,brilliance:2.001,brillianceVersion:.adaptiveLocalV1)
    XCTAssertThrowsError(try invalid.validate());invalid.brilliance = .nan
    XCTAssertThrowsError(try invalid.validate())
  }

}
