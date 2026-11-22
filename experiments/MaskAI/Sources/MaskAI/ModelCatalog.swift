import Foundation

public enum MaskAIModel: String, Codable, CaseIterable, Sendable {
    case isnet = "isnet-general"
    case efficientViT = "efficientvit-seg-b2-ade20k"
    case slimSAMEncoder = "slimsam-encoder"
    case slimSAMDecoder = "slimsam-decoder"
    case dFine = "dfine-s-coco"
    case selfieMulticlass = "selfie-multiclass"
    case yuNet = "yunet"
    case faceLandmarks = "face-landmarks"

    public var relativePath: String {
        switch self {
        case .isnet: return "isnet-general/model_fp16.onnx"
        case .efficientViT: return "efficientvit-seg-b2-ade20k/model.onnx"
        case .slimSAMEncoder: return "slimsam/vision_encoder_quantized.onnx"
        case .slimSAMDecoder: return "slimsam/prompt_encoder_mask_decoder_quantized.onnx"
        case .dFine: return "dfine-s-coco/model_quantized.onnx"
        case .selfieMulticlass: return "selfie-multiclass/model.onnx"
        case .yuNet: return "yunet/face_detection_yunet_2023mar.onnx"
        case .faceLandmarks: return "face-landmarks/model.onnx"
        }
    }

    public var expectedSHA256: String {
        switch self {
        case .isnet: return "0857167263ad816d67c26852b99c2861e46a86c9a889527061a5eb2a6f90d32c"
        case .efficientViT: return "e6df30d2fa120b86364e0b5158a278f4550fd9f1ebeda3ec342683da55872f7d"
        case .slimSAMEncoder: return "cce23c7b2e5d4f330932738fb67ba518e04b0d99ccdd1cccd22a7da4e01f2971"
        case .slimSAMDecoder: return "cb90b279f549d2cab7fd6e20c38522438c65d84bdcca3d2a764cff7d857fdce2"
        case .dFine: return "1929a508f43c2d60f62f32308506cec21b31c7e4518c5e0458ca75688d6faa8f"
        case .selfieMulticlass: return "35ec1ecd9ee7f85073c99c00020b7f6751b69506eeacf683bc8665f6117f85b0"
        case .yuNet: return "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
        case .faceLandmarks: return "7d6e82dee82a1dca5fbddb282b3cc74571833a530de317fc22ae325c3358beeb"
        }
    }
}

public struct MaskAIModelPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func url(for model: MaskAIModel) -> URL { root.appending(path: model.relativePath) }
    public func require(_ model: MaskAIModel) throws -> URL {
        let url = url(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MaskAIError.modelUnavailable("\(model.rawValue): run Scripts/download-dependencies.sh first (\(url.path)).")
        }
        return url
    }
}
