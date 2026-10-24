import Foundation
import RAWMasterCore

public struct SequenceMetadataExperimentConfiguration: Codable, Sendable, Equatable {
    public static let version = "metadata-events-h-only-v1"
    public let associationPolicy: SequenceAssociationPolicy
    public let rescuePolicy: SequenceMetadataRescuePolicy
    public let auditSeal, snapshotFingerprint, eventMapFingerprint: String
    public let semanticVersion: String
    public init(associationPolicy: SequenceAssociationPolicy, rescuePolicy: SequenceMetadataRescuePolicy,
                auditSeal: String, snapshotFingerprint: String, eventMapFingerprint: String,
                semanticVersion: String = Self.version) {
        self.associationPolicy = associationPolicy; self.rescuePolicy = rescuePolicy
        self.auditSeal = auditSeal; self.snapshotFingerprint = snapshotFingerprint
        self.eventMapFingerprint = eventMapFingerprint; self.semanticVersion = semanticVersion
    }
    public func validate() throws {
        let digests = [auditSeal, snapshotFingerprint, eventMapFingerprint]
        guard semanticVersion == Self.version, digests.allSatisfy({ value in
            value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        }) else { throw SequenceMetadataError.invalid("Invalid metadata experiment identity") }
    }
}
public struct SequenceMetadataBurstContext: Codable, Sendable, Equatable {
    public let representativeAssetID, currentSHA256, originalSHA256, auditSeal, snapshotFingerprint: String
    public let originalOffsetMinutes: Int?
    public let releaseMode, sequenceNumber, sequenceImageNumber: Int?
    public init(representativeAssetID: String, currentSHA256: String, originalSHA256: String,
                auditSeal: String, snapshotFingerprint: String, originalOffsetMinutes: Int?,
                releaseMode: Int?, sequenceNumber: Int?, sequenceImageNumber: Int?) {
        self.representativeAssetID = representativeAssetID; self.currentSHA256 = currentSHA256
        self.originalSHA256 = originalSHA256; self.auditSeal = auditSeal; self.snapshotFingerprint = snapshotFingerprint
        self.originalOffsetMinutes = originalOffsetMinutes; self.releaseMode = releaseMode
        self.sequenceNumber = sequenceNumber; self.sequenceImageNumber = sequenceImageNumber
    }
    static func integer(_ field: String, in facts: SequenceMetadataFileEvidence) -> Int? {
        guard facts.fieldStates[field] == .present,
              let decimal = SequenceCaptureEvents.decimal(facts.resolvedNumbers[field]), decimal >= 0,
              decimal <= Decimal(UInt32.max) else { return nil }
        let integer = NSDecimalNumber(decimal: decimal).int64Value
        return Decimal(integer) == decimal ? Int(integer) : nil
    }
    public static func make(file: SequenceCaptureFileInput, snapshot: SequenceMetadataSnapshot) -> Self {
        Self(representativeAssetID: file.entry.assetID, currentSHA256: file.metadata.currentSHA256,
            originalSHA256: file.metadata.originalSHA256, auditSeal: snapshot.auditSeal, snapshotFingerprint: snapshot.fingerprint,
            originalOffsetMinutes: file.metadata.originalCapture.time.offsetMinutes,
            releaseMode: integer("sony.ReleaseMode", in: file.metadata),
            sequenceNumber: integer("sony.SequenceNumber", in: file.metadata),
            sequenceImageNumber: integer("sony.SequenceImageNumber", in: file.metadata))
    }
    func isBound(entry: SequenceManifestEntry, configuration: SequenceMetadataExperimentConfiguration) -> Bool {
        representativeAssetID == entry.assetID && currentSHA256 == entry.contentHash
            && auditSeal == configuration.auditSeal && snapshotFingerprint == configuration.snapshotFingerprint
    }
}
public enum SequenceMetadataBurstDecision: String, Codable, Sendable {
    case unsupported, continuation, shortRestart
}
public enum SequenceMetadataBurstRule {
    /// Temporal/exposure, H/L/hash and global-anchor checks remain in the actual detector.
    /// This function certifies only the explicitly bounded original-metadata context.
    public static func decision(previous: SequenceMetadataBurstContext?, current: SequenceMetadataBurstContext?,
                                gapSeconds: Double, denseGapSeconds: Double,
                                policy: SequenceMetadataRescuePolicy) -> SequenceMetadataBurstDecision {
        guard let previous, let current, previous.auditSeal == current.auditSeal,
              previous.snapshotFingerprint == current.snapshotFingerprint,
              previous.originalOffsetMinutes == current.originalOffsetMinutes,
              gapSeconds.isFinite, denseGapSeconds.isFinite, gapSeconds > 0, gapSeconds <= denseGapSeconds,
              previous.releaseMode == 2, current.releaseMode == 2,
              let first = previous.sequenceNumber, let second = current.sequenceNumber,
              first > 0, second > 0, first <= Int(UInt32.max), second <= Int(UInt32.max),
              previous.sequenceImageNumber == first, current.sequenceImageNumber == second else { return .unsupported }
        if second > first && second-first == 1 { return .continuation }
        if policy == .allowShortRestart, second < first { return .shortRestart }
        return .unsupported
    }
}

public struct SequenceMetadataBurstStatistics: Codable, Sendable, Equatable {
    public internal(set) var observedContexts = 0
    public internal(set) var rescueCandidates = 0
    public internal(set) var continuationRescues = 0
    public internal(set) var shortRestartRescues = 0
    public internal(set) var rejectedContexts = 0
    public init() {}
}
