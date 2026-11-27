import AppKit
import Metal
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentDisplayPixelTests: XCTestCase {
    func testLinearSamplersReadExactFITAndNativeWindowTexelsInTheirOwnPrimaries() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 2, height: 2, mipmapped: false)
        desc.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        // Top left has a straight 4× red with half alpha. The lower-right pixel is transparent.
        let pixels: [SIMD4<Float>] = [.init(2, 0, 0, 0.5), .init(0, 1, 0, 1), .init(0, 0, 1, 1), .zero]
        pixels.withUnsafeBytes { values in
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: values.baseAddress!, bytesPerRow: 32)
        }
        let native = CGSize(width: 4000, height: 6000)
        let fit = DevelopmentScenePreviewFrameV1(id: UUID(), texture: texture, target: .hdr2020, nativeSize: native, window: nil)
        let samples = DevelopmentDisplayPixel.linearSamples(fit, at: [.init(x: 0.499, y: 0.1), .init(x: 0.501, y: 0.1),
            .init(x: 1, y: 1), nil, .init(x: -0.1, y: 0)])
        XCTAssertEqual(samples[0]?.rgb, .init(4, 0, 0))
        XCTAssertEqual(try XCTUnwrap(samples[0]).luminanceNits, 105.08, accuracy: 0.001)
        XCTAssertEqual(samples[1]?.rgb, .init(0, 1, 0))
        XCTAssertEqual(try XCTUnwrap(samples[1]).luminanceNits, 67.8, accuracy: 0.001)
        XCTAssertTrue(samples[2...].allSatisfy { $0 == nil })
        let window = CGRect(x: 1000 / native.width, y: 2500 / native.height, width: 2 / native.width, height: 2 / native.height)
        let crop = DevelopmentScenePreviewFrameV1(id: UUID(), texture: texture, target: .sdr709, nativeSize: native, window: window)
        let inside = DevelopmentSourcePoint(x: 1000.5 / native.width, y: 2500.5 / native.height)
        let outside = DevelopmentSourcePoint(x: 999.5 / native.width, y: 2500.5 / native.height)
        let cropped = DevelopmentDisplayPixel.linearSamples(crop, at: [inside, outside])
        XCTAssertEqual(cropped[0]?.target, .sdr709)
        XCTAssertEqual(try XCTUnwrap(cropped[0]).luminanceNits, 85.04, accuracy: 0.001)
        XCTAssertNil(cropped[1])
    }

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
