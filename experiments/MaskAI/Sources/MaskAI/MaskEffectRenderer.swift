import Foundation
import CoreImage
import CoreGraphics

public struct MaskEffectMetrics: Codable, Equatable, Sendable {
    public let exposureEV: Double
    public let selectedMeanLuminanceBefore: Double
    public let selectedMeanLuminanceAfter: Double
    public let unselectedMeanLuminanceBefore: Double
    public let unselectedMeanLuminanceAfter: Double
    public let selectedMeanAbsoluteChange: Double
    public let unselectedMeanAbsoluteChange: Double
    public let changedSelectedPixels: Int
}

public struct MaskEffectResult: Sendable {
    public let image: NativeImage
    public let metrics: MaskEffectMetrics
}

/// Validation-only effect renderer using Core Image exposure and a mask blend.
/// It is intentionally not presented as RAWMaster's canonical local adjustment algorithm.
public enum MaskEffectRenderer {
    public static func applyExposure(to base: NativeImage, mask: MaskImage, exposureEV: Double = 0.75) throws -> MaskEffectResult {
        guard base.width == mask.width, base.height == mask.height, exposureEV.isFinite else {
            throw MaskAIError.invalidInput("Effect input and mask must have identical finite dimensions.")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let source = CIImage(bitmapData: Data(base.rgba), bytesPerRow: base.width * 4,
                             size: CGSize(width: base.width, height: base.height), format: .RGBA8, colorSpace: colorSpace)
        let matte = CIImage(bitmapData: Data(mask.values), bytesPerRow: mask.width,
                            size: CGSize(width: mask.width, height: mask.height), format: .L8, colorSpace: nil)
        let adjusted = source.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposureEV])
        guard let blended = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: adjusted,
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: matte,
        ])?.outputImage else {
            throw MaskAIError.inferenceFailed("CIBlendWithMask returned no output.")
        }
        let output = try NativeImage(ciImage: blended, maximumLongEdge: max(base.width, base.height))
        let metrics = try measure(base: base, output: output, mask: mask, exposureEV: exposureEV)
        return MaskEffectResult(image: output, metrics: metrics)
    }

    private static func measure(base: NativeImage, output: NativeImage, mask: MaskImage, exposureEV: Double) throws -> MaskEffectMetrics {
        var selectedWeight = 0.0, unselectedWeight = 0.0
        var selectedBefore = 0.0, selectedAfter = 0.0, unselectedBefore = 0.0, unselectedAfter = 0.0
        var selectedChange = 0.0, unselectedChange = 0.0
        var changedSelected = 0
        for index in 0..<mask.values.count {
            let weight = Double(mask.values[index]) / 255
            let before = luminance(base.rgba, index), after = luminance(output.rgba, index)
            let change = abs(after - before)
            selectedWeight += weight
            unselectedWeight += 1 - weight
            selectedBefore += before * weight
            selectedAfter += after * weight
            unselectedBefore += before * (1 - weight)
            unselectedAfter += after * (1 - weight)
            selectedChange += change * weight
            unselectedChange += change * (1 - weight)
            if mask.values[index] >= 128 && change > 1 / 255 { changedSelected += 1 }
        }
        guard selectedWeight > 0 else { throw MaskAIError.invalidInput("Cannot measure an empty effect mask.") }
        return MaskEffectMetrics(exposureEV: exposureEV,
                                 selectedMeanLuminanceBefore: selectedBefore / selectedWeight,
                                 selectedMeanLuminanceAfter: selectedAfter / selectedWeight,
                                 unselectedMeanLuminanceBefore: unselectedBefore / max(unselectedWeight, 1e-9),
                                 unselectedMeanLuminanceAfter: unselectedAfter / max(unselectedWeight, 1e-9),
                                 selectedMeanAbsoluteChange: selectedChange / selectedWeight,
                                 unselectedMeanAbsoluteChange: unselectedChange / max(unselectedWeight, 1e-9),
                                 changedSelectedPixels: changedSelected)
    }

    private static func luminance(_ rgba: [UInt8], _ index: Int) -> Double {
        (0.2126 * Double(rgba[index * 4]) + 0.7152 * Double(rgba[index * 4 + 1]) + 0.0722 * Double(rgba[index * 4 + 2])) / 255
    }
}
