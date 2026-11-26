import Foundation

/// V3 uses its own units and operator identities; these values do not relabel legacy V2 math.
public enum DevelopmentAdjustmentID: String, Codable, CaseIterable, Sendable {
  case light, color, blackAndWhite, retouch, redEye, whiteBalance, curves, levels
  case definition, selectiveColor, noiseReduction, sharpen, vignette, filter, optics
  case texture, clarity, dehaze
}

// Shared only by the new strict V3 model family. Legacy Codable bytes remain unchanged.
enum DevelopmentV3Validation {
  static func range(_ values: [Double], _ range: ClosedRange<Double>) throws {
    guard values.allSatisfy({ $0.isFinite && range.contains($0) }) else { throw EditingError.invalidRecipe }
  }
  static func crop(_ crop: NormalizedCrop) throws {
    guard [crop.x,crop.y,crop.width,crop.height].allSatisfy(\.isFinite), crop.x >= 0, crop.y >= 0,
      crop.width > 0, crop.height > 0, crop.x + crop.width <= 1.00000001,
      crop.y + crop.height <= 1.00000001 else { throw EditingError.invalidRecipe }
  }
  static func legacyWhiteBalance(_ value: DevelopmentWhiteBalance) throws {
    if case let .temperatureTint(temperature,tint) = value {
      try range([temperature],2000...50000); try range([tint],-150...150)
    }
  }
  static func decodeLegacyWhiteBalance(_ decoder: Decoder) throws -> DevelopmentWhiteBalance {
    let value = try DevelopmentWhiteBalance(from: decoder)
    let object = try decoder.container(keyedBy: RecipeCodingKey.self)
    switch value {
    case .asShot:
      try RecipeCoding.requireKeys(decoder,["asShot"])
      try RecipeCoding.requireKeys(try object.superDecoder(forKey:.init("asShot")),[])
    case .temperatureTint:
      try RecipeCoding.requireKeys(decoder,["temperatureTint"])
      try RecipeCoding.requireKeys(try object.superDecoder(forKey:.init("temperatureTint")),["temperature","tint"])
    }
    try legacyWhiteBalance(value); return value
  }
}

public enum DevelopmentLegacyBasisVersion: String, Codable, Sendable { case v1, v2 }
/// Closed legacy-only data, deliberately incapable of containing another DevelopmentRecipe/V3 payload.
public struct DevelopmentLegacyBasis: Codable, Equatable, Sendable {
  public var version: DevelopmentLegacyBasisVersion
  public var exposureEV: Double
  public var whiteBalance: DevelopmentWhiteBalance
  public var color: DevelopmentColorAdjustments?
  public init(version: DevelopmentLegacyBasisVersion, exposureEV: Double = 0,
              whiteBalance: DevelopmentWhiteBalance = .asShot, color: DevelopmentColorAdjustments? = nil) {
    self.version = version; self.exposureEV = exposureEV; self.whiteBalance = whiteBalance; self.color = color
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([exposureEV],-10...10)
    try DevelopmentV3Validation.legacyWhiteBalance(whiteBalance)
    guard (version == .v1 && color == nil) || (version == .v2 && color != nil) else { throw EditingError.invalidRecipe }
    try color?.validate()
  }
  public var isPixelNeutral: Bool { exposureEV == 0 && whiteBalance == .asShot && (color?.isNeutral ?? true) }
  private enum CodingKeys: String, CodingKey { case version, exposureEV, whiteBalance, color }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    version = try c.decode(DevelopmentLegacyBasisVersion.self,forKey:.version)
    try RecipeCoding.requireKeys(decoder,version == .v1 ? ["version","exposureEV","whiteBalance"] : ["version","exposureEV","whiteBalance","color"])
    exposureEV = try c.decode(Double.self,forKey:.exposureEV)
    whiteBalance = try DevelopmentV3Validation.decodeLegacyWhiteBalance(c.superDecoder(forKey:.whiteBalance))
    color = version == .v1 ? nil : try c.decode(DevelopmentColorAdjustments.self,forKey:.color)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(version,forKey:.version); try c.encode(exposureEV,forKey:.exposureEV); try c.encode(whiteBalance,forKey:.whiteBalance)
    if version == .v2 { try c.encode(color!,forKey:.color) }
  }
}

public enum DevelopmentBrillianceVersion: String, Codable, Hashable, Sendable {
  case publicTiledJointFixed050V1
  /// Source-native adaptive local light. Old unversioned recipes keep their original operator.
  case adaptiveLocalV1
}

public enum DevelopmentLightAutoFieldV3: String, Codable, CaseIterable, Sendable {
  case brilliance, exposure, highlights, shadows, whites, blackPoint, brightness, contrast
}

public enum DevelopmentClippingPreviewV3: String, Codable, Sendable { case shadows, highlights, both }

public struct DevelopmentLightV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var brilliance: Double
  public var brillianceVersion: DevelopmentBrillianceVersion?
  public var exposure: Double
  public var highlights: Double
  public var shadows: Double
  public var brightness: Double
  public var contrast: Double
  public var blackPoint: Double
  public var whites: Double
  /// Ephemeral preview-only mode; the Controller never commits it to the draft.
  public var clippingPreview: DevelopmentClippingPreviewV3?
  public init(enabled: Bool = false, brilliance: Double = 0, brillianceVersion: DevelopmentBrillianceVersion? = nil, exposure: Double = 0, highlights: Double = 0, shadows: Double = 0, brightness: Double = 0, contrast: Double = 0, blackPoint: Double = 0, whites: Double = 0, clippingPreview: DevelopmentClippingPreviewV3? = nil) {
    self.enabled = enabled; self.brilliance = brilliance; self.brillianceVersion = brillianceVersion; self.exposure = exposure; self.highlights = highlights; self.shadows = shadows; self.brightness = brightness; self.contrast = contrast; self.blackPoint = blackPoint; self.whites = whites;self.clippingPreview = clippingPreview
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([brilliance],-2...2)
    if enabled, brillianceVersion == .publicTiledJointFixed050V1, brilliance != 0 {
      guard brilliance == 0.5, exposure == 0, highlights == 0, shadows == 0,
        brightness == 0, contrast == 0, blackPoint == 0, whites == 0 else { throw EditingError.invalidRecipe }
    }
    try DevelopmentV3Validation.range([exposure],-2...2)
    try DevelopmentV3Validation.range([highlights],-1...1)
    try DevelopmentV3Validation.range([shadows],-1...1)
    try DevelopmentV3Validation.range([brightness],-2...2)
    try DevelopmentV3Validation.range([contrast],-1...2)
    try DevelopmentV3Validation.range([blackPoint],-2...2)
    try DevelopmentV3Validation.range([whites],-1...1)
  }
  private enum CodingKeys: String, CodingKey { case enabled, brilliance, brillianceVersion, exposure, highlights, shadows, brightness, contrast, blackPoint, whites, clippingPreview }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","brilliance","exposure","highlights","shadows","brightness","contrast","blackPoint"] +
      (c.contains(.brillianceVersion) ? ["brillianceVersion"]:[]) + (c.contains(.whites) ? ["whites"]:[]) + (c.contains(.clippingPreview) ? ["clippingPreview"]:[]))
    enabled = try c.decode(Bool.self,forKey:.enabled)
    brilliance = try c.decode(Double.self,forKey:.brilliance)
    brillianceVersion = c.contains(.brillianceVersion) ? try c.decode(DevelopmentBrillianceVersion.self,forKey:.brillianceVersion):nil
    exposure = try c.decode(Double.self,forKey:.exposure)
    highlights = try c.decode(Double.self,forKey:.highlights)
    shadows = try c.decode(Double.self,forKey:.shadows)
    brightness = try c.decode(Double.self,forKey:.brightness)
    contrast = try c.decode(Double.self,forKey:.contrast)
    blackPoint = try c.decode(Double.self,forKey:.blackPoint)
    whites = c.contains(.whites) ? try c.decode(Double.self,forKey:.whites):0
    clippingPreview = c.contains(.clippingPreview) ? try c.decode(DevelopmentClippingPreviewV3.self,forKey:.clippingPreview):nil
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(enabled,forKey:.enabled)
    try c.encode(brilliance,forKey:.brilliance)
    if let brillianceVersion { try c.encode(brillianceVersion,forKey:.brillianceVersion) }
    try c.encode(exposure,forKey:.exposure)
    try c.encode(highlights,forKey:.highlights)
    try c.encode(shadows,forKey:.shadows)
    try c.encode(brightness,forKey:.brightness)
    try c.encode(contrast,forKey:.contrast)
    try c.encode(blackPoint,forKey:.blackPoint)
    if whites != 0 { try c.encode(whites,forKey:.whites) }
    try c.encodeIfPresent(clippingPreview,forKey:.clippingPreview)
  }
}

