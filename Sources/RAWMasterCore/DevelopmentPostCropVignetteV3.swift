import Foundation

public enum DevelopmentPostCropVignetteStyleV3: String, Codable, CaseIterable, Sendable {
  case highlightPriority, colorPriority, paintOverlay
}

/// Post-crop coordinates are always the final oriented geometry canvas, not the RAW sensor canvas.
public struct DevelopmentPostCropVignetteV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var amount: Double
  public var style: DevelopmentPostCropVignetteStyleV3
  public var midpoint, roundness, feather, highlights: Double

  public init(enabled: Bool = false, amount: Double = 0, style: DevelopmentPostCropVignetteStyleV3 = .highlightPriority,
              midpoint: Double = 50, roundness: Double = 0, feather: Double = 50, highlights: Double = 0) {
    self.enabled = enabled; self.amount = amount; self.style = style; self.midpoint = midpoint
    self.roundness = roundness; self.feather = feather; self.highlights = highlights
  }
  public var isActive: Bool { enabled && amount != 0 }
  public func validate() throws {
    try DevelopmentV3Validation.range([amount],-100...100)
    try DevelopmentV3Validation.range([midpoint,feather,highlights],0...100)
    try DevelopmentV3Validation.range([roundness],-100...100)
  }
  private enum CodingKeys: String, CodingKey { case enabled,amount,style,midpoint,roundness,feather,highlights }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","amount","style","midpoint","roundness","feather","highlights"])
    enabled = try c.decode(Bool.self,forKey:.enabled); amount = try c.decode(Double.self,forKey:.amount)
    style = try c.decode(DevelopmentPostCropVignetteStyleV3.self,forKey:.style)
    midpoint = try c.decode(Double.self,forKey:.midpoint); roundness = try c.decode(Double.self,forKey:.roundness)
    feather = try c.decode(Double.self,forKey:.feather); highlights = try c.decode(Double.self,forKey:.highlights)
    try validate()
  }
}
