import Foundation
import RAWMasterCore

private struct SequenceTimePoint: Sendable {
    let second: Int64
    let nanosecond: Int?
    let uncertainty: Double
    init(_ time: SequenceTimeEvidence) {
        second = time.local!.civilSecond; nanosecond = time.local!.nanosecond
        if nanosecond != nil { uncertainty = pow(10, -Double(min(9, time.subsecondDigits ?? 0))) }
        else { uncertainty = 1 }
    }
    func gap(since other: Self) -> Double {
        Double(second - other.second) + Double((nanosecond ?? 0) - (other.nanosecond ?? 0)) / 1e9
    }
}
private struct SequenceWorkingFrame: Sendable {
    let ordinal: Int
    let time: SequenceTimePoint
    let offset: Int?
    let exposure: Double?
    let make: String?
    let model: String?
    let camera: String
    let clock: SequenceClockPartition
    let feature: SequenceFrameFeature
    let contentHash: String
    var spatialFeature: SequenceSpatialFeature?
    let metadataBurstContext: SequenceMetadataBurstContext?
}

/// Streaming fixed-origin phase fit. Neither the origin nor its global constraints slide forward.
private struct SequenceCadence: Sendable {
    let origin: SequenceTimePoint
    var last: SequenceTimePoint
    var period: Double
    var lower: Double
    var upper: Double
    var cycle = 0
    var baseSupports = 0
    var skipped = 0
    var consecutiveMissing = 0
    var certificate: SequencePeriodInterval
    init(period: Double, first: SequenceTimePoint, configuration c: SequenceDetectorConfiguration) {
        self.origin = first; self.last = first; self.period = period
        lower = max(c.minimumIntervalPeriod, period * (1 - c.relativeCadenceTolerance))
        upper = min(c.maximumIntervalPeriod, period * (1 + c.relativeCadenceTolerance))
        certificate = SequencePeriodInterval(lower: lower, upper: upper)!
    }
    mutating func append(_ point: SequenceTimePoint, configuration c: SequenceDetectorConfiguration,
                         ordinal: Int = 0, referenceOrdinal: Int? = nil,
                         trace: ((SequenceTraceEvent) -> Void)? = nil) -> Bool {
        let gap = point.gap(since: last)
        var event: SequenceTraceEvent? = trace == nil ? nil : SequenceTraceEvent(ordinal: ordinal, stage: .cadence, reason: .passed, accepted: false)
        event?.referenceOrdinal = referenceOrdinal; event?.gapSeconds = gap
        event?.uncertaintySeconds = max(point.uncertainty, origin.uncertainty)
        event?.periodSeconds = period; event?.lowerPeriod = lower; event?.upperPeriod = upper
        func report(_ reason: SequenceTraceReason, accepted: Bool = false) {
            if var value = event { value.reason = reason; value.accepted = accepted; trace?(value) }
        }
        guard gap > 0, period >= 4 * max(point.uncertainty, origin.uncertainty) else {
            report(gap <= 0 ? .nonPositiveGap : .precisionLimit); return false
        }
        let ratio = gap / period
        guard ratio.isFinite, ratio < Double(c.maximumMissingFrames + 2) else { report(.stepLimit); return false }
        let steps = max(1, Int(ratio.rounded()))
        event?.steps = steps
        guard steps <= c.maximumMissingFrames + 1 else { report(.stepLimit); return false }
        let tolerance = max(c.absoluteCadenceTolerance, c.relativeCadenceTolerance * period)
        event?.toleranceSeconds = tolerance + point.uncertainty + last.uncertainty
        guard abs(gap - Double(steps) * period) <= tolerance + point.uncertainty + last.uncertainty else {
            report(.gapResidual); return false
        }
        let nextCycle = cycle + steps
        let elapsed = point.gap(since: origin)
        let phaseTolerance = tolerance + point.uncertainty + origin.uncertainty
        let nextLower = max(lower, (elapsed - phaseTolerance) / Double(nextCycle))
        let nextUpper = min(upper, (elapsed + phaseTolerance) / Double(nextCycle))
        let missingRun = steps > 1 ? consecutiveMissing + 1 : 0
        let missing = skipped + steps - 1
        event?.cycle = nextCycle; event?.elapsedSeconds = elapsed
        event?.proposedLowerPeriod = nextLower; event?.proposedUpperPeriod = nextUpper
        event?.missingFrames = missing; event?.consecutiveMissingGaps = missingRun
        guard nextLower <= nextUpper, missingRun <= c.maximumConsecutiveMissingGaps,
              Double(missing) / Double(nextCycle) <= c.maximumMissingFraction else {
            report(nextLower > nextUpper ? .phaseConflict : missingRun > c.maximumConsecutiveMissingGaps ? .missingRunLimit : .missingFractionLimit)
            return false
        }
        guard let nextCertificate = certificate.accepting(gap: gap, elapsed: elapsed, steps: steps, cycle: nextCycle,
            tolerance: tolerance, pointUncertainty: point.uncertainty, previousUncertainty: last.uncertainty,
            originUncertainty: origin.uncertainty) else { report(.periodCertificateConflict); return false }
        event?.certificateLowerPeriod = nextCertificate.lower; event?.certificateUpperPeriod = nextCertificate.upper
        certificate = nextCertificate
        lower = nextLower; upper = nextUpper; period = max(lower, min(upper, period))
        cycle = nextCycle; last = point; skipped = missing; consecutiveMissing = missingRun
        if steps == 1 { baseSupports += 1 }
        event?.baseSupports = baseSupports
        report(.passed, accepted: true)
        return true
    }
    static func fit(_ frames: [SequenceWorkingFrame], configuration c: SequenceDetectorConfiguration, minimumFrames: Int? = nil,
                    trace: ((SequenceTraceEvent) -> Void)? = nil) -> Self? {
        guard frames.count >= (minimumFrames ?? c.minimumIntervalFrames) else { return nil }
        let gaps = zip(frames.dropFirst(), frames).map { $0.time.gap(since: $1.time) }.filter { $0 > 0 }
        guard gaps.count == frames.count - 1 else { return nil }
        // Candidate count is bounded by contextFrames × (maximumMissingFrames + 1).
        let candidates = Set(gaps.flatMap { gap in (1...(c.maximumMissingFrames + 1)).map { gap / Double($0) } })
            .filter { $0 >= c.minimumIntervalPeriod && $0 <= c.maximumIntervalPeriod }.sorted(by: >)
        var best: Self?
        for candidate in candidates {
            var trial = Self(period: candidate, first: frames[0].time, configuration: c)
            var valid = true
            let rejected: ((SequenceTraceEvent) -> Void)? = trace.map { sink in
                { event in
                    if !event.accepted {
                        var value = event; value.seedLength = frames.count; value.runFirst = frames[0].ordinal
                        value.runLast = frames.last!.ordinal; sink(value)
                    }
                }
            }
            for frame in frames.dropFirst() {
                if !trial.append(frame.time, configuration: c, ordinal: frame.ordinal, trace: rejected) { valid = false; break }
            }
            if valid, let trace {
                var event = SequenceTraceEvent(ordinal: frames.last!.ordinal, stage: .cadence,
                    reason: trial.baseSupports >= 2 ? .passed : .baseSupportLimit, accepted: trial.baseSupports >= 2)
                event.runFirst = frames[0].ordinal; event.runLast = frames.last!.ordinal; event.seedLength = frames.count
                event.periodSeconds = trial.period; event.lowerPeriod = trial.lower; event.upperPeriod = trial.upper
                event.cycle = trial.cycle; event.baseSupports = trial.baseSupports; event.missingFrames = trial.skipped
                event.certificateLowerPeriod = trial.certificate.lower; event.certificateUpperPeriod = trial.certificate.upper
                trace(event)
            }
            if valid, trial.baseSupports >= 2,
               best == nil || trial.skipped < best!.skipped { best = trial }
        }
        return best
    }
}
private struct SequenceActiveRun: Sendable {
    var first: Int
    var last: Int
    let camera: String
    let clock: SequenceClockPartition
    var recent: [SequenceWorkingFrame]
    var anchors: [SequenceFrameFeature]
    var kind: SequenceKind?
    var cadence: SequenceCadence?
    var intervalConsensus: SequenceIntervalConsensus?
    var count: Int { last - first + 1 }
    init(_ frame: SequenceWorkingFrame) {
        first = frame.ordinal; last = frame.ordinal; camera = frame.camera; clock = frame.clock
        recent = [frame]; anchors = [frame.feature]
    }
    mutating func append(_ frame: SequenceWorkingFrame, configuration c: SequenceDetectorConfiguration) {
        last = frame.ordinal; recent.append(frame)
        let recentLimit = kind == nil ? 12 : c.contextFrames
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        let fixedSlots = kind == .interval ? 2 : 1
        if count % c.anchorStride == 0, c.anchorCount > fixedSlots {
            if anchors.count < c.anchorCount { anchors.append(frame.feature) }
            else { anchors.remove(at: fixedSlots); anchors.append(frame.feature) }
        }
    }
}
private struct SequencePreparedInterval: Sendable {
    let run: SequenceActiveRun
    let firstCadenceSupport: [SequenceWorkingFrame]
}
private struct SequenceRowCoverage: Sendable {
    var state: SequenceCoverageState
    var reasons: [SequenceReason]
}

