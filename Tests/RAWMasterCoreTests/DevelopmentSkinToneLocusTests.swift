import XCTest
@testable import RAWMasterCore

final class DevelopmentSkinToneLocusTests: XCTestCase {
  private func chromaticity(_ rgb: DevelopmentSampledColorV3) -> DevelopmentChromaticityV3 {
    let xyz = DevelopmentRGBMatrixV3.apply(DevelopmentImageWhiteBalancePickV3.rgbToXYZ,[rgb.red,rgb.green,rgb.blue])
    let sum = xyz.reduce(0,+); return .init(x:xyz[0]/sum,y:xyz[1]/sum)
  }
  func testTargetSkinUnderD65EstimatesD65RatherThanItsGrayWhitePoint() throws {
    let skin = DevelopmentSkinToneLocusV3.targetLinearRGB, assumedGray = chromaticity(skin)
    let actual = try DevelopmentSkinToneLocusV3.illuminant(assumingGray:assumedGray,sample:skin,alpha:1)
    let sum = 0.95047+1+1.08883
    XCTAssertEqual(actual.x,0.95047/sum,accuracy:1e-12)
    XCTAssertEqual(actual.y,1/sum,accuracy:1e-12)
    XCTAssertGreaterThan(abs(actual.x-assumedGray.x)+abs(actual.y-assumedGray.y),0.01)
  }
  func testActualSkinColorChangesEstimateAndIntensityScalingDoesNot() throws {
    let a = DevelopmentSampledColorV3(red:0.45,green:0.28,blue:0.20)
    let b = DevelopmentSampledColorV3(red:0.40,green:0.21,blue:0.12)
    let x = try DevelopmentSkinToneLocusV3.illuminant(assumingGray:chromaticity(a),sample:a,alpha:1)
    let y = try DevelopmentSkinToneLocusV3.illuminant(assumingGray:chromaticity(b),sample:b,alpha:1)
    XCTAssertGreaterThan(abs(x.x-y.x)+abs(x.y-y.y),0.005)
    let half = DevelopmentSampledColorV3(red:b.red*0.5,green:b.green*0.5,blue:b.blue*0.5)
    let scaled = try DevelopmentSkinToneLocusV3.illuminant(assumingGray:chromaticity(half),sample:half,alpha:0.5)
    XCTAssertEqual(scaled.x,y.x,accuracy:1e-12); XCTAssertEqual(scaled.y,y.y,accuracy:1e-12)
  }
  func testGrayBlueClippedDarkAndInvalidAlphaCannotCallNativeSetters() throws {
    let invalid: [(DevelopmentSampledColorV3,Double)] = [
      (.init(red:0.2,green:0.2,blue:0.2),1),(.init(red:0.08,green:0.2,blue:0.5),1),
      (.init(red:1,green:0.5,blue:0.25),1),(.init(red:0.004,green:0.003,blue:0.0025),1),
      (.init(red:0.45,green:0.28,blue:0.2),0),(.init(red:0.45,green:0.28,blue:0.2),.nan),
      (.init(red:.nan,green:0.28,blue:0.2),1)]
    for (sample,alpha) in invalid {
      var grayCalls = 0, skinCalls = 0
      XCTAssertThrowsError(try DevelopmentSkinToneLocusV3.resolvingNativeTarget(sample:sample,alpha:alpha,estimateGray:{
        grayCalls += 1; return .init(x:0.4,y:0.35)
      },assignSkin:{ _ in skinCalls += 1; return .init(temperature:6000,tint:8) }))
      XCTAssertEqual(grayCalls,0); XCTAssertEqual(skinCalls,0)
    }
  }
  func testBadNativeChromaticityAndConeCannotReachSkinSetter() throws {
    let sample = DevelopmentSkinToneLocusV3.targetLinearRGB
    for xy in [DevelopmentChromaticityV3(x:0,y:0.3),.init(x:0.5,y:0.5),.init(x:.nan,y:0.3),.init(x:0.999,y:0.00001)] {
      var assigned = 0
      XCTAssertThrowsError(try DevelopmentSkinToneLocusV3.resolvingNativeTarget(sample:sample,alpha:1,estimateGray:{ xy },assignSkin:{ _ in
        assigned += 1; return .init(temperature:6000,tint:8)
      }))
      XCTAssertEqual(assigned,0)
    }
  }
  func testOnlyActualNativeTTReadbackIsPersistedWithVersionOne() throws {
    let sample = DevelopmentSkinToneLocusV3.targetLinearRGB, expected = DevelopmentNativeWhiteBalanceV3(temperature:6123.125,tint:7.25)
    var grayCalls = 0, skinCalls = 0
    let target = try DevelopmentSkinToneLocusV3.resolvingNativeTarget(sample:sample,alpha:1,estimateGray:{
      grayCalls += 1; return self.chromaticity(sample)
    },assignSkin:{ xy in
      skinCalls += 1; XCTAssertTrue(xy.x.isFinite && xy.y.isFinite && xy.x > 0 && xy.y > 0 && xy.x+xy.y < 1)
      return expected
    })
    XCTAssertEqual(grayCalls,1); XCTAssertEqual(skinCalls,1); XCTAssertEqual(target,expected)
    let pick = DevelopmentRawWhiteBalancePickV3(baseline:target)
    let data = try JSONEncoder().encode(pick), json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    XCTAssertEqual(json["version"] as? Int,1); XCTAssertNil(json["xy"]); XCTAssertNil(json["chromaticity"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentRawWhiteBalancePickV3.self,from:data).target(),expected)
  }
  func testImageSkinUsesSameDomainAndRemainsDistinctFromGray() throws {
    for sample in [DevelopmentSampledColorV3(red:0.2,green:0.2,blue:0.2),.init(red:0.1,green:0.2,blue:0.5)] {
      XCTAssertThrowsError(try DevelopmentImageWhiteBalancePickV3.skinTone(sampledLinearRGB:sample))
    }
    let sample = DevelopmentSkinToneLocusV3.targetLinearRGB
    XCTAssertNotEqual(try DevelopmentImageWhiteBalancePickV3.skinTone(sampledLinearRGB:sample).baseline,
      try DevelopmentImageWhiteBalancePickV3.neutralGray(sampledLinearRGB:sample).baseline)
  }
}
