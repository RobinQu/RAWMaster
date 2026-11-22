import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreImage

public enum MaskAIError: Error, CustomStringConvertible {
    case invalidInput(String)
    case modelUnavailable(String)
    case inferenceFailed(String)
    case unsupportedTensor(String)
    case snapshotFailure(String)
    case cancelled
    case noSubject
    case noPeople
    case noFace(person: Int)

    public var description: String {
        switch self {
        case .invalidInput(let message): return "Invalid input: \(message)"
        case .modelUnavailable(let message): return "Model unavailable: \(message)"
        case .inferenceFailed(let message): return "Inference failed: \(message)"
        case .unsupportedTensor(let message): return "Unsupported tensor: \(message)"
        case .snapshotFailure(let message): return "Snapshot failure: \(message)"
        case .cancelled: return "The AI operation was cancelled."
        case .noSubject: return "No foreground subject was detected."
        case .noPeople: return "No people were detected."
        case .noFace(let person): return "No face was detected for person \(person + 1)."
        }
    }
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func validated() throws -> NormalizedPoint {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw MaskAIError.invalidInput("Point coordinates must be finite and normalized to 0...1.")
        }
        return self
    }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func validated() throws -> NormalizedRect {
        guard [x, y, width, height].allSatisfy({ $0.isFinite }), x >= 0, y >= 0,
              width > 0, height > 0, x + width <= 1, y + height <= 1 else {
            throw MaskAIError.invalidInput("Rectangle must be a non-empty normalized region inside the image.")
        }
        return self
    }
}

public struct ObjectPrompt: Codable, Equatable, Sendable {
    public var positivePoints: [NormalizedPoint]
    public var negativePoints: [NormalizedPoint]
    public var box: NormalizedRect?
    public init(positivePoints: [NormalizedPoint] = [], negativePoints: [NormalizedPoint] = [], box: NormalizedRect? = nil) {
        self.positivePoints = positivePoints
        self.negativePoints = negativePoints
        self.box = box
    }
    public func validated() throws -> ObjectPrompt {
        guard positivePoints.count + negativePoints.count <= 32 else {
            throw MaskAIError.invalidInput("A maximum of 32 prompt points is supported.")
        }
        guard !positivePoints.isEmpty || box != nil else {
            throw MaskAIError.invalidInput("An object prompt needs a positive point or a box.")
        }
        _ = try positivePoints.map { try $0.validated() }
        _ = try negativePoints.map { try $0.validated() }
        _ = try box?.validated()
        return self
    }
}

public enum LandscapeMaskTarget: String, Codable, CaseIterable, Sendable {
    case sky, snow, architecture, vegetation, water, naturalGround, artificialGround, mountains
}

public enum PersonMaskTarget: String, Codable, CaseIterable, Sendable {
    case entirePerson, faceSkin, bodySkin, eyebrows, eyeSclera, irisPupil, lips, teeth, hair, clothes
}

public struct MaskImage: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, top-left origin, 0 = unselected and 255 = fully selected.
    public let values: [UInt8]

    public init(width: Int, height: Int, values: [UInt8]) throws {
        guard width > 0, height > 0, values.count == width * height else {
            throw MaskAIError.invalidInput("Mask dimensions do not match the pixel count.")
        }
        self.width = width; self.height = height; self.values = values
    }

    public static func empty(width: Int, height: Int) -> MaskImage {
        try! MaskImage(width: width, height: height, values: [UInt8](repeating: 0, count: width * height))
    }

    public static func full(width: Int, height: Int) -> MaskImage {
        try! MaskImage(width: width, height: height, values: [UInt8](repeating: 255, count: width * height))
    }

    public var coverage: Double {
        Double(values.reduce(0) { $0 + Int($1) }) / Double(max(1, values.count * 255))
    }
    public var selectedPixelCount: Int { values.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } }
    public var isEmpty: Bool { !values.contains(where: { $0 > 0 }) }

    public func inverted() -> MaskImage {
        try! MaskImage(width: width, height: height, values: values.map { 255 - $0 })
    }

    public func combined(with other: MaskImage, operation: MaskCombineOperation) throws -> MaskImage {
        guard width == other.width, height == other.height else {
            throw MaskAIError.invalidInput("Combined masks must have identical dimensions.")
        }
        let result = zip(values, other.values).map { a, b -> UInt8 in
            switch operation {
            case .add:
                return UInt8((Int(a) + Int(b) - Int(a) * Int(b) / 255).clamped(to: 0...255))
            case .subtract:
                return UInt8((Int(a) * (255 - Int(b)) / 255).clamped(to: 0...255))
            case .intersect:
                return UInt8(Int(a) * Int(b) / 255)
            }
        }
        return try MaskImage(width: width, height: height, values: result)
    }

    public func resized(toWidth targetWidth: Int, toHeight targetHeight: Int) throws -> MaskImage {
        guard targetWidth > 0, targetHeight > 0 else { throw MaskAIError.invalidInput("Mask target size must be positive.") }
        if targetWidth == width && targetHeight == height { return self }
        let source = CIImage(bitmapData: Data(values), bytesPerRow: width,
                             size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: Double(targetWidth) / Double(width),
                                                               y: Double(targetHeight) / Double(height)))
        let normalized = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX,
                                                                   y: -scaled.extent.minY))
        var output = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        let destination = CIRenderDestination(bitmapData: &output, width: targetWidth, height: targetHeight,
                                               bytesPerRow: targetWidth, format: .L8)
        destination.colorSpace = nil
        destination.isFlipped = true
        destination.isDithered = false
        let context = CIContext(options: [.cacheIntermediates: false])
        _ = try context.startTask(toRender: normalized, from: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                                  to: destination, at: .zero).waitUntilCompleted()
        return try MaskImage(width: targetWidth, height: targetHeight, values: output)
    }

    public func cropped(to rect: NormalizedRect) throws -> MaskImage {
        _ = try rect.validated()
        let x0 = Int((rect.x * Double(width)).rounded(.down))
        let y0 = Int((rect.y * Double(height)).rounded(.down))
        let x1 = min(width, max(x0 + 1, Int(((rect.x + rect.width) * Double(width)).rounded(.up))))
        let y1 = min(height, max(y0 + 1, Int(((rect.y + rect.height) * Double(height)).rounded(.up))))
        var output = [UInt8](); output.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { output.append(contentsOf: values[(y * width + x0)..<(y * width + x1)]) }
        return try MaskImage(width: x1 - x0, height: y1 - y0, values: output)
    }

    public func writePNG(to url: URL) throws {
        let data = Data(values) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MaskAIError.invalidInput("Could not create the PNG destination.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MaskAIError.invalidInput("Could not encode mask PNG.") }
    }
}

public enum MaskCombineOperation: String, Codable, Sendable { case add, subtract, intersect }

public struct MaskRunMetrics: Codable, Equatable, Sendable {
    public var elapsedMilliseconds: Double
    public var modelIDs: [String]
    public var notes: [String]
    public init(elapsedMilliseconds: Double, modelIDs: [String], notes: [String] = []) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.modelIDs = modelIDs
        self.notes = notes
    }
}

public struct MaskResult: Sendable {
    public var mask: MaskImage
    public var metrics: MaskRunMetrics
    public init(mask: MaskImage, metrics: MaskRunMetrics) { self.mask = mask; self.metrics = metrics }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