/// Pure, serial consumer. This type owns no paths, database, labels or native decode permits.
public struct SequenceDetector: Sendable {
    public static var algorithmVersion: String { SequenceDetectorConfiguration.algorithmVersion }
    public let manifest: SequenceInputManifest
    public let token: SequenceAnalysisToken
    public let configuration: SequenceDetectorConfiguration
    /// Conservative engine-owned working/output allowance; excludes caller-owned manifest and framework/RSS allocations.
    public private(set) var managedPeakEstimateBytes = 0
    public private(set) var isStopped = false
    public private(set) var processedCount = 0
    public private(set) var metadataStatistics: SequenceMetadataBurstStatistics?
    private var finalized = false
    private let spatialMetrics: (@Sendable (SequenceSpatialMetricsEvent) -> Void)?
    public private(set) var spatialStatistics: SequenceSpatialStatistics?
    private var spatialCache: [SequenceSpatialCacheKey: SequenceSpatialEvidence] = [:]
    private var spatialCacheOrder: [SequenceSpatialCacheKey] = []
    private let spatialCacheNamespace: String?
    public var spatialManagedLiveBytes: Int {
        guard configuration.spatialExperiment != nil else { return 0 }
        let held = (active?.recent ?? []) + bridgeRight + intervalRight
        return held.reduce(0) { $0 + ($1.spatialFeature?.managedByteEstimate ?? 0) } + spatialCache.count * 1024
    }
    private let trace: SequenceTraceRecorder?
    public var traceSummary: SequenceTraceSummary? { trace?.summary }
    private var rows: [SequenceRowCoverage] = []
    private var detected: [SequenceDetectedRange] = []
    private var active: SequenceActiveRun?
    private var bridgeRight: [SequenceWorkingFrame] = []
    // The sole additional unproved interval FIFO. Left cadence/period stay frozen while awaiting it.
    private var intervalRight: [SequenceWorkingFrame] = []
    private var closedIntervalLast: Int?
    private static let intervalPendingCapacity = 12
    private var warnings: [String] = []
    private var observedCamera: String?
    private var observedClock: SequenceClockPartition?
    private var observedOffset: Int?
    private var observedSecond: Int64?
    private var preciseHighWater: (second: Int64, nanosecond: Int)?
    private var observedMake: String?
    private var observedModel: String?

