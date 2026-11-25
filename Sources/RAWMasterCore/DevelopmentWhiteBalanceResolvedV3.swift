import Foundation

public enum DevelopmentWhiteBalanceModeV3: String, Codable, Sendable { case asShot, temperatureTint, neutralGray, skinTone }

/// The sole native target representation. As-shot does not replay this value: its fresh decoder
/// neutral remains untouched, and the captured default TT is diagnostic metadata only.
public struct DevelopmentNativeWhiteBalanceV3: Codable, Equatable, Sendable {
  public var temperatureBits, tintBits: UInt32
  public var temperature: Float { Float(bitPattern:temperatureBits) }
  public var tint: Float { Float(bitPattern:tintBits) }
  public init(temperature: Float, tint: Float) { temperatureBits = temperature.bitPattern; tintBits = tint.bitPattern }
  public func validate() throws {
    guard temperature.isFinite, tint.isFinite, (2000...50000).contains(temperature), (-150...150).contains(tint) else { throw EditingError.invalidRecipe }
  }
  private enum CodingKeys: String, CodingKey { case temperatureBits, tintBits }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["temperatureBits","tintBits"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    temperatureBits = try c.decode(UInt32.self,forKey:.temperatureBits); tintBits = try c.decode(UInt32.self,forKey:.tintBits); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(temperatureBits,forKey:.temperatureBits); try c.encode(tintBits,forKey:.tintBits)
  }
}
public struct DevelopmentRawWhiteBalancePickV3: Codable, Equatable, Sendable {
  public var version: Int
  public var baseline: DevelopmentNativeWhiteBalanceV3
  public var warmth: Double
  /// An unpicked construction-default baseline keeps native as-shot neutral untouched at zero.
  /// A real picker always stores false, so its TT remains the sole picked-target authority.
  public var usesSourceDefaultAtZero: Bool
  public init(baseline: DevelopmentNativeWhiteBalanceV3, warmth: Double = 0, version: Int = 1, usesSourceDefaultAtZero: Bool = false) { self.version = version; self.baseline = baseline; self.warmth = warmth; self.usesSourceDefaultAtZero = usesSourceDefaultAtZero }
  public func validate() throws {
    guard version == 1 else { throw EditingError.invalidRecipe }; try baseline.validate(); try DevelopmentV3Validation.range([warmth],-0.5...0.5)
    _ = try target()
  }
  public func target() throws -> DevelopmentNativeWhiteBalanceV3 {
    guard version == 1 else { throw EditingError.invalidRecipe }; try baseline.validate(); try DevelopmentV3Validation.range([warmth],-0.5...0.5)
    if warmth == 0 { return baseline }
    let mired = 1e6/Double(baseline.temperature)-80*warmth
    guard mired.isFinite, mired > 0 else { throw EditingError.invalidRecipe }
    let result = DevelopmentNativeWhiteBalanceV3(temperature:Float(1e6/mired),tint:baseline.tint); try result.validate(); return result
  }
  private enum CodingKeys: String, CodingKey { case version, baseline, warmth, usesSourceDefaultAtZero }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["version","baseline","warmth"]+(c.contains(.usesSourceDefaultAtZero) ? ["usesSourceDefaultAtZero"]:[]))
    usesSourceDefaultAtZero = c.contains(.usesSourceDefaultAtZero) ? try c.decode(Bool.self,forKey:.usesSourceDefaultAtZero):false
    version = try c.decode(Int.self,forKey:.version); baseline = try c.decode(DevelopmentNativeWhiteBalanceV3.self,forKey:.baseline); warmth = try c.decode(Double.self,forKey:.warmth); try validate()
  }
  public func encode(to encoder: Encoder) throws { try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(version,forKey:.version); try c.encode(baseline,forKey:.baseline); try c.encode(warmth,forKey:.warmth); if usesSourceDefaultAtZero { try c.encode(true,forKey:.usesSourceDefaultAtZero) } }
}

