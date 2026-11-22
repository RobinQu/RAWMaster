import Foundation

/// An opt-in mosaic decoder. The default source decoder remains part of the recipe so switching off restores the same image.
public struct DevelopmentAIDenoiseV1: Codable, Equatable, Sendable {
    public enum Model: String, Codable, Sendable {
        case appleRAW9 = "apple-core-image-raw9-v1"
        case appleRAW9DNG = "apple-core-image-raw9-dng-v1"
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
    public var inputContract: String { "\(model.rawValue)/luminance-\(amount)" }
}
