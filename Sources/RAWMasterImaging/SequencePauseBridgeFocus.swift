import Foundation
import RAWMasterCore

public enum SequenceFocusAuditState: String, Codable, Sendable { case audited, outsideAuditedCohort, runtimeExtracted }
public struct SequenceFocusFileEvidence: Codable, Sendable, Equatable {
    public let assetID, currentSHA256, originalSHA256: String
    public let ordinal: Int
    public let state: SequenceFocusAuditState
    public let fieldStates: [String: SequenceMetadataFieldState]
    public let resolvedCodes: [String: Int]
    public let resolvedTuples: [String: [Int]]
    public init(assetID: String, currentSHA256: String, originalSHA256: String, ordinal: Int,
                state: SequenceFocusAuditState, fieldStates: [String: SequenceMetadataFieldState],
                resolvedCodes: [String: Int], resolvedTuples: [String: [Int]]) {
        self.assetID = assetID; self.currentSHA256 = currentSHA256; self.originalSHA256 = originalSHA256
        self.ordinal = ordinal; self.state = state; self.fieldStates = fieldStates
        self.resolvedCodes = resolvedCodes; self.resolvedTuples = resolvedTuples
    }
}
public struct SequenceFocusSnapshot: Codable, Sendable, Equatable {
    /// Verified curated-file byte SHA. The classifier additionally binds the actual DTO contents.
    public let focusAuditSeal, fingerprint, metadataSnapshotFingerprint: String
    public let files: [SequenceFocusFileEvidence]
    public let runtimeProofDigest: String?
    public init(focusAuditSeal: String, fingerprint: String, metadataSnapshotFingerprint: String,
                files: [SequenceFocusFileEvidence], runtimeProofDigest: String? = nil) {
        self.focusAuditSeal = focusAuditSeal; self.fingerprint = fingerprint
        self.metadataSnapshotFingerprint = metadataSnapshotFingerprint; self.files = files; self.runtimeProofDigest = runtimeProofDigest
    }
    public static let tupleCounts = ["sony.FocusLocation": 4, "sony.FocusLocation2": 4,
        "sony.FocusFrameSize": 3, "sony.FlexibleSpotPosition": 2]
    public static let codeFields: Set<String> = ["sony.FocusMode", "sony.AFAreaModeSetting", "sony.AFAreaMode",
        "sony.AFPointSelected", "sony.AFTracking", "sony.FocusPosition2", "sony.CameraOrientation"]
    public static let allFields = codeFields.union(tupleCounts.keys).union(["exif.SubjectDistance"])
    public func validateBindings(manifest: SequenceInputManifest, metadata: SequenceMetadataSnapshot) throws {
        try metadata.validateBindings(manifest: manifest)
        guard SequenceMetadataEvidenceLoader.isSHA(focusAuditSeal), SequenceMetadataEvidenceLoader.isSHA(fingerprint),
              metadataSnapshotFingerprint == metadata.fingerprint, files.count == manifest.entries.count,
              files.count <= 30_000 else { throw SequenceMetadataError.invalid("Focus snapshot scope/lineage mismatch") }
        guard runtimeProofDigest == (try metadata.runtimeProof?.digest()) else { throw SequenceMetadataError.invalid("Focus runtime provenance mismatch") }
        if metadata.runtimeProof != nil {
            guard focusAuditSeal == metadata.auditSeal, fingerprint == (try SequenceFingerprint.digest(files)) else { throw SequenceMetadataError.invalid("Live focus receipt changed") }
        }
        for (index, file) in files.enumerated() {
            let entry = manifest.entries[index], original = metadata.files[index]
            guard file.ordinal == index, file.assetID == entry.assetID, file.currentSHA256 == entry.contentHash,
                  file.originalSHA256 == original.originalSHA256,
                  Set(file.fieldStates.keys).isSubset(of: Self.allFields),
                  Set(file.resolvedCodes.keys).isSubset(of: Self.codeFields),
                  Set(file.resolvedTuples.keys).isSubset(of: Set(Self.tupleCounts.keys)) else {
                throw SequenceMetadataError.invalid("Focus file identity or field scope mismatch")
            }
            if metadata.runtimeProof != nil && file.state != .runtimeExtracted { throw SequenceMetadataError.invalid("Live focus rows require live extraction state") }
            if file.state == .outsideAuditedCohort {
                guard file.fieldStates.isEmpty, file.resolvedCodes.isEmpty, file.resolvedTuples.isEmpty else {
                    throw SequenceMetadataError.invalid("Unaudited focus row contains claimed facts")
                }
                continue
            }
            if file.state == .runtimeExtracted {
                guard let proof = metadata.runtimeProof, try proof.files[index].focusDigest == SequenceFingerprint.digest(file) else { throw SequenceMetadataError.invalid("Focus runtime facts changed") }
            } else if metadata.runtimeProof != nil { throw SequenceMetadataError.invalid("Runtime facts cannot claim historical audit") }
            guard Set(file.fieldStates.keys) == Self.allFields, (file.state == .runtimeExtracted || (original.originalFormat == .arw && original.originalCapture.cameraMake == "SONY" && original.originalCapture.cameraModel == "ILCE-1M2")) else { throw SequenceMetadataError.invalid("Focus cohort mismatch") }
            for (field, value) in file.resolvedCodes {
                guard file.fieldStates[field] == .present, value >= 0, value <= Int(UInt32.max) else {
                    throw SequenceMetadataError.invalid("Invalid resolved focus code")
                }
            }
            for (field, values) in file.resolvedTuples {
                guard file.fieldStates[field] == .present, values.count == Self.tupleCounts[field],
                      values.allSatisfy({ (0...65535).contains($0) }) else {
                    throw SequenceMetadataError.invalid("Invalid resolved focus tuple")
                }
            }
            for field in Self.codeFields where file.fieldStates[field] == .present {
                guard file.resolvedCodes[field] != nil else { throw SequenceMetadataError.invalid("Missing present focus code") }
            }
            for field in Self.tupleCounts.keys where file.fieldStates[field] == .present {
                guard file.resolvedTuples[field] != nil else { throw SequenceMetadataError.invalid("Missing present focus tuple") }
            }
        }
    }
    public func boundFingerprint(manifest: SequenceInputManifest, metadata: SequenceMetadataSnapshot) throws -> String {
        try validateBindings(manifest: manifest, metadata: metadata)
        struct Scope: Encodable {
            let version = "focus-snapshot-actual-scope-v1"
            let manifest: SequenceInputManifest
            let metadata: SequenceMetadataSnapshot
            let focus: SequenceFocusSnapshot
        }
        return try SequenceFingerprint.digest(Scope(manifest: manifest, metadata: metadata, focus: self))
    }
}
public enum SequencePauseBridgePolicy: String, Codable, Sendable {
    case focusRectAndCohortSeparation = "focus-rect-and-cohort-separation-v1"
}
public struct SequencePauseBridgeConfiguration: Codable, Sendable, Equatable {
    public let policy: SequencePauseBridgePolicy
    public let focusAuditSeal, focusSnapshotFingerprint: String
    public init(policy: SequencePauseBridgePolicy, focusAuditSeal: String, focusSnapshotFingerprint: String) {
        self.policy = policy; self.focusAuditSeal = focusAuditSeal; self.focusSnapshotFingerprint = focusSnapshotFingerprint
    }
    public func validate() throws {
        guard SequenceMetadataEvidenceLoader.isSHA(focusAuditSeal), SequenceMetadataEvidenceLoader.isSHA(focusSnapshotFingerprint) else {
            throw SequenceMetadataError.invalid("Invalid pause bridge focus identity")
        }
    }
}
public struct SequencePauseBridgeStatistics: Codable, Sendable, Equatable {
    public internal(set) var observedContexts = 0
    public internal(set) var bridgeCandidates = 0
    public internal(set) var notApplicable = 0
    public internal(set) var focusGeometryPassed = 0
    public internal(set) var appearanceSeparationPassed = 0
    public internal(set) var vetoes = 0
    public init() {}
}
/// Immutable factory-produced scope member. No public initializer or Codable entry point:
/// callers provide full snapshots to the event pipeline, not unchecked per-frame focus scalars.
public struct SequencePauseBridgeContext: Sendable, Equatable {
    let assetID, currentSHA256, originalSHA256, focusAuditSeal, scopeFingerprint: String
    let cameraPartitionID: String?
    let originalOffsetMinutes: Int?
    let orientation, referenceWidth, referenceHeight: Int?
    let releaseMode, sequenceNumber, sequenceImageNumber: Int?
    let localSecond: Int64?
    let nanosecond: Int?
    let settings: [String: String]
    let focus: SequenceFocusFileEvidence
    var runtimeCohortComparable = true
    static let settingFields = ["exif.ExposureTime", "exif.ISO", "exif.FNumber", "exif.FocalLength", "exif.ExposureProgram"]
    static func make(file: SequenceCaptureFileInput, focus: SequenceFocusFileEvidence,
                     focusAuditSeal: String, scopeFingerprint: String, manifest: SequenceInputManifest) -> Self {
        let metadata = file.metadata
        var settings: [String: String] = [:]
        for field in settingFields where metadata.fieldStates[field] == .present {
            if let number = SequenceCaptureEvents.decimal(metadata.resolvedNumbers[field]) {
                let valid: Bool
                if field == "exif.ExposureProgram" {
                    valid = number >= 0 && number <= Decimal(UInt32.max)
                        && Decimal(NSDecimalNumber(decimal: number).int64Value) == number
                } else { valid = number > 0 }
                if valid { settings[field] = NSDecimalNumber(decimal: number).stringValue }
            }
        }
        var context = Self(assetID: file.entry.assetID, currentSHA256: metadata.currentSHA256,
            originalSHA256: metadata.originalSHA256, focusAuditSeal: focusAuditSeal, scopeFingerprint: scopeFingerprint,
            cameraPartitionID: file.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint),
            originalOffsetMinutes: metadata.originalCapture.time.offsetMinutes,
            orientation: SequenceMetadataBurstContext.integer("exif.Orientation", in: metadata),
            referenceWidth: SequenceMetadataBurstContext.integer("exif.ExifImageWidth", in: metadata),
            referenceHeight: SequenceMetadataBurstContext.integer("exif.ExifImageHeight", in: metadata),
            releaseMode: SequenceMetadataBurstContext.integer("sony.ReleaseMode", in: metadata),
            sequenceNumber: SequenceMetadataBurstContext.integer("sony.SequenceNumber", in: metadata),
            sequenceImageNumber: SequenceMetadataBurstContext.integer("sony.SequenceImageNumber", in: metadata),
            localSecond: metadata.originalCapture.time.local?.civilSecond, nanosecond: metadata.originalCapture.time.local?.nanosecond,
            settings: settings, focus: focus)
        context.runtimeCohortComparable = focus.state != .runtimeExtracted || (metadata.originalFormat == .arw && metadata.originalCapture.cameraMake == "SONY" && metadata.originalCapture.cameraModel == "ILCE-1M2")
        return context
    }
    func isBound(entry: SequenceManifestEntry, configuration: SequencePauseBridgeConfiguration) -> Bool {
        assetID == entry.assetID && currentSHA256 == entry.contentHash && focus.assetID == assetID
            && focus.currentSHA256 == currentSHA256 && focus.originalSHA256 == originalSHA256
            && focusAuditSeal == configuration.focusAuditSeal && scopeFingerprint == configuration.focusSnapshotFingerprint
    }
}