/// Row-major coefficients acting on linear-sRGB COLUMN vectors. Bits preserve a picked baseline.
public struct DevelopmentRGBMatrixV3: Codable, Equatable, Sendable {
  public var bits: [UInt64]
  public var values: [Double] { bits.map(Double.init(bitPattern:)) }
  public init(_ values: [Double]) { bits = values.map(\.bitPattern) }
  public static let identity = Self([1,0,0,0,1,0,0,0,1])
  public func validate() throws {
    let a = values
    guard a.count == 9, a.allSatisfy({ $0.isFinite && abs($0) <= 16 }) else { throw EditingError.invalidRecipe }
    let inverse = try Self.inverse(a)
    let norm = Self.rowSumNorm(a), inverseNorm = Self.rowSumNorm(inverse)
    guard norm*inverseNorm <= 1024 else { throw EditingError.invalidRecipe }
  }
  public func applying(to rgb: DevelopmentSampledColorV3) throws -> DevelopmentSampledColorV3 {
    try validate(); try rgb.validate(); let v = Self.apply(values,[rgb.red,rgb.green,rgb.blue])
    return .init(red:v[0],green:v[1],blue:v[2])
  }
  static func apply(_ a: [Double], _ v: [Double]) -> [Double] {
    (0..<3).map { (r: Int) -> Double in
      (0..<3).reduce(0.0) { (sum: Double, k: Int) -> Double in sum+a[r*3+k]*v[k] }
    }
  }
  static func rowSumNorm(_ m: [Double]) -> Double {
    var maximum = 0.0
    for r in 0..<3 {
      var sum = 0.0
      for k in 0..<3 { sum += abs(m[r*3+k]) }
      maximum = max(maximum, sum)
    }
    return maximum
  }
  static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
    (0..<9).map { (i: Int) -> Double in
      let row = (i/3)*3, column = i%3
      return (0..<3).reduce(0.0) { (sum: Double, k: Int) -> Double in
        sum+a[row+k]*b[k*3+column]
      }
    }
  }
  static func inverse(_ a: [Double]) throws -> [Double] {
    guard a.count == 9 else { throw EditingError.invalidRecipe }
    let d = a[0]*(a[4]*a[8]-a[5]*a[7])-a[1]*(a[3]*a[8]-a[5]*a[6])+a[2]*(a[3]*a[7]-a[4]*a[6])
    guard d.isFinite, abs(d)>1e-8 else { throw EditingError.invalidRecipe }
    return [a[4]*a[8]-a[5]*a[7],a[2]*a[7]-a[1]*a[8],a[1]*a[5]-a[2]*a[4],
      a[5]*a[6]-a[3]*a[8],a[0]*a[8]-a[2]*a[6],a[2]*a[3]-a[0]*a[5],
      a[3]*a[7]-a[4]*a[6],a[1]*a[6]-a[0]*a[7],a[0]*a[4]-a[1]*a[3]].map { $0/d }
  }
  private enum CodingKeys: String, CodingKey { case bits }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["bits"]); let c = try decoder.container(keyedBy:CodingKeys.self); var a = try c.nestedUnkeyedContainer(forKey:.bits)
    if let count = a.count, count != 9 { throw EditingError.invalidRecipe }; bits = []; bits.reserveCapacity(9)
    while !a.isAtEnd { guard bits.count < 9 else { throw EditingError.invalidRecipe }; bits.append(try a.decode(UInt64.self)) }; try validate()
  }
  public func encode(to encoder: Encoder) throws { try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(bits,forKey:.bits) }
}

