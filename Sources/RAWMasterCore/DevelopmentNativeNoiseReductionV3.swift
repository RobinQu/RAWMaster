import Foundation

public enum DevelopmentNativeParameterError: Error, Equatable, Sendable { case invalidDefaults, unsupportedNoiseReduction, unsupportedVersion }
/// Pure values attested by the native decoder, not inferred from an extension or a UI preset.
public struct DevelopmentRAWNoiseReductionDefaultsV3: Equatable, Sendable {
  public let luminance, color, detail: Float
  public let luminanceSupported, colorSupported, detailSupported: Bool
  public init(luminance: Float, color: Float, detail: Float, luminanceSupported: Bool, colorSupported: Bool, detailSupported: Bool) {
    self.luminance = luminance; self.color = color; self.detail = detail
    self.luminanceSupported = luminanceSupported; self.colorSupported = colorSupported; self.detailSupported = detailSupported
  }
  public func validate() throws {
    guard luminance.isFinite, color.isFinite, detail.isFinite, (0...1).contains(luminance), (0...1).contains(color), (0...3).contains(detail) else { throw DevelopmentNativeParameterError.invalidDefaults }
  }
  public func resolving(_ p: DevelopmentNoiseReductionV3) throws -> DevelopmentRAWNoiseReductionParametersV3 {
    try validate(); try p.validate(for:.raw)
    guard p.nativeMappingVersion == 1 else { throw DevelopmentNativeParameterError.unsupportedVersion }
    func target(_ ui: Double, baseline: Float, negativeSpan: Double, maximum: Double, supported: Bool) throws -> UInt32 {
      guard p.enabled, ui != 0 else { return baseline.bitPattern }
      guard supported else { throw DevelopmentNativeParameterError.unsupportedNoiseReduction }
      let d = Double(baseline)
      let value = ui < 0 ? d*(1+ui/negativeSpan):d+(maximum-d)*(ui/maximum)
      let result = Float(value)
      guard result.isFinite, (0...Float(maximum)).contains(result) else { throw DevelopmentNativeParameterError.invalidDefaults }
      return result.bitPattern
    }
    return try .init(version:1,
      luminanceBits:target(p.luminanceNoise,baseline:luminance,negativeSpan:0.1,maximum:1,supported:luminanceSupported),
      colorBits:target(p.colorNoise,baseline:color,negativeSpan:1,maximum:1,supported:colorSupported),
      detailBits:target(p.detail,baseline:detail,negativeSpan:1,maximum:3,supported:detailSupported))
  }
}
/// Exact effective Float bits are suitable native-key inputs. Defaults/support identity is keyed
/// separately by the decoder fingerprint; zero/off preserve the original bits without arithmetic.
public struct DevelopmentRAWNoiseReductionParametersV3: Codable, Equatable, Sendable {
  public let version: Int
  public let luminanceBits, colorBits, detailBits: UInt32
  public var luminance: Float { Float(bitPattern:luminanceBits) }
  public var color: Float { Float(bitPattern:colorBits) }
  public var detail: Float { Float(bitPattern:detailBits) }
  public init(version: Int = 1, luminanceBits: UInt32, colorBits: UInt32, detailBits: UInt32) throws {
    self.version = version; self.luminanceBits = luminanceBits; self.colorBits = colorBits; self.detailBits = detailBits; try validate()
  }
  public func validate() throws {
    guard version == 1 else { throw DevelopmentNativeParameterError.unsupportedVersion }
    guard luminance.isFinite, color.isFinite, detail.isFinite, (0...1).contains(luminance), (0...1).contains(color), (0...3).contains(detail) else { throw DevelopmentNativeParameterError.invalidDefaults }
  }
  private enum CodingKeys: String, CodingKey { case version, luminanceBits, colorBits, detailBits }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["version","luminanceBits","colorBits","detailBits"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    version = try c.decode(Int.self,forKey:.version); luminanceBits = try c.decode(UInt32.self,forKey:.luminanceBits)
    colorBits = try c.decode(UInt32.self,forKey:.colorBits); detailBits = try c.decode(UInt32.self,forKey:.detailBits); try validate()
  }
  public func encode(to encoder: Encoder) throws { try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(version,forKey:.version); try c.encode(luminanceBits,forKey:.luminanceBits); try c.encode(colorBits,forKey:.colorBits); try c.encode(detailBits,forKey:.detailBits) }
}
