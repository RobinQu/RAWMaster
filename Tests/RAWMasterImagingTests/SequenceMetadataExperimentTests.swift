import XCTest
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class SequenceMetadataExperimentTests:XCTestCase {
    func testOfflineUnit() throws {
        let env=ProcessInfo.processInfo.environment
        guard let control=env["RAWMASTER_METADATA_EXPERIMENT_UNIT"] else { throw XCTSkip("Research only: explicit frozen 30-unit metadata runner") }
        guard let outputPath=env["RAWMASTER_METADATA_EXPERIMENT_REPORT"] else { throw SequenceFixtureError.invalid("Missing metadata report") }
        let resources=try XCTUnwrap(Bundle.module.resourceURL),v1=resources.appendingPathComponent("Fixtures/SequenceGrouping/v1"),v2=resources.appendingPathComponent("Fixtures/SequenceGroupingMetadata/v2")
        let output=try SpatialExperimentHarness.protectedOutput(outputPath,fixtureRoot:v1)
        let request=try JSONDecoder().decode(MetadataExperimentUnit.self,from:Data(contentsOf:URL(fileURLWithPath:control)))
        let report=request.phase=="bootstrap" ? try MetadataExperimentHarness.bootstrap(request,v1:v1,v2:v2) : try MetadataExperimentHarness.run(request,v1:v1,v2:v2,output:output)
        let bytes=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes])
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try bytes.write(to:output,options:.withoutOverwriting)
    }
    /// Pins measured candidate behavior, including known failures; this is not a quality gate.
    func testObservedMetadataBehaviorRetainsAllTwentyFourNativeResults() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let v1 = resources.appendingPathComponent("Fixtures/SequenceGrouping/v1")
        let v2 = resources.appendingPathComponent("Fixtures/SequenceGroupingMetadata/v2")
        let baselineBytes = try Data(contentsOf: v2.appendingPathComponent("baselines/behavior-v1.json"))
        XCTAssertEqual(SequenceProbeRun.sha256(baselineBytes), "0b3d5c6d09a35bc655633c5e1633def18bad2fee6eb5cf1b4f253e2991de2dbc")
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: baselineBytes) as? [String: Any])
        XCTAssertEqual(baseline["kind"] as? String, "observed-metadata-behavior")
        XCTAssertEqual(baseline["qualityAccepted"] as? Bool, false)
        let lineage = try XCTUnwrap(baseline["lineage"] as? [String: Any])
        let expectedRows = try XCTUnwrap(baseline["observations"] as? [[String: Any]])
        let (index, v1Bytes) = try SequenceFixtureHarness.loadIndex(root: v1)
        let v2Bytes = try Data(contentsOf: v2.appendingPathComponent("index.json"))
        XCTAssertEqual(lineage["fixtureIndexSHA256"] as? String, SequenceProbeRun.sha256(v1Bytes))
        XCTAssertEqual(lineage["metadataIndexSHA256"] as? String, SequenceProbeRun.sha256(v2Bytes))
        XCTAssertEqual(expectedRows.count, 24)
        var checked = 0
        for item in index.cases {
            let request = MetadataExperimentUnit(schemaVersion: 1, runID: "observed-behavior-regression", unitID: item.id,
                phase: "bootstrap", caseID: item.id, variant: nil, expectedPolicyFingerprint: nil,
                fixtureIndexSHA256: SequenceProbeRun.sha256(v1Bytes), metadataIndexSHA256: SequenceProbeRun.sha256(v2Bytes),
                sourceSnapshotSHA256: try XCTUnwrap(lineage["sourceSnapshotSHA256"] as? String),
                executableSHA256: try XCTUnwrap(lineage["executableSHA256"] as? String))
            let prepared = try MetadataExperimentHarness.prepare(request, v1: v1, v2: v2)
            XCTAssertTrue(prepared.native.sourcesUnchanged)
            XCTAssertEqual(prepared.snapshot.auditSeal, lineage["auditSeal"] as? String)
            // Finish all four classifications before loading this case's human truth.
            let candidates = try MetadataExperimentHarness.variants.filter { $0 != "dev4" }.map { name in
                let (association, rescue) = try MetadataExperimentHarness.policies(name)
                return (name, try SequenceMetadataEventPipeline.analyze(files: prepared.files,
                    manifest: prepared.native.manifest, metadata: prepared.snapshot,
                    associationPolicy: association, rescuePolicy: rescue))
            }
            let (truthBytes, _) = try SequenceFixtureHarness.verifiedSidecar(item.truthPath,
                expectedHash: item.truthSHA256, root: v1)
            let labels = try SequenceFixtureHarness.decode(ProbeLabels.self, data: truthBytes)
            for (name, result) in candidates {
                let matches = expectedRows.filter { $0["caseID"] as? String == item.id && $0["variant"] as? String == name }
                XCTAssertEqual(matches.count, 1)
                let expected = try XCTUnwrap(matches.first)
                let context = "Observed008 \(item.id)/\(name)"
                XCTAssertEqual(expected["assetCount"] as? Int, item.assetCount, context)
                XCTAssertEqual(expected["metadataSnapshotSHA256"] as? String, prepared.snapshot.fingerprint, context)
                XCTAssertEqual(expected["policyFingerprint"] as? String, try result.configuration.fingerprint, context)
                XCTAssertEqual(expected["resultSHA256"] as? String, try SequenceProbeRun.resultSHA256(result.result), context)
                XCTAssertEqual(expected["eventMapFingerprint"] as? String, result.map.fingerprint, context)
                XCTAssertEqual(expected["scopeSnapshotFingerprint"] as? String, result.map.scopeSnapshotFingerprint, context)
                XCTAssertEqual(expected["eventCount"] as? Int, result.map.events.count, context)
                XCTAssertEqual(expected["proposalCount"] as? Int, result.map.proposals.count, context)
                XCTAssertEqual(result.map.fileToEvent.count, item.assetCount, context)
                XCTAssertEqual(result.map.events.flatMap { $0.members.map(\.ordinal) }, Array(0..<item.assetCount), context)
                let analysis = ProbeAnalysis(manifest: result.manifest, result: result.result, observations: result.observations,
                    featuresAvailable: result.featuresAvailable, sources: prepared.native.sources,
                    hashBeforeSeconds: 0, readerAndEngineSeconds: 0, hashAfterSeconds: 0, analysisSeconds: 0,
                    engineManagedPeakEstimateBytes: result.managedPeakEstimateBytes, processPeakResidentBytes: nil)
                let policy = SpatialExperimentHarness.policy(caseID: item.id, configuration: result.configuration, trace: false)
                let evaluation = try ProbeEvaluator.evaluateMetadata(analysis: analysis, labels: labels, policy: policy,
                    configuration: try XCTUnwrap(result.configuration.metadataExperiment), files: prepared.files,
                    map: result.map, metadata: prepared.snapshot, confirmedPairs: [])
                let actualEvaluation = try XCTUnwrap(SpatialExperimentHarness.object(evaluation) as? [String: Any])
                let expectedEvaluation = try XCTUnwrap(expected["evaluation"] as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: actualEvaluation).isEqual(to: expectedEvaluation), context)
                XCTAssertEqual(evaluation.coverageCounts.values.reduce(0, +), item.assetCount, context)
                let statistics = try XCTUnwrap(result.metadataStatistics)
                let actualStatistics = try XCTUnwrap(SpatialExperimentHarness.object(statistics) as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: actualStatistics).isEqual(to: try XCTUnwrap(expected["metadataStatistics"] as? [String: Any])), context)
                let assumed = result.associationHypothesisAssumed
                let topAccepted = evaluation.acceptedWithinDeclaredSourceScope && !assumed && item.completeGroupTruth
                XCTAssertEqual(expected["associationHypothesisAssumed"] as? Bool, assumed, context)
                XCTAssertEqual(expected["topQualityAccepted"] as? Bool, topAccepted, context)
                XCTAssertEqual(expected["metricsMeaning"] as? String,
                    assumed ? "conditionalGroupingMetrics" : "strictGroupingMetricsUnderDeclaredSource", context)
                XCTAssertTrue(expected["pairPrecision"] is NSNull, context)
                XCTAssertEqual(expected["completeGroupTruth"] as? Bool, item.completeGroupTruth, context)
                XCTAssertEqual(expected["unknownTruthAssetIDs"] as? [String], item.unknownAssetIDs, context)
                // Algorithm-unknown coverage is separate from the two unlabeled DJI0188 files.
                if item.id == "dji187-context376" {
                    XCTAssertEqual(item.unknownAssetIDs.count, 2, context)
                    XCTAssertEqual(evaluation.unknownCount, assumed ? 0 : 188, context)
                    XCTAssertFalse(topAccepted, context)
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 24)
    }
    func testOldSpatialVariantsRetainAllTwelveNativeResultSeals() throws {
        let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let summary=try JSONSerialization.jsonObject(with:Data(contentsOf:repository.appendingPathComponent("docs/diagnostics/spatial-cv-v1-summary.json"))) as? [String:Any]
        let quality=try XCTUnwrap(summary?["quality"] as? [[String:Any]])
        let root=try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/SequenceGrouping/v1")
        let (index,_)=try SequenceFixtureHarness.loadIndex(root:root)
        for name in ["bridgeVetoOnly","localRescueAndBridgeVeto"] {
            let config=try SpatialExperimentHarness.configuration(name);XCTAssertNil(config.metadataExperiment)
            for item in index.cases {
                let (bytes,url)=try SequenceFixtureHarness.verifiedSidecar(item.manifestPath,expectedHash:item.manifestSHA256,root:root)
                let manifest=try SequenceFixtureHarness.decode(ProbeManifest.self,data:bytes)
                let policy=SpatialExperimentHarness.policy(caseID:item.id,configuration:config,trace:false)
                let native=try SequenceProbeRun.analyze(manifest:manifest,root:url.deletingLastPathComponent(),policy:policy)
                let expected=try XCTUnwrap(quality.first{ $0["caseID"] as? String==item.id && $0["variant"] as? String==name }?["resultSHA256"] as? String)
                XCTAssertTrue(native.sourcesUnchanged);XCTAssertEqual(try SequenceProbeRun.resultSHA256(native.result),expected,"Frozen007 control \(item.id)/\(name)")
            }
        }
    }
    func testAdditiveSupplementLoadsAll1265WithoutChangingCurrentRepresentation() throws {
        let resources=try XCTUnwrap(Bundle.module.resourceURL),v1=resources.appendingPathComponent("Fixtures/SequenceGrouping/v1"),v2=resources.appendingPathComponent("Fixtures/SequenceGroupingMetadata/v2")
        let bytes=try Data(contentsOf:v2.appendingPathComponent("index.json"))
        let index=try SequenceMetadataEvidenceLoader.loadIndex(at:v2.appendingPathComponent("index.json"),expectedSHA256:SequenceMetadataEvidenceLoader.sha256(bytes))
        let (native,_)=try SequenceFixtureHarness.loadIndex(root:v1);var total=0
        for item in index.cases {
            let original=try XCTUnwrap(native.cases.first{$0.id==item.id})
            let url=try SequenceFixtureFiles.resolve(original.manifestPath,root:v1)
            let snapshot=try SequenceMetadataEvidenceLoader.loadCase(item,index:index,metadataRoot:v2,v1Root:v1,v1ManifestURL:url)
            XCTAssertEqual(snapshot.fingerprint,item.sha256);total+=snapshot.files.count
            for file in snapshot.files {
                XCTAssertNotEqual(file.originalSHA256,file.currentSHA256)
                XCTAssertTrue(file.originalCapture.time.isConsistent)
                XCTAssertTrue(Set(file.opaqueCandidates.keys).isSubset(of:SequenceMetadataEvidenceLoader.privateFields))
                XCTAssertEqual(file.originalCapture.time.offsetMinutes,file.originalCapture.cameraMake=="SONY" ? 480:nil)
            }
        }
        XCTAssertEqual(total,1265)
    }
}
