import CoreImage
import Foundation
import XCTest
@testable import MaskAI

final class RAWOrientationTests: XCTestCase {
    func testPortraitPreviewAndTopLeftCropFollowTheDecoder() throws {
        guard let path = ProcessInfo.processInfo.environment["MASK_AI_ORIENTATION_RAW"] else {
            throw XCTSkip("Set MASK_AI_ORIENTATION_RAW to the portrait RAW listed in spec 027.")
        }
        let url = URL(fileURLWithPath: path)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        raw.isDraftModeEnabled = false
        raw.scaleFactor = 1
        let decoded = try XCTUnwrap(raw.outputImage)
        let extent = decoded.extent
        XCTAssertTrue((5...8).contains(raw.orientation.rawValue))
        XCTAssertLessThan(extent.width, extent.height)

        let loaded = try RAWImageAdapter.load(url, maximumLongEdge: 360)
        XCTAssertEqual(loaded.info.nativeWidth, Int(extent.width))
        XCTAssertEqual(loaded.info.nativeHeight, Int(extent.height))
        let reference = try NativeImage(ciImage: decoded, maximumLongEdge: 360)
        XCTAssertEqual(loaded.image.width, reference.width)
        XCTAssertEqual(loaded.image.height, reference.height)
        XCTAssertTrue(loaded.image.rgba.elementsEqual(reference.rgba))

        // The upper left quarter has integral bounds for the archived 4000 × 6000 source.
        let bounds = CGRect(x: extent.minX, y: extent.midY,
                            width: extent.width / 2, height: extent.height / 2)
        let expected = try NativeImage(ciImage: decoded.cropped(to: bounds),
                                       maximumLongEdge: Int(max(bounds.width, bounds.height)))
        let crop = try RAWImageAdapter.loadCrop(url, rect: .init(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(crop.width, expected.width)
        XCTAssertEqual(crop.height, expected.height)
        XCTAssertTrue(crop.rgba.elementsEqual(expected.rgba))
    }
}
