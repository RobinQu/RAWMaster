import Foundation

struct EvidenceInput {
    let id: String
    let sourceOrder: Int
    let url: URL
    var displayName: String { url.lastPathComponent }
}
struct EvidenceOptions {
    var memoryBudgetBytes = 64 * 1024 * 1024
    static let maximumBudgetBytes = 64 * 1024 * 1024
    static let maximumInputs = 512
    /// Prespecified sensitivity baselines, never a production threshold selection.
    static let timeThresholdSeconds: [Double] = [0.5, 1, 2, 5, 10]
    static let algorithmVersion = "burst-evidence-experiment-1"
}
struct EvidenceFrame: Encodable {
    let id: String
    let sourceOrder: Int
    let displayName: String
    let metadata: CaptureEvidence?
    let preview: PreviewFeature?
    let metadataFailure: String?
    let previewFailure: String?
}
struct AdjacentEvidence: Encodable {
    let fromID: String, toID: String
    let coarseLocalCameraSecondDifference: Int64?
    let preciseLocalCameraGapSeconds: Double?
    let utcGapSeconds: Double?
    let timeStatus: String
    let normalizedLuminanceRMS: Float?
    let colorHistogramL1: Float?
    let differenceHashHammingFraction: Float?
}
struct ThresholdEvidence: Encodable {
    let thresholdSeconds: Double
    let retainedPairs: Int
    let evaluablePairs: Int
    let unknownPairs: Int
    let rejectedPairs: Int
}
struct EvidenceCoverage: Encodable {
    let requested: Int, attempted: Int, recorded: Int, notAttempted: Int, discardedOnCancellation: Int, discardedOnBudget: Int
    let metadataSuccesses: Int, metadataFailures: Int, previewSuccesses: Int, previewFailures: Int
    let validLocalTimes: Int, preciseLocalTimes: Int, explicitOffsets: Int
}
struct NullEvidenceMetric: Encodable {
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encodeNil() }
}
struct PositiveEvaluation: Encodable {
    let role: String
    let fixtureID: String
    let labeledGroups: Int
    let labeledFramesInScope: Int
    let labeledFramesMissingFromReport: Int
    let ambiguousLabeledNames: Int
    let knownPositiveAdjacentPairs: Int
    let observedPositiveAdjacentPairs: Int
    let thresholdRetention: [ThresholdEvidence]
    let precision = NullEvidenceMetric()
    let independentHoldoutPrecision = NullEvidenceMetric()
    let boundaryEvaluation: [LabeledThresholdEvaluation]?
    let warning = "Only explicitly labeled edges are evaluated; scope-external and unmarked edges remain unknown. No threshold is selected and production quality is not accepted."
}
struct WilsonInterval: Encodable {
    let lower: Double, upper: Double
    static func calculate(successes: Int, total: Int) -> WilsonInterval? {
        guard total > 0 else { return nil }
        let z = 1.959963984540054, n = Double(total), p = Double(successes) / n
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let radius = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator
        return WilsonInterval(lower: max(0, center - radius), upper: min(1, center + radius))
    }
}
struct LabeledThresholdEvaluation: Encodable {
    let thresholdSeconds: Double
    let truePositive: Int, falsePositive: Int, falseNegative: Int, trueNegative: Int
    let unknownPositive: Int, unknownNegative: Int
    let positiveRetention: Double?
    let positiveRetentionWilson95: WilsonInterval?
    let boundaryFalseMergeRate: Double?
    let boundaryFalseMergeWilson95: WilsonInterval?
    let precision: Double?
    let precisionWilson95: WilsonInterval?
    let zeroPredictions: Bool
    let accepted = false
    let interpretation = "Time-only baseline on explicitly labeled edges; unknown positives count as unretained in coverage-aware retention. Precision denominator includes predicted joins on labeled edges only. No threshold selection, generalization claim, or production acceptance."
    enum CodingKeys: String, CodingKey { case thresholdSeconds, truePositive, falsePositive, falseNegative, trueNegative, unknownPositive, unknownNegative, positiveRetention, positiveRetentionWilson95, boundaryFalseMergeRate, boundaryFalseMergeWilson95, precision, precisionWilson95, zeroPredictions, accepted, interpretation }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(thresholdSeconds, forKey: .thresholdSeconds)
        try c.encode(truePositive, forKey: .truePositive); try c.encode(falsePositive, forKey: .falsePositive)
        try c.encode(falseNegative, forKey: .falseNegative); try c.encode(trueNegative, forKey: .trueNegative)
        try c.encode(unknownPositive, forKey: .unknownPositive); try c.encode(unknownNegative, forKey: .unknownNegative)
        try c.encode(positiveRetention, forKey: .positiveRetention); try c.encode(positiveRetentionWilson95, forKey: .positiveRetentionWilson95)
        try c.encode(boundaryFalseMergeRate, forKey: .boundaryFalseMergeRate); try c.encode(boundaryFalseMergeWilson95, forKey: .boundaryFalseMergeWilson95)
        try c.encode(precision, forKey: .precision); try c.encode(precisionWilson95, forKey: .precisionWilson95)
        try c.encode(zeroPredictions, forKey: .zeroPredictions); try c.encode(accepted, forKey: .accepted)
        try c.encode(interpretation, forKey: .interpretation)
    }
}
struct BurstEvidenceReport: Encodable {
    let schemaVersion = 1
    let algorithmVersion = EvidenceOptions.algorithmVersion
    let metadataExtractorVersion = CaptureEvidence.extractorVersion
    var status: String
    var stopReason: String?
    let coverage: EvidenceCoverage
    let frames: [EvidenceFrame]
    let adjacentPairs: [AdjacentEvidence]
    let chronologicalIDs: [String]
    let chronologicalOrderDiffersFromSourceOrder: Bool
    let rollbackPairs: Int
    let equalPreciseTimePairs: Int
    let thresholds: [ThresholdEvidence]
    let managedBudgetBytes: Int
    let managedPeakEstimateBytes: Int
    let durationSeconds: Double
    var evaluation: PositiveEvaluation?
    let productionQualityAccepted = false
    let precision = NullEvidenceMetric()
    let independentHoldout = NullEvidenceMetric()
    let boundaries = ["Standalone diagnostic; no database writes or production candidate state",
        "Source order is manifest order; chronological view never replaces source-order evidence",
        "No explicit offset means local camera time differences, not UTC elapsed time",
        "Camera model is not proof of a shared physical device",
        "Distances are descriptive signals, not calibrated confidence or production grouping",
        "Managed budget estimates retained vectors, metadata/report records and reserved scratch; ImageIO/framework internals and process RSS are excluded",
        "Serial utility work uses no foreground ImagePipeline permits; production foreground scheduling is not validated"]
}
struct PositiveLabels: Decodable {
    let fixture: String?
    let role: String?
    let groups: [Group]
    var negativeBoundaries: [Boundary]? = nil
    struct Boundary: Decodable { let from: String; let to: String }
    struct Group: Decodable { let id: String; let files: [String] }
}
enum BurstEvidenceExperiment {
    typealias Reader = @Sendable (URL) -> FrameProbe
    static func run(inputs: [EvidenceInput], options: EvidenceOptions = .init(),
                    cancelled: @escaping @Sendable () -> Bool = { false }, reader: @escaping Reader = { CaptureEvidenceReader.read($0) },
                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> BurstEvidenceReport {
        let start = Date()
        let budget = min(EvidenceOptions.maximumBudgetBytes, max(0, options.memoryBudgetBytes))
        var frames: [EvidenceFrame] = [], attempted = 0, discarded = 0, discardedBudget = 0, retainedBytes = 0, peakBytes = 0
        var status = "complete", stopReason: String?
        if inputs.count > EvidenceOptions.maximumInputs { status = "partial"; stopReason = "Input limit exceeded (512); no source read" }
        if status == "complete" {
            for input in inputs {
                if Task.isCancelled || cancelled() { status = "cancelled"; stopReason = "Cancellation before next serial unit"; break }
                let minimumRecordReservation = 16 * 1024
                guard retainedBytes + minimumRecordReservation + CaptureEvidenceReader.scratchReservation <= budget else {
                    status = "partial"; stopReason = "Managed memory budget reached before source read"; break
                }
                attempted += 1
                let probe = await Task.detached(priority: .utility) { reader(input.url) }.value
                if Task.isCancelled || cancelled() {
                    discarded += 1; status = "cancelled"; stopReason = "Cancellation discarded completed unit; no late record committed"; break
                }
                let metadataBytes = (try? JSONEncoder().encode(probe.metadata).count) ?? 0
                let recordBytes = minimumRecordReservation + metadataBytes + (probe.preview?.workingBytes ?? 0)
                guard retainedBytes + recordBytes + CaptureEvidenceReader.scratchReservation <= budget else {
                    discardedBudget += 1; status = "partial"; stopReason = "Managed memory budget reached; current unit not retained"; break
                }
                retainedBytes += recordBytes
                peakBytes = max(peakBytes, retainedBytes + CaptureEvidenceReader.scratchReservation)
                frames.append(EvidenceFrame(id: input.id, sourceOrder: input.sourceOrder, displayName: input.displayName,
                    metadata: probe.metadata, preview: probe.preview, metadataFailure: probe.metadataFailure,
                    previewFailure: probe.previewFailure))
                progress(frames.count, inputs.count)
            }
        }
        if status == "complete", Task.isCancelled || cancelled() {
            status = "cancelled"; stopReason = "Cancellation after final unit; report is not marked complete"
        }
        var pairs: [AdjacentEvidence] = []
        if frames.count > 1 { for i in 1..<frames.count { pairs.append(pair(frames[i - 1], frames[i])) } }
        let sorted = frames.filter { $0.metadata?.time.local != nil }.sorted {
            let a = $0.metadata!.time.local!, b = $1.metadata!.time.local!
            if a.civilSecond != b.civilSecond { return a.civilSecond < b.civilSecond }
            if a.nanosecond != b.nanosecond { return (a.nanosecond ?? -1) < (b.nanosecond ?? -1) }
            return $0.sourceOrder < $1.sourceOrder
        }.map(\.id)
        let validInSourceOrder = frames.filter { $0.metadata?.time.local != nil }.map(\.id)
        let metadataFailures = frames.filter { $0.metadata == nil }.count
        let previewFailures = frames.filter { $0.preview == nil }.count
        // An unreadable unit is retained as a failed record, never silently dropped from coverage.
        if status == "complete", metadataFailures > 0 || previewFailures > 0 {
            status = "partial"; stopReason = "One or more metadata/embedded preview reads failed"
        }
        if Task.isCancelled || cancelled() { status = "cancelled"; stopReason = "Cancellation observed before report completion" }
        return BurstEvidenceReport(status: status, stopReason: stopReason,
            coverage: EvidenceCoverage(requested: inputs.count, attempted: attempted, recorded: frames.count,
                notAttempted: inputs.count - attempted, discardedOnCancellation: discarded, discardedOnBudget: discardedBudget,
                metadataSuccesses: frames.count - metadataFailures, metadataFailures: metadataFailures,
                previewSuccesses: frames.count - previewFailures, previewFailures: previewFailures,
                validLocalTimes: frames.filter { $0.metadata?.time.local != nil }.count,
                preciseLocalTimes: frames.filter { $0.metadata?.time.local?.nanosecond != nil }.count,
                explicitOffsets: frames.filter { $0.metadata?.time.offsetEvidence == "explicit-valid" }.count),
            frames: frames, adjacentPairs: pairs, chronologicalIDs: sorted,
            chronologicalOrderDiffersFromSourceOrder: sorted != validInSourceOrder,
            rollbackPairs: pairs.filter { $0.timeStatus == "clock-rollback-or-source-order-reversal" }.count,
            equalPreciseTimePairs: pairs.filter { $0.timeStatus == "equal-precise-local-time" }.count,
            thresholds: thresholds(pairs), managedBudgetBytes: budget, managedPeakEstimateBytes: peakBytes,
            durationSeconds: Date().timeIntervalSince(start))
    }
    static func pair(_ a: EvidenceFrame, _ b: EvidenceFrame) -> AdjacentEvidence {
        let al = a.metadata?.time.local, bl = b.metadata?.time.local
        let coarse = al.flatMap { a in bl.map { $0.civilSecond - a.civilSecond } }
        var precise: Double?
        if let al, let bl, let an = al.nanosecond, let bn = bl.nanosecond {
            precise = Double(bl.civilSecond - al.civilSecond) + Double(bn - an) / 1e9
        }
        var timeStatus = "missing-or-invalid-local-time"
        if let coarse {
            if let precise {
                timeStatus = precise < 0 ? "clock-rollback-or-source-order-reversal" : precise == 0 ? "equal-precise-local-time" : "precise-local-camera-difference"
            } else { timeStatus = coarse < 0 ? "clock-rollback-or-source-order-reversal" : "coarse-seconds-only-precise-gap-unknown" }
        }
        var luma: Float?, histogram: Float?, hash: Float?
        if let a = a.preview, let b = b.preview, a.normalizedLuminance.count == 1024, b.normalizedLuminance.count == 1024,
           a.colorHistogram.count == 48, b.colorHistogram.count == 48 {
            luma = sqrt(zip(a.normalizedLuminance, b.normalizedLuminance).reduce(Float(0)) { $0 + pow($1.0 - $1.1, 2) } / 1024) / 6
            histogram = zip(a.colorHistogram, b.colorHistogram).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / 6
            hash = Float((a.differenceHash ^ b.differenceHash).nonzeroBitCount) / 64
        }
        let utc = precise == nil ? nil : a.metadata?.time.utcInstant.flatMap { a in b.metadata?.time.utcInstant.map { $0.timeIntervalSince(a) } }
        return AdjacentEvidence(fromID: a.id, toID: b.id, coarseLocalCameraSecondDifference: coarse,
            preciseLocalCameraGapSeconds: precise, utcGapSeconds: utc, timeStatus: timeStatus,
            normalizedLuminanceRMS: luma, colorHistogramL1: histogram, differenceHashHammingFraction: hash)
    }
    static func thresholds(_ pairs: [AdjacentEvidence], expectedCount: Int? = nil) -> [ThresholdEvidence] {
        EvidenceOptions.timeThresholdSeconds.map { threshold in
            let evaluable = pairs.compactMap(\.preciseLocalCameraGapSeconds).filter { $0 >= 0 }
            let retained = evaluable.filter { $0 <= threshold }.count
            return ThresholdEvidence(thresholdSeconds: threshold, retainedPairs: retained, evaluablePairs: evaluable.count,
                unknownPairs: max(pairs.count, expectedCount ?? pairs.count) - evaluable.count, rejectedPairs: evaluable.count - retained)
        }
    }
    private static func evaluateBoundaries(_ report: BurstEvidenceReport, labels: PositiveLabels,
        positives: [AdjacentEvidence], expectedPositiveCount: Int, names: [String: String]) -> [LabeledThresholdEvaluation]? {
        guard let boundaries = labels.negativeBoundaries, !boundaries.isEmpty else { return nil }
        let edges = Dictionary(uniqueKeysWithValues: report.adjacentPairs.map { ($0.fromID + ":" + $0.toID, $0) })
        let uniqueBoundaries = Set(boundaries.map { $0.from + "\u{0}" + $0.to })
        let negatives = boundaries.reduce(into: [String: AdjacentEvidence]()) { result, edge in
            if let a = names[edge.from], let b = names[edge.to], let evidence = edges[a + ":" + b] {
                result[edge.from + "\u{0}" + edge.to] = evidence
            }
        }.values
        let positiveGaps = positives.compactMap(\.preciseLocalCameraGapSeconds).filter { $0 >= 0 }
        let negativeGaps = negatives.compactMap(\.preciseLocalCameraGapSeconds).filter { $0 >= 0 }
        return EvidenceOptions.timeThresholdSeconds.map { threshold in
            let tp = positiveGaps.filter { $0 <= threshold }.count, fp = negativeGaps.filter { $0 <= threshold }.count
            let predicted = tp + fp
            return LabeledThresholdEvaluation(thresholdSeconds: threshold, truePositive: tp, falsePositive: fp,
                falseNegative: positiveGaps.count - tp, trueNegative: negativeGaps.count - fp,
                unknownPositive: expectedPositiveCount - positiveGaps.count, unknownNegative: uniqueBoundaries.count - negativeGaps.count,
                positiveRetention: expectedPositiveCount > 0 ? Double(tp) / Double(expectedPositiveCount) : nil,
                positiveRetentionWilson95: WilsonInterval.calculate(successes: tp, total: expectedPositiveCount),
                boundaryFalseMergeRate: negativeGaps.isEmpty ? nil : Double(fp) / Double(negativeGaps.count),
                boundaryFalseMergeWilson95: WilsonInterval.calculate(successes: fp, total: negativeGaps.count),
                precision: predicted > 0 ? Double(tp) / Double(predicted) : nil,
                precisionWilson95: WilsonInterval.calculate(successes: tp, total: predicted), zeroPredictions: predicted == 0)
        }
    }
    /// Labels are applied only after immutable source-order extraction and pair analysis have finished.
    static func evaluate(_ report: BurstEvidenceReport, labels: PositiveLabels) -> PositiveEvaluation {
        let groupedNames = Dictionary(grouping: report.frames, by: \.displayName)
        let names = groupedNames.compactMapValues { $0.count == 1 ? $0[0].id : nil }
        let labeledNames = Set(labels.groups.flatMap(\.files))
        let positiveEdges = Set(labels.groups.flatMap { group -> [String] in
            let ids = Set(group.files.compactMap { names[$0] })
            return report.adjacentPairs.filter { ids.contains($0.fromID) && ids.contains($0.toID) }.map { $0.fromID + ":" + $0.toID }
        })
        let positives = report.adjacentPairs.filter { positiveEdges.contains($0.fromID + ":" + $0.toID) }
        let expected = labels.groups.reduce(0) { $0 + max(0, Set($1.files).count - 1) }
        return PositiveEvaluation(role: labels.role ?? "positive-only", fixtureID: labels.fixture ?? "unnamed-positive-fixture",
            labeledGroups: labels.groups.count, labeledFramesInScope: labeledNames.filter { names[$0] != nil }.count,
            labeledFramesMissingFromReport: labeledNames.filter { groupedNames[$0] == nil }.count,
            ambiguousLabeledNames: labeledNames.filter { (groupedNames[$0]?.count ?? 0) > 1 }.count,
            knownPositiveAdjacentPairs: expected, observedPositiveAdjacentPairs: positives.count,
            thresholdRetention: thresholds(positives, expectedCount: expected),
            boundaryEvaluation: evaluateBoundaries(report, labels: labels, positives: positives, expectedPositiveCount: expected, names: names))
    }
}
