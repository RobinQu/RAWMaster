import Foundation
import CoreGraphics

/// Small, versioned evidence. It is not a learned embedding or a confidence score.
public struct SequenceFrameFeature: Codable, Sendable, Equatable {
    public static let version = "sequence-srgb32-hist16-dhash-v1"
    public static let maximumPixel = 160
    public let width: Int
    public let height: Int
    public let normalizedLuminance: [Float]
    public let colorHistogram: [Float]
    public let differenceHash: UInt64
    public let mean: Float
    public let standardDeviation: Float
    public var isInformative: Bool { standardDeviation >= 0.02 }
    public var managedByteEstimate: Int { 512 + (normalizedLuminance.count + colorHistogram.count) * MemoryLayout<Float>.stride }

    public init(width: Int, height: Int, normalizedLuminance: [Float], colorHistogram: [Float],
                differenceHash: UInt64, mean: Float, standardDeviation: Float) throws {
        guard (1...Self.maximumPixel).contains(width), (1...Self.maximumPixel).contains(height),
              normalizedLuminance.count == 1024, colorHistogram.count == 48,
              normalizedLuminance.allSatisfy({ $0.isFinite && (-3...3).contains($0) }),
              colorHistogram.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              mean.isFinite, (0...1).contains(mean), standardDeviation.isFinite, standardDeviation >= 0 else {
            throw SequenceFeatureError.invalidFeature
        }
        for channel in 0..<3 {
            guard abs(colorHistogram[(channel * 16)..<(channel * 16 + 16)].reduce(0, +) - 1) < 0.002 else {
                throw SequenceFeatureError.invalidFeature
            }
        }
        self.width = width; self.height = height; self.normalizedLuminance = normalizedLuminance
        self.colorHistogram = colorHistogram; self.differenceHash = differenceHash
        self.mean = mean; self.standardDeviation = standardDeviation
    }
    private enum CodingKeys: String, CodingKey { case width, height, normalizedLuminance, colorHistogram, differenceHash, mean, standardDeviation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height),
            normalizedLuminance: c.decode([Float].self, forKey: .normalizedLuminance),
            colorHistogram: c.decode([Float].self, forKey: .colorHistogram), differenceHash: c.decode(UInt64.self, forKey: .differenceHash),
            mean: c.decode(Float.self, forKey: .mean), standardDeviation: c.decode(Float.self, forKey: .standardDeviation))
    }
    public func distance(to other: Self) -> SequenceFeatureDistance {
        let luma = sqrt(zip(normalizedLuminance, other.normalizedLuminance).reduce(Float(0)) {
            $0 + ($1.0 - $1.1) * ($1.0 - $1.1)
        } / 1024) / 6
        let histogram = zip(colorHistogram, other.colorHistogram).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / 6
        return SequenceFeatureDistance(luminance: luma, histogram: histogram,
            hash: Float((differenceHash ^ other.differenceHash).nonzeroBitCount) / 64)
    }
    static func extract(_ image: CGImage) throws -> Self {
        guard image.width <= maximumPixel, image.height <= maximumPixel else { throw SequenceFeatureError.oversizedPreview }
        var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32)); return true
        }
        guard drawn else { throw SequenceFeatureError.renderFailed }
        var luma = [Float](repeating: 0, count: 1024), histogram = [Float](repeating: 0, count: 48)
        for i in 0..<1024 {
            let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            for (channel, value) in [r, g, b].enumerated() { histogram[channel * 16 + min(15, Int(value * 16))] += 1 / 1024 }
        }
        let mean = luma.reduce(0, +) / 1024
        let deviation = sqrt(luma.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / 1024)
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 {
            if luma[(y * 4 + 2) * 32 + x * 3 + 2] > luma[(y * 4 + 2) * 32 + (x + 1) * 3 + 2] {
                hash |= UInt64(1) << UInt64(y * 8 + x)
            }
        } }
        return try Self(width: image.width, height: image.height,
            normalizedLuminance: luma.map { max(-3, min(3, ($0 - mean) / max(0.05, deviation))) },
            colorHistogram: histogram, differenceHash: hash, mean: mean, standardDeviation: deviation)
    }
}
public struct SequenceFeatureDistance: Sendable, Equatable {
    public let luminance: Float
    public let histogram: Float
    public let hash: Float
}
public enum SequenceFeatureError: Error { case invalidFeature, oversizedPreview, renderFailed }
