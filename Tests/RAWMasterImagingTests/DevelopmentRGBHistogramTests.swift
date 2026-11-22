import XCTest
@testable import RAWMasterImaging

final class DevelopmentRGBHistogramTests: XCTestCase {
    func testKnownRGBAndTransparentPixelsUseEncodedChannelsInOnePass() throws {
        // Linear 0.5 encodes to sRGB 0.7353, therefore bin 187 after floor.
        let pixels = DevelopmentDisplayHistogramEngineV1.ProxyPixels(rgba: [
            0.5, 0, 0, 1,
            0, 0.125, 0, 0.25,
            0, 0, 0.5, 0
        ], width: 3, height: 1)
        let result = try DevelopmentDisplayHistogramEngineV1.histogram(pixels)
        XCTAssertEqual(result.visibleSamples, 2)
        XCTAssertEqual(result.transparentSamples, 1)
        XCTAssertEqual(result.red[187], 1)
        XCTAssertEqual(result.green[187], 1, "Premultiplied green unpremultiplies to 0.5")
        XCTAssertEqual(result.blue[0], 2)
        XCTAssertEqual(result.red.reduce(0, +), 2)
        XCTAssertEqual(result.green.reduce(0, +), 2)
        XCTAssertEqual(result.blue.reduce(0, +), 2)
        let row = (DevelopmentDisplayHistogramV1.saturationBins - 1) * DevelopmentDisplayHistogramV1.hueBins
        XCTAssertEqual(result.chroma[row], 1)
        XCTAssertEqual(result.chroma[row + DevelopmentDisplayHistogramV1.hueBins / 3], 1)
        XCTAssertEqual(result.chroma.reduce(0, +), 2)
    }

    func testPartialOrInconsistentRGBPayloadIsRejected() {
        let bins = [UInt64](repeating: 0, count: 256)
        XCTAssertThrowsError(try DevelopmentDisplayHistogramV1(luminance: bins, visibleSamples: 0,
            transparentSamples: 1, sampledSize: .init(width: 1, height: 1), red: [1]).validate())
        XCTAssertThrowsError(try DevelopmentDisplayHistogramV1(luminance: bins, visibleSamples: 0,
            transparentSamples: 1, sampledSize: .init(width: 1, height: 1), red: bins, green: bins, blue: [1]).validate())
    }
}
