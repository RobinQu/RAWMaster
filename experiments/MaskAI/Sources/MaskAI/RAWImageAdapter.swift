import Foundation
import CoreImage
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public struct RAWSourceInfo: Codable, Equatable, Sendable {
    public let sourceSHA256: String
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let analysisWidth: Int
    public let analysisHeight: Int
    public let exifOrientation: Int
    public let decoderVersion: String
    public let draftMode: Bool
}

public struct RAWLoadedImage: Sendable {
    public let image: NativeImage
    public let info: RAWSourceInfo
}

public enum RAWImageAdapter {
    /// Independent validation input. This intentionally does not call RAWMaster's renderer.
    public static func load(_ url: URL, maximumLongEdge: Int = 2400) throws -> RAWLoadedImage {
        guard let raw = CIRAWFilter(imageURL: url) else { throw MaskAIError.invalidInput("CIRAWFilter cannot open \(url.path).") }
        raw.scaleFactor = 1
        raw.isDraftModeEnabled = false
        guard let output = raw.outputImage, !output.extent.isEmpty else {
            throw MaskAIError.invalidInput("CIRAWFilter returned no image for \(url.path).")
        }
        let orientation = Int(raw.orientation.rawValue)
        let oriented = output.oriented(forExifOrientation: Int32(orientation))
        let nativeWidth = Int(oriented.extent.width.rounded())
        let nativeHeight = Int(oriented.extent.height.rounded())
        let image = try NativeImage(ciImage: oriented, maximumLongEdge: maximumLongEdge)
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        return RAWLoadedImage(image: image, info: RAWSourceInfo(sourceSHA256: digest,
                                                                 nativeWidth: nativeWidth, nativeHeight: nativeHeight,
                                                                 analysisWidth: image.width, analysisHeight: image.height,
                                                                 exifOrientation: orientation,
                                                                 decoderVersion: raw.decoderVersion.rawValue,
                                                                 draftMode: raw.isDraftModeEnabled))
    }

    /// Renders only a native-resolution crop; no full-size RGBA host buffer is allocated.
    public static func loadCrop(_ url: URL, rect: NormalizedRect) throws -> NativeImage {
        _ = try rect.validated()
        guard let raw = CIRAWFilter(imageURL: url) else { throw MaskAIError.invalidInput("CIRAWFilter cannot open \(url.path).") }
        raw.scaleFactor = 1
        raw.isDraftModeEnabled = false
        guard let output = raw.outputImage, !output.extent.isEmpty else {
            throw MaskAIError.invalidInput("CIRAWFilter returned no image for \(url.path).")
        }
        let oriented = output.oriented(forExifOrientation: Int32(Int(raw.orientation.rawValue)))
        let width = oriented.extent.width, height = oriented.extent.height
        // Match MaskImage: integral source pixels, lower bounds floor and upper bounds ceil.
        // NormalizedRect is top-left; CIImage source coordinates are bottom-left.
        let x0 = (rect.x * width).rounded(.down)
        let x1 = ((rect.x + rect.width) * width).rounded(.up)
        let y0 = ((1 - rect.y - rect.height) * height).rounded(.down)
        let y1 = ((1 - rect.y) * height).rounded(.up)
        let crop = CGRect(x: oriented.extent.minX + x0, y: oriented.extent.minY + y0,
                          width: x1 - x0, height: y1 - y0)
        let cropped = oriented.cropped(to: crop)
        return try NativeImage(ciImage: cropped, maximumLongEdge: max(Int(crop.width.rounded(.up)), Int(crop.height.rounded(.up))))
    }
}

public extension NativeImage {
    init(ciImage source: CIImage, maximumLongEdge: Int = 2048) throws {
        guard !source.extent.isEmpty else { throw MaskAIError.invalidInput("Cannot render an empty CIImage.") }
        let sourceWidth = Int(source.extent.width.rounded())
        let sourceHeight = Int(source.extent.height.rounded())
        let scale = min(1, Double(maximumLongEdge) / Double(max(sourceWidth, sourceHeight)))
        let translated = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let image = scale == 1 ? translated : translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(image.extent.width.rounded()))
        let height = max(1, Int(image.extent.height.rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        let destination = CIRenderDestination(bitmapData: &bytes, width: width, height: height,
                                               bytesPerRow: width * 4, format: .RGBA8)
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        destination.alphaMode = .premultiplied
        destination.isFlipped = true
        destination.isDithered = false
        _ = try context.startTask(toRender: image, from: CGRect(x: 0, y: 0, width: width, height: height),
                                  to: destination, at: .zero).waitUntilCompleted()
        try self.init(width: width, height: height, rgba: bytes)
    }

    func writePNG(to url: URL) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MaskAIError.invalidInput("Could not allocate RGBA output context.")
        }
        rgba.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            memcpy(context.data, base, bytes.count)
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MaskAIError.invalidInput("Could not create RGBA PNG destination.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MaskAIError.invalidInput("Could not encode RGBA PNG.") }
    }
}
