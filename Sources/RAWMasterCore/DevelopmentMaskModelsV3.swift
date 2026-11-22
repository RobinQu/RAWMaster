import Foundation

public enum DevelopmentMaskKindV3: String, Codable, CaseIterable, Sendable {
  case linear, radial, range, subject
  public var title: String {
    switch self { case .linear: "线性渐变"; case .radial: "径向渐变"; case .range: "亮度范围"; case .subject: "AI 主体" }
  }
}

public struct DevelopmentMaskAdjustmentsV3: Codable, Equatable, Sendable {
  public var exposure, highlights, shadows, saturation: Double
  /// Per-layer amount. Style and all other glow settings remain globally shared.
  /// Optional storage preserves the exact JSON shape of recipes created before local Glow.
  public var glowAmount: Double?
  /// Independent local sample copy; using it never implicitly applies the same sample globally.
  public var pointColor: DevelopmentPointColorSampleV3?
  /// Optional local Light controls preserve the exact JSON shape of pre-v5 mask recipes.
  public var contrast, whites, blacks: Double?
  /// Normalized local Temp/Tint offsets around a 6500K image-working reference.
  public var temperature, tint: Double?
  /// Local Hue is in turns; Fine Adjustment applies a 0.1× range.
  public var hue: Double?
  public var fineAdjustment: Bool?
  /// Optional linear-sRGB colorize target and amount. Nil preserves old recipe bytes.
  public var colorize: DevelopmentSampledColorV3?
  public var colorizeAmount: Double?
  /// Local logarithmic Texture/Clarity amounts in the global operators' -1…1 domain.
  public var texture, clarity: Double?
  /// Local atmospheric correction in the global Dehaze signed -1…1 domain; no global preparation is reused.
  public var dehaze: Double?
  /// Source-native deterministic local grain. Size/roughness share the global generator semantics.
  public var grain, grainSize, grainRoughness: Double?
  /// Optional per-mask curve graph; it never aliases the global curve controls.
  public var curves: DevelopmentCurvesV3?
  /// Optional Shadows/Midtones/Highlights/Global wheel set with shared blending semantics.
  public var grading: DevelopmentColorGrading?
  public var gradingLUT: DevelopmentLUTLayer?
  /// Local Detail amounts. Sharpness is signed; NR and Moiré are nonnegative.
  public var sharpness, noiseReduction, moireReduction: Double?
  /// Positive values add local defringe; negative values protect the region from global Defringe.
  public var defringe: Double?
  public init(exposure: Double = 0, highlights: Double = 0, shadows: Double = 0, saturation: Double = 0,
              glowAmount: Double? = nil, pointColor: DevelopmentPointColorSampleV3? = nil,
              contrast: Double? = nil, whites: Double? = nil, blacks: Double? = nil,
              temperature: Double? = nil, tint: Double? = nil, hue: Double? = nil,
              fineAdjustment: Bool? = nil, colorize: DevelopmentSampledColorV3? = nil,
              colorizeAmount: Double? = nil, texture: Double? = nil, clarity: Double? = nil, dehaze: Double? = nil,
              grain: Double? = nil, grainSize: Double? = nil, grainRoughness: Double? = nil,
              curves: DevelopmentCurvesV3? = nil, grading: DevelopmentColorGrading? = nil,
              sharpness: Double? = nil, noiseReduction: Double? = nil, moireReduction: Double? = nil,
              defringe: Double? = nil, gradingLUT: DevelopmentLUTLayer? = nil) {
    self.gradingLUT = gradingLUT
    self.exposure=exposure;self.highlights=highlights;self.shadows=shadows;self.saturation=saturation
    self.glowAmount=glowAmount;self.pointColor=pointColor
    self.contrast=contrast;self.whites=whites;self.blacks=blacks
    self.temperature=temperature;self.tint=tint;self.hue=hue;self.fineAdjustment=fineAdjustment
    self.colorize=colorize;self.colorizeAmount=colorizeAmount;self.texture=texture;self.clarity=clarity;self.dehaze=dehaze
    self.grain=grain;self.grainSize=grainSize;self.grainRoughness=grainRoughness;self.curves=curves;self.grading=grading
    self.sharpness=sharpness;self.noiseReduction=noiseReduction;self.moireReduction=moireReduction;self.defringe=defringe
  }
  public var isNeutral: Bool { exposure==0 && highlights==0 && shadows==0 && saturation==0 && (glowAmount ?? 0)==0 && pointColor?.isActive != true && (contrast ?? 0)==0 && (whites ?? 0)==0 && (blacks ?? 0)==0 && (temperature ?? 0)==0 && (tint ?? 0)==0 && (hue ?? 0)==0 && (colorize == nil || (colorizeAmount ?? 1)==0) && (texture ?? 0)==0 && (clarity ?? 0)==0 && (dehaze ?? 0)==0 && (grain ?? 0)==0 && curves?.enabled != true && grading?.isNeutral != false && (gradingLUT?.amount ?? 0) == 0 && (sharpness ?? 0)==0 && (noiseReduction ?? 0)==0 && (moireReduction ?? 0)==0 && (defringe ?? 0)==0 }
  public func validate() throws {
    try DevelopmentV3Validation.range([exposure],-2...2)
    try DevelopmentV3Validation.range([highlights,shadows,saturation],-1...1)
    if let glowAmount { try DevelopmentV3Validation.range([glowAmount],0...1) }
    if let contrast { try DevelopmentV3Validation.range([contrast],-1...2) }
    if let whites { try DevelopmentV3Validation.range([whites],-1...1) }
    if let blacks { try DevelopmentV3Validation.range([blacks],-2...2) }
    if let temperature { try DevelopmentV3Validation.range([temperature],-1...1) }
    if let tint { try DevelopmentV3Validation.range([tint],-1...1) }
    if let hue { try DevelopmentV3Validation.range([hue],-1...1) }
    if let colorize {
      try colorize.validate();try DevelopmentV3Validation.range([colorize.red,colorize.green,colorize.blue],0...1)
    }
    if let colorizeAmount { try DevelopmentV3Validation.range([colorizeAmount],0...1) }
    if let texture { try DevelopmentV3Validation.range([texture],-1...1) }
    if let clarity { try DevelopmentV3Validation.range([clarity],-1...1) }
    if let dehaze { try DevelopmentV3Validation.range([dehaze],-1...1) }
    if let grain { try DevelopmentV3Validation.range([grain],0...1) }
    if let grainSize { try DevelopmentV3Validation.range([grainSize],0...1) }
    if let grainRoughness { try DevelopmentV3Validation.range([grainRoughness],0...1) }
    if let sharpness { try DevelopmentV3Validation.range([sharpness],-1...1) }
    if let noiseReduction { try DevelopmentV3Validation.range([noiseReduction],0...1) }
    if let moireReduction { try DevelopmentV3Validation.range([moireReduction],0...1) }
    if let defringe { try DevelopmentV3Validation.range([defringe],-1...1) }
    try curves?.validate();try grading?.validate();try pointColor?.validate()
    try gradingLUT?.validate()
  }
}

