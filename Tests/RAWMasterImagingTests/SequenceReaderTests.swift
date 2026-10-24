import XCTest
import Foundation
import ImageIO
import CoreImage
import CoreGraphics
import CryptoKit
@testable import RAWMasterImaging

final class SequenceReaderTests: XCTestCase {
    func image() throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 48 * 32 * 4)
        for y in 0..<32 { for x in 0..<48 {
            let i = (y * 48 + x) * 4
            bytes[i] = UInt8(x * 5); bytes[i + 1] = UInt8(y * 7); bytes[i + 2] = x < 12 && y < 6 ? 255 : 0
        } }
        return try XCTUnwrap(bytes.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: 48, height: 32,
            bitsPerComponent: 8, bytesPerRow: 48 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() })
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func write(_ image: CGImage, to url: URL, type: String = "public.tiff", orientation: Int = 1) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:34:56",
            kCGImagePropertyExifSubsecTimeOriginal: "123", kCGImagePropertyExifExposureTime: 2.5]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation, kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    func read(_ url: URL, cancelled: () -> Bool = { false }) throws -> SequenceCaptureReadResult {
        let before = try SequenceFileCredential.capture(at: url), hash = try digest(url)
        XCTAssertEqual(before, try SequenceFileCredential.capture(at: url))
        return try SequenceCaptureReader.read(at: url, assetID: "opaque", contentHash: hash, evidenceRevision: 1,
            verifiedCredential: before, cancelled: cancelled)
    }
    func testStrictSharedReaderPreservesLocalTimeAndActualExposure() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.tiff")
        try write(image(), to: url)
        let before = try digest(url), result = try read(url)
        XCTAssertEqual(result.evidence.assetID, "opaque")
        XCTAssertEqual(result.evidence.evidenceRevision, 1)
        XCTAssertEqual(result.evidence.contentHash, before)
        XCTAssertEqual(result.evidence.exposureSeconds, 2.5)
        XCTAssertEqual(result.evidence.time.local?.nanosecond, 123_000_000)
        XCTAssertNil(result.evidence.time.utcInstant)
        XCTAssertNotNil(result.feature)
        XCTAssertEqual(before, try digest(url))
    }
    func testAllEightOrientationsHaveEquivalentNormalizedFeatures() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try image(), context = CIContext(options: [.useSoftwareRenderer: true])
        let inverse: [Int32] = [1, 2, 3, 4, 5, 8, 7, 6]
        var reference: SequenceFrameFeature?
        for orientation in 1...8 {
            let rotated = CIImage(cgImage: base).oriented(forExifOrientation: inverse[orientation - 1])
            let stored = try XCTUnwrap(context.createCGImage(rotated, from: rotated.extent))
            let url = root.appendingPathComponent("\(orientation).tiff")
            try write(stored, to: url, orientation: orientation)
            let result = try read(url), feature = try XCTUnwrap(result.feature)
            XCTAssertEqual(result.evidence.orientation, orientation)
            XCTAssertLessThanOrEqual(max(feature.width, feature.height), 160)
            if let reference {
                XCTAssertEqual(feature.width, reference.width); XCTAssertEqual(feature.height, reference.height)
                let d = feature.distance(to: reference)
                XCTAssertLessThan(d.luminance, 0.005); XCTAssertLessThan(d.histogram, 0.005)
                XCTAssertEqual(feature.differenceHash, reference.differenceHash)
            } else { reference = feature }
        }
    }
    func testMissingRAWEmbeddedPreviewNeverRendersFullImage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.arw")
        try write(image(), to: url, type: "public.png")
        let result = try read(url)
        XCTAssertNil(result.feature)
        XCTAssertEqual(result.previewFailure, "missing-embedded-preview")
    }
    func testCancellationAfterNativeUnitThrowsInsteadOfReturningLateEvidence() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.tiff"); try write(image(), to: url)
        var calls = 0
        XCTAssertThrowsError(try read(url, cancelled: { calls += 1; return calls >= 2 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(calls, 2)
    }
    func testChangedCredentialRejectedBeforeReadingOldContentBinding() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.tiff"); try write(image(), to: url)
        let old = try SequenceFileCredential.capture(at: url), hash = try digest(url)
        try Data("replacement-not-the-verified-image".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try SequenceCaptureReader.read(at: url, assetID: "opaque", contentHash: hash,
            evidenceRevision: 0, verifiedCredential: old)) { XCTAssertEqual($0 as? SequenceReadError, .sourceChanged) }
    }
    func testFeatureBoundsAndLowTextureReliability() throws {
        var histogram = [Float](repeating: 0, count: 48)
        for c in 0..<3 { histogram[c * 16] = 1 }
        let flat = try SequenceFrameFeature(width: 32, height: 32, normalizedLuminance: [Float](repeating: 0, count: 1024),
            colorHistogram: histogram, differenceHash: 0, mean: 0, standardDeviation: 0)
        XCTAssertFalse(flat.isInformative)
        XCTAssertEqual(flat.distance(to: flat).histogram, 0)
        XCTAssertLessThan(flat.managedByteEstimate, 6 * 1024)
        XCTAssertThrowsError(try SequenceFrameFeature(width: 161, height: 32, normalizedLuminance: flat.normalizedLuminance,
            colorHistogram: histogram, differenceHash: 0, mean: 0, standardDeviation: 0))
        var broken = flat.normalizedLuminance; broken[0] = .nan
        XCTAssertThrowsError(try SequenceFrameFeature(width: 32, height: 32, normalizedLuminance: broken,
            colorHistogram: histogram, differenceHash: 0, mean: 0, standardDeviation: 0))
    }
}
