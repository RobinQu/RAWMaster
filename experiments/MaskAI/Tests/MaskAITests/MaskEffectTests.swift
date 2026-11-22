import XCTest
@testable import MaskAI

final class MaskEffectTests: XCTestCase {
    func testExposureAffectsOnlySelectedPixels() throws {
        let base = try NativeImage(width: 4, height: 1, rgba: [
            64, 64, 64, 255, 64, 64, 64, 255, 64, 64, 64, 255, 64, 64, 64, 255,
        ])
        let mask = try MaskImage(width: 4, height: 1, values: [0, 255, 255, 0])
        let result = try MaskEffectRenderer.applyExposure(to: base, mask: mask, exposureEV: 1)
        XCTAssertGreaterThan(result.metrics.selectedMeanAbsoluteChange, 0.01)
        XCTAssertLessThan(result.metrics.unselectedMeanAbsoluteChange, 0.0001)
        XCTAssertEqual(result.metrics.changedSelectedPixels, 2)
        XCTAssertEqual(result.image.rgba[4], result.image.rgba[8])
        XCTAssertEqual(result.image.rgba[0], 64)
        XCTAssertEqual(result.image.rgba[12], 64)
    }

    func testEffectRejectsEmptyMask() throws {
        let base = try NativeImage(width: 1, height: 1, rgba: [0, 0, 0, 255])
        let mask = MaskImage.empty(width: 1, height: 1)
        XCTAssertThrowsError(try MaskEffectRenderer.applyExposure(to: base, mask: mask))
    }
}
