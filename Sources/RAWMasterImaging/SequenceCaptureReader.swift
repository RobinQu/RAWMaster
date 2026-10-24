import Foundation
import ImageIO
import Darwin
import RAWMasterCore

/// Capture this credential around the caller's verified SHA-256 read. Stat alone does not verify content.
public struct SequenceFileCredential: Sendable, Equatable {
    public let device: Int64, inode: UInt64, size: Int64
    public let modifiedSeconds: Int64, modifiedNanoseconds: Int64
    public let changedSeconds: Int64, changedNanoseconds: Int64
    public static func capture(at url: URL) throws -> Self {
        var attributes = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &attributes, 0) }) == 0 else { throw SequenceReadError.unreadable }
        return Self(device: Int64(attributes.st_dev), inode: UInt64(attributes.st_ino), size: attributes.st_size,
            modifiedSeconds: Int64(attributes.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(attributes.st_mtimespec.tv_nsec),
            changedSeconds: Int64(attributes.st_ctimespec.tv_sec), changedNanoseconds: Int64(attributes.st_ctimespec.tv_nsec))
    }
}
public struct SequenceCaptureReadResult: Sendable {
    public let evidence: SequenceCaptureEvidence
    public let feature: SequenceFrameFeature?
    public let previewFailure: String?
}
public enum SequenceReadError: Error, Equatable { case unreadable, sourceChanged, invalidBinding }

/// A single bounded synchronous unit; scheduling/admission belongs to the caller.
public enum SequenceCaptureReader {
    public static let extractorVersion = "sequence-imageio-exif-v1"
    public static let scratchReservationBytes = 2 * 1024 * 1024
    private static let rawExtensions: Set<String> = ["arw", "dng", "cr2", "cr3", "nef", "nrw", "raf", "rw2", "orf", "pef", "srw", "raw", "rwl", "3fr", "iiq"]

    /// verifiedCredential must correspond to the caller-verified contentHash, not a newly guessed identity.
    public static func read(at url: URL, assetID: String, contentHash: String, evidenceRevision: Int,
                            verifiedCredential: SequenceFileCredential,
                            cancelled: () -> Bool = { false }) throws -> SequenceCaptureReadResult {
        if Task.isCancelled || cancelled() { throw CancellationError() }
        guard !assetID.isEmpty, contentHash.utf8.count == 64,
              contentHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), evidenceRevision >= 0 else {
            throw SequenceReadError.invalidBinding
        }
        guard try SequenceFileCredential.capture(at: url) == verifiedCredential else { throw SequenceReadError.sourceChanged }
        let result: SequenceCaptureReadResult = try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw SequenceReadError.unreadable }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let auxiliary = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            var warnings: [String] = []
            let rawExposure = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
            let exposure = rawExposure.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if rawExposure != nil && exposure == nil { warnings.append("Invalid ExposureTime; kept unknown") }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            if properties[kCGImagePropertyOrientation] == nil { warnings.append("Orientation absent; EXIF default up") }
            let evidence = SequenceCaptureEvidence(assetID: assetID, contentHash: contentHash,
                extractorVersion: extractorVersion, evidenceRevision: evidenceRevision,
                time: SequenceTimestampParser.parse(original: exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                    subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                    offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String),
                cameraMake: tiff[kCGImagePropertyTIFFMake] as? String, cameraModel: tiff[kCGImagePropertyTIFFModel] as? String,
                imageNumberRaw: auxiliary[kCGImagePropertyExifAuxImageNumber].map { String(describing: $0) },
                exposureSeconds: exposure, orientation: orientation, warnings: warnings)
            guard (1...8).contains(orientation) else {
                return SequenceCaptureReadResult(evidence: evidence, feature: nil, previewFailure: "invalid-orientation")
            }
            let raw = rawExtensions.contains(url.pathExtension.lowercased())
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: !raw,
                kCGImageSourceCreateThumbnailFromImageAlways: !raw, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: SequenceFrameFeature.maximumPixel, kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return SequenceCaptureReadResult(evidence: evidence, feature: nil, previewFailure: "missing-embedded-preview")
            }
            do { return SequenceCaptureReadResult(evidence: evidence, feature: try SequenceFrameFeature.extract(image), previewFailure: nil) }
            catch { return SequenceCaptureReadResult(evidence: evidence, feature: nil, previewFailure: "invalid-preview") }
        }
        if Task.isCancelled || cancelled() { throw CancellationError() }
        guard try SequenceFileCredential.capture(at: url) == verifiedCredential else { throw SequenceReadError.sourceChanged }
        return result
    }
}
