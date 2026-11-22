import XCTest
import RAWMasterCore
@testable import RAWMaster

final class PhotosCurveResetChannelTests: XCTestCase {
  func testResetOnlySelectedChannelAndPreserveOtherCurveState()throws {
    var value=DevelopmentCurvesV3(enabled:true,algorithm:.naturalCubicGamma512LumaV1,refineSaturation:25)
    value.rgb.curve = .init(points:[.init(x:0,y:0),.init(x:0.2,y:0.5),.init(x:1,y:1)])
    value.red.curve = value.rgb.curve;value.green.curve=value.rgb.curve;value.blue.curve=value.rgb.curve
    value.red.inputBlack=0.1;value.parametric = .init(highlights:15)
    for channel in DevelopmentCurveChannel.allCases {
      let reset=try PhotosCurveParameterControls.resetting(value,channel:channel)
      XCTAssertEqual(reset[keyPath:keyPath(channel)],.init())
      for other in DevelopmentCurveChannel.allCases where other != channel {
        XCTAssertEqual(reset[keyPath:keyPath(other)],value[keyPath:keyPath(other)])
      }
      XCTAssertEqual(reset.parametric,value.parametric);XCTAssertEqual(reset.refineSaturation,25)
      XCTAssertEqual(reset.enabled,true);XCTAssertEqual(reset.algorithm,.naturalCubicGamma512LumaV1)
    }
  }
  private func keyPath(_ channel:DevelopmentCurveChannel)->WritableKeyPath<DevelopmentCurvesV3,DevelopmentCurveChannelV3> {
    switch channel { case .rgb:\.rgb;case .red:\.red;case .green:\.green;case .blue:\.blue }
  }
}
