import Foundation
import RAWMasterCore

/// A live read receipt, deliberately distinct from the sealed historical audit.
/// Digests bind values and scope; authenticity comes from the local provider/code signature.
public struct SequenceRuntimeMetadataProof: Codable, Sendable, Equatable {
    public static let providerVersion = "runtime-exiftool-jsonq-v1"
    public static let extractorVersion = "runtime-exiftool-13.59-jsonq/qualified-v1"
    public struct File: Codable, Sendable, Equatable {
        public let assetID, contentSHA256, locationFingerprint: String
        public let ordinal, evidenceRevision: Int
        public let before, after: AutomaticGroupingFileStamp
        public let beforeCredential, afterCredential: SequenceFileCredential
        public let normalized: RuntimeNormalizedMetadata
        public let nativeEvidence: SequenceCaptureEvidence?
        public let metadataDigest, focusDigest: String
        public let featureDigest: String?
        public let featureVersion: String
        public let barrier: SequenceReason?
    }
    public let version, toolCommit, toolVersion, toolClosureSHA256, registrySHA256, keyID, manifestSHA256: String
    public let files: [File]
    public func digest() throws -> String { try SequenceFingerprint.digest(self) }
    static func metadataDigest(_ file: SequenceMetadataFileEvidence) throws -> String {
        struct Facts: Encodable {
            let assetID, currentSHA256, originalSHA256, keyID: String
            let originalFormat: SequenceOriginalFormat
            let capture: SequenceCaptureEvidence
            let states: [String: SequenceMetadataFieldState]
            let numbers, opaque: [String: String]
        }
        return try SequenceFingerprint.digest(Facts(assetID: file.assetID, currentSHA256: file.currentSHA256,
            originalSHA256: file.originalSHA256, keyID: file.keyID, originalFormat: file.originalFormat,
            capture: file.originalCapture, states: file.fieldStates, numbers: file.resolvedNumbers, opaque: file.opaqueCandidates))
    }
    public func validate(snapshot: SequenceMetadataSnapshot, manifest: SequenceInputManifest) throws {
        guard version == Self.providerVersion, toolCommit == RuntimeSequenceTool.commit, toolVersion == "13.59",
              [toolClosureSHA256, registrySHA256, keyID, manifestSHA256].allSatisfy(SequenceMetadataEvidenceLoader.isSHA),
              manifestSHA256 == (try SequenceFingerprint.digest(manifest)), registrySHA256 == (try RuntimeSequenceRegistry.fingerprint), files.count == manifest.entries.count,
              snapshot.auditSeal == (try digest()), snapshot.v1IndexSHA256 == toolClosureSHA256,
              snapshot.caseManifestSHA256 == manifestSHA256,
              snapshot.fingerprint == (try SequenceFingerprint.digest(snapshot.files)) else {
            throw SequenceMetadataError.invalid("Live metadata receipt/scope mismatch")
        }
        for (ordinal, row) in files.enumerated() {
            let entry = manifest.entries[ordinal], facts = snapshot.files[ordinal]
            guard row.ordinal == ordinal, row.assetID == entry.assetID, row.contentSHA256 == entry.contentHash,
                  row.evidenceRevision == entry.evidenceRevision, row.before == row.after, row.beforeCredential == row.afterCredential,
                  row.before.size == row.beforeCredential.size, row.before.inode == row.beforeCredential.inode,
                  row.featureVersion == SequenceFrameFeature.version, row.featureDigest.map(SequenceMetadataEvidenceLoader.isSHA) ?? true,
                  SequenceMetadataEvidenceLoader.isSHA(row.locationFingerprint), SequenceMetadataEvidenceLoader.isSHA(row.focusDigest),
                  facts.currentSHA256 == facts.originalSHA256, facts.keyID == keyID,
                  facts.originalCapture.extractorVersion == Self.extractorVersion,
                  facts.originalCapture.evidenceRevision == entry.evidenceRevision,
                  Set(facts.fieldStates.keys) == SequenceMetadataEvidenceLoader.allFields,
                  row.metadataDigest == (try Self.metadataDigest(facts)),
                  row.normalized.states.filter({ SequenceMetadataEvidenceLoader.allFields.contains($0.key) }) == facts.fieldStates,
                  row.normalized.numbers == facts.resolvedNumbers, row.normalized.opaque == facts.opaqueCandidates,
                  Set(row.normalized.states.keys) == SequenceMetadataEvidenceLoader.allFields.union(SequenceFocusSnapshot.allFields),
                  row.normalized.strings["exif.DateTimeOriginal"] == facts.originalCapture.time.originalRaw,
                  row.normalized.strings["exif.SubSecTimeOriginal"] == facts.originalCapture.time.subsecondsRaw,
                  row.normalized.strings["exif.OffsetTimeOriginal"] == facts.originalCapture.time.offsetRaw,
                  row.normalized.strings["exif.Make"] == facts.originalCapture.cameraMake,
                  row.normalized.strings["exif.Model"] == facts.originalCapture.cameraModel,
                  row.nativeEvidence.map({ $0.assetID == entry.assetID && $0.contentHash == entry.contentHash && $0.evidenceRevision == entry.evidenceRevision && $0.extractorVersion == SequenceCaptureReader.extractorVersion }) ?? true,
                  row.nativeEvidence != nil || row.barrier != nil else {
                throw SequenceMetadataError.invalid("Live metadata file proof mismatch")
            }
        }
    }
    func validateInputs(files inputs: [SequenceCaptureFileInput]) throws {
        guard inputs.count == files.count else { throw SequenceMetadataError.invalid("Live input count") }
        for (input, proof) in zip(inputs, files) {
            guard input.currentEvidence == input.metadata.originalCapture, input.readBarrier == proof.barrier,
                  input.contentVersion == proof.evidenceRevision,
                  proof.featureDigest == (try input.feature.map { try SequenceFingerprint.digest($0) }) else { throw SequenceMetadataError.invalid("Live primary/native input mismatch") }
            if let native = proof.nativeEvidence {
                let primary = input.metadata.originalCapture
                let conflict = Self.nativeContradiction(native, primary)
                guard conflict == nil || input.readBarrier != nil else { throw SequenceMetadataError.invalid("Native counterevidence was discarded") }
            }
        }
    }
    static func nativeContradiction(_ native: SequenceCaptureEvidence, _ primary: SequenceCaptureEvidence) -> SequenceReason? {
        for (a, b) in [(native.cameraMake, primary.cameraMake), (native.cameraModel, primary.cameraModel)] {
            if let a = SequenceCaptureEvents.canonicalCamera(a), let b = SequenceCaptureEvents.canonicalCamera(b), a != b { return .assertionMismatch }
        }
        if let a = native.time.local, let b = primary.time.local {
            if a.civilSecond != b.civilSecond { return .invalidTimestamp }
            if let x = a.nanosecond, let y = b.nanosecond, x != y { return .invalidTimestamp }
        }
        if let a = native.time.offsetMinutes, let b = primary.time.offsetMinutes, a != b { return .invalidClockPartition }
        if let a = native.exposureSeconds, let b = primary.exposureSeconds,
           !a.isFinite || !b.isFinite || abs(a-b) > max(1e-8, abs(b)*1e-6) { return .contentMismatch }
        return nil
    }
}
