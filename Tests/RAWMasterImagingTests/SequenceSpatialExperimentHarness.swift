import Foundation
import Darwin
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

struct SpatialExperimentUnit: Codable {
    let schemaVersion: Int
    let runID, unitID, phase: String
    let caseID, variant: String?
    let repetition: Int?
    let pairID: String?
    let expectedPolicyFingerprint, fixtureIndexSHA256: String?
    let sourceSnapshotSHA256, executableSHA256: String
}
final class SpatialMeasurementCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProbeMeasurement] = []
    private var invalid = false
    func record(_ value: ProbeMeasurement) {
        lock.lock(); defer { lock.unlock() }
        guard value.durationSeconds.isFinite, value.durationSeconds >= 0, values.count < 65_536 else { invalid = true; return }
        if let pair = value.spatial {
            guard pair.referenceOrdinal < pair.ordinal, pair.candidateCount >= 0, pair.candidateCount <= 539,
                  pair.managedLiveBytes >= 0, pair.managedPeakBytes >= pair.managedLiveBytes,
                  pair.scratchReservedBytes >= 0 else { invalid = true; return }
        }
        values.append(value)
    }
    func snapshot() throws -> [ProbeMeasurement] {
        lock.lock(); defer { lock.unlock() }
        guard !invalid else { throw SequenceFixtureError.invalid("Invalid or truncated experimental performance samples") }
        return values
    }
}
enum SpatialExperimentHarness {
    static let variants = ["baseline", "bridgeVetoOnly", "localRescueAndBridgeVeto"]
    static func configuration(_ name: String) throws -> SequenceDetectorConfiguration {
        var result = SequenceDetectorConfiguration()
        switch name {
        case "baseline": break
        case "bridgeVetoOnly": result.spatialExperiment = SequenceSpatialConfiguration(mode: .bridgeVetoOnly)
        case "localRescueAndBridgeVeto": result.spatialExperiment = SequenceSpatialConfiguration(mode: .localRescueAndBridgeVeto)
        default: throw SequenceFixtureError.invalid("Unknown spatial variant")
        }
        try result.validate(); return result
    }
    static func policy(caseID: String, configuration: SequenceDetectorConfiguration, trace: Bool) -> ProbePolicy {
        let positive = ["burst123":122, "burst14-context38":13, "burst48-context72":47,
            "interval427-context439":426, "burst193-context217":192, "dji187-context376":373][caseID]!
        return ProbePolicy(schemaVersion: trace ? 3 : 2, detector: configuration,
            sourceAssertion: ProbeSourceAssertion(id: "fixture-declared-\(caseID)", revision: 0, declaredByUser: true,
                provenance: "User-declared single-source batch, checked against all derivative JPEG metadata; not native-device verification"),
            acceptance: ProbeAcceptance(minimumPositivePairs: positive, minimumRecall: 0.95, minimumTypedCoverage: 0.8,
                minimumExactGroupFraction: 1, minimumPrecision: 0.95, minimumNegativePairs: caseID == "interval427-context439" ? 1 : 2),
            maximumDurationSeconds: 60, deterministicSeed: 0, boundedTrace: trace ? ProbeBoundedTrace() : nil)
    }
    static func protectedOutput(_ path: String, fixtureRoot: URL) throws -> URL {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SequenceFixtureError.invalid("Empty experimental output") }
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for root in [fixtureRoot, repository.appendingPathComponent("Tests/RAWMasterImagingTests/Fixtures"), repository.appendingPathComponent("Tests/Fixtures/SequenceGroupingInputs")] {
            let resolved = root.standardizedFileURL.resolvingSymlinksInPath().path
            guard target.path != resolved, !target.path.hasPrefix(resolved + "/") else { throw SequenceFixtureError.invalid("Experimental output aliases fixture/truth") }
        }
        return target
    }
    static func write(_ data: Data, path: String, fixtureRoot: URL) throws {
        let target = try protectedOutput(path, fixtureRoot: fixtureRoot)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rechecked = try protectedOutput(path, fixtureRoot: fixtureRoot)
        guard target == rechecked else { throw SequenceFixtureError.invalid("Experimental output destination changed") }
        try data.write(to: target, options: .atomic)
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: SequenceFixtureHarness.encoded(value))
    }
    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : nil
    }
    static func bootstrap(_ request: SpatialExperimentUnit, root: URL) throws -> [String: Any] {
        let (index, data) = try SequenceFixtureHarness.loadIndex(root: root)
        let golden = try Data(contentsOf: SequenceFixtureFiles.resolve(SequenceFixtureHarness.baselineRelativePath, root: root))
        let records: [[String: Any]] = try variants.map { name in
            let configuration = try self.configuration(name)
            return ["variant": name, "policyFingerprint": try configuration.fingerprint,
                "configuration": try object(configuration), "versions": try object(configuration.versions(order: SequenceBaseOrder.version))]
        }
        return ["schemaVersion": 1, "kind": "descriptor", "identity": try object(request),
            "fixtureIndexSHA256": SequenceProbeRun.sha256(data), "goldenSHA256": SequenceProbeRun.sha256(golden),
            "variants": records, "caseCounts": SequenceFixtureIndex.expectedCounts, "platform": try object(SequenceFixturePlatform()),
            "bundlePath": Bundle.module.bundleURL.path]
    }
    static func run(_ request: SpatialExperimentUnit, root: URL, reportPath: String) throws -> [String: Any] {
        guard request.schemaVersion == 1, !request.runID.isEmpty, !request.unitID.isEmpty,
              ["quality", "warmup", "measured"].contains(request.phase),
              let caseID = request.caseID, let variant = request.variant else { throw SequenceFixtureError.invalid("Invalid spatial unit identity") }
        let (index, data) = try SequenceFixtureHarness.loadIndex(root: root)
        guard request.fixtureIndexSHA256 == SequenceProbeRun.sha256(data),
              let item = index.cases.first(where: { $0.id == caseID }) else { throw SequenceFixtureError.invalid("Fixture index/case identity mismatch") }
        let config = try configuration(variant)
        guard request.expectedPolicyFingerprint == (try config.fingerprint),
              SequenceFixtureFiles.isDigest(request.sourceSnapshotSHA256), SequenceFixtureFiles.isDigest(request.executableSHA256)
        else { throw SequenceFixtureError.invalid("Experiment policy/source/binary identity mismatch") }
        let (manifestData, manifestURL) = try SequenceFixtureHarness.verifiedSidecar(item.manifestPath, expectedHash: item.manifestSHA256, root: root)
        let manifest = try SequenceFixtureHarness.decode(SequenceFixtureManifest.self, data: manifestData)
        try manifest.validate(expectedCount: item.assetCount)
        let description = try SequenceFixtureHarness.decode(ProbeManifest.self, data: manifestData)
        let (metadataData, _) = try SequenceFixtureHarness.verifiedSidecar(item.metadataPath, expectedHash: item.metadataSHA256, root: root)
        let metadata = try SequenceFixtureHarness.decode(SequenceFixtureMetadata.self, data: metadataData)
        guard metadata.schemaVersion == 1, metadata.caseID == caseID,
              metadata.assets.map(\.assetID) == manifest.files.map(\.assetID) else { throw SequenceFixtureError.invalid("Experimental metadata inventory mismatch") }
        let caseRoot = manifestURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: caseRoot.appendingPathComponent("files"), includingPropertiesForKeys: nil)
        guard files.count == item.assetCount, Set(files.map(\.lastPathComponent)) == Set(manifest.files.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent }) else { throw SequenceFixtureError.invalid("Experimental physical fixture inventory mismatch") }
        if caseID == "dji187-context376" { try SequenceFixtureHarness.validateDJIPairs(manifest) }
        let tracing = request.phase == "quality"
        let policy = self.policy(caseID: caseID, configuration: config, trace: tracing)
        let trace: ProbeTraceSink?
        if let bounded = policy.boundedTrace {
            trace = try ProbeTraceSink.reserve(reportURL: protectedOutput(reportPath, fixtureRoot: root), sourceRoot: root,
                controls: [manifestURL], configuration: bounded)
            try trace?.begin(manifestControlSHA256: item.manifestSHA256, policyControlSHA256: SequenceProbeRun.sha256(SequenceFixtureHarness.encoded(policy)))
        } else { trace = nil }
        let collector = SpatialMeasurementCollector()
        var summary: SequenceTraceSummary?
        let rssBefore = residentBytes()
        let analysis = try SequenceProbeRun.analyze(manifest: description, root: caseRoot, policy: policy,
            trace: trace, onTraceSummary: { summary = $0 }, onMeasurement: { collector.record($0) })
        let rssAfter = residentBytes()
        guard analysis.sourcesUnchanged, analysis.featuresAvailable.allSatisfy({ $0 }),
              analysis.sources.count == manifest.files.count else { throw SequenceFixtureError.invalid("Native experimental analysis incomplete") }
        for ordinal in manifest.files.indices {
            let file = manifest.files[ordinal], source = analysis.sources[ordinal]
            guard source.assetID == file.assetID, source.beforeSHA256 == file.jpegSHA256,
                  source.afterSHA256 == file.jpegSHA256, source.errors.isEmpty,
                  analysis.manifest.entries[ordinal].contentHash == file.jpegSHA256,
                  let evidence = analysis.observations[ordinal].evidence else { throw SequenceFixtureError.invalid("Experimental JPEG hash/input binding invalid") }
            try SequenceFixtureHarness.validateMetadata(metadata.assets[ordinal], evidence: evidence, sourceHash: file.sourceCapture.sha256, recipe: index.recipe)
            try SequenceFixtureHarness.validateJPEG(SequenceFixtureFiles.resolve(file.relativePath, root: caseRoot), file: file)
        }
        let measurements = try collector.snapshot()
        guard measurements.filter({ $0.stage == .nativeRead }).count == item.assetCount,
              measurements.filter({ $0.stage == .engineConsume }).count == item.assetCount,
              measurements.filter({ $0.stage == .spatialExtraction }).count == (variant == "baseline" ? 0 : item.assetCount),
              measurements.filter({ $0.stage == .engineFinish }).count == 1 else { throw SequenceFixtureError.invalid("Missing experimental measurements") }
        if let stats = analysis.spatialStatistics {
            guard stats.pairRequests == measurements.filter({ $0.stage == .spatialPair }).count,
                  stats.maximumCandidatesPerPair <= 539 else { throw SequenceFixtureError.invalid("Spatial metric sample/count mismatch") }
        } else if variant != "baseline" { throw SequenceFixtureError.invalid("Candidate missing spatial statistics") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sealedData = try encoder.encode(analysis)
        let analysisPath = reportPath + ".analysis.json"
        let (seal, evaluation) = try SequenceProbeRun.sealThenEvaluate(analysis, policy: policy, onSealed: { seal in
            guard seal == SequenceProbeRun.sha256(sealedData) else { throw SequenceFixtureError.invalid("Analysis seal mismatch") }
            try write(sealedData, path: analysisPath, fixtureRoot: root)
        }) {
            let (truthData, _) = try SequenceFixtureHarness.verifiedSidecar(item.truthPath, expectedHash: item.truthSHA256, root: root)
            let truth = try SequenceFixtureHarness.decode(ProbeLabels.self, data: truthData)
            try truth.validate(assetIDs: manifest.files.map(\.assetID))
            let unknown = Set(item.unknownAssetIDs)
            guard truth.role == "development-regression-fixture", truth.groups.allSatisfy({ unknown.isDisjoint(with: $0.assetIDs) }),
                  truth.negativePairs.allSatisfy({ !unknown.contains($0.from) && !unknown.contains($0.to) }) else { throw SequenceFixtureError.invalid("Unknown extent leaked into labels") }
            return truth
        }
        let traceReport = try trace.map { sink -> ProbeTraceReport in
            guard let summary else { throw SequenceFixtureError.invalid("Missing trace summary") }
            return try sink.finish(analysis: analysis, analysisSHA256: seal, summary: summary)
        }
        var limitations = evaluation.failures.filter { $0.contains("support") || $0.contains("acceptanceIncomplete") || $0 == "acceptanceNotConfigured" || $0 == "source-declaration-contradicted" }
        if evaluation.unknownPositivePairs > 0 { limitations.append("positive-pairs-not-decidable: \(evaluation.unknownPositivePairs)") }
        if !item.completeGroupTruth { limitations.append("full-group-extent-not-labeled; DJI0188 remains unknown") }
        let behavior = SequenceFixtureCaseBehavior(id: caseID, assetCount: item.assetCount, manifestSHA256: item.manifestSHA256,
            metadataSHA256: item.metadataSHA256, truthSHA256: item.truthSHA256, policyFingerprint: try config.fingerprint,
            result: analysis.result, evaluation: evaluation, completeGroupTruth: item.completeGroupTruth,
            unknownAssetIDs: item.unknownAssetIDs, integrityValidated: true,
            qualityAccepted: evaluation.acceptedWithinDeclaredSourceScope && item.completeGroupTruth,
            evidenceLimitations: limitations, classificationFailures: evaluation.failures.filter { !limitations.contains($0) })
        if variant == "baseline" { try validateDefaultGolden(behavior, root: root) }
        var report: [String: Any] = ["schemaVersion": 1, "kind": "unit", "identity": try object(request),
            "integrityValidated": true, "strictValidated": true, "behavior": try object(behavior),
            "analysisSHA256": seal, "resultSHA256": try SequenceProbeRun.resultSHA256(analysis.result),
            "analysisPath": analysisPath, "measurements": try object(measurements), "platform": try object(SequenceFixturePlatform()),
            "wholeCaseSeconds": analysis.analysisSeconds, "hashBeforeSeconds": analysis.hashBeforeSeconds,
            "hashAfterSeconds": analysis.hashAfterSeconds, "readerAndEngineSeconds": analysis.readerAndEngineSeconds,
            "engineManagedPeakEstimateBytes": analysis.engineManagedPeakEstimateBytes,
            "timingBoundary": "wholeCase=before-hash through after-hash; metadata audit, labels and file/report writes excluded; nativeRead/engineConsume include nested CV times, never sum parent+child"]
        report["rssBeforeBytes"] = rssBefore.map { NSNumber(value: $0) as Any } ?? NSNull()
        report["rssAfterBytes"] = rssAfter.map { NSNumber(value: $0) as Any } ?? NSNull()
        report["processPeakResidentBytes"] = analysis.processPeakResidentBytes.map { NSNumber(value: $0) as Any } ?? NSNull()
        report["spatialStatistics"] = try analysis.spatialStatistics.map { try object($0) } ?? NSNull()
        report["trace"] = try traceReport.map { try object($0) } ?? NSNull()
        return report
    }
    static func validateDefaultGolden(_ behavior: SequenceFixtureCaseBehavior, root: URL) throws {
        let data = try Data(contentsOf: SequenceFixtureFiles.resolve(SequenceFixtureHarness.baselineRelativePath, root: root))
        let golden = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let cases = golden?["cases"] as? [[String: Any]], let expected = cases.first(where: { $0["id"] as? String == behavior.id }),
              try SequenceFixtureFiles.canonicalJSON(expected) == SequenceFixtureFiles.canonicalJSON(object(behavior))
        else { throw SequenceFixtureError.invalid("Default nil path drifted from complete approved golden") }
    }
}
