import XCTest
import Foundation
import CoreGraphics
import ImageIO
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class SequenceSpatialAdapterTests: XCTestCase {
    func testOptionalPolicyIdentityDoesNotChangeDefaultAndSeparatesCandidates() throws {
        let baseline = SequenceDetectorConfiguration()
        let data = try SequenceFixtureHarness.encoded(baseline)
        let fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(fields["spatialExperiment"])
        XCTAssertEqual(baseline.versions(order: SequenceBaseOrder.version).algorithm, SequenceDetectorConfiguration.algorithmVersion)
        XCTAssertEqual(baseline.versions(order: SequenceBaseOrder.version).policy, SequenceDetectorConfiguration.policyVersion)
        let fingerprints = try SpatialExperimentHarness.variants.map { try SpatialExperimentHarness.configuration($0).fingerprint }
        XCTAssertEqual(Set(fingerprints).count, 3)
        let roundtrip = try JSONDecoder().decode(SequenceDetectorConfiguration.self, from: data)
        XCTAssertEqual(try roundtrip.fingerprint, try baseline.fingerprint)
    }
    func testHashCancellationStopsAtBoundedChunk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.bin")
        try Data(repeating: 47, count: 3 * 1024 * 1024).write(to: file)
        var bytes = 0
        XCTAssertThrowsError(try SequenceProbeRun.verifiedHash(file, deadline: ProcessInfo.processInfo.systemUptime + 10,
            cancelled: { bytes > 0 }, onChunk: { bytes += $0 })) { error in XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(bytes, 1024 * 1024)
    }
    func testLegacyInjectedReaderCannotSilentlyDropExperimentalFeature() throws {
        let manifest = ProbeManifest(schemaVersion: 1, scopeID: "synthetic", sessionID: "synthetic", orderVersion: SequenceBaseOrder.version,
            files: [.init(assetID: "asset0000", ordinal: 0, relativePath: "not-read.jpg")])
        let policy = try SpatialExperimentHarness.policy(caseID: "burst123", configuration: SpatialExperimentHarness.configuration("bridgeVetoOnly"), trace: false)
        var called = false
        XCTAssertThrowsError(try SequenceProbeRun.analyze(manifest: manifest, root: FileManager.default.temporaryDirectory, policy: policy,
            reader: { _, _, _ in called = true; throw SequenceReadError.unreadable }))
        XCTAssertFalse(called)
    }
    func testNativeJPEGSpatialExtractionCancellationPropagates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic-cancel.jpg")
        var pixels = [UInt8](repeating: 255, count: 96 * 96 * 4)
        for y in 0..<96 { for x in 0..<96 {
            let at = (y * 96 + x) * 4
            pixels[at] = UInt8((x * 37 + y * 19) % 256)
            pixels[at + 1] = UInt8((x * 11 + y * 43) % 256)
            pixels[at + 2] = UInt8((x * 53 + y * 7) % 256)
        } }
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: 96, height: 96,
            bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() })
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let (digest, credential) = try SequenceProbeRun.verifiedHash(url, deadline: ProcessInfo.processInfo.systemUptime + 10)
        var polls = 0
        XCTAssertThrowsError(try SequenceCaptureReader.read(at: url, assetID: "synthetic-cancel", contentHash: digest,
            evidenceRevision: 0, verifiedCredential: credential, spatial: SequenceSpatialConfiguration(mode: .bridgeVetoOnly),
            cancelled: { polls += 1; return polls > 2 })) { error in XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThan(polls, 2)
    }
    func testMeasurementOverflowAndInvalidClockAreHardErrors() throws {
        let collector = SpatialMeasurementCollector()
        collector.record(ProbeMeasurement(stage: .nativeRead, durationSeconds: .nan))
        XCTAssertThrowsError(try collector.snapshot())
    }
}