    public init(manifest: SequenceInputManifest, token: SequenceAnalysisToken,
                configuration: SequenceDetectorConfiguration = .init(),
                trace observer: (@Sendable (SequenceTraceEvent) -> Void)? = nil,
                traceLimits: SequenceTraceLimits = .init(),
                spatialMetrics: (@Sendable (SequenceSpatialMetricsEvent) -> Void)? = nil) throws {
        try configuration.validate()
        let expected = try SequenceAnalysisToken.make(manifest: manifest, versions: token.versions,
            policyFingerprint: token.policyFingerprint, inputRevision: token.inputRevision,
            structureRevision: token.structureRevision, generation: token.generation)
        guard token == expected, token.policyFingerprint == (try configuration.fingerprint),
              token.versions == configuration.versions(order: manifest.orderVersion) else { throw SequenceDetectorError.incompatibleToken }
        self.manifest = manifest; self.token = token; self.configuration = configuration
        self.metadataStatistics = configuration.metadataExperiment == nil ? nil : SequenceMetadataBurstStatistics()
        self.trace = observer.map { SequenceTraceRecorder(limits: traceLimits, sink: $0) }
        self.spatialMetrics = spatialMetrics
        self.spatialStatistics = configuration.spatialExperiment == nil ? nil : SequenceSpatialStatistics()
        self.spatialCacheNamespace = configuration.spatialExperiment == nil ? nil : token.policyFingerprint + ":" + manifest.contentFingerprint
    }
    public mutating func cancel() {
        trace?.emit(SequenceTraceEvent(ordinal: processedCount, stage: .decision, reason: .cancelled, accepted: false))
        if !isStopped { warnings.append("cancelled-before-complete-result") }
        isStopped = true
        releaseSpatialBuffers()
    }
    private mutating func releaseSpatialBuffers() {
        guard configuration.spatialExperiment != nil else { return }
        if var run = active {
            for index in run.recent.indices { run.recent[index].spatialFeature = nil }
            active = run
        }
        for index in bridgeRight.indices { bridgeRight[index].spatialFeature = nil }
        for index in intervalRight.indices { intervalRight[index].spatialFeature = nil }
        spatialCache.removeAll(keepingCapacity: false); spatialCacheOrder.removeAll(keepingCapacity: false)
    }
    public mutating func consume(_ observation: SequenceObservation, cancelled: () -> Bool = { false }) throws {
        do { try consumeImpl(observation, cancelled: cancelled) }
        catch is CancellationError { if !isStopped { cancel() }; throw CancellationError() }
        catch {
            if configuration.spatialExperiment != nil { isStopped = true; releaseSpatialBuffers() }
            throw error
        }
    }
    private mutating func consumeImpl(_ observation: SequenceObservation, cancelled: () -> Bool) throws {
        guard !finalized else { throw SequenceDetectorError.finished }
        if Task.isCancelled || cancelled() { cancel(); throw CancellationError() }
        guard !isStopped else { throw SequenceDetectorError.stopped }
        guard observation.input.entry.ordinal == processedCount, processedCount < manifest.entries.count else {
            isStopped = true; warnings.append("invalid-input-order"); throw SequenceDetectorError.invalidOrder
        }
        if configuration.spatialExperiment != nil, observation.feature != nil, observation.spatialFeature == nil {
            isStopped = true; releaseSpatialBuffers(); throw SequenceDetectorError.missingSpatialFeature
        }
        if let metadata = configuration.metadataExperiment, observation.feature != nil,
           observation.input.validationIssues(manifest: manifest, versions: token.versions).isEmpty {
            guard observation.metadataBurstContext?.isBound(entry: observation.input.entry, configuration: metadata) == true else {
                isStopped = true; throw SequenceDetectorError.missingMetadataContext
            }
            metadataStatistics?.observedContexts += 1
        }
        trace?.beginFrame(observation.input.entry.ordinal)
        guard estimatedBytes(additionalRow: true) <= configuration.memoryBudgetBytes else {
            trace?.emit(SequenceTraceEvent(ordinal: observation.input.entry.ordinal, stage: .input, reason: .budgetExceeded, accepted: false))
            isStopped = true; warnings.append("managed-budget-exceeded"); throw SequenceDetectorError.budgetExceeded
        }
        if configuration.spatialExperiment != nil, observation.spatialFeature != nil { spatialStatistics?.observedSpatialFeatures += 1 }
        for warning in observation.warnings.prefix(8) where warnings.count < 32 {
            let bounded = String(warning.prefix(128))
            if !warnings.contains(bounded) { warnings.append(bounded) }
        }
        let input = observation.input
        if let trace {
            var event = SequenceTraceEvent(ordinal: input.entry.ordinal, stage: .input, reason: .observed, accepted: true)
            event.civilSecond = input.evidence?.time.local?.civilSecond
            event.nanosecond = input.evidence?.time.local?.nanosecond
            event.subsecondDigits = input.evidence?.time.subsecondDigits
            event.exposureSeconds = input.evidence?.exposureSeconds
            trace.emit(event)
        }
        var reasons = input.validationIssues(manifest: manifest, versions: token.versions)
        if observation.feature == nil, !reasons.contains(.missingEmbeddedPreview) { reasons.append(.missingEmbeddedPreview) }
        processedCount += 1
        if !reasons.isEmpty {
            if let trace {
                var event = SequenceTraceEvent(ordinal: input.entry.ordinal, stage: .input, reason: .inputBarrier, accepted: false)
                event.barrier = reasons.first; trace.emit(event)
            }
            try flush(cancelled: cancelled); resetObservedContext()
            let unreadable = reasons.contains(.unreadable) || reasons.contains(.missingEmbeddedPreview)
            let state: SequenceCoverageState = reasons.contains(.incomplete) ? .incomplete : unreadable ? .unreadable : .insufficient
            rows.append(SequenceRowCoverage(state: state, reasons: reasons))
        } else {
            func canonical(_ value: String?) -> String? {
                guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return text.lowercased(with: Locale(identifier: "en_US_POSIX"))
            }
            let frame = SequenceWorkingFrame(ordinal: input.entry.ordinal, time: SequenceTimePoint(input.evidence!.time),
                offset: input.evidence!.time.offsetMinutes, exposure: input.evidence!.exposureSeconds,
                make: canonical(input.evidence!.cameraMake), model: canonical(input.evidence!.cameraModel),
                camera: input.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint)!,
                clock: input.clock!, feature: observation.feature!, contentHash: input.entry.contentHash!,
                spatialFeature: configuration.spatialExperiment == nil ? nil : observation.spatialFeature,
                metadataBurstContext: configuration.metadataExperiment == nil ? nil : observation.metadataBurstContext)
            rows.append(SequenceRowCoverage(state: .insufficient, reasons: [.noSequenceSupport]))
            if let issue = contextIssue(for: frame) {
                if let trace {
                    var event = SequenceTraceEvent(ordinal: frame.ordinal, stage: .input, reason: .contextBarrier, accepted: false)
                    event.barrier = issue; trace.emit(event)
                }
                try flush(cancelled: cancelled); resetObservedContext()
                rows[frame.ordinal] = SequenceRowCoverage(state: .insufficient, reasons: [issue])
                if issue == .assertionMismatch {
                    let warning = "camera-metadata-contradicts-single-device-evidence"
                    if !warnings.contains(warning) { warnings.append(warning) }
                }
            } else {
                recordObservedContext(frame)
                try accept(frame, cancelled: cancelled)
            }
        }
        recordPeak()
        if Task.isCancelled || cancelled() { cancel(); throw CancellationError() }
    }
    public mutating func finish(sealedInputComplete: Bool = true, cancelled: () -> Bool = { false }) throws -> SequenceAnalysisResult {
        do { return try finishImpl(sealedInputComplete: sealedInputComplete, cancelled: cancelled) }
        catch is CancellationError { if !isStopped { cancel() }; throw CancellationError() }
    }
    private mutating func finishImpl(sealedInputComplete: Bool, cancelled: () -> Bool) throws -> SequenceAnalysisResult {
        guard !finalized else { throw SequenceDetectorError.finished }
        if Task.isCancelled || cancelled() { cancel() }
        if !sealedInputComplete || processedCount != manifest.entries.count {
            trace?.emit(SequenceTraceEvent(ordinal: processedCount, stage: .decision, reason: .incompleteTail, accepted: false))
            isStopped = true; warnings.append("sealed-input-tail-incomplete")
        }
        if isStopped {
            // A left interval boundary became closed when a genuine long pause started.
            // It is not retroactively invalidated by cancelling an unproved right tail.
            var closedThrough: Int?
            if let last = closedIntervalLast, let left = active {
                traceInterval(left, ordinal: last, reason: .closedLeft, accepted: true)
                emit(left, through: last); active = nil; closedThrough = last
            }
            let firstOpen = closedThrough.map { $0 + 1 } ?? active?.first ?? intervalRight.first?.ordinal ?? bridgeRight.first?.ordinal ?? processedCount
            if firstOpen < rows.count {
                for index in firstOpen..<rows.count { rows[index] = SequenceRowCoverage(state: .incomplete, reasons: [.incomplete]) }
            }
            active = nil; bridgeRight.removeAll(); intervalRight.removeAll()
        } else { try flush(cancelled: cancelled) }
        releaseSpatialBuffers()
        finalized = true
        var coverage: [SequenceCoverageRange] = []
        var start = 0
        while start < rows.count {
            var end = start
            while end + 1 < rows.count, rows[end + 1].state == rows[start].state, rows[end + 1].reasons == rows[start].reasons { end += 1 }
            coverage.append(SequenceCoverageRange(range: try SequenceOrdinalRange(first: start, last: end), state: rows[start].state, reasons: rows[start].reasons))
            start = end + 1
        }
        if processedCount < manifest.entries.count {
            coverage.append(SequenceCoverageRange(range: try SequenceOrdinalRange(first: processedCount, last: manifest.entries.count - 1), state: .incomplete, reasons: [.incomplete]))
        }
        let result = SequenceAnalysisResult(token: token, ranges: detected, coverage: coverage, warnings: warnings)
        try result.validateStructure(manifest: manifest, expectedToken: token)
        return result
    }
    private mutating func resetObservedContext() {
        observedCamera = nil; observedClock = nil; observedOffset = nil; observedSecond = nil
        preciseHighWater = nil; observedMake = nil; observedModel = nil
    }
    private mutating func contextIssue(for frame: SequenceWorkingFrame) -> SequenceReason? {
        if observedCamera != frame.camera || observedClock != frame.clock { resetObservedContext(); return nil }
        if (observedMake != nil && frame.make != nil && observedMake != frame.make)
            || (observedModel != nil && frame.model != nil && observedModel != frame.model) { return .assertionMismatch }
        if observedOffset != frame.offset { return .invalidClockPartition }
        if let previousSecond = observedSecond, frame.time.second < previousSecond { return .invalidClockPartition }
        if let high = preciseHighWater, let nano = frame.time.nanosecond,
           frame.time.second < high.second || (frame.time.second == high.second && nano <= high.nanosecond) { return .invalidClockPartition }
        return nil
    }
    private mutating func recordObservedContext(_ frame: SequenceWorkingFrame) {
        observedCamera = frame.camera; observedClock = frame.clock; observedOffset = frame.offset; observedSecond = frame.time.second
        if let nano = frame.time.nanosecond { preciseHighWater = (frame.time.second, nano) }
        observedMake = frame.make ?? observedMake; observedModel = frame.model ?? observedModel
    }
    private func estimatedBytes(additionalRow: Bool = false) -> Int {
        // Reserve peak feature capacity up front, including native-unit output. The row
        // allowance also covers worst-case ranges and finish's compact coverage output.
        let frames = configuration.contextFrames + configuration.anchorCount + configuration.bridgeSupportFrames
            + Self.intervalPendingCapacity + 2
        let legacy = SequenceCaptureReader.scratchReservationBytes + (rows.count + (additionalRow ? 1 : 0)) * 1_280
            + frames * (5_120 + (configuration.metadataExperiment == nil ? 0 : 512)) + 8_192
        guard configuration.spatialExperiment != nil else { return legacy }
        return legacy + frames * (114 * 1024) + 2 * 1024 * 1024
            + SequenceSpatialMatcher.scratchReservationBytes + 64 * 1024
    }
    private mutating func recordPeak() {
        managedPeakEstimateBytes = max(managedPeakEstimateBytes, estimatedBytes())
        if spatialStatistics != nil { spatialStatistics?.managedPeakEstimateBytes = managedPeakEstimateBytes }
    }
    private mutating func locallyRelated(_ a: SequenceWorkingFrame, _ b: SequenceWorkingFrame, cancelled: () -> Bool, allowMetadata: Bool) throws -> Bool {
        guard a.feature.isInformative, b.feature.isInformative else {
            trace?.emit(SequenceTraceEvent(ordinal: b.ordinal, stage: .local, reason: .uninformative, accepted: false)); return false
        }
        let d = a.feature.distance(to: b.feature)
        let accepted = d.histogram <= configuration.localHistogramLimit && d.luminance <= configuration.localLuminanceLimit && d.hash <= configuration.localHashLimit
        if let trace {
            var event = SequenceTraceEvent(ordinal: b.ordinal, stage: .local, reason: accepted ? .passed : .distanceLimit, accepted: accepted)
            event.referenceOrdinal = a.ordinal
            event.distances(d, histogram: configuration.localHistogramLimit, luminance: configuration.localLuminanceLimit, hash: configuration.localHashLimit)
            trace.emit(event)
        }
        if accepted { return true }
        // Only a lone sparse-hash veto can be rescued, with a stricter spatial check.
        let eligible = d.hash > configuration.localHashLimit
            && d.histogram <= configuration.localHistogramLimit && d.luminance <= configuration.localLuminanceLimit
        let strongLuminance = configuration.localStructuralRescueFraction * configuration.localLuminanceLimit
        let rescued = eligible && d.luminance <= strongLuminance && d.hash <= configuration.anchorHashLimit
        if let trace {
            var event = SequenceTraceEvent(ordinal: b.ordinal, stage: .local,
                reason: rescued ? .structuralRescue : .structuralRescueRejected, accepted: rescued)
            event.referenceOrdinal = a.ordinal; event.rescueEligible = eligible
            event.distances(d, histogram: configuration.localHistogramLimit, luminance: strongLuminance, hash: configuration.anchorHashLimit)
            trace.emit(event)
        }
        if rescued { return true }
        if allowMetadata, let metadata = configuration.metadataExperiment,
           d.histogram > configuration.localHistogramLimit, d.histogram <= configuration.anchorHistogramLimit,
           d.luminance <= configuration.localLuminanceLimit, d.hash <= configuration.localHashLimit {
            metadataStatistics?.rescueCandidates += 1
            let decision = SequenceMetadataBurstRule.decision(previous: a.metadataBurstContext, current: b.metadataBurstContext,
                gapSeconds: b.time.gap(since: a.time), denseGapSeconds: configuration.denseGapSeconds, policy: metadata.rescuePolicy)
            switch decision {
            case .continuation: metadataStatistics?.continuationRescues += 1
            case .shortRestart: metadataStatistics?.shortRestartRescues += 1
            case .unsupported: metadataStatistics?.rejectedContexts += 1
            }
            if let trace {
                var event = SequenceTraceEvent(ordinal: b.ordinal, stage: .local, reason: decision == .unsupported ? .structuralRescueRejected : .structuralRescue, accepted: decision != .unsupported)
                event.referenceOrdinal = a.ordinal; event.metadataRescue = decision
                event.metadataRuleVersion = SequenceMetadataExperimentConfiguration.version
                event.distances(d, histogram: configuration.anchorHistogramLimit, luminance: configuration.localLuminanceLimit, hash: configuration.localHashLimit)
                trace.emit(event)
            }
            if decision != .unsupported { return true }
        }
        guard configuration.spatialExperiment?.mode == .localRescueAndBridgeVeto,
              d.histogram > configuration.localHistogramLimit, d.histogram <= configuration.anchorHistogramLimit,
              d.luminance <= configuration.localLuminanceLimit, d.hash <= configuration.localHashLimit else { return false }
        return try spatialPair(a, b, purpose: .denseBurstLocal, cancelled: cancelled).verdict == .supported
    }
    private mutating func dense(_ a: SequenceWorkingFrame, _ b: SequenceWorkingFrame, cancelled: () -> Bool, allowMetadata: Bool = true) throws -> Bool {
        let gap = b.time.gap(since: a.time)
        let exposurePass = (a.exposure.map { $0 <= configuration.denseGapSeconds } ?? true)
            && (b.exposure.map { $0 <= configuration.denseGapSeconds } ?? true)
        let precisionPass = a.time.nanosecond != nil && b.time.nanosecond != nil
        let temporalPass = exposurePass && precisionPass && gap > 0 && gap <= configuration.denseGapSeconds
        let accepted = try temporalPass && locallyRelated(a, b, cancelled: cancelled, allowMetadata: allowMetadata)
        if let trace {
            let reason: SequenceTraceReason = !exposurePass ? .exposureLimit : !precisionPass ? .precisionLimit : !temporalPass ? .gapLimit : accepted ? .passed : .distanceLimit
            var event = SequenceTraceEvent(ordinal: b.ordinal, stage: .dense, reason: reason, accepted: accepted)
            event.referenceOrdinal = a.ordinal; event.gapSeconds = gap; event.gapLimit = configuration.denseGapSeconds
            event.uncertaintySeconds = max(a.time.uncertainty, b.time.uncertainty); event.exposureSeconds = b.exposure
            trace.emit(event)
        }
        return accepted
    }
    private func anchored(_ feature: SequenceFrameFeature, in run: SequenceActiveRun, ordinal: Int) -> Bool {
        run.anchors.enumerated().allSatisfy { index, anchor in
            let d = anchor.distance(to: feature)
            let accepted = d.histogram <= configuration.anchorHistogramLimit
                && d.luminance <= configuration.anchorLuminanceLimit && d.hash <= configuration.anchorHashLimit
            if let trace {
                var event = SequenceTraceEvent(ordinal: ordinal, stage: .anchor, reason: accepted ? .passed : .distanceLimit, accepted: accepted)
                event.runFirst = run.first; event.runLast = run.last; event.anchorIndex = index
                event.distances(d, histogram: configuration.anchorHistogramLimit, luminance: configuration.anchorLuminanceLimit, hash: configuration.anchorHashLimit)
                trace.emit(event)
            }
            return accepted
        }
    }
    private func strongSceneChange(_ a: SequenceWorkingFrame, _ b: SequenceWorkingFrame) -> Bool {
        let d = a.feature.distance(to: b.feature)
        let color = d.histogram > configuration.intervalSceneHistogramLimit
        let structure = d.hash > configuration.intervalSceneHashLimit
        let luminance = d.luminance > configuration.intervalSceneLuminanceLimit
        let changed = (color && (structure || luminance)) || (structure && luminance)
        if let trace {
            var event = SequenceTraceEvent(ordinal: max(a.ordinal, b.ordinal), stage: .scene, reason: changed ? .distanceLimit : .passed, accepted: !changed)
            event.referenceOrdinal = min(a.ordinal, b.ordinal)
            event.distances(d, histogram: configuration.intervalSceneHistogramLimit, luminance: configuration.intervalSceneLuminanceLimit, hash: configuration.intervalSceneHashLimit)
            trace.emit(event)
        }
        return changed
    }
    private mutating func accept(_ frame: SequenceWorkingFrame, cancelled: () -> Bool) throws {
        guard var run = active else {
            trace?.emit(SequenceTraceEvent(ordinal: frame.ordinal, stage: .decision, reason: .runStarted, accepted: true))
            active = SequenceActiveRun(frame); return
        }
        if run.camera != frame.camera || run.clock != frame.clock {
            trace?.emit(SequenceTraceEvent(ordinal: frame.ordinal, stage: .decision, reason: .partitionBoundary, accepted: false))
            try flush(cancelled: cancelled); active = SequenceActiveRun(frame); return
        }
        if !intervalRight.isEmpty {
            try acceptIntervalRight(frame, left: run, cancelled: cancelled)
            return
        }
        if !bridgeRight.isEmpty {
            if try !dense(bridgeRight.last!, frame, cancelled: cancelled, allowMetadata: false) {
                separateBridge(); try accept(frame, cancelled: cancelled); return
            }
            bridgeRight.append(frame)
            if bridgeRight.count >= configuration.bridgeSupportFrames {
                if try bridgeSupported(left: run, right: bridgeRight, burstSpatial: true, cancelled: cancelled) {
                    for right in bridgeRight { run.append(right, configuration: configuration) }
                    active = run; bridgeRight.removeAll()
                } else { separateBridge() }
            }
            return
        }
        let previous = run.recent.last!
        switch run.kind {
        case .burst:
            if try dense(previous, frame, cancelled: cancelled), anchored(frame.feature, in: run, ordinal: frame.ordinal) {
                run.append(frame, configuration: configuration); active = run
            } else {
                let gap = frame.time.gap(since: previous.time)
                if gap > configuration.denseGapSeconds, gap <= configuration.maximumBridgeSeconds,
                   run.count >= configuration.bridgeSupportFrames, frame.feature.isInformative {
                    if let trace {
                        var event = SequenceTraceEvent(ordinal: frame.ordinal, stage: .decision, reason: .bridgePending, accepted: false)
                        event.runFirst = run.first; event.runLast = run.last; event.gapSeconds = gap
                        event.gapLimit = configuration.maximumBridgeSeconds; event.leftSupport = run.recent.count; event.rightSupport = 1
                        trace.emit(event)
                    }
                    bridgeRight = [frame]
                } else { try flush(cancelled: cancelled); active = SequenceActiveRun(frame) }
            }
        case .interval:
            let scenePass = !strongSceneChange(previous, frame)
            if scenePass, var cadence = run.cadence,
               cadence.append(frame.time, configuration: configuration, ordinal: frame.ordinal,
                    referenceOrdinal: previous.ordinal, trace: trace.map { recorder in { recorder.emit($0) } }),
               let consensus = run.intervalConsensus?.accepting(cadence.certificate) {
                run.cadence = cadence; run.intervalConsensus = consensus
                run.append(frame, configuration: configuration); active = run
                traceInterval(run, ordinal: frame.ordinal, reason: .episodeExtended, accepted: true)
            } else if scenePass, pauseAllowed(left: run, right: frame) {
                intervalRight = [frame]; closedIntervalLast = run.last
                traceInterval(run, ordinal: frame.ordinal, reason: .epochPending, accepted: false)
            } else {
                traceInterval(run, ordinal: frame.ordinal, reason: .epochRejected, accepted: false)
                try flush(cancelled: cancelled); active = SequenceActiveRun(frame)
            }
        default:
            if try dense(previous, frame, cancelled: cancelled) {
                // Earlier unsupported seeds stay flat; no deleted intermediate rows are bridged.
                if let trace {
                    var event = SequenceTraceEvent(ordinal: frame.ordinal, stage: .decision, reason: .burstSeed, accepted: true)
                    event.runFirst = previous.ordinal; event.runLast = frame.ordinal; trace.emit(event)
                }
                var burst = SequenceActiveRun(previous); burst.kind = .burst
                burst.append(frame, configuration: configuration); active = burst
            } else {
                run.append(frame, configuration: configuration)
                let pending = Array(run.recent.suffix(Self.intervalPendingCapacity))
                if let seed = firstStableSeed(in: pending) {
                    if let prepared = try prepareInterval(seed: seed.frames, cadence: seed.cadence, pending: pending, cancelled: cancelled) {
                        active = prepared.run
                        traceInterval(prepared.run, ordinal: frame.ordinal, reason: .episodeStarted, accepted: true)
                    } else {
                        trace?.emit(SequenceTraceEvent(ordinal: frame.ordinal, stage: .episode, reason: .consensusConflict, accepted: false))
                        active = SequenceActiveRun(frame)
                    }
                    return
                }
                active = run
            }
        }
    }
    private func traceInterval(_ run: SequenceActiveRun, ordinal: Int, reason: SequenceTraceReason, accepted: Bool) {
        guard let trace else { return }
        var event = SequenceTraceEvent(ordinal: ordinal, stage: .episode, reason: reason, accepted: accepted)
        event.runFirst = run.first; event.runLast = run.last
        event.referencePeriod = run.intervalConsensus?.referencePeriod
        event.globalLowerPeriod = run.intervalConsensus?.feasible.lower
        event.globalUpperPeriod = run.intervalConsensus?.feasible.upper
        event.periodSeconds = run.cadence?.period
        event.certificateLowerPeriod = run.cadence?.certificate.lower
        event.certificateUpperPeriod = run.cadence?.certificate.upper
        trace.emit(event)
    }
    private func pauseAllowed(left: SequenceActiveRun, right: SequenceWorkingFrame) -> Bool {
        guard let cadence = left.cadence, let consensus = left.intervalConsensus,
              let last = left.recent.last else { return false }
        let gap = right.time.gap(since: last.time)
        let accepted = consensus.acceptsPause(gap: gap, leftPeriod: cadence.period,
            leftUncertainty: last.time.uncertainty, rightUncertainty: right.time.uncertainty, configuration: configuration)
        if let trace {
            var event = SequenceTraceEvent(ordinal: right.ordinal, stage: .episode,
                reason: accepted ? .epochPending : .epochRejected, accepted: accepted)
            event.referenceOrdinal = last.ordinal; event.gapSeconds = gap; event.periodSeconds = cadence.period
            event.referencePeriod = consensus.referencePeriod
            event.lowerGapBound = Double(configuration.maximumMissingFrames + 1) * cadence.period
                + max(configuration.absoluteCadenceTolerance, configuration.relativeCadenceTolerance * cadence.period)
                + last.time.uncertainty + right.time.uncertainty
            event.upperGapBound = min(configuration.maximumEpisodePausePeriods * consensus.referencePeriod, configuration.maximumEpisodePauseSeconds)
            trace.emit(event)
        }
        return accepted
    }
    private func firstStableSeed(in pending: [SequenceWorkingFrame]) -> (frames: [SequenceWorkingFrame], cadence: SequenceCadence)? {
        guard pending.count >= configuration.minimumIntervalFrames else { return nil }
        for length in stride(from: pending.count, through: configuration.minimumIntervalFrames, by: -1) {
            let suffix = Array(pending.suffix(length))
            let sceneContinuous = zip(suffix.dropFirst(), suffix).allSatisfy { !strongSceneChange($0, $1) }
            if sceneContinuous, let cadence = SequenceCadence.fit(suffix, configuration: configuration,
                trace: trace.map { recorder in { recorder.emit($0) } }) {
                if let trace {
                    var event = SequenceTraceEvent(ordinal: suffix.last!.ordinal, stage: .decision, reason: .intervalSeed, accepted: true)
                    event.runFirst = suffix[0].ordinal; event.runLast = suffix.last!.ordinal
                    event.seedLength = suffix.count; event.periodSeconds = cadence.period; trace.emit(event)
                }
                return (suffix, cadence)
            }
        }
        return nil
    }
    private mutating func prepareInterval(seed: [SequenceWorkingFrame], cadence: SequenceCadence,
                                 pending: [SequenceWorkingFrame], anchorConstraint: SequenceActiveRun? = nil, cancelled: () -> Bool) throws -> SequencePreparedInterval? {
        let initial: SequenceIntervalConsensus?
        if let left = anchorConstraint {
            // A right-hand fit cannot redefine the episode reference or relax an earlier bound.
            initial = left.intervalConsensus?.accepting(cadence.certificate)
        } else {
            initial = SequenceIntervalConsensus(referencePeriod: cadence.period, certificate: cadence.certificate,
                relativeTolerance: configuration.relativeCadenceTolerance)
        }
        guard let initial,
              let seedIndex = pending.firstIndex(where: { $0.ordinal == seed[0].ordinal }) else { return nil }
        var consensus = initial
        var firstCadenceIndex = seedIndex
        var firstSupport = Array(seed.prefix(3))
        var anchorRun = SequenceActiveRun(seed[0])
        anchorRun.anchors = anchorConstraint?.anchors ?? [seed[0].feature, seed[0].feature]
        var allowStartup = true
        // Each accepted weak segment points rightwards to this immutable stable seed.
        // No weak segment can establish or cyclically endorse another unproved segment.
        while firstCadenceIndex >= 3 {
            let earlier = Array(pending.prefix(firstCadenceIndex))
            var selected: (frames: [SequenceWorkingFrame], cadence: SequenceCadence)?
            for length in stride(from: earlier.count, through: 3, by: -1) {
                let candidate = Array(earlier.suffix(length))
                let sceneContinuous = zip(candidate.dropFirst(), candidate).allSatisfy { !strongSceneChange($0, $1) }
                if sceneContinuous, let fit = SequenceCadence.fit(candidate, configuration: configuration, minimumFrames: 3,
                    trace: trace.map { recorder in { recorder.emit($0) } }) {
                    selected = (candidate, fit); break
                }
            }
            guard let selected else { break }
            var left = SequenceActiveRun(selected.frames[0])
            left.kind = .interval; left.last = selected.frames.last!.ordinal
            left.recent = selected.frames; left.cadence = selected.cadence
            left.intervalConsensus = consensus; left.anchors = anchorRun.anchors
            guard let joined = consensus.accepting(selected.cadence.certificate) else {
                traceInterval(left, ordinal: seed.last!.ordinal, reason: .consensusConflict, accepted: false)
                allowStartup = false; break
            }
            guard pauseAllowed(left: left, right: firstSupport[0]),
                  selected.frames.allSatisfy({ anchored($0.feature, in: anchorRun, ordinal: $0.ordinal) }),
                  try bridgeSupported(left: left, right: firstSupport, supportCount: 3, cancelled: cancelled) else {
                traceInterval(left, ordinal: seed.last!.ordinal, reason: .epochRejected, accepted: false)
                allowStartup = false; break
            }
            consensus = joined; left.intervalConsensus = joined
            firstCadenceIndex -= selected.frames.count
            firstSupport = Array(selected.frames.prefix(3))
            traceInterval(left, ordinal: seed.last!.ordinal, reason: .weakConfirmed, accepted: true)
        }
        let firstCadence = pending[firstCadenceIndex]
        var start = firstCadenceIndex
        let stableRepresentatives = Array(seed.prefix(3))
        if allowStartup {
            while start > 0 {
                let earlier = pending[start - 1], next = pending[start]
                let span = firstCadence.time.gap(since: earlier.time)
                guard span >= 0, span <= configuration.maximumStartupPeriods * consensus.referencePeriod else {
                    if let trace {
                        var event = SequenceTraceEvent(ordinal: earlier.ordinal, stage: .startup, reason: .startupSpanLimit, accepted: false)
                        event.referenceOrdinal = firstCadence.ordinal; event.gapSeconds = span
                        event.gapLimit = configuration.maximumStartupPeriods * consensus.referencePeriod; trace.emit(event)
                    }
                    break
                }
                guard startupSupported(earlier, next, representatives: stableRepresentatives, anchorRun: anchorRun) else { break }
                start -= 1
            }
        }
        var run = SequenceActiveRun(pending[start])
        run.kind = .interval; run.cadence = cadence; run.intervalConsensus = consensus
        // Two immutable roles, even when both reference the same physical feature.
        run.anchors = [pending[start].feature, seed[0].feature]
        for frame in pending.dropFirst(start + 1) { run.append(frame, configuration: configuration) }
        return SequencePreparedInterval(run: run, firstCadenceSupport: firstSupport)
    }
    private func startupSupported(_ earlier: SequenceWorkingFrame, _ next: SequenceWorkingFrame,
                                  representatives: [SequenceWorkingFrame], anchorRun: SequenceActiveRun) -> Bool {
        guard representatives.count == 3, earlier.feature.isInformative, next.feature.isInformative else { return false }
        let distances = [earlier.feature.distance(to: next.feature)]
            + representatives.flatMap { [earlier.feature.distance(to: $0.feature), next.feature.distance(to: $0.feature)] }
        let h = distances.map(\.histogram).max()!, l = distances.map(\.luminance).max()!, d = distances.map(\.hash).max()!
        let luminanceLimit = configuration.bridgeStructuralRescueFraction * configuration.bridgeLuminanceLimit
        let ordinary = h <= configuration.bridgeHistogramLimit && l <= luminanceLimit && d <= configuration.bridgeHashLimit
        let rescueEligible = h > configuration.bridgeHistogramLimit && l <= luminanceLimit && d <= configuration.bridgeHashLimit
        let rescue = rescueEligible && h <= configuration.anchorHistogramLimit
        let distancePass = ordinary || rescue
        let accepted = distancePass && anchored(earlier.feature, in: anchorRun, ordinal: earlier.ordinal)
            && anchored(next.feature, in: anchorRun, ordinal: next.ordinal)
        if let trace {
            let rescuePath = h > configuration.bridgeHistogramLimit
            let reason: SequenceTraceReason = rescuePath
                ? (accepted ? .structuralRescue : .structuralRescueRejected)
                : (accepted ? .startupAccepted : .startupRejected)
            var event = SequenceTraceEvent(ordinal: earlier.ordinal, stage: .startup,
                reason: reason, accepted: accepted)
            event.referenceOrdinal = next.ordinal; event.aggregation = .maximum
            if rescuePath { event.rescueEligible = rescueEligible }
            event.rightRepresentative0 = representatives[0].ordinal; event.rightRepresentative1 = representatives[1].ordinal
            event.rightRepresentative2 = representatives[2].ordinal
            event.distances(SequenceFeatureDistance(luminance: l, histogram: h, hash: d),
                histogram: rescuePath ? configuration.anchorHistogramLimit : configuration.bridgeHistogramLimit,
                luminance: luminanceLimit, hash: configuration.bridgeHashLimit)
            trace.emit(event)
        }
        return accepted
    }
    private mutating func acceptIntervalRight(_ frame: SequenceWorkingFrame, left: SequenceActiveRun, cancelled: () -> Bool) throws {
        // An independently established dense burst must not be swallowed by an interval hypothesis.
        if let previous = intervalRight.last, try dense(previous, frame, cancelled: cancelled, allowMetadata: false) {
            try separateIntervalRight(cancelled: cancelled); try accept(frame, cancelled: cancelled); return
        }
        if intervalRight.count == Self.intervalPendingCapacity {
            let evicted = intervalRight.removeFirst()
            trace?.emit(SequenceTraceEvent(ordinal: evicted.ordinal, stage: .episode, reason: .pendingEvicted, accepted: false))
            emit(left); active = nil; closedIntervalLast = nil
            let pending = intervalRight; intervalRight.removeAll()
            for retained in pending { try accept(retained, cancelled: cancelled) }
            try accept(frame, cancelled: cancelled); return
        }
        intervalRight.append(frame)
        guard let seed = firstStableSeed(in: intervalRight) else { return }
        guard let right = try prepareInterval(seed: seed.frames, cadence: seed.cadence, pending: intervalRight, anchorConstraint: left, cancelled: cancelled) else {
            traceInterval(left, ordinal: frame.ordinal, reason: .consensusConflict, accepted: false)
            try separateIntervalRight(cancelled: cancelled); return
        }
        guard let certificate = right.run.intervalConsensus?.feasible,
              let combined = left.intervalConsensus?.accepting(certificate) else {
            traceInterval(left, ordinal: frame.ordinal, reason: .consensusConflict, accepted: false)
            try separateIntervalRight(cancelled: cancelled); return
        }
        guard right.run.first == intervalRight[0].ordinal,
              pauseAllowed(left: left, right: right.firstCadenceSupport[0]),
              right.firstCadenceSupport.allSatisfy({ anchored($0.feature, in: left, ordinal: $0.ordinal) }),
              anchored(right.run.anchors[0], in: left, ordinal: right.run.first),
              try bridgeSupported(left: left, right: right.firstCadenceSupport, supportCount: 3, cancelled: cancelled) else {
            traceInterval(left, ordinal: frame.ordinal, reason: .epochRejected, accepted: false)
            try separateIntervalRight(cancelled: cancelled); return
        }
        var joined = left
        joined.cadence = right.run.cadence; joined.intervalConsensus = combined
        for accepted in intervalRight { joined.append(accepted, configuration: configuration) }
        intervalRight.removeAll(); active = joined
        traceInterval(joined, ordinal: frame.ordinal, reason: .epochAccepted, accepted: true)
    }
    private mutating func separateIntervalRight(cancelled: () -> Bool) throws {
        if let left = active { emit(left) }
        active = nil; closedIntervalLast = nil
        let pending = intervalRight; intervalRight.removeAll()
        for frame in pending { try accept(frame, cancelled: cancelled) }
    }
    private mutating func bridgeSupported(left: SequenceActiveRun, right: [SequenceWorkingFrame], supportCount: Int? = nil, burstSpatial: Bool = false, cancelled: () -> Bool) throws -> Bool {
        let count = supportCount ?? configuration.bridgeSupportFrames
        let before = Array(left.recent.suffix(count))
        guard before.count == count,
              right.count >= count, right.allSatisfy({ anchored($0.feature, in: left, ordinal: $0.ordinal) }) else { return false }
        let distances = before.flatMap { a in right.map { a.feature.distance(to: $0.feature) } }
        func median(_ values: [Float]) -> Float { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        let h = median(distances.map(\.histogram)), l = median(distances.map(\.luminance)), d = median(distances.map(\.hash))
        let accepted = h <= configuration.bridgeHistogramLimit && l <= configuration.bridgeLuminanceLimit && d <= configuration.bridgeHashLimit
        if let trace {
            var event = SequenceTraceEvent(ordinal: right.last!.ordinal, stage: .bridge,
                reason: accepted ? .bridgeAccepted : .distanceLimit, accepted: accepted)
            event.runFirst = left.first; event.runLast = left.last; event.leftSupport = before.count; event.rightSupport = right.count
            event.aggregation = .median
            if before.count == 3 && right.count == 3 {
                event.leftRepresentative0 = before[0].ordinal; event.leftRepresentative1 = before[1].ordinal; event.leftRepresentative2 = before[2].ordinal
                event.rightRepresentative0 = right[0].ordinal; event.rightRepresentative1 = right[1].ordinal; event.rightRepresentative2 = right[2].ordinal
            }
            event.distances(SequenceFeatureDistance(luminance: l, histogram: h, hash: d),
                histogram: configuration.bridgeHistogramLimit, luminance: configuration.bridgeLuminanceLimit, hash: configuration.bridgeHashLimit)
            trace.emit(event)
        }
        if accepted { return try !burstSpatial || spatialBridge(before, right, cancelled: cancelled) }
        // All global anchors and both dense support windows were checked above.
        // Only the histogram may exceed its ordinary bridge limit.
        let eligible = h > configuration.bridgeHistogramLimit
            && l <= configuration.bridgeLuminanceLimit && d <= configuration.bridgeHashLimit
        let strongLuminance = configuration.bridgeStructuralRescueFraction * configuration.bridgeLuminanceLimit
        let rescued = eligible && l <= strongLuminance && h <= configuration.anchorHistogramLimit
        if let trace {
            var event = SequenceTraceEvent(ordinal: right.last!.ordinal, stage: .bridge,
                reason: rescued ? .structuralRescue : .structuralRescueRejected, accepted: rescued)
            event.runFirst = left.first; event.runLast = left.last; event.leftSupport = before.count; event.rightSupport = right.count
            event.rescueEligible = eligible; event.aggregation = .median
            if before.count == 3 && right.count == 3 {
                event.leftRepresentative0 = before[0].ordinal; event.leftRepresentative1 = before[1].ordinal; event.leftRepresentative2 = before[2].ordinal
                event.rightRepresentative0 = right[0].ordinal; event.rightRepresentative1 = right[1].ordinal; event.rightRepresentative2 = right[2].ordinal
            }
            event.distances(SequenceFeatureDistance(luminance: l, histogram: h, hash: d),
                histogram: configuration.anchorHistogramLimit, luminance: strongLuminance, hash: configuration.bridgeHashLimit)
            trace.emit(event)
        }
        guard rescued else { return false }
        return try !burstSpatial || spatialBridge(before, right, cancelled: cancelled)
    }
    private mutating func spatialPair(_ first: SequenceWorkingFrame, _ second: SequenceWorkingFrame,
                                      purpose: SequenceSpatialDecisionPurpose, cancelled: () -> Bool) throws -> SequenceSpatialEvidence {
        try checkSpatialCancellation(cancelled)
        guard let spatial = configuration.spatialExperiment, let a = first.spatialFeature, let b = second.spatialFeature,
              let namespace = spatialCacheNamespace, first.ordinal < second.ordinal else { throw SequenceDetectorError.missingSpatialFeature }
        let key = SequenceSpatialCacheKey(source: first.ordinal, target: second.ordinal, sourceHash: first.contentHash,
            targetHash: second.contentHash, namespace: namespace)
        spatialStatistics?.pairRequests += 1
        let start = spatialMetrics == nil ? nil : DispatchTime.now().uptimeNanoseconds
        let evidence: SequenceSpatialEvidence, hit: Bool
        if let cached = spatialCache[key] {
            evidence = cached; hit = true; spatialStatistics?.cacheHits += 1
            spatialCacheOrder.removeAll { $0 == key }; spatialCacheOrder.append(key)
        } else {
            spatialStatistics?.pairComputations += 1
            evidence = try SequenceSpatialMatcher.compare(a, b, configuration: spatial, cancelled: cancelled); hit = false
            try checkSpatialCancellation(cancelled)
            if spatialCacheOrder.count == 64 { spatialCache.removeValue(forKey: spatialCacheOrder.removeFirst()) }
            spatialCache[key] = evidence; spatialCacheOrder.append(key)
            spatialStatistics?.coarseCandidates += evidence.coarseCandidates
            spatialStatistics?.fineCandidates += evidence.fineCandidates
            spatialStatistics?.patchCandidates += evidence.patchCandidates
            let previousMaximum = spatialStatistics?.maximumCandidatesPerPair ?? 0
            spatialStatistics?.maximumCandidatesPerPair = max(previousMaximum, evidence.candidateCount)
        }
        switch evidence.verdict {
        case .supported: spatialStatistics?.supportedPairs += 1
        case .rejected: spatialStatistics?.rejectedPairs += 1
        case .insufficient: spatialStatistics?.insufficientPairs += 1
        }
        recordPeak()
        if let observer = spatialMetrics, let start {
            observer(SequenceSpatialMetricsEvent(referenceOrdinal: first.ordinal, ordinal: second.ordinal, purpose: purpose,
                durationSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, cacheHit: hit,
                verdict: evidence.verdict, managedLiveBytes: spatialManagedLiveBytes, managedPeakBytes: managedPeakEstimateBytes,
                scratchReservedBytes: SequenceSpatialMatcher.scratchReservationBytes, candidateCount: hit ? 0 : evidence.candidateCount,
                evidence: evidence))
        }
        if let trace {
            var event = SequenceTraceEvent(ordinal: second.ordinal, stage: purpose == .denseBurstLocal ? .local : .bridge,
                reason: evidence.verdict == .supported ? .spatialSupported : .spatialRejected, accepted: evidence.verdict == .supported)
            event.referenceOrdinal = first.ordinal; event.spatial = evidence; event.spatialPurpose = purpose
            event.spatialFeatureVersion = SequenceSpatialFeature.version; trace.emit(event)
        }
        try checkSpatialCancellation(cancelled)
        return evidence
    }
    private mutating func spatialBridge(_ left: [SequenceWorkingFrame], _ right: [SequenceWorkingFrame], cancelled: () -> Bool) throws -> Bool {
        guard configuration.spatialExperiment != nil else { return true }
        // The experiment is defined for the frozen three-by-three support, never a best subset.
        guard left.count == 3, right.count == 3 else { return false }
        var rows = [Int](repeating: 0, count: 3), columns = rows, supported = 0
        for row in 0..<3 { for column in 0..<3 {
            let value = try spatialPair(left[row], right[column], purpose: .burstPauseBridge, cancelled: cancelled)
            if value.verdict == .supported { supported += 1; rows[row] += 1; columns[column] += 1 }
        } }
        let accepted = supported >= 6 && rows.allSatisfy { $0 > 0 } && columns.allSatisfy { $0 > 0 }
        if let trace {
            var event = SequenceTraceEvent(ordinal: right[2].ordinal, stage: .bridge,
                reason: accepted ? .spatialSupported : .spatialRejected, accepted: accepted)
            event.referenceOrdinal = left[2].ordinal; event.spatialPurpose = .burstPauseBridge
            event.spatialFeatureVersion = SequenceSpatialFeature.version; event.spatialSupportedPairs = supported
            event.spatialRowsSupported = rows.filter { $0 > 0 }.count; event.spatialColumnsSupported = columns.filter { $0 > 0 }.count
            trace.emit(event)
        }
        return accepted
    }
    private mutating func emit(_ run: SequenceActiveRun, through closedLast: Int? = nil) {
        let last = closedLast ?? run.last
        guard let kind = run.kind, last - run.first + 1 >= (kind == .interval ? configuration.minimumIntervalFrames : 2) else { return }
        let range = try! SequenceOrdinalRange(first: run.first, last: last)
        if let trace {
            var event = SequenceTraceEvent(ordinal: last, stage: .output, reason: .emitted, accepted: true)
            event.runFirst = run.first; event.runLast = last; trace.emit(event)
        }
        detected.append(SequenceDetectedRange(range: range, kind: kind, cameraPartitionID: run.camera,
            clockPartitionID: run.clock.id, reasons: kind == .burst ? ["local-continuity", "bounded-anchors"] : ["cadence", "fixed-origin-phase"]))
        for index in run.first...last { rows[index] = SequenceRowCoverage(state: .complete, reasons: []) }
    }
    private mutating func separateBridge() {
        trace?.emit(SequenceTraceEvent(ordinal: bridgeRight.last?.ordinal ?? processedCount, stage: .decision, reason: .bridgeRejected, accepted: false))
        if let active { emit(active) }
        active = nil
        if let first = bridgeRight.first {
            var right = SequenceActiveRun(first)
            if bridgeRight.count >= 2 { right.kind = .burst }
            for frame in bridgeRight.dropFirst() { right.append(frame, configuration: configuration) }
            active = right
        }
        bridgeRight.removeAll()
    }
    private mutating func flush(cancelled: () -> Bool) throws {
        trace?.emit(SequenceTraceEvent(ordinal: processedCount > 0 ? processedCount - 1 : 0, stage: .decision, reason: .runFlushed, accepted: true))
        if let active { emit(active) }
        active = nil
        let pendingInterval = intervalRight
        intervalRight.removeAll(); closedIntervalLast = nil
        if let first = bridgeRight.first {
            var right = SequenceActiveRun(first)
            if bridgeRight.count >= 2 { right.kind = .burst }
            for frame in bridgeRight.dropFirst() { right.append(frame, configuration: configuration) }
            emit(right)
        }
        bridgeRight.removeAll()
        if !pendingInterval.isEmpty {
            for frame in pendingInterval { try accept(frame, cancelled: cancelled) }
            try flush(cancelled: cancelled)
        }
    }
}
