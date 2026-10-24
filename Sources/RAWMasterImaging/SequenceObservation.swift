import Foundation
import RAWMasterCore

public struct SequenceObservation: Sendable {
    public let input: SequenceAssetInput
    public let feature: SequenceFrameFeature?
    public let warnings: [String]
    public let spatialFeature: SequenceSpatialFeature?
    public let metadataBurstContext: SequenceMetadataBurstContext?
    public let pauseBridgeContext: SequencePauseBridgeContext?
    public init(input: SequenceAssetInput, feature: SequenceFrameFeature?, warnings: [String] = [], spatialFeature: SequenceSpatialFeature? = nil, metadataBurstContext: SequenceMetadataBurstContext? = nil, pauseBridgeContext: SequencePauseBridgeContext? = nil) {
        self.metadataBurstContext = metadataBurstContext; self.pauseBridgeContext = pauseBridgeContext
        self.input = input; self.feature = feature; self.warnings = warnings; self.spatialFeature = spatialFeature
    }
}

/// Deterministic, source-order clock eras. A matching camera model is deliberately irrelevant.
public struct SequenceObservationPreprocessor: Sendable {
    public static let version = "sequence-source-clock-v1"
    private let manifestFingerprint: String
    private var previous: (camera: String, time: SequenceTimeEvidence)?
    private var eraID: String?
    private var knownMake: String?
    private var knownModel: String?
    private var preciseHighWater: (second: Int64, nanosecond: Int)?
    public init(manifest: SequenceInputManifest) { manifestFingerprint = manifest.contentFingerprint }