public struct DevelopmentMaskLayerV3: Codable, Equatable, Sendable, Identifiable {
  public static let maximumLayers=32
  public static let maximumSubjectPNGBytes=4*1024*1024
  public var id: UUID
  public var name: String
  public var enabled: Bool
  public var kind: DevelopmentMaskKindV3
  public var start, end, center: DevelopmentSourcePoint
  public var radiusX, radiusY, feather, opacity: Double
  public var rangeLower, rangeUpper: Double
  public var inverted: Bool
  public var adjustments: DevelopmentMaskAdjustmentsV3
  /// A downsampled 8-bit Vision result. Replay never repeats subject inference.
  public var subjectPNG: Data?
  public init(id: UUID = UUID(), name: String = "蒙版", enabled: Bool = true, kind: DevelopmentMaskKindV3,
              start: DevelopmentSourcePoint = .init(x:0.25,y:0.25), end: DevelopmentSourcePoint = .init(x:0.75,y:0.75),
              center: DevelopmentSourcePoint = .init(x:0.5,y:0.5), radiusX: Double = 0.3, radiusY: Double = 0.3,
              feather: Double = 0.2, opacity: Double = 1, rangeLower: Double = 0, rangeUpper: Double = 1,
              inverted: Bool = false, adjustments: DevelopmentMaskAdjustmentsV3 = .init(), subjectPNG: Data? = nil) {
    self.id=id;self.name=name;self.enabled=enabled;self.kind=kind;self.start=start;self.end=end;self.center=center
    self.radiusX=radiusX;self.radiusY=radiusY;self.feather=feather;self.opacity=opacity
    self.rangeLower=rangeLower;self.rangeUpper=rangeUpper;self.inverted=inverted;self.adjustments=adjustments;self.subjectPNG=subjectPNG
  }
  public func validate() throws {
    guard (1...80).contains(name.count),opacity.isFinite,(0...1).contains(opacity),feather.isFinite,(0...1).contains(feather),
      radiusX.isFinite,radiusY.isFinite,(0.001...2).contains(radiusX),(0.001...2).contains(radiusY),
      rangeLower.isFinite,rangeUpper.isFinite,(0...1).contains(rangeLower),(0...1).contains(rangeUpper),rangeLower<rangeUpper else { throw EditingError.invalidRecipe }
    try start.validate();try end.validate();try center.validate();try adjustments.validate()
    if kind == .subject { guard let subjectPNG,!subjectPNG.isEmpty,subjectPNG.count<=Self.maximumSubjectPNGBytes else { throw EditingError.invalidRecipe } }
    else if subjectPNG != nil { throw EditingError.invalidRecipe }
  }
  public static func validateLayers(_ layers:[Self]) throws {
    guard layers.count<=maximumLayers else { throw EditingError.invalidRecipe }
    var ids=Set<UUID>();for layer in layers {try layer.validate();guard ids.insert(layer.id).inserted else {throw EditingError.invalidRecipe}}
  }
}
