import Foundation
import RAWMasterCore

public struct SequenceFocusFixtureIndex: Decodable, Sendable {
    public struct Case: Decodable, Sendable {
        public let id: String
        public let assetCount, auditedAssetCount: Int
        public let path, sha256, metadataSnapshotFingerprint, caseManifestSHA256: String
    }
    public let schemaVersion: Int
    public let datasetID, recipeVersion, focusAuditSeal, focusRowsSHA256, focusRegistrySHA256, normalizerVersion: String
    public let metadataV2IndexSHA256, v1IndexSHA256: String
    public let assetCount, auditedAssetCount, outsideAuditedCohortCount: Int
    public let cases: [Case]
}
private struct FocusCaseDTO: Decodable {
    struct File: Decodable {
        let assetID, currentSHA256, originalSHA256: String
        let ordinal: Int
        let state: SequenceFocusAuditState
        let fieldStates: [String: SequenceMetadataFieldState]
        let resolvedCodes: [String: Int]
        let resolvedTuples: [String: [Int]]
        let qualifiedFieldSources: [String: [String]]
        let auditWarningCount: Int?
    }
    let schemaVersion: Int
    let recipeVersion, caseID, focusAuditSeal, focusRowsSHA256, focusRegistrySHA256, normalizerVersion: String
    let metadataV2IndexSHA256, metadataSnapshotFingerprint, v1IndexSHA256, caseManifestSHA256: String
    let files: [File]
}
public enum SequenceFocusEvidenceError: Error { case invalid(String) }
/// Historical parser facts only. No JPEG-time repair, subject identity or native exposure proof.
public enum SequenceFocusEvidenceLoader {
    public static let datasetID = "sequence-focus-metadata-v1"
    public static let recipeVersion = "focus-audit-to-current-jpeg-v1"
    public static let acceptedAuditSeal = "b3ad33d4409ddf885d4ccff21da57e30d3c688d9087332ff2ceb3fabce48bec3"
    public static let acceptedRowsSHA256 = "1c2880c6a3e61e032b695843fae7f2ee0b25b9a5c3135b6ca46166e01c198719"
    public static let acceptedRegistrySHA256 = "98ff3bd7b9fe7d6468a6ecaeb195fbefc291c6ad33d9a11c2243763a1631d399"
    public static let metadataV2IndexSHA256 = "ec832150d7cf51675f29a3851206e314722fe0d39d2bc0df40cf1761c85b0e36"
    public static let normalizerVersion = "qualified-focus-facts-v1"
    private static let counts = ["burst123": 123, "burst14-context38": 38, "burst48-context72": 72,
        "interval427-context439": 439, "burst193-context217": 217, "dji187-context376": 376]
    private static let auditedCounts = ["burst123": 123, "burst14-context38": 38, "burst48-context72": 72,
        "interval427-context439": 0, "burst193-context217": 217, "dji187-context376": 0]
    private static func data(_ url: URL, maximum: Int) throws -> Data {
        let stream = try FileHandle(forReadingFrom: url); defer { try? stream.close() }
        let bytes = try stream.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw SequenceFocusEvidenceError.invalid("Focus fixture byte budget") }
        return bytes
    }
    public static func loadIndex(at url: URL, expectedSHA256: String) throws -> SequenceFocusFixtureIndex {
        let bytes = try data(url, maximum: 1024 * 1024)
        guard SequenceMetadataEvidenceLoader.isSHA(expectedSHA256), SequenceMetadataEvidenceLoader.sha256(bytes) == expectedSHA256 else {
            throw SequenceFocusEvidenceError.invalid("Focus index bytes changed")
        }
        let index = try JSONDecoder().decode(SequenceFocusFixtureIndex.self, from: bytes)
        guard index.schemaVersion == 1, index.datasetID == datasetID, index.recipeVersion == recipeVersion,
              index.focusAuditSeal == acceptedAuditSeal, index.focusRowsSHA256 == acceptedRowsSHA256,
              index.focusRegistrySHA256 == acceptedRegistrySHA256, index.normalizerVersion == normalizerVersion,
              index.metadataV2IndexSHA256 == metadataV2IndexSHA256, index.v1IndexSHA256 == "e2bc0f560c96d9c60cea737d43718d3d867aacc7c0e6599a44f6d7da58efb48c",
              index.assetCount == 1265, index.auditedAssetCount == 450, index.outsideAuditedCohortCount == 815,
              index.cases.count == 6, Set(index.cases.map(\.id)) == Set(counts.keys),
              index.cases.allSatisfy({ counts[$0.id] == $0.assetCount && auditedCounts[$0.id] == $0.auditedAssetCount
                  && SequenceMetadataEvidenceLoader.isSHA($0.sha256) && SequenceMetadataEvidenceLoader.isSHA($0.metadataSnapshotFingerprint)
                  && SequenceMetadataEvidenceLoader.isSHA($0.caseManifestSHA256) }) else {
            throw SequenceFocusEvidenceError.invalid("Focus index lineage/scope")
        }
        return index
    }
    private static func qualified(_ text: String, field: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let fieldParts = field.split(separator: ".")
        guard fieldParts.count == 2, parts.count == 3 || parts.count == 4, parts.last == fieldParts.last else { return false }
        let expected = fieldParts[0] == "sony" ? ["MakerNotes", "Sony"] : ["EXIF", "ExifIFD"]
        guard parts[0] == expected[0], parts[1] == expected[1] else { return false }
        if parts.count == 4 {
            let copy = parts[2]
            guard copy.hasPrefix("Copy"), copy.count > 4, copy.dropFirst(4).utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        }
        return true
    }
    public static func loadCase(_ item: SequenceFocusFixtureIndex.Case, index: SequenceFocusFixtureIndex,
                                focusRoot: URL, metadata: SequenceMetadataSnapshot,
                                manifest: SequenceInputManifest) throws -> SequenceFocusSnapshot {
        try metadata.validateBindings(manifest: manifest)
        guard index.cases.contains(where: { authorized in
            authorized.id == item.id && authorized.assetCount == item.assetCount && authorized.auditedAssetCount == item.auditedAssetCount
                && authorized.path == item.path && authorized.sha256 == item.sha256
                && authorized.metadataSnapshotFingerprint == item.metadataSnapshotFingerprint && authorized.caseManifestSHA256 == item.caseManifestSHA256
        }) else { throw SequenceFocusEvidenceError.invalid("Focus case is not authorized by the verified index") }
        let bytes = try data(SequenceMetadataEvidenceLoader.resolve(item.path, root: focusRoot), maximum: 8 * 1024 * 1024)
        guard SequenceMetadataEvidenceLoader.sha256(bytes) == item.sha256 else { throw SequenceFocusEvidenceError.invalid("Focus case bytes changed") }
        let dto = try JSONDecoder().decode(FocusCaseDTO.self, from: bytes)
        guard dto.schemaVersion == 1, dto.recipeVersion == recipeVersion, dto.caseID == item.id,
              dto.focusAuditSeal == acceptedAuditSeal, dto.focusAuditSeal == index.focusAuditSeal,
              dto.focusRowsSHA256 == acceptedRowsSHA256, dto.focusRowsSHA256 == index.focusRowsSHA256,
              dto.focusRegistrySHA256 == acceptedRegistrySHA256, dto.focusRegistrySHA256 == index.focusRegistrySHA256,
              dto.normalizerVersion == normalizerVersion, dto.normalizerVersion == index.normalizerVersion,
              dto.metadataV2IndexSHA256 == metadataV2IndexSHA256, dto.metadataV2IndexSHA256 == index.metadataV2IndexSHA256,
              dto.metadataSnapshotFingerprint == item.metadataSnapshotFingerprint, dto.metadataSnapshotFingerprint == metadata.fingerprint,
              dto.v1IndexSHA256 == index.v1IndexSHA256, dto.v1IndexSHA256 == metadata.v1IndexSHA256,
              dto.caseManifestSHA256 == item.caseManifestSHA256, dto.caseManifestSHA256 == metadata.caseManifestSHA256,
              dto.files.count == item.assetCount, dto.files.count == manifest.entries.count else {
            throw SequenceFocusEvidenceError.invalid("Focus case full metadata/source lineage")
        }
        var files: [SequenceFocusFileEvidence] = []
        var audited = 0
        for (ordinal, file) in dto.files.enumerated() {
            let source = metadata.files[ordinal]
            let inCohort = source.originalFormat == .arw && source.originalCapture.cameraMake == "SONY" && source.originalCapture.cameraModel == "ILCE-1M2"
            guard file.ordinal == ordinal, (file.state == .audited) == inCohort else { throw SequenceFocusEvidenceError.invalid("Focus audited cohort changed") }
            if file.state == .audited {
                audited += 1
                guard Set(file.fieldStates.keys) == SequenceFocusSnapshot.allFields,
                      Set(file.qualifiedFieldSources.keys) == SequenceFocusSnapshot.allFields,
                      file.fieldStates["exif.SubjectDistance"] == .absent, file.auditWarningCount.map({ $0 >= 0 }) == true,
                      !file.fieldStates.values.contains(.unsupportedSelector) else { throw SequenceFocusEvidenceError.invalid("Focus requested field coverage") }
                for (field, state) in file.fieldStates {
                    let sources = file.qualifiedFieldSources[field]!
                    guard (state == .absent) == sources.isEmpty, sources.allSatisfy({ qualified($0, field: field) }) else {
                        throw SequenceFocusEvidenceError.invalid("Focus field availability/instance source")
                    }
                }
            } else {
                guard file.fieldStates.isEmpty, file.resolvedCodes.isEmpty, file.resolvedTuples.isEmpty,
                      file.qualifiedFieldSources.isEmpty, file.auditWarningCount == nil else {
                    throw SequenceFocusEvidenceError.invalid("Unaudited focus file contains facts or verification claim")
                }
            }
            files.append(SequenceFocusFileEvidence(assetID: file.assetID, currentSHA256: file.currentSHA256, originalSHA256: file.originalSHA256,
                ordinal: file.ordinal, state: file.state, fieldStates: file.fieldStates, resolvedCodes: file.resolvedCodes, resolvedTuples: file.resolvedTuples))
        }
        guard audited == item.auditedAssetCount else { throw SequenceFocusEvidenceError.invalid("Focus audited count changed") }
        let snapshot = SequenceFocusSnapshot(focusAuditSeal: dto.focusAuditSeal, fingerprint: item.sha256,
            metadataSnapshotFingerprint: dto.metadataSnapshotFingerprint, files: files)
        try snapshot.validateBindings(manifest: manifest, metadata: metadata)
        return snapshot
    }
}
