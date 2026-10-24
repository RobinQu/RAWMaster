import XCTest
import Foundation
import CryptoKit
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class ProbeManifestRunTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sequence-probe-synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func policy() -> ProbePolicy {
        ProbePolicy(schemaVersion: 2, detector: .init(), sourceAssertion: ProbeSourceAssertion(id: "test-whole-manifest", revision: 0, declaredByUser: false, provenance: "synthetic only"), acceptance: nil, maximumDurationSeconds: 30, deterministicSeed: 0)
    }
    func description(_ names: [String]) -> ProbeManifest {
        ProbeManifest(schemaVersion: 1, scopeID: "test", sessionID: "one", orderVersion: SequenceBaseOrder.version, files: names.enumerated().map { .init(assetID: "id\($0.offset)", ordinal: $0.offset, relativePath: $0.element) })
    }
    func readValue(_ entry: SequenceManifestEntry) throws -> ProbeReadValue {
        var histogram = Array(repeating: Float(0), count: 48)
        for index in [0, 16, 32] { histogram[index] = 1 }
        let feature = try SequenceFrameFeature(width: 32, height: 32, normalizedLuminance: (0..<1024).map { $0.isMultiple(of: 2) ? -0.5 : 0.5 }, colorHistogram: histogram, differenceHash: 42, mean: 0.5, standardDeviation: 0.2)
        let evidence = SequenceCaptureEvidence(assetID: entry.assetID, contentHash: entry.contentHash!, extractorVersion: SequenceCaptureReader.extractorVersion,
            time: SequenceTimestampParser.parse(original: "2026:10:01 12:00:00", subseconds: "\(entry.ordinal + 1)00", offset: nil))
        return ProbeReadValue(evidence: evidence, feature: feature, failure: nil)
    }
    func testExplicitOrderOnlyAndFilenamesAreNotAlgorithmSignals() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["z.arw", "a.arw", "neighbor-not-listed.arw"] { try Data("synthetic bytes".utf8).write(to: root.appendingPathComponent(name)) }
        var calls: [String] = []
        let first = try SequenceProbeRun.analyze(manifest: description(["z.arw", "a.arw"]), root: root, policy: policy()) { url, entry, _ in calls.append(url.lastPathComponent); return try self.readValue(entry) }
        XCTAssertEqual(calls, ["z.arw", "a.arw"])
        XCTAssertEqual(first.observations.count, 2); XCTAssertTrue(first.sourcesUnchanged)
        try FileManager.default.moveItem(at: root.appendingPathComponent("z.arw"), to: root.appendingPathComponent("first-renamed.arw"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.arw"), to: root.appendingPathComponent("second-renamed.arw"))
        let second = try SequenceProbeRun.analyze(manifest: description(["first-renamed.arw", "second-renamed.arw"]), root: root, policy: policy()) { _, entry, _ in try self.readValue(entry) }
        XCTAssertEqual(first.result.ranges, second.result.ranges)
        XCTAssertEqual(first.manifest.contentFingerprint, second.manifest.contentFingerprint)
    }
    func testSourceMutationCannotPassIntegrityAndMissingInputKeepsOrdinal() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("before".utf8).write(to: root.appendingPathComponent("one.arw"))
        let changed = try SequenceProbeRun.analyze(manifest: description(["one.arw"]), root: root, policy: policy()) { url, entry, _ in
            try Data("changed during synthetic read".utf8).write(to: url)
            return try self.readValue(entry)
        }
        XCTAssertFalse(changed.sourcesUnchanged)
        let missing = try SequenceProbeRun.analyze(manifest: description(["missing.arw", "one.arw"]), root: root, policy: policy()) { _, entry, _ in try self.readValue(entry) }
        XCTAssertEqual(missing.observations.map(\.entry.ordinal), [0, 1])
        XCTAssertEqual(missing.observations[0].entry.barrier, .unreadable)
        XCTAssertFalse(missing.sourcesUnchanged)
    }
    func testUnsafeAndDuplicateManifestNeverCallsReader() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for names in [["../escape.arw"], ["/absolute.arw"], ["a.arw", "a.arw"], ["nested//bad.arw"]] {
            var called = false
            XCTAssertThrowsError(try SequenceProbeRun.analyze(manifest: description(names), root: root, policy: policy()) { _, entry, _ in called = true; return try self.readValue(entry) })
            XCTAssertFalse(called)
        }
        let outside = try directory(); defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("file.arw"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.arw"), withDestinationURL: outside.appendingPathComponent("file.arw"))
        XCTAssertThrowsError(try description(["escape.arw"]).urls(root: root))
    }
    func testNormalOptionsRequireAbsolutePathsAndRejectParameterAliases() throws {
        let valid = ["--source-root", "/tmp/source", "--manifest", "/tmp/manifest", "--policy", "/tmp/policy", "--labels", "/tmp/labels", "--report", "/tmp/report"]
        XCTAssertNoThrow(try SequenceProbeCLI.options(valid))
        for position in stride(from: 1, to: valid.count, by: 2) {
            var bad = valid; bad[position] = "relative"
            XCTAssertThrowsError(try SequenceProbeCLI.options(bad))
        }
        var duplicate = valid; duplicate[2] = "--source-root"
        XCTAssertThrowsError(try SequenceProbeCLI.options(duplicate))
    }
    // This checks bounded chunk work and digest correctness, not a flaky process RSS ceiling.
    // The root-owned old-data guarded run separately validates real peak memory after this fix.
    func testRepeatedLargeSyntheticHashUsesBoundedChunksAndKeepsCredential() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large-synthetic.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let writer = try FileHandle(forWritingTo: file)
        let chunk = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let tail = Data(repeating: 0x17, count: 257)
        var expected = SHA256()
        for _ in 0..<16 { try writer.write(contentsOf: chunk); expected.update(data: chunk) }
        try writer.write(contentsOf: tail); expected.update(data: tail); try writer.close()
        let digest = expected.finalize().map { String(format: "%02x", $0) }.joined()
        let credential = try SequenceFileCredential.capture(at: file)
        for _ in 0..<3 {
            var sizes: [Int] = []
            let actual = try SequenceProbeRun.verifiedHash(file, deadline: ProcessInfo.processInfo.systemUptime + 30, onChunk: { sizes.append($0) })
            XCTAssertEqual(actual.0, digest); XCTAssertEqual(actual.1, credential)
            XCTAssertEqual(sizes.reduce(0, +), 16 * 1024 * 1024 + tail.count)
            XCTAssertTrue(sizes.allSatisfy { $0 > 0 && $0 <= 1024 * 1024 })
            XCTAssertGreaterThan(sizes.count, 1)
        }
    }
    func testOfflineDefaultPolicyContainsAllDetectorFieldsAndCannotOverwrite() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("policy.json")
        XCTAssertEqual(try SequenceProbeCLI.run(["--write-default-policy", file.path]), 0)
        let value = try JSONDecoder().decode(ProbePolicy.self, from: Data(contentsOf: file))
        XCTAssertEqual(value.detector, SequenceDetectorConfiguration())
        XCTAssertEqual(value.acceptance?.minimumPrecision, 0.95)
        XCTAssertEqual(value.acceptance?.minimumNegativePairs, 2)
        XCTAssertEqual(value.sourceAssertion?.declaredByUser, false)
        XCTAssertEqual(value.schemaVersion, 2)
        XCTAssertThrowsError(try SequenceProbeCLI.run(["--write-default-policy", file.path]))
    }
}