public struct DevelopmentImageWhiteBalancePickV3: Codable, Equatable, Sendable {
  public var version: Int
  public var baseline: DevelopmentRGBMatrixV3
  public var sampledLinearRGB: DevelopmentSampledColorV3
  public var warmth: Double
  public init(baseline: DevelopmentRGBMatrixV3, sampledLinearRGB: DevelopmentSampledColorV3, warmth: Double = 0, version: Int = 1) {
    self.version = version; self.baseline = baseline; self.sampledLinearRGB = sampledLinearRGB; self.warmth = warmth
  }
  static let rgbToXYZ = [0.4124564,0.3575761,0.1804375,0.2126729,0.7151522,0.0721750,0.0193339,0.1191920,0.9503041]
  static let bradford = [0.8951,0.2664,-0.1614,-0.7502,1.7135,0.0367,0.0389,-0.0685,1.0296]
  public func validate() throws {
    guard version == 1 else { throw EditingError.invalidRecipe }; try baseline.validate(); try sampledLinearRGB.validate(); try DevelopmentV3Validation.range([warmth],-0.5...0.5)
    let s = [sampledLinearRGB.red,sampledLinearRGB.green,sampledLinearRGB.blue]
    guard s.allSatisfy({ $0 >= 0 && $0 <= 64 }), Self.y(s)>1e-6, Self.y(DevelopmentRGBMatrixV3.apply(baseline.values,s))>1e-6 else { throw EditingError.invalidRecipe }
    _ = try matrix()
  }
  private static func y(_ rgb: [Double]) -> Double { rgbToXYZ[3]*rgb[0]+rgbToXYZ[4]*rgb[1]+rgbToXYZ[5]*rgb[2] }
  public func matrix() throws -> DevelopmentRGBMatrixV3 {
    guard version == 1 else { throw EditingError.invalidRecipe }; try baseline.validate(); try DevelopmentV3Validation.range([warmth],-0.5...0.5)
    try sampledLinearRGB.validate()
    let sample = [sampledLinearRGB.red,sampledLinearRGB.green,sampledLinearRGB.blue]
    guard sample.allSatisfy({ $0 >= 0 && $0 <= 64 }), Self.y(sample)>1e-6,
      Self.y(DevelopmentRGBMatrixV3.apply(baseline.values,sample))>1e-6 else { throw EditingError.invalidRecipe }
    if warmth == 0 { return baseline }
    let b = Self.bradford, c = Self.rgbToXYZ
    let diagonal = [pow(2,0.4*warmth),0,0,0,1,0,0,0,pow(2,-0.4*warmth)]
    let xyz = DevelopmentRGBMatrixV3.multiply(try DevelopmentRGBMatrixV3.inverse(b),DevelopmentRGBMatrixV3.multiply(diagonal,b))
    var m = DevelopmentRGBMatrixV3.multiply(try DevelopmentRGBMatrixV3.inverse(c),DevelopmentRGBMatrixV3.multiply(xyz,DevelopmentRGBMatrixV3.multiply(c,baseline.values)))
    let s = [sampledLinearRGB.red,sampledLinearRGB.green,sampledLinearRGB.blue], before = Self.y(s), after = Self.y(DevelopmentRGBMatrixV3.apply(m,s))
    guard before.isFinite, before>1e-6, after.isFinite, after>1e-6 else { throw EditingError.invalidRecipe }
    m = m.map { $0*before/after }; let result = DevelopmentRGBMatrixV3(m); try result.validate(); return result
  }
  /// Pure gray-neutral transform construction. Skin uses a separately analyzed baseline.
  public static func neutralGray(sampledLinearRGB sample: DevelopmentSampledColorV3) throws -> Self {
    try sample.validate(); let rgb = [sample.red,sample.green,sample.blue], luminance = y(rgb)
    guard rgb.allSatisfy({ $0 >= 0 && $0 <= 64 }), luminance.isFinite, luminance>1e-6 else { throw EditingError.invalidRecipe }
    let c = rgbToXYZ, b = bradford
    let sourceWhite = DevelopmentRGBMatrixV3.apply(c,rgb).map { $0/luminance }
    let sourceCone = DevelopmentRGBMatrixV3.apply(b,sourceWhite), targetCone = DevelopmentRGBMatrixV3.apply(b,[0.95047,1,1.08883])
    guard sourceCone.allSatisfy({ $0.isFinite && $0 > 1e-8 }) else { throw EditingError.invalidRecipe }
    let ratios = zip(targetCone,sourceCone).map { $0.0/$0.1 }
    let diagonal = [ratios[0],0,0,0,ratios[1],0,0,0,ratios[2]]
    let xyz = DevelopmentRGBMatrixV3.multiply(try DevelopmentRGBMatrixV3.inverse(b),DevelopmentRGBMatrixV3.multiply(diagonal,b))
    var m = DevelopmentRGBMatrixV3.multiply(try DevelopmentRGBMatrixV3.inverse(c),DevelopmentRGBMatrixV3.multiply(xyz,c))
    let after = y(DevelopmentRGBMatrixV3.apply(m,rgb)); guard after.isFinite, after>1e-6 else { throw EditingError.invalidRecipe }
    m = m.map { $0*luminance/after }
    let result = Self(baseline:.init(m),sampledLinearRGB:sample); try result.validate(); return result
  }
  /// An explicit own skin-locus target, distinct from a neutral-gray target. The resolved RGB
  /// baseline is persisted; this target is not alleged to be Photos' proprietary face I/Q model.
  public static func skinTone(sampledLinearRGB sample: DevelopmentSampledColorV3) throws -> Self {
    try DevelopmentSkinToneLocusV3.validateSample(sample,alpha:1)
    let gray = try neutralGray(sampledLinearRGB:sample)
    let target = try neutralGray(sampledLinearRGB:DevelopmentSkinToneLocusV3.targetLinearRGB)
    var m = DevelopmentRGBMatrixV3.multiply(try DevelopmentRGBMatrixV3.inverse(target.baseline.values),gray.baseline.values)
    let rgb = [sample.red,sample.green,sample.blue], before = y(rgb), after = y(DevelopmentRGBMatrixV3.apply(m,rgb))
    guard after.isFinite, after > 1e-6 else { throw EditingError.invalidRecipe }
    m = m.map { $0*before/after }; let result = Self(baseline:.init(m),sampledLinearRGB:sample); try result.validate(); return result
  }
  private enum CodingKeys: String, CodingKey { case version, baseline, sampledLinearRGB, warmth }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["version","baseline","sampledLinearRGB","warmth"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    version = try c.decode(Int.self,forKey:.version); baseline = try c.decode(DevelopmentRGBMatrixV3.self,forKey:.baseline)
    sampledLinearRGB = try c.decode(DevelopmentSampledColorV3.self,forKey:.sampledLinearRGB); warmth = try c.decode(Double.self,forKey:.warmth); try validate()
  }
  public func encode(to encoder: Encoder) throws { try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(version,forKey:.version); try c.encode(baseline,forKey:.baseline); try c.encode(sampledLinearRGB,forKey:.sampledLinearRGB); try c.encode(warmth,forKey:.warmth) }
}

