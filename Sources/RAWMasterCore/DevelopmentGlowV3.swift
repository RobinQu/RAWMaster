import Foundation

public enum DevelopmentGlowStyleV3: String, Codable, CaseIterable, Sendable {
  case bloom, diffusion, halation, motion, streak
  public var usesDirectionalControls: Bool { self == .motion || self == .streak }
}

/// Versioned, source-scale glow parameters. Direction is degrees clockwise in the working image.
public struct DevelopmentGlowV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var amount: Double
  public var style: DevelopmentGlowStyleV3
  public var range, spread, warmth, direction, softness: Double

  public init(enabled: Bool = false, amount: Double = 0, style: DevelopmentGlowStyleV3 = .bloom,
              range: Double = 50, spread: Double = 50, warmth: Double = 20,
              direction: Double = 0, softness: Double = 50) {
    self.enabled = enabled; self.amount = amount; self.style = style; self.range = range
    self.spread = spread; self.warmth = warmth; self.direction = direction; self.softness = softness
  }
  public var isActive: Bool { enabled && amount != 0 }
  public func validate() throws {
    try DevelopmentV3Validation.range([amount,range,spread,softness],0...100)
    try DevelopmentV3Validation.range([warmth],-100...100)
    try DevelopmentV3Validation.range([direction],0...360)
  }
  private enum CodingKeys: String, CodingKey { case enabled,amount,style,range,spread,warmth,direction,softness }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","amount","style","range","spread","warmth","direction","softness"])
    enabled = try c.decode(Bool.self,forKey:.enabled); amount = try c.decode(Double.self,forKey:.amount)
    style = try c.decode(DevelopmentGlowStyleV3.self,forKey:.style); range = try c.decode(Double.self,forKey:.range)
    spread = try c.decode(Double.self,forKey:.spread); warmth = try c.decode(Double.self,forKey:.warmth)
    direction = try c.decode(Double.self,forKey:.direction); softness = try c.decode(Double.self,forKey:.softness)
    try validate()
  }
}
