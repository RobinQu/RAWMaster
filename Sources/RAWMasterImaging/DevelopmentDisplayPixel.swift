import AppKit
import Metal
import RAWMasterCore
import simd

/// Color-managed sample of an already rendered, top-left-oriented preview bitmap.
/// Sampling never opens the original file or submits another image render.
public struct DevelopmentDisplayPixel: Equatable, Sendable {
    public let rgb: SIMD3<Double>
    public let lab: SIMD3<Double>

    /// Encoded sRGB luma, in the normalized domain used by the curve editor.
    public var tone: Double { 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z }

    private static let labSpace = CGColorSpace(name: CGColorSpace.genericLab)!
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    package struct LinearSample: Equatable, Sendable {
        package let rgb: SIMD3<Float>
        package let target: DevelopmentSceneOutputStateV1.Target

        package var luminanceNits: Float {
            let weights: SIMD3<Float> = target == .hdr2020 ? .init(0.2627, 0.6780, 0.0593) : .init(0.2126, 0.7152, 0.0722)
            return simd_dot(rgb, weights) * target.referenceWhiteNits
        }
        package var colorSpace: CGColorSpace? {
            CGColorSpace(name: target == .hdr2020 ? CGColorSpace.extendedLinearITUR_2020 : CGColorSpace.extendedLinearSRGB)
        }
    }

    /// Coordinates are normalized on the entire developed image. A native preview contains
    /// only its pixel-aligned window. A point outside that window must not sample its edge.
    private static func texel(_ point: DevelopmentSourcePoint?, in frame: DevelopmentScenePreviewFrameV1) -> MTLOrigin? {
        guard let point, (try? point.validate()) != nil else { return nil }
        let texture = frame.texture
        guard let window = frame.window else {
            return .init(x: min(texture.width - 1, Int(point.x * Double(texture.width))),
                         y: min(texture.height - 1, Int(point.y * Double(texture.height))), z: 0)
        }
        let size = frame.nativeSize
        let x = min(Int(size.width) - 1, Int(point.x * size.width)) - Int((window.minX * size.width).rounded())
        let y = min(Int(size.height) - 1, Int(point.y * size.height)) - Int((window.minY * size.height).rounded())
        guard (0..<texture.width).contains(x), (0..<texture.height).contains(y) else { return nil }
        return .init(x: x, y: y, z: 0)
    }

    /// Read all inspection points from one immutable frame with one Metal submission.
    package static func linearSamples(_ frame: DevelopmentScenePreviewFrameV1, at points: [DevelopmentSourcePoint?]) -> [LinearSample?] {
        let missing = [LinearSample?](repeating: nil, count: points.count)
        let origins = points.map { texel($0, in: frame) }
        let texture = frame.texture, device = texture.device
        let stride = 256
        guard origins.contains(where: { $0 != nil }), texture.pixelFormat == .rgba32Float,
              points.count <= device.maxBufferLength / stride,
              let buffer = device.makeBuffer(length: points.count * stride, options: .storageModeShared),
              let command = device.makeCommandQueue()?.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return missing }
        for (index, origin) in origins.enumerated() {
            guard let origin else { continue }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
                sourceSize: .init(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: index * stride,
                destinationBytesPerRow: stride, destinationBytesPerImage: stride)
        }
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return missing }
        return origins.enumerated().map { index, origin in
            guard origin != nil else { return nil }
            let v = buffer.contents().load(fromByteOffset: index * stride, as: SIMD4<Float>.self)
            guard v.w.isFinite, v.w > 0 else { return nil }
            let rgb = SIMD3(v.x, v.y, v.z) / v.w
            guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { return nil }
            return LinearSample(rgb: rgb, target: frame.target)
        }
    }

    /// The curve editor uses a bounded sRGB projection of the accepted displayed pixel.
    package static func sample(_ frame: DevelopmentScenePreviewFrameV1, at point: DevelopmentSourcePoint) -> Self? {
        guard let sample = linearSamples(frame, at: [point])[0], let space = sample.colorSpace,
              let rgb = CGColor(colorSpace: space, components: [CGFloat(sample.rgb.x), CGFloat(sample.rgb.y), CGFloat(sample.rgb.z), 1]),
              let encoded = rgb.converted(to: sRGB, intent: .relativeColorimetric, options: nil)?.components, encoded.count >= 3,
              let lab = rgb.converted(to: labSpace, intent: .relativeColorimetric, options: nil)?.components, lab.count >= 3 else { return nil }
        return .init(rgb: .init(encoded[0], encoded[1], encoded[2]), lab: .init(lab[0], lab[1], lab[2]))
    }
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
