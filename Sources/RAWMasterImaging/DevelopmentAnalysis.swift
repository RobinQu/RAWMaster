import Foundation
import CoreImage
import RAWMasterCore

public enum DevelopmentCurvePickerPointV3: String, Sendable { case black, midtone, white, addPoint }
public enum DevelopmentAnalysisOperation: Equatable, Sendable {
  case histogram
  /// Versioned display-only bins; never an input to automatic adjustments.
  case displayHistogram
  case displayMaskHistogram(UUID)
  case cropAutomatic
  case prepareDehaze
  case retouchSource(stroke: DevelopmentStroke, explicitDonor: DevelopmentSourcePoint?)
  case retouch(stroke: DevelopmentStroke, explicitDonor: DevelopmentSourcePoint?, mode: DevelopmentRetouchMode)
  case redEyeAt(sourcePoint: DevelopmentSourcePoint, radiusInShortEdge: Double, strength: Double)
  case redEyeAutomatic
  case automatic(DevelopmentAdjustmentID?)
  case automaticLight(DevelopmentLightAutoFieldV3)
  case summary(DevelopmentAdjustmentID, amount: Double)
  case curvePicker(channel: DevelopmentCurveChannelV3ID, point: DevelopmentCurvePickerPointV3, sourcePoint: DevelopmentSourcePoint)
  // Represented for a stable adapter boundary; P3B-A explicitly returns unsupported for these B tools.
  case whiteBalancePicker(sourcePoint: DevelopmentSourcePoint, mode: DevelopmentWhiteBalanceAdjustmentV3)
  case selectiveColorPicker(slot: DevelopmentSelectiveColorSlotV3, sourcePoint: DevelopmentSourcePoint)
  case defringePicker(band: DevelopmentDefringeBandV3, sourcePoint: DevelopmentSourcePoint)
  case pointColorPicker(id: UUID, sourcePoint: DevelopmentSourcePoint)
  case whiteBalanceAutomatic(mode: DevelopmentWhiteBalanceModeV3)
  var localTool: DevelopmentLocalTool? {
    switch self { case .retouchSource,.retouch:return .retouch; case .redEyeAt,.redEyeAutomatic:return .redEye; default:return nil }
  }
  var isHistogram: Bool { self == .histogram || isDisplayHistogram }
  var isDisplayHistogram: Bool { switch self { case .displayHistogram, .displayMaskHistogram: return true; default: return false } }
  var scopeMaskID: UUID? { if case let .displayMaskHistogram(id) = self { return id }; return nil }
}
public enum DevelopmentAnalysisSampling: Equatable, Sendable {
  case legacy
  case blackAndWhiteSummaryStripes32V2
  case blackAndWhiteSummaryResident32V3
  var usesBlackAndWhiteStripes: Bool { self == .blackAndWhiteSummaryStripes32V2 || self == .blackAndWhiteSummaryResident32V3 }
}

