import XCTest
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class SequenceFocusExperimentTests: XCTestCase {
    private struct CoverageFact: Equatable {
        let state: SequenceCoverageState
        let reasons: [SequenceReason]
    }
    private func coverage(_ result: SequenceAnalysisResult) -> [Int: CoverageFact] {
        var facts: [Int: CoverageFact] = [:]
        for part in result.coverage {
            for ordinal in part.range.first...part.range.last { facts[ordinal] = CoverageFact(state: part.state, reasons: part.reasons) }
        }
        return facts
    }
    private func joined(_ result: SequenceAnalysisResult, _ left: Int, _ right: Int) -> Bool {
        result.ranges.contains { $0.range.first <= left && right <= $0.range.last }
    }
    /// Pins observed development behavior and explicit no-added-split evidence, not production quality.
    func testObservedFocusBehaviorAndEveryPreviouslyJoinedKnownPositiveEdge() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let v1 = resources.appendingPathComponent("Fixtures/SequenceGrouping/v1"), v2 = resources.appendingPathComponent("Fixtures/SequenceGroupingMetadata/v2")
        let focusRoot = resources.appendingPathComponent("Fixtures/SequenceGroupingFocus/v1")
        let bytes = try Data(contentsOf: focusRoot.appendingPathComponent("baselines/behavior-v1.json"))
        XCTAssertEqual(SequenceProbeRun.sha256(bytes), "57c82c075a524f260d166aea88404b4176b97288717d3b4aba453216d603496b")
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(baseline["kind"] as? String, "observed-focus-bridge-behavior")
        XCTAssertEqual(baseline["qualityAccepted"] as? Bool, false)
        let lineage = try XCTUnwrap(baseline["lineage"] as? [String: Any])
        let expected009 = try XCTUnwrap(baseline["observations"] as? [[String: Any]])
        let oldBytes = try Data(contentsOf: v2.appendingPathComponent("baselines/behavior-v1.json"))
        XCTAssertEqual(SequenceProbeRun.sha256(oldBytes), "0b3d5c6d09a35bc655633c5e1633def18bad2fee6eb5cf1b4f253e2991de2dbc")
        let old = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        let expected008 = try XCTUnwrap(old["observations"] as? [[String: Any]])
        XCTAssertEqual(expected009.count, 12)
        let (index, v1Bytes) = try SequenceFixtureHarness.loadIndex(root: v1)
        let v2Bytes = try Data(contentsOf: v2.appendingPathComponent("index.json")), focusBytes = try Data(contentsOf: focusRoot.appendingPathComponent("index.json"))
        XCTAssertEqual(lineage["fixtureIndexSHA256"] as? String, SequenceProbeRun.sha256(v1Bytes))
        XCTAssertEqual(lineage["metadataIndexSHA256"] as? String, SequenceProbeRun.sha256(v2Bytes))
        XCTAssertEqual(lineage["focusIndexSHA256"] as? String, SequenceProbeRun.sha256(focusBytes))
        var checked = 0
        for item in index.cases {
            let request = FocusExperimentUnit(schemaVersion: 1, runID: "focus-observed-regression", unitID: item.id, phase: "bootstrap", caseID: item.id,
                variant: nil, expectedPolicyFingerprint: nil, fixtureIndexSHA256: SequenceProbeRun.sha256(v1Bytes), metadataIndexSHA256: SequenceProbeRun.sha256(v2Bytes),
                focusIndexSHA256: SequenceProbeRun.sha256(focusBytes), sourceSnapshotSHA256: try XCTUnwrap(lineage["sourceSnapshotSHA256"] as? String),
                executableSHA256: try XCTUnwrap(lineage["executableSHA256"] as? String))
            let prepared = try MetadataExperimentHarness.prepare(SequenceFocusExperimentHarness.request(request), v1: v1, v2: v2)
            let focus = try SequenceFocusExperimentHarness.focus(request, prepared: prepared, root: focusRoot)
            XCTAssertTrue(prepared.native.sourcesUnchanged)
            XCTAssertEqual(focus.focusAuditSeal, lineage["focusAuditSeal"] as? String)
            XCTAssertEqual(prepared.snapshot.auditSeal, lineage["metadataAuditSeal"] as? String)
            // All four native classifications finish before this case's human truth is loaded.
            let results = try SequenceFocusExperimentHarness.variants.map { name -> (String, SequenceMetadataEventAnalysis) in
                let (association, enabled) = try SequenceFocusExperimentHarness.policy(name)
                let result = try SequenceMetadataEventPipeline.analyze(files: prepared.files, manifest: prepared.native.manifest,
                    metadata: prepared.snapshot, associationPolicy: association, rescuePolicy: .allowShortRestart,
                    focusSnapshot: enabled ? focus : nil, pauseBridgePolicy: enabled ? .focusRectAndCohortSeparation : nil)
                return (name, result)
            }
            let (truthBytes, _) = try SequenceFixtureHarness.verifiedSidecar(item.truthPath, expectedHash: item.truthSHA256, root: v1)
            let labels = try SequenceFixtureHarness.decode(ProbeLabels.self, data: truthBytes)
            var evaluations: [String: ProbeEvaluation] = [:]
            for (name, result) in results {
                let (association, enabled) = try SequenceFocusExperimentHarness.policy(name)
                let oldName = association == .strict ? "strict-shortRestart" : "assumed-shortRestart"
                let candidates = (enabled ? expected009 : expected008).filter { $0["caseID"] as? String == item.id && $0["variant"] as? String == (enabled ? name : oldName) }
                XCTAssertEqual(candidates.count, 1)
                let expected = try XCTUnwrap(candidates.first), context = "Observed009 \(item.id)/\(name)"
                XCTAssertEqual(expected["assetCount"] as? Int, item.assetCount, context)
                XCTAssertEqual(expected["metadataSnapshotSHA256"] as? String, prepared.snapshot.fingerprint, context)
                XCTAssertEqual(expected["resultSHA256"] as? String, try SequenceProbeRun.resultSHA256(result.result), context)
                XCTAssertEqual(expected["policyFingerprint"] as? String, try result.configuration.fingerprint, context)
                XCTAssertEqual(expected["eventMapFingerprint"] as? String, result.map.fingerprint, context)
                XCTAssertEqual(expected["scopeSnapshotFingerprint"] as? String, result.map.scopeSnapshotFingerprint, context)
                XCTAssertEqual(expected["eventCount"] as? Int, result.map.events.count, context)
                XCTAssertEqual(expected["proposalCount"] as? Int, result.map.proposals.count, context)
                XCTAssertEqual(result.map.events.flatMap { $0.members.map(\.ordinal) }, Array(0..<item.assetCount), context)
                let analysis = ProbeAnalysis(manifest: result.manifest, result: result.result, observations: result.observations,
                    featuresAvailable: result.featuresAvailable, sources: prepared.native.sources,
                    hashBeforeSeconds: 0, readerAndEngineSeconds: 0, hashAfterSeconds: 0, analysisSeconds: 0,
                    engineManagedPeakEstimateBytes: result.managedPeakEstimateBytes, processPeakResidentBytes: nil)
                let evaluation = try ProbeEvaluator.evaluateMetadata(analysis: analysis, labels: labels,
                    policy: SpatialExperimentHarness.policy(caseID: item.id, configuration: result.configuration, trace: false),
                    configuration: try XCTUnwrap(result.configuration.metadataExperiment), files: prepared.files, map: result.map,
                    metadata: prepared.snapshot, confirmedPairs: [], focusSnapshot: enabled ? focus : nil)
                evaluations[name] = evaluation
                let actualEvaluation = try XCTUnwrap(SpatialExperimentHarness.object(evaluation) as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: actualEvaluation).isEqual(to: try XCTUnwrap(expected["evaluation"] as? [String: Any])), context)
                let actualMetadataStatistics = try XCTUnwrap(SpatialExperimentHarness.object(try XCTUnwrap(result.metadataStatistics)) as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: actualMetadataStatistics).isEqual(to: try XCTUnwrap(expected["metadataStatistics"] as? [String: Any])), context)
                let assumed = result.associationHypothesisAssumed
                let topAccepted = evaluation.acceptedWithinDeclaredSourceScope && !assumed && item.completeGroupTruth
                XCTAssertEqual(expected["associationHypothesisAssumed"] as? Bool, assumed, context)
                XCTAssertEqual(expected["topQualityAccepted"] as? Bool, topAccepted, context)
                XCTAssertEqual(expected["metricsMeaning"] as? String, assumed ? "conditionalGroupingMetrics" : "strictGroupingMetricsUnderDeclaredSource", context)
                XCTAssertTrue(expected["pairPrecision"] is NSNull, context)
                XCTAssertEqual(expected["unknownTruthAssetIDs"] as? [String], item.unknownAssetIDs, context)
                if enabled {
                    let actualConfig = try XCTUnwrap(SpatialExperimentHarness.object(result.configuration) as? [String: Any])
                    XCTAssertTrue(NSDictionary(dictionary: actualConfig).isEqual(to: try XCTUnwrap(expected["configuration"] as? [String: Any])), context)
                    XCTAssertEqual(expected["focusSnapshotSHA256"] as? String, focus.fingerprint, context)
                    XCTAssertEqual(expected["focusAuditSeal"] as? String, focus.focusAuditSeal, context)
                    XCTAssertEqual(expected["focusBoundFingerprint"] as? String, try focus.boundFingerprint(manifest: prepared.native.manifest, metadata: prepared.snapshot), context)
                    let stats = try XCTUnwrap(SpatialExperimentHarness.object(try XCTUnwrap(result.pauseBridgeStatistics)) as? [String: Any])
                    XCTAssertTrue(NSDictionary(dictionary: stats).isEqual(to: try XCTUnwrap(expected["pauseBridgeStatistics"] as? [String: Any])), context)
                } else { XCTAssertNil(result.pauseBridgeStatistics, context); XCTAssertNil(result.configuration.pauseBridgeExperiment, context) }
                checked += 1
            }
            let ordinals = Dictionary(uniqueKeysWithValues: prepared.native.manifest.entries.map { ($0.assetID, $0.ordinal) })
            for association in ["strict", "assumed"] {
                let before = try XCTUnwrap(results.first { $0.0 == "008B-" + association }?.1)
                let after = try XCTUnwrap(results.first { $0.0 == "009-" + association }?.1)
                let oldEvaluation = try XCTUnwrap(evaluations["008B-" + association]), newEvaluation = try XCTUnwrap(evaluations["009-" + association])
                let context = "No added split \(item.id)/\(association)"
                XCTAssertEqual(before.map, after.map, context)
                XCTAssertEqual(before.observations, after.observations, context)
                XCTAssertEqual(before.featuresAvailable, after.featuresAvailable, context)
                XCTAssertEqual(coverage(before.result), coverage(after.result), context)
                XCTAssertEqual(coverage(after.result).keys.sorted(), Array(0..<item.assetCount), context)
                XCTAssertEqual(oldEvaluation.unknownCount, newEvaluation.unknownCount, context)
                XCTAssertEqual(oldEvaluation.unknownPositivePairs, newEvaluation.unknownPositivePairs, context)
                XCTAssertEqual(oldEvaluation.unknownNegativePairs, newEvaluation.unknownNegativePairs, context)
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: oldEvaluation.groups.map { ($0.id, $0.typedMemberCount) }),
                    Dictionary(uniqueKeysWithValues: newEvaluation.groups.map { ($0.id, $0.typedMemberCount) }), context)
                for group in oldEvaluation.groups where group.exactMembershipAndType {
                    XCTAssertEqual(newEvaluation.groups.first { $0.id == group.id }?.exactMembershipAndType, true, context)
                }
                for group in labels.groups {
                    let members = Set(group.assetIDs.compactMap { ordinals[$0] })
                    for left in members.sorted() where members.contains(left + 1) && joined(before.result, left, left + 1) {
                        XCTAssertTrue(joined(after.result, left, left + 1), context + " positive \(left)/\(left + 1)")
                    }
                }
                for pair in labels.negativePairs {
                    let left = try XCTUnwrap(ordinals[pair.from]), right = try XCTUnwrap(ordinals[pair.to])
                    if !joined(before.result, min(left, right), max(left, right)) {
                        XCTAssertFalse(joined(after.result, min(left, right), max(left, right)), context)
                    }
                }
            }
        }
        XCTAssertEqual(checked, 24)
    }
    func testOfflineUnit() throws {
        let env = ProcessInfo.processInfo.environment
        guard let control = env["RAWMASTER_FOCUS_EXPERIMENT_UNIT"] else { throw XCTSkip("Explicit frozen24unit focus research runner only") }
        guard let path = env["RAWMASTER_FOCUS_EXPERIMENT_REPORT"] else { throw SequenceFixtureError.invalid("Missing focus experiment report") }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = try SequencePauseBridgeObserverHarness.protectedOutput(path, repository: repository)
        let request = try JSONDecoder().decode(FocusExperimentUnit.self, from: Data(contentsOf: URL(fileURLWithPath: control)))
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let v1 = resources.appendingPathComponent("Fixtures/SequenceGrouping/v1"), v2 = resources.appendingPathComponent("Fixtures/SequenceGroupingMetadata/v2")
        let focus = resources.appendingPathComponent("Fixtures/SequenceGroupingFocus/v1")
        let value = request.phase == "bootstrap" ? try SequenceFocusExperimentHarness.bootstrap(request, v1: v1, v2: v2, focusRoot: focus)
            : try SequenceFocusExperimentHarness.run(request, v1: v1, v2: v2, focusRoot: focus, output: output)
        _ = try SequencePauseBridgeObserverHarness.write(SequencePauseBridgeObserverHarness.bytes(value), path: output.path, repository: repository)
    }
    func testAll1265FocusBindingsRetain450AuditedAnd815OutsideWithNoClaimedFacts() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let v1 = resources.appendingPathComponent("Fixtures/SequenceGrouping/v1"), v2 = resources.appendingPathComponent("Fixtures/SequenceGroupingMetadata/v2")
        let focusRoot = resources.appendingPathComponent("Fixtures/SequenceGroupingFocus/v1")
        let (_, v1Bytes) = try SequenceFixtureHarness.loadIndex(root: v1)
        let v2Bytes = try Data(contentsOf: v2.appendingPathComponent("index.json")), focusBytes = try Data(contentsOf: focusRoot.appendingPathComponent("index.json"))
        let index = try SequenceFocusEvidenceLoader.loadIndex(at: focusRoot.appendingPathComponent("index.json"), expectedSHA256: SequenceProbeRun.sha256(focusBytes))
        var audited = 0, outside = 0
        for item in index.cases {
            // These syntactic IDs are for a normal regression, not an executable/source attestation.
            let request = FocusExperimentUnit(schemaVersion: 1, runID: "focus-binding-regression", unitID: item.id, phase: "bootstrap", caseID: item.id,
                variant: nil, expectedPolicyFingerprint: nil, fixtureIndexSHA256: SequenceProbeRun.sha256(v1Bytes), metadataIndexSHA256: SequenceProbeRun.sha256(v2Bytes),
                focusIndexSHA256: SequenceProbeRun.sha256(focusBytes), sourceSnapshotSHA256: String(repeating: "a", count: 64), executableSHA256: String(repeating: "b", count: 64))
            let prepared = try MetadataExperimentHarness.prepare(SequenceFocusExperimentHarness.request(request), v1: v1, v2: v2)
            let snapshot = try SequenceFocusExperimentHarness.focus(request, prepared: prepared, root: focusRoot)
            XCTAssertEqual(snapshot.files.count, item.assetCount)
            XCTAssertEqual(snapshot.fingerprint, item.sha256)
            XCTAssertEqual(snapshot.metadataSnapshotFingerprint, prepared.snapshot.fingerprint)
            XCTAssertNotEqual(try snapshot.boundFingerprint(manifest: prepared.native.manifest, metadata: prepared.snapshot), snapshot.fingerprint)
            XCTAssertTrue(prepared.native.sourcesUnchanged)
            for file in snapshot.files {
                if file.state == .audited {
                    audited += 1
                    XCTAssertEqual(Set(file.fieldStates.keys), SequenceFocusSnapshot.allFields)
                    XCTAssertEqual(file.fieldStates["exif.SubjectDistance"], .absent)
                } else {
                    outside += 1
                    XCTAssertTrue(file.fieldStates.isEmpty); XCTAssertTrue(file.resolvedCodes.isEmpty); XCTAssertTrue(file.resolvedTuples.isEmpty)
                }
            }
        }
        XCTAssertEqual(audited, 450); XCTAssertEqual(outside, 815)
    }
}
