import Foundation
import RAWMasterImaging

enum ProbeMeasurementStage: String, Codable, Sendable {
    case nativeRead, spatialExtraction, engineConsume, engineFinish, spatialPair
}
struct ProbeSpatialMeasurement: Codable, Sendable {
    let referenceOrdinal, ordinal: Int
    let purpose: SequenceSpatialDecisionPurpose
    let durationSeconds: Double
    let cacheHit: Bool
    let verdict: SequenceSpatialVerdict
    let managedLiveBytes, managedPeakBytes, scratchReservedBytes, candidateCount: Int
    init(_ value: SequenceSpatialMetricsEvent) {
        referenceOrdinal = value.referenceOrdinal; ordinal = value.ordinal; purpose = value.purpose
        durationSeconds = value.durationSeconds; cacheHit = value.cacheHit; verdict = value.verdict
        managedLiveBytes = value.managedLiveBytes; managedPeakBytes = value.managedPeakBytes
        scratchReservedBytes = value.scratchReservedBytes; candidateCount = value.candidateCount
    }
}
struct ProbeMeasurement: Codable, Sendable {
    let stage: ProbeMeasurementStage
    let ordinal: Int?
    let referenceOrdinal: Int?
    let durationSeconds: Double
    let spatial: ProbeSpatialMeasurement?
    init(stage: ProbeMeasurementStage, ordinal: Int? = nil, referenceOrdinal: Int? = nil,
         durationSeconds: Double, spatial: ProbeSpatialMeasurement? = nil) {
        self.stage = stage; self.ordinal = ordinal; self.referenceOrdinal = referenceOrdinal
        self.durationSeconds = durationSeconds; self.spatial = spatial
    }
}
