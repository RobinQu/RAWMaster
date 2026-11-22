import RAWMasterCore
import XCTest

final class DevelopmentAIDenoiseTests: XCTestCase {
    func testUnsupportedNestedKeysAndInvalidAmountAreRejectedOnDecode() throws {
        for invalid in [
            #"{"model":"apple-core-image-raw9-v1","amount":10,"futureDecoder":true}"#,
            #"{"model":"apple-core-image-raw9-v1","amount":101}"#,
            #"{"model":"apple-core-image-raw9-v1"}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentAIDenoiseV1.self, from: Data(invalid.utf8)))
        }
    }
    func testOptionalModelAndAmountRoundTripResetAndConflicts() throws {
        var payload = DevelopmentAdjustmentsV3()
        payload.rawDecoder = .flashRaw031
        let original = DevelopmentRecipe(adjustmentsV3: payload)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(original), as: UTF8.self).contains("aiDenoise"))
        for model in [DevelopmentAIDenoiseV1.Model.appleRAW9, .appleRAW9DNG] {
            let low = try original.applying(.setAIDenoise(.init(model: model, amount: 0)))
            let high = try low.applying(.setAIDenoise(.init(model: model, amount: 100)))
            XCTAssertEqual(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(high)), high)
            XCTAssertNotEqual(try EditingFingerprint.of(low), try EditingFingerprint.of(high))
            XCTAssertNotEqual(low.adjustmentsV3?.aiDenoise?.inputContract, high.adjustmentsV3?.aiDenoise?.inputContract)
            XCTAssertEqual(try high.applying(.setAIDenoise(nil)), original)
            XCTAssertEqual(try high.applying(.resetAll), original)
            XCTAssertThrowsError(try high.applying(.setRawDetails(.bayerAHD)))
            XCTAssertThrowsError(try low.applying(.setAIDenoise(.init(model: model, amount: 101))))
        }
        let image = DevelopmentAdjustmentCommandContext(source: .init(sourceContentID: String(repeating: "a", count: 64),
            exifOrientation: 1, orientedWidth: 4000, orientedHeight: 3000), sourceGeneration: 1,
            analysisStage: .workingImageBeforeGeometry, sourceCapability: .image)
        XCTAssertThrowsError(try original.applying(.setAIDenoise(.init(model: .appleRAW9)), context: image))
    }
}
