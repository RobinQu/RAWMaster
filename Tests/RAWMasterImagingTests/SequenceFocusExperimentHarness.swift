import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

struct FocusExperimentUnit: Codable {
    let schemaVersion: Int
    let runID, unitID, phase, caseID: String
    let variant, expectedPolicyFingerprint: String?
    let fixtureIndexSHA256, metadataIndexSHA256, focusIndexSHA256, sourceSnapshotSHA256, executableSHA256: String
}
private final class FocusExperimentTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SequenceTraceEvent] = []
    private var overflow = false
    func record(_ value: SequenceTraceEvent) {
        guard value.pauseBridge != nil else { return }
        lock.lock(); defer { lock.unlock() }
        guard values.count < 4096 else { overflow = true; return }
        values.append(value)
    }
    func snapshot() throws -> [SequenceTraceEvent] {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw SequenceFixtureError.invalid("Focus hook trace observer cap exceeded") }
        return values
    }
}
enum SequenceFocusExperimentHarness {
    static let variants = ["008B-strict", "008B-assumed", "009-strict", "009-assumed"]
    static func policy(_ name: String) throws -> (SequenceAssociationPolicy, Bool) {
        guard variants.contains(name) else { throw SequenceFixtureError.invalid("Unknown focus experiment variant") }
        return (name.hasSuffix("-assumed") ? .assumeCorroborated : .strict, name.hasPrefix("009-"))
    }
    static func request(_ value: FocusExperimentUnit) -> MetadataExperimentUnit {
        MetadataExperimentUnit(schemaVersion: value.schemaVersion, runID: value.runID, unitID: value.unitID,
            phase: "bootstrap", caseID: value.caseID, variant: nil, expectedPolicyFingerprint: nil,
            fixtureIndexSHA256: value.fixtureIndexSHA256, metadataIndexSHA256: value.metadataIndexSHA256,
            sourceSnapshotSHA256: value.sourceSnapshotSHA256, executableSHA256: value.executableSHA256)
    }
    static func focus(_ value: FocusExperimentUnit, prepared: MetadataExperimentHarness.Prepared, root: URL) throws -> SequenceFocusSnapshot {
        let index = try SequenceFocusEvidenceLoader.loadIndex(at: root.appendingPathComponent("index.json"), expectedSHA256: value.focusIndexSHA256)
        guard let item = index.cases.first(where: { $0.id == value.caseID }) else { throw SequenceFixtureError.invalid("Missing full focus case") }
        return try SequenceFocusEvidenceLoader.loadCase(item, index: index, focusRoot: root, metadata: prepared.snapshot, manifest: prepared.native.manifest)
    }
    static func configuration(_ name: String, prepared: MetadataExperimentHarness.Prepared, focus: SequenceFocusSnapshot) throws -> SequenceDetectorConfiguration {
        let (association, enabled) = try policy(name)
        let map = try SequenceCaptureEvents.make(files: prepared.files, manifest: prepared.native.manifest,
            metadata: prepared.snapshot, confirmedPairs: [], policy: association)
        var result = SequenceDetectorConfiguration()
        result.metadataExperiment = SequenceMetadataExperimentConfiguration(associationPolicy: association, rescuePolicy: .allowShortRestart,
            auditSeal: prepared.snapshot.auditSeal, snapshotFingerprint: prepared.snapshot.fingerprint, eventMapFingerprint: map.fingerprint)
        if enabled {
            result.pauseBridgeExperiment = SequencePauseBridgeConfiguration(policy: .focusRectAndCohortSeparation,
                focusAuditSeal: focus.focusAuditSeal, focusSnapshotFingerprint: try focus.boundFingerprint(manifest: prepared.native.manifest, metadata: prepared.snapshot))
        }
        try result.validate()
        return result
    }
    static func bootstrap(_ value: FocusExperimentUnit, v1: URL, v2: URL, focusRoot: URL) throws -> [String: Any] {
        guard value.phase == "bootstrap" else { throw SequenceFixtureError.invalid("Focus bootstrap identity") }
        let prepared = try MetadataExperimentHarness.prepare(request(value), v1: v1, v2: v2)
        let snapshot = try focus(value, prepared: prepared, root: focusRoot)
        let records = try variants.map { name -> [String: Any] in
            let config = try configuration(name, prepared: prepared, focus: snapshot)
            return ["variant": name, "policyFingerprint": try config.fingerprint, "configuration": try SpatialExperimentHarness.object(config)]
        }
        return ["schemaVersion": 1, "kind": "focus-experiment-descriptor", "identity": try SpatialExperimentHarness.object(value),
            "variants": records, "labelsRead": false, "metadataSnapshotSHA256": prepared.snapshot.fingerprint,
            "focusSnapshotSHA256": snapshot.fingerprint, "focusAuditSeal": snapshot.focusAuditSeal]
    }
    static func run(_ value: FocusExperimentUnit, v1: URL, v2: URL, focusRoot: URL, output: URL) throws -> [String: Any] {
        guard value.phase == "quality", let variant = value.variant else { throw SequenceFixtureError.invalid("Focus quality identity") }
        let (association, enabled) = try policy(variant), started = ProcessInfo.processInfo.systemUptime
        let prepared = try MetadataExperimentHarness.prepare(request(value), v1: v1, v2: v2)
        let snapshot = enabled ? try focus(value, prepared: prepared, root: focusRoot) : nil
        let collector = FocusExperimentTrace()
        let projected = try SequenceMetadataEventPipeline.analyze(files: prepared.files, manifest: prepared.native.manifest,
            metadata: prepared.snapshot, associationPolicy: association, rescuePolicy: .allowShortRestart,
            focusSnapshot: snapshot, pauseBridgePolicy: enabled ? .focusRectAndCohortSeparation : nil, trace: { collector.record($0) })
        let config = projected.configuration
        guard try config.fingerprint == value.expectedPolicyFingerprint else { throw SequenceFixtureError.invalid("Effective frozen focus policy changed") }
        let analysis = ProbeAnalysis(manifest: projected.manifest, result: projected.result, observations: projected.observations,
            featuresAvailable: projected.featuresAvailable, sources: prepared.native.sources,
            hashBeforeSeconds: prepared.native.hashBeforeSeconds, readerAndEngineSeconds: prepared.native.readerAndEngineSeconds + projected.analysisSeconds,
            hashAfterSeconds: prepared.native.hashAfterSeconds, analysisSeconds: prepared.native.analysisSeconds + projected.analysisSeconds,
            engineManagedPeakEstimateBytes: projected.managedPeakEstimateBytes, processPeakResidentBytes: MetadataExperimentHarness.processPeakResidentBytes())
        let hooks = try collector.snapshot()
        let sealed: [String: Any] = ["analysis": try SpatialExperimentHarness.object(analysis),
            "eventMap": try SpatialExperimentHarness.object(projected.map), "configuration": try SpatialExperimentHarness.object(config),
            "metadataSnapshotSHA256": prepared.snapshot.fingerprint, "focusSnapshot": try snapshot.map { try SpatialExperimentHarness.object($0) } ?? NSNull(),
            "pauseBridgeStatistics": try projected.pauseBridgeStatistics.map { try SpatialExperimentHarness.object($0) } ?? NSNull(),
            "pauseBridgeHookEvents": try SpatialExperimentHarness.object(hooks)]
        let bytes = try JSONSerialization.data(withJSONObject: sealed, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= 16 * 1024 * 1024 else { throw SequenceFixtureError.invalid("Focus analysis artifact budget") }
        let sealedURL = output.appendingPathExtension("analysis.json")
        try FileManager.default.createDirectory(at: sealedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sealedURL, options: .withoutOverwriting) // Before human labels are opened.
        let (truthBytes, _) = try SequenceFixtureHarness.verifiedSidecar(prepared.item.truthPath, expectedHash: prepared.item.truthSHA256, root: v1)
        let labels = try SequenceFixtureHarness.decode(ProbeLabels.self, data: truthBytes)
        let evaluation = try ProbeEvaluator.evaluateMetadata(analysis: analysis, labels: labels,
            policy: SpatialExperimentHarness.policy(caseID: value.caseID, configuration: config, trace: false),
            configuration: try requiredMetadata(config.metadataExperiment), files: prepared.files,
            map: projected.map, metadata: prepared.snapshot, confirmedPairs: [], focusSnapshot: snapshot)
        let assumed = projected.associationHypothesisAssumed
        let topAccepted = evaluation.acceptedWithinDeclaredSourceScope && !assumed && prepared.item.completeGroupTruth
        let limitations = evaluation.failures.filter { $0.contains("support") || $0.contains("acceptanceIncomplete") || $0 == "acceptanceNotConfigured" || $0 == "source-declaration-contradicted" }
            + (prepared.item.completeGroupTruth ? [] : ["full-group-extent-not-labeled; DJI0188 remains unknown"])
        let behavior = SequenceFixtureCaseBehavior(id: prepared.item.id, assetCount: prepared.item.assetCount,
            manifestSHA256: prepared.item.manifestSHA256, metadataSHA256: prepared.item.metadataSHA256, truthSHA256: prepared.item.truthSHA256,
            policyFingerprint: try config.fingerprint, result: analysis.result, evaluation: evaluation,
            completeGroupTruth: prepared.item.completeGroupTruth, unknownAssetIDs: prepared.item.unknownAssetIDs,
            integrityValidated: true, qualityAccepted: topAccepted, evidenceLimitations: limitations,
            classificationFailures: evaluation.failures.filter { !limitations.contains($0) })
        if !enabled {
            let observed = try JSONSerialization.jsonObject(with: Data(contentsOf: v2.appendingPathComponent("baselines/behavior-v1.json"))) as? [String: Any]
            let rows = observed?["observations"] as? [[String: Any]]
            let oldName = association == .strict ? "strict-shortRestart" : "assumed-shortRestart"
            guard let expected = rows?.first(where: { $0["caseID"] as? String == value.caseID && $0["variant"] as? String == oldName }),
                  expected["resultSHA256"] as? String == (try SequenceProbeRun.resultSHA256(analysis.result)),
                  expected["policyFingerprint"] as? String == (try config.fingerprint), expected["eventMapFingerprint"] as? String == projected.map.fingerprint else {
                throw SequenceFixtureError.invalid("008B observed control changed")
            }
        }
        return ["schemaVersion": 1, "kind": "focus-quality-unit", "identity": try SpatialExperimentHarness.object(value),
            "integrityValidated": true, "strictValidated": true, "analysisSealedBeforeLabels": true,
            "analysisPath": sealedURL.path, "analysisSealSHA256": SequenceProbeRun.sha256(bytes),
            "resultSHA256": try SequenceProbeRun.resultSHA256(analysis.result), "behavior": try SpatialExperimentHarness.object(behavior),
            "configuration": try SpatialExperimentHarness.object(config), "eventMap": try SpatialExperimentHarness.object(projected.map),
            "focusConsumed": enabled, "focusSnapshotSHA256": snapshot?.fingerprint as Any? ?? NSNull(),
            "focusAuditSeal": snapshot?.focusAuditSeal as Any? ?? NSNull(), "metadataSnapshotSHA256": prepared.snapshot.fingerprint,
            "pauseBridgeStatistics": try projected.pauseBridgeStatistics.map { try SpatialExperimentHarness.object($0) } ?? NSNull(),
            "metadataStatistics": try projected.metadataStatistics.map { try SpatialExperimentHarness.object($0) } ?? NSNull(),
            "pauseBridgeHookEvents": try SpatialExperimentHarness.object(hooks),
            "hookTraceBoundary": "Bounded emitted hook subset; underlying generic trace summary is unavailable, so absence is not causal evidence",
            "associationHypothesisAssumed": assumed, "topQualityAccepted": topAccepted,
            "metricsMeaning": assumed ? "conditionalGroupingMetrics" : "strictGroupingMetricsUnderDeclaredSource", "pairPrecision": NSNull(),
            "wholeUnitSeconds": ProcessInfo.processInfo.systemUptime - started, "processPeakResidentBytes": MetadataExperimentHarness.processPeakResidentBytes() as Any? ?? NSNull(),
            "engineManagedPeakEstimateBytes": analysis.engineManagedPeakEstimateBytes,
            "resourceBoundary": "Single process includes native JPEG preparation/control classification, optional event/focus pipeline, sealing and labels; managed estimate excludes caller/frameworks; no repeat benchmark, original RAW decode, GUI or P50 claim"]
    }
    private static func requiredMetadata(_ value: SequenceMetadataExperimentConfiguration?) throws -> SequenceMetadataExperimentConfiguration {
        guard let value else { throw SequenceFixtureError.invalid("Missing event configuration") }
        return value
    }
}