public struct DevelopmentColorV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var saturation: Double
  public var vibrance: Double
  public var cast: Double
  public init(enabled: Bool = false, saturation: Double = 0, vibrance: Double = 0, cast: Double = 0) {
    self.enabled = enabled; self.saturation = saturation; self.vibrance = vibrance; self.cast = cast
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([saturation],-1...2)
    try DevelopmentV3Validation.range([vibrance],-1...2)
    try DevelopmentV3Validation.range([cast],-1...1)
  }
  private enum CodingKeys: String, CodingKey { case enabled, saturation, vibrance, cast }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["enabled","saturation","vibrance","cast"])
    let c = try decoder.container(keyedBy:CodingKeys.self)
    enabled = try c.decode(Bool.self,forKey:.enabled)
    saturation = try c.decode(Double.self,forKey:.saturation)
    vibrance = try c.decode(Double.self,forKey:.vibrance)
    cast = try c.decode(Double.self,forKey:.cast)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(enabled,forKey:.enabled)
    try c.encode(saturation,forKey:.saturation)
    try c.encode(vibrance,forKey:.vibrance)
    try c.encode(cast,forKey:.cast)
  }
}

/// Versioned grain semantics. Legacy is represented by an absent optional field, never a new default.
public enum DevelopmentGrainSamplingVersion: String, Codable, Hashable, Sendable {
  case sourceNativeLatticeV1 = "source-native-lattice-v1"
}

public struct DevelopmentBlackAndWhiteMixerV3: Codable, Equatable, Sendable {
  /// Red, orange, yellow, green, cyan, blue, purple, magenta; recipe domain -1...1.
  public var values: [Double]
  public init(values: [Double] = Array(repeating:0,count:8)) { self.values = values }
  public var isActive: Bool { values.contains { $0 != 0 } }
  public func validate() throws {
    guard values.count == DevelopmentSelectiveColorSlotV3.allCases.count else { throw EditingError.invalidRecipe }
    try DevelopmentV3Validation.range(values,-1...1)
  }
}

public struct DevelopmentBlackAndWhiteV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var intensity: Double
  public var neutrals: Double
  public var tone: Double
  public var grain: Double
  /// Missing/omitted is the original v3.2 interpretation; no automatic migration on decode.
  public var grainSamplingVersion: DevelopmentGrainSamplingVersion?
  /// Optional storage preserves every pre-B&W-Mixer recipe and its frozen fingerprint.
  public var mixer: DevelopmentBlackAndWhiteMixerV3?
  public var requiresLegacyGrainCanonicalInput: Bool { grain != 0 && grainSamplingVersion == nil }
  public init(enabled: Bool = false, intensity: Double = 0.5, neutrals: Double = 0, tone: Double = 0, grain: Double = 0,
              grainSamplingVersion: DevelopmentGrainSamplingVersion? = nil, mixer: DevelopmentBlackAndWhiteMixerV3? = nil) {
    self.enabled = enabled; self.intensity = intensity; self.neutrals = neutrals; self.tone = tone; self.grain = grain
    self.grainSamplingVersion = grainSamplingVersion; self.mixer = mixer
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([intensity],0...1)
    try DevelopmentV3Validation.range([neutrals],-1...1)
    try DevelopmentV3Validation.range([tone],-1...1)
    try DevelopmentV3Validation.range([grain],0...1)
    try mixer?.validate()
    guard grainSamplingVersion == nil || grain != 0 else { throw EditingError.invalidRecipe }
  }
  private enum CodingKeys: String, CodingKey { case enabled, intensity, neutrals, tone, grain, grainSamplingVersion, mixer }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","intensity","neutrals","tone","grain"] + (c.contains(.grainSamplingVersion) ? ["grainSamplingVersion"]:[]) + (c.contains(.mixer) ? ["mixer"]:[]))
    enabled = try c.decode(Bool.self,forKey:.enabled)
    intensity = try c.decode(Double.self,forKey:.intensity)
    neutrals = try c.decode(Double.self,forKey:.neutrals)
    tone = try c.decode(Double.self,forKey:.tone)
    grain = try c.decode(Double.self,forKey:.grain)
    grainSamplingVersion = c.contains(.grainSamplingVersion) ? try c.decode(DevelopmentGrainSamplingVersion.self,forKey:.grainSamplingVersion):nil
    mixer = try c.decodeIfPresent(DevelopmentBlackAndWhiteMixerV3.self,forKey:.mixer)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(enabled,forKey:.enabled)
    try c.encode(intensity,forKey:.intensity)
    try c.encode(neutrals,forKey:.neutrals)
    try c.encode(tone,forKey:.tone)
    try c.encode(grain,forKey:.grain)
    try c.encodeIfPresent(grainSamplingVersion,forKey:.grainSamplingVersion)
    try c.encodeIfPresent(mixer,forKey:.mixer)
  }
}

public struct DevelopmentDefinitionV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var amount: Double
  public init(enabled: Bool = false, amount: Double = 0) {
    self.enabled = enabled; self.amount = amount
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([amount],0...2)
  }
  private enum CodingKeys: String, CodingKey { case enabled, amount }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["enabled","amount"])
    let c = try decoder.container(keyedBy:CodingKeys.self)
    enabled = try c.decode(Bool.self,forKey:.enabled)
    amount = try c.decode(Double.self,forKey:.amount)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(enabled,forKey:.enabled)
    try c.encode(amount,forKey:.amount)
  }
}