    public mutating func make(entry: SequenceManifestEntry, evidence: SequenceCaptureEvidence?,
                              feature: SequenceFrameFeature?, barrier: SequenceReason? = nil, spatialFeature: SequenceSpatialFeature? = nil, metadataBurstContext: SequenceMetadataBurstContext? = nil, pauseBridgeContext: SequencePauseBridgeContext? = nil) -> SequenceObservation {
        var failure = barrier ?? entry.barrier
        var warnings: [String] = []
        func canonical(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text.lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
        let camera = entry.camera.partitionID(manifestFingerprint: manifestFingerprint)
        if camera == nil { failure = failure ?? .cameraIdentityUnknown }
        if previous?.camera != camera { knownMake = nil; knownModel = nil; preciseHighWater = nil }
        let make = canonical(evidence?.cameraMake), model = canonical(evidence?.cameraModel)
        if (knownMake != nil && make != nil && knownMake != make) || (knownModel != nil && model != nil && knownModel != model) {
            failure = failure ?? .assertionMismatch
            warnings.append("camera-metadata-contradicts-single-device-evidence")
        }
        if evidence?.time.isConsistent != true || evidence?.time.local == nil { failure = failure ?? .invalidTimestamp }
        if feature == nil { failure = failure ?? .missingEmbeddedPreview }
        if let previous, let camera, let time = evidence?.time, let currentLocal = time.local, let old = previous.time.local,
           previous.camera == camera {
            if time.offsetMinutes != previous.time.offsetMinutes { failure = failure ?? .invalidClockPartition }
            if currentLocal.civilSecond < old.civilSecond { failure = failure ?? .invalidClockPartition }
            if let high = preciseHighWater, let nano = currentLocal.nanosecond,
               currentLocal.civilSecond < high.second || (currentLocal.civilSecond == high.second && nano <= high.nanosecond) {
                failure = failure ?? .ambiguous
            }
        }
        if failure != nil {
            previous = nil; eraID = nil; knownMake = nil; knownModel = nil; preciseHighWater = nil
            return SequenceObservation(input: SequenceAssetInput(entry: entry, evidence: evidence, clock: nil, barrier: failure), feature: feature, warnings: warnings, spatialFeature: spatialFeature, metadataBurstContext: metadataBurstContext, pauseBridgeContext: pauseBridgeContext)
        }
        if previous?.camera != camera || eraID == nil { eraID = "\(camera!):era:\(entry.ordinal)" }
        if let local = evidence?.time.local, let nano = local.nanosecond { preciseHighWater = (local.civilSecond, nano) }
        knownMake = make ?? knownMake; knownModel = model ?? knownModel
        previous = (camera!, evidence!.time)
        return SequenceObservation(input: SequenceAssetInput(entry: entry, evidence: evidence,
            clock: SequenceClockPartition(id: eraID!, basis: .localCivil, derivationVersion: Self.version)), feature: feature, spatialFeature: spatialFeature, metadataBurstContext: metadataBurstContext, pauseBridgeContext: pauseBridgeContext)
    }
}

public struct SequenceDetectorConfiguration: Codable, Sendable, Equatable {
    public static let algorithmVersion = "sequence-local-anchor-cadence-dev-4"
    public static let policyVersion = "sequence-policy-dev-4"
    public var spatialExperiment: SequenceSpatialConfiguration? = nil
    public var metadataExperiment: SequenceMetadataExperimentConfiguration? = nil
    public var pauseBridgeExperiment: SequencePauseBridgeConfiguration? = nil
    public var memoryBudgetBytes = 64 * 1024 * 1024
    public var contextFrames = 12
    public var anchorCount = 3
    public var anchorStride = 8
    public var denseGapSeconds = 0.6
    public var maximumBridgeSeconds = 12.0
    public var bridgeSupportFrames = 3
    public var localHistogramLimit: Float = 0.16
    public var localLuminanceLimit: Float = 0.23
    public var localHashLimit: Float = 0.55
    public var localStructuralRescueFraction: Float = 0.5
    public var anchorHistogramLimit: Float = 0.35
    public var anchorLuminanceLimit: Float = 0.28
    public var anchorHashLimit: Float = 0.7
    public var intervalSceneHistogramLimit: Float = 0.55
    public var intervalSceneLuminanceLimit: Float = 0.3
    public var intervalSceneHashLimit: Float = 0.7
    public var bridgeHistogramLimit: Float = 0.23
    public var bridgeLuminanceLimit: Float = 0.26
    public var bridgeHashLimit: Float = 0.65
    public var bridgeStructuralRescueFraction: Float = 0.5
    public var minimumIntervalPeriod = 1.0
    public var maximumIntervalPeriod = 86_400.0
    public var minimumIntervalFrames = 4
    public var absoluteCadenceTolerance = 0.1
    public var relativeCadenceTolerance = 0.08
    public var maximumMissingFrames = 3
    public var maximumConsecutiveMissingGaps = 2
    public var maximumMissingFraction = 0.5
    public var maximumEpisodePausePeriods = 12.0
    public var maximumEpisodePauseSeconds = 3600.0
    public var maximumStartupPeriods = 3.0
    public init() {}
    public var fingerprint: String { get throws { try validate(); return try SequenceFingerprint.digest(self) } }
    public func versions(order: String) -> SequenceAnalysisVersions {
        SequenceAnalysisVersions(extractor: metadataExperiment?.runtimeExtractorVersion ?? SequenceCaptureReader.extractorVersion, feature: pauseBridgeExperiment != nil ? SequenceFrameFeature.version + "+metadata-focus-pause-v1" : metadataExperiment != nil ? SequenceFrameFeature.version + "+metadata-context-v1" : spatialExperiment == nil ? SequenceFrameFeature.version : SequenceFrameFeature.version + "+" + SequenceSpatialFeature.version,
            algorithm: pauseBridgeExperiment != nil ? "sequence-local-anchor-cadence-focus-pause-exp-1" : metadataExperiment != nil ? "sequence-local-anchor-cadence-metadata-exp-1" : spatialExperiment == nil ? Self.algorithmVersion : "sequence-local-anchor-cadence-spatial-exp-1",
            policy: pauseBridgeExperiment != nil ? "sequence-focus-pause-policy-exp-1" : metadataExperiment != nil ? "sequence-metadata-policy-exp-1" : spatialExperiment == nil ? Self.policyVersion : "sequence-spatial-policy-exp-1", order: order)
    }
    public func validate() throws {
        try spatialExperiment?.validate()
        try metadataExperiment?.validate()
        try pauseBridgeExperiment?.validate()
        if pauseBridgeExperiment != nil, metadataExperiment == nil || spatialExperiment != nil || bridgeSupportFrames != 3 {
            throw SequenceDetectorError.invalidConfiguration
        }
        guard spatialExperiment == nil || metadataExperiment == nil else { throw SequenceDetectorError.invalidConfiguration }
        if spatialExperiment != nil, bridgeSupportFrames != 3 { throw SequenceDetectorError.invalidConfiguration }
        let values = [denseGapSeconds, maximumBridgeSeconds, minimumIntervalPeriod, maximumIntervalPeriod,
            absoluteCadenceTolerance, relativeCadenceTolerance, maximumMissingFraction,
            maximumEpisodePausePeriods, maximumEpisodePauseSeconds, maximumStartupPeriods]
        guard (0...(64 * 1024 * 1024)).contains(memoryBudgetBytes), (4...64).contains(contextFrames),
              (2...8).contains(anchorCount), anchorStride > 0, (2...8).contains(bridgeSupportFrames),
              bridgeSupportFrames <= contextFrames, (4...contextFrames).contains(minimumIntervalFrames),
              minimumIntervalFrames <= 12,
              values.allSatisfy({ $0.isFinite && $0 > 0 }), maximumBridgeSeconds >= denseGapSeconds,
              minimumIntervalPeriod > denseGapSeconds, maximumIntervalPeriod >= minimumIntervalPeriod,
              relativeCadenceTolerance < 0.5, maximumMissingFraction < 1,
              (0...8).contains(maximumMissingFrames), (0...8).contains(maximumConsecutiveMissingGaps),
              [localStructuralRescueFraction, bridgeStructuralRescueFraction].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 0.5 }),
              [localHistogramLimit, localLuminanceLimit, localHashLimit, anchorHistogramLimit, anchorLuminanceLimit, anchorHashLimit,
               intervalSceneHistogramLimit, intervalSceneLuminanceLimit, intervalSceneHashLimit,
               bridgeHistogramLimit, bridgeLuminanceLimit, bridgeHashLimit].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }) else {
            throw SequenceDetectorError.invalidConfiguration
        }
    }
}
public enum SequenceDetectorError: Error { case invalidConfiguration, invalidOrder, stopped, finished, budgetExceeded, incompatibleToken, missingSpatialFeature, missingMetadataContext, missingPauseBridgeContext }
