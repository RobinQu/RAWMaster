import Foundation
import CoreImage
import CoreGraphics

public struct NativeImage: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major RGBA8, top-left origin, display-referred sRGB.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard width > 0, height > 0, rgba.count == width * height * 4 else {
            throw MaskAIError.invalidInput("RGBA dimensions do not match the pixel count.")
        }
        self.width = width; self.height = height; self.rgba = rgba
    }

    public init(contentsOf url: URL, maximumLongEdge: Int = 2048) throws {
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), !source.extent.isEmpty else {
            throw MaskAIError.invalidInput("Cannot read image at \(url.path).")
        }
        try self.init(ciImage: source, maximumLongEdge: maximumLongEdge)
    }

    public func resized(toWidth targetWidth: Int, toHeight targetHeight: Int) throws -> NativeImage {
        guard targetWidth > 0, targetHeight > 0 else { throw MaskAIError.invalidInput("Image target size must be positive.") }
        if targetWidth == width && targetHeight == height { return self }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                                      bytesPerRow: targetWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MaskAIError.invalidInput("Could not allocate image resize context.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let pointer = context.data else { throw MaskAIError.invalidInput("Missing resized image storage.") }
        let bytes = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: targetWidth * targetHeight * 4))
        return try NativeImage(width: targetWidth, height: targetHeight, rgba: bytes)
    }

    public func cropped(to rect: NormalizedRect) throws -> NativeImage {
        _ = try rect.validated()
        let x0 = Int((rect.x * Double(width)).rounded(.down))
        let y0 = Int((rect.y * Double(height)).rounded(.down))
        let x1 = min(width, max(x0 + 1, Int(((rect.x + rect.width) * Double(width)).rounded(.up))))
        let y1 = min(height, max(y0 + 1, Int(((rect.y + rect.height) * Double(height)).rounded(.up))))
        var output = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0) * 4)
        for y in y0..<y1 {
            let sourceStart = (y * width + x0) * 4
            let destinationStart = (y - y0) * (x1 - x0) * 4
            output[destinationStart..<(destinationStart + (x1 - x0) * 4)] = rgba[sourceStart..<(sourceStart + (x1 - x0) * 4)]
        }
        return try NativeImage(width: x1 - x0, height: y1 - y0, rgba: output)
    }

    public func nchwFloat32(normalization: TensorNormalization) -> [Float] {
        let plane = width * height
        var result = [Float](repeating: 0, count: plane * 3)
        for index in 0..<plane {
            for channel in 0..<3 {
                let value = Float(rgba[index * 4 + channel]) / 255
                result[channel * plane + index] = normalization.apply(value, channel: channel)
            }
        }
        return result
    }

    public func nhwcFloat32(normalization: TensorNormalization = .zeroToOne) -> [Float] {
        var result = [Float](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                result[index * 3 + channel] = normalization.apply(Float(rgba[index * 4 + channel]) / 255, channel: channel)
            }
        }
        return result
    }

    public func bgrNCHWFloat32() -> [Float] {
        let plane = width * height
        var result = [Float](repeating: 0, count: plane * 3)
        for index in 0..<plane {
            for channel in 0..<3 {
                let rgbaChannel = 2 - channel
                result[channel * plane + index] = Float(rgba[index * 4 + rgbaChannel])
            }
        }
        return result
    }
}

public enum TensorNormalization: Sendable {
    case zeroToOne
    case centeredHalf
    case imageNet

    func apply(_ value: Float, channel: Int) -> Float {
        switch self {
        case .zeroToOne: return value
        case .centeredHalf: return value - 0.5
        case .imageNet:
            let mean: [Float] = [0.485, 0.456, 0.406]
            let std: [Float] = [0.229, 0.224, 0.225]
            return (value - mean[channel]) / std[channel]
        }
    }
}