/// Declared recipe domain. The renderer supplies the actual decoded-source capability separately.
public enum DevelopmentNoiseReductionSourceCapability: String, Codable, Sendable { case raw, image }
public struct DevelopmentNoiseReductionV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var sourceCapability: DevelopmentNoiseReductionSourceCapability
  public var luminanceNoise, colorNoise, detail: Double
  /// Ordinary rendered-image Amount, measured 0...5. It is not RAW luminance noise.
  public var nonRawAmount: Double
  /// Optional image-domain detail controls, independent of the native decoder's shared Detail key.
  public var luminanceContrast, colorDetail: Double?
  public var nativeMappingVersion: Int
  public init(enabled: Bool = false, sourceCapability: DevelopmentNoiseReductionSourceCapability = .raw,
              luminanceNoise: Double = 0, colorNoise: Double = 0, detail: Double = 0, nonRawAmount: Double = 0,
              luminanceContrast: Double? = nil, colorDetail: Double? = nil, nativeMappingVersion: Int = 1) {
    self.enabled = enabled; self.sourceCapability = sourceCapability; self.luminanceNoise = luminanceNoise
    self.colorNoise = colorNoise; self.detail = detail; self.nonRawAmount = nonRawAmount
    self.luminanceContrast = luminanceContrast; self.colorDetail = colorDetail; self.nativeMappingVersion = nativeMappingVersion
  }
  public func validate() throws {
    // Remembered inactive-domain parameters are validated too; no silent clamping or reinterpretation.
    guard nativeMappingVersion == 1 else { throw EditingError.invalidRecipe }
    try DevelopmentV3Validation.range([luminanceNoise],-0.1...1)
    try DevelopmentV3Validation.range([colorNoise],-1...1)
    try DevelopmentV3Validation.range([detail],0...3)
    try DevelopmentV3Validation.range([nonRawAmount],0...5)
    if let luminanceContrast { try DevelopmentV3Validation.range([luminanceContrast],0...1) }
    if let colorDetail { try DevelopmentV3Validation.range([colorDetail],0...1) }
  }
  /// Must be called with actual decoder/source facts before applying an enabled NR operator.
  /// A disabled group can retain another domain's values, but they must still pass full validation.
  public func validate(for actualSourceCapability: DevelopmentNoiseReductionSourceCapability) throws {
    try validate()
    guard !enabled || sourceCapability == actualSourceCapability else { throw EditingError.invalidRecipe }
  }
  private enum CodingKeys: String, CodingKey { case enabled, sourceCapability, luminanceNoise, colorNoise, detail, nonRawAmount, luminanceContrast, colorDetail, nativeMappingVersion }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","sourceCapability","luminanceNoise","colorNoise","detail","nonRawAmount"]+(c.contains(.luminanceContrast) ? ["luminanceContrast"]:[])+(c.contains(.colorDetail) ? ["colorDetail"]:[])+(c.contains(.nativeMappingVersion) ? ["nativeMappingVersion"]:[]))
    nativeMappingVersion = c.contains(.nativeMappingVersion) ? try c.decode(Int.self,forKey:.nativeMappingVersion):1
    enabled = try c.decode(Bool.self,forKey:.enabled); sourceCapability = try c.decode(DevelopmentNoiseReductionSourceCapability.self,forKey:.sourceCapability)
    luminanceNoise = try c.decode(Double.self,forKey:.luminanceNoise); colorNoise = try c.decode(Double.self,forKey:.colorNoise)
    detail = try c.decode(Double.self,forKey:.detail); nonRawAmount = try c.decode(Double.self,forKey:.nonRawAmount)
    luminanceContrast = try c.decodeIfPresent(Double.self,forKey:.luminanceContrast); colorDetail = try c.decodeIfPresent(Double.self,forKey:.colorDetail); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(enabled,forKey:.enabled); try c.encode(sourceCapability,forKey:.sourceCapability)
    try c.encode(luminanceNoise,forKey:.luminanceNoise); try c.encode(colorNoise,forKey:.colorNoise)
    try c.encode(detail,forKey:.detail); try c.encode(nonRawAmount,forKey:.nonRawAmount)
    try c.encodeIfPresent(luminanceContrast,forKey:.luminanceContrast); try c.encodeIfPresent(colorDetail,forKey:.colorDetail)
    if sourceCapability == .raw && enabled && (luminanceNoise != 0 || colorNoise != 0 || detail != 0) { try c.encode(nativeMappingVersion,forKey:.nativeMappingVersion) }
  }
}

public struct DevelopmentSharpenV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var intensity: Double
  public var edges: Double
  public var falloff: Double
  /// Explicit Camera Raw-style controls. Nil preserves the original Photos-oriented recipe and math.
  public var radius: Double?
  public var detail: Double?
  public var masking: Double?
  /// Ephemeral preview intent; nil is absent from every legacy recipe.
  public var visualiseMasking: Bool?
  public init(enabled: Bool = false, intensity: Double = 0, edges: Double = 0.22, falloff: Double = 0.69,
              radius: Double? = nil, detail: Double? = nil, masking: Double? = nil, visualiseMasking: Bool? = nil) {
    self.enabled = enabled; self.intensity = intensity; self.edges = edges; self.falloff = falloff
    self.radius = radius; self.detail = detail; self.masking = masking; self.visualiseMasking = visualiseMasking
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([intensity],0...1)
    try DevelopmentV3Validation.range([edges],0...1)
    try DevelopmentV3Validation.range([falloff],0...1)
    if let radius { try DevelopmentV3Validation.range([radius],0.5...3) }
    if let detail { try DevelopmentV3Validation.range([detail],0...1) }
    if let masking { try DevelopmentV3Validation.range([masking],0...1) }
  }
  private enum CodingKeys: String, CodingKey { case enabled, intensity, edges, falloff, radius, detail, masking, visualiseMasking }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","intensity","edges","falloff"] + (c.contains(.radius) ? ["radius"]:[]) + (c.contains(.detail) ? ["detail"]:[]) + (c.contains(.masking) ? ["masking"]:[]) + (c.contains(.visualiseMasking) ? ["visualiseMasking"]:[]))
    enabled = try c.decode(Bool.self,forKey:.enabled)
    intensity = try c.decode(Double.self,forKey:.intensity)
    edges = try c.decode(Double.self,forKey:.edges)
    falloff = try c.decode(Double.self,forKey:.falloff)
    radius = try c.decodeIfPresent(Double.self,forKey:.radius)
    detail = try c.decodeIfPresent(Double.self,forKey:.detail)
    masking = try c.decodeIfPresent(Double.self,forKey:.masking)
    visualiseMasking = try c.decodeIfPresent(Bool.self,forKey:.visualiseMasking)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(enabled,forKey:.enabled)
    try c.encode(intensity,forKey:.intensity)
    try c.encode(edges,forKey:.edges)
    try c.encode(falloff,forKey:.falloff)
    try c.encodeIfPresent(radius,forKey:.radius)
    try c.encodeIfPresent(detail,forKey:.detail)
    try c.encodeIfPresent(masking,forKey:.masking)
    try c.encodeIfPresent(visualiseMasking,forKey:.visualiseMasking)
  }
}

public struct DevelopmentVignetteV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var strength: Double
  public var radius: Double
  public var softness: Double
  public init(enabled: Bool = false, strength: Double = 0, radius: Double = 0.5, softness: Double = 0) {
    self.enabled = enabled; self.strength = strength; self.radius = radius; self.softness = softness
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([strength],-1...1)
    try DevelopmentV3Validation.range([radius],0...1)
    try DevelopmentV3Validation.range([softness],0...1)
  }
  private enum CodingKeys: String, CodingKey { case enabled, strength, radius, softness }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["enabled","strength","radius","softness"])
    let c = try decoder.container(keyedBy:CodingKeys.self)
    enabled = try c.decode(Bool.self,forKey:.enabled)
    strength = try c.decode(Double.self,forKey:.strength)
    radius = try c.decode(Double.self,forKey:.radius)
    softness = try c.decode(Double.self,forKey:.softness)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(enabled,forKey:.enabled)
    try c.encode(strength,forKey:.strength)
    try c.encode(radius,forKey:.radius)
    try c.encode(softness,forKey:.softness)
  }
}

