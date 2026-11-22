import XCTest
@testable import RAWMasterCore

final class DevelopmentTargetedCurveAdjustmentV3Tests:XCTestCase {
  func testParametricRegionsRespectCurrentSplitsAndOnlyChangeTheStartingRegion() throws {
    typealias Target = DevelopmentTargetedCurveAdjustmentV3
    let curve = DevelopmentParametricCurveV3(lights: 40, split1: 0.1, split2: 0.35, split3: 0.9)
    for (tone, expected): (Double, Target.Region) in [(0, .shadows), (0.1, .darks), (0.35, .lights), (0.9, .highlights), (1, .highlights)] {
      XCTAssertEqual(try Target.region(tone: tone, curve: curve), expected)
    }
    let baseline = DevelopmentCurvesV3(parametric: curve)
    XCTAssertEqual(try Target.applyParametric(initial: baseline, region: .lights, translation: .zero), baseline)
    let up = try Target.applyParametric(initial: baseline, region: .lights, translation: .init(0.05, 0.4))
    XCTAssertEqual(up.parametric?.lights, 100)
    let left = try Target.applyParametric(initial: baseline, region: .lights, translation: .init(-0.5, 0.1))
    var expected = curve
    expected.lights = -60
    XCTAssertEqual(left.parametric, expected)
    XCTAssertEqual(left.rgb, baseline.rgb)
    XCTAssertThrowsError(try Target.region(tone: .nan, curve: curve))
    XCTAssertThrowsError(try Target.applyParametric(initial: baseline, region: .lights, translation: .init(0, .infinity)))
  }

  func testPointCurveDragUsesStableBaselineAndOwnChannel()throws {
    var channel=DevelopmentCurveChannelV3();channel.curve = .init(points:[.init(x:0,y:0),.init(x:0.5,y:0.4),.init(x:1,y:1)])
    var initial=DevelopmentCurvesV3();initial.rgb=channel
    let moved=try DevelopmentTargetedCurveAdjustmentV3.applyPoint(initial:initial,channel:.rgb,pointIndex:1,translation:.init(x:0.1,y:0.2))
    XCTAssertEqual(moved.rgb.curve.points[1].x,0.6,accuracy:1e-12);XCTAssertEqual(moved.rgb.curve.points[1].y,0.6,accuracy:1e-12);XCTAssertEqual(moved.red,initial.red)
    let reverse=try DevelopmentTargetedCurveAdjustmentV3.applyPoint(initial:initial,channel:.rgb,pointIndex:1,translation:.init(x:-0.1,y:-0.2))
    XCTAssertEqual(reverse.rgb.curve.points[1].x,0.4,accuracy:1e-12);XCTAssertEqual(reverse.rgb.curve.points[1].y,0.2,accuracy:1e-12)
    let endpoint=try DevelopmentTargetedCurveAdjustmentV3.applyPoint(initial:initial,channel:.rgb,pointIndex:0,translation:.init(x:0.2,y:0.1))
    XCTAssertEqual(endpoint.rgb.curve.points[0],.init(x:0,y:0.1))
    XCTAssertThrowsError(try DevelopmentTargetedCurveAdjustmentV3.applyPoint(initial:initial,channel:.rgb,pointIndex:1,translation:.init(x:1.1,y:0)))
  }
}