public struct DevelopmentRawWhiteBalanceStateV3: Codable, Equatable, Sendable {
  public var selectedMode: DevelopmentWhiteBalanceModeV3
  public var defaultTTDiagnostic, temperatureTint: DevelopmentNativeWhiteBalanceV3
  public var gray, skin: DevelopmentRawWhiteBalancePickV3?
  public init(selectedMode: DevelopmentWhiteBalanceModeV3 = .asShot, defaultTTDiagnostic: DevelopmentNativeWhiteBalanceV3,
              temperatureTint: DevelopmentNativeWhiteBalanceV3, gray: DevelopmentRawWhiteBalancePickV3? = nil, skin: DevelopmentRawWhiteBalancePickV3? = nil) {
    self.selectedMode = selectedMode; self.defaultTTDiagnostic = defaultTTDiagnostic; self.temperatureTint = temperatureTint; self.gray = gray; self.skin = skin
  }
  public func validate() throws {
    try defaultTTDiagnostic.validate(); try temperatureTint.validate(); try gray?.validate(); try skin?.validate()
    for pick in [gray,skin].compactMap({ $0 }) where pick.usesSourceDefaultAtZero {
      guard pick.baseline == defaultTTDiagnostic else { throw EditingError.invalidRecipe }
    }
    guard temperatureTint.temperature <= 50000, selectedMode != .neutralGray || gray != nil, selectedMode != .skinTone || skin != nil else { throw EditingError.invalidRecipe }
  }
  /// Nil means preserve a fresh decoder's original neutral; diagnostic TT MUST NOT be assigned.
  public func nativeTarget() throws -> DevelopmentNativeWhiteBalanceV3? {
    try validate(); switch selectedMode { case .asShot:return nil; case .temperatureTint:return temperatureTint
    case .neutralGray: return gray!.usesSourceDefaultAtZero && gray!.warmth == 0 ? nil:try gray!.target()
    case .skinTone: return skin!.usesSourceDefaultAtZero && skin!.warmth == 0 ? nil:try skin!.target() }
  }
  private enum CodingKeys: String, CodingKey { case selectedMode, defaultTTDiagnostic, temperatureTint, gray, skin }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["selectedMode","defaultTTDiagnostic","temperatureTint","gray","skin"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    selectedMode = try c.decode(DevelopmentWhiteBalanceModeV3.self,forKey:.selectedMode); defaultTTDiagnostic = try c.decode(DevelopmentNativeWhiteBalanceV3.self,forKey:.defaultTTDiagnostic)
    temperatureTint = try c.decode(DevelopmentNativeWhiteBalanceV3.self,forKey:.temperatureTint); gray = try c.decodeIfPresent(DevelopmentRawWhiteBalancePickV3.self,forKey:.gray); skin = try c.decodeIfPresent(DevelopmentRawWhiteBalancePickV3.self,forKey:.skin); try validate()
  }
  public func encode(to encoder: Encoder) throws { try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(selectedMode,forKey:.selectedMode); try c.encode(defaultTTDiagnostic,forKey:.defaultTTDiagnostic); try c.encode(temperatureTint,forKey:.temperatureTint); try c.encode(gray,forKey:.gray); try c.encode(skin,forKey:.skin) }
}
public struct DevelopmentImageWhiteBalanceStateV3: Codable, Equatable, Sendable {
  public var selectedMode: DevelopmentWhiteBalanceModeV3
  public var temperatureTint: DevelopmentNativeWhiteBalanceV3
  /// Rendered-image UI uses an approximate −100…100 scale, not a fabricated Kelvin metadata claim.
  /// The actual working neutral remains stored for deterministic replay of older and newer recipes.
  public var temperatureOffset: Double
  public var gray, skin: DevelopmentImageWhiteBalancePickV3?
  public init(selectedMode: DevelopmentWhiteBalanceModeV3 = .asShot, temperatureTint: DevelopmentNativeWhiteBalanceV3 = .init(temperature:6500,tint:0),
              temperatureOffset: Double = 0, gray: DevelopmentImageWhiteBalancePickV3? = nil, skin: DevelopmentImageWhiteBalancePickV3? = nil) {
    self.selectedMode = selectedMode; self.temperatureTint = temperatureTint; self.temperatureOffset = temperatureOffset; self.gray = gray; self.skin = skin
  }
  public static func approximateTemperature(forOffset offset: Double) -> Float {
    Float(5000 * pow(2, offset / 100))
  }
  public func validate() throws {
    try temperatureTint.validate(); try gray?.validate(); try skin?.validate()
    guard temperatureTint.temperature <= 20000, temperatureOffset.isFinite, (-100...100).contains(temperatureOffset),
      selectedMode != .neutralGray || gray != nil, selectedMode != .skinTone || skin != nil else { throw EditingError.invalidRecipe }
  }
  private enum CodingKeys: String, CodingKey { case selectedMode, temperatureTint, temperatureOffset, gray, skin }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["selectedMode","temperatureTint","gray","skin"]+(c.contains(.temperatureOffset) ? ["temperatureOffset"]:[]))
    selectedMode = try c.decode(DevelopmentWhiteBalanceModeV3.self,forKey:.selectedMode); temperatureTint = try c.decode(DevelopmentNativeWhiteBalanceV3.self,forKey:.temperatureTint)
    temperatureOffset = try c.decodeIfPresent(Double.self,forKey:.temperatureOffset) ?? 0
    gray = try c.decodeIfPresent(DevelopmentImageWhiteBalancePickV3.self,forKey:.gray); skin = try c.decodeIfPresent(DevelopmentImageWhiteBalancePickV3.self,forKey:.skin); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(selectedMode,forKey:.selectedMode); try c.encode(temperatureTint,forKey:.temperatureTint)
    if temperatureOffset != 0 { try c.encode(temperatureOffset,forKey:.temperatureOffset) }
    try c.encode(gray,forKey:.gray); try c.encode(skin,forKey:.skin)
  }
}
public enum DevelopmentResolvedWhiteBalanceV3: Codable, Equatable, Sendable {
  case raw(source: DevelopmentLocalEditSourceBinding, state: DevelopmentRawWhiteBalanceStateV3)
  case image(source: DevelopmentLocalEditSourceBinding, state: DevelopmentImageWhiteBalanceStateV3)
  public var source: DevelopmentLocalEditSourceBinding { switch self { case .raw(let s,_),.image(let s,_):return s } }
  public var sourceCapability: DevelopmentNoiseReductionSourceCapability { switch self { case .raw:return .raw; case .image:return .image } }
  public var displayAdjustment: DevelopmentWhiteBalanceAdjustmentV3 {
    let mode: DevelopmentWhiteBalanceModeV3, tt: DevelopmentNativeWhiteBalanceV3, warmth: Double
    switch self {
    case .raw(_,let s):mode = s.selectedMode; tt = s.temperatureTint; warmth = mode == .neutralGray ? s.gray?.warmth ?? 0:s.skin?.warmth ?? 0
    case .image(_,let s):mode = s.selectedMode; tt = s.temperatureTint; warmth = mode == .neutralGray ? s.gray?.warmth ?? 0:s.skin?.warmth ?? 0
    }
    switch mode { case .asShot:return .asShot; case .temperatureTint:return .temperatureTint(temperature:Double(tt.temperature),tint:Double(tt.tint))
    case .neutralGray:return .neutralGray(warmth:warmth); case .skinTone:return .skinTone(warmth:warmth) }
  }
  public func validate(expectedSource: DevelopmentLocalEditSourceBinding? = nil) throws {
    try source.validate(); if let expectedSource, expectedSource != source { throw EditingError.invalidRecipe }
    switch self { case .raw(_,let s):try s.validate(); case .image(_,let s):try s.validate() }
  }
  private enum CodingKeys: String, CodingKey { case version, kind, source, state }
  private enum Kind: String, Codable { case raw, image }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["version","kind","source","state"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    guard try c.decode(Int.self,forKey:.version) == 1 else { throw EditingError.invalidRecipe }
    let source = try c.decode(DevelopmentLocalEditSourceBinding.self,forKey:.source)
    switch try c.decode(Kind.self,forKey:.kind) { case .raw:self = .raw(source:source,state:try c.decode(DevelopmentRawWhiteBalanceStateV3.self,forKey:.state))
    case .image:self = .image(source:source,state:try c.decode(DevelopmentImageWhiteBalanceStateV3.self,forKey:.state)) }; try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(1,forKey:.version); try c.encode(source,forKey:.source)
    switch self { case .raw(_,let s):try c.encode(Kind.raw,forKey:.kind); try c.encode(s,forKey:.state)
    case .image(_,let s):try c.encode(Kind.image,forKey:.kind); try c.encode(s,forKey:.state) }
  }
}