/// As-shot has no fabricated numeric temperature/tint. Display-mode projection belongs to bound analysis/UI.
public enum DevelopmentWhiteBalanceAdjustmentV3: Codable, Equatable, Sendable {
  case asShot
  case neutralGray(warmth: Double)
  case skinTone(warmth: Double)
  case temperatureTint(temperature: Double, tint: Double)
  public func validate() throws {
    switch self {
    case .asShot: break
    case .neutralGray(let warmth), .skinTone(let warmth): try DevelopmentV3Validation.range([warmth],-0.5...0.5)
    case let .temperatureTint(temperature,tint):
      try DevelopmentV3Validation.range([temperature],2000...50000); try DevelopmentV3Validation.range([tint],-150...150)
    }
  }
  private enum CodingKeys: String, CodingKey { case mode, warmth, temperature, tint }
  private enum Mode: String, Codable { case asShot, neutralGray, skinTone, temperatureTint }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self), mode = try c.decode(Mode.self,forKey:.mode)
    switch mode {
    case .asShot: try RecipeCoding.requireKeys(decoder,["mode"]); self = .asShot
    case .neutralGray, .skinTone:
      try RecipeCoding.requireKeys(decoder,["mode","warmth"])
      let value = try c.decode(Double.self,forKey:.warmth)
      self = mode == .neutralGray ? .neutralGray(warmth:value) : .skinTone(warmth:value)
    case .temperatureTint:
      try RecipeCoding.requireKeys(decoder,["mode","temperature","tint"])
      self = .temperatureTint(temperature:try c.decode(Double.self,forKey:.temperature),tint:try c.decode(Double.self,forKey:.tint))
    }
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    switch self {
    case .asShot: try c.encode(Mode.asShot,forKey:.mode)
    case .neutralGray(let warmth): try c.encode(Mode.neutralGray,forKey:.mode); try c.encode(warmth,forKey:.warmth)
    case .skinTone(let warmth): try c.encode(Mode.skinTone,forKey:.mode); try c.encode(warmth,forKey:.warmth)
    case let .temperatureTint(temperature,tint):
      try c.encode(Mode.temperatureTint,forKey:.mode); try c.encode(temperature,forKey:.temperature); try c.encode(tint,forKey:.tint)
    }
  }
}
public struct DevelopmentWhiteBalanceV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var adjustment: DevelopmentWhiteBalanceAdjustmentV3
  public var resolvedState: DevelopmentResolvedWhiteBalanceV3?
  public init(enabled: Bool = false, adjustment: DevelopmentWhiteBalanceAdjustmentV3 = .asShot) { self.enabled = enabled; self.adjustment = adjustment; resolvedState = nil }
  public init(enabled: Bool, resolvedState: DevelopmentResolvedWhiteBalanceV3) { self.enabled = enabled; self.resolvedState = resolvedState; adjustment = resolvedState.displayAdjustment }
  public func validate() throws {
    try adjustment.validate(); try resolvedState?.validate()
    if let resolvedState, adjustment != resolvedState.displayAdjustment { throw EditingError.invalidRecipe }
  }
  private enum CodingKeys: String, CodingKey { case enabled, adjustment, resolvedState }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","adjustment"]+(c.contains(.resolvedState) ? ["resolvedState"]:[]))
    resolvedState = try c.decodeIfPresent(DevelopmentResolvedWhiteBalanceV3.self,forKey:.resolvedState)
    enabled = try c.decode(Bool.self,forKey:.enabled); adjustment = try c.decode(DevelopmentWhiteBalanceAdjustmentV3.self,forKey:.adjustment); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(enabled,forKey:.enabled); try c.encode(adjustment,forKey:.adjustment)
    if let resolvedState { try c.encode(resolvedState,forKey:.resolvedState) }
  }
}

/// Curve coordinates and input range are normalized model units, not an assertion about Photos interpolation.
public struct DevelopmentCurveChannelV3: Codable, Equatable, Sendable {
  public var curve: DevelopmentCurve
  public var inputBlack: Double
  public var inputWhite: Double
  public init(curve: DevelopmentCurve = .init(), inputBlack: Double = 0, inputWhite: Double = 1) { self.curve = curve; self.inputBlack = inputBlack; self.inputWhite = inputWhite }
  public func validate() throws {
    try curve.validate(); try DevelopmentV3Validation.range([inputBlack,inputWhite],0...1)
    guard inputBlack < inputWhite else { throw EditingError.invalidRecipe }
  }
  private enum CodingKeys: String, CodingKey { case curve, inputBlack, inputWhite }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["curve","inputBlack","inputWhite"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    curve = try c.decode(DevelopmentCurve.self,forKey:.curve); inputBlack = try c.decode(Double.self,forKey:.inputBlack); inputWhite = try c.decode(Double.self,forKey:.inputWhite); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(curve,forKey:.curve); try c.encode(inputBlack,forKey:.inputBlack); try c.encode(inputWhite,forKey:.inputWhite)
  }
}
public struct DevelopmentCurvesV3: Codable, Equatable, Sendable {
  public var algorithm: DevelopmentCurvesAlgorithmV3
  public var enabled: Bool
  public var rgb, red, green, blue: DevelopmentCurveChannelV3
  public var parametric: DevelopmentParametricCurveV3?
  /// Optional point-curve saturation refinement, stored in display units -100...100.
  public var refineSaturation: Double?
  public init(enabled: Bool = false, rgb: DevelopmentCurveChannelV3 = .init(), red: DevelopmentCurveChannelV3 = .init(), green: DevelopmentCurveChannelV3 = .init(), blue: DevelopmentCurveChannelV3 = .init(), algorithm: DevelopmentCurvesAlgorithmV3 = .legacyPCHIPV1, parametric: DevelopmentParametricCurveV3? = nil, refineSaturation: Double? = nil) {
    self.algorithm = algorithm; self.enabled = enabled; self.rgb = rgb; self.red = red; self.green = green; self.blue = blue
    self.parametric = parametric; self.refineSaturation = refineSaturation
  }
  public func validate() throws {
    try rgb.validate(); try red.validate(); try green.validate(); try blue.validate(); try parametric?.validate()
    if let refineSaturation { try DevelopmentV3Validation.range([refineSaturation],-100...100) }
  }
  private enum CodingKeys: String, CodingKey { case enabled, rgb, red, green, blue, algorithm, parametric, refineSaturation }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","rgb","red","green","blue"]+(c.contains(.algorithm) ? ["algorithm"]:[])+(c.contains(.parametric) ? ["parametric"]:[])+(c.contains(.refineSaturation) ? ["refineSaturation"]:[]))
    algorithm = c.contains(.algorithm) ? try c.decode(DevelopmentCurvesAlgorithmV3.self,forKey:.algorithm):.legacyPCHIPV1
    enabled = try c.decode(Bool.self,forKey:.enabled); rgb = try c.decode(DevelopmentCurveChannelV3.self,forKey:.rgb); red = try c.decode(DevelopmentCurveChannelV3.self,forKey:.red)
    green = try c.decode(DevelopmentCurveChannelV3.self,forKey:.green); blue = try c.decode(DevelopmentCurveChannelV3.self,forKey:.blue)
    parametric = try c.decodeIfPresent(DevelopmentParametricCurveV3.self,forKey:.parametric)
    refineSaturation = try c.decodeIfPresent(Double.self,forKey:.refineSaturation); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    if algorithm != .legacyPCHIPV1 { try c.encode(algorithm,forKey:.algorithm) }
    try c.encode(enabled,forKey:.enabled); try c.encode(rgb,forKey:.rgb); try c.encode(red,forKey:.red); try c.encode(green,forKey:.green); try c.encode(blue,forKey:.blue)
    if let parametric { try c.encode(parametric,forKey:.parametric) }
    try c.encodeIfPresent(refineSaturation,forKey:.refineSaturation)
  }
}

