import Foundation
import XCTest
import RAWMasterCore

final class DevelopmentRawDetailsTests: XCTestCase {
  func testOldNeutralRecipeAndPinnedDemosaicRoundTripAndReset() throws {
    var payload = DevelopmentAdjustmentsV3()
    payload.rawDecoder = .flashRaw031
    let base = DevelopmentRecipe(adjustmentsV3: payload)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(base), as: UTF8.self).contains("rawDetails"))
    for mode in DevelopmentRawDetails.allCases {
      let changed = try base.applying(.setRawDetails(mode))
      let saved = try JSONEncoder().encode(changed)
      XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains(mode.rawValue))
      XCTAssertEqual(try DevelopmentRecipe.decodeJSON(saved), changed)
      XCTAssertNotEqual(try EditingFingerprint.of(base), try EditingFingerprint.of(changed))
      XCTAssertEqual(try changed.applying(.setRawDetails(nil)), base)
      XCTAssertEqual(try changed.applying(.resetAll), base)
    }
  }
}
