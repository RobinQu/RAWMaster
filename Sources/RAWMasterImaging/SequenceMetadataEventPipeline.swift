import Foundation
import RAWMasterCore

public struct SequenceMetadataEventAnalysis: Sendable {
    public let manifest: SequenceInputManifest
    public let result: SequenceAnalysisResult
    public let observations: [SequenceAssetInput]
    public let featuresAvailable: [Bool]
    public let map: SequenceCaptureEventMap
    public let configuration: SequenceDetectorConfiguration
    public let eventManifest: SequenceInputManifest
    public let eventResult: SequenceAnalysisResult
    public let metadataStatistics: SequenceMetadataBurstStatistics?
    public let managedPeakEstimateBytes: Int
    public let analysisSeconds: Double
    public var associationHypothesisAssumed: Bool { map.associationHypothesisAssumed }
    public init(manifest: SequenceInputManifest, result: SequenceAnalysisResult, observations: [SequenceAssetInput],
                featuresAvailable: [Bool], map: SequenceCaptureEventMap, configuration: SequenceDetectorConfiguration,
                eventManifest: SequenceInputManifest, eventResult: SequenceAnalysisResult,
                metadataStatistics: SequenceMetadataBurstStatistics?, managedPeakEstimateBytes: Int, analysisSeconds: Double) {
        self.manifest = manifest; self.result = result; self.observations = observations; self.featuresAvailable = featuresAvailable
        self.map = map; self.configuration = configuration; self.eventManifest = eventManifest; self.eventResult = eventResult
        self.metadataStatistics = metadataStatistics; self.managedPeakEstimateBytes = managedPeakEstimateBytes; self.analysisSeconds = analysisSeconds
    }
}
public enum SequenceMetadataEventPipeline {
    public static let clockVersion = "event-clock-with-historical-offset-v1"
    struct Prepared {
        let eventManifest: SequenceInputManifest
        let eventObservations: [SequenceObservation]
        let fileObservations: [SequenceAssetInput]
    }
    static func prepare(files: [SequenceCaptureFileInput], manifest: SequenceInputManifest, metadata: SequenceMetadataSnapshot,
                        map: SequenceCaptureEventMap, cancelled: () -> Bool) throws -> Prepared {
        let firstEntries = map.events.map { event -> SequenceManifestEntry in
            let file = files[event.members.first(where: { $0.assetID == event.representativeAssetID })!.ordinal]
            let issue = event.members.compactMap { SequenceCaptureEvents.fileIssue(files[$0.ordinal]) }.first
            return SequenceManifestEntry(assetID: file.entry.assetID, ordinal: event.eventOrdinal,
                contentHash: file.entry.contentHash, evidenceRevision: file.entry.evidenceRevision, barrier: issue)
        }
        let scope = manifest.scopeID + "/capture-events"
        let order = manifest.orderVersion + "+capture-events-v1"
        let initial = try SequenceInputManifest(scopeID: scope, sessionID: manifest.sessionID, orderVersion: order, entries: firstEntries)
        let bound = firstEntries.map { entry -> SequenceManifestEntry in
            let original = files[map.events[entry.ordinal].members.first(where: { $0.assetID == entry.assetID })!.ordinal].entry
            let camera: SequenceCameraEvidence
            switch original.camera {
            case .unknown: camera = .unknown
            case .verifiedDevice: camera = original.camera // retain an existing proof; never mint one from an audit candidate
            case .manifestAssertion(let id, let revision, let parent):
                camera = parent == manifest.contentFingerprint
                    ? .manifestAssertion(id: "event-subset:"+id+":parent:"+parent, revision: revision, manifestFingerprint: initial.contentFingerprint)
                    : .unknown
            }
            return SequenceManifestEntry(assetID: entry.assetID, ordinal: entry.ordinal, contentHash: entry.contentHash,
                evidenceRevision: entry.evidenceRevision, camera: camera, barrier: entry.barrier)
        }
        let eventManifest = try SequenceInputManifest(scopeID: scope, sessionID: manifest.sessionID, orderVersion: order, entries: bound)
        var preprocessor = SequenceObservationPreprocessor(manifest: eventManifest)
        var eventObservations: [SequenceObservation] = []
        var fileObservations: [SequenceAssetInput] = []
        var previousCamera: String?, previousOffset: Int?, hasPreviousOffset = false
        var highWaterSecond: Int64?, highWaterNanos: Int?
        for event in map.events {
            try SequenceCaptureEvents.checkCancellation(cancelled)
            let file = files[event.members.first(where: { $0.assetID == event.representativeAssetID })!.ordinal]
            let originalTime = file.metadata.originalCapture.time
            let camera = file.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint)
            var barrier = eventManifest.entries[event.eventOrdinal].barrier
            if previousCamera != camera { hasPreviousOffset = false; highWaterSecond = nil; highWaterNanos = nil }
            if hasPreviousOffset && previousOffset != originalTime.offsetMinutes { barrier = barrier ?? .invalidClockPartition }
            if let local = originalTime.local {
                if let high = highWaterSecond, local.civilSecond < high { barrier = barrier ?? .invalidClockPartition }
                if highWaterSecond == local.civilSecond {
                    if let nano = local.nanosecond, let high = highWaterNanos {
                        if nano <= high { barrier = barrier ?? .ambiguous }
                    } else { barrier = barrier ?? .ambiguous }
                }
                if highWaterSecond != local.civilSecond { highWaterSecond = local.civilSecond; highWaterNanos = nil }
                if let nano = local.nanosecond { highWaterNanos = max(highWaterNanos ?? nano, nano) }
            }
            previousCamera = camera; previousOffset = originalTime.offsetMinutes; hasPreviousOffset = true
            let observed = preprocessor.make(entry: eventManifest.entries[event.eventOrdinal], evidence: file.currentEvidence,
                feature: file.feature, barrier: barrier,
                metadataBurstContext: SequenceMetadataBurstContext.make(file: file, snapshot: metadata))
            eventObservations.append(observed)
            for member in event.members {
                let item = files[member.ordinal]
                fileObservations.append(SequenceAssetInput(entry: item.entry, evidence: item.currentEvidence,
                    clock: observed.input.clock, barrier: observed.input.barrier ?? SequenceCaptureEvents.fileIssue(item)))
            }
        }
        return Prepared(eventManifest: eventManifest, eventObservations: eventObservations, fileObservations: fileObservations)
    }
    public static func analyze(files: [SequenceCaptureFileInput], manifest: SequenceInputManifest,
                               metadata: SequenceMetadataSnapshot, confirmedPairs: [SequenceConfirmedCapturePair] = [],
                               associationPolicy: SequenceAssociationPolicy, rescuePolicy: SequenceMetadataRescuePolicy,
                               baseConfiguration: SequenceDetectorConfiguration = .init(),
                               trace: (@Sendable (SequenceTraceEvent) -> Void)? = nil,
                               cancelled: () -> Bool = { false }) throws -> SequenceMetadataEventAnalysis {
        let start = ProcessInfo.processInfo.systemUptime
        guard baseConfiguration.spatialExperiment == nil, baseConfiguration.metadataExperiment == nil else {
            throw SequenceMetadataError.invalid("Metadata pipeline requires an unmodified nonspatial base configuration")
        }
        let map = try SequenceCaptureEvents.make(files: files, manifest: manifest, metadata: metadata,
            confirmedPairs: confirmedPairs, policy: associationPolicy, cancelled: cancelled)
        var configuration = baseConfiguration
        configuration.metadataExperiment = SequenceMetadataExperimentConfiguration(associationPolicy: associationPolicy,
            rescuePolicy: rescuePolicy, auditSeal: metadata.auditSeal, snapshotFingerprint: metadata.fingerprint,
            eventMapFingerprint: map.fingerprint)
        try configuration.validate()
        let prepared = try prepare(files: files, manifest: manifest, metadata: metadata, map: map, cancelled: cancelled)
        let token = try SequenceAnalysisToken.make(manifest: prepared.eventManifest,
            versions: configuration.versions(order: prepared.eventManifest.orderVersion), policyFingerprint: configuration.fingerprint)
        var detector = try SequenceDetector(manifest: prepared.eventManifest, token: token, configuration: configuration, trace: trace)
        for observation in prepared.eventObservations { try detector.consume(observation, cancelled: cancelled) }
        let eventResult = try detector.finish(cancelled: cancelled)
        try eventResult.validate(manifest: prepared.eventManifest, expectedToken: token,
            observations: prepared.eventObservations.map(\.input))
        let fileToken = try SequenceAnalysisToken.make(manifest: manifest, versions: configuration.versions(order: manifest.orderVersion),
            policyFingerprint: configuration.fingerprint)
        var coverage: [SequenceCoverageRange] = []
        for part in eventResult.coverage {
            let first = map.events[part.range.first].members[0].ordinal
            let last = map.events[part.range.last].members.last!.ordinal
            coverage.append(SequenceCoverageRange(range: try SequenceOrdinalRange(first: first, last: last), state: part.state, reasons: part.reasons))
        }
        let ranges = try eventResult.ranges.map { group -> SequenceDetectedRange in
            let first = map.events[group.range.first].members[0].ordinal
            let last = map.events[group.range.last].members.last!.ordinal
            guard let camera = manifest.entries[first].camera.partitionID(manifestFingerprint: manifest.contentFingerprint) else {
                throw SequenceMetadataError.invalid("Projected group lost its original camera proof")
            }
            return SequenceDetectedRange(range: try SequenceOrdinalRange(first: first, last: last), kind: group.kind,
                cameraPartitionID: camera, clockPartitionID: group.clockPartitionID, reasons: group.reasons + ["capture-event-projection-v1"])
        }
        let result = SequenceAnalysisResult(token: fileToken, ranges: ranges, coverage: coverage,
            warnings: eventResult.warnings + (map.associationHypothesisAssumed ? ["Association hypothesis assumed; conditional grouping metrics only"] : []))
        let features = files.map { $0.feature != nil }
        try validateProjection(result: result, observations: prepared.fileObservations, featuresAvailable: features,
            files: files, manifest: manifest, metadata: metadata, map: map, configuration: configuration, confirmedPairs: confirmedPairs)
        return SequenceMetadataEventAnalysis(manifest: manifest, result: result, observations: prepared.fileObservations,
            featuresAvailable: features, map: map, configuration: configuration, eventManifest: prepared.eventManifest,
            eventResult: eventResult, metadataStatistics: detector.metadataStatistics,
            managedPeakEstimateBytes: detector.managedPeakEstimateBytes, analysisSeconds: ProcessInfo.processInfo.systemUptime - start)
    }
    /// Mapping/input validation only, not a second classifier run after labels have been opened.
    public static func validateProjection(result: SequenceAnalysisResult, observations: [SequenceAssetInput], featuresAvailable: [Bool],
                                          files: [SequenceCaptureFileInput], manifest: SequenceInputManifest,
                                          metadata: SequenceMetadataSnapshot, map: SequenceCaptureEventMap,
                                          configuration: SequenceDetectorConfiguration,
                                          confirmedPairs: [SequenceConfirmedCapturePair]) throws {
        guard let recipe = configuration.metadataExperiment, configuration.spatialExperiment == nil,
              recipe.auditSeal == metadata.auditSeal, recipe.snapshotFingerprint == metadata.fingerprint,
              recipe.eventMapFingerprint == map.fingerprint else { throw SequenceMetadataError.invalid("Metadata recipe/input identity mismatch") }
        try configuration.validate()
        try map.validate(files: files, manifest: manifest, metadata: metadata, confirmedPairs: confirmedPairs, policy: recipe.associationPolicy)
        let expected = try prepare(files: files, manifest: manifest, metadata: metadata, map: map, cancelled: { false })
        guard observations == expected.fileObservations, featuresAvailable == files.map({ $0.feature != nil }) else {
            throw SequenceMetadataError.invalid("Projected observations were repaired, lost, reordered or substituted")
        }
        for group in result.ranges {
            let first = group.range.first, last = group.range.last
            guard files.indices.contains(first), files.indices.contains(last) else { throw SequenceMetadataError.invalid("Projected range outside full file scope") }
            let firstEvent = map.fileToEvent[first], lastEvent = map.fileToEvent[last]
            guard firstEvent < lastEvent, map.events[firstEvent].members[0].ordinal == first,
                  map.events[lastEvent].members.last!.ordinal == last else { throw SequenceMetadataError.invalid("Projected range splits a capture event") }
        }
        let token = try SequenceAnalysisToken.make(manifest: manifest, versions: configuration.versions(order: manifest.orderVersion),
            policyFingerprint: configuration.fingerprint)
        try result.validate(manifest: manifest, expectedToken: token, observations: observations)
    }
}
