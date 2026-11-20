import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import RAWMasterCore

/// Experimental preview statistics for human review. No result is an automatic reject decision.
/// Call from a utility worker; native image extraction is one bounded, non-preemptible unit.
public enum TriageQualityAnalyzer {
    public static let methodVersion = "triage-preview-risk-v1"
    public static let defaultMaximumPixel = 256
    public static let maximumSourcePixels = 150_000_000.0

    public static func analyze(
        asset: AssetRecord, maximumPixel: Int = defaultMaximumPixel,
        cancelled: () -> Bool = { false }
    ) throws -> TriageQualityEvidence {
        func check() throws {
            if Task.isCancelled || cancelled() { throw CancellationError() }
        }
        let raw = CaptureFileFormat.isRAW(asset.filename)
        var sourceName = raw ? "embeddedRAWPreview" : (CaptureFileFormat.isJPEG(asset.filename) ? "jpegPreview" : "imagePreview")
        func evidence(_ status: TriageQualityStatus, _ reasons: [String], _ metrics: [String: Double] = [:]) -> TriageQualityEvidence {
            TriageQualityEvidence(assetID: asset.id, contentHash: asset.contentHash, fileSize: asset.fileSize,
                source: sourceName, methodVersion: methodVersion, status: status, reasons: reasons, metrics: metrics)
        }
        try check()
        guard (16...512).contains(maximumPixel) else {
            return evidence(.error, ["预览分析预算无效，未进行质量判断。"])
        }
        guard asset.importState == .ready, asset.availability == .available else {
            return evidence(.error, ["文件尚未接入完成或原片不可用，不能进行质量判断。"])
        }
        guard let expectedHash = asset.contentHash, expectedHash.count == 64,
              expectedHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return evidence(.unknown, ["缺少已核验的文件身份，未进行质量判断。"])
        }
        do {
            let url = asset.resolvedURL
            let stamp = try Stamp.capture(url)
            guard stamp.size == asset.fileSize else {
                return evidence(.error, ["文件大小已变化，请重新核验原片。"])
            }
            guard try digest(url, check: check) == expectedHash, try Stamp.capture(url) == stamp else {
                return evidence(.error, ["文件内容已变化，旧的质量证据不能用于当前原片。"])
            }
            try check()
            let result: TriageQualityEvidence = try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                    return evidence(.error, ["无法读取图像，不把读取失败判作低质量照片。"])
                }
                let type = CGImageSourceGetType(source) as String?
                if !raw { sourceName = type == "public.jpeg" ? "jpegPreview" : "imagePreview" }
                let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                guard width.isFinite, height.isFinite, width > 0, height > 0,
                      width * height <= maximumSourcePixels else {
                    return evidence(.unsupported, ["图像尺寸超出本轮预览分析预算，需人工复核。"])
                }
                let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                guard (1...8).contains(orientation) else {
                    return evidence(.unknown, ["图像方向信息无效，未进行质量判断。"])
                }
                // RAW is never fully rendered when its embedded preview is absent.
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: !raw,
                    kCGImageSourceCreateThumbnailFromImageAlways: !raw,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixel,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return evidence(raw ? .unsupported : .error,
                        [raw ? "没有可用内嵌预览；未解码完整 RAW，请人工复核。" : "无法生成预览，不把解码失败判作低质量照片。"])
                }
                try check()
                guard image.width > 0, image.height > 0,
                      image.width <= maximumPixel, image.height <= maximumPixel else {
                    return evidence(.unsupported, ["图像框架未遵守预览尺寸预算，未继续分析。"])
                }
                guard let metrics = try statistics(image, check: check) else {
                    return evidence(.error, ["无法读取预览像素，需人工复核。"])
                }
                let lowTexture = metrics["luminanceStdDev"]! < 0.015 || metrics["meanGradient"]! < 0.001
                if lowTexture {
                    return evidence(.unknown, ["预览纹理很少，无法区分失焦、纯色场景或有意曝光；请人工复核。"], metrics)
                }
                var reasons: [String] = []
                if metrics["darkFraction"]! >= 0.8 { reasons.append("预览中极暗像素较多；可能是有意欠曝，需结合 RAW 与拍摄用途复核。") }
                if metrics["brightFraction"]! >= 0.8 { reasons.append("预览中极亮像素较多；不能据此判断 RAW 高光不可恢复，需人工复核。") }
                if !reasons.isEmpty { return evidence(.risk, reasons, metrics) }
                return evidence(.clear, ["有限预览统计未触发亮暗风险；这不代表清晰度或 RAW 曝光已通过质量验收。"], metrics)
            }
            try check()
            guard try Stamp.capture(url) == stamp else {
                return evidence(.error, ["分析期间原片发生变化，结果已作废。"])
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try check()
            return evidence(.error, ["原片不可读或读取期间发生变化；未作低质量判断。"])
        }
    }

    private struct Stamp: Equatable {
        let device: Int64, inode: UInt64, size: Int64
        let modifiedSeconds: Int64, modifiedNanoseconds: Int64
        let changedSeconds: Int64, changedNanoseconds: Int64
        static func capture(_ url: URL) throws -> Self {
            var value = stat()
            guard url.path.withCString({ fstatat(AT_FDCWD, $0, &value, 0) }) == 0,
                  (value.st_mode & S_IFMT) == S_IFREG else { throw ReadFailure.unreadable }
            return Self(device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: value.st_size,
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
        }
    }
    private enum ReadFailure: Error { case unreadable }
    private static func digest(_ url: URL, check: () throws -> Void) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while true {
            try check()
            let block = try autoreleasepool { try file.read(upToCount: 1024 * 1024) ?? Data() }
            if block.isEmpty { break }
            digest.update(data: block)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func statistics(_ image: CGImage, check: () throws -> Void) throws -> [String: Double]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered: Bool = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        var sum = 0.0, squared = 0.0, dark = 0, bright = 0, gradient = 0.0, pairs = 0
        var previous = [Double](repeating: 0, count: width)
        for y in 0..<height {
            try check()
            var left = 0.0
            for x in 0..<width {
                let index = (y * width + x) * 4
                let value = (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
                sum += value; squared += value * value
                if value <= 5.0 / 255 { dark += 1 }
                if value >= 250.0 / 255 { bright += 1 }
                if x > 0 { gradient += abs(value - left); pairs += 1 }
                if y > 0 { gradient += abs(value - previous[x]); pairs += 1 }
                previous[x] = value; left = value
            }
        }
        let count = Double(width * height), mean = sum / count
        return ["previewWidth": Double(width), "previewHeight": Double(height),
            "luminanceMean": mean, "luminanceStdDev": sqrt(max(0, squared / count - mean * mean)),
            "darkFraction": Double(dark) / count, "brightFraction": Double(bright) / count,
            "meanGradient": pairs > 0 ? gradient / Double(pairs) : 0]
    }
}
