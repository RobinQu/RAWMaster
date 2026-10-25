import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

/// Additive evaluation only. Classifiers receive current JPEG pixels and bound historical metadata,
/// never human annotations. The original 1,265-file fixtures and frozen controls are unchanged.
enum SequenceAcceptedAnnotationHarness {
    static let candidateRawValue = "focus-reset-and-cohort-separation-v2"
    static let acceptedSHA256 = "ba193b709d4e7606e318a2fd780f03ddfb725678dc628f6d82a6bca1f9d32381"
    struct Input {
        let manifest: SequenceInputManifest
        let files: [SequenceCaptureFileInput]
        let metadata: SequenceMetadataSnapshot
        let focus: SequenceFocusSnapshot
        let sourceOrdinals: [Int]
    }
    static func input(_ prepared: MetadataExperimentHarness.Prepared, focus: SequenceFocusSnapshot) throws -> Input {
        if prepared.item.id != "dji187-context376" {
            return Input(manifest: prepared.native.manifest, files: prepared.files, metadata: prepared.snapshot,
                         focus: focus, sourceOrdinals: Array(prepared.files.indices))
        }
        // Select the original JPEG representation, not the .jpg fixture suffix (all fixtures are JPEGs).
        let ordinals = prepared.files.indices.filter { prepared.files[$0].metadata.originalFormat == .jpeg }
        guard ordinals.count == 188, ordinals == Array(stride(from: 1, through: 375, by: 2)) else {
            throw SequenceFixtureError.invalid("DJI JPEG projection identity changed")
        }
        let old = prepared.native.manifest
        let unbound = ordinals.enumerated().map { index, source in
            let entry = old.entries[source]
            return SequenceManifestEntry(assetID: entry.assetID, ordinal: index, contentHash: entry.contentHash,
                                         evidenceRevision: entry.evidenceRevision, barrier: entry.barrier)
        }
        let base = try SequenceInputManifest(scopeID: old.scopeID + "/jpeg-only-v1", sessionID: old.sessionID,
                                            orderVersion: old.orderVersion + "+jpeg-only-v1", entries: unbound)
        let entries = ordinals.enumerated().map { index, source -> SequenceManifestEntry in
            let entry = old.entries[source]
            let camera: SequenceCameraEvidence
            switch entry.camera {
            case .unknown: camera = .unknown
            case .verifiedDevice: camera = entry.camera
            case .manifestAssertion(let id, let revision, let fingerprint):
                camera = fingerprint == old.contentFingerprint
                    ? .manifestAssertion(id: "jpeg-subset:" + id, revision: revision, manifestFingerprint: base.contentFingerprint)
                    : .unknown
            }
            return SequenceManifestEntry(assetID: entry.assetID, ordinal: index, contentHash: entry.contentHash,
                                         evidenceRevision: entry.evidenceRevision, camera: camera, barrier: entry.barrier)
        }
        let manifest = try SequenceInputManifest(scopeID: base.scopeID, sessionID: base.sessionID,
                                                orderVersion: base.orderVersion, entries: entries)
        let metadataFiles = ordinals.map { prepared.snapshot.files[$0] }
        // New receipt fingerprints explicitly bind the parent seal and the selected ordered contents.
        struct Projection<T: Encodable>: Encodable {
            let version = "accepted-jpeg-projection-v1"
            let parent: String
            let sourceOrdinals: [Int]
            let files: T
        }
        let metadata = SequenceMetadataSnapshot(auditSeal: prepared.snapshot.auditSeal,
            fingerprint: try SequenceFingerprint.digest(Projection(parent: prepared.snapshot.fingerprint, sourceOrdinals: ordinals, files: metadataFiles)),
            v1IndexSHA256: prepared.snapshot.v1IndexSHA256, caseManifestSHA256: try SequenceFingerprint.digest(manifest), files: metadataFiles)
        let focusFiles = ordinals.enumerated().map { index, source -> SequenceFocusFileEvidence in
            let file = focus.files[source]
            return SequenceFocusFileEvidence(assetID: file.assetID, currentSHA256: file.currentSHA256,
                originalSHA256: file.originalSHA256, ordinal: index, state: file.state, fieldStates: file.fieldStates,
                resolvedCodes: file.resolvedCodes, resolvedTuples: file.resolvedTuples)
        }
        let projectedFocus = SequenceFocusSnapshot(focusAuditSeal: focus.focusAuditSeal,
            fingerprint: try SequenceFingerprint.digest(Projection(parent: focus.fingerprint, sourceOrdinals: ordinals, files: focusFiles)),
            metadataSnapshotFingerprint: metadata.fingerprint, files: focusFiles)
        let files = ordinals.enumerated().map { index, source -> SequenceCaptureFileInput in
            let file = prepared.files[source]
            return SequenceCaptureFileInput(entry: entries[index], currentEvidence: file.currentEvidence, metadata: file.metadata,
                                            contentVersion: file.contentVersion, feature: file.feature, readBarrier: file.readBarrier)
        }
        try projectedFocus.validateBindings(manifest: manifest, metadata: metadata)
        return Input(manifest: manifest, files: files, metadata: metadata, focus: projectedFocus, sourceOrdinals: ordinals)
    }
    static func predict(resources: URL, repeats: Int) throws -> [String: Any] {
        guard (1...10).contains(repeats), let candidate = SequencePauseBridgePolicy(rawValue: candidateRawValue),
              candidate != .focusRectAndCohortSeparation else { throw SequenceFixtureError.invalid("Candidate policy is absent or aliases frozen v1") }
        let v1 = resources.appendingPathComponent("Fixtures/SequenceGrouping/v1")
        let v2 = resources.appendingPathComponent("Fixtures/SequenceGroupingMetadata/v2")
        let focusRoot = resources.appendingPathComponent("Fixtures/SequenceGroupingFocus/v1")
        let (index, indexBytes) = try SequenceFixtureHarness.loadIndex(root: v1)
        let metadataSHA = SequenceProbeRun.sha256(try Data(contentsOf: v2.appendingPathComponent("index.json")))
        let focusSHA = SequenceProbeRun.sha256(try Data(contentsOf: focusRoot.appendingPathComponent("index.json")))
        let placeholder = String(repeating: "0", count: 64)
        var cases: [[String: Any]] = []
        for item in index.cases {
            let started = ProcessInfo.processInfo.systemUptime
            let request = FocusExperimentUnit(schemaVersion: 1, runID: "accepted-annotation-regression", unitID: item.id,
                phase: "bootstrap", caseID: item.id, variant: nil, expectedPolicyFingerprint: nil,
                fixtureIndexSHA256: SequenceProbeRun.sha256(indexBytes), metadataIndexSHA256: metadataSHA,
                focusIndexSHA256: focusSHA, sourceSnapshotSHA256: placeholder, executableSHA256: placeholder)
            let prepared = try MetadataExperimentHarness.prepare(SequenceFocusExperimentHarness.request(request), v1: v1, v2: v2)
            let focus = try SequenceFocusExperimentHarness.focus(request, prepared: prepared, root: focusRoot)
            let selected = try input(prepared, focus: focus)
            let preparationSeconds = ProcessInfo.processInfo.systemUptime - started
            var variants: [[String: Any]] = []
            for (name, policy) in [("legacy", SequencePauseBridgePolicy.focusRectAndCohortSeparation), ("candidate", candidate)] {
                for association in [SequenceAssociationPolicy.strict, .assumeCorroborated] {
                    var samples: [Double] = [], first: SequenceMetadataEventAnalysis?
                    for _ in 0..<repeats {
                        let analysis = try SequenceMetadataEventPipeline.analyze(files: selected.files, manifest: selected.manifest,
                            metadata: selected.metadata, associationPolicy: association, rescuePolicy: .allowShortRestart,
                            focusSnapshot: selected.focus, pauseBridgePolicy: policy)
                        samples.append(analysis.analysisSeconds)
                        if let first {
                            guard try SequenceProbeRun.resultSHA256(first.result) == SequenceProbeRun.resultSHA256(analysis.result),
                                  try first.configuration.fingerprint == analysis.configuration.fingerprint else {
                                throw SequenceFixtureError.invalid("Repeated inference changed results")
                            }
                        } else { first = analysis }
                    }
                    let analysis = first!
                    guard analysis.map.events.flatMap({ $0.members.map(\.ordinal) }) == Array(selected.files.indices),
                          analysis.featuresAvailable.allSatisfy({ $0 }) else { throw SequenceFixtureError.invalid("Projection coverage lost inputs") }
                    variants.append(["variant": name, "associationPolicy": association.rawValue,
                        "configuration": try SpatialExperimentHarness.object(analysis.configuration),
                        "policyFingerprint": try analysis.configuration.fingerprint, "result": try SpatialExperimentHarness.object(analysis.result),
                        "resultSHA256": try SequenceProbeRun.resultSHA256(analysis.result),
                        "eventMapFingerprint": analysis.map.fingerprint, "eventCount": analysis.map.events.count,
                        "associationHypothesisAssumed": analysis.associationHypothesisAssumed,
                        "engineSeconds": samples, "engineManagedPeakEstimateBytes": analysis.managedPeakEstimateBytes,
                        "pauseBridgeStatistics": try analysis.pauseBridgeStatistics.map { try SpatialExperimentHarness.object($0) } ?? NSNull()])
                }
            }
            let bindings: [[String: Any]] = selected.files.enumerated().map { ordinal, file in
                ["caseID": item.id, "assetID": file.entry.assetID, "ordinal": ordinal,
                 "sourceOrdinal": selected.sourceOrdinals[ordinal], "jpegSHA256": file.metadata.currentSHA256,
                 "originalSHA256": file.metadata.originalSHA256]
            }
            cases.append(["id": item.id, "assetCount": selected.files.count, "sourceAssetCount": prepared.files.count,
                "bindings": bindings, "sourceProofs": try SpatialExperimentHarness.object(prepared.native.sources),
                "sourceManifestSHA256": item.manifestSHA256, "metadataSnapshotSHA256": selected.metadata.fingerprint,
                "sourceMetadataSnapshotSHA256": prepared.snapshot.fingerprint, "focusSnapshotSHA256": selected.focus.fingerprint,
                "sourceFocusSnapshotSHA256": focus.fingerprint, "manifest": try SpatialExperimentHarness.object(selected.manifest),
                "sourcesUnchanged": prepared.native.sourcesUnchanged, "variants": variants,
                "preparationSeconds": preparationSeconds, "hashBeforeSeconds": prepared.native.hashBeforeSeconds,
                "nativeReaderAndControlSeconds": prepared.native.readerAndEngineSeconds,
                "hashAfterSeconds": prepared.native.hashAfterSeconds])
        }
        return ["schemaVersion": 1, "kind": "accepted-annotation-predictions", "labelsRead": false,
            "candidatePolicy": candidateRawValue, "fixtureIndexSHA256": SequenceProbeRun.sha256(indexBytes),
            "metadataIndexSHA256": metadataSHA, "focusIndexSHA256": focusSHA, "cases": cases,
            "assetCount": cases.reduce(0) { $0 + ($1["assetCount"] as! Int) }, "engineRepeats": repeats,
            "platform": try SpatialExperimentHarness.object(SequenceFixturePlatform()),
            "timingBoundary": "Preparation includes 1,265 native JPEG hashes/reads plus default control analysis, metadata/focus validation and projection. Engine samples classify only 1,077 selected inputs with already-read features. No RAW decode, ExifTool extraction, database, GUI, or independent-device benchmark."]
    }
}
