import Foundation
import CoreImage
import ImageIO
import RAWMasterCore

public enum DevelopmentV3Error: LocalizedError, Equatable, Sendable {
  case unsupportedAdjustment(DevelopmentAdjustmentID), unsupportedGeometry, unsupportedAnalysis
  case unsupportedNativeParameters, unrepresentableParameters, invalidGraph
  public var errorDescription: String? {
    switch self {
    case .unsupportedAdjustment(let group): return "当前图像引擎尚未实现此调整：\(group.rawValue)"
    case .unsupportedGeometry: return "当前图像引擎尚未实现此几何变换"
    case .unsupportedAnalysis: return "当前图像引擎尚未实现此分析操作"
    case .unsupportedNativeParameters: return "RAW 解码器不支持请求的原生参数"
    case .unrepresentableParameters: return "当前图像引擎无法精确表示这些参数"
    case .invalidGraph: return "图像处理图或画布无效"
    }
  }
}
struct DevelopedV3Graph {
  let image: CIImage
  let sourceDepth: Int?
  let sourceSize: CGSize
  let canonicalSize: CGSize
  let graphDescriptor: String
  var brilliancePublic:DevelopmentBrilliancePublicV1.Observation? = nil
  var dehazeTIFFRequestID:UUID? = nil
}
/// One v3 graph for preview, export and provider inputs. Public CI/Metal only.
enum DevelopmentRendererV3 {
  static let pipelineVersion = "rawmaster-v3.2/fresh-adjust-neutral-F32/native-raw-exposure-before-legacy-color/image-exposure-after-legacy-color"
  static let nativeContract = "rawmaster-v3.2/scale1/draftfalse/effectiveEV-absoluteWB-NR/original-neutral-defaults-attested/linear-F32-premul"
  struct NativeParameters {
    let exposure: Float
    let whiteBalance: DevelopmentWhiteBalance
    let noiseReduction: DevelopmentRAWNoiseReductionParametersV3?
    let originalDefaultsFingerprint: String?
    init(_ payload: DevelopmentAdjustmentsV3, noiseDefaults: DevelopmentRAWNoiseReductionDefaultsV3? = nil, originalDefaultsFingerprint: String? = nil) throws {
      let ev = (payload.legacyBasis?.exposureEV ?? 0)+(payload.light.enabled ? 2*payload.light.exposure:0)
      guard ev.isFinite, Float(ev).isFinite else { throw DevelopmentV3Error.unsupportedNativeParameters }
      exposure = Float(ev)
      whiteBalance = try DevelopmentWhiteBalanceEngineV3.nativeTarget(payload.whiteBalance) ?? payload.legacyBasis?.whiteBalance ?? .asShot
      self.originalDefaultsFingerprint = originalDefaultsFingerprint
      if payload.noiseReduction.enabled {
        guard let noiseDefaults else { throw DevelopmentV3Error.unsupportedNativeParameters }
        noiseReduction = try noiseDefaults.resolving(payload.noiseReduction)
      } else { noiseReduction = nil }
    }
    func effectiveFingerprint(original: String) throws -> String {
      struct Attestation: Encodable { let original: String; let noise: DevelopmentRAWNoiseReductionParametersV3? }
      return try EditingFingerprint.of(Attestation(original:original,noise:noiseReduction))
    }
    var whiteBalanceRequest: NativeWBRequest {
      switch whiteBalance { case .asShot: return .asShot
      case let .temperatureTint(t,v): return .temperatureTint(Float(t).bitPattern,Float(v).bitPattern) }
    }
  }
  private struct DecoderDefaults: Encodable {
    let floatBits: [UInt32]
    let flags: [Bool]
    let originalNeutralBits: [UInt64]
  }
  /// Unchanged decoder defaults are attested, not silently replaced by an all-zero NR preset.
  static func decoderDefaultsFingerprint(_ raw: CIRAWFilter) throws -> String {
    let values: [Float] = [raw.baselineExposure,raw.shadowBias,raw.boostAmount,raw.boostShadowAmount,
      raw.luminanceNoiseReductionAmount,raw.colorNoiseReductionAmount,raw.sharpnessAmount,raw.contrastAmount,
      raw.detailAmount,raw.moireReductionAmount,raw.despeckleAmount,raw.localToneMapAmount,raw.extendedDynamicRangeAmount]
    guard values.allSatisfy(\.isFinite) else { throw DevelopmentV3Error.unsupportedNativeParameters }
    var flags = [raw.isGamutMappingEnabled,raw.isLensCorrectionEnabled,raw.isLuminanceNoiseReductionSupported,
      raw.isColorNoiseReductionSupported,raw.isSharpnessSupported,raw.isContrastSupported,raw.isDetailSupported,
      raw.isMoireReductionSupported,raw.isDespeckleSupported,raw.isLocalToneMapSupported]
    if #available(macOS 26, *) { flags += [raw.isHighlightRecoverySupported,raw.isHighlightRecoveryEnabled] }
    let neutral = raw.neutralChromaticity
    guard neutral.x.isFinite, neutral.y.isFinite, raw.neutralTemperature.isFinite, raw.neutralTint.isFinite else { throw DevelopmentV3Error.unsupportedNativeParameters }
    return try EditingFingerprint.of(DecoderDefaults(floatBits:values.map(\.bitPattern)+[raw.neutralTemperature.bitPattern,raw.neutralTint.bitPattern],flags:flags,
      originalNeutralBits:[Double(neutral.x).bitPattern,Double(neutral.y).bitPattern]))
  }
  static func localDecoderFingerprint(decoder: String, originalDefaults: String?, orientation: Int, size: CGSize) throws -> String {
    guard size.width.isFinite,size.height.isFinite,size.width >= 1,size.height >= 1,
      size.width <= Double(DevelopmentLocalEditLimits.maximumSourceDimension),size.height <= Double(DevelopmentLocalEditLimits.maximumSourceDimension) else { throw DevelopmentV3Error.invalidGraph }
    struct Contract: Encodable { let version,decoder,nativeContract,stagePipeline,os:String;let originalDefaults:String?;let orientation,width,height:Int }
    let filterStage=try DevelopmentPhotoFilterEngineV3.stageIdentity()
    let stages=[pipelineVersion,filterStage,DevelopmentSpatialEngineV3.operatorVersion,DevelopmentColorEngineV3.operatorVersion,DevelopmentGlobalEngineV3.operatorVersion,DevelopmentWhiteBalanceEngineV3.operatorVersion,DevelopmentAdvancedDetailEngineV3.operatorVersion,DevelopmentDehazeEngineV3.operatorVersion,DevelopmentLocalEngineV3.operatorVersion,"canonical-local-I0-v1/no-exact-legacy-delegate"].joined(separator:"/")
    return try EditingFingerprint.of(Contract(version:"local-decoder-contract-v1",decoder:decoder,nativeContract:nativeContract,
      stagePipeline:stages,
      os:ProcessInfo.processInfo.operatingSystemVersionString,originalDefaults:originalDefaults,orientation:orientation,width:Int(size.width),height:Int(size.height)))
  }
  static func noiseDefaults(_ raw: CIRAWFilter) -> DevelopmentRAWNoiseReductionDefaultsV3 {
    .init(luminance:raw.luminanceNoiseReductionAmount,color:raw.colorNoiseReductionAmount,detail:raw.detailAmount,
      luminanceSupported:raw.isLuminanceNoiseReductionSupported,colorSupported:raw.isColorNoiseReductionSupported,detailSupported:raw.isDetailSupported)
  }
  static func configure(_ raw: CIRAWFilter, parameters: NativeParameters) throws {
    if let expected = parameters.originalDefaultsFingerprint, try decoderDefaultsFingerprint(raw) != expected { throw DevelopmentV3Error.unsupportedNativeParameters }
    raw.scaleFactor = 1; raw.isDraftModeEnabled = false; raw.exposure = parameters.exposure
    if case let .temperatureTint(t,v) = parameters.whiteBalance {
      let temp = Float(t), tint = Float(v); raw.neutralTemperature = temp; raw.neutralTint = tint
      guard raw.neutralTemperature.bitPattern == temp.bitPattern, raw.neutralTint.bitPattern == tint.bitPattern else { throw DevelopmentV3Error.unsupportedNativeParameters }
    }
    if let nr = parameters.noiseReduction {
      if raw.isLuminanceNoiseReductionSupported, raw.luminanceNoiseReductionAmount.bitPattern != nr.luminanceBits { raw.luminanceNoiseReductionAmount = nr.luminance }
      if raw.isColorNoiseReductionSupported, raw.colorNoiseReductionAmount.bitPattern != nr.colorBits { raw.colorNoiseReductionAmount = nr.color }
      if raw.isDetailSupported, raw.detailAmount.bitPattern != nr.detailBits { raw.detailAmount = nr.detail }
      guard raw.luminanceNoiseReductionAmount.bitPattern == nr.luminanceBits, raw.colorNoiseReductionAmount.bitPattern == nr.colorBits,
        raw.detailAmount.bitPattern == nr.detailBits else { throw DevelopmentV3Error.unsupportedNativeParameters }
    }
    guard raw.exposure.bitPattern == parameters.exposure.bitPattern, raw.scaleFactor == 1, !raw.isDraftModeEnabled else { throw DevelopmentV3Error.unsupportedNativeParameters }
  }
  static func validateSupport(_ recipe: DevelopmentRecipe, sourceIsRAW: Bool) throws {
    try recipe.validate()
    guard recipe.schemaVersion == 3, let p = recipe.adjustmentsV3 else { throw DevelopmentError.unsupportedEngine }
    if p.blackAndWhite.grainSamplingVersion != nil, !sourceIsRAW { throw DevelopmentV3Error.unsupportedAdjustment(.blackAndWhite) }
    if let resolved = p.whiteBalance.resolvedState, resolved.sourceCapability != (sourceIsRAW ? .raw:.image) { throw EditingError.invalidRecipe }
    if p.advancedDetail.dehaze.enabled && p.advancedDetail.dehaze.amount != 0 {
      guard p.advancedDetail.preparedDehaze != nil else { throw DevelopmentDehazePreparationError.preparationRequired }
    }
    if p.whiteBalance.enabled, p.whiteBalance.resolvedState == nil {
      switch p.whiteBalance.adjustment { case .asShot,.temperatureTint:break; default:throw DevelopmentV3Error.unsupportedAdjustment(.whiteBalance) }
    }
    try p.noiseReduction.validate(for:sourceIsRAW ? .raw:.image)
    _ = try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(p.filter)
    try DevelopmentLocalEngineV3.validate(p.localEdits)
    let g = p.geometry
    if g.version == .adjustV3 && (g.verticalPerspective != 0 || g.horizontalPerspective != 0) { throw DevelopmentV3Error.unsupportedGeometry }
  }
  static func hasNewEffects(_ p: DevelopmentAdjustmentsV3) -> Bool {
    let nr = p.noiseReduction, g = p.geometry
    return p.advancedDetail.hasEffects || (p.whiteBalance.enabled && p.whiteBalance.resolvedState != nil) ||
      (p.light.enabled && p.light.exposure != 0) || DevelopmentSpatialEngineV3.isActive(p.light) ||
      DevelopmentColorEngineV3.pointwiseActive(p) || DevelopmentColorEngineV3.curvesActive(p.curves) || DevelopmentColorEngineV3.levelsActive(p.levels) ||
      (p.whiteBalance.enabled && (p.whiteBalance.adjustment != .asShot || (p.legacyBasis?.whiteBalance ?? .asShot) != .asShot)) ||
      (p.definition.enabled && p.definition.amount != 0) ||
      (p.selectiveColor.enabled && p.selectiveColor.colors.contains { $0.hue != 0 || $0.saturation != 0 || $0.luminance != 0 }) ||
      (nr.enabled && (nr.sourceCapability == .raw ? (nr.luminanceNoise != 0 || nr.colorNoise != 0 || nr.detail != 0):(nr.nonRawAmount != 0))) ||
      (p.sharpen.enabled && p.sharpen.intensity != 0) || (p.vignette.enabled && p.vignette.strength != 0) ||
      (p.filter.enabled && p.filter.selection != .original && p.filter.intensity != 0) ||
      p.localEdits.operations.contains { $0.tool == .retouch ? p.localEdits.retouchEnabled:p.localEdits.redEyeEnabled } ||
      ((g.version == .adjustV3 || g.version == .projectiveV3_1) && (g.straightenDegrees != 0 || g.crop != NormalizedCrop() || g.clockwiseQuarterTurns != 0 || g.flipHorizontal || g.flipVertical || g.verticalPerspective != 0 || g.horizontalPerspective != 0 || g.lateOrientation.orientation != .identity))
  }
  private static func validateLocalSource(_ p: DevelopmentAdjustmentsV3, capture: URL, isRAW: Bool) throws {
    guard p.localEdits.sourceBinding != nil || p.whiteBalance.resolvedState != nil else { return }
    let size: CGSize, orientation: Int
    if isRAW {
      guard let raw = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }
      raw.scaleFactor = 1; raw.isDraftModeEnabled = false
      guard let image = raw.outputImage else { throw DevelopmentError.unreadable }; size = image.extent.size; orientation = Int(raw.orientation.rawValue)
    } else {
      guard let image = CIImage(contentsOf:capture,options:[.applyOrientationProperty:true]), let source = CGImageSourceCreateWithURL(capture as CFURL,nil),
        let metadata = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] else { throw DevelopmentError.unreadable }
      size = image.extent.size; orientation = (metadata[kCGImagePropertyOrientation] as? Int) ?? 1
    }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size.width <= Double(DevelopmentLocalEditLimits.maximumSourceDimension), size.height <= Double(DevelopmentLocalEditLimits.maximumSourceDimension) else { throw DevelopmentV3Error.invalidGraph }
    let binding = DevelopmentLocalEditSourceBinding(sourceContentID:try RenderFiles.hash(capture),exifOrientation:orientation,orientedWidth:Int(size.width),orientedHeight:Int(size.height))
    try p.localEdits.validate(expectedSource:binding)
    try p.whiteBalance.resolvedState?.validate(expectedSource:binding)
  }
  static func legacyRecipe(_ p: DevelopmentAdjustmentsV3) throws -> DevelopmentRecipe {
    var result = DevelopmentRecipe(exposureEV:p.legacyBasis?.exposureEV ?? 0,whiteBalance:p.legacyBasis?.whiteBalance ?? .asShot,
      straightenDegrees:p.geometry.straightenDegrees,crop:p.geometry.crop)
    if p.legacyBasis?.version == .v2 { result = try result.promotingToV2(); result.color = p.legacyBasis!.color }
    try result.validate(); return result
  }
  static func legacyEquivalent(_ recipe: DevelopmentRecipe) throws -> DevelopmentRecipe? {
    try recipe.validate()
    // Promotion records its historical geometry version even when a neutral legacy basis is nil.
    // A newly created adjustV3 recipe instead owns the F32 path, including its neutral state.
    guard let p = recipe.adjustmentsV3, (p.geometry.version == .legacyV1 || p.geometry.version == .legacyV2), !hasNewEffects(p) else { return nil }
    return try legacyRecipe(p)
  }
  /// Only the RAW legacy-v1 analysis branch owns this short validation lifetime.
  /// Export and all other graph/context selections retain their existing behavior.
  static func ownsAnalysisLegacyValidationContext(requested: Bool, sourceIsRAW: Bool,
      applyGeometry: Bool, parameters: DevelopmentAdjustmentsV3, legacy: DevelopmentRecipe) -> Bool {
    requested && sourceIsRAW && !applyGeometry && parameters.geometry.version == .legacyV1 &&
      !hasNewEffects(parameters) && legacy.schemaVersion == 1 && legacy.engineVersion == "core-image-v1"
  }
  /// The same options as PhotoRenderer.context, with no format or memory-target override.
  /// The body must finish its native tasks before returning; no context escapes this scope.
  static func withOwnedAnalysisLegacyValidationContext(_ body: (CIContext) throws -> Void) rethrows {
    try autoreleasepool {
      let context = CIContext(options:[.cacheIntermediates:false,
        .workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
      defer { context.clearCaches() }
      try body(context)
    }
  }
  static func develop(_ capture: URL, recipe: DevelopmentRecipe, applyGeometry: Bool = true,
                      suppliedRawBase: CIImage? = nil, suppliedImageBase: DevelopmentSuppliedImageBaseV1? = nil, context suppliedContext: CIContext? = nil,
                      thumbnailNativeSink: ((CIImage) throws -> Void)? = nil, localDecoderContractFingerprint: String? = nil, preparingLocal: Bool = false, preparingDehazeContext: DevelopmentDehazeContextV1? = nil, canonicalFiniteEvidence: PreviewCanonicalFiniteEvidenceV1? = nil, canonicalNaturalEvidence:PreviewNaturalCurveFiniteEvidenceV1? = nil, naturalFiniteObservation:PreviewNaturalCurveFiniteObservation? = nil, preparingNaturalCurvePicker: Bool = false, analysisOwnsLegacyValidationContext: Bool = false, analysisResidentInput: DevelopmentBWSummaryResidentV3.Input? = nil, brillianceQARequest:DevelopmentBrilliancePublicV1.Request? = nil, dehazeTIFFInvocation:DevelopmentDehazeTIFFInvocationV1? = nil, checkCancellation: (() throws -> Void)? = nil) throws -> DevelopedV3Graph {
    var context:CIContext{dehazeTIFFInvocation?.currentContext ?? suppliedContext ?? DevelopmentColorEngineV3.context}
    let isRAW = PhotoRenderer.rawExtensions.contains(capture.pathExtension.lowercased())
    try validateSupport(recipe,sourceIsRAW:isRAW)
    let p = recipe.adjustmentsV3!
    if let dehazeTIFFInvocation {
      try dehazeTIFFInvocation.requireRequest(capture,recipe:recipe,sourceIsRAW:isRAW,applyGeometry:applyGeometry)
      guard suppliedRawBase==nil,suppliedImageBase==nil,suppliedContext==nil,localDecoderContractFingerprint==nil,
        !preparingLocal,preparingDehazeContext==nil,canonicalFiniteEvidence==nil,canonicalNaturalEvidence==nil,
        naturalFiniteObservation==nil,!preparingNaturalCurvePicker,!analysisOwnsLegacyValidationContext,
        analysisResidentInput==nil,brillianceQARequest==nil else{throw DevelopmentV3Error.invalidGraph}
    }
    if let analysisResidentInput {
      guard isRAW,!applyGeometry,analysisOwnsLegacyValidationContext,suppliedRawBase == nil,suppliedImageBase == nil,
        thumbnailNativeSink == nil,localDecoderContractFingerprint == nil,!preparingLocal,preparingDehazeContext == nil,
        canonicalFiniteEvidence == nil,canonicalNaturalEvidence == nil,naturalFiniteObservation == nil,
        !preparingNaturalCurvePicker,brillianceQARequest == nil,
        let legacy = try legacyEquivalent(recipe),legacy == DevelopmentRecipe(),
        ownsAnalysisLegacyValidationContext(requested:true,sourceIsRAW:true,applyGeometry:false,parameters:p,legacy:legacy)
        else { throw DevelopmentV3Error.unsupportedAnalysis }
      try analysisResidentInput.requireCurrent()
    }
    let newBrilliance=DevelopmentBrilliancePublicV1.active(recipe)
    if newBrilliance {
      guard brillianceQARequest != nil,!preparingNaturalCurvePicker,!preparingLocal,preparingDehazeContext == nil,
        suppliedRawBase == nil,suppliedImageBase == nil,canonicalFiniteEvidence == nil,canonicalNaturalEvidence == nil else{throw DevelopmentV3Error.unsupportedAdjustment(.light)}
      try DevelopmentBrilliancePublicV1.requireDomain(p,sourceIsRAW:isRAW)
      try brillianceQARequest?.requireCurrent()
    }
    var brillianceObservation:DevelopmentBrilliancePublicV1.Observation?
    if preparingNaturalCurvePicker {
      guard !applyGeometry,suppliedRawBase == nil,suppliedImageBase == nil,thumbnailNativeSink == nil,
        canonicalFiniteEvidence == nil,canonicalNaturalEvidence == nil,naturalFiniteObservation == nil,localDecoderContractFingerprint == nil,!preparingLocal,preparingDehazeContext == nil else { throw DevelopmentV3Error.invalidGraph }
      try DevelopmentNaturalCurvePickerV1.validateAdmission(p,sourceIsRAW:isRAW)
      try checkCancellation?()
    }
    try validateLocalSource(p,capture:capture,isRAW:isRAW)
    if let expected=preparingDehazeContext {
      let actual=try DevelopmentDehazeContextFactoryV1.fromCapture(capture,generation:expected.sourceGeneration)
      guard actual==expected else { throw DevelopmentDehazePreparationError.staleInput }
      guard !p.advancedDetail.dehaze.enabled,p.advancedDetail.preparedDehaze==nil,
        p.localEdits == DevelopmentLocalEditsV3(),p.geometry == DevelopmentGeometryV3() else { throw DevelopmentDehazePreparationError.invalidPreparation }
    } else if p.advancedDetail.dehaze.enabled && p.advancedDetail.dehaze.amount != 0 {
      try DevelopmentDehazeContextFactoryV1.requirePrepared(recipe,context:DevelopmentDehazeContextFactoryV1.fromCapture(capture))
    }
    if !preparingNaturalCurvePicker, !preparingLocal, preparingDehazeContext == nil, suppliedRawBase == nil, suppliedImageBase == nil, (p.geometry.version == .legacyV1 || p.geometry.version == .legacyV2), !hasNewEffects(p) {
      var legacy = try legacyRecipe(p)
      if !applyGeometry { legacy.straightenDegrees = 0; legacy.crop = .init() }
      let value = try PhotoRenderer.develop(capture,legacy,analysisResidentInput:analysisResidentInput)
      let ownsAnalysisContext = ownsAnalysisLegacyValidationContext(requested:analysisOwnsLegacyValidationContext,sourceIsRAW:isRAW,
        applyGeometry:applyGeometry,parameters:p,legacy:legacy)
      if ownsAnalysisContext {
        try withOwnedAnalysisLegacyValidationContext { validationContext in
          try DevelopmentColorEngineV3.validateFinite(value.0,context:validationContext,checkCancellation:checkCancellation)
        }
      } else {
        try DevelopmentColorEngineV3.validateFinite(value.0,context:PhotoRenderer.renderingContext(legacy),checkCancellation:checkCancellation)
      }
      // The graph is unchanged. Only the explicitly requested analysis validation owner retires here.
      let sourceSize: CGSize
      if ownsAnalysisContext {
        // Only the size value survives this analysis metadata query.
        sourceSize = autoreleasepool {
          let sourceSize: CGSize
          if isRAW, let raw = CIRAWFilter(imageURL:capture), let native = raw.outputImage { sourceSize = native.extent.size }
          else if let source = CGImageSourceCreateWithURL(capture as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
            sourceSize = orientation >= 5 ? CGSize(width:height,height:width):CGSize(width:width,height:height)
          } else { sourceSize = value.0.extent.size }
          return sourceSize
        }
      } else {
        if isRAW, let raw = CIRAWFilter(imageURL:capture), let native = raw.outputImage { sourceSize = native.extent.size }
        else if let source = CGImageSourceCreateWithURL(capture as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
          let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
          sourceSize = orientation >= 5 ? CGSize(width:height,height:width):CGSize(width:width,height:height)
        } else { sourceSize = value.0.extent.size }
      }
      return .init(image:value.0,sourceDepth:value.1,sourceSize:sourceSize,canonicalSize:value.0.extent.size,graphDescriptor:pipelineVersion+(analysisResidentInput == nil ? "/exact-legacy":"/"+DevelopmentBWSummaryResidentV3.version))
    }
    // Optional profile input is an already verified oriented native image, BEFORE WB/EV.
    // Its caller owns the complete descriptor/pin. Defaultnil keeps the original path.
    guard suppliedImageBase == nil || (!isRAW && suppliedRawBase == nil && localDecoderContractFingerprint == nil && !preparingLocal && preparingDehazeContext == nil) else { throw DevelopmentV3Error.invalidGraph }
    if suppliedImageBase != nil, try legacyEquivalent(recipe) != nil { throw DevelopmentV3Error.invalidGraph }
    var image: CIImage; var depth: Int?
    var brillianceInputICC:Data?
    if let suppliedRawBase {
      guard isRAW, localDecoderContractFingerprint == nil else { throw DevelopmentV3Error.invalidGraph }; image = suppliedRawBase
      try thumbnailNativeSink?(image.transformed(by:.init(translationX:-image.extent.minX,y:-image.extent.minY)))
    } else if isRAW {
      guard let raw = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }
      if let expected = localDecoderContractFingerprint {
        guard let original = raw.outputImage,
          expected == (try localDecoderFingerprint(decoder:raw.decoderVersion.rawValue,originalDefaults:decoderDefaultsFingerprint(raw),
            orientation:Int(raw.orientation.rawValue),size:original.extent.size)) else { throw DevelopmentLocalPreparationError.staleInput }
      }
      try configure(raw,parameters:NativeParameters(p,noiseDefaults:noiseDefaults(raw),originalDefaultsFingerprint:try decoderDefaultsFingerprint(raw)))
      guard let output = raw.outputImage else { throw DevelopmentV3Error.unsupportedNativeParameters }; image = output
      try thumbnailNativeSink?(image.transformed(by:.init(translationX:-image.extent.minX,y:-image.extent.minY)))
    } else {
      let output:CIImage,originalDepth:Int
      if let suppliedImageBase {
        output=suppliedImageBase.image;originalDepth=suppliedImageBase.sourceDepth
      } else {
        guard let decoded = CIImage(contentsOf:capture,options:[.applyOrientationProperty:true]),
          let source = CGImageSourceCreateWithURL(capture as CFURL,nil), let cg = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw DevelopmentError.unreadable }
        if let expected = localDecoderContractFingerprint {
          let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
          guard expected == (try localDecoderFingerprint(decoder:"image-io",originalDefaults:nil,
            orientation:(properties?[kCGImagePropertyOrientation] as? Int) ?? 1,size:decoded.extent.size)) else { throw DevelopmentLocalPreparationError.staleInput }
        }
        output=decoded;originalDepth=cg.bitsPerComponent
        if newBrilliance,let profile=cg.colorSpace?.copyICCData(){brillianceInputICC=profile as Data}
      }
      image = output; depth = originalDepth
      try thumbnailNativeSink?(image.transformed(by:.init(translationX:-image.extent.minX,y:-image.extent.minY)))
      if let basis = p.legacyBasis {
        if !p.whiteBalance.enabled, case let .temperatureTint(t,v) = basis.whiteBalance { image = image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:t,y:v),"inputTargetNeutral":CIVector(x:6500,y:0)]) }
        if basis.exposureEV != 0 { image = image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:basis.exposureEV]) }
      }
    }
    guard !image.extent.isEmpty, !image.extent.isInfinite, image.extent.width.isFinite, image.extent.height.isFinite else { throw DevelopmentV3Error.invalidGraph }
    if p.blackAndWhite.grainSamplingVersion != nil,
      !DevelopmentGrainSamplingEngineV1.validNativeExtent(image.extent) { throw DevelopmentV3Error.invalidGraph }
    image = image.transformed(by:.init(translationX:-image.extent.minX,y:-image.extent.minY)); let sourceSize = image.extent.size
    if !isRAW { image = try DevelopmentWhiteBalanceEngineV3.applyImage(p.whiteBalance,to:image,context:context,checkCancellation:checkCancellation) }
    if let color = p.legacyBasis?.color, !color.isNeutral { image = try DevelopmentColorEngineV2.apply(color,to:image) }
    // RAW applies the effective native EV before legacy color; rendered images apply this new EV here.
    if !isRAW, p.light.enabled, p.light.exposure != 0 { image = image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:2*p.light.exposure]) }
    if newBrilliance {
      guard let request=brillianceQARequest,depth==16,let profile=brillianceInputICC,
        DevelopmentBrilliancePublicV1.hash(profile)==PreviewWindows.icc else{throw DevelopmentV3Error.unsupportedAdjustment(.light)}
      let result=try DevelopmentBrilliancePublicV1.apply(image,parameters:p,capture:capture,context:context,request:request)
      image=result.0;brillianceObservation=result.1
    } else if DevelopmentBrillianceAdaptiveV1.isActive(p.light) {
      // This version defines its guide/map at this full native WB/EV/legacy-color prefix.
      // Keep the existing shadows/highlights operation after Brilliance; subsequent point/color
      // stages retain their order. No Photos equivalence is claimed for combined adjustments.
      image = try DevelopmentBrillianceAdaptiveV1.apply(p.light,to:image,sourceIsRAW:isRAW,context:context,checkCancellation:checkCancellation)
      var remainingLight=p.light;remainingLight.brilliance=0
      image = try DevelopmentSpatialEngineV3.applyLight(remainingLight,to:image)
    } else { image = try DevelopmentSpatialEngineV3.applyLight(p.light,to:image) }
    image = try DevelopmentColorEngineV3.applyPointwise(p,to:image,context:context,checkCancellation:checkCancellation)
    if preparingNaturalCurvePicker {
      try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation)
      try checkCancellation?()
      return .init(image:image,sourceDepth:depth,sourceSize:sourceSize,canonicalSize:image.extent.size,
        graphDescriptor:pipelineVersion+"/"+DevelopmentNaturalCurvePickerV1.samplingVersion)
    }
    image = try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:image,canonicalNaturalEvidence:canonicalNaturalEvidence)
    if !isRAW, p.noiseReduction.enabled, p.noiseReduction.nonRawAmount != 0 { try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation) }
    image = try DevelopmentGlobalEngineV3.apply(p,to:image,sourceIsRAW:isRAW)
    image = try DevelopmentPhotoFilterEngineV3.apply(p.filter,to:image)
    // Only this named global-output scan may use actual worker-scoped evidence.
    // Export/analysis/default callers pass nil and execute the unchanged checked scan.
    let globalFiniteProven = try canonicalFiniteEvidence?.consumeGlobalOutput(recipe:recipe,capture:capture,
      context:context,suppliedBase:suppliedRawBase ?? suppliedImageBase?.image,sourceIsRAW:isRAW,
      sourceSize:sourceSize,check:checkCancellation) ?? false
    let naturalFiniteProven = try canonicalNaturalEvidence?.consumeGlobalOutput(recipe:recipe,capture:capture,
      context:context,suppliedBase:suppliedRawBase ?? suppliedImageBase?.image,sourceIsRAW:isRAW,
      sourceSize:sourceSize,output:image,check:checkCancellation) ?? false
    if !globalFiniteProven && !naturalFiniteProven {
      if DevelopmentBrillianceAdaptiveV1.isActive(p.light) {
        try DevelopmentBrillianceAdaptiveV1.withOwnedFiniteValidationContext(sourceIsRAW:isRAW) { validation in
          try DevelopmentBrillianceAdaptiveV1.validateFinite(image,context:validation,checkCancellation:checkCancellation)
        }
      } else {
        try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation)
      }
      naturalFiniteObservation?.joinedGlobalScans += 1
    }
    if p.advancedDetail.hasEffects {
      // Source-native radii, after all global effects and before the ordered local prefix.
      // Off/zero takes no new graph, finite pass, context or GPU work.
      guard sourceSize.width==floor(sourceSize.width),sourceSize.height==floor(sourceSize.height),
        sourceSize.width<=Double(DevelopmentLocalEditLimits.maximumSourceDimension),
        sourceSize.height<=Double(DevelopmentLocalEditLimits.maximumSourceDimension) else { throw DevelopmentV3Error.invalidGraph }
      var bands=p.advancedDetail;bands.dehaze = .init() // T/C engine owns only its unchanged bands.
      image = try DevelopmentAdvancedDetailEngineV3.apply(bands,to:image,
        sourceSize:.init(width:Int(sourceSize.width),height:Int(sourceSize.height)),context:context,checkCancellation:checkCancellation)
    }
    if p.advancedDetail.dehaze.enabled && p.advancedDetail.dehaze.amount != 0 {
      if let dehazeTIFFInvocation {
        image = try dehazeTIFFInvocation.apply(p.advancedDetail,to:image,
          sourceSize:.init(width:Int(sourceSize.width),height:Int(sourceSize.height)))
      }else{
        image = try DevelopmentDehazeEngineV3.apply(p.advancedDetail,to:image,
          sourceSize:.init(width:Int(sourceSize.width),height:Int(sourceSize.height)),sourceIsRAW:isRAW,context:context,checkCancellation:checkCancellation)
      }
    }
    image = try DevelopmentLocalEngineV3.apply(p.localEdits,to:image,context:context,checkCancellation:checkCancellation)
    if applyGeometry {
      if p.geometry.version == .legacyV1 || p.geometry.version == .legacyV2 { image = try PhotoRenderer.applyV2Geometry(image,legacyRecipe(p)) }
      else {
        image = try DevelopmentGeometryEngineV3.apply(p.geometry,to:image)
        if DevelopmentBrillianceAdaptiveV1.isActive(p.light) {
          try DevelopmentBrillianceAdaptiveV1.withOwnedFiniteValidationContext(sourceIsRAW:isRAW) { validation in
            try DevelopmentBrillianceAdaptiveV1.validateFinite(image,context:validation,checkCancellation:checkCancellation)
          }
        } else {
          try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation)
        }
      }
    }
    let filterIdentity = try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(p.filter)
    let filterDescriptor = filterIdentity.map { "/photo-filter:"+$0 } ?? ""
    let dehazeVersion=(DevelopmentDehazeEngineV3.usesPositiveV2(p.advancedDetail) ?
      DevelopmentDehazeColorGuideV2.version:DevelopmentDehazeEngineV3.operatorVersion) +
      DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(p.advancedDetail,sourceIsRAW:isRAW) +
      (dehazeTIFFInvocation == nil ? DevelopmentDehazeNativeRfV1.keySuffix(p.advancedDetail):"/"+DevelopmentDehazeTIFFPreviewV1.version)
    let brillianceIdentity=brillianceObservation.map{"/transport:"+$0.transport} ?? ""
    let spatialIdentity=brillianceObservation?.version ?? (DevelopmentBrillianceAdaptiveV1.isActive(p.light) ?
      DevelopmentBrillianceAdaptiveV1.version+DevelopmentBrillianceNativeRGV1.keySuffix(p.light,sourceIsRAW:isRAW)+"/"+DevelopmentSpatialEngineV3.operatorVersion:DevelopmentSpatialEngineV3.operatorVersion)
    return .init(image:image,sourceDepth:depth,sourceSize:sourceSize,canonicalSize:image.extent.size,graphDescriptor:pipelineVersion+brillianceIdentity+DevelopmentGrainSamplingEngineV1.stageIdentity(p)+filterDescriptor+"/"+spatialIdentity+"/"+DevelopmentColorEngineV3.operatorVersion+"/"+DevelopmentGlobalEngineV3.operatorVersion+"/"+DevelopmentWhiteBalanceEngineV3.operatorVersion+"/"+DevelopmentGeometryEngineV3.operatorVersion+"/"+DevelopmentAdvancedDetailEngineV3.operatorVersion+"/"+dehazeVersion+"/"+DevelopmentLocalEngineV3.operatorVersion,brilliancePublic:brillianceObservation,dehazeTIFFRequestID:dehazeTIFFInvocation?.request.id)
  }
}
