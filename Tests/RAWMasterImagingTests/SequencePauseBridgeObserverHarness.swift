import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

struct PauseBridgeObserverUnit: Codable {
    let schemaVersion: Int
    let runID, unitID, caseID: String
    let fixtureIndexSHA256, metadataIndexSHA256, observedBaselineSHA256: String
    let sourceSnapshotSHA256, executableSHA256: String
}

final class PauseBridgeObserverTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let allowedOrdinals: Set<Int>?
    private var events: [SequenceTraceEvent] = []
    private var overflow = false
    init(limit: Int = 4096, allowedOrdinals: Set<Int>? = nil) {
        self.limit = min(4096, max(0, limit)); self.allowedOrdinals = allowedOrdinals
    }
    func record(_ event: SequenceTraceEvent) {
        if let allowedOrdinals, !allowedOrdinals.contains(event.ordinal) { return }
        guard event.stage == .bridge || event.stage == .anchor
            || (event.stage == .decision && [.bridgePending, .bridgeRejected].contains(event.reason)) else { return }
        lock.lock(); defer { lock.unlock() }
        guard events.count < limit else { overflow = true; return }
        events.append(event)
    }
    func snapshot() throws -> [SequenceTraceEvent] {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw SequenceFixtureError.invalid("Pause observer emitted-subset cap exceeded") }
        return events
    }
}

struct PauseBridgeObserverSupport {
    let ordinal: Int
    let issues: [String]
    let feature: SequenceFrameFeature?
    let facts: [String: Any]
}

enum SequencePauseBridgeObserverHarness {
    static let version = "pause-bridge-observer-v1"
    static let maximumBytes = 16 * 1024 * 1024
    static let traceBoundary = "Bounded emitted observer subset; absence is not causal evidence. Underlying event-pipeline trace summary is unavailable; no completeness claim follows from an unfilled observer cap. Independently enumerated matrices are the complete diagnostic basis."
    static let fields = ["sony.ReleaseMode", "sony.SequenceNumber", "sony.SequenceImageNumber", "sony.SequenceFileNumber", "sony.SequenceLength", "sony.ReleaseMode2", "exif.ISO", "exif.FNumber", "exif.FocalLength", "exif.ExposureProgram", "exif.ExposureTime"]