/// Five ordered tonal handles plus two output-range handles. Coincident adjacent tonal handles are legal.
public struct DevelopmentLevelsHandlesV3: Codable, Equatable, Sendable {
  public var black, shadows, midtones, highlights, white, outputBlack, outputWhite: Double
  // Deliberately no guessed Photos defaults. Reset uses the explicit .identity case below.
  public init(black: Double, shadows: Double, midtones: Double, highlights: Double, white: Double, outputBlack: Double, outputWhite: Double) {
    self.black = black; self.shadows = shadows; self.midtones = midtones; self.highlights = highlights; self.white = white; self.outputBlack = outputBlack; self.outputWhite = outputWhite
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([black,shadows,midtones,highlights,white,outputBlack,outputWhite],0...1)
    guard black <= shadows, shadows <= midtones, midtones <= highlights, highlights <= white, black < white,
      outputBlack <= outputWhite else { throw EditingError.invalidRecipe }
  }
  private enum CodingKeys: String, CodingKey { case black, shadows, midtones, highlights, white, outputBlack, outputWhite }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["black","shadows","midtones","highlights","white","outputBlack","outputWhite"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    black = try c.decode(Double.self,forKey:.black); shadows = try c.decode(Double.self,forKey:.shadows); midtones = try c.decode(Double.self,forKey:.midtones)
    highlights = try c.decode(Double.self,forKey:.highlights); white = try c.decode(Double.self,forKey:.white); outputBlack = try c.decode(Double.self,forKey:.outputBlack); outputWhite = try c.decode(Double.self,forKey:.outputWhite); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(black,forKey:.black); try c.encode(shadows,forKey:.shadows); try c.encode(midtones,forKey:.midtones); try c.encode(highlights,forKey:.highlights); try c.encode(white,forKey:.white); try c.encode(outputBlack,forKey:.outputBlack); try c.encode(outputWhite,forKey:.outputWhite)
  }
}
public enum DevelopmentLevelsChannelV3: Codable, Equatable, Sendable {
  case identity
  case manual(DevelopmentLevelsHandlesV3)
  public func validate() throws { if case .manual(let handles) = self { try handles.validate() } }
  private enum CodingKeys: String, CodingKey { case kind, handles }
  private enum Kind: String, Codable { case identity, manual }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    switch try c.decode(Kind.self,forKey:.kind) {
    case .identity: try RecipeCoding.requireKeys(decoder,["kind"]); self = .identity
    case .manual: try RecipeCoding.requireKeys(decoder,["kind","handles"]); self = .manual(try c.decode(DevelopmentLevelsHandlesV3.self,forKey:.handles))
    }
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    switch self { case .identity: try c.encode(Kind.identity,forKey:.kind)
    case .manual(let handles): try c.encode(Kind.manual,forKey:.kind); try c.encode(handles,forKey:.handles) }
  }
}
public struct DevelopmentLevelsV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var luminance, rgb, red, green, blue: DevelopmentLevelsChannelV3
  public init(enabled: Bool = false, luminance: DevelopmentLevelsChannelV3 = .identity, rgb: DevelopmentLevelsChannelV3 = .identity, red: DevelopmentLevelsChannelV3 = .identity, green: DevelopmentLevelsChannelV3 = .identity, blue: DevelopmentLevelsChannelV3 = .identity) {
    self.enabled = enabled; self.luminance = luminance; self.rgb = rgb; self.red = red; self.green = green; self.blue = blue
  }
  public func validate() throws { try luminance.validate(); try rgb.validate(); try red.validate(); try green.validate(); try blue.validate() }
  private enum CodingKeys: String, CodingKey { case enabled, luminance, rgb, red, green, blue }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["enabled","luminance","rgb","red","green","blue"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    enabled = try c.decode(Bool.self,forKey:.enabled); luminance = try c.decode(DevelopmentLevelsChannelV3.self,forKey:.luminance); rgb = try c.decode(DevelopmentLevelsChannelV3.self,forKey:.rgb)
    red = try c.decode(DevelopmentLevelsChannelV3.self,forKey:.red); green = try c.decode(DevelopmentLevelsChannelV3.self,forKey:.green); blue = try c.decode(DevelopmentLevelsChannelV3.self,forKey:.blue); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(enabled,forKey:.enabled); try c.encode(luminance,forKey:.luminance); try c.encode(rgb,forKey:.rgb); try c.encode(red,forKey:.red); try c.encode(green,forKey:.green); try c.encode(blue,forKey:.blue)
  }
}
public enum DevelopmentSelectiveColorSlotV3: String, Codable, CaseIterable, Sendable { case red, orange, yellow, green, cyan, blue, purple, magenta }
/// Picker output in the canonical extended-linear-sRGB working space, never the display's RGB.
public struct DevelopmentSampledColorV3: Codable, Equatable, Sendable {
  public var red, green, blue: Double
  public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
  public func validate() throws {
    let bound = Double(Float.greatestFiniteMagnitude)
    try DevelopmentV3Validation.range([red,green,blue],(-bound)...bound)
  }
  private enum CodingKeys: String, CodingKey { case red, green, blue }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["red","green","blue"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    red = try c.decode(Double.self,forKey:.red); green = try c.decode(Double.self,forKey:.green); blue = try c.decode(Double.self,forKey:.blue); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(red,forKey:.red); try c.encode(green,forKey:.green); try c.encode(blue,forKey:.blue)
  }
}
public struct DevelopmentSelectiveColorAdjustmentV3: Codable, Equatable, Sendable {
  public var slot: DevelopmentSelectiveColorSlotV3
  public var sampledColor: DevelopmentSampledColorV3?
  public var hue, saturation, luminance, range: Double
  /// Optional -100...100 convergence/divergence from the sampled color; absent preserves legacy wire bytes.
  public var variance: Double?
  public init(slot: DevelopmentSelectiveColorSlotV3, sampledColor: DevelopmentSampledColorV3? = nil, hue: Double = 0,
              saturation: Double = 0, luminance: Double = 0, range: Double = 1, variance: Double? = nil) {
    self.slot = slot; self.sampledColor = sampledColor; self.hue = hue; self.saturation = saturation
    self.luminance = luminance; self.range = range; self.variance = variance
  }
  public func validate() throws {
    try sampledColor?.validate(); try DevelopmentV3Validation.range([hue],-60...60); try DevelopmentV3Validation.range([saturation],-100...100)
    try DevelopmentV3Validation.range([luminance],-70...70); try DevelopmentV3Validation.range([range],0...2)
    if let variance { try DevelopmentV3Validation.range([variance],-100...100) }
  }
  private enum CodingKeys: String, CodingKey { case slot, sampledColor, hue, saturation, luminance, range, variance }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["slot","sampledColor","hue","saturation","luminance","range"]+(c.contains(.variance) ? ["variance"]:[]))
    slot = try c.decode(DevelopmentSelectiveColorSlotV3.self,forKey:.slot); sampledColor = try c.decodeIfPresent(DevelopmentSampledColorV3.self,forKey:.sampledColor)
    hue = try c.decode(Double.self,forKey:.hue); saturation = try c.decode(Double.self,forKey:.saturation); luminance = try c.decode(Double.self,forKey:.luminance); range = try c.decode(Double.self,forKey:.range)
    variance = try c.decodeIfPresent(Double.self,forKey:.variance); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(slot,forKey:.slot); try c.encode(sampledColor,forKey:.sampledColor)
    try c.encode(hue,forKey:.hue); try c.encode(saturation,forKey:.saturation); try c.encode(luminance,forKey:.luminance); try c.encode(range,forKey:.range)
    try c.encodeIfPresent(variance,forKey:.variance)
  }
}
public struct DevelopmentPointColorSampleV3: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var sampledColor: DevelopmentSampledColorV3
  public var hue,saturation,luminance,range: Double
  public var variance: Double?
  public init(id:UUID=UUID(),sampledColor:DevelopmentSampledColorV3,hue:Double=0,saturation:Double=0,
              luminance:Double=0,range:Double=1,variance:Double?=nil) {
    self.id=id;self.sampledColor=sampledColor;self.hue=hue;self.saturation=saturation
    self.luminance=luminance;self.range=range;self.variance=variance
  }
  public var isActive:Bool{hue != 0 || saturation != 0 || luminance != 0 || (variance ?? 0) != 0}
  public func validate()throws{
    try sampledColor.validate();try DevelopmentV3Validation.range([hue],-60...60)
    try DevelopmentV3Validation.range([saturation],-100...100);try DevelopmentV3Validation.range([luminance],-70...70)
    try DevelopmentV3Validation.range([range],0...2)
    if let variance{try DevelopmentV3Validation.range([variance],-100...100)}
  }
}

