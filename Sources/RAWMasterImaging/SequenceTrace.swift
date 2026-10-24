import Foundation
import RAWMasterCore

/// Diagnostics only. Neither the trace switch nor these limits participate in the analysis token.
public struct SequenceTraceLimits: Codable, Sendable, Equatable {
    public let maximumEvents: Int
    public let maximumBytes: Int
    public let maximumEventsPerFrame: Int
    public static let maximumEventBytes = 4096
    public init(maximumEvents: Int = 64_000, maximumBytes: Int = 32 * 1024 * 1024,
                maximumEventsPerFrame: Int = 512) {
        self.maximumEvents = min(64_000, max(0, maximumEvents))
        self.maximumBytes = min(32 * 1024 * 1024, max(0, maximumBytes))
        self.maximumEventsPerFrame = min(512, max(0, maximumEventsPerFrame))
    }
    public func validate() throws {
        guard (0...64_000).contains(maximumEvents), (0...(32 * 1024 * 1024)).contains(maximumBytes),
              (0...512).contains(maximumEventsPerFrame) else { throw SequenceTraceError.invalidLimits }
    }
    private enum CodingKeys: String, CodingKey { case maximumEvents, maximumBytes, maximumEventsPerFrame }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maximumEvents = try c.decode(Int.self, forKey: .maximumEvents)
        maximumBytes = try c.decode(Int.self, forKey: .maximumBytes)
        maximumEventsPerFrame = try c.decode(Int.self, forKey: .maximumEventsPerFrame)
        try validate()
    }
}
public enum SequenceTraceError: Error { case invalidLimits, invalidSpatialEvidence }

public struct SequenceTraceSummary: Codable, Sendable, Equatable {
    public let emittedEvents: Int
    public let droppedEvents: Int
    /// sorted-key JSON event plus one LF; an outer report/container is not included.
    public let encodedBytes: Int
    public let invalidEvents: Int
    public let incomplete: Bool
    init(emittedEvents: Int, droppedEvents: Int, encodedBytes: Int, invalidEvents: Int) {
        self.emittedEvents = emittedEvents; self.droppedEvents = droppedEvents
        self.encodedBytes = encodedBytes; self.invalidEvents = invalidEvents
        self.incomplete = droppedEvents > 0 || invalidEvents > 0
    }
}

public enum SequenceTraceStage: String, Codable, Sendable {
    case input, dense, local, anchor, scene, cadence, bridge, episode, startup, decision, output
}
public enum SequenceTraceReason: String, Codable, Sendable {
    case observed, inputBarrier, contextBarrier, runStarted, partitionBoundary
    case passed, uninformative, distanceLimit, exposureLimit, precisionLimit, gapLimit
    case nonPositiveGap, stepLimit, gapResidual, phaseConflict, missingRunLimit, missingFractionLimit, baseSupportLimit
    case burstSeed, intervalSeed, bridgePending, bridgeAccepted, bridgeRejected, runFlushed, emitted
    case cancelled, incompleteTail, budgetExceeded
    case structuralRescue, structuralRescueRejected, spatialSupported, spatialRejected
    case periodCertificateConflict
    case episodeStarted, episodeExtended, epochPending, epochAccepted, epochRejected
    case consensusConflict, weakConfirmed, startupAccepted, startupRejected, startupSpanLimit, pendingEvicted, closedLeft
}
public enum SequenceTraceAggregation: String, Codable, Sendable { case median, maximum }