    static func bytes(_ value: Any, limit: Int = maximumBytes) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= min(limit, maximumBytes) else { throw SequenceFixtureError.invalid("Pause observer artifact byte cap exceeded") }
        return data
    }
    static func protectedOutput(_ path: String, repository: URL) throws -> URL {
        guard path.hasPrefix("/") else { throw SequenceFixtureError.invalid("Pause observer output must be absolute") }
        let root = repository.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("output")
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw SequenceFixtureError.invalid("Pause observer output must be under ignored output") }
        var cursor = URL(fileURLWithPath: "/")
        for part in target.pathComponents.dropFirst() {
            cursor.appendPathComponent(part)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: cursor.path) {
                guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw SequenceFixtureError.invalid("Pause observer output traverses symlink") }
                if cursor != target {
                    guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw SequenceFixtureError.invalid("Pause observer output parent is not a directory") }
                }
            }
        }
        return target
    }
    static func write(_ data: Data, path: String, repository: URL) throws -> URL {
        guard data.count <= maximumBytes else { throw SequenceFixtureError.invalid("Pause observer artifact byte cap exceeded") }
        let output = try protectedOutput(path, repository: repository)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try protectedOutput(path, repository: repository) == output else { throw SequenceFixtureError.invalid("Pause observer output changed") }
        try data.write(to: output, options: .withoutOverwriting)
        return output
    }
    /// Geometry of the existing clipped luminance vectors, not an independent feature channel.
    static func luminanceGeometry(_ a: [Float], _ b: [Float]) throws -> [String: Any] {
        guard !a.isEmpty, a.count == b.count, a.count <= 1024,
              (a + b).allSatisfy({ $0.isFinite && (-3...3).contains($0) }) else {
            throw SequenceFixtureError.invalid("Pause observer invalid luminance geometry input")
        }
        let first = a.map(Double.init), second = b.map(Double.init), count = Double(a.count)
        let firstMean = first.reduce(0, +) / count, secondMean = second.reduce(0, +) / count
        var dot = 0.0, firstNorm = 0.0, secondNorm = 0.0
        var centeredDot = 0.0, firstCenteredNorm = 0.0, secondCenteredNorm = 0.0
        for (x, y) in zip(first, second) {
            dot += x * y; firstNorm += x * x; secondNorm += y * y
            let centeredX = x - firstMean, centeredY = y - secondMean
            centeredDot += centeredX * centeredY
            firstCenteredNorm += centeredX * centeredX; secondCenteredNorm += centeredY * centeredY
        }
        guard [dot, firstNorm, secondNorm, firstMean, secondMean, centeredDot, firstCenteredNorm, secondCenteredNorm].allSatisfy(\.isFinite) else {
            throw SequenceFixtureError.invalid("Pause observer nonfinite luminance geometry")
        }
        func coefficient(_ numerator: Double, _ left: Double, _ right: Double) throws -> (Any, Any) {
            guard left > 0, right > 0 else { return (NSNull(), "zero-or-degenerate-energy") }
            let value = numerator / sqrt(left * right)
            guard value.isFinite else { throw SequenceFixtureError.invalid("Pause observer nonfinite luminance coefficient") }
            // Mathematical coefficient bounds, correcting only floating-point roundoff.
            return (min(1.0, max(-1.0, value)), NSNull())
        }
        let cosine = try coefficient(dot, firstNorm, secondNorm)
        let pearson = try coefficient(centeredDot, firstCenteredNorm, secondCenteredNorm)
        return ["count": a.count, "rawDot": dot, "firstNormSquared": firstNorm, "secondNormSquared": secondNorm,
            "firstMean": firstMean, "secondMean": secondMean, "centeredDot": centeredDot,
            "firstCenteredNormSquared": firstCenteredNorm, "secondCenteredNormSquared": secondCenteredNorm,
            "cosine": cosine.0, "cosineUnavailableReason": cosine.1,
            "pearson": pearson.0, "pearsonUnavailableReason": pearson.1]
    }
    static func distance(_ a: PauseBridgeObserverSupport, _ b: PauseBridgeObserverSupport) throws -> [String: Any] {
        var issues = Set(a.issues + b.issues)
        if a.feature == nil || b.feature == nil { issues.insert("feature-unavailable") }
        var value: [String: Any] = ["fromOrdinal": a.ordinal, "toOrdinal": b.ordinal, "issues": issues.sorted()]
        if issues.isEmpty, let first = a.feature, let second = b.feature {
            let d = first.distance(to: second)
            value["distance"] = ["histogram": d.histogram, "luminance": d.luminance, "hash": d.hash]
            value["luminanceGeometry"] = try luminanceGeometry(first.normalizedLuminance, second.normalizedLuminance)
            value["luminanceGeometryUnavailableReason"] = NSNull()
        } else {
            value["distance"] = NSNull(); value["luminanceGeometry"] = NSNull()
            value["luminanceGeometryUnavailableReason"] = "pair-support-unavailable"
        }
        return value
    }
    static func matrices(left: [PauseBridgeObserverSupport], right: [PauseBridgeObserverSupport]) throws -> [String: Any] {
        guard left.count == 3, right.count == 3 else { throw SequenceFixtureError.invalid("Pause observer requires all three ordered slots per side") }
        guard zip(left, left.dropFirst()).allSatisfy({ $1.ordinal == $0.ordinal + 1 }),
              zip(right, right.dropFirst()).allSatisfy({ $1.ordinal == $0.ordinal + 1 }),
              right[0].ordinal == left[2].ordinal + 1 else { throw SequenceFixtureError.invalid("Pause observer slots must be contiguous") }
        func intra(_ frames: [PauseBridgeObserverSupport]) throws -> [[String: Any]] {
            try [(0, 1), (0, 2), (1, 2)].map { try distance(frames[$0.0], frames[$0.1]) }
        }
        return ["crossNine": try left.flatMap { a in try right.map { try distance(a, $0) } },
            "leftIntraThree": try intra(left), "rightIntraThree": try intra(right)]
    }
    static func gap(_ first: SequenceTimeEvidence, _ second: SequenceTimeEvidence) -> Double? {
        guard first.isConsistent, second.isConsistent, let a = first.local, let b = second.local,
              let an = a.nanosecond, let bn = b.nanosecond else { return nil }
        return Double(b.civilSecond - a.civilSecond) + Double(bn - an) / 1_000_000_000
    }
    static func support(_ ordinal: Int, prepared: MetadataExperimentHarness.Prepared,
                        analysis: SequenceMetadataEventAnalysis, reference: Int) -> PauseBridgeObserverSupport {
        guard prepared.files.indices.contains(ordinal) else {
            return PauseBridgeObserverSupport(ordinal: ordinal, issues: ["outside-input-scope"], feature: nil,
                facts: ["ordinal": ordinal, "status": "outside-input-scope", "issues": ["outside-input-scope"]])
        }
        let file = prepared.files[ordinal], observed = analysis.observations[ordinal], anchor = analysis.observations[reference]
        let fingerprint = prepared.native.manifest.contentFingerprint
        let camera = observed.entry.camera.partitionID(manifestFingerprint: fingerprint)
        let referenceCamera = anchor.entry.camera.partitionID(manifestFingerprint: fingerprint)
        var issues = observed.validationIssues(manifest: analysis.manifest, versions: analysis.result.token.versions).map(\.rawValue)
        if observed.barrier != nil { issues.append("input-barrier") }
        if camera == nil || referenceCamera == nil || camera != referenceCamera { issues.append("camera-not-comparable") }
        if observed.clock == nil || anchor.clock == nil || observed.clock != anchor.clock { issues.append("clock-not-comparable") }
        if file.feature == nil { issues.append("feature-unavailable") }
        let original = file.metadata.originalCapture.time, current = file.currentEvidence?.time
        let selected = Dictionary(uniqueKeysWithValues: fields.compactMap { name in file.metadata.resolvedNumbers[name].map { (name, $0) } })
        let states = Dictionary(uniqueKeysWithValues: fields.map { ($0, file.metadata.fieldStates[$0]?.rawValue ?? "not-recorded") })
        let facts: [String: Any] = ["ordinal": ordinal, "status": issues.isEmpty ? "available" : "unavailable",
            "issues": Array(Set(issues)).sorted(), "informative": file.feature?.isInformative as Any? ?? NSNull(),
            "originalDateTimeRaw": original.originalRaw as Any? ?? NSNull(), "originalSubsecondsRaw": original.subsecondsRaw as Any? ?? NSNull(),
            "originalOffsetRaw": original.offsetRaw as Any? ?? NSNull(), "originalCivilSecond": original.local?.civilSecond as Any? ?? NSNull(),
            "originalNanosecond": original.local?.nanosecond as Any? ?? NSNull(),
            "currentCivilSecond": current?.local?.civilSecond as Any? ?? NSNull(), "currentNanosecond": current?.local?.nanosecond as Any? ?? NSNull(),
            "currentOffsetMinutes": current?.offsetMinutes as Any? ?? NSNull(), "resolvedPublicNumbers": selected, "fieldStates": states]
        return PauseBridgeObserverSupport(ordinal: ordinal, issues: Array(Set(issues)).sorted(), feature: file.feature, facts: facts)
    }
    static func windows(prepared: MetadataExperimentHarness.Prepared, analysis: SequenceMetadataEventAnalysis) throws -> [[String: Any]] {
        guard prepared.files.count == analysis.observations.count else { throw SequenceFixtureError.invalid("Pause observer coverage mismatch") }
        guard prepared.files.count > 1 else { return [] }
        let base = SequenceDetectorConfiguration()
        var rows: [[String: Any]] = []
        for right in 1..<prepared.files.count {
            let a = prepared.files[right - 1].metadata, b = prepared.files[right].metadata
            guard a.fieldStates["sony.ReleaseMode"] == .present, b.fieldStates["sony.ReleaseMode"] == .present,
                  a.resolvedNumbers["sony.ReleaseMode"] == "2", b.resolvedNumbers["sony.ReleaseMode"] == "2",
                  let delta = gap(a.originalCapture.time, b.originalCapture.time),
                  delta > base.denseGapSeconds, delta <= base.maximumBridgeSeconds else { continue }
            guard rows.count < 4096 else { throw SequenceFixtureError.invalid("Pause observer row cap exceeded") }
            let leftFrames = (right - 3..<right).map { support($0, prepared: prepared, analysis: analysis, reference: right - 1) }
            let rightFrames = (right..<right + 3).map { support($0, prepared: prepared, analysis: analysis, reference: right - 1) }
            var row = try matrices(left: leftFrames, right: rightFrames)
            row["leftOrdinal"] = right - 1; row["rightOrdinal"] = right; row["gapSeconds"] = delta
            row["leftSlots"] = leftFrames.map(\.facts); row["rightSlots"] = rightFrames.map(\.facts)
            row["supportComplete"] = (leftFrames + rightFrames).allSatisfy { $0.issues.isEmpty }
            rows.append(row)
        }
        return rows
    }
    static func run(_ request: PauseBridgeObserverUnit, v1: URL, v2: URL, output: URL, repository: URL) throws -> [String: Any] {
        guard request.schemaVersion == 1, !request.runID.isEmpty, !request.unitID.isEmpty,
              [request.fixtureIndexSHA256, request.metadataIndexSHA256, request.observedBaselineSHA256,
               request.sourceSnapshotSHA256, request.executableSHA256].allSatisfy(SequenceFixtureFiles.isDigest) else {
            throw SequenceFixtureError.invalid("Pause observer identity")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let metadataRequest = MetadataExperimentUnit(schemaVersion: 1, runID: request.runID, unitID: request.unitID,
            phase: "bootstrap", caseID: request.caseID, variant: nil, expectedPolicyFingerprint: nil,
            fixtureIndexSHA256: request.fixtureIndexSHA256, metadataIndexSHA256: request.metadataIndexSHA256,
            sourceSnapshotSHA256: request.sourceSnapshotSHA256, executableSHA256: request.executableSHA256)
        let prepared = try MetadataExperimentHarness.prepare(metadataRequest, v1: v1, v2: v2)
        let mode2Ordinals = Set(prepared.files.indices.filter {
            prepared.files[$0].metadata.fieldStates["sony.ReleaseMode"] == .present
                && prepared.files[$0].metadata.resolvedNumbers["sony.ReleaseMode"] == "2"
        })
        let trace = PauseBridgeObserverTrace(allowedOrdinals: mode2Ordinals)
        let analyzed = try SequenceMetadataEventPipeline.analyze(files: prepared.files, manifest: prepared.native.manifest,
            metadata: prepared.snapshot, associationPolicy: .strict, rescuePolicy: .allowShortRestart,
            trace: { trace.record($0) })
        let rows = try windows(prepared: prepared, analysis: analyzed)
        let events = try trace.snapshot()
        let defaultSHA = try SequenceProbeRun.resultSHA256(prepared.native.result), strictSHA = try SequenceProbeRun.resultSHA256(analyzed.result)
        let sources: [[String: Any]] = prepared.files.indices.map { ordinal in
            let source = prepared.native.sources[ordinal], file = prepared.files[ordinal]
            return ["ordinal": ordinal, "assetID": file.entry.assetID, "currentSHA256": file.metadata.currentSHA256,
                "originalSHA256": file.metadata.originalSHA256, "beforeSHA256": source.beforeSHA256 as Any? ?? NSNull(),
                "afterSHA256": source.afterSHA256 as Any? ?? NSNull(), "sourceUnchanged": source.unchanged,
                "featureAvailable": file.feature != nil]
        }
        let diagnostic: [String: Any] = ["schemaVersion": 1, "kind": "pause-bridge-observation", "version": version,
            "identity": try SpatialExperimentHarness.object(request), "assetCount": prepared.files.count,
            "metadataSnapshotSHA256": prepared.snapshot.fingerprint, "auditSeal": prepared.snapshot.auditSeal,
            "defaultResult": try SpatialExperimentHarness.object(prepared.native.result), "strict008BResult": try SpatialExperimentHarness.object(analyzed.result),
            "defaultResultSHA256": defaultSHA, "strict008BResultSHA256": strictSHA,
            "configuration": try SpatialExperimentHarness.object(analyzed.configuration),
            "eventMapFingerprint": analyzed.map.fingerprint, "sources": sources, "pauseWindows": rows,
            "emittedTraceSubset": try SpatialExperimentHarness.object(events), "emittedTraceSubsetCount": events.count,
            "traceBoundary": traceBoundary, "emittedTraceScope": "Target ordinals with present audited main ReleaseMode=2 only; no case or label filter",
            "emittedTraceScopeOrdinalCount": mode2Ordinals.count, "matricesComplete": true, "labelsRead": false,
            "luminanceGeometryBoundary": "Double scalar geometry of the same existing clipped normalizedLuminance vectors, not independent evidence. Pearson is recomputed after mean centering; degenerate coefficients are null with a reason. Zero/negative correlation does not prove a semantic scene or group boundary. No vector arrays are exported.",
            "enumerationBoundary": "Every original adjacent edge with both main ReleaseMode=2 and original precise local gap in the unchanged (denseGapSeconds, maximumBridgeSeconds] interval. Every edge retains all six requested ordinal slots, all cross9 and intra3+3 pairs; missing support is explicit. Not a list of actual bridge attempts."]
        let diagnosticBytes = try bytes(diagnostic)
        let diagnosticURL = try write(diagnosticBytes, path: output.appendingPathExtension("diagnostic.json").path, repository: repository)
        // Diagnostics and both unmodified predictions are sealed before old observed behavior is interpreted.
        let baselineBytes = try Data(contentsOf: v2.appendingPathComponent("baselines/behavior-v1.json"))
        guard SequenceProbeRun.sha256(baselineBytes) == request.observedBaselineSHA256,
              let baseline = try JSONSerialization.jsonObject(with: baselineBytes) as? [String: Any],
              let observations = baseline["observations"] as? [[String: Any]],
              let expected = observations.first(where: { $0["caseID"] as? String == request.caseID && $0["variant"] as? String == "strict-shortRestart" }),
              expected["resultSHA256"] as? String == strictSHA,
              expected["policyFingerprint"] as? String == (try analyzed.configuration.fingerprint),
              expected["eventMapFingerprint"] as? String == analyzed.map.fingerprint else {
            throw SequenceFixtureError.invalid("Pause observer changed frozen008 strictB behavior")
        }
        let goldenBytes = try Data(contentsOf: v1.appendingPathComponent(SequenceFixtureHarness.baselineRelativePath))
        guard let golden = try JSONSerialization.jsonObject(with: goldenBytes) as? [String: Any],
              let cases = golden["cases"] as? [[String: Any]],
              let old = cases.first(where: { $0["id"] as? String == request.caseID }), let oldResult = old["result"] else {
            throw SequenceFixtureError.invalid("Pause observer missing dev4 control")
        }
        let oldResultBytes = try JSONSerialization.data(withJSONObject: oldResult, options: .sortedKeys)
        let oldPrediction = try SequenceFixtureHarness.decode(SequenceAnalysisResult.self, data: oldResultBytes)
        guard try SequenceProbeRun.resultSHA256(oldPrediction) == defaultSHA else { throw SequenceFixtureError.invalid("Pause observer changed dev4 behavior") }
        return ["schemaVersion": 1, "kind": "pause-bridge-observer-report", "identity": try SpatialExperimentHarness.object(request),
            "assetCount": prepared.files.count, "pauseWindowCount": rows.count, "sourceIntegrityValidated": prepared.native.sourcesUnchanged,
            "defaultParity": true, "strict008BParity": true, "diagnosticSealedBeforeBaselineRead": true,
            "diagnosticPath": diagnosticURL.path, "diagnosticSHA256": SequenceProbeRun.sha256(diagnosticBytes),
            "defaultResultSHA256": defaultSHA, "strict008BResultSHA256": strictSHA,
            "metadataSnapshotSHA256": prepared.snapshot.fingerprint, "auditSeal": prepared.snapshot.auditSeal,
            "traceBoundary": traceBoundary, "labelsRead": false, "qualityAccepted": false,
            "wholeUnitSeconds": ProcessInfo.processInfo.systemUptime - started,
            "processPeakResidentBytes": MetadataExperimentHarness.processPeakResidentBytes() as Any? ?? NSNull(),
            "resourceBoundary": "Single observer process high-water RSS includes native preparation, unchanged strict008B classification, matrices, sealing and baseline comparison; not application latency or repeat benchmark."]
    }
}