public struct DevelopmentSelectiveColorV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var colors: [DevelopmentSelectiveColorAdjustmentV3]
  /// Transient preview-only slot. Controller never commits it to the user's draft.
  public var visualiseRange: DevelopmentSelectiveColorSlotV3?
  /// Independent hue-isolation preview; active hue stays colored and all others become achromatic.
  public var visualiseIsolation: DevelopmentSelectiveColorSlotV3?
  /// Independent UUID-based samples, distinct from the fixed HSL slots. Nil preserves old wire bytes.
  public var pointColors: [DevelopmentPointColorSampleV3]?
  public static let legacySlots: [DevelopmentSelectiveColorSlotV3] = [.red,.yellow,.green,.cyan,.blue,.magenta]
  public init(enabled: Bool = false, colors: [DevelopmentSelectiveColorAdjustmentV3] = DevelopmentSelectiveColorSlotV3.allCases.map { .init(slot:$0) },
              visualiseRange: DevelopmentSelectiveColorSlotV3? = nil, pointColors: [DevelopmentPointColorSampleV3]? = nil,
              visualiseIsolation: DevelopmentSelectiveColorSlotV3? = nil) {
    self.enabled = enabled; self.colors = colors; self.visualiseRange = visualiseRange; self.pointColors = pointColors;self.visualiseIsolation = visualiseIsolation
  }
  public func validate() throws {
    let slots = Set(colors.map(\.slot))
    let legacy = colors.count == 6 && slots == Set(Self.legacySlots)
    let current = colors.count == 8 && slots == Set(DevelopmentSelectiveColorSlotV3.allCases)
    guard (legacy || current), slots.count == colors.count else { throw EditingError.invalidRecipe }
    if let visualiseRange { guard slots.contains(visualiseRange) else { throw EditingError.invalidRecipe } }
    if let visualiseIsolation { guard slots.contains(visualiseIsolation) else { throw EditingError.invalidRecipe } }
    for color in colors { try color.validate() }
    if let pointColors {
      guard pointColors.count<=8,Set(pointColors.map(\.id)).count==pointColors.count else{throw EditingError.invalidRecipe}
      for sample in pointColors{try sample.validate()}
    }
  }
  private enum CodingKeys: String, CodingKey { case enabled, colors, visualiseRange, visualiseIsolation, pointColors }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","colors"]+(c.contains(.visualiseRange) ? ["visualiseRange"]:[])+(c.contains(.visualiseIsolation) ? ["visualiseIsolation"]:[])+(c.contains(.pointColors) ? ["pointColors"]:[]))
    enabled = try c.decode(Bool.self,forKey:.enabled); var a = try c.nestedUnkeyedContainer(forKey:.colors)
    if let count = a.count, count != 6 && count != 8 { throw EditingError.invalidRecipe }
    colors = []; colors.reserveCapacity(a.count ?? 8)
    while !a.isAtEnd { guard colors.count < 8 else { throw EditingError.invalidRecipe }; colors.append(try a.decode(DevelopmentSelectiveColorAdjustmentV3.self)) }
    visualiseRange = try c.decodeIfPresent(DevelopmentSelectiveColorSlotV3.self,forKey:.visualiseRange)
    visualiseIsolation = try c.decodeIfPresent(DevelopmentSelectiveColorSlotV3.self,forKey:.visualiseIsolation)
    pointColors = try c.decodeIfPresent([DevelopmentPointColorSampleV3].self,forKey:.pointColors)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(enabled,forKey:.enabled); try c.encode(colors,forKey:.colors)
    try c.encodeIfPresent(visualiseRange,forKey:.visualiseRange);try c.encodeIfPresent(visualiseIsolation,forKey:.visualiseIsolation);try c.encodeIfPresent(pointColors,forKey:.pointColors)
  }
}
public enum DevelopmentPhotoFilterV3: String, Codable, CaseIterable, Sendable {
  case original, vivid, vividWarm, vividCool, dramatic, dramaticWarm, dramaticCool, mono, silvertone, noir
  case spektraPortra400Endura, spektraVelvia100, spektraVision250D2383
  case spektraGold200UltraEndura, spektraPortra800SupraEndura, spektraEktar100Endura
  case spektraProvia100F, spektraEktachrome100, spektraVision500T2383

