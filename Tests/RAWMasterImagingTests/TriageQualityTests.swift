import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class TriageQualityTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-TriageQuality-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func image(_ pixel: (Int, Int) -> UInt8) throws -> CGImage {
        let width = 96, height = 64
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4, value = pixel(x, y)
            data[i] = value; data[i + 1] = value; data[i + 2] = value
        } }
        return try XCTUnwrap(data.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
    }
    private func write(_ name: String, _ image: CGImage, type: String = "public.png", orientation: Int = 1) throws -> AssetRecord {
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try record(url)
    }
    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func record(_ url: URL) throws -> AssetRecord {
        AssetRecord(sessionID: "session", projectID: "project", sourcePath: url.path,
            fileSize: Int64(try Data(contentsOf: url).count), contentHash: try digest(url), importState: .ready)
    }

    func testFlatScenesRemainUnknownAndNeverClaimFocusOrExposureFailure() throws {
        for value: UInt8 in [0, 128, 255] {
            let asset = try write("flat-\(value).png", image { _, _ in value })
            let result = try TriageQualityAnalyzer.analyze(asset: asset)
            XCTAssertEqual(result.status, .unknown)
            XCTAssertTrue(result.reasons.contains { $0.contains("无法区分") })
            XCTAssertEqual(result.assetID, asset.id)
            XCTAssertEqual(result.contentHash, asset.contentHash)
            XCTAssertEqual(result.methodVersion, TriageQualityAnalyzer.methodVersion)
        }
    }

    func testExposureRisksArePreviewOnlyAndNormalStatisticsDoNotCertifyQuality() throws {
        let dark = try write("dark.jpg", image { x, _ in x < 88 ? 0 : 128 }, type: "public.jpeg")
        let bright = try write("bright.jpg", image { x, _ in x < 88 ? 255 : 128 }, type: "public.jpeg")
        let textured = try write("textured.jpg", image { x, y in (x / 8 + y / 8) % 2 == 0 ? 60 : 180 }, type: "public.jpeg")
        let first = try TriageQualityAnalyzer.analyze(asset: dark)
        let second = try TriageQualityAnalyzer.analyze(asset: bright)
        let third = try TriageQualityAnalyzer.analyze(asset: textured)
        XCTAssertEqual(first.status, .risk)
        XCTAssertEqual(second.status, .risk)
        XCTAssertEqual(first.source, "jpegPreview")
        XCTAssertTrue(second.reasons.contains { $0.contains("不能据此判断 RAW") })
        XCTAssertEqual(third.status, .clear)
        XCTAssertTrue(third.reasons.contains { $0.contains("不代表") })
        for evidence in [first, second, third] {
            XCTAssertTrue(evidence.metrics.values.allSatisfy { $0.isFinite })
            XCTAssertLessThanOrEqual(evidence.metrics["previewWidth"]!, 256)
            XCTAssertLessThanOrEqual(evidence.metrics["previewHeight"]!, 256)
        }
    }

    func testMissingEmbeddedRAWPreviewNeverFallsBackToFullRender() throws {
        let asset = try write("synthetic.arw", image { x, y in UInt8((x + y) % 200) })
        let result = try TriageQualityAnalyzer.analyze(asset: asset)
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.source, "embeddedRAWPreview")
        XCTAssertTrue(result.reasons.contains { $0.contains("未解码完整 RAW") })
        XCTAssertTrue(result.metrics.isEmpty)
    }

    func testWrongIdentityUnavailableAndCorruptFilesAreNotPhotographyRejects() throws {
        var changed = try write("source.png", image { x, y in UInt8((x + y) % 200) })
        changed.contentHash = String(repeating: "0", count: 64)
        XCTAssertEqual(try TriageQualityAnalyzer.analyze(asset: changed).status, .error)
        changed.availability = .missing
        XCTAssertEqual(try TriageQualityAnalyzer.analyze(asset: changed).status, .error)
        let corruptURL = root.appendingPathComponent("corrupt.jpg")
        try Data("not an image".utf8).write(to: corruptURL)
        let result = try TriageQualityAnalyzer.analyze(asset: record(corruptURL))
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.reasons.contains { $0.contains("读取失败") })
        var unidentified = try write("unidentified.png", image { _, _ in 128 })
        unidentified.contentHash = nil
        XCTAssertEqual(try TriageQualityAnalyzer.analyze(asset: unidentified).status, .unknown)
    }

    func testDirectionIsNormalizedAndSourcesStayReadOnly() throws {
        let picture = try image { x, y in (x / 8 + y / 8) % 2 == 0 ? 30 : 220 }
        var reference: TriageQualityEvidence?
        for orientation in 1...8 {
            let asset = try write("orientation-\(orientation).tiff", picture, type: "public.tiff", orientation: orientation)
            let attributes = try FileManager.default.attributesOfItem(atPath: asset.sourcePath)
            let hash = try digest(asset.resolvedURL)
            let result = try TriageQualityAnalyzer.analyze(asset: asset)
            XCTAssertEqual(hash, try digest(asset.resolvedURL))
            XCTAssertEqual(attributes[.modificationDate] as? Date,
                try FileManager.default.attributesOfItem(atPath: asset.sourcePath)[.modificationDate] as? Date)
            XCTAssertEqual(result.source, "imagePreview")
            XCTAssertEqual(result.metrics["previewWidth"], orientation <= 4 ? 96 : 64)
            XCTAssertEqual(result.metrics["previewHeight"], orientation <= 4 ? 64 : 96)
            if let reference {
                XCTAssertEqual(result.metrics["luminanceMean"]!, reference.metrics["luminanceMean"]!, accuracy: 0.00001)
                XCTAssertEqual(result.metrics["luminanceStdDev"]!, reference.metrics["luminanceStdDev"]!, accuracy: 0.00001)
            } else { reference = result }
        }
    }

    func testCancellationAndInvalidBudgetDoNotReturnLateQualityJudgment() throws {
        let asset = try write("source.png", image { x, y in UInt8((x * y) % 255) })
        XCTAssertThrowsError(try TriageQualityAnalyzer.analyze(asset: asset, cancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        var calls = 0
        XCTAssertThrowsError(try TriageQualityAnalyzer.analyze(asset: asset, cancelled: {
            calls += 1
            return calls >= 5
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(calls, 5)
        let result = try TriageQualityAnalyzer.analyze(asset: asset, maximumPixel: 8192)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.metrics.isEmpty)
    }

    func testFileChangedDuringNativeReadIsDiscarded() throws {
        let asset = try write("source.png", image { x, y in UInt8((x * y) % 255) })
        var calls = 0, changed = false
        let result = try TriageQualityAnalyzer.analyze(asset: asset, cancelled: {
            calls += 1
            if calls == 6 {
                try? Data("replacement".utf8).write(to: asset.resolvedURL, options: .atomic)
                changed = true
            }
            return false
        })
        XCTAssertTrue(changed)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.reasons.contains { $0.contains("变化") })
    }
}
