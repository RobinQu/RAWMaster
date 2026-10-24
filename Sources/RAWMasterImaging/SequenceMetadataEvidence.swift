import Foundation
import CryptoKit
import Darwin
import RAWMasterCore

public enum SequenceMetadataFieldState: String, Codable, Sendable { case present, absent, unsupportedSelector, invalid, conflicting }
public enum SequenceOriginalFormat: String, Codable, Sendable { case arw, dng, jpeg, unknown }
public struct SequenceMetadataFileEvidence: Codable, Sendable, Equatable {
    public let assetID, currentSHA256, originalSHA256, auditSeal, keyID: String
    public let originalFormat: SequenceOriginalFormat
    public let originalCapture: SequenceCaptureEvidence
    public let fieldStates: [String: SequenceMetadataFieldState]
    public let resolvedNumbers: [String: String]
    public let opaqueCandidates: [String: String]
    public init(assetID: String, currentSHA256: String, originalSHA256: String, auditSeal: String, keyID: String,
                originalFormat: SequenceOriginalFormat, originalCapture: SequenceCaptureEvidence,
                fieldStates: [String: SequenceMetadataFieldState], resolvedNumbers: [String: String], opaqueCandidates: [String: String]) {
        self.assetID = assetID; self.currentSHA256 = currentSHA256; self.originalSHA256 = originalSHA256
        self.auditSeal = auditSeal; self.keyID = keyID; self.originalFormat = originalFormat; self.originalCapture = originalCapture
        self.fieldStates = fieldStates; self.resolvedNumbers = resolvedNumbers; self.opaqueCandidates = opaqueCandidates
    }
}
public struct SequenceMetadataSnapshot: Codable, Sendable, Equatable {
    /// fingerprint is the curated sidecar's verified byte SHA, not a self-referential JSON digest.
    public let auditSeal, fingerprint, v1IndexSHA256, caseManifestSHA256: String
    public let files: [SequenceMetadataFileEvidence]
    public let runtimeProof: SequenceRuntimeMetadataProof?
    public init(auditSeal: String, fingerprint: String, v1IndexSHA256: String, caseManifestSHA256: String, files: [SequenceMetadataFileEvidence], runtimeProof: SequenceRuntimeMetadataProof? = nil) {
        self.auditSeal = auditSeal; self.fingerprint = fingerprint; self.v1IndexSHA256 = v1IndexSHA256
        self.caseManifestSHA256 = caseManifestSHA256; self.files = files; self.runtimeProof = runtimeProof
    }
    public func validateBindings(manifest: SequenceInputManifest) throws {
        guard SequenceMetadataEvidenceLoader.isSHA(auditSeal), SequenceMetadataEvidenceLoader.isSHA(fingerprint),
              SequenceMetadataEvidenceLoader.isSHA(v1IndexSHA256), SequenceMetadataEvidenceLoader.isSHA(caseManifestSHA256),
              files.count == manifest.entries.count else { throw SequenceMetadataEvidenceError.invalid("Metadata snapshot identity/count") }
        try runtimeProof?.validate(snapshot: self, manifest: manifest)
        for (file, entry) in zip(files, manifest.entries) {
            guard file.assetID == entry.assetID, file.currentSHA256 == entry.contentHash, file.auditSeal == auditSeal,
                  SequenceMetadataEvidenceLoader.isSHA(file.originalSHA256), SequenceMetadataEvidenceLoader.isSHA(file.keyID),
                  file.originalCapture.assetID == file.assetID, file.originalCapture.contentHash == file.originalSHA256,
                  file.originalCapture.time.isConsistent else { throw SequenceMetadataEvidenceError.invalid("Metadata file binding") }
            try SequenceMetadataEvidenceLoader.validateFieldValues(file)
        }
    }
}
public enum SequenceMetadataEvidenceError: Error { case invalid(String) }
public struct SequenceMetadataFixtureIndex: Decodable, Sendable {
    public struct Case: Decodable, Sendable {
        public let id: String
        public let assetCount: Int
        public let path, sha256, caseManifestSHA256: String
    }
    public let schemaVersion: Int
    public let datasetID, recipeVersion, auditSeal, auditRowsSHA256, registrySHA256, normalizerVersion, v1IndexSHA256: String
    public let assetCount: Int
    public let cases: [Case]
}
private struct MetadataCaseDTO: Decodable {
    struct Capture: Decodable {
        let dateTimeOriginalRaw, subsecTimeOriginalRaw, offsetTimeOriginalRaw: String?
        let exposureSeconds: Double?
        let cameraMake, cameraModel: String?
        let orientation: Int?
    }
    struct File: Decodable {
        let assetID: String
        let ordinal: Int
        let currentSHA256, originalSHA256: String
        let originalFormat: SequenceOriginalFormat
        let capture: Capture
        let fieldStates: [String: SequenceMetadataFieldState]
        let resolvedNumbers, opaqueCandidates: [String: String]
        let qualifiedFieldSources: [String: [String]]
        let auditWarningCount: Int
    }
    let schemaVersion: Int
    let recipeVersion, caseID, auditSeal, auditRowsSHA256, registrySHA256, normalizerVersion, keyID, v1IndexSHA256, caseManifestSHA256: String
    let files: [File]
}
private struct MetadataV1Manifest: Decodable {
    struct File: Decodable {
        struct Source: Decodable { let sha256: String }
        let assetID: String; let ordinal: Int; let jpegSHA256: String; let sourceCapture: Source
    }
    let files: [File]
}
/// Explicit historical-original supplement. It never repairs current JPEG EXIF or the native reader.
public enum SequenceMetadataEvidenceLoader {
    public static let recipeVersion = "audit-to-current-jpeg-v1"
    public static let datasetID = "sequence-original-metadata-v2"
    public static let originalExtractor = "historical-exiftool-13.59/qualified-parser-facts-v1.1"
    public static let acceptedAuditSeal = "ba663312eec6cfd0aabfcc2837bd39e75fa45f64d4585c63a60c20c4497c3f17"
    public static let privateFields: Set<String> = ["exif.SerialNumber", "exif.CameraSerialNumber", "sony.SerialNumber", "sony.InternalSerialNumber",
        "dji.SensorID", "exif.ImageUniqueID", "exif.RawDataUniqueID", "xmp.ImageUniqueID", "xmpEX.ImageUniqueID"]
    public static let numberFields: Set<String> = ["exif.ExposureTime", "exif.Orientation", "exif.ImageNumber", "exif.ISO", "exif.FNumber", "exif.FocalLength", "exif.ExposureProgram", "exif.ExifImageWidth", "exif.ExifImageHeight", "exif.ImageWidth", "exif.ImageHeight", "sony.SequenceNumber", "sony.SequenceImageNumber", "sony.SequenceFileNumber", "sony.SequenceLength", "sony.ReleaseMode", "sony.ReleaseMode2", "sony.ReleaseMode3", "sony.DriveMode", "sony.DriveMode2", "sony.DriveModeSetting", "sony.ShutterType"]
    public static let allFields = privateFields.union(numberFields).union(["exif.Make", "exif.Model", "exif.DateTimeOriginal", "exif.SubSecTimeOriginal", "exif.OffsetTimeOriginal", "exif.UniqueCameraModel", "file.FileType", "file.MIMEType", "dji.unresolved.CaptureMode", "dji.unresolved.PhotoCaptureMode", "dji.unresolved.SequenceNumber", "dji.unresolved.CaptureUUID"])
    public static func isSHA(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func data(_ url: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw SequenceMetadataEvidenceError.invalid("Metadata control budget") }
        return bytes
    }
    public static func loadIndex(at url: URL, expectedSHA256: String) throws -> SequenceMetadataFixtureIndex {
        let bytes = try data(url, maximum: 1024 * 1024)
        guard isSHA(expectedSHA256), sha256(bytes) == expectedSHA256 else { throw SequenceMetadataEvidenceError.invalid("Metadata index bytes changed") }
        let index = try JSONDecoder().decode(SequenceMetadataFixtureIndex.self, from: bytes)
        let counts = ["burst123": 123, "burst14-context38": 38, "burst48-context72": 72, "interval427-context439": 439, "burst193-context217": 217, "dji187-context376": 376]
        guard index.schemaVersion == 2, index.datasetID == datasetID, index.recipeVersion == recipeVersion,
              index.auditSeal == acceptedAuditSeal, index.normalizerVersion == "qualified-parser-facts-v1.1",
              isSHA(index.auditRowsSHA256), isSHA(index.registrySHA256), isSHA(index.v1IndexSHA256), index.assetCount == 1265,
              index.cases.count == 6, Set(index.cases.map(\.id)) == Set(counts.keys),
              index.cases.allSatisfy({ counts[$0.id] == $0.assetCount && isSHA($0.sha256) && isSHA($0.caseManifestSHA256) }) else {
            throw SequenceMetadataEvidenceError.invalid("Metadata index lineage or scope")
        }
        return index
    }
    public static func resolve(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), !parts.isEmpty,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw SequenceMetadataEvidenceError.invalid("Unsafe metadata relative path") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var result = base
        // Foundation does not reliably resolve an existing symlink ancestor when the
        // remaining suffix is absent. Inspect every existing component without following it.
        for part in parts {
            result.appendPathComponent(String(part))
            var info = Darwin.stat()
            let status = result.path.withCString { fstatat(AT_FDCWD, $0, &info, AT_SYMLINK_NOFOLLOW) }
            if status == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw SequenceMetadataEvidenceError.invalid("Metadata path contains a symlink") }
            } else if errno != ENOENT { throw SequenceMetadataEvidenceError.invalid("Metadata path component unreadable") }
        }
        guard result.path.hasPrefix(base.path + "/") else { throw SequenceMetadataEvidenceError.invalid("Metadata path escaped root") }
        return result
    }
    public static func loadCase(_ item: SequenceMetadataFixtureIndex.Case, index: SequenceMetadataFixtureIndex,
                                metadataRoot: URL, v1Root: URL, v1ManifestURL: URL) throws -> SequenceMetadataSnapshot {
        let bytes = try data(resolve(item.path, root: metadataRoot), maximum: 8 * 1024 * 1024)
        guard sha256(bytes) == item.sha256 else { throw SequenceMetadataEvidenceError.invalid("Metadata case bytes changed") }
        let dto = try JSONDecoder().decode(MetadataCaseDTO.self, from: bytes)
        let v1Index = try data(v1Root.appendingPathComponent("index.json"), maximum: 1024 * 1024)
        let manifestBytes = try data(v1ManifestURL, maximum: 2 * 1024 * 1024)
        guard sha256(v1Index) == index.v1IndexSHA256, sha256(manifestBytes) == item.caseManifestSHA256,
              dto.schemaVersion == 2, dto.recipeVersion == recipeVersion, dto.caseID == item.id,
              dto.auditSeal == index.auditSeal, dto.auditRowsSHA256 == index.auditRowsSHA256,
              dto.registrySHA256 == index.registrySHA256, dto.normalizerVersion == index.normalizerVersion,
              dto.v1IndexSHA256 == index.v1IndexSHA256, dto.caseManifestSHA256 == item.caseManifestSHA256,
              isSHA(dto.keyID), dto.files.count == item.assetCount else { throw SequenceMetadataEvidenceError.invalid("Metadata lineage/provenance mismatch") }
        let original = try JSONDecoder().decode(MetadataV1Manifest.self, from: manifestBytes)
        guard original.files.count == dto.files.count else { throw SequenceMetadataEvidenceError.invalid("Metadata/v1 count mismatch") }
        var files: [SequenceMetadataFileEvidence] = []
        for (ordinal, pair) in zip(dto.files, original.files).enumerated() {
            let raw = pair.0, declared = pair.1
            guard raw.ordinal == ordinal, declared.ordinal == ordinal, raw.assetID == declared.assetID,
                  raw.currentSHA256 == declared.jpegSHA256, raw.originalSHA256 == declared.sourceCapture.sha256,
                  raw.originalFormat != .unknown, let orientation = raw.capture.orientation, (1...8).contains(orientation),
                  raw.auditWarningCount >= 0, raw.auditWarningCount <= 48, Set(raw.fieldStates.keys) == allFields,
                  Set(raw.qualifiedFieldSources.keys).isSubset(of: allFields),
                  raw.qualifiedFieldSources.values.flatMap({ $0 }).allSatisfy({ $0.utf8.count <= 256 && !$0.contains("/") && !$0.contains("\\") }) else { throw SequenceMetadataEvidenceError.invalid("Metadata ordinal/content/native format") }
            let evidence = SequenceCaptureEvidence(assetID: raw.assetID, contentHash: raw.originalSHA256,
                extractorVersion: originalExtractor, evidenceRevision: 1,
                time: SequenceTimestampParser.parse(original: raw.capture.dateTimeOriginalRaw, subseconds: raw.capture.subsecTimeOriginalRaw, offset: raw.capture.offsetTimeOriginalRaw),
                cameraMake: raw.capture.cameraMake, cameraModel: raw.capture.cameraModel,
                exposureSeconds: raw.capture.exposureSeconds, orientation: orientation,
                warnings: ["Historical original audit supplement; not current JPEG EXIF", "Original parser warning count: \(raw.auditWarningCount)"])
            let file = SequenceMetadataFileEvidence(assetID: raw.assetID, currentSHA256: raw.currentSHA256, originalSHA256: raw.originalSHA256,
                auditSeal: dto.auditSeal, keyID: dto.keyID, originalFormat: raw.originalFormat, originalCapture: evidence,
                fieldStates: raw.fieldStates, resolvedNumbers: raw.resolvedNumbers, opaqueCandidates: raw.opaqueCandidates)
            try validateFieldValues(file)
            files.append(file)
        }
        return SequenceMetadataSnapshot(auditSeal: dto.auditSeal, fingerprint: item.sha256, v1IndexSHA256: dto.v1IndexSHA256,
            caseManifestSHA256: dto.caseManifestSHA256, files: files)
    }
    static func validateFieldValues(_ file: SequenceMetadataFileEvidence) throws {
        guard !file.assetID.isEmpty, isSHA(file.currentSHA256), isSHA(file.originalSHA256), isSHA(file.auditSeal), isSHA(file.keyID),
              file.originalCapture.time.isConsistent, file.originalCapture.contentHash == file.originalSHA256,
              Set(file.fieldStates.keys).isSubset(of: allFields) else { throw SequenceMetadataEvidenceError.invalid("Invalid metadata identity/time") }
        let locale = Locale(identifier: "en_US_POSIX")
        for (field, value) in file.resolvedNumbers {
            guard numberFields.contains(field), file.fieldStates[field] == .present, value.utf8.count <= 256,
                  value.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
                  let number = Decimal(string: value, locale: locale), !number.isNaN else { throw SequenceMetadataEvidenceError.invalid("Unresolved/private/nonfinite numeric fact") }
        }
        for (field, value) in file.opaqueCandidates {
            guard privateFields.contains(field), file.fieldStates[field] == .present, isSHA(value) else { throw SequenceMetadataEvidenceError.invalid("Unusable private identity candidate") }
        }
    }
}
