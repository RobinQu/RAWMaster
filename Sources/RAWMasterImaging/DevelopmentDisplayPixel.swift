import AppKit
import RAWMasterCore

/// Color-managed sample of an already rendered, top-left-oriented preview bitmap.
/// Sampling never opens the original file or submits another image render.
public struct DevelopmentDisplayPixel: Equatable, Sendable {
    public let rgb: SIMD3<Double>
    public let lab: SIMD3<Double>

    /// Encoded sRGB luma, in the normalized domain used by the curve editor.
    public var tone: Double { 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z }

    private static let labSpace = CGColorSpace(name: CGColorSpace.genericLab)!
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    @MainActor public static func sample(_ image: NSImage, at point: DevelopmentSourcePoint) -> Self? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return sample(cg, at: point)
    }

    public static func sample(_ cg: CGImage, at point: DevelopmentSourcePoint) -> Self? {
        guard (try? point.validate()) != nil, cg.width > 0, cg.height > 0 else { return nil }
        let x = min(cg.width - 1, Int(point.x * Double(cg.width)))
        let y = min(cg.height - 1, Int(point.y * Double(cg.height)))
        guard let pixel = cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        // Preserve the CGImage's ICC profile. NSBitmapImageRep.colorAt tags plain CGImage RGB as calibrated RGB.
        var bytes = SIMD4<UInt8>.zero
        let rendered = withUnsafeMutableBytes(of: &bytes) { storage in
            guard let context = CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: sRGB,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(pixel, in: .init(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered, bytes.w > 0 else { return nil }
        let rgb = SIMD3(Double(bytes.x), Double(bytes.y), Double(bytes.z)) / Double(bytes.w)
        guard let color = CGColor(colorSpace: sRGB, components: [rgb.x, rgb.y, rgb.z, 1]),
              let components = color.converted(to: labSpace, intent: .relativeColorimetric, options: nil)?.components,
              components.count >= 3 else { return nil }
        return Self(rgb: rgb, lab: .init(components[0], components[1], components[2]))
    }
}
