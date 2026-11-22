import XCTest
@testable import RAWMasterCore

final class DevelopmentTargetedColorAdjustmentV3Tests:XCTestCase {
  func testTargetedDragAffectsAdjacentSlotsFromStableBaseline()throws {
    let initial=DevelopmentSelectiveColorV3()
    let sample=DevelopmentSampledColorV3(red:0.8,green:0.1,blue:0.1)
    let result=try DevelopmentTargetedColorAdjustmentV3.apply(initial:initial,sample:sample,mode:.saturation,drag:0.5)
    func value(_ slot:DevelopmentSelectiveColorSlotV3,in parameters:DevelopmentSelectiveColorV3)->Double {
      parameters.colors.first{$0.slot == slot}?.saturation ?? .nan
    }
    XCTAssertEqual(value(.red,in:result),50,accuracy:1e-6)
    XCTAssertEqual(value(.orange,in:result),12.5,accuracy:1e-6)
    XCTAssertEqual(value(.yellow,in:result),0,accuracy:1e-6)
    XCTAssertEqual(value(.blue,in:result),0,accuracy:1e-6)
    let weaker=try DevelopmentTargetedColorAdjustmentV3.apply(initial:initial,sample:sample,mode:.saturation,drag:0.25)
    XCTAssertEqual(value(.red,in:weaker),25,accuracy:1e-6)
    XCTAssertNotEqual(try DevelopmentTargetedColorAdjustmentV3.apply(initial:initial,sample:sample,mode:.hue,drag:0.5),result)
    XCTAssertNotEqual(try DevelopmentTargetedColorAdjustmentV3.apply(initial:initial,sample:sample,mode:.luminance,drag:0.5),result)
    XCTAssertThrowsError(try DevelopmentTargetedColorAdjustmentV3.apply(initial:initial,sample:sample,mode:.hue,drag:1.1))
  }
}
