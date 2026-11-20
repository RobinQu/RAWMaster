import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class PhotosBrillianceAdaptiveTests:XCTestCase {
  func testDirectBrillianceEditSelectsAdaptiveButOtherLightEditsPreserveOldRecipe()throws {
    var old=DevelopmentAdjustmentsV3();old.light = .init(enabled:true,brilliance:0.3)
    let fields=PhotosScalarField.fields(for:.light,noiseReduction:.image)
    let brilliance=try XCTUnwrap(fields.first(where:{$0.id=="brilliance"}))
    let exposure=try XCTUnwrap(fields.first(where:{$0.id=="exposure"}))
    let edit=try PhotosAdjustmentCommands.scalar(brilliance,group:.light,value:0.4,parameters:old,noiseReduction:.image)
    guard case .setParameters(.light(let changed))=edit else {return XCTFail("light command")}
    XCTAssertEqual(changed.brillianceVersion,.adaptiveLocalV1);XCTAssertEqual(changed.brilliance,0.4)
    let unrelated=try PhotosAdjustmentCommands.scalar(exposure,group:.light,value:0.2,parameters:old,noiseReduction:.image)
    guard case .setParameters(.light(let retained))=unrelated else {return XCTFail("light command")}
    XCTAssertNil(retained.brillianceVersion);XCTAssertEqual(retained.brilliance,0.3)
    XCTAssertNil(old.light.brillianceVersion)
  }
}