  public var spektrafilmTitle: String? {
    switch self {
    case .spektraPortra400Endura: return "Portra 400 / Portra Endura"
    case .spektraVelvia100: return "Velvia 100"
    case .spektraVision250D2383: return "Vision3 250D / 2383"
    case .spektraGold200UltraEndura: return "Gold 200 / Ultra Endura"
    case .spektraPortra800SupraEndura: return "Portra 800 / Supra Endura"
    case .spektraEktar100Endura: return "Ektar 100 / Portra Endura"
    case .spektraProvia100F: return "Provia 100F"
    case .spektraEktachrome100: return "Ektachrome 100"
    case .spektraVision500T2383: return "Vision3 500T / 2383"
    default: return nil
    }
  }
  public var isSpektrafilm: Bool { spektrafilmTitle != nil }
}
public struct DevelopmentFilterV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var selection: DevelopmentPhotoFilterV3
  /// Measured Photos control units (0...100); this does not identify a vendor LUT or algorithm.
  public var intensity: Double
  public init(enabled: Bool = false, selection: DevelopmentPhotoFilterV3 = .original, intensity: Double = 100) { self.enabled = enabled; self.selection = selection; self.intensity = intensity }
  public var normalizedIntensity: Double { intensity / 100 }
  public func validate() throws { try DevelopmentV3Validation.range([intensity],0...100) }
  private enum CodingKeys: String, CodingKey { case enabled, selection, intensity }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["enabled","selection","intensity"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    enabled = try c.decode(Bool.self,forKey:.enabled); selection = try c.decode(DevelopmentPhotoFilterV3.self,forKey:.selection); intensity = try c.decode(Double.self,forKey:.intensity); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(enabled,forKey:.enabled); try c.encode(selection,forKey:.selection); try c.encode(intensity,forKey:.intensity)
  }
}

public struct DevelopmentEffectsV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var grain: Double
  /// Nil preserves the original lattice operator. Non-nil opts into sized/roughness sampling.
  public var grainSize: Double?
  public var grainRoughness: Double?
  public var glow: DevelopmentGlowV3?
  public var postCropVignette: DevelopmentPostCropVignetteV3?
  public var lensBlur: DevelopmentLensBlurV3?
  public init(enabled: Bool = false, grain: Double = 0, grainSize: Double? = nil, grainRoughness: Double? = nil,
              glow: DevelopmentGlowV3? = nil, postCropVignette: DevelopmentPostCropVignetteV3? = nil,
              lensBlur: DevelopmentLensBlurV3? = nil) {
    self.enabled = enabled; self.grain = grain; self.grainSize = grainSize; self.grainRoughness = grainRoughness
    self.glow = glow; self.postCropVignette = postCropVignette; self.lensBlur = lensBlur
  }
  public var usesSizeRoughnessSampling: Bool { grainSize != nil || grainRoughness != nil }
  public func validate() throws {
    try DevelopmentV3Validation.range([grain],0...1)
    if let grainSize { try DevelopmentV3Validation.range([grainSize],0...1) }
    if let grainRoughness { try DevelopmentV3Validation.range([grainRoughness],0...1) }
    try glow?.validate(); try postCropVignette?.validate(); try lensBlur?.validate()
  }
  private enum CodingKeys: String, CodingKey { case enabled, grain, grainSize, grainRoughness, glow, postCropVignette, lensBlur }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["enabled","grain"]+(c.contains(.grainSize) ? ["grainSize"]:[])+(c.contains(.grainRoughness) ? ["grainRoughness"]:[])+(c.contains(.glow) ? ["glow"]:[])+(c.contains(.postCropVignette) ? ["postCropVignette"]:[])+(c.contains(.lensBlur) ? ["lensBlur"]:[]))
    enabled = try c.decode(Bool.self,forKey:.enabled); grain = try c.decode(Double.self,forKey:.grain)
    grainSize = try c.decodeIfPresent(Double.self,forKey:.grainSize); grainRoughness = try c.decodeIfPresent(Double.self,forKey:.grainRoughness)
    glow = try c.decodeIfPresent(DevelopmentGlowV3.self,forKey:.glow)
    postCropVignette = try c.decodeIfPresent(DevelopmentPostCropVignetteV3.self,forKey:.postCropVignette)
    lensBlur = try c.decodeIfPresent(DevelopmentLensBlurV3.self,forKey:.lensBlur)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(enabled,forKey:.enabled); try c.encode(grain,forKey:.grain)
    if let grainSize { try c.encode(grainSize,forKey:.grainSize) }
    if let grainRoughness { try c.encode(grainRoughness,forKey:.grainRoughness) }
    if let glow { try c.encode(glow,forKey:.glow) }
    if let postCropVignette { try c.encode(postCropVignette,forKey:.postCropVignette) }
    if let lensBlur { try c.encode(lensBlur,forKey:.lensBlur) }
  }
}

/// Requested high-quality, source-resolution demosaic. Raw values pin the replay algorithm and library version.
public enum DevelopmentSuperResolutionV1: String, Codable, Sendable {
  case photoUpconv7 = "waifu2x-upconv7-photo-2x-deb2c288-post-geometry-linear-v1"
}

public enum DevelopmentRawDetails: String, Codable, Sendable, CaseIterable {
  case bayerAHD = "flashraw-0.3.1-bayer-ahd-v1"
  case xTransEdgeAware = "flashraw-0.3.1-xtrans-edge-aware-v1"
  public var title: String { self == .bayerAHD ? "Bayer · AHD" : "X-Trans · 边缘感知" }
}

public enum DevelopmentRAWDecoder: String, Codable, Sendable {
  case flashRaw031 = "flashraw-0.3.1-linear-srgb-bilinear"
}

