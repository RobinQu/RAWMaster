import XCTest
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class ProbeEvaluationTests: XCTestCase {
    struct Fixture { let analysis: ProbeAnalysis; let labels: ProbeLabels; let policy: ProbePolicy }
    func fixture(barrier: SequenceReason? = nil, allUnknown: Bool = false, predicted: Bool = true, kind: SequenceKind = .burst, declared: Bool = true, memberCount: Int = 3, contextFacts: [(make: String?, model: String?)] = [], contextBarriers: [Int: SequenceReason] = [:], coverageOnlyMismatches: Set<Int> = [], observationOnlyMismatch: Bool = false) throws -> Fixture {
        let blob = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("synthetic stamp only".utf8).write(to: blob); defer { try? FileManager.default.removeItem(at: blob) }
        let stamp = ProbeStamp(try SequenceFileCredential.capture(at: blob))
        let hash = String(repeating: "a", count: 64), config = SequenceDetectorConfiguration()
        let prefixCount = contextFacts.count
        let count = prefixCount + memberCount + 2
        let firstMember = prefixCount + 1, lastMember = prefixCount + memberCount
        func invalidReason(_ ordinal: Int) -> SequenceReason? {
            if allUnknown { return .cameraIdentityUnknown }
            if ordinal < prefixCount { return contextBarriers[ordinal] }
            return ordinal == prefixCount ? barrier : nil
        }
        let initial = try SequenceInputManifest(scopeID: "scope", sessionID: "session", orderVersion: SequenceBaseOrder.version,
            entries: (0..<count).map { SequenceManifestEntry(assetID: "f\($0)", ordinal: $0, contentHash: hash) })
        let manifest = try SequenceInputManifest(scopeID: "scope", sessionID: "session", orderVersion: SequenceBaseOrder.version,
            entries: initial.entries.map { entry in SequenceManifestEntry(assetID: entry.assetID, ordinal: entry.ordinal, contentHash: hash,
                camera: invalidReason(entry.ordinal) == .cameraIdentityUnknown ? .unknown : .manifestAssertion(id: "whole-scope", revision: 0, manifestFingerprint: initial.contentFingerprint)) })
        let token = try SequenceAnalysisToken.make(manifest: manifest, versions: config.versions(order: manifest.orderVersion), policyFingerprint: config.fingerprint)
        let clock = SequenceClockPartition(id: "one-clock", basis: .localCivil, derivationVersion: "synthetic-v1")
        let observations = manifest.entries.map { entry in
            let invalid = invalidReason(entry.ordinal)
            let evidence = SequenceCaptureEvidence(assetID: entry.assetID, contentHash: hash, extractorVersion: token.versions.extractor, evidenceRevision: 0,
                time: SequenceTimestampParser.parse(original: invalid == .invalidTimestamp ? nil : String(format: "2026:10:01 12:%02d:%02d", entry.ordinal / 60, entry.ordinal % 60), subseconds: "100", offset: nil),
                cameraMake: entry.ordinal < prefixCount ? contextFacts[entry.ordinal].make : "Sony",
                cameraModel: entry.ordinal < prefixCount ? contextFacts[entry.ordinal].model : "ILCE-1M2", orientation: 1)
            return SequenceAssetInput(entry: entry, evidence: invalid == .unreadable ? nil : evidence, clock: invalid == nil ? clock : nil, barrier: invalid)
        }
        let result = SequenceAnalysisResult(token: token,
            ranges: predicted && !allUnknown ? [SequenceDetectedRange(range: try SequenceOrdinalRange(first: firstMember, last: lastMember), kind: kind,
                cameraPartitionID: manifest.entries[firstMember].camera.partitionID(manifestFingerprint: manifest.contentFingerprint)!, clockPartitionID: clock.id)] : [],
            coverage: try (0..<count).map { ordinal in
                let invalid = invalidReason(ordinal)
                let isDetected = predicted && !allUnknown && (firstMember...lastMember).contains(ordinal)
                let state: SequenceCoverageState
                if invalid == .unreadable { state = .unreadable }
                else if invalid == .incomplete { state = .incomplete }
                else { state = isDetected ? .complete : .insufficient }
                let reasons: [SequenceReason]
                if coverageOnlyMismatches.contains(ordinal) { reasons = [.assertionMismatch] }
                else if observationOnlyMismatch && invalid == .assertionMismatch { reasons = [.noSequenceSupport] }
                else { reasons = invalid.map { [$0] } ?? (isDetected ? [] : [.noSequenceSupport]) }
                return SequenceCoverageRange(range: try SequenceOrdinalRange(first: ordinal, last: ordinal), state: state, reasons: reasons)
            })
        let sources = manifest.entries.map { entry -> ProbeSourceRecord in
            var record = ProbeSourceRecord(assetID: entry.assetID, relativePath: "\(entry.ordinal).bin")
            record.beforeSHA256 = hash; record.afterSHA256 = hash; record.before = stamp; record.after = stamp
            return record
        }
        let analysis = ProbeAnalysis(manifest: manifest, result: result, observations: observations, featuresAvailable: (0..<count).map { invalidReason($0) == nil }, sources: sources,
            hashBeforeSeconds: 0, readerAndEngineSeconds: 0, hashAfterSeconds: 0, analysisSeconds: 0, engineManagedPeakEstimateBytes: 0, processPeakResidentBytes: nil)
        let policy = ProbePolicy(schemaVersion: 2, detector: config, sourceAssertion: ProbeSourceAssertion(id: "whole-scope", revision: 0, declaredByUser: declared, provenance: "synthetic whole manifest incl negatives"),
            acceptance: ProbeAcceptance(minimumPositivePairs: memberCount - 1, minimumRecall: 1, minimumTypedCoverage: 1, minimumExactGroupFraction: 1, minimumPrecision: 0.95, minimumNegativePairs: 2), maximumDurationSeconds: 60, deterministicSeed: 0)
        let labels = ProbeLabels(schemaVersion: 1, role: "synthetic", groups: [.init(id: "truth", kind: .burst, assetIDs: (firstMember...lastMember).map { "f\($0)" })], negativePairs: [.init(from: "f\(prefixCount)", to: "f\(firstMember)"), .init(from: "f\(lastMember)", to: "f\(lastMember + 1)")])
        return Fixture(analysis: analysis, labels: labels, policy: policy)
    }
    func testCompletePositiveAndDecidableStandaloneEdgesCanPass() throws {
        let f = try fixture(), result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
        XCTAssertEqual(result.truePositive, 2); XCTAssertEqual(result.trueNegative, 2)
        XCTAssertEqual(result.falsePositive, 0); XCTAssertEqual(result.falseNegative, 0)
        XCTAssertEqual(result.unknownNegativePairs, 0); XCTAssertTrue(result.acceptedWithinDeclaredSourceScope)
        XCTAssertEqual(result.exactGroupFraction, 1)
    }
    func testPerfectPositiveCannotHideUnknownNegativeEdges() throws {
        for reason in [SequenceReason.unreadable, .incomplete, .cameraIdentityUnknown, .invalidTimestamp] {
            let f = try fixture(barrier: reason), result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
            XCTAssertEqual(result.truePositive, 2); XCTAssertEqual(result.exactGroupFraction, 1)
            XCTAssertEqual(result.unknownNegativePairs, 1); XCTAssertEqual(result.trueNegative, 1)
            XCTAssertFalse(result.qualityUnderAssumption); XCTAssertFalse(result.acceptedWithinDeclaredSourceScope)
        }
    }
    func testAllUnknownAndAllFlatCannotPass() throws {
        for unknown in [true, false] {
            let f = try fixture(allUnknown: unknown, predicted: false), result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
            XCTAssertEqual(result.falseNegative, 2); XCTAssertNil(result.precision)
            XCTAssertEqual(result.recall, 0); XCTAssertFalse(result.qualityUnderAssumption)
            if unknown { XCTAssertEqual(result.trueNegative, 0); XCTAssertEqual(result.unknownPositivePairs, 2) }
        }
    }
    func testGenericMembershipDoesNotCountAsTypedRecovery() throws {
        let f = try fixture(kind: .sequence), result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
        XCTAssertTrue(result.groups[0].exactMembership); XCTAssertFalse(result.groups[0].exactMembershipAndType)
        XCTAssertEqual(result.typedCoverage, 0); XCTAssertFalse(result.qualityUnderAssumption)
    }
    func testAbsentUserDeclarationRemainsResearchOnly() throws {
        let f = try fixture(declared: false), result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
        XCTAssertTrue(result.qualityUnderAssumption); XCTAssertFalse(result.sourceDeclaredByUser); XCTAssertFalse(result.acceptedWithinDeclaredSourceScope)
    }
    func testMetricsUseOnlyFullManifestAdjacentPositiveEdges() throws {
        for memberCount in [4, 123, 427] {
            let f = try fixture(memberCount: memberCount)
            let result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
            XCTAssertEqual(result.truePositive, memberCount - 1)
            XCTAssertEqual(result.falseNegative, 0)
            XCTAssertEqual(result.groups.first?.exactMembershipAndType, true)
            XCTAssertTrue(result.acceptedWithinDeclaredSourceScope)
        }
    }
    func testLabelsCannotHopAcrossInterveningOrMissingManifestRows() throws {
        let f = try fixture(memberCount: 4)
        for ids in [["f1", "f3"], ["f1", "f2", "f4"]] {
            let labels = ProbeLabels(schemaVersion: 1, role: "synthetic interleaving", groups: [.init(id: "truth", kind: .burst, assetIDs: ids)], negativePairs: f.labels.negativePairs)
            let result = try ProbeEvaluator.evaluate(f.analysis, labels: labels, policy: f.policy)
            XCTAssertEqual(result.truePositive, ids.count == 2 ? 0 : 1)
            XCTAssertEqual(result.falseNegative, 0)
            XCTAssertFalse(result.acceptedWithinDeclaredSourceScope)
        }
        let missing = ProbeLabels(schemaVersion: 1, role: "missing input", groups: [.init(id: "truth", kind: .burst, assetIDs: ["f1", "absent", "f2"])], negativePairs: f.labels.negativePairs)
        XCTAssertThrowsError(try ProbeEvaluator.evaluate(f.analysis, labels: missing, policy: f.policy))
        let nonadjacentNegative = ProbeLabels(schemaVersion: 1, role: "nonadjacent negative", groups: f.labels.groups, negativePairs: [.init(from: "f0", to: "f4")])
        XCTAssertThrowsError(try ProbeEvaluator.evaluate(f.analysis, labels: nonadjacentNegative, policy: f.policy))
    }
    func testUnlabeledCameraCounterevidenceBlocksPerfectLabeledResults() throws {
        let cases: [[(make: String?, model: String?)]] = [
            [("Leica", nil)], [(nil, "different-model")], [("Sony", "different-model"), (nil, nil)]
        ]
        for facts in cases {
            // The final case crosses an unreadable context barrier before the well-labeled region.
            let barriers: [Int: SequenceReason] = facts.count > 1 ? [1: .unreadable] : [:]
            let f = try fixture(contextFacts: facts, contextBarriers: barriers)
            let result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
            XCTAssertEqual(result.truePositive, 2); XCTAssertEqual(result.trueNegative, 2)
            XCTAssertEqual(result.unknownNegativePairs, 0); XCTAssertEqual(result.exactGroupFraction, 1)
            XCTAssertFalse(result.qualityUnderAssumption); XCTAssertFalse(result.acceptedWithinDeclaredSourceScope)
            XCTAssertTrue(result.failures.contains("source-declaration-contradicted"))
            XCTAssertFalse(result.sourceDeclarationContradictions.isEmpty)
            XCTAssertFalse(result.nativeDeviceIdentityVerified)
        }
    }
    func testUnknownUnlabeledContextAndNormalizedSameModelAreNotContradictions() throws {
        let cases: [[(make: String?, model: String?)]] = [
            [(nil, nil)], [(" \n", " \t")], [("  SONY\n", " ilce-1m2 ")], [(nil, nil), ("Sony", nil)]
        ]
        for facts in cases {
            let barriers: [Int: SequenceReason] = facts.count > 1 ? [0: .unreadable] : [:]
            let f = try fixture(contextFacts: facts, contextBarriers: barriers)
            let result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
            XCTAssertTrue(result.sourceDeclarationContradictions.isEmpty)
            XCTAssertTrue(result.qualityUnderAssumption); XCTAssertTrue(result.acceptedWithinDeclaredSourceScope)
            XCTAssertEqual(result.knownCameraMakes, ["sony"]); XCTAssertEqual(result.knownCameraModels, ["ilce-1m2"])
            XCTAssertFalse(result.nativeDeviceIdentityVerified)
        }
    }
    func testExplicitAssertionMismatchInUnlabeledObservationOrCoverageBlocksAcceptance() throws {
        for coverageOnly in [true, false] {
            let f = try fixture(contextFacts: [(nil, nil)], contextBarriers: coverageOnly ? [:] : [0: .assertionMismatch],
                coverageOnlyMismatches: coverageOnly ? [0] : [], observationOnlyMismatch: !coverageOnly)
            let result = try ProbeEvaluator.evaluate(f.analysis, labels: f.labels, policy: f.policy)
            XCTAssertEqual(result.truePositive, 2); XCTAssertEqual(result.trueNegative, 2)
            XCTAssertEqual(result.exactGroupFraction, 1); XCTAssertEqual(result.unknownNegativePairs, 0)
            XCTAssertEqual(result.sourceAssertionMismatchOrdinals, [0])
            XCTAssertTrue(result.sourceDeclarationContradictions.contains("explicit-assertion-mismatch"))
            XCTAssertFalse(result.qualityUnderAssumption); XCTAssertFalse(result.acceptedWithinDeclaredSourceScope)
        }
    }
    func testLabelsOnlyLoadedAfterAnalysisExistsAndSealIsDeterministic() throws {
        let f = try fixture()
        var order: [String] = []
        let first = try SequenceProbeRun.sealThenEvaluate(f.analysis, policy: f.policy, onSealed: { _ in order.append("sealed") }) { order.append("labels"); return f.labels }
        XCTAssertEqual(order, ["sealed", "labels"])
        let second = try SequenceProbeRun.sealThenEvaluate(f.analysis, policy: f.policy) { f.labels }
        XCTAssertEqual(first.0, second.0); XCTAssertEqual(first.0.count, 64)
        let invalid = ProbeLabels(schemaVersion: 1, role: "synthetic", groups: f.labels.groups, negativePairs: [.init(from: "not-in-manifest", to: "f1")])
        XCTAssertThrowsError(try ProbeEvaluator.evaluate(f.analysis, labels: invalid, policy: f.policy))
    }
}
