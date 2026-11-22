import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosMixerOrganizationTests:XCTestCase {
  func testMixerModesMapExistingHSLValuesAndRanges() {
    let color=DevelopmentSelectiveColorAdjustmentV3(slot:.green,hue:20,saturation:-30,luminance:40)
    XCTAssertEqual(PhotosMixerOrganization.color.value(color),20)
    XCTAssertEqual(PhotosMixerOrganization.hue.value(color),20)
    XCTAssertEqual(PhotosMixerOrganization.saturation.value(color),-30)
    XCTAssertEqual(PhotosMixerOrganization.luminance.value(color),40)
    XCTAssertEqual(PhotosMixerOrganization.hue.range,-60...60)
    XCTAssertEqual(PhotosMixerOrganization.saturation.range,-100...100)
    XCTAssertEqual(PhotosMixerOrganization.luminance.range,-70...70)
    var edited=color;edited[keyPath:PhotosMixerOrganization.saturation.path]=55
    XCTAssertEqual(edited.saturation,55);XCTAssertEqual(edited.hue,20);XCTAssertEqual(edited.luminance,40)
    XCTAssertEqual(DevelopmentSelectiveColorSlotV3.allCases.count,8)
  }
}
