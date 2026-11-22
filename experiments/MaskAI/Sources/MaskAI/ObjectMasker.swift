import Foundation
import CryptoKit

public final class ObjectMasker {
    private struct EmbeddingState {
        let digest: String
        let originalWidth: Int
        let originalHeight: Int
        let resizedWidth: Int
        let resizedHeight: Int
        let embedding: ONNXTensor
        let positionalEmbedding: ONNXTensor
    }

    private let paths: MaskAIModelPaths
    private var encoder: ONNXSession?
    private var decoder: ONNXSession?
    private var embeddingState: EmbeddingState?
    public private(set) var encoderRunCount = 0
    public private(set) var decoderRunCount = 0

    public init(paths: MaskAIModelPaths) { self.paths = paths }
    public var hasLoadedSessions: Bool { encoder != nil || decoder != nil }
    public var hasCachedEmbedding: Bool { embeddingState != nil }
    public func releaseResources() { encoder = nil; decoder = nil; embeddingState = nil }

    public func generate(from image: NativeImage, prompt: ObjectPrompt, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        try generateCandidates(from: image, prompt: prompt, cancellation: cancellation)[0]
    }

    public func generateCandidates(from image: NativeImage, prompt: ObjectPrompt, cancellation: ONNXCancellation? = nil) throws -> [MaskResult] {
        _ = try prompt.validated()
        let started = Date()
        let state = try prepareEmbedding(for: image, cancellation: cancellation)
        if decoder == nil { decoder = try ONNXSession(modelAt: paths.require(.slimSAMDecoder)) }
        guard let decoder else { throw MaskAIError.inferenceFailed("SlimSAM decoder was not created.") }

        var points: [(x: Double, y: Double, label: Int64)] = []
        var addedBoxCenter = false
        if let box = prompt.box, prompt.positivePoints.isEmpty {
            // The Q8 box-only path selected background in validation. A center positive point
            // restores the intended rectangle workflow while preserving the user's box bounds.
            points.append((box.x + box.width / 2, box.y + box.height / 2, 1))
            addedBoxCenter = true
        }
        points.append(contentsOf: prompt.positivePoints.map { ($0.x, $0.y, 1) })
        points.append(contentsOf: prompt.negativePoints.map { ($0.x, $0.y, 0) })
        if let box = prompt.box {
            points.append((box.x, box.y, 2))
            points.append((box.x + box.width, box.y + box.height, 3))
        }
        let coordinates = points.flatMap { point in
            [Float(point.x * Double(state.resizedWidth)), Float(point.y * Double(state.resizedHeight))]
        }
        let labels = points.map { $0.label }
        // These are the observed inputs of Lightflow's native-CPU Q8 SlimSAM export.
        let inputs: [String: ONNXTensor] = try [
            "image_embeddings": state.embedding,
            "image_positional_embeddings": state.positionalEmbedding,
            "input_points": .floats(coordinates, shape: [1, 1, points.count, 2]),
            "input_labels": .int64s(labels, shape: [1, 1, points.count]),
        ]
        let outputs = try decoder.run(inputs: inputs, cancellation: cancellation)
        decoderRunCount += 1
        try cancellation?.throwIfCancelled()
        guard let masks = outputs["pred_masks"] ?? outputs[decoder.outputNames.first(where: { $0.contains("mask") }) ?? ""],
              let scores = outputs["iou_scores"] ?? outputs[decoder.outputNames.first(where: { $0.contains("iou") }) ?? ""] else {
            throw MaskAIError.inferenceFailed("SlimSAM decoder did not return pred_masks and iou_scores.")
        }
        let maskValues = try masks.floats()
        let scoreValues = try scores.floats()
        guard masks.elementCount == 3 * 256 * 256,
              masks.shape.suffix(3) == [3, 256, 256], scoreValues.count >= 3 else {
            throw MaskAIError.unsupportedTensor("Unexpected SlimSAM outputs: \(masks.shape), scores \(scores.shape).")
        }
        let order = [0, 1, 2].sorted { scoreValues[$0] > scoreValues[$1] }
        return try order.map { candidate in
            try cancellation?.throwIfCancelled()
            let start = candidate * 256 * 256
            let probabilities = (0..<(256 * 256)).map { index in
                let logit = maskValues[start + index]
                return UInt8((255 / (1 + exp(-logit))).rounded().clamped(to: 0...255))
            }
            let square = try MaskImage(width: 256, height: 256, values: probabilities)
                .resized(toWidth: 1024, toHeight: 1024)
            let content = try square.cropped(to: NormalizedRect(x: 0, y: 0,
                                                                 width: Double(state.resizedWidth) / 1024,
                                                                 height: Double(state.resizedHeight) / 1024))
            let mask = try content.resized(toWidth: image.width, toHeight: image.height)
            return MaskResult(mask: mask, metrics: MaskRunMetrics(elapsedMilliseconds: Date().timeIntervalSince(started) * 1000,
                                                                  modelIDs: [MaskAIModel.slimSAMEncoder.rawValue, MaskAIModel.slimSAMDecoder.rawValue],
                                                                  notes: ["candidate=\(candidate)", "predictedIoU=\(scoreValues[candidate])",
                                                                          "encoderRuns=\(encoderRunCount)", "decoderRuns=\(decoderRunCount)",
                                                                          "addedBoxCenter=\(addedBoxCenter)"]))
        }
    }

    private func prepareEmbedding(for image: NativeImage, cancellation: ONNXCancellation?) throws -> EmbeddingState {
        let digest = SHA256.hash(data: Data(image.rgba)).map { String(format: "%02x", $0) }.joined()
        if let embeddingState, embeddingState.digest == digest { return embeddingState }
        if encoder == nil { encoder = try ONNXSession(modelAt: paths.require(.slimSAMEncoder)) }
        guard let encoder else { throw MaskAIError.inferenceFailed("SlimSAM encoder was not created.") }
        let scale = 1024 / Double(max(image.width, image.height))
        let resizedWidth = max(1, Int((Double(image.width) * scale).rounded()))
        let resizedHeight = max(1, Int((Double(image.height) * scale).rounded()))
        let resized = try image.resized(toWidth: resizedWidth, toHeight: resizedHeight)
        let source = resized.nchwFloat32(normalization: .imageNet)
        let plane = 1024 * 1024
        var padded = [Float](repeating: 0, count: plane * 3)
        for channel in 0..<3 {
            for y in 0..<resizedHeight {
                let sourceStart = channel * resizedWidth * resizedHeight + y * resizedWidth
                let destinationStart = channel * plane + y * 1024
                padded[destinationStart..<(destinationStart + resizedWidth)] = source[sourceStart..<(sourceStart + resizedWidth)]
            }
        }
        let input = try ONNXTensor.floats(padded, shape: [1, 3, 1024, 1024])
        let outputs = try encoder.run(inputs: [encoder.inputNames[0]: input], cancellation: cancellation)
        encoderRunCount += 1
        guard let embedding = outputs["image_embeddings"], let positional = outputs["image_positional_embeddings"] else {
            throw MaskAIError.inferenceFailed("SlimSAM encoder returned incomplete embeddings.")
        }
        let state = EmbeddingState(digest: digest, originalWidth: image.width, originalHeight: image.height,
                                   resizedWidth: resizedWidth, resizedHeight: resizedHeight,
                                   embedding: embedding, positionalEmbedding: positional)
        embeddingState = state
        return state
    }
}
