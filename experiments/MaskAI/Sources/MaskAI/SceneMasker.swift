import Foundation
import CryptoKit

public final class SceneMasker {
    private struct SceneAnalysis {
        let digest: String
        let width: Int
        let height: Int
        /// Softmax probabilities in [150,H,W] order.
        let probabilities: [Float]
    }

    private let paths: MaskAIModelPaths
    private var session: ONNXSession?
    private var analysis: SceneAnalysis?
    public private(set) var inferenceRunCount = 0
    public init(paths: MaskAIModelPaths) { self.paths = paths }
    public var hasLoadedSession: Bool { session != nil }
    public var hasCachedAnalysis: Bool { analysis != nil }
    public func releaseResources() { session = nil; analysis = nil }

    public func generate(from image: NativeImage, target: LandscapeMaskTarget, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        if target == .snow { return try generateSnow(from: image, cancellation: cancellation) }
        let started = Date()
        let scene = try analyze(image, cancellation: cancellation)
        let selected = Set(Self.ade20kIndices(for: target))
        var maskValues = [UInt8](repeating: 0, count: scene.width * scene.height)
        let plane = scene.width * scene.height
        for pixel in 0..<plane {
            var probability: Float = 0
            for classIndex in selected { probability += scene.probabilities[classIndex * plane + pixel] }
            maskValues[pixel] = UInt8((probability * 255).rounded().clamped(to: 0...255))
        }
        let mask = try MaskImage(width: scene.width, height: scene.height, values: maskValues)
            .resized(toWidth: image.width, toHeight: image.height)
        return MaskResult(mask: mask, metrics: MaskRunMetrics(elapsedMilliseconds: Date().timeIntervalSince(started) * 1000,
                                                              modelIDs: [MaskAIModel.efficientViT.rawValue]))
    }

    private func analyze(_ image: NativeImage, cancellation: ONNXCancellation?) throws -> SceneAnalysis {
        let digest = SHA256.hash(data: Data(image.rgba)).map { String(format: "%02x", $0) }.joined()
        if let analysis, analysis.digest == digest { return analysis }
        if session == nil { session = try ONNXSession(modelAt: paths.require(.efficientViT)) }
        guard let session else { throw MaskAIError.inferenceFailed("EfficientViT session was not created.") }
        let scale = 512 / Double(min(image.width, image.height))
        let width = max(32, Int((Double(image.width) * scale / 32).rounded(.up)) * 32)
        let height = max(32, Int((Double(image.height) * scale / 32).rounded(.up)) * 32)
        let resized = try image.resized(toWidth: width, toHeight: height)
        let input = try ONNXTensor.floats(resized.nchwFloat32(normalization: .imageNet), shape: [1, 3, height, width])
        let outputs = try session.run(inputs: [session.inputNames[0]: input], cancellation: cancellation)
        inferenceRunCount += 1
        guard let output = outputs[session.outputNames[0]] else { throw MaskAIError.inferenceFailed("EfficientViT returned no scene logits.") }
        let logits = try output.floats(), shape = output.shape
        guard shape.count == 4, shape[0] == 1, shape[1] == 150 else {
            throw MaskAIError.unsupportedTensor("Expected [1,150,H,W] ADE20K logits, got \(shape).")
        }
        let classes = 150, outputHeight = shape[2], outputWidth = shape[3], plane = outputHeight * outputWidth
        var probabilities = [Float](repeating: 0, count: logits.count)
        for pixel in 0..<plane {
            var maximum = -Float.greatestFiniteMagnitude
            for classIndex in 0..<classes { maximum = max(maximum, logits[classIndex * plane + pixel]) }
            var denominator: Float = 0
            for classIndex in 0..<classes { denominator += exp(logits[classIndex * plane + pixel] - maximum) }
            for classIndex in 0..<classes {
                probabilities[classIndex * plane + pixel] = exp(logits[classIndex * plane + pixel] - maximum) / denominator
            }
        }
        let result = SceneAnalysis(digest: digest, width: outputWidth, height: outputHeight, probabilities: probabilities)
        analysis = result
        return result
    }

    private func generateSnow(from image: NativeImage, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        let started = Date()
        // Compatibility experiment only: ADE20K has no snow class. Use terrain as a soft spatial prior,
        // then select bright, low-saturation pixels. This is not claimed to be Adobe-equivalent AI.
        let terrainTargets: [LandscapeMaskTarget] = [.mountains, .naturalGround, .artificialGround]
        var prior = MaskImage.empty(width: image.width, height: image.height)
        for target in terrainTargets {
            prior = try prior.combined(with: generate(from: image, target: target, cancellation: cancellation).mask, operation: .add)
        }
        var values = [UInt8](repeating: 0, count: image.width * image.height)
        for index in 0..<values.count {
            let red = Float(image.rgba[index * 4]) / 255
            let green = Float(image.rgba[index * 4 + 1]) / 255
            let blue = Float(image.rgba[index * 4 + 2]) / 255
            let high = max(red, green, blue), low = min(red, green, blue)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let saturation = high > 0 ? (high - low) / high : 0
            let brightnessWeight = min(1, max(0, (luminance - 0.55) / 0.25))
            let neutralWeight = min(1, max(0, (0.28 - saturation) / 0.20))
            let priorWeight = Float(prior.values[index]) / 255
            let spatialWeight = 0.25 + 0.75 * priorWeight
            values[index] = UInt8((255 * brightnessWeight * neutralWeight * spatialWeight).rounded().clamped(to: 0...255))
        }
        return MaskResult(mask: try MaskImage(width: image.width, height: image.height, values: values),
                          metrics: MaskRunMetrics(elapsedMilliseconds: Date().timeIntervalSince(started) * 1000,
                                                  modelIDs: [MaskAIModel.efficientViT.rawValue],
                                                  notes: ["Snow uses a terrain-guided color heuristic because ADE20K has no snow class."]))
    }

    public static func ade20kIndices(for target: LandscapeMaskTarget) -> [Int] {
        switch target {
        case .sky: return [2]
        case .architecture: return [0, 1, 25, 32, 39, 42, 48, 51, 61, 79, 84, 86, 88, 101, 106]
        case .vegetation: return [4, 9, 17, 66, 72]
        case .water: return [21, 26, 60, 104, 109, 113, 128]
        case .naturalGround: return [13, 29, 46, 68, 91, 94]
        case .artificialGround: return [3, 6, 11, 52, 53, 54, 59, 61, 140]
        case .mountains: return [16, 34, 68]
        case .snow: return []
        }
    }
}
