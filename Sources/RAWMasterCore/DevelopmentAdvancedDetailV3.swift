import Foundation

/// Own application units; these are not measured Photos or ACR slider domains.
public struct DevelopmentDetailAmountV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var amount: Double
  public init(enabled: Bool = false, amount: Double = 0) { self.enabled = enabled; self.amount = amount }
  public func validate() throws { try DevelopmentV3Validation.range([amount],-100...100) }
  private enum CodingKeys: String, CodingKey { case enabled, amount }
  public init(from decoder: Decoder) throws { try RecipeCoding.requireKeys(decoder,["enabled","amount"]); let c = try decoder.container(keyedBy:CodingKeys.self); enabled = try c.decode(Bool.self,forKey:.enabled); amount = try c.decode(Double.self,forKey:.amount); try validate() }
  public func encode(to encoder: Encoder) throws { try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(enabled,forKey:.enabled); try c.encode(amount,forKey:.amount) }
}
public struct DevelopmentAdvancedDetailV3: Codable, Equatable, Sendable {
  public var version: Int
  public var texture, clarity, dehaze: DevelopmentDetailAmountV3
  public var preparedDehaze: DevelopmentPreparedDehazeV1?
  /// Durable intent after invalidation, not an airlight or proof. Absent in old JSON.
  public var dehazeAlgorithmVersion: Int?
  public var selectedDehazeAlgorithm: DevelopmentDehazeAlgorithm? {
    if let preparedDehaze { return DevelopmentDehazeAlgorithm(rawValue:preparedDehaze.algorithmVersion) }
    if let dehazeAlgorithmVersion { return DevelopmentDehazeAlgorithm(rawValue:dehazeAlgorithmVersion) }
    // An old nonzero unprepared recipe already expressed the original v1 effect.
    return dehaze.amount != 0 ? .v1:nil
  }
  public init(version: Int = 1, texture: DevelopmentDetailAmountV3 = .init(), clarity: DevelopmentDetailAmountV3 = .init(), dehaze: DevelopmentDetailAmountV3 = .init(), preparedDehaze: DevelopmentPreparedDehazeV1? = nil, dehazeAlgorithmVersion: Int? = nil) { self.version = version; self.texture = texture; self.clarity = clarity; self.dehaze = dehaze; self.preparedDehaze = preparedDehaze; self.dehazeAlgorithmVersion = dehazeAlgorithmVersion }
  public func validate() throws { guard version == 1 else { throw EditingError.invalidRecipe }; try texture.validate(); try clarity.validate(); try dehaze.validate(); try preparedDehaze?.validate(); if let dehazeAlgorithmVersion { guard DevelopmentDehazeAlgorithm(rawValue:dehazeAlgorithmVersion) != nil else { throw EditingError.invalidRecipe } } }
  public var hasEffects: Bool { [texture,clarity,dehaze].contains { $0.enabled && $0.amount != 0 } }
  private enum CodingKeys: String, CodingKey { case version, texture, clarity, dehaze, preparedDehaze, dehazeAlgorithmVersion }
  public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy:CodingKeys.self); try RecipeCoding.requireKeys(decoder,["version","texture","clarity","dehaze"] + (c.contains(.preparedDehaze) ? ["preparedDehaze"]:[]) + (c.contains(.dehazeAlgorithmVersion) ? ["dehazeAlgorithmVersion"]:[])); dehazeAlgorithmVersion = c.contains(.dehazeAlgorithmVersion) ? try c.decode(Int.self,forKey:.dehazeAlgorithmVersion):nil; preparedDehaze = c.contains(.preparedDehaze) ? try c.decode(DevelopmentPreparedDehazeV1.self,forKey:.preparedDehaze):nil; version = try c.decode(Int.self,forKey:.version); texture = try c.decode(DevelopmentDetailAmountV3.self,forKey:.texture); clarity = try c.decode(DevelopmentDetailAmountV3.self,forKey:.clarity); dehaze = try c.decode(DevelopmentDetailAmountV3.self,forKey:.dehaze); try validate() }
  public func encode(to encoder: Encoder) throws { try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(version,forKey:.version); try c.encode(texture,forKey:.texture); try c.encode(clarity,forKey:.clarity); try c.encode(dehaze,forKey:.dehaze); if let preparedDehaze { try c.encode(preparedDehaze,forKey:.preparedDehaze) }; if let dehazeAlgorithmVersion { try c.encode(dehazeAlgorithmVersion,forKey:.dehazeAlgorithmVersion) } }
}
