import Foundation
import ImageIO
import CoreGraphics

/// Experimental evidence only. These types are deliberately outside the product modules.
struct CaptureLocalComponents: Codable, Equatable {
    let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    let nanosecond: Int?
    var civilSecond: Int64 {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month + (month > 2 ? -3 : 9)
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Int64(era * 146097 + doe - 719468) * 86400 + Int64(hour * 3600 + minute * 60 + second)
    }
}
struct CaptureTimeEvidence: Codable, Equatable {
    let originalRaw: String?
    let subsecondsRaw: String?
    let offsetRaw: String?
    let local: CaptureLocalComponents?
    let utcInstant: Date?
    let precision: String
    let offsetEvidence: String
    let warnings: [String]
}
enum CaptureTimestampParser {
    static func parse(original: String?, subseconds: String?, offset: String?) -> CaptureTimeEvidence {
        var warnings: [String] = []
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if result != value { warnings.append("EXIF padding trimmed") }
            return result
        }
        let dateText = clean(original), fraction = clean(subseconds), offsetText = clean(offset)
        var local: CaptureLocalComponents?
        var nanos: Int?
        var precision = "seconds"
        if let fraction, !fraction.isEmpty {
            if fraction.allSatisfy({ $0.isASCII && $0.isNumber }) {
                let digits = String(fraction.prefix(9))
                nanos = Int(digits + String(repeating: "0", count: 9 - digits.count))
                precision = fraction.count > 9 ? "subseconds-truncated-to-nanoseconds" : "subseconds"
                if fraction.count > 9 { warnings.append("Subsecond precision exceeds nanoseconds; truncated explicitly") }
            } else { warnings.append("Invalid SubsecTimeOriginal; precise differences unavailable") }
        }
        if let dateText, dateText.range(of: #"^[0-9]{4}:[0-9]{2}:[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil {
            let fields = dateText.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
            if fields.count == 6 {
                let y = fields[0], m = fields[1], d = fields[2], h = fields[3], min = fields[4], s = fields[5]
                let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
                let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
                if (1...9999).contains(y), (1...12).contains(m), (1...lengths[m - 1]).contains(d),
                   (0...23).contains(h), (0...59).contains(min), (0...59).contains(s) {
                    local = CaptureLocalComponents(year: y, month: m, day: d, hour: h, minute: min, second: s, nanosecond: nanos)
                }
            }
        }
        if local == nil { warnings.append(original == nil ? "Missing DateTimeOriginal" : "Invalid DateTimeOriginal") ; precision = "unknown" }
        var offsetMinutes: Int?
        if let offsetText, !offsetText.isEmpty {
            if offsetText.range(of: #"^[+-][0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil {
                let h = Int(offsetText.dropFirst().prefix(2))!, m = Int(offsetText.suffix(2))!
                if h <= 14, m < 60, h < 14 || m == 0 { offsetMinutes = (h * 60 + m) * (offsetText.first == "-" ? -1 : 1) }
            }
            if offsetMinutes == nil { warnings.append("Invalid OffsetTimeOriginal; UTC unavailable") }
        }
        let instant = local.flatMap { local in offsetMinutes.map { Date(timeIntervalSince1970: Double(local.civilSecond - Int64($0 * 60)) + Double(local.nanosecond ?? 0) / 1e9) } }
        return CaptureTimeEvidence(originalRaw: original, subsecondsRaw: subseconds, offsetRaw: offset,
            local: local, utcInstant: instant, precision: precision,
            offsetEvidence: offsetMinutes == nil ? "unknown" : "explicit-valid", warnings: warnings)
    }
}
struct CaptureEvidence: Codable, Equatable {
    let time: CaptureTimeEvidence
    let cameraMake: String?
    let cameraModel: String?
    let imageNumberRaw: String?
    let orientation: Int
    let width: Int?
    let height: Int?
    let warnings: [String]
    static let extractorVersion = "imageio-exif-strict-1"
}
struct PreviewFeature: Encodable, Equatable {
    let width: Int, height: Int
    let differenceHash: UInt64
    let colorHistogram: [Float]
    let luminanceMean: Float
    let luminanceStdDev: Float
    /// Retained only in bounded working memory. The report writes distances, not this vector.
    let normalizedLuminance: [Float]
    var workingBytes: Int { 8 + (colorHistogram.count + normalizedLuminance.count) * 4 + 64 }
    enum CodingKeys: String, CodingKey { case width, height, differenceHash, colorHistogram, luminanceMean, luminanceStdDev }
    init(width: Int, height: Int, differenceHash: UInt64, colorHistogram: [Float], luminanceMean: Float,
         luminanceStdDev: Float, normalizedLuminance: [Float]) {
        self.width = width; self.height = height; self.differenceHash = differenceHash
        self.colorHistogram = colorHistogram; self.luminanceMean = luminanceMean
        self.luminanceStdDev = luminanceStdDev; self.normalizedLuminance = normalizedLuminance
    }

}
struct FrameProbe {
    var metadata: CaptureEvidence?
    var preview: PreviewFeature?
    var metadataFailure: String?
    var previewFailure: String?
}
enum EvidenceReadError: Error { case unreadable, missingEmbeddedPreview, invalidOrientation, oversizedPreview }
enum CaptureEvidenceReader {
    static let previewMaxPixel = 160
    static let scratchReservation = 2 * 1024 * 1024
    static func read(_ url: URL) -> FrameProbe {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return FrameProbe(metadataFailure: "Unreadable image metadata", previewFailure: "Unreadable image source")
            }
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            let warnings = props[kCGImagePropertyOrientation] == nil ? ["Orientation missing; EXIF default up"] : []
            let metadata = CaptureEvidence(time: CaptureTimestampParser.parse(
                original: exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String),
                cameraMake: tiff[kCGImagePropertyTIFFMake] as? String, cameraModel: tiff[kCGImagePropertyTIFFModel] as? String,
                imageNumberRaw: aux[kCGImagePropertyExifAuxImageNumber].map { String(describing: $0) },
                orientation: orientation, width: props[kCGImagePropertyPixelWidth] as? Int,
                height: props[kCGImagePropertyPixelHeight] as? Int, warnings: warnings)
            do { return FrameProbe(metadata: metadata, preview: try PreviewFeatureExtractor.read(source: source, orientation: orientation, isRAW: isRAW(url))) }
            catch { return FrameProbe(metadata: metadata, previewFailure: String(describing: error)) }
        }
    }
    static func isRAW(_ url: URL) -> Bool { ["arw", "dng", "cr2", "cr3", "nef", "nrw", "raf", "rw2", "orf", "pef", "srw", "raw", "rwl"].contains(url.pathExtension.lowercased()) }
}
enum PreviewFeatureExtractor {
    static func read(source: CGImageSource, orientation: Int, isRAW: Bool) throws -> PreviewFeature {
        guard (1...8).contains(orientation) else { throw EvidenceReadError.invalidOrientation }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: !isRAW,
            kCGImageSourceCreateThumbnailFromImageAlways: !isRAW, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: CaptureEvidenceReader.previewMaxPixel,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw EvidenceReadError.missingEmbeddedPreview }
        guard image.width <= CaptureEvidenceReader.previewMaxPixel, image.height <= CaptureEvidenceReader.previewMaxPixel else { throw EvidenceReadError.oversizedPreview }
        return try extract(image)
    }
    static func extract(_ image: CGImage) throws -> PreviewFeature {
        let side = 32
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let success = rgba.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)); return true
        }
        guard success else { throw EvidenceReadError.unreadable }
        var luma = [Float](repeating: 0, count: side * side), histogram = [Float](repeating: 0, count: 48)
        for i in luma.indices {
            let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            for (channel, value) in [r, g, b].enumerated() { histogram[channel * 16 + min(15, Int(value * 16))] += 1 / Float(side * side) }
        }
        let mean = luma.reduce(0, +) / Float(luma.count)
        let deviation = sqrt(luma.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(luma.count))
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 {
            let a = luma[(y * 4 + 2) * side + x * 3 + 2], b = luma[(y * 4 + 2) * side + (x + 1) * 3 + 2]
            if a > b { hash |= UInt64(1) << UInt64(y * 8 + x) }
        } }
        return PreviewFeature(width: image.width, height: image.height, differenceHash: hash, colorHistogram: histogram,
            luminanceMean: mean, luminanceStdDev: deviation,
            normalizedLuminance: luma.map { max(-3, min(3, ($0 - mean) / max(0.05, deviation))) })
    }
}
