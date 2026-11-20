import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentCurveDisplayModelTests: XCTestCase {
  private func shaped() -> DevelopmentCurve {
    .init(points:[.init(x:0,y:0),.init(x:0.3,y:0.15),.init(x:0.7,y:0.9),.init(x:1,y:1)])
  }
  func testLegacyDescriptorIsExactAndDoesNotChangeRecipeEncodingOrFingerprint() throws {
    let curve=shaped(), display=try DevelopmentCurveDisplayModel(curve:curve,algorithm:.legacyPCHIPV1)
    var recipe=try DevelopmentRecipe().promotingToV3()
    recipe.adjustmentsV3!.curves = .init(enabled:true,rgb:.init(curve:curve))
    let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    let before=try encoder.encode(recipe), fp=try EditingFingerprint.of(recipe)
    for x in [-0.25,0,0.123456789,0.3,0.5,0.7,1,1.25] {
      XCTAssertEqual(try display.value(at:x),try curve.value(at:x))
    }
    XCTAssertTrue(display.matches(curve));XCTAssertFalse(display.matches(.init()))
    XCTAssertEqual(try encoder.encode(recipe),before);XCTAssertEqual(try EditingFingerprint.of(recipe),fp)
  }
  func testNewDescriptorUsesFrozenF32NaturalEvaluatorAndIsAnImmutableSendableValue() throws {
    let curve=shaped(), model=try DevelopmentNaturalCubicCurvesV1.model(curve)
    let display=try DevelopmentCurveDisplayModel(curve:curve,algorithm:.naturalCubicGamma512LumaV1)
    func sendableValue<T: Sendable>(_ value:T)->T { value }
    let copy=sendableValue(display)
    for x in [-0.25,0,0.123456789,0.3,0.5,0.7,1,1.25] {
      let expected=try DevelopmentNaturalCubicCurvesV1.evaluate(model,Float(x))
      XCTAssertEqual(Float(try display.value(at:x)).bitPattern,expected.bitPattern)
      XCTAssertEqual(try copy.value(at:x),try display.value(at:x))
    }
    XCTAssertGreaterThan(abs(try display.value(at:0.5)-curve.value(at:0.5)),0.001)
    let constant=DevelopmentCurve(points:[.init(x:0,y:0.25),.init(x:1,y:0.25)])
    let fixed=try DevelopmentCurveDisplayModel(curve:constant,algorithm:.naturalCubicGamma512LumaV1)
    for x in [-1.0,0,0.5,1,2] { XCTAssertEqual(try fixed.value(at:x),0.25) }
  }
  func testNonfiniteAndFloatCoordinateOverflowAreRejectedBeforeEvaluation() throws {
    let display=try DevelopmentCurveDisplayModel(curve:shaped(),algorithm:.naturalCubicGamma512LumaV1)
    for x in [Double.nan,.infinity,-.infinity,Double.greatestFiniteMagnitude] {
      XCTAssertThrowsError(try display.value(at:x))
    }
    let invalid=DevelopmentCurve(points:[.init(x:0,y:0),.init(x:0,y:0.5),.init(x:1,y:1)])
    XCTAssertThrowsError(try DevelopmentCurveDisplayModel(curve:invalid,algorithm:.naturalCubicGamma512LumaV1))
  }
}
