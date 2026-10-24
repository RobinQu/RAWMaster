import Foundation

public enum SequenceSpatialDecisionPurpose: String, Codable, Sendable { case denseBurstLocal, burstPauseBridge }
public struct SequenceSpatialStatistics: Codable, Sendable, Equatable {
    public internal(set) var observedSpatialFeatures = 0
    public internal(set) var pairRequests = 0
    public internal(set) var pairComputations = 0
    public internal(set) var cacheHits = 0
    public internal(set) var supportedPairs = 0
    public internal(set) var rejectedPairs = 0
    public internal(set) var insufficientPairs = 0
    public internal(set) var coarseCandidates = 0
    public internal(set) var fineCandidates = 0
    public internal(set) var patchCandidates = 0
    public internal(set) var maximumCandidatesPerPair = 0
    public internal(set) var managedPeakEstimateBytes = 0
}
public struct SequenceSpatialMetricsEvent: Sendable {
    public let referenceOrdinal: Int
    public let ordinal: Int
    public let purpose: SequenceSpatialDecisionPurpose
    public let durationSeconds: Double
    public let cacheHit: Bool
    public let verdict: SequenceSpatialVerdict
    public let managedLiveBytes: Int
    public let managedPeakBytes: Int
    public let scratchReservedBytes: Int
    public let candidateCount: Int
    public let evidence: SequenceSpatialEvidence
}
struct SequenceSpatialCacheKey: Hashable, Sendable {
    let source: Int, target: Int
    let sourceHash: String, targetHash: String, namespace: String
}
