import XCTest
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class ProbeTraceTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sequence-trace-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func policy(_ trace: ProbeBoundedTrace?, schema: Int = 3) -> ProbePolicy {
        ProbePolicy(schemaVersion: schema, detector: .init(), sourceAssertion: .init(id: "synthetic", revision: 0, declaredByUser: false, provenance: "synthetic only"),
            acceptance: nil, maximumDurationSeconds: 30, deterministicSeed: 0, boundedTrace: trace)
    }
    private func input(_ root: URL) throws -> ProbeManifest {
        let names = ["first.bin", "second.bin", "third.bin", "fourth.bin"]
        for name in names { try Data("synthetic-byte-stamp".utf8).write(to: root.appendingPathComponent(name)) }
        return ProbeManifest(schemaVersion: 1, scopeID: "synthetic", sessionID: "one", orderVersion: SequenceBaseOrder.version,
            files: names.enumerated().map { .init(assetID: "f\($0.offset)", ordinal: $0.offset, relativePath: $0.element) })
    }
    private func read(_ entry: SequenceManifestEntry) throws -> ProbeReadValue {
        var histogram = Array(repeating: Float(0), count: 48)
        for index in [0, 16, 32] { histogram[index] = 1 }
        let feature = try SequenceFrameFeature(width: 32, height: 32,
            normalizedLuminance: (0..<1024).map { $0.isMultiple(of: 2) ? -0.5 : 0.5 },
            colorHistogram: histogram, differenceHash: 42, mean: 0.5, standardDeviation: 0.2)
        let evidence = SequenceCaptureEvidence(assetID: entry.assetID, contentHash: entry.contentHash!, extractorVersion: SequenceCaptureReader.extractorVersion,
            time: SequenceTimestampParser.parse(original: "2026:10:01 12:00:00", subseconds: "\(entry.ordinal + 1)00", offset: nil))
        return ProbeReadValue(evidence: evidence, feature: feature, failure: nil)
    }
    private func lines(_ url: URL) throws -> [[String: Any]] {
        try Data(contentsOf: url).split(separator: 10).map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }
    func testSchemaTwoRemainsOffAndSchemaThreeTraceIsExplicitAndBounded() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let old = policy(nil, schema: 2)
        let oldBytes = try encoder.encode(old)
        XCTAssertNil((try JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])?["boundedTrace"])
        XCTAssertNil(try decoder.decode(ProbePolicy.self, from: oldBytes).boundedTrace)
        XCTAssertNoThrow(try policy(nil).validate())
        XCTAssertNoThrow(try policy(.init()).validate())
        XCTAssertThrowsError(try policy(.init(), schema: 2).validate())
        XCTAssertThrowsError(try policy(.init(version: "unknown-trace")).validate())
        XCTAssertThrowsError(try policy(.init(maximumFileBytes: 12)).validate())
        XCTAssertThrowsError(try policy(.init(limits: .init(maximumBytes: 32 * 1024 * 1024))).validate())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(policy(.init()))) as? [String: Any])
        var trace = try XCTUnwrap(object["boundedTrace"] as? [String: Any])
        trace["limits"] = ["maximumEvents": 64_001, "maximumBytes": 10, "maximumEventsPerFrame": 2]
        object["boundedTrace"] = trace
        XCTAssertThrowsError(try decoder.decode(ProbePolicy.self, from: JSONSerialization.data(withJSONObject: object)).validate())
        XCTAssertEqual(try old.detector.fingerprint, try policy(.init()).detector.fingerprint)
    }
    func testDerivedTraceReservationRejectsExistingControlsAndSourceSymlinkBeforeReader() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let report = root.appendingPathComponent("report.json")
        let output = ProbeTraceSink.derivedURL(reportURL: report)
        XCTAssertEqual(output.path, report.path + ".trace.jsonl")
        XCTAssertThrowsError(try ProbeTraceSink.reserve(reportURL: report, sourceRoot: source, controls: [output], configuration: .init()))
        try Data("reserved-receipt-or-control".utf8).write(to: output)
        XCTAssertThrowsError(try ProbeTraceSink.reserve(reportURL: report, sourceRoot: source, controls: [], configuration: .init()))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "reserved-receipt-or-control")
        let link = root.appendingPathComponent("linked-output")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try ProbeTraceSink.reserve(reportURL: link.appendingPathComponent("report.json"), sourceRoot: source, controls: [], configuration: .init()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("report.json.trace.jsonl").path))
    }
    func testStreamAndFooterBindIdenticalDeterministicResultBeforeLabels() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = try input(source)
        let off = try SequenceProbeRun.analyze(manifest: manifest, root: source, policy: policy(nil)) { _, entry, _ in try self.read(entry) }
        let config = ProbeBoundedTrace()
        let sink = try ProbeTraceSink.reserve(reportURL: root.appendingPathComponent("report.json"), sourceRoot: source, controls: [], configuration: config)
        try sink.begin(manifestControlSHA256: "synthetic-manifest", policyControlSHA256: "synthetic-policy")
        var summary: SequenceTraceSummary?
        let on = try SequenceProbeRun.analyze(manifest: manifest, root: source, policy: policy(config), trace: sink, onTraceSummary: { summary = $0 }) { _, entry, _ in try self.read(entry) }
        XCTAssertEqual(try SequenceProbeRun.resultSHA256(off.result), try SequenceProbeRun.resultSHA256(on.result))
        var traceReport: ProbeTraceReport?
        var loadedLabels = false
        let labels = ProbeLabels(schemaVersion: 1, role: "synthetic", groups: [], negativePairs: [])
        let (seal, _) = try SequenceProbeRun.sealThenEvaluate(on, policy: policy(config), onSealed: { seal in
            traceReport = try sink.finish(analysis: on, analysisSHA256: seal, summary: XCTUnwrap(summary))
        }) {
            XCTAssertEqual(try self.lines(sink.url).last?["recordType"] as? String, "footer")
            loadedLabels = true; return labels
        }
        XCTAssertTrue(loadedLabels)
        let report = try XCTUnwrap(traceReport), data = try Data(contentsOf: sink.url), records = try lines(sink.url)
        XCTAssertEqual(report.sha256, SequenceProbeRun.sha256(data)); XCTAssertEqual(report.fileBytes, data.count)
        XCTAssertLessThanOrEqual(report.fileBytes, config.maximumFileBytes)
        XCTAssertEqual(records.first?["recordType"] as? String, "header"); XCTAssertEqual(records.last?["analysisSHA256"] as? String, seal)
        XCTAssertEqual(records.last?["resultSHA256"] as? String, report.resultSHA256)
        XCTAssertGreaterThan(report.eventCount, 0); XCTAssertEqual(records.count, report.eventCount + 2)
        XCTAssertFalse(report.incomplete)
        let eventRows = Array(records.dropFirst().dropLast())
        for event in eventRows {
            XCTAssertNil(event["path"]); XCTAssertNil(event["label"]); XCTAssertNil(event["pixels"])
            XCTAssertTrue(event.values.allSatisfy { !($0 is [Any]) && !($0 is [String: Any]) })
        }
        let eventBytes = data.split(separator: 10).dropFirst().dropLast().reduce(0) { $0 + $1.count + 1 }
        XCTAssertEqual(report.eventBytes, eventBytes)
        XCTAssertEqual(report.fileBytes, report.eventBytes + data.split(separator: 10).first!.count + data.split(separator: 10).last!.count + 2)
    }
    func testZeroEventBudgetExplicitlyTruncatesWithoutChangingResult() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = try input(source), config = ProbeBoundedTrace(limits: .init(maximumEvents: 0, maximumBytes: 0, maximumEventsPerFrame: 0))
        let off = try SequenceProbeRun.analyze(manifest: manifest, root: source, policy: policy(nil)) { _, entry, _ in try self.read(entry) }
        let sink = try ProbeTraceSink.reserve(reportURL: root.appendingPathComponent("report.json"), sourceRoot: source, controls: [], configuration: config)
        try sink.begin(manifestControlSHA256: "manifest", policyControlSHA256: "policy")
        var summary: SequenceTraceSummary?
        let on = try SequenceProbeRun.analyze(manifest: manifest, root: source, policy: policy(config), trace: sink, onTraceSummary: { summary = $0 }) { _, entry, _ in try self.read(entry) }
        XCTAssertEqual(try SequenceProbeRun.resultSHA256(on.result), try SequenceProbeRun.resultSHA256(off.result))
        let actual = try XCTUnwrap(summary)
        let report = try sink.finish(analysis: on, analysisSHA256: "sealed-before-labels", summary: actual)
        XCTAssertEqual(report.eventCount, 0); XCTAssertEqual(report.eventBytes, 0)
        XCTAssertGreaterThan(actual.droppedEvents, 0); XCTAssertTrue(report.incomplete)
        XCTAssertEqual(try lines(sink.url).last?["incomplete"] as? Bool, true)
        XCTAssertEqual(try lines(sink.url).count, 2)
    }
    func testSinkFailureDoesNotAlterClassificationOrLoadLabels() throws {
        enum Failure: Error { case intentional }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = try input(source), config = ProbeBoundedTrace()
        var writes = 0
        let sink = try ProbeTraceSink.reserve(reportURL: root.appendingPathComponent("report.json"), sourceRoot: source, controls: [], configuration: config,
            writerOverride: { _ in writes += 1; if writes > 1 { throw Failure.intentional } })
        try sink.begin(manifestControlSHA256: "manifest", policyControlSHA256: "policy")
        var summary: SequenceTraceSummary?
        let failedTrace = try SequenceProbeRun.analyze(manifest: manifest, root: source, policy: policy(config), trace: sink, onTraceSummary: { summary = $0 }) { _, entry, _ in try self.read(entry) }
        let off = try SequenceProbeRun.analyze(manifest: manifest, root: source, policy: policy(nil)) { _, entry, _ in try self.read(entry) }
        XCTAssertEqual(try SequenceProbeRun.resultSHA256(failedTrace.result), try SequenceProbeRun.resultSHA256(off.result))
        var labelsCalled = false
        XCTAssertThrowsError(try SequenceProbeRun.sealThenEvaluate(failedTrace, policy: policy(config), onSealed: { seal in
            _ = try sink.finish(analysis: failedTrace, analysisSHA256: seal, summary: XCTUnwrap(summary))
        }) { labelsCalled = true; return ProbeLabels(schemaVersion: 1, role: "must-not-load", groups: [], negativePairs: []) })
        XCTAssertFalse(labelsCalled)
        XCTAssertEqual(writes, 2) // Once failed, later callbacks do no IO or accumulation.
    }
    func testFiveOptionsRemainExactAndDoNotAcceptTraceOutputArgument() throws {
        let arguments = ["--source-root", "/tmp/source", "--manifest", "/tmp/manifest", "--policy", "/tmp/policy", "--labels", "/tmp/labels", "--report", "/tmp/report"]
        XCTAssertNoThrow(try SequenceProbeCLI.options(arguments))
        XCTAssertThrowsError(try SequenceProbeCLI.options(arguments + ["--trace-output", "/tmp/alternate"]))
    }
}