/// All fields are bounded scalar values. No paths, IDs, labels or feature/pixel arrays enter a trace.
public struct SequenceTraceEvent: Codable, Sendable, Equatable {
    public static let version = "sequence-decision-trace-v3"
    public let ordinal: Int
    /// The consume call charged against the per-frame cap; a seed-fit may reference an earlier ordinal.
    public var processingOrdinal: Int?
    public var stage: SequenceTraceStage
    public var reason: SequenceTraceReason
    public var accepted: Bool
    public var rescueEligible: Bool?
    public var spatial: SequenceSpatialEvidence?
    public var spatialPurpose: SequenceSpatialDecisionPurpose?
    public var spatialFeatureVersion: String?
    public var spatialSupportedPairs: Int?
    public var spatialRowsSupported: Int?
    public var spatialColumnsSupported: Int?
    public var barrier: SequenceReason?
    public var referenceOrdinal: Int?
    public var runFirst: Int?
    public var runLast: Int?
    public var anchorIndex: Int?
    public var seedLength: Int?
    public var civilSecond: Int64?
    public var nanosecond: Int?
    public var subsecondDigits: Int?
    public var uncertaintySeconds: Double?
    public var gapSeconds: Double?
    public var exposureSeconds: Double?
    public var gapLimit: Double?
    public var histogram: Float?
    public var luminance: Float?
    public var hash: Float?
    public var histogramLimit: Float?
    public var luminanceLimit: Float?
    public var hashLimit: Float?
    public var histogramMargin: Float?
    public var luminanceMargin: Float?
    public var hashMargin: Float?
    public var periodSeconds: Double?
    public var steps: Int?
    public var cycle: Int?
    public var elapsedSeconds: Double?
    public var toleranceSeconds: Double?
    public var lowerPeriod: Double?
    public var upperPeriod: Double?
    public var proposedLowerPeriod: Double?
    public var proposedUpperPeriod: Double?
    public var missingFrames: Int?
    public var consecutiveMissingGaps: Int?
    public var baseSupports: Int?
    public var certificateLowerPeriod: Double?
    public var certificateUpperPeriod: Double?
    public var referencePeriod: Double?
    public var globalLowerPeriod: Double?
    public var globalUpperPeriod: Double?
    public var lowerGapBound: Double?
    public var upperGapBound: Double?
    public var metadataRescue: SequenceMetadataBurstDecision?
    public var metadataRuleVersion: String?
    public var aggregation: SequenceTraceAggregation?
    public var leftRepresentative0: Int?
    public var leftRepresentative1: Int?
    public var leftRepresentative2: Int?
    public var rightRepresentative0: Int?
    public var rightRepresentative1: Int?
    public var rightRepresentative2: Int?
    public var leftSupport: Int?
    public var rightSupport: Int?
    public init(ordinal: Int, stage: SequenceTraceStage, reason: SequenceTraceReason, accepted: Bool) {
        self.ordinal = ordinal; self.stage = stage; self.reason = reason; self.accepted = accepted
    }
    public func encodedJSONLine() throws -> Data {
        guard spatial?.isFinite ?? true else { throw SequenceTraceError.invalidSpatialEvidence }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self); data.append(10); return data
    }
    mutating func distances(_ distance: SequenceFeatureDistance, histogram h: Float, luminance l: Float, hash d: Float) {
        histogram = distance.histogram; luminance = distance.luminance; hash = distance.hash
        histogramLimit = h; luminanceLimit = l; hashLimit = d
        histogramMargin = h - distance.histogram; luminanceMargin = l - distance.luminance; hashMargin = d - distance.hash
    }
}

/// Thread-safe bounded delivery. A sink must stream or impose its own smaller storage budget.
/// Sink I/O failures belong to the diagnostic runner, never to the detector's classification state.
final class SequenceTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: SequenceTraceLimits
    private let sink: @Sendable (SequenceTraceEvent) -> Void
    private var frame: Int?
    private var frameEvents = 0
    private var emitted = 0
    private var dropped = 0
    private var bytes = 0
    private var invalid = 0
    init(limits: SequenceTraceLimits, sink: @escaping @Sendable (SequenceTraceEvent) -> Void) {
        self.limits = limits; self.sink = sink
    }
    func beginFrame(_ ordinal: Int) {
        lock.lock(); defer { lock.unlock() }
        if frame != ordinal { frame = ordinal; frameEvents = 0 }
    }
    var summary: SequenceTraceSummary {
        lock.lock(); defer { lock.unlock() }
        return SequenceTraceSummary(emittedEvents: emitted, droppedEvents: dropped, encodedBytes: bytes, invalidEvents: invalid)
    }
    func emit(_ event: SequenceTraceEvent) {
        lock.lock()
        guard emitted < limits.maximumEvents, frameEvents < limits.maximumEventsPerFrame else {
            dropped += 1; lock.unlock(); return
        }
        var delivered = event; delivered.processingOrdinal = frame
        guard let line = try? delivered.encodedJSONLine(), line.count <= SequenceTraceLimits.maximumEventBytes else {
            dropped += 1; invalid += 1; lock.unlock(); return
        }
        guard line.count <= limits.maximumBytes - bytes else { dropped += 1; lock.unlock(); return }
        emitted += 1; frameEvents += 1; bytes += line.count
        lock.unlock()
        sink(delivered)
    }
}