public struct DevelopmentAdjustmentsV3: Codable, Equatable, Sendable {
  /// Missing in recipes persisted with the Core Image decoder.
  public var rawDecoder: DevelopmentRAWDecoder?
  public var rawDetails: DevelopmentRawDetails?
  public var superResolution: DevelopmentSuperResolutionV1?
  public var aiDenoise: DevelopmentAIDenoiseV1?
  public var neutralForSameSource: Self {
    var neutral = Self()
    neutral.rawDecoder = rawDecoder
    return neutral
  }
  public var legacyBasis: DevelopmentLegacyBasis?
  public var light: DevelopmentLightV3
  public var color: DevelopmentColorV3
  public var blackAndWhite: DevelopmentBlackAndWhiteV3
  public var whiteBalance: DevelopmentWhiteBalanceV3
  public var curves: DevelopmentCurvesV3
  public var levels: DevelopmentLevelsV3
  public var definition: DevelopmentDefinitionV3
  public var selectiveColor: DevelopmentSelectiveColorV3
  public var noiseReduction: DevelopmentNoiseReductionV3
  public var sharpen: DevelopmentSharpenV3
  public var vignette: DevelopmentVignetteV3
  public var filter: DevelopmentFilterV3
  public var gradingLUTs: DevelopmentLUTStack?
  public var geometry: DevelopmentGeometryV3
  public var localEdits: DevelopmentLocalEditsV3
  public var advancedDetail: DevelopmentAdvancedDetailV3
  public var effects: DevelopmentEffectsV3?
  public var masks: [DevelopmentMaskLayerV3]
  public var optics: DevelopmentOpticsV3?
  public init(legacyBasis: DevelopmentLegacyBasis? = nil, light: DevelopmentLightV3 = .init(), color: DevelopmentColorV3 = .init(), blackAndWhite: DevelopmentBlackAndWhiteV3 = .init(), whiteBalance: DevelopmentWhiteBalanceV3 = .init(), curves: DevelopmentCurvesV3 = .init(), levels: DevelopmentLevelsV3 = .init(), definition: DevelopmentDefinitionV3 = .init(), selectiveColor: DevelopmentSelectiveColorV3 = .init(), noiseReduction: DevelopmentNoiseReductionV3 = .init(), sharpen: DevelopmentSharpenV3 = .init(), vignette: DevelopmentVignetteV3 = .init(), filter: DevelopmentFilterV3 = .init(), geometry: DevelopmentGeometryV3 = .init(), localEdits: DevelopmentLocalEditsV3 = .init(), advancedDetail: DevelopmentAdvancedDetailV3 = .init(), effects: DevelopmentEffectsV3? = nil, masks: [DevelopmentMaskLayerV3] = [], optics: DevelopmentOpticsV3? = nil, gradingLUTs: DevelopmentLUTStack? = nil) {
    self.gradingLUTs = gradingLUTs
    self.legacyBasis = legacyBasis; self.light = light; self.color = color; self.blackAndWhite = blackAndWhite; self.whiteBalance = whiteBalance; self.curves = curves; self.levels = levels; self.definition = definition; self.selectiveColor = selectiveColor; self.noiseReduction = noiseReduction; self.sharpen = sharpen; self.vignette = vignette; self.filter = filter; self.geometry = geometry; self.localEdits = localEdits
    self.advancedDetail = advancedDetail; self.effects = effects; self.masks = masks; self.optics = optics
  }
  public func validate() throws {
    try legacyBasis?.validate()
    try light.validate()
    try color.validate()
    try blackAndWhite.validate()
    try whiteBalance.validate()
    try curves.validate()
    try levels.validate()
    try definition.validate()
    try selectiveColor.validate()
    try noiseReduction.validate()
    try sharpen.validate()
    try vignette.validate()
    try filter.validate()
    try gradingLUTs?.validate()
    // These legacy grain recipes explicitly depend on the original Core Image decoder.
    try aiDenoise?.validate()
    guard aiDenoise == nil || (rawDetails == nil && !blackAndWhite.requiresLegacyGrainCanonicalInput) else { throw EditingError.invalidRecipe }
    guard rawDetails == nil || !blackAndWhite.requiresLegacyGrainCanonicalInput else { throw EditingError.invalidRecipe }
    try geometry.validate()
    try localEdits.validate()
    try advancedDetail.validate()
    try effects?.validate()
    try DevelopmentMaskLayerV3.validateLayers(masks)
    try optics?.validate()
  }
  private enum CodingKeys: String, CodingKey { case rawDecoder, rawDetails, aiDenoise, superResolution, legacyBasis, light, color, blackAndWhite, whiteBalance, curves, levels, definition, selectiveColor, noiseReduction, sharpen, vignette, filter, geometry, localEdits, advancedDetail, effects, masks, optics, gradingLUTs }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["legacyBasis","light","color","blackAndWhite","whiteBalance","curves","levels","definition","selectiveColor","noiseReduction","sharpen","vignette","filter","geometry","localEdits"]+(c.contains(.advancedDetail) ? ["advancedDetail"]:[])+(c.contains(.effects) ? ["effects"]:[])+(c.contains(.masks) ? ["masks"]:[])+(c.contains(.optics) ? ["optics"]:[])+(c.contains(.rawDecoder) ? ["rawDecoder"]:[])+(c.contains(.gradingLUTs) ? ["gradingLUTs"]:[])+(c.contains(.rawDetails) ? ["rawDetails"]:[])+(c.contains(.aiDenoise) ? ["aiDenoise"]:[])+(c.contains(.superResolution) ? ["superResolution"]:[]))
    superResolution = try c.decodeIfPresent(DevelopmentSuperResolutionV1.self, forKey: .superResolution)
    aiDenoise = try c.decodeIfPresent(DevelopmentAIDenoiseV1.self, forKey: .aiDenoise)
    rawDetails = try c.decodeIfPresent(DevelopmentRawDetails.self, forKey: .rawDetails)
    gradingLUTs = try c.decodeIfPresent(DevelopmentLUTStack.self, forKey: .gradingLUTs)
    rawDecoder = try c.decodeIfPresent(DevelopmentRAWDecoder.self,forKey:.rawDecoder)
    advancedDetail = c.contains(.advancedDetail) ? try c.decode(DevelopmentAdvancedDetailV3.self,forKey:.advancedDetail):.init()
    effects = c.contains(.effects) ? try c.decode(DevelopmentEffectsV3.self,forKey:.effects):nil
    masks = c.contains(.masks) ? try c.decode([DevelopmentMaskLayerV3].self,forKey:.masks):[]
    optics = try c.decodeIfPresent(DevelopmentOpticsV3.self,forKey:.optics)
    legacyBasis = try c.decodeIfPresent(DevelopmentLegacyBasis.self,forKey:.legacyBasis)
    light = try c.decode(DevelopmentLightV3.self,forKey:.light)
    color = try c.decode(DevelopmentColorV3.self,forKey:.color)
    blackAndWhite = try c.decode(DevelopmentBlackAndWhiteV3.self,forKey:.blackAndWhite)
    whiteBalance = try c.decode(DevelopmentWhiteBalanceV3.self,forKey:.whiteBalance)
    curves = try c.decode(DevelopmentCurvesV3.self,forKey:.curves)
    levels = try c.decode(DevelopmentLevelsV3.self,forKey:.levels)
    definition = try c.decode(DevelopmentDefinitionV3.self,forKey:.definition)
    selectiveColor = try c.decode(DevelopmentSelectiveColorV3.self,forKey:.selectiveColor)
    noiseReduction = try c.decode(DevelopmentNoiseReductionV3.self,forKey:.noiseReduction)
    sharpen = try c.decode(DevelopmentSharpenV3.self,forKey:.sharpen)
    vignette = try c.decode(DevelopmentVignetteV3.self,forKey:.vignette)
    filter = try c.decode(DevelopmentFilterV3.self,forKey:.filter)
    geometry = try c.decode(DevelopmentGeometryV3.self,forKey:.geometry)
    localEdits = try c.decode(DevelopmentLocalEditsV3.self,forKey:.localEdits)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encodeIfPresent(rawDecoder,forKey:.rawDecoder)
    try c.encodeIfPresent(rawDetails, forKey: .rawDetails)
    try c.encodeIfPresent(superResolution, forKey: .superResolution)
    try c.encodeIfPresent(aiDenoise, forKey: .aiDenoise)
    try c.encode(legacyBasis,forKey:.legacyBasis)
    try c.encode(light,forKey:.light)
    try c.encode(color,forKey:.color)
    try c.encode(blackAndWhite,forKey:.blackAndWhite)
    try c.encode(whiteBalance,forKey:.whiteBalance)
    try c.encode(curves,forKey:.curves)
    try c.encode(levels,forKey:.levels)
    try c.encode(definition,forKey:.definition)
    try c.encode(selectiveColor,forKey:.selectiveColor)
    try c.encode(noiseReduction,forKey:.noiseReduction)
    try c.encode(sharpen,forKey:.sharpen)
    try c.encode(vignette,forKey:.vignette)
    try c.encode(filter,forKey:.filter)
    try c.encodeIfPresent(gradingLUTs, forKey: .gradingLUTs)
    try c.encode(geometry,forKey:.geometry)
    try c.encode(localEdits,forKey:.localEdits)
    if advancedDetail != .init() { try c.encode(advancedDetail,forKey:.advancedDetail) }
    if effects != nil && effects != .init() { try c.encode(effects,forKey:.effects) }
    if !masks.isEmpty { try c.encode(masks,forKey:.masks) }
    try c.encodeIfPresent(optics,forKey:.optics)
  }
}
