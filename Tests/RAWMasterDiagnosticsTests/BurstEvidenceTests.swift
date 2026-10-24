import XCTest
import Foundation
import ImageIO
import CoreImage
import CoreGraphics
@testable import RAWMasterDiagnostics

final class BurstEvidenceTests: XCTestCase {
    func time(_ text: String? = "2026:10:02 12:12:13", sub: String? = "648", offset: String? = nil) -> CaptureTimeEvidence {
        CaptureTimestampParser.parse(original: text, subseconds: sub, offset: offset)
    }
    func metadata(_ time: CaptureTimeEvidence) -> CaptureEvidence {
        CaptureEvidence(time: time, cameraMake: "Synthetic", cameraModel: "Not device identity", imageNumberRaw: nil,
                        orientation: 1, width: 32, height: 32, warnings: [])
    }
    func feature() -> PreviewFeature {
        PreviewFeature(width: 32, height: 32, differenceHash: 0, colorHistogram: [Float](repeating: 0, count: 48),
            luminanceMean: 0.5, luminanceStdDev: 0.1, normalizedLuminance: [Float](repeating: 0, count: 1024))
    }
    func inputs(_ count: Int) -> [EvidenceInput] {
        (0..<count).map { EvidenceInput(id: "opaque-\($0)", sourceOrder: $0, url: URL(fileURLWithPath: "/synthetic/\($0).tiff")) }
    }
    func frame(_ id: String, _ value: CaptureTimeEvidence) -> EvidenceFrame {
        EvidenceFrame(id: id, sourceOrder: 0, displayName: id, metadata: metadata(value), preview: feature(), metadataFailure: nil, previewFailure: nil)
    }
    func testStrictTimestampKeepsLocalTimeWithoutInventingUTC() {
        let value = time()
        XCTAssertEqual(value.local?.nanosecond, 648_000_000)
        XCTAssertEqual(value.local?.year, 2026)
        XCTAssertNil(value.utcInstant)
        XCTAssertEqual(value.offsetEvidence, "unknown")
        XCTAssertEqual(value.originalRaw, "2026:10:02 12:12:13")
        XCTAssertNil(time("2026:02:30 12:12:13").local)
        XCTAssertNil(time("2026:10:02 24:00:00").local)
        XCTAssertNil(time("2026-10-02 12:12:13").local)
        XCTAssertNotNil(time("2024:02:29 00:00:00").local)
        XCTAssertNil(time("1900:02:29 00:00:00").local)
    }
    func testExplicitOffsetIsRequiredAndStrict() {
        let a = time(offset: "+08:00"), b = time("2026:10:02 04:12:13", offset: "+00:00")
        XCTAssertEqual(a.utcInstant, b.utcInstant)
        for bad in ["8:00", "+15:00", "+14:01", "+08:60", "+٠٨:٠٠", "unknown"] { XCTAssertNil(time(offset: bad).utcInstant) }
        XCTAssertEqual(time(sub: "12345678910").local?.nanosecond, 123_456_789)
        XCTAssertEqual(time(sub: "12345678910").precision, "subseconds-truncated-to-nanoseconds")
        XCTAssertNil(time(sub: "1x").local?.nanosecond)
        XCTAssertEqual(time(sub: nil).precision, "seconds")
    }
    func testUnknownTimeIsNeverZeroAndRollbackRemainsSigned() {
        let unknown = BurstEvidenceExperiment.pair(frame("a", time()), frame("b", time(nil)))
        XCTAssertNil(unknown.preciseLocalCameraGapSeconds)
        XCTAssertNil(unknown.coarseLocalCameraSecondDifference)
        let coarse = BurstEvidenceExperiment.pair(frame("a", time(sub: nil)), frame("b", time(sub: nil)))
        XCTAssertNil(coarse.preciseLocalCameraGapSeconds)
        XCTAssertEqual(coarse.coarseLocalCameraSecondDifference, 0)
        let rollback = BurstEvidenceExperiment.pair(frame("a", time()), frame("b", time(sub: "500")))
        XCTAssertEqual(rollback.preciseLocalCameraGapSeconds!, -0.148, accuracy: 1e-9)
        XCTAssertEqual(rollback.timeStatus, "clock-rollback-or-source-order-reversal")
        XCTAssertNil(rollback.utcGapSeconds)
        let midnight = BurstEvidenceExperiment.pair(frame("a", time("2026:10:02 23:59:59", sub: "900")),
            frame("b", time("2026:10:03 00:00:00", sub: "100")))
        XCTAssertEqual(midnight.preciseLocalCameraGapSeconds!, 0.2, accuracy: 1e-9)
    }
    func testSourceOrderIsPreservedAndRollbackNotSortedAway() async {
        let m = metadata(time()), f = feature()
        let earlier = metadata(time(sub: "500"))
        let report = await BurstEvidenceExperiment.run(inputs: inputs(2), reader: { url in
            FrameProbe(metadata: url.lastPathComponent == "0.tiff" ? m : earlier, preview: f)
        })
        XCTAssertEqual(report.frames.map(\.id), ["opaque-0", "opaque-1"])
        XCTAssertEqual(report.chronologicalIDs, ["opaque-1", "opaque-0"])
        XCTAssertTrue(report.chronologicalOrderDiffersFromSourceOrder)
        XCTAssertEqual(report.rollbackPairs, 1)
        XCTAssertTrue(report.thresholds.allSatisfy { $0.unknownPairs == 1 && $0.evaluablePairs == 0 })
    }
    func testCancellationAfterUncancellableUnitDiscardsLateResult() async {
        let token = EvidenceCancellation(), m = metadata(time()), f = feature()
        let report = await BurstEvidenceExperiment.run(inputs: inputs(3), cancelled: { token.isCancelled }, reader: { _ in
            token.cancel()
            return FrameProbe(metadata: m, preview: f)
        })
        XCTAssertEqual(report.status, "cancelled")
        XCTAssertEqual(report.coverage.attempted, 1)
        XCTAssertEqual(report.coverage.discardedOnCancellation, 1)
        XCTAssertEqual(report.coverage.recorded, 0)
        XCTAssertEqual(report.coverage.notAttempted, 2)
    }
    func testBudgetStopsBeforeDecodeAndLabelsCannotChangeAnalysis() async throws {
        let m = metadata(time()), f = feature()
        let report = await BurstEvidenceExperiment.run(inputs: inputs(3), options: EvidenceOptions(memoryBudgetBytes: 1024), reader: { _ in
            XCTFail("Budget must stop before reading source"); return FrameProbe(metadata: m, preview: f)
        })
        XCTAssertEqual(report.status, "partial"); XCTAssertEqual(report.coverage.attempted, 0)
        let complete = await BurstEvidenceExperiment.run(inputs: inputs(3), reader: { _ in FrameProbe(metadata: m, preview: f) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(complete.adjacentPairs)
        let labels = PositiveLabels(fixture: "posthoc", role: "positive-only", groups: [.init(id: "x", files: ["0.tiff", "1.tiff", "2.tiff"])])
        let evaluation = BurstEvidenceExperiment.evaluate(complete, labels: labels)
        XCTAssertEqual(evaluation.knownPositiveAdjacentPairs, 2)
        XCTAssertEqual(before, try encoder.encode(complete.adjacentPairs))
        XCTAssertEqual(complete.frames.map(\.id), ["opaque-0", "opaque-1", "opaque-2"])
        XCTAssertFalse(complete.productionQualityAccepted)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(complete)) as! [String: Any]
        XCTAssertTrue(json["precision"] is NSNull); XCTAssertTrue(json["independentHoldout"] is NSNull)
    }
    func testPartialPosthocEvaluationCountsMissingPositivePairsAsUnknown() async {
        let m = metadata(time()), f = feature(), token = EvidenceCancellation()
        let report = await BurstEvidenceExperiment.run(inputs: inputs(3), cancelled: { token.isCancelled },
            reader: { _ in FrameProbe(metadata: m, preview: f) }, progress: { _, _ in token.cancel() })
        let labels = PositiveLabels(fixture: "partial", role: "positive-only", groups: [.init(id: "x", files: ["0.tiff", "1.tiff", "2.tiff"])])
        let evaluation = BurstEvidenceExperiment.evaluate(report, labels: labels)
        XCTAssertEqual(evaluation.knownPositiveAdjacentPairs, 2)
        XCTAssertEqual(evaluation.observedPositiveAdjacentPairs, 0)
        XCTAssertEqual(evaluation.labeledFramesMissingFromReport, 2)
        XCTAssertTrue(evaluation.thresholdRetention.allSatisfy { $0.unknownPairs == 2 })
    }
    func testSerialUnitsAndCancellationBeforeRead() async {
        let token = EvidenceCancellation(); token.cancel()
        let report = await BurstEvidenceExperiment.run(inputs: inputs(4), cancelled: { token.isCancelled }, reader: { _ in
            XCTFail("Already cancelled run must not read"); return FrameProbe()
        })
        XCTAssertEqual(report.status, "cancelled")
        XCTAssertEqual(report.coverage.attempted, 0)
        XCTAssertEqual(report.coverage.notAttempted, 4)
        let m = metadata(time()), f = feature(), count = LockedProbeCount()
        let complete = await BurstEvidenceExperiment.run(inputs: inputs(8), reader: { _ in
            count.enter(); defer { count.leave() }
            return FrameProbe(metadata: m, preview: f)
        })
        XCTAssertEqual(complete.status, "complete")
        XCTAssertEqual(count.maximum, 1)
        XCTAssertEqual(count.entries, 8)
        XCTAssertLessThanOrEqual(complete.managedPeakEstimateBytes, complete.managedBudgetBytes)
    }
    func testPostReadBudgetFailureIsCounted() async {
        let m = metadata(time())
        let huge = PreviewFeature(width: 32, height: 32, differenceHash: 0, colorHistogram: [], luminanceMean: 0,
            luminanceStdDev: 0, normalizedLuminance: [Float](repeating: 0, count: 600_000))
        let report = await BurstEvidenceExperiment.run(inputs: inputs(2), options: EvidenceOptions(memoryBudgetBytes: 3 * 1024 * 1024),
            reader: { _ in FrameProbe(metadata: m, preview: huge) })
        XCTAssertEqual(report.status, "partial")
        XCTAssertEqual(report.coverage.attempted, 1)
        XCTAssertEqual(report.coverage.recorded, 0)
        XCTAssertEqual(report.coverage.discardedOnBudget, 1)
        XCTAssertEqual(report.coverage.notAttempted, 1)
    }
    func testFailedMetadataAndPreviewRetainPartialCoverage() async {
        let report = await BurstEvidenceExperiment.run(inputs: inputs(2), reader: { _ in
            FrameProbe(metadataFailure: "corrupt", previewFailure: "no embedded preview")
        })
        XCTAssertEqual(report.status, "partial")
        XCTAssertEqual(report.coverage.recorded, 2)
        XCTAssertEqual(report.coverage.metadataFailures, 2)
        XCTAssertEqual(report.coverage.previewFailures, 2)
        XCTAssertEqual(report.thresholds[0].unknownPairs, 1)
    }
    func testPrespecifiedThresholdsExposeLongPauseWithoutChoosingWinner() {
        let pair = BurstEvidenceExperiment.pair(frame("a", time("2026:10:02 12:12:13", sub: "000")),
            frame("b", time("2026:10:02 12:12:22", sub: "075")))
        let thresholds = BurstEvidenceExperiment.thresholds([pair])
        XCTAssertEqual(thresholds.map(\.thresholdSeconds), [0.5, 1, 2, 5, 10])
        XCTAssertEqual(thresholds.map(\.retainedPairs), [0, 0, 0, 0, 1])
    }
    func testExplicitNegativeBoundaryMetricsArePosthocAndSmallSampleUncertain() async throws {
        let records = [metadata(time("2026:10:02 12:12:00", sub: "000")),
            metadata(time("2026:10:02 12:12:10", sub: "000")),
            metadata(time("2026:10:02 12:12:10", sub: "100")),
            metadata(time("2026:10:02 12:12:20", sub: "000"))]
        let f = feature()
        let report = await BurstEvidenceExperiment.run(inputs: inputs(4), reader: { url in
            FrameProbe(metadata: records[Int(url.deletingPathExtension().lastPathComponent)!], preview: f)
        })
        let labels = PositiveLabels(fixture: "explicit", role: "independent-positive-and-two-boundaries",
            groups: [.init(id: "positive", files: ["1.tiff", "2.tiff"])],
            negativeBoundaries: [.init(from: "0.tiff", to: "1.tiff"), .init(from: "2.tiff", to: "3.tiff")])
        let result = try XCTUnwrap(BurstEvidenceExperiment.evaluate(report, labels: labels).boundaryEvaluation)
        XCTAssertEqual(result[0].truePositive, 1); XCTAssertEqual(result[0].falsePositive, 0)
        XCTAssertEqual(result[0].trueNegative, 2); XCTAssertEqual(result[0].unknownNegative, 0)
        XCTAssertEqual(result.last?.falsePositive, 2)
        XCTAssertGreaterThan(try XCTUnwrap(result[0].boundaryFalseMergeWilson95).upper, 0.65)
        XCTAssertFalse(result[0].accepted)
        let ci = try XCTUnwrap(WilsonInterval.calculate(successes: 13, total: 13))
        XCTAssertGreaterThan(ci.lower, 0.77); XCTAssertLessThan(ci.lower, 0.78)
    }
    func testZeroPredictionsHaveNullPrecisionAndNeverPass() async throws {
        let records = [metadata(time("2026:10:02 12:12:00", sub: "000")),
            metadata(time("2026:10:02 12:12:20", sub: "000")),
            metadata(time("2026:10:02 12:12:40", sub: "000"))]
        let f = feature()
        let report = await BurstEvidenceExperiment.run(inputs: inputs(3), reader: { url in
            FrameProbe(metadata: records[Int(url.deletingPathExtension().lastPathComponent)!], preview: f)
        })
        let labels = PositiveLabels(fixture: "zero", role: "synthetic", groups: [.init(id: "positive", files: ["1.tiff", "2.tiff"])],
            negativeBoundaries: [.init(from: "0.tiff", to: "1.tiff")])
        let values = try XCTUnwrap(BurstEvidenceExperiment.evaluate(report, labels: labels).boundaryEvaluation)
        XCTAssertTrue(values.allSatisfy { $0.zeroPredictions && $0.precision == nil && !$0.accepted })
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as! [[String: Any]]
        XCTAssertTrue(object.allSatisfy { $0["precision"] is NSNull && $0["precisionWilson95"] is NSNull })
    }
    func testManifestRejectsTraversalDuplicatesAndEscapingSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = dir.appendingPathComponent("manifest.txt")
        for text in ["../outside.ARW", "/absolute.ARW", "a.ARW\na.ARW"] {
            try text.write(to: manifest, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try BurstEvidenceCLI.loadInputs(manifestURL: manifest, root: dir))
        }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("escape.ARW"), withDestinationURL: URL(fileURLWithPath: "/tmp/outside.ARW"))
        try "escape.ARW".write(to: manifest, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BurstEvidenceCLI.loadInputs(manifestURL: manifest, root: dir))
        try "z.ARW\na.ARW".write(to: manifest, atomically: true, encoding: .utf8)
        XCTAssertEqual(try BurstEvidenceCLI.loadInputs(manifestURL: manifest, root: dir).map(\.displayName), ["z.ARW", "a.ARW"])
    }
    func syntheticImage() throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 48 * 32 * 4)
        for y in 0..<32 { for x in 0..<48 {
            let i = (y * 48 + x) * 4
            bytes[i] = UInt8(x * 5); bytes[i + 1] = UInt8(y * 7); bytes[i + 2] = x < 15 && y < 9 ? 255 : 0
        } }
        return try XCTUnwrap(bytes.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: 48, height: 32, bitsPerComponent: 8,
            bytesPerRow: 48 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() })
    }
    func testAllEightEXIFOrientationsNormalizeSameFeatures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try syntheticImage(), context = CIContext(options: [.useSoftwareRenderer: true])
        let inverse: [Int32] = [1, 2, 3, 4, 5, 8, 7, 6]
        var features: [PreviewFeature] = []
        for orientation in 1...8 {
            let transformed = CIImage(cgImage: base).oriented(forExifOrientation: inverse[orientation - 1])
            let image = try XCTUnwrap(context.createCGImage(transformed, from: transformed.extent))
            let url = root.appendingPathComponent("\(orientation).tiff")
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            let probe = CaptureEvidenceReader.read(url)
            XCTAssertEqual(probe.metadata?.orientation, orientation)
            features.append(try XCTUnwrap(probe.preview, probe.previewFailure ?? "missing feature"))
        }
        for feature in features.dropFirst() {
            XCTAssertEqual(feature.width, features[0].width)
            XCTAssertEqual(feature.height, features[0].height)
            XCTAssertEqual(feature.differenceHash, features[0].differenceHash)
            XCTAssertEqual(feature.luminanceMean, features[0].luminanceMean, accuracy: 0.002)
            XCTAssertLessThan(zip(feature.normalizedLuminance, features[0].normalizedLuminance).map { abs($0 - $1) }.max()!, 0.02)
        }
    }
    func testRAWLikeFileWithoutEmbeddedPreviewNeverFallsBackToFullImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".arw")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try syntheticImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let probe = CaptureEvidenceReader.read(url)
        XCTAssertNotNil(probe.metadata)
        XCTAssertNil(probe.preview)
        XCTAssertEqual(probe.previewFailure, "missingEmbeddedPreview")
    }
}

private final class LockedProbeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0
    private(set) var entries = 0
    func enter() { lock.lock(); active += 1; entries += 1; maximum = max(maximum, active); lock.unlock() }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
}
