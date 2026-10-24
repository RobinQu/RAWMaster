import Foundation
import CoreGraphics

public enum SequenceSpatialMode: String, Codable, Sendable { case bridgeVetoOnly, localRescueAndBridgeVeto }
public struct SequenceSpatialRecipe: Codable, Sendable, Equatable {
    public var maximumPixel = 96
    public var coarsePixel = 24
    public var minimumValidSide = 48
    public var maximumTranslation = 12
    public var coarseRadius = 3
    public var fineRadius = 3
    public var patchSize = 16
    public var residualRadius = 3
    public var minimumOverlap: Float = 0.75
    public var minimumCorrelation: Float = 0.80
    public var minimumPeakMargin: Float = 0.03
    public var minimumDeviation: Float = 0.025
    public var minimumGradient: Float = 0.01
    public var minimumGradientCosine: Float = 0.70
    public var minimumTexturedPatches = 6
    public var minimumSupportedFraction: Float = 0.80
    public var minimumQuadrants = 3
    public init() {}
}
public struct SequenceSpatialConfiguration: Codable, Sendable, Equatable {
    public static let version = "spatial-translation-patch-v1"
    public let recipeVersion: String
    public let mode: SequenceSpatialMode
    public let recipe: SequenceSpatialRecipe
    public init(mode: SequenceSpatialMode) { recipeVersion = Self.version; self.mode = mode; recipe = .init() }
    public func validate() throws {
        guard recipeVersion == Self.version, recipe == SequenceSpatialRecipe() else { throw SequenceSpatialError.invalidConfiguration }
    }
}
public enum SequenceSpatialError: Error, Equatable { case invalidConfiguration, invalidFeature, renderFailed }
struct SequenceSpatialRect: Sendable, Equatable {
    let x: Int, y: Int, width: Int, height: Int
    var maxX: Int { x + width }; var maxY: Int { y + height }
    var area: Int { width * height }
    func contains(x: Int, y: Int, width: Int, height: Int, margin: Int = 0) -> Bool {
        x - margin >= self.x && y - margin >= self.y && x + width + margin <= maxX && y + height + margin <= maxY
    }
}
/// Ephemeral image evidence, not metadata or a learned embedding. Pixels never enter a result/trace.
public struct SequenceSpatialFeature: Sendable, Equatable {
    public static let version = SequenceSpatialConfiguration.version
    let valid: SequenceSpatialRect
    let coarseValid: SequenceSpatialRect
    let luminance: [Float], gradientX: [Float], gradientY: [Float], coarse: [Float]
    public var width: Int { valid.width }; public var height: Int { valid.height }
    public var isSmall: Bool { min(width, height) < 48 }
    public var managedByteEstimate: Int { 512 + (luminance.count + gradientX.count + gradientY.count + coarse.count) * MemoryLayout<Float>.stride }
    init(valid: SequenceSpatialRect, luminance: [Float], gradientX: [Float], gradientY: [Float], coarse: [Float]) throws {
        guard valid.width > 0, valid.height > 0, valid.x >= 0, valid.y >= 0, valid.maxX <= 96, valid.maxY <= 96 else { throw SequenceSpatialError.invalidFeature }
        let small = min(valid.width, valid.height) < 48
        guard small ? (luminance.isEmpty && gradientX.isEmpty && gradientY.isEmpty && coarse.isEmpty)
            : (luminance.count == 9216 && gradientX.count == 9216 && gradientY.count == 9216 && coarse.count == 576),
            luminance.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            coarse.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            gradientX.allSatisfy({ $0.isFinite && (-1...1).contains($0) }), gradientY.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { throw SequenceSpatialError.invalidFeature }
        self.valid = valid; self.luminance = luminance; self.gradientX = gradientX; self.gradientY = gradientY; self.coarse = coarse
        let x = (valid.x + 3) / 4, y = (valid.y + 3) / 4
        coarseValid = SequenceSpatialRect(x: x, y: y, width: max(0, valid.maxX / 4 - x), height: max(0, valid.maxY / 4 - y))
    }
    public static func extract(_ image: CGImage, cancelled: () -> Bool = { false }) throws -> Self {
        try checkSpatialCancellation(cancelled)
        guard image.width > 0, image.height > 0, image.width <= SequenceFrameFeature.maximumPixel, image.height <= SequenceFrameFeature.maximumPixel else { throw SequenceSpatialError.invalidFeature }
        let scale = min(1, 96 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        let rect = SequenceSpatialRect(x: (96 - width) / 2, y: (96 - height) / 2, width: width, height: height)
        // Readable tiny previews are successful evidence with insufficient resolution; no large allocation.
        if min(width, height) < 48 { return try Self(valid: rect, luminance: [], gradientX: [], gradientY: [], coarse: []) }
        var rgba = [UInt8](repeating: 0, count: 96 * 96 * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: bytes.baseAddress, width: 96, height: 96,
                bitsPerComponent: 8, bytesPerRow: 96 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: rect.x, y: rect.y, width: width, height: height)); return true
        }
        guard rendered else { throw SequenceSpatialError.renderFailed }
        var luma = [Float](repeating: 0, count: 9216), gx = luma, gy = luma, coarse = [Float](repeating: 0, count: 576)
        for y in 0..<96 {
            if y.isMultiple(of: 8) { try checkSpatialCancellation(cancelled) }
            for x in 0..<96 {
                let p = (y * 96 + x) * 4
                luma[y * 96 + x] = (0.2126 * Float(rgba[p]) + 0.7152 * Float(rgba[p + 1]) + 0.0722 * Float(rgba[p + 2])) / 255
            }
        }
        for y in (rect.y + 1)..<(rect.maxY - 1) {
            if y.isMultiple(of: 8) { try checkSpatialCancellation(cancelled) }
            for x in (rect.x + 1)..<(rect.maxX - 1) {
                let i = y * 96 + x
                gx[i] = (-luma[i-97] + luma[i-95] - 2*luma[i-1] + 2*luma[i+1] - luma[i+95] + luma[i+97]) / 8
                gy[i] = (-luma[i-97] - 2*luma[i-96] - luma[i-95] + luma[i+95] + 2*luma[i+96] + luma[i+97]) / 8
            }
        }
        for y in 0..<24 { for x in 0..<24 {
            var total: Float = 0
            for yy in 0..<4 { for xx in 0..<4 { total += luma[(y*4+yy)*96+x*4+xx] } }
            coarse[y*24+x] = total / 16
        } }
        try checkSpatialCancellation(cancelled)
        return try Self(valid: rect, luminance: luma, gradientX: gx, gradientY: gy, coarse: coarse)
    }
}
func checkSpatialCancellation(_ cancelled: () -> Bool) throws {
    if Task.isCancelled || cancelled() { throw CancellationError() }
}