public struct DevelopmentAnalysisRequest: Sendable {
  public let sampling: DevelopmentAnalysisSampling
  public let cropAutoInputV1: DevelopmentCropAutoInputV1?
  public let localInputV1: DevelopmentLocalInputV1?
  public let dehazeInputV1: DevelopmentDehazeInputV1?
  public let operationID: UUID
  public let preview: DevelopmentPreviewRequest
  public let expectedRecipeFingerprint: String
  /// Visible draft may still be legacy while analysis uses an explicitly promoted immutable V3 snapshot.
  public let presentedRecipeFingerprint: String
  public let stage: DevelopmentAnalysisStage
  /// EXIF-oriented, pre-geometry source coordinates. This never means a screen/NSImage rectangle.
  public let roi: NormalizedCrop
  public let operation: DevelopmentAnalysisOperation
  public init(operationID: UUID = UUID(), preview: DevelopmentPreviewRequest, expectedRecipeFingerprint: String,
              stage: DevelopmentAnalysisStage, roi: NormalizedCrop = .init(), operation: DevelopmentAnalysisOperation, presentedRecipeFingerprint: String? = nil, localInputV1: DevelopmentLocalInputV1? = nil, dehazeInputV1: DevelopmentDehazeInputV1? = nil, cropAutoInputV1: DevelopmentCropAutoInputV1? = nil, sampling: DevelopmentAnalysisSampling = .legacy) {
    self.sampling = sampling
    self.cropAutoInputV1 = cropAutoInputV1
    self.localInputV1 = localInputV1
    self.dehazeInputV1 = dehazeInputV1
    self.operationID = operationID; self.preview = preview; self.expectedRecipeFingerprint = expectedRecipeFingerprint
    self.presentedRecipeFingerprint = presentedRecipeFingerprint ?? expectedRecipeFingerprint
    self.stage = stage; self.roi = roi; self.operation = operation
  }
  /// Includes the active Photo Filter resource identity, where applicable.
  public func matchesSamplingVersion(_ actual: String) throws -> Bool {
    actual == (try DevelopmentAnalysisEngine.validatedSamplingVersion(self))
  }
  func validateSamplingChoice() throws {
    if sampling.usesBlackAndWhiteStripes {
      guard case .summary(.blackAndWhite, _) = operation,
        stage == .workingImageBeforeGeometry, roi == NormalizedCrop() else { throw DevelopmentPreviewError.invalidRequest }
    }
  }
  func validate() throws {
    try validateSamplingChoice()
    try preview.recipe.validate()
    guard EditingFingerprint.isSHA256(expectedRecipeFingerprint), EditingFingerprint.isSHA256(presentedRecipeFingerprint), expectedRecipeFingerprint == (try EditingFingerprint.of(preview.recipe)),
      [roi.x,roi.y,roi.width,roi.height].allSatisfy(\.isFinite), roi.x >= 0, roi.y >= 0, roi.width > 0, roi.height > 0,
      roi.x+roi.width <= 1, roi.y+roi.height <= 1 else { throw DevelopmentPreviewError.invalidRequest }
    if operation.isDisplayHistogram { guard stage == .workingImageBeforeGeometry else { throw DevelopmentPreviewError.invalidRequest } }
    if let id = operation.scopeMaskID, preview.recipe.adjustmentsV3?.masks.contains(where: { $0.id == id }) != true {
      throw DevelopmentPreviewError.invalidRequest
    }
    if !operation.isHistogram { guard preview.recipe.schemaVersion == 3 else { throw DevelopmentAdjustmentCommandError.requiresV3 } }
    // Natural Auto is still unsupported. Picker has a distinct pre-curves contract,
    // including disabled natural metadata; never dispatch it through legacy sampling.
    if let curves = preview.recipe.adjustmentsV3?.curves, curves.algorithm != .legacyPCHIPV1 {
      switch operation {
      case .automatic(.some(.curves)): throw DevelopmentV3Error.unsupportedAnalysis
      case .curvePicker:
        guard curves.algorithm == .naturalCubicGamma512LumaV1,stage == .workingImageBeforeGeometry else { throw DevelopmentV3Error.unsupportedAnalysis }
      default: break
      }
    }
    if case .cropAutomatic = operation {
      guard stage == .orientedSourceBeforeGeometry, roi == NormalizedCrop(), let input = cropAutoInputV1,
        let geometry = preview.recipe.adjustmentsV3?.geometry,
        input.baselineGeometryFingerprint == (try EditingFingerprint.of(geometry)) else { throw DevelopmentPreviewError.invalidRequest }
      if let ratio = input.aspectRatio { guard ratio.isFinite, ratio > 0 else { throw DevelopmentPreviewError.invalidRequest } }
    } else if cropAutoInputV1 != nil { throw DevelopmentPreviewError.invalidRequest }
    if let target = operation.localTool {
      guard stage == .workingImageBeforeGeometry, roi == NormalizedCrop(), let input = localInputV1, input.targetTool == target else { throw DevelopmentPreviewError.invalidRequest }; try input.validate()
    } else if localInputV1 != nil { throw DevelopmentPreviewError.invalidRequest }
    if case .prepareDehaze=operation {
      guard let input=dehazeInputV1,stage == .workingImageBeforeGeometry,roi == NormalizedCrop(),
        input.context.sourceGeneration==preview.sourceGeneration else { throw DevelopmentPreviewError.invalidRequest }
      try input.context.validate()
    } else if dehazeInputV1 != nil { throw DevelopmentPreviewError.invalidRequest }
    switch operation {
    case .retouchSource(let stroke,let donor): try stroke.validate(); try donor?.validate()
    case .retouch(let stroke,let donor,let mode):
      try stroke.validate(); try donor?.validate(); if mode == .clone, donor == nil { throw DevelopmentPreviewError.invalidRequest }
    case .redEyeAt(let point,let radius,let strength):
      try DevelopmentStroke(points:[.init(position:point)],radiusInShortEdge:radius,strength:strength).validate()
    case let .summary(group,amount): guard [.light,.color,.blackAndWhite].contains(group), amount.isFinite, (-1...1).contains(amount) else { throw DevelopmentPreviewError.invalidRequest }
    case .curvePicker(_,_,let point): try point.validate()
    case .whiteBalancePicker(let point,let mode): try point.validate(); try mode.validate()
      guard stage == .orientedSourceBeforeGeometry else { throw DevelopmentPreviewError.invalidRequest }
      switch mode { case .neutralGray,.skinTone:break; default:throw DevelopmentPreviewError.invalidRequest }
    case .whiteBalanceAutomatic(let mode): guard mode != .asShot, stage == .orientedSourceBeforeGeometry else { throw DevelopmentPreviewError.invalidRequest }
    case .selectiveColorPicker(_,let point): try point.validate()
    case .defringePicker(_,let point): try point.validate()
    case .pointColorPicker(_,let point): try point.validate()
    default: break
    }
  }
}
public struct DevelopmentHistogramV3: Equatable, Sendable {
  /// Exactly256 bins each. Population is the explicit bounded source proxy, not a full-image count.
  public let red, green, blue, luminance: [UInt64]
  public let visibleSamples, transparentSamples: Int
  public let sampledSize: DevelopmentPixelSize
}
public enum DevelopmentAnalysisValue: Equatable, Sendable { case geometry(DevelopmentResolvedGeometryV1), histogram(DevelopmentHistogramV3), displayHistogram(DevelopmentDisplayHistogramV1), resolved(DevelopmentResolvedAdjustmentCommand), local(DevelopmentResolvedLocalBatch), dehaze(DevelopmentResolvedDehazeV1) }
public struct DevelopmentAnalysisResult: Equatable, Sendable {
  public let localPixelAttestation: DevelopmentLocalPixelAttestation?
  public let operationID: UUID
  public let sessionID: DevelopmentPreviewSessionID
  public let consumerID: PreviewConsumerID
  public let revision: UInt64
  public let role: PreviewConsumerRole
  public let quality: PreviewQuality
  public let actualRecipe: DevelopmentRecipe
  public let clientCorrelation: Data?
  public let binding: DevelopmentAnalysisBinding
  public let sourceBinding: DevelopmentLocalEditSourceBinding
  public let presentedRecipeFingerprint: String
  public let roi: NormalizedCrop
  public let samplingRecipeFingerprint: String
  public let samplingVersion: String
  public let geometryMapping: DevelopmentGeometryMappingV3
  public let value: DevelopmentAnalysisValue
  public init(operationID: UUID, sessionID: DevelopmentPreviewSessionID, consumerID: PreviewConsumerID, revision: UInt64,
              role: PreviewConsumerRole, quality: PreviewQuality, actualRecipe: DevelopmentRecipe, clientCorrelation: Data?,
              binding: DevelopmentAnalysisBinding, sourceBinding: DevelopmentLocalEditSourceBinding, presentedRecipeFingerprint: String,
              roi: NormalizedCrop, samplingRecipeFingerprint: String, samplingVersion: String,
              geometryMapping: DevelopmentGeometryMappingV3, value: DevelopmentAnalysisValue,
              localPixelAttestation: DevelopmentLocalPixelAttestation? = nil) {
    self.operationID=operationID;self.sessionID=sessionID;self.consumerID=consumerID;self.revision=revision
    self.role=role;self.quality=quality;self.actualRecipe=actualRecipe;self.clientCorrelation=clientCorrelation
    self.binding=binding;self.sourceBinding=sourceBinding;self.presentedRecipeFingerprint=presentedRecipeFingerprint
    self.roi=roi;self.samplingRecipeFingerprint=samplingRecipeFingerprint;self.samplingVersion=samplingVersion
    self.geometryMapping=geometryMapping;self.value=value;self.localPixelAttestation=localPixelAttestation
  }
}
public struct DevelopmentAnalysisStatistics: Sendable {
  public internal(set) var workingImageHits: UInt64 = 0, workingImageBuilds: UInt64 = 0, scalarHistoryHits: UInt64 = 0
  /// Uncompressed native rgba16Float source represented by the currently retained graph.
  public internal(set) var retainedWorkingSourceBytes: Int64 = 0
  public internal(set) var scalarHistoryEntries: Int = 0
  public internal(set) var submitted: UInt64 = 0
  public internal(set) var completed: UInt64 = 0
  public internal(set) var superseded: UInt64 = 0
  public internal(set) var pendingUser = 0
  public internal(set) var pendingHistogram = 0
  public internal(set) var active = 0
  public internal(set) var maximumActive = 0
}
public enum DevelopmentAnalysisError: Error, Equatable, Sendable { case noVisibleSamples }
struct DevelopmentAnalysisScalars {
  let histogram: DevelopmentHistogramV3
  let meanLinearRGB: SIMD3<Double>
  let meanSaturation: Double
  var noiseEstimate: Double = 0
  var edgeEnergy: Double = 0
  var cornerFalloff: Double = 0
  func percentile(_ fraction: Double) -> Double {
    let target = max(1,Int(ceil(fraction*Double(histogram.visibleSamples)))); var count: UInt64 = 0
    for (i,n) in histogram.luminance.enumerated() { count += n; if count >= target { return Double(i)/255 } }
    return 1
  }
}
struct DevelopmentAnalysisCacheEntry {
  let recipeFingerprint: String
  let stage: DevelopmentAnalysisStage
  let roi: NormalizedCrop
  let scalars: DevelopmentAnalysisScalars
  let filterResourceIdentity:String?
  let samplingVersion: String
  let residentIdentity: DevelopmentBWSummaryResidentV3.Identity?
  init(recipeFingerprint:String,stage:DevelopmentAnalysisStage,roi:NormalizedCrop,scalars:DevelopmentAnalysisScalars,filterResourceIdentity:String?,samplingVersion:String,residentIdentity:DevelopmentBWSummaryResidentV3.Identity? = nil) {
    self.recipeFingerprint=recipeFingerprint;self.stage=stage;self.roi=roi;self.scalars=scalars
    self.filterResourceIdentity=filterResourceIdentity;self.samplingVersion=samplingVersion;self.residentIdentity=residentIdentity
  }
  func matches(recipeFingerprint:String,stage:DevelopmentAnalysisStage,roi:NormalizedCrop,filterResourceIdentity:String?,samplingVersion:String,residentIdentity:DevelopmentBWSummaryResidentV3.Identity? = nil)->Bool {
    self.recipeFingerprint==recipeFingerprint && self.stage==stage && self.roi==roi &&
      self.filterResourceIdentity==filterResourceIdentity && self.samplingVersion==samplingVersion && self.residentIdentity==residentIdentity
  }
}
/// Executes only inside PreviewService's joined native worker. No process-global native/analysis pool.
enum DevelopmentAnalysisEngine {
  static let samplingVersion = "rawmaster-analysis-v3.4/linear-source-proxy128/encoded256bins/light-summary-calibration1/WB-original-skin-locus-v1/global-auto-residual128-v1"
  static let blackAndWhiteStripesVersion = "rawmaster-analysis-bw-summary-v2/linear-source-proxy128/global-readback32-clear-pool"
  static let maximumProxyDimension = 128
  static func requestsOwnedLegacyValidationContext(_ operation: DevelopmentAnalysisOperation) -> Bool {
    if case .summary(.blackAndWhite, _) = operation { return true }
    return false
  }
  /// BW summary resolves only from the measured scalars; keep every other operation's
  /// existing RAW-default query unchanged, including automatic noise reduction.
  static func requestsRAWNoiseDefaults(_ operation: DevelopmentAnalysisOperation) -> Bool {
    if case .summary(.blackAndWhite, _) = operation { return false }
    return true
  }
  static func samplingRecipe(_ request: DevelopmentAnalysisRequest) throws -> DevelopmentRecipe {
    if DevelopmentNaturalCurvePickerV1.isNatural(request) { return request.preview.recipe }
    if request.operation.localTool != nil { return try DevelopmentLocalAnalysisV3.projection(request).recipe }
    if case .prepareDehaze=request.operation { return try DevelopmentDehazeAnalysisV3.projection(request).samplingRecipe }
    var recipe = request.preview.recipe.schemaVersion == 3 ? request.preview.recipe : try request.preview.recipe.promotingToV3()
    let neutral = recipe.adjustmentsV3!.neutralForSameSource
    if case .cropAutomatic = request.operation { recipe.adjustmentsV3 = neutral; return recipe }
    var p = recipe.adjustmentsV3!
    switch request.operation {
    case .whiteBalancePicker,.whiteBalanceAutomatic:
      // Original pre-WB source: no historical WB/EV/color or any new source-dependent effect.
      recipe.adjustmentsV3 = neutral; return recipe
    default:break
    }
    if request.stage == .orientedSourceBeforeGeometry {
      p.light = .init(); p.color = .init(); p.blackAndWhite = .init(); p.curves = .init(); p.levels = .init()
    }
    switch request.operation {
    case .summary(let group,_): p.reset(group:group)
    case .automatic(let group):
      if let group { p.reset(group:group) }
      else { p.light = .init(); p.color = .init(); p.blackAndWhite = .init(); p.curves = .init(); p.levels = .init() }
    case .curvePicker: p.curves = .init(); p.levels = .init()
    case .selectiveColorPicker:p.selectiveColor = .init()
    default: break
    }
    recipe.adjustmentsV3 = p; try recipe.validate(); return recipe
  }
  static func run(capture: URL, request: DevelopmentAnalysisRequest, sourceBinding: DevelopmentLocalEditSourceBinding,
                  memoryHint: Int, cache: inout DevelopmentAnalysisCacheEntry?, localDecoderContractFingerprint: String? = nil, dehazeContext: DevelopmentDehazeContextV1? = nil, cancellation: DevelopmentAnalysisCancellation? = nil, residentInput: DevelopmentBWSummaryResidentV3.Input? = nil, analysisImages: DevelopmentAnalysisImageCache? = nil, sourceAuthority: (() throws -> Void)? = nil) throws -> DevelopmentAnalysisResult {
    guard !request.operation.isDisplayHistogram else { throw DevelopmentPreviewError.invalidRequest }
    try request.validate(); try sourceBinding.validate()
    let isRAW = PhotoRenderer.rawExtensions.contains(capture.pathExtension.lowercased())
    guard request.sampling == .legacy || isRAW else { throw DevelopmentPreviewError.invalidRequest }
    if request.sampling == .blackAndWhiteSummaryResident32V3 {
      try DevelopmentBWSummaryResidentV3.requireRequest(request, sourceIsRAW: isRAW)
      guard let residentInput else { throw DevelopmentV3Error.unsupportedAnalysis }
      try residentInput.requireCurrent()
    } else if residentInput != nil { throw DevelopmentV3Error.unsupportedAnalysis }
    if DevelopmentNaturalCurvePickerV1.isNatural(request) {
      try DevelopmentNaturalCurvePickerV1.validateAdmission(request.preview.recipe.adjustmentsV3!,sourceIsRAW:isRAW)
    }
    if request.preview.recipe.schemaVersion == 3 { try DevelopmentRendererV3.validateSupport(try samplingSupportRecipe(request),sourceIsRAW:isRAW) }
    switch request.operation {
    case .automatic(let group): if let group, ![.light,.color,.blackAndWhite,.curves,.levels,.definition,.noiseReduction,.sharpen,.vignette].contains(group) { throw DevelopmentV3Error.unsupportedAnalysis }
    default: break }
    let sampling = try samplingRecipe(request), fingerprint = try EditingFingerprint.of(sampling)
    let filterIdentity = try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(sampling)
    let effectiveVersion = resultSamplingVersion(request, filterIdentity: filterIdentity)
    let retainsImage: Bool
    switch request.operation {
    case .automatic, .automaticLight, .curvePicker, .whiteBalanceAutomatic, .selectiveColorPicker, .defringePicker, .pointColorPicker: retainsImage = true
    default: retainsImage = false
    }
    // Keep the native rgba16Float texture only for source/light/colour graphs. Multi-pass filters,
    // masks and local edits can retain additional full-size assets and use their existing lifetime.
    let pixels = Int64(sourceBinding.orientedWidth) * Int64(sourceBinding.orientedHeight)
    let maximumPixels = Int64(min(512, max(0, memoryHint))) * 1024 * 1024 / 8
    let plainGraph = retainsImage && analysisImages != nil ? DevelopmentAnalysisImageCache.removingInactiveColorSamples(from:sampling) : nil
    let parameters = (plainGraph ?? sampling).adjustmentsV3!
    var cacheable = parameters.neutralForSameSource
    cacheable.light = parameters.light; cacheable.color = parameters.color; cacheable.whiteBalance = parameters.whiteBalance
    cacheable.curves = parameters.curves; cacheable.rawDetails = parameters.rawDetails
    let images = retainsImage && request.sampling == .legacy && parameters.rawDecoder == .flashRaw031 &&
      cacheable == parameters && pixels <= maximumPixels ? analysisImages : nil
    let imageEpoch = images?.currentEpoch
    let context = images?.context(memoryHint:memoryHint) ?? CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryHint])
    defer { if images == nil { context.clearCaches() } }
    let natural = DevelopmentNaturalCurvePickerV1.isNatural(request)
    let ownLegacy = requestsOwnedLegacyValidationContext(request.operation)
    let graphFingerprint = try plainGraph.map(EditingFingerprint.of) ?? fingerprint
    let key = DevelopmentAnalysisImageCache.Key(capture:capture,contentID:sourceBinding.sourceContentID,
      generation:request.preview.sourceGeneration,samplingRecipe:graphFingerprint,stage:request.stage,version:effectiveVersion,
      filterResource:filterIdentity,graphKind:natural ? "pre-natural-curves" : (ownLegacy ? "owned-legacy" : "working"))
    func stillCurrent() throws { try cancellation?.check(); try Task.checkCancellation(); try sourceAuthority?() }
    func samplingImage() throws -> CIImage {
      let build = { try DevelopmentRendererV3.develop(capture,recipe:sampling,applyGeometry:false,context:context,
        preparingNaturalCurvePicker:natural,analysisOwnsLegacyValidationContext:ownLegacy,analysisResidentInput:residentInput,
        checkCancellation:{ try cancellation?.check(); try residentInput?.requireCurrent() }).image }
      if let images { return try images.image(for:key,validate:stillCurrent,build:build) }
      return try build()
    }
    let binding = DevelopmentAnalysisBinding(sourceContentID:sourceBinding.sourceContentID,sourceGeneration:request.preview.sourceGeneration,expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:request.stage)
    let mapping = try (request.preview.recipe.adjustmentsV3?.geometry ?? .init(version:request.preview.recipe.schemaVersion == 2 ? .legacyV2:.legacyV1,straightenDegrees:request.preview.recipe.straightenDegrees,crop:request.preview.recipe.crop)).mapping(sourceSize:sourceBinding.sourceSize)
    let value: DevelopmentAnalysisValue
    var localReceipt: DevelopmentLocalPixelAttestation?
    if case .cropAutomatic = request.operation {
      guard let input = request.cropAutoInputV1 else { throw DevelopmentPreviewError.invalidRequest }
      let graph = try DevelopmentRendererV3.develop(capture,recipe:sampling,applyGeometry:false,context:context,checkCancellation:{ try cancellation?.check() })
      value = .geometry(try DevelopmentCropAutoV1.resolve(image:graph.image,request:request,source:sourceBinding,input:input,context:context,checkCancellation:{ try cancellation?.check() }))
    } else if case .prepareDehaze=request.operation {
      guard let actual=dehazeContext,actual.source==sourceBinding else { throw DevelopmentDehazePreparationError.missingContext }
      value = .dehaze(try DevelopmentDehazeAnalysisV3.prepare(capture:capture,request:request,current:actual,context:context,cancellation:cancellation))
    } else if request.operation.localTool != nil {
      guard let decoder = localDecoderContractFingerprint else { throw DevelopmentLocalPreparationError.invalidInput }
      let local = try DevelopmentLocalAnalysisV3.prepare(capture:capture,request:request,sourceBinding:sourceBinding,decoderContractFingerprint:decoder,context:context,cancellation:cancellation)
      value = .local(local.0); localReceipt = local.1
    } else if case .whiteBalancePicker = request.operation {
      value = .resolved(try whiteBalanceCommand(capture:capture,request:request,binding:binding,sourceBinding:sourceBinding,context:context,samplingImage:samplingImage))
    } else if case .whiteBalanceAutomatic = request.operation {
      value = .resolved(try whiteBalanceCommand(capture:capture,request:request,binding:binding,sourceBinding:sourceBinding,context:context,samplingImage:samplingImage))
    } else if case let .selectiveColorPicker(slot,position) = request.operation {
      let c = try samplePixel(samplingImage(),position:position,context:context)
      var p = request.preview.recipe.adjustmentsV3!.selectiveColor
      for required in DevelopmentSelectiveColorSlotV3.allCases where !p.colors.contains(where: { $0.slot == required }) {
        p.colors.append(.init(slot: required))
      }
      guard let index = p.colors.firstIndex(where: { $0.slot == slot }) else { throw DevelopmentPreviewError.invalidRequest }
      p.enabled = true; p.colors[index].sampledColor = .init(red:c.x,green:c.y,blue:c.z)
      value = .resolved(.init(binding:binding,purpose:.selectiveColorPicker,parameters:[.selectiveColor(p)]))
    } else if case let .pointColorPicker(id,position) = request.operation {
      let c=try samplePixel(samplingImage(),position:position,context:context)
      var p=request.preview.recipe.adjustmentsV3!.selectiveColor
      var samples=p.pointColors ?? []
      if !samples.contains(where:{$0.id==id}) {
        guard samples.count<8 else{throw DevelopmentPreviewError.invalidRequest}
        samples.append(.init(id:id,sampledColor:.init(red:c.x,green:c.y,blue:c.z)))
      }
      p.pointColors=samples;p.enabled=true;try p.validate()
      value = .resolved(.init(binding:binding,purpose:.pointColorPicker,parameters:[.selectiveColor(p)]))
    } else if case let .defringePicker(band,position) = request.operation {
      let c=try samplePixel(samplingImage(),position:position,context:context)
      let encoded=SIMD3<Double>(DevelopmentColorEngineV2.encode(c.x),DevelopmentColorEngineV2.encode(c.y),DevelopmentColorEngineV2.encode(c.z))
      let center=DevelopmentGlobalEngineV3.hue(encoded)*360,lower=max(0,center-30),upper=min(360,center+30)
      var optics=request.preview.recipe.adjustmentsV3!.optics ?? .init()
      optics.defringe.enabled=true
      switch band {
      case .purple:
        optics.defringe.purpleHueLower=lower;optics.defringe.purpleHueUpper=upper
        if optics.defringe.purpleAmount==0{optics.defringe.purpleAmount=60}
      case .green:
        optics.defringe.greenHueLower=lower;optics.defringe.greenHueUpper=upper
        if optics.defringe.greenAmount==0{optics.defringe.greenAmount=60}
      }
      try optics.validate()
      value = .resolved(.init(binding:binding,purpose:.defringePicker,parameters:[.optics(optics)]))
    } else if case let .curvePicker(channel,point,position) = request.operation {
      if DevelopmentNaturalCurvePickerV1.isNatural(request) {
        let pixel = try DevelopmentNaturalCurvePickerV1.sample(samplingImage(),position:position,context:context,checkCancellation:{ try cancellation?.check() })
        value = .resolved(try DevelopmentNaturalCurvePickerV1.command(curves:request.preview.recipe.adjustmentsV3!.curves,
          pixel:pixel,channel:channel,point:point,binding:binding))
      } else {
      let color = try samplePixel(samplingImage(),position:position,context:context)
      value = .resolved(try curveCommand(request:request,binding:binding,channel:channel,point:point,sample:color))
      }
    } else {
      let scalars: DevelopmentAnalysisScalars
      if let entry = cache, entry.matches(recipeFingerprint:fingerprint,stage:request.stage,roi:request.roi,filterResourceIdentity:filterIdentity,samplingVersion:effectiveVersion,residentIdentity:residentInput?.identity) {
        try residentInput?.willPublish(cacheHit: true); scalars = entry.scalars
      }
      else if let previous = images?.scalars(for:key,roi:request.roi) { try stillCurrent(); scalars = previous }
      else {
        scalars = try analyzePixels(samplingImage(),roi:request.roi,context:context,sampling:request.sampling,cancellation:cancellation)
        let entry = DevelopmentAnalysisCacheEntry(recipeFingerprint:fingerprint,stage:request.stage,roi:request.roi,
          scalars:scalars,filterResourceIdentity:filterIdentity,samplingVersion:effectiveVersion,residentIdentity:residentInput?.identity)
        try residentInput?.willPublish(cacheHit: false)
        if request.sampling.usesBlackAndWhiteStripes {
          try Task.checkCancellation()
          if let cancellation { try cancellation.withInputPublication(allowFrameSuperseded: false) { cache = entry } }
          else { cache = entry }
        } else {
          try stillCurrent(); cache = entry
          if let imageEpoch { images?.remember(scalars,for:key,roi:request.roi,expectedEpoch:imageEpoch) }
        }
      }
      if request.operation.isHistogram { value = .histogram(scalars.histogram) }
      else {
        guard scalars.histogram.visibleSamples > 0 else { throw DevelopmentAnalysisError.noVisibleSamples }
        let defaults: DevelopmentRAWNoiseReductionDefaultsV3?
        let needsNoise = images == nil ? requestsRAWNoiseDefaults(request.operation) : request.operation == .automatic(.noiseReduction)
        if isRAW && needsNoise { guard let filter = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }; defaults = DevelopmentRendererV3.noiseDefaults(filter) }
        else { defaults = nil }
        value = .resolved(try resolve(request:request,binding:binding,scalars:scalars,rawDefaults:defaults))
      }
    }
    if request.sampling.usesBlackAndWhiteStripes {
      try Task.checkCancellation();try cancellation?.check();try residentInput?.requireCurrent()
    }
    return .init(operationID:request.operationID,sessionID:request.preview.sessionID,consumerID:request.preview.consumerID,revision:request.preview.revision,role:request.preview.role,quality:request.preview.quality,actualRecipe:request.preview.recipe,clientCorrelation:request.preview.clientCorrelation,binding:binding,sourceBinding:sourceBinding,presentedRecipeFingerprint:request.presentedRecipeFingerprint,roi:request.roi,
      samplingRecipeFingerprint:fingerprint,samplingVersion:effectiveVersion,geometryMapping:mapping,value:value,localPixelAttestation:localReceipt)
  }
  static func validatedSamplingVersion(_ request:DevelopmentAnalysisRequest)throws->String {
    try request.validateSamplingChoice()
    guard includesFilterIdentity(request.operation) else { return resultSamplingVersion(request) }
    let identity=try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(samplingRecipe(request))
    return resultSamplingVersion(request, filterIdentity: identity)
  }
  private static func includesFilterIdentity(_ operation: DevelopmentAnalysisOperation) -> Bool {
    // These branches have their own source/prefix/decoder attestations and exact version contracts.
    switch operation {
    case .cropAutomatic, .redEyeAutomatic, .prepareDehaze: return false
    default: return true
    }
  }
  private static func resultSamplingVersion(_ request: DevelopmentAnalysisRequest, filterIdentity: String?) -> String {
    let version=resultSamplingVersion(request)
    guard includesFilterIdentity(request.operation), let filterIdentity else { return version }
    return version+"/photo-filter:"+filterIdentity
  }
  static func resultSamplingVersion(_ request:DevelopmentAnalysisRequest)->String {
    if request.sampling == .blackAndWhiteSummaryResident32V3 { return DevelopmentBWSummaryResidentV3.version }
    if request.sampling == .blackAndWhiteSummaryStripes32V2 { return blackAndWhiteStripesVersion }
    if DevelopmentNaturalCurvePickerV1.isNatural(request) { return DevelopmentNaturalCurvePickerV1.samplingVersion }
    if let id = request.operation.scopeMaskID { return DevelopmentDisplayHistogramEngineV1.version + "/mask:" + id.uuidString }
    if request.operation.isDisplayHistogram { return DevelopmentDisplayHistogramEngineV1.version }
    if case .cropAutomatic=request.operation { return DevelopmentCropAutoV1.version }
    if case .redEyeAutomatic=request.operation { return DevelopmentRedEyeAutomaticV3.version }
    if case .prepareDehaze=request.operation { return DevelopmentDehazeAnalysisV3.resultVersion(request) }
    return samplingVersion
  }
  static func samplingSupportRecipe(_ request:DevelopmentAnalysisRequest)throws->DevelopmentRecipe {
    if case .cropAutomatic=request.operation { return try samplingRecipe(request) }
    if case .prepareDehaze=request.operation { return try DevelopmentDehazeAnalysisV3.projection(request).samplingRecipe }
    return request.preview.recipe
  }
  private static func analyzePixels(_ image: CIImage, roi: NormalizedCrop, context: CIContext,
                                    sampling: DevelopmentAnalysisSampling, cancellation: DevelopmentAnalysisCancellation?) throws -> DevelopmentAnalysisScalars {
    let e = image.extent, rect = CGRect(x:e.minX+e.width*roi.x,y:e.minY+e.height*(1-roi.y-roi.height),width:e.width*roi.width,height:e.height*roi.height)
    let factor = min(1,Double(maximumProxyDimension)/max(rect.width,rect.height))
    let width = max(1,Int(floor(rect.width*factor))), height = max(1,Int(floor(rect.height*factor)))
    let proxy = image.cropped(to:rect).transformed(by:.init(translationX:-rect.minX,y:-rect.minY)).transformed(by:.init(scaleX:Double(width)/rect.width,y:Double(height)/rect.height))
    let stripes = sampling.usesBlackAndWhiteStripes
    var pixels = [Float](repeating:stripes ? .nan:0,count:width*height*4)
    if stripes {
      try renderBlackAndWhiteProxyStripes(proxy, width: width, height: height, context: context, pixels: &pixels) {
        try Task.checkCancellation();try cancellation?.check()
      }
      try Task.checkCancellation();try cancellation?.check()
    } else {
      context.render(proxy,toBitmap:&pixels,rowBytes:width*16,bounds:.init(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    }
    return try statistics(pixels,width:width,height:height)
  }
  static func renderBlackAndWhiteProxyStripes(_ proxy: CIImage, width: Int, height: Int, context: CIContext,
                                              pixels: inout [Float], check: () throws -> Void) throws {
    guard (1...maximumProxyDimension).contains(width), (1...maximumProxyDimension).contains(height),
      pixels.count == width*height*4 else { throw DevelopmentV3Error.invalidGraph }
    let rowBytes = width*16
    try pixels.withUnsafeMutableBytes { storage in
      guard let address = storage.baseAddress else { throw DevelopmentV3Error.invalidGraph }
      for y in stride(from: 0, to: height, by: 32) {
        let count = min(32,height-y)
        // CI bounds stay in the global proxy grid. The bitmap starts at the band's upper-left.
        let topRow = height-y-count
        try check()
        autoreleasepool {
          context.render(proxy,toBitmap:address.advanced(by:topRow*rowBytes),rowBytes:rowBytes,
                         bounds:.init(x:0,y:y,width:width,height:count),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
          // render(toBitmap:) is synchronous. Clear only after the borrowed storage is no longer in use by CI.
          context.clearCaches()
        }
        try check()
      }
    }
  }
  static func statistics(_ pixels: [Float], width: Int, height: Int) throws -> DevelopmentAnalysisScalars {
    guard width > 0, height > 0, width <= maximumProxyDimension, height <= maximumProxyDimension, pixels.count == width*height*4 else { throw DevelopmentV3Error.invalidGraph }
    var bins = Array(repeating:[UInt64](repeating:0,count:256),count:4), visible = 0, transparent = 0
    var mean = SIMD3<Double>(repeating:0), saturation: Double = 0
    func bin(_ value: Double) -> Int { Int((min(1,max(0,value))*255).rounded(.down)) }
    for i in 0..<(width*height) {
      let n = i*4, alpha = Double(pixels[n+3])
      guard (0..<4).allSatisfy({ pixels[n+$0].isFinite }) else { throw DevelopmentError.invalidEncoding }
      if alpha <= 0 { transparent += 1; continue }
      let c = SIMD3(Double(pixels[n]),Double(pixels[n+1]),Double(pixels[n+2]))/alpha
      let encoded = SIMD3(DevelopmentColorEngineV2.encode(c.x),DevelopmentColorEngineV2.encode(c.y),DevelopmentColorEngineV2.encode(c.z))
      let y = DevelopmentColorEngineV2.encode(DevelopmentColorEngineV2.luma(c)), top = max(encoded.x,max(encoded.y,encoded.z)), bottom = min(encoded.x,min(encoded.y,encoded.z))
      bins[0][bin(encoded.x)] += 1; bins[1][bin(encoded.y)] += 1; bins[2][bin(encoded.z)] += 1; bins[3][bin(y)] += 1
      mean += c; saturation += min(1,max(0,(top-bottom)/max(abs(top),1e-4))); visible += 1
    }
    if visible > 0 { mean /= Double(visible); saturation /= Double(visible) }
    var result = DevelopmentAnalysisScalars(histogram:.init(red:bins[0],green:bins[1],blue:bins[2],luminance:bins[3],visibleSamples:visible,transparentSamples:transparent,sampledSize:.init(width:width,height:height)),meanLinearRGB:mean,meanSaturation:saturation)
    var noise: [Double] = [], edges = 0.0, edgeCount = 0, center = 0.0, corners = 0.0, nc = 0, nk = 0
    func luminance(_ x: Int,_ y: Int) -> Double {
      let i = (y*width+x)*4, a = Double(pixels[i+3]); if a <= 0 { return 0 }
      return DevelopmentColorEngineV2.luma(.init(Double(pixels[i]),Double(pixels[i+1]),Double(pixels[i+2]))/a)
    }
    if width > 2, height > 2 { for y in 1..<(height-1) { for x in 1..<(width-1) {
      if [(x,y),(x-1,y),(x+1,y),(x,y-1),(x,y+1)].contains(where: { pixels[($0.1*width+$0.0)*4+3] <= 0 }) { continue }
      let c = luminance(x,y), l = luminance(x-1,y), r = luminance(x+1,y), t = luminance(x,y-1), b = luminance(x,y+1)
      let edge = (abs(r-l)+abs(b-t))/max(0.01,abs(c)*2); edges += min(1,edge); edgeCount += 1
      if edge < 0.15 { noise.append(abs(c-(l+r+t+b)/4)) }
      let dx = abs(Double(x)/Double(width)-0.5), dy = abs(Double(y)/Double(height)-0.5)
      if dx < 0.2, dy < 0.2 { center += c; nc += 1 }
      if dx > 0.35, dy > 0.35 { corners += c; nk += 1 }
    } } }
    noise.sort(); result.noiseEstimate = noise.isEmpty ? 0:noise[noise.count/2]*1.4826
    result.edgeEnergy = edgeCount == 0 ? 0:edges/Double(edgeCount)
    result.cornerFalloff = nc > 0 && nk > 0 ? max(-1,min(1,(center/Double(nc)-corners/Double(nk))/max(0.01,center/Double(nc)))):0
    return result
  }
  private static func samplePixel(_ image: CIImage, position: DevelopmentSourcePoint, context: CIContext) throws -> SIMD3<Double> {
    let p = try samplePixelRGBA(image,position:position,context:context)
    return SIMD3(p.x,p.y,p.z)/p.w
  }
  private static func samplePixelRGBA(_ image: CIImage, position: DevelopmentSourcePoint, context: CIContext) throws -> SIMD4<Double> {
    try position.validate(); let e = image.extent
    let x = min(e.maxX-1,max(e.minX,e.minX+floor(position.x*e.width))), y = min(e.maxY-1,max(e.minY,e.minY+floor((1-position.y)*e.height)))
    var p = [Float](repeating:0,count:4); context.render(image,toBitmap:&p,rowBytes:16,bounds:.init(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    guard p.allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding }; guard p[3] > 0 else { throw DevelopmentAnalysisError.noVisibleSamples }
    return SIMD4(Double(p[0]),Double(p[1]),Double(p[2]),Double(p[3]))
  }
  private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high,max(low,value)) }
  static func resolvedSummary(_ group: DevelopmentAdjustmentID, amount: Double, scalars s: DevelopmentAnalysisScalars) throws -> DevelopmentAdjustmentParametersV3 {
    guard amount.isFinite, (-1...1).contains(amount), s.histogram.visibleSamples > 0 else { throw DevelopmentPreviewError.invalidRequest }
    let low = s.percentile(0.05), mid = s.percentile(0.5), high = s.percentile(0.95), white = s.percentile(0.99), spread = high-low
    switch group {
    case .light:
      let exposure = clamp(0.5*log2(0.77/max(0.02,DevelopmentColorEngineV2.decode(white))),-0.5,0.5)
      return .light(.init(enabled:true,brilliance:amount*clamp(0.33+0.65*spread,0,1.3),brillianceVersion:.adaptiveLocalV1,exposure:amount*exposure,
        highlights:-amount*clamp((high-0.49)*2,0,1),shadows:amount*clamp((0.55-mid)*3,0,1),
        brightness:amount*clamp((0.7-mid)*1.5,-1,1),contrast:amount*clamp(spread-0.3225,-0.5,0.8),blackPoint:amount*clamp(low*1.25,0,0.5)))
    case .color:
      let grayCast = clamp((s.meanLinearRGB.z-s.meanLinearRGB.x)/max(0.02,s.meanLinearRGB.z+s.meanLinearRGB.x),-0.4,0.4)
      return .color(.init(enabled:true,saturation:amount*(0.35+0.4*(1-s.meanSaturation)),vibrance:amount*(0.4+0.6*(1-s.meanSaturation)),cast:amount*grayCast))
    case .blackAndWhite:
      return .blackAndWhite(.init(enabled:true,intensity:clamp(0.5+amount*(0.25+0.25*s.meanSaturation),0,1),
        neutrals:clamp(amount*(0.5-mid)*1.2,-1,1),tone:clamp(amount*(0.25+0.5*spread),-1,1),grain:0))
    default: throw DevelopmentV3Error.unsupportedAnalysis
    }
  }
  private static func resolve(request: DevelopmentAnalysisRequest, binding: DevelopmentAnalysisBinding, scalars: DevelopmentAnalysisScalars, rawDefaults: DevelopmentRAWNoiseReductionDefaultsV3?) throws -> DevelopmentResolvedAdjustmentCommand {
    let purpose: DevelopmentAnalysisPurpose, values: [DevelopmentAdjustmentParametersV3]
    switch request.operation {
    case let .summary(group,amount): purpose = .summary(group,amount:amount); values = [try resolvedSummary(group,amount:amount,scalars:scalars)]
    case .automaticLight(let field):
      purpose = .automatic(.light)
      guard case .light(let automatic)=try resolvedSummary(.light,amount:0.8,scalars:scalars)else{throw DevelopmentV3Error.unsupportedAnalysis}
      var current=request.preview.recipe.adjustmentsV3!.light;current.enabled=true
      switch field {
      case .brilliance:current.brilliance=automatic.brilliance;current.brillianceVersion=automatic.brillianceVersion
      case .exposure:current.exposure=automatic.exposure; case .highlights:current.highlights=automatic.highlights
      case .shadows:current.shadows=automatic.shadows; case .whites:current.whites=automatic.whites
      case .blackPoint:current.blackPoint=automatic.blackPoint; case .brightness:current.brightness=automatic.brightness
      case .contrast:current.contrast=automatic.contrast
      }
      values=[.light(current)]
    case .automatic(let group):
      purpose = .automatic(group)
      if let group, group == .curves || group == .levels {
        var low = scalars.percentile(0.01), high = scalars.percentile(0.99)
        if high-low < 0.01 { let mid = scalars.percentile(0.5); low = max(0,mid-0.05); high = min(1,mid+0.05) }
        if group == .curves { var curves = DevelopmentCurvesV3(enabled:true); curves.rgb.inputBlack = low; curves.rgb.inputWhite = high; values = [.curves(curves)] }
        else {
          let mid = clamp(scalars.percentile(0.5),low,high)
          let handles = DevelopmentLevelsHandlesV3(black:low,shadows:clamp(scalars.percentile(0.25),low,mid),midtones:mid,
            highlights:clamp(scalars.percentile(0.75),mid,high),white:high,outputBlack:0,outputWhite:1)
          values = [.levels(.init(enabled:true,luminance:.manual(handles)))]
        }
      } else if let group {
        switch group {
        case .definition:values = [.definition(.init(enabled:true,amount:clamp(1.2-2*scalars.edgeEnergy,0,2)))]
        case .sharpen:values = [.sharpen(.init(enabled:true,intensity:clamp(0.6-2*scalars.noiseEstimate,0,1),edges:clamp(0.15+scalars.edgeEnergy,0,1),falloff:0.69))]
        case .vignette:values = [.vignette(.init(enabled:true,strength:-clamp(scalars.cornerFalloff*0.5,0,1),radius:0.5,softness:0.5))]
        case .noiseReduction:
          if let d = rawDefaults {
            values = [.noiseReduction(.init(enabled:true,sourceCapability:.raw,
              luminanceNoise:d.luminanceSupported ? clamp(scalars.noiseEstimate*12,0,1):0,
              colorNoise:d.colorSupported ? clamp(scalars.noiseEstimate*8,0,1):0,
              detail:d.detailSupported ? clamp(1-scalars.edgeEnergy,0,3):0))]
          } else { values = [.noiseReduction(.init(enabled:true,sourceCapability:.image,nonRawAmount:clamp(scalars.noiseEstimate*100,0,5)))] }
        default:values = [try resolvedSummary(group,amount:0.8,scalars:scalars)]
        }
      }
      else { values = [try resolvedSummary(.light,amount:0.8,scalars:scalars),try resolvedSummary(.color,amount:0.8,scalars:scalars)] }
    default: throw DevelopmentV3Error.unsupportedAnalysis
    }
    return .init(binding:binding,purpose:purpose,parameters:values)
  }
  private static func whiteBalanceCommand(capture: URL, request: DevelopmentAnalysisRequest, binding: DevelopmentAnalysisBinding,
                                         sourceBinding: DevelopmentLocalEditSourceBinding, context: CIContext, samplingImage: () throws -> CIImage) throws -> DevelopmentResolvedAdjustmentCommand {
    let isRAW = PhotoRenderer.rawExtensions.contains(capture.pathExtension.lowercased())
    let raw = isRAW ? CIRAWFilter(imageURL:capture):nil
    if isRAW, raw == nil { throw DevelopmentError.unreadable }
    let original: DevelopmentAsShotWhiteBalance? = raw.map { .init(temperature:$0.neutralTemperature,tint:$0.neutralTint) }
    var state = try request.preview.recipe.adjustmentsV3!.whiteBalance.resolvedState ?? DevelopmentWhiteBalanceEngineV3.initialState(source:sourceBinding,rawDefault:original)
    try state.validate(expectedSource:sourceBinding)
    let mode: DevelopmentWhiteBalanceModeV3, position: DevelopmentSourcePoint, warmth: Double, purpose: DevelopmentAnalysisPurpose
    var sampled: SIMD3<Double>?
    var originalImage: CIImage?
    switch request.operation {
    case let .whiteBalancePicker(point,adjustment):
      position = point; purpose = .whiteBalancePicker
      switch adjustment { case .neutralGray(let w):mode = .neutralGray; warmth = w; case .skinTone(let w):mode = .skinTone; warmth = w
      default:throw DevelopmentPreviewError.invalidRequest }
    case .whiteBalanceAutomatic(let requested):
      let image = try samplingImage()
      originalImage = image
      let chosen = try automaticWBPosition(image,roi:request.roi,mode:requested,context:context)
      mode = requested; position = chosen.0; sampled = chosen.1; warmth = 0; purpose = .automatic(.whiteBalance)
    default:throw DevelopmentPreviewError.invalidRequest
    }
    var skinSample: DevelopmentSampledColorV3?, sampleAlpha = 1.0
    if mode == .skinTone {
      if originalImage == nil { originalImage = try samplingImage() }
      // Proxy selection is only a candidate. Re-read the actual source location and run exactly
      // the same versioned sample domain as manual picking before any native WB setter.
      let pixel = try samplePixelRGBA(originalImage!,position:position,context:context)
      let c = SIMD3(pixel.x,pixel.y,pixel.z)/pixel.w
      let s = DevelopmentSampledColorV3(red:c.x,green:c.y,blue:c.z)
      do { try DevelopmentSkinToneLocusV3.validateSample(s,alpha:pixel.w) }
      catch { throw DevelopmentAnalysisError.noVisibleSamples }
      skinSample = s; sampleAlpha = pixel.w; sampled = c
    }
    if let raw {
      // Public neutralLocation is in the unrotated native image's bottom-left pixel coordinates.
      // The caller's point is oriented/source-top-left and removes EXIF exactly once here.
      let point = try position.removingEXIFOrientation(sourceBinding.exifOrientation), size = raw.nativeSize
      let location = CGPoint(x:min(size.width-0.5,max(0.5,point.x*size.width)),y:min(size.height-0.5,max(0.5,(1-point.y)*size.height)))
      let tt: DevelopmentNativeWhiteBalanceV3
      if mode == .skinTone {
        do {
          tt = try DevelopmentSkinToneLocusV3.resolvingNativeTarget(sample:skinSample!,alpha:sampleAlpha,estimateGray:{
            raw.neutralLocation = location
            let xy = raw.neutralChromaticity; return .init(x:Double(xy.x),y:Double(xy.y))
          },assignSkin:{ xy in
            raw.neutralChromaticity = CGPoint(x:xy.x,y:xy.y)
            let actual = raw.neutralChromaticity
            guard Float(actual.x).bitPattern == Float(xy.x).bitPattern, Float(actual.y).bitPattern == Float(xy.y).bitPattern else { throw DevelopmentV3Error.unsupportedNativeParameters }
            // TT is the sole persisted native target; no claim that this conversion is lossless xy.
            return .init(temperature:raw.neutralTemperature,tint:raw.neutralTint)
          })
        } catch { throw DevelopmentAnalysisError.noVisibleSamples }
      } else {
        raw.neutralLocation = location
        tt = .init(temperature:raw.neutralTemperature,tint:raw.neutralTint)
      }
      try tt.validate()
      guard case .raw(let source,var s) = state else { throw EditingError.invalidRecipe }
      s.selectedMode = mode
      if mode == .temperatureTint { s.temperatureTint = tt }
      else if mode == .neutralGray { s.gray = .init(baseline:tt,warmth:warmth) }
      else { s.skin = .init(baseline:tt,warmth:warmth) }
      state = .raw(source:source,state:s)
    } else {
      if sampled == nil {
        sampled = try samplePixel(samplingImage(),position:position,context:context)
      }
      let rgb = sampled!, sample = DevelopmentSampledColorV3(red:rgb.x,green:rgb.y,blue:rgb.z)
      guard case .image(let source,var s) = state else { throw EditingError.invalidRecipe }
      s.selectedMode = mode
      if mode == .temperatureTint {
        guard rgb.x > 1e-6, rgb.z > 1e-6 else { throw DevelopmentAnalysisError.noVisibleSamples }
        s.temperatureOffset = min(100, max(-100, 50 * log2(rgb.z / rgb.x)))
        let temperature = DevelopmentImageWhiteBalanceStateV3.approximateTemperature(forOffset: s.temperatureOffset)
        let tint = Float(-100*(rgb.y-(rgb.x+rgb.z)/2)/max(1e-6,rgb.x+rgb.y+rgb.z))
        s.temperatureTint = .init(temperature:temperature,tint:tint)
      } else {
        var pick = try mode == .skinTone ? DevelopmentImageWhiteBalancePickV3.skinTone(sampledLinearRGB:sample):DevelopmentImageWhiteBalancePickV3.neutralGray(sampledLinearRGB:sample)
        pick.warmth = warmth
        if mode == .neutralGray { s.gray = pick } else { s.skin = pick }
      }
      state = .image(source:source,state:s)
    }
    try state.validate(expectedSource:sourceBinding)
    return .init(binding:binding,purpose:purpose,parameters:[.whiteBalance(.init(enabled:true,resolvedState:state))])
  }
  private static func automaticWBPosition(_ image: CIImage, roi: NormalizedCrop, mode: DevelopmentWhiteBalanceModeV3,
                                          context: CIContext) throws -> (DevelopmentSourcePoint,SIMD3<Double>) {
    let e = image.extent, rect = CGRect(x:e.minX+e.width*roi.x,y:e.minY+e.height*(1-roi.y-roi.height),width:e.width*roi.width,height:e.height*roi.height)
    let f = min(1,Double(maximumProxyDimension)/max(rect.width,rect.height))
    let width = max(1,Int(floor(rect.width*f))), height = max(1,Int(floor(rect.height*f)))
    let proxy = image.cropped(to:rect).transformed(by:.init(translationX:-rect.minX,y:-rect.minY)).transformed(by:.init(scaleX:Double(width)/rect.width,y:Double(height)/rect.height))
    var pixels = [Float](repeating:0,count:width*height*4)
    context.render(proxy,toBitmap:&pixels,rowBytes:width*16,bounds:.init(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    var best: (Double,Int,SIMD3<Double>)?
    for i in 0..<(width*height) {
      let n = i*4, alpha = Double(pixels[n+3]); guard (0..<4).allSatisfy({ pixels[n+$0].isFinite }) else { throw DevelopmentError.invalidEncoding }
      if alpha <= 0 { continue }
      let c = SIMD3(Double(pixels[n]),Double(pixels[n+1]),Double(pixels[n+2]))/alpha
      let top = max(c.x,max(c.y,c.z)), bottom = min(c.x,min(c.y,c.z)), y = DevelopmentColorEngineV2.luma(c)
      let sat = (top-bottom)/max(top,1e-6), encoded = SIMD3(DevelopmentColorEngineV2.encode(c.x),DevelopmentColorEngineV2.encode(c.y),DevelopmentColorEngineV2.encode(c.z))
      var score = sat*sat+0.1*abs(DevelopmentColorEngineV2.encode(y)-0.5)
      if mode == .skinTone {
        if (try? DevelopmentSkinToneLocusV3.validateSample(.init(red:c.x,green:c.y,blue:c.z),alpha:alpha)) == nil { continue }
        let hue = DevelopmentGlobalEngineV3.hue(encoded)
        let hi = max(encoded.x,max(encoded.y,encoded.z)), lo = min(encoded.x,min(encoded.y,encoded.z)), encodedSat = (hi-lo)/hi
        score = 4*abs(hue-0.08)+abs(encodedSat-0.4)+0.1*abs(DevelopmentColorEngineV2.encode(y)-0.5)
      } else if bottom <= 0.002 || top >= 0.95 || y < 0.02 { continue }
      if best == nil || score < best!.0 { best = (score,i,c) }
    }
    guard let best else { throw DevelopmentAnalysisError.noVisibleSamples }
    let px = Double(best.1%width)+0.5, py = Double(best.1/width)+0.5
    return (.init(x:roi.x+px/Double(width)*roi.width,y:roi.y+(1-py/Double(height))*roi.height),best.2)
  }
  private static func curveCommand(request: DevelopmentAnalysisRequest, binding: DevelopmentAnalysisBinding, channel: DevelopmentCurveChannelV3ID,
                                   point: DevelopmentCurvePickerPointV3, sample: SIMD3<Double>) throws -> DevelopmentResolvedAdjustmentCommand {
    var curves = request.preview.recipe.adjustmentsV3!.curves
    let e = SIMD3(DevelopmentColorEngineV2.encode(sample.x),DevelopmentColorEngineV2.encode(sample.y),DevelopmentColorEngineV2.encode(sample.z))
    var value: Double
    switch channel { case .rgb: value = DevelopmentColorEngineV2.luma(e); case .red: value = e.x; case .green: value = e.y; case .blue: value = e.z }
    if channel != .rgb, (!curves.rgb.curve.isNeutral || curves.rgb.inputBlack != 0 || curves.rgb.inputWhite != 1) {
      value = try curves.rgb.curve.value(at:(value-curves.rgb.inputBlack)/(curves.rgb.inputWhite-curves.rgb.inputBlack))
    }
    guard value.isFinite, (0...1).contains(value) else { throw DevelopmentV3Error.unrepresentableParameters }
    var target: DevelopmentCurveChannelV3
    switch channel { case .rgb: target = curves.rgb; case .red: target = curves.red; case .green: target = curves.green; case .blue: target = curves.blue }
    switch point {
    case .black: guard value < target.inputWhite else { throw DevelopmentV3Error.unrepresentableParameters }; target.inputBlack = value
    case .white: guard value > target.inputBlack else { throw DevelopmentV3Error.unrepresentableParameters }; target.inputWhite = value
    case .midtone, .addPoint:
      let x = (value-target.inputBlack)/(target.inputWhite-target.inputBlack)
      guard x > 1e-4, x < 1-1e-4 else { throw DevelopmentV3Error.unrepresentableParameters }
      let y = point == .midtone ? 0.5:try target.curve.value(at:x)
      if let index = target.curve.points.indices.dropFirst().dropLast().first(where:{ abs(target.curve.points[$0].x-x) < 1e-4 }) { target.curve.points[index] = .init(x:x,y:y) }
      else { guard target.curve.points.count < 16 else { throw DevelopmentV3Error.unrepresentableParameters }; target.curve.points.append(.init(x:x,y:y)); target.curve.points.sort { $0.x < $1.x } }
    }
    try target.validate(); curves.enabled = true
    switch channel { case .rgb: curves.rgb = target; case .red: curves.red = target; case .green: curves.green = target; case .blue: curves.blue = target }
    return .init(binding:binding,purpose:.curvesPicker,parameters:[.curves(curves)])
  }
}
