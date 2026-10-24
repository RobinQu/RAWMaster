import XCTest
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class SequencePauseBridgeObserverTests: XCTestCase {
    private func frame(_ ordinal: Int, available: Bool = true) throws -> PauseBridgeObserverSupport {
        var histogram = [Float](repeating: 0, count: 48)
        for channel in 0..<3 { histogram[channel * 16 + ordinal % 16] = 1 }
        let feature = try SequenceFrameFeature(width: 32, height: 32, normalizedLuminance: Array(repeating: Float(ordinal) / 10, count: 1024),
            colorHistogram: histogram, differenceHash: UInt64(ordinal), mean: 0.5, standardDeviation: 0.2)
        return PauseBridgeObserverSupport(ordinal: ordinal, issues: available ? [] : ["synthetic-unavailable"],
            feature: available ? feature : nil, facts: ["ordinal": ordinal])
    }
    func testMatricesRetainEveryCrossAndIntraPairWithoutSelectingRepresentatives() throws {
        let left = try (0..<3).map { try frame($0) }, right = try (3..<6).map { try frame($0) }
        let value = try SequencePauseBridgeObserverHarness.matrices(left: left, right: right)
        let cross = try XCTUnwrap(value["crossNine"] as? [[String: Any]])
        XCTAssertEqual(cross.count, 9)
        XCTAssertEqual(cross.compactMap { $0["fromOrdinal"] as? Int }, [0,0,0,1,1,1,2,2,2])
        XCTAssertEqual(cross.compactMap { $0["toOrdinal"] as? Int }, [3,4,5,3,4,5,3,4,5])
        for (row, pair) in cross.enumerated() {
            let d = left[row / 3].feature!.distance(to: right[row % 3].feature!)
            let measured = try XCTUnwrap(pair["distance"] as? [String: Float])
            XCTAssertEqual(measured["histogram"], d.histogram)
            XCTAssertEqual(measured["luminance"], d.luminance)
            XCTAssertEqual(measured["hash"], d.hash)
            XCTAssertNotNil(pair["luminanceGeometry"] as? [String: Any])
        }
        for name in ["leftIntraThree", "rightIntraThree"] {
            XCTAssertEqual((value[name] as? [[String: Any]])?.count, 3)
        }
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.matrices(left: Array(left.prefix(2)), right: right))
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.matrices(left: left, right: [right[1], right[0], right[2]]))
    }
    func testUnavailableSupportRemainsInAllNineSlotsWithExplicitReasons() throws {
        let left = try (0..<3).map { try frame($0, available: $0 != 1) }, right = try (3..<6).map { try frame($0) }
        let value = try SequencePauseBridgeObserverHarness.matrices(left: left, right: right)
        let cross = try XCTUnwrap(value["crossNine"] as? [[String: Any]])
        XCTAssertEqual(cross.count, 9)
        XCTAssertEqual(cross.filter { $0["distance"] is NSNull }.count, 3)
        XCTAssertEqual(cross.filter { $0["luminanceGeometry"] is NSNull }.count, 3)
        XCTAssertTrue(cross[3...5].allSatisfy { ($0["issues"] as? [String])?.contains("feature-unavailable") == true })
        XCTAssertEqual((value["leftIntraThree"] as? [[String: Any]])?.filter { $0["distance"] is NSNull }.count, 2)
    }
    func testLuminanceGeometryIsCenteredSymmetricAndExplicitForDegenerateEnergy() throws {
        let a: [Float] = [1, -1, 0, 0], opposed: [Float] = [-1, 1, 0, 0], orthogonal: [Float] = [0, 0, 1, -1]
        let identical = try SequencePauseBridgeObserverHarness.luminanceGeometry(a, a)
        XCTAssertEqual(identical["cosine"] as? Double, 1)
        XCTAssertEqual(identical["pearson"] as? Double, 1)
        let negative = try SequencePauseBridgeObserverHarness.luminanceGeometry(a, opposed)
        XCTAssertEqual(negative["cosine"] as? Double, -1)
        XCTAssertEqual(negative["pearson"] as? Double, -1)
        let zeroCorrelation = try SequencePauseBridgeObserverHarness.luminanceGeometry(a, orthogonal)
        XCTAssertEqual(zeroCorrelation["cosine"] as? Double, 0)
        XCTAssertEqual(zeroCorrelation["pearson"] as? Double, 0)
        let shifted = try SequencePauseBridgeObserverHarness.luminanceGeometry([0, 1, 2, 3], [-1, 0, 1, 2])
        XCTAssertEqual(shifted["pearson"] as? Double, 1)
        XCTAssertLessThan(try XCTUnwrap(shifted["cosine"] as? Double), 1)
        let reverse = try SequencePauseBridgeObserverHarness.luminanceGeometry([-1, 0, 1, 2], [0, 1, 2, 3])
        for name in ["rawDot", "centeredDot", "cosine", "pearson"] { XCTAssertEqual(shifted[name] as? Double, reverse[name] as? Double) }
        XCTAssertEqual(shifted["firstNormSquared"] as? Double, reverse["secondNormSquared"] as? Double)
        let noEnergy = try SequencePauseBridgeObserverHarness.luminanceGeometry([0, 0, 0], [1, -1, 0])
        XCTAssertTrue(noEnergy["cosine"] is NSNull); XCTAssertTrue(noEnergy["pearson"] is NSNull)
        XCTAssertEqual(noEnergy["cosineUnavailableReason"] as? String, "zero-or-degenerate-energy")
        let constant = try SequencePauseBridgeObserverHarness.luminanceGeometry([1, 1, 1], [2, 2, 2])
        XCTAssertEqual(constant["cosine"] as? Double, 1)
        XCTAssertTrue(constant["pearson"] is NSNull)
        XCTAssertEqual(constant["pearsonUnavailableReason"] as? String, "zero-or-degenerate-energy")
    }
    func testLuminanceGeometryRejectsInvalidOrNonfiniteVectors() throws {
        let invalidVectors: [[Float]] = [[], [.nan], [.infinity], [4]]
        for invalid in invalidVectors {
            XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.luminanceGeometry(invalid, invalid))
        }
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.luminanceGeometry([0], [0, 0]))
    }
    func testObserverCapsFailExplicitlyAndTraceSubsetDoesNotClaimCompleteness() throws {
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.bytes(["synthetic": String(repeating: "x", count: 32)], limit: 8))
        let collector = PauseBridgeObserverTrace(limit: 1)
        collector.record(SequenceTraceEvent(ordinal: 0, stage: .local, reason: .passed, accepted: true))
        XCTAssertTrue(try collector.snapshot().isEmpty)
        collector.record(SequenceTraceEvent(ordinal: 1, stage: .anchor, reason: .passed, accepted: true))
        XCTAssertEqual(try collector.snapshot().count, 1)
        collector.record(SequenceTraceEvent(ordinal: 2, stage: .bridge, reason: .bridgeAccepted, accepted: true))
        XCTAssertThrowsError(try collector.snapshot())
        XCTAssertTrue(SequencePauseBridgeObserverHarness.traceBoundary.contains("absence is not causal evidence"))
        XCTAssertTrue(SequencePauseBridgeObserverHarness.traceBoundary.contains("summary is unavailable"))
        let noContinuousFrames = PauseBridgeObserverTrace(limit: 0, allowedOrdinals: [])
        noContinuousFrames.record(SequenceTraceEvent(ordinal: 0, stage: .anchor, reason: .passed, accepted: true))
        XCTAssertTrue(try noContinuousFrames.snapshot().isEmpty)
    }
    func testOutputCannotAliasFixturesOrTraverseSymlinkWithMissingTail() throws {
        // The output policy rejects every symlink ancestor, including macOS /var.
        // Exercise it in the same canonical workspace output tree as the real runner.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("output/observer-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.protectedOutput(root.appendingPathComponent("Tests/fixture.json").path, repository: root))
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.protectedOutput(root.appendingPathComponent("output-other/file.json").path, repository: root))
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.protectedOutput("relative.json", repository: root))
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("alias"), withDestinationURL: root)
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.protectedOutput(output.appendingPathComponent("alias/missing/file.json").path, repository: root))
        let safe = output.appendingPathComponent("safe/report.json")
        _ = try SequencePauseBridgeObserverHarness.write(Data("{}".utf8), path: safe.path, repository: root)
        XCTAssertThrowsError(try SequencePauseBridgeObserverHarness.write(Data("{}".utf8), path: safe.path, repository: root))
    }
    func testOfflineObserverUnit() throws {
        let env = ProcessInfo.processInfo.environment
        guard let control = env["RAWMASTER_PAUSE_OBSERVER_UNIT"] else { throw XCTSkip("Explicit frozen six-unit pause observer only") }
        guard let report = env["RAWMASTER_PAUSE_OBSERVER_REPORT"] else { throw SequenceFixtureError.invalid("Missing pause observer report") }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let target = try SequencePauseBridgeObserverHarness.protectedOutput(report, repository: repository)
        let request = try JSONDecoder().decode(PauseBridgeObserverUnit.self, from: Data(contentsOf: URL(fileURLWithPath: control)))
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let value = try SequencePauseBridgeObserverHarness.run(request,
            v1: resources.appendingPathComponent("Fixtures/SequenceGrouping/v1"),
            v2: resources.appendingPathComponent("Fixtures/SequenceGroupingMetadata/v2"), output: target, repository: repository)
        _ = try SequencePauseBridgeObserverHarness.write(SequencePauseBridgeObserverHarness.bytes(value), path: target.path, repository: repository)
    }
}
