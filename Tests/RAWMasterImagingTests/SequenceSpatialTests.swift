import XCTest
import CoreGraphics
import ImageIO
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class SequenceSpatialTests: XCTestCase {
    private let config = SequenceSpatialConfiguration(mode: .localRescueAndBridgeVeto)
    private func value(_ x: Int, _ y: Int, seed: UInt64 = 7) -> UInt8 {
        let xx = UInt64(max(0, x) / 4), yy = UInt64(max(0, y) / 4)
        var n = (xx &* 0x9e3779b97f4a7c15) ^ (yy &* 0xbf58476d1ce4e5b9) ^ seed
        n = (n ^ (n >> 30)) &* 0xbf58476d1ce4e5b9; n = (n ^ (n >> 27)) &* 0x94d049bb133111eb
        return UInt8(40 + (n ^ (n >> 31)) % 170)
    }
    private func image(width: Int = 96, height: Int = 96, shiftX: Int = 0, seed: UInt64 = 7,
                       exposure: Int = 0, centerSeed: UInt64? = nil, constant: UInt8? = nil, checker: Bool = false) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            var v = constant ?? value(x-shiftX, y, seed: seed)
            if checker { v = ((x / 4 + y / 4) % 2 == 0) ? 40 : 210 }
            if let centerSeed, (36..<60).contains(x), (36..<60).contains(y) { v = value(x, y, seed: centerSeed) }
            let adjusted = UInt8(max(0, min(255, Int(v) + exposure))), p = (y*width+x)*4
            bytes[p] = adjusted; bytes[p+1] = adjusted; bytes[p+2] = adjusted
        } }
        return try XCTUnwrap(bytes.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() })
    }
    private func feature(_ image: CGImage) throws -> SequenceSpatialFeature { try SequenceSpatialFeature.extract(image) }
    private func compare(_ a: CGImage, _ b: CGImage) throws -> SequenceSpatialEvidence {
        try SequenceSpatialMatcher.compare(feature(a), feature(b), configuration: config)
    }
    func testTexturedIdentityExposureAndDirectedTranslation() throws {
        let first = try image()
        let exact = try compare(first, first)
        XCTAssertEqual(exact.verdict, .supported); XCTAssertEqual(exact.dx, 0); XCTAssertEqual(exact.dy, 0)
        XCTAssertEqual(exact.supportedPatches, 9); XCTAssertEqual(exact.supportedQuadrants, 4)
        let shifted = try compare(first, image(shiftX: 4, exposure: 8))
        XCTAssertEqual(shifted.verdict, .supported); XCTAssertEqual(shifted.dx, 4); XCTAssertEqual(shifted.dy, 0)
        XCTAssertTrue(shifted.isFinite); XCTAssertLessThanOrEqual(shifted.candidateCount, 539)
        XCTAssertEqual(shifted, try compare(first, image(shiftX: 4, exposure: 8)))
    }
    func testCenteredForegroundCannotValidateReplacedBackground() throws {
        let a = try image(seed: 7, centerSeed: 71), b = try image(seed: 91, centerSeed: 71)
        XCTAssertNotEqual(try compare(a,b).verdict, .supported)
    }
    func testStableBackgroundCannotHideChangedTexturedCenter() throws {
        let a = try image(seed: 7, centerSeed: 71), b = try image(seed: 7, centerSeed: 91)
        let result = try compare(a,b)
        XCTAssertNotEqual(result.verdict, .supported)
        if result.texturedPatches >= 6 { XCTAssertEqual(result.centerSupported, false) }
    }
    func testUniformAndRepeatedTexturesAreInsufficientNotPositive() throws {
        let flat = try image(constant: 90), repeated = try image(checker: true)
        XCTAssertEqual(try compare(flat,flat).verdict, .insufficient)
        XCTAssertEqual(try compare(repeated,repeated).verdict, .insufficient)
    }
    func testReadableSmallFeatureIsCompactSuccessfulInsufficientEvidence() throws {
        let small = try feature(image(width: 32, height: 24))
        XCTAssertTrue(small.isSmall); XCTAssertLessThan(small.managedByteEstimate, 1024)
        let result = try SequenceSpatialMatcher.compare(small, small, configuration: config)
        XCTAssertEqual(result.verdict, .insufficient); XCTAssertEqual(result.reason, .smallImage)
        XCTAssertEqual(result.candidateCount, 0)
    }
    func testAspectMismatchAndBeyondBoundShiftCannotClaimSupport() throws {
        XCTAssertEqual(try compare(image(), image(width: 96, height: 64)).reason, .aspectMismatch)
        XCTAssertNotEqual(try compare(image(), image(shiftX: 20)).verdict, .supported)
    }
    func testPartialOrPaddedPatchNeverProvidesSupport() throws {
        let result = try compare(image(), image(shiftX: 12))
        // At +12 right-corner windows leave the target. Fixed full windows cannot be rescued by padding.
        XCTAssertNotEqual(result.verdict, .supported); XCTAssertLessThan(result.supportedQuadrants, 3)
        let rect = SequenceSpatialRect(x: 0, y: 0, width: 96, height: 96)
        XCTAssertTrue(rect.contains(x: 79, y: 1, width: 16, height: 16, margin: 1))
        XCTAssertFalse(rect.contains(x: 80, y: 1, width: 16, height: 16, margin: 1))
        XCTAssertFalse(rect.contains(x: -1, y: 1, width: 16, height: 16, margin: 1))
    }
    func testMalformedNonfiniteFeatureAndChangedRecipeAreRejected() throws {
        let valid = try feature(image())
        var values = valid.luminance; values[100] = .nan
        XCTAssertThrowsError(try SequenceSpatialFeature(valid: valid.valid, luminance: values, gradientX: valid.gradientX, gradientY: valid.gradientY, coarse: valid.coarse))
        XCTAssertThrowsError(try SequenceSpatialFeature(valid: valid.valid, luminance: [], gradientX: [], gradientY: [], coarse: []))
        let encoded = try JSONEncoder().encode(config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String:Any])
        var recipe = try XCTUnwrap(object["recipe"] as? [String:Any]); recipe["maximumTranslation"] = 13; object["recipe"] = recipe
        let altered = try JSONDecoder().decode(SequenceSpatialConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try altered.validate())
    }
    func testMatcherChecksCancellationInsideWorkAndDoesNotReturnPartialScore() throws {
        let a = try feature(image()); var checks = 0
        XCTAssertThrowsError(try SequenceSpatialMatcher.compare(a, a, configuration: config, cancelled: {
            checks += 1; return checks >= 80
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(checks, 80)
        XCTAssertLessThanOrEqual(a.managedByteEstimate, 114 * 1024)
        XCTAssertLessThanOrEqual(SequenceSpatialMatcher.scratchReservationBytes, 512 * 1024)
    }
    func testDefaultConfigurationEncodingFingerprintAndVersionsRemainDev4() throws {
        let config = SequenceDetectorConfiguration(), data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
        XCTAssertNil(object["spatialExperiment"])
        let decoded = try JSONDecoder().decode(SequenceDetectorConfiguration.self, from: data)
        XCTAssertEqual(try decoded.fingerprint, try config.fingerprint)
        // Frozen default dev4 policy identity from the pre-experiment approved snapshot.
        XCTAssertEqual(try config.fingerprint, "6d2d41684046f60da698eec7e19ed37c74673662fa33500db90fbdc8e7ecfcc4")
        XCTAssertEqual(config.versions(order: SequenceBaseOrder.version).algorithm, "sequence-local-anchor-cadence-dev-4")
        XCTAssertEqual(config.versions(order: SequenceBaseOrder.version).feature, SequenceFrameFeature.version)
        var spatial = config; spatial.spatialExperiment = self.config
        XCTAssertNotEqual(try spatial.fingerprint, try config.fingerprint)
        XCTAssertEqual(spatial.versions(order: SequenceBaseOrder.version).algorithm, "sequence-local-anchor-cadence-spatial-exp-1")
        XCTAssertTrue(spatial.versions(order: SequenceBaseOrder.version).feature.contains(SequenceSpatialFeature.version))
    }
    func testActualReaderOptionalExtractionPreservesLegacyBytesAndSmallPreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for size in [96, 24] {
            let url = root.appendingPathComponent("synthetic-\(size).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try image(width: size, height: size), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            let before = try SequenceFileCredential.capture(at: url)
            let baseline = try SequenceCaptureReader.read(at: url, assetID: "generated", contentHash: digest, evidenceRevision: 0, verifiedCredential: before)
            let candidate = try SequenceCaptureReader.read(at: url, assetID: "generated", contentHash: digest, evidenceRevision: 0, verifiedCredential: before, spatial: config)
            XCTAssertEqual(baseline.feature, candidate.feature); XCTAssertEqual(baseline.evidence, candidate.evidence)
            XCTAssertNil(baseline.spatialFeature); XCTAssertNil(baseline.spatialExtractionSeconds)
            let feature = try XCTUnwrap(candidate.spatialFeature)
            XCTAssertEqual(feature.isSmall, size < 48); XCTAssertGreaterThanOrEqual(candidate.spatialExtractionSeconds ?? -1, 0)
            XCTAssertEqual(try SequenceFileCredential.capture(at: url), before)
        }
    }
}
