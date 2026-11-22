import AppKit
import XCTest
@testable import RAWMasterImaging

final class DevelopmentDisplayPixelTests: XCTestCase {
    @MainActor func testTopLeftOrientationColorConversionAndTransparency() throws {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                              0, 0, 255, 255, 0, 0, 0, 0]
        let cg = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let image = NSImage(cgImage: cg, size: NSSize(width: 2, height: 2))
        let red = try XCTUnwrap(DevelopmentDisplayPixel.sample(image, at: .init(x: 0, y: 0)))
        XCTAssertEqual(red.rgb.x, 1, accuracy: 0.002)
        XCTAssertEqual(red.rgb.y, 0, accuracy: 0.002)
        XCTAssertEqual(red.rgb.z, 0, accuracy: 0.002)
        XCTAssertEqual(red.lab.x, 54.29, accuracy: 0.3)
        XCTAssertEqual(red.lab.y, 80.81, accuracy: 0.4)
        XCTAssertEqual(red.lab.z, 69.89, accuracy: 0.4)
        let blue = try XCTUnwrap(DevelopmentDisplayPixel.sample(image, at: .init(x: 0, y: 1)))
        XCTAssertEqual(blue.rgb.z, 1, accuracy: 0.002)
        XCTAssertNil(DevelopmentDisplayPixel.sample(image, at: .init(x: 1, y: 1)))
        XCTAssertNil(DevelopmentDisplayPixel.sample(image, at: .init(x: -0.1, y: 0)))
    }
}
