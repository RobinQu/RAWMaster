import Foundation

/// The model and its source domain are persisted so reopening cannot silently select a different denoiser.
public struct DevelopmentAIDenoiseV1: Codable, Equatable, Sendable {
    public enum Model: String, Codable, Sendable {
        case appleRAW9 = "apple-core-image-raw9-v1"
        case appleRAW9DNG = "apple-core-image-raw9-dng-v1"
        case photoVGG7 = "waifu2x-vgg7-photo-noise2-cc385f97-f32-v1"
        case photoVGG7OutputDNG = "waifu2x-vgg7-photo-noise2-cc385f97-output-dng-v1"
        case photoVGG7Chroma = "waifu2x-vgg7-photo-noise2-cc385f97-full-chroma-v2"
        case photoVGG7ChromaOutputDNG = "waifu2x-vgg7-photo-noise2-cc385f97-full-chroma-output-dng-v2"

        private var currentSourceModel: Self {
            switch self {
            case .photoVGG7: return .photoVGG7Chroma
            case .photoVGG7OutputDNG: return .photoVGG7ChromaOutputDNG
            default: return self
            }
        }
        public func isSupported(by capability: Self?) -> Bool { currentSourceModel == capability?.currentSourceModel }
        public var usesFullPhotoChroma: Bool { self == .photoVGG7Chroma || self == .photoVGG7ChromaOutputDNG }
        public var requiresMosaic: Bool { self == .appleRAW9 || self == .appleRAW9DNG }
        public var usesRAWInput: Bool { currentSourceModel != .photoVGG7Chroma }
    }
    public let model: Model
    public var amount: Int

    public init(model: Model, amount: Int = 50) { self.model = model; self.amount = amount }
    private enum CodingKeys: String, CodingKey { case model, amount }
    public init(from decoder: Decoder) throws {
        try RecipeCoding.requireKeys(decoder, ["model", "amount"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        model = try fields.decode(Model.self, forKey: .model)
        amount = try fields.decode(Int.self, forKey: .amount)
        try validate()
    }
    public func validate() throws {
        guard (0...100).contains(amount) else { throw EditingError.invalidRecipe }
    }
    public var inputContract: String {
        model.requiresMosaic ? "\(model.rawValue)/luminance-\(amount)" : "\(model.rawValue)/display-rgb-\(amount)"
    }
}
