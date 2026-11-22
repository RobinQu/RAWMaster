import Foundation

public enum DevelopmentAnalysisStage: String, Codable, Sendable { case orientedSourceBeforeGeometry, workingImageBeforeGeometry }
public struct DevelopmentAdjustmentCommandContext: Equatable, Sendable {
  public let source: DevelopmentLocalEditSourceBinding
  public let sourceGeneration: UInt64
  public let analysisStage: DevelopmentAnalysisStage
  public let sourceCapability: DevelopmentNoiseReductionSourceCapability?
  public let localInputV1: DevelopmentLocalInputV1?
  public let dehazeContextV1: DevelopmentDehazeContextV1?
  public let supportedGrainSamplingVersions: Set<DevelopmentGrainSamplingVersion>
  public init(source: DevelopmentLocalEditSourceBinding, sourceGeneration: UInt64, analysisStage: DevelopmentAnalysisStage, sourceCapability: DevelopmentNoiseReductionSourceCapability? = nil,
              localInputV1: DevelopmentLocalInputV1? = nil, dehazeContextV1: DevelopmentDehazeContextV1? = nil,
              supportedGrainSamplingVersions: Set<DevelopmentGrainSamplingVersion> = []) {
    self.source = source; self.sourceGeneration = sourceGeneration; self.analysisStage = analysisStage
    self.sourceCapability = sourceCapability
    self.localInputV1 = localInputV1
    self.dehazeContextV1 = dehazeContextV1
    self.supportedGrainSamplingVersions = supportedGrainSamplingVersions
  }
}
public struct DevelopmentAnalysisBinding: Equatable, Sendable {
  public let sourceContentID: String
  public let sourceGeneration: UInt64
  public let expectedRecipeFingerprint: String
  public let stage: DevelopmentAnalysisStage
  public init(sourceContentID: String, sourceGeneration: UInt64, expectedRecipeFingerprint: String, stage: DevelopmentAnalysisStage) {
    self.sourceContentID = sourceContentID; self.sourceGeneration = sourceGeneration; self.expectedRecipeFingerprint = expectedRecipeFingerprint; self.stage = stage
  }
}
public enum DevelopmentAdjustmentParametersV3: Equatable, Sendable {
  case light(DevelopmentLightV3), color(DevelopmentColorV3), blackAndWhite(DevelopmentBlackAndWhiteV3)
  case whiteBalance(DevelopmentWhiteBalanceV3), curves(DevelopmentCurvesV3), levels(DevelopmentLevelsV3)
  case definition(DevelopmentDefinitionV3), selectiveColor(DevelopmentSelectiveColorV3), noiseReduction(DevelopmentNoiseReductionV3)
  case sharpen(DevelopmentSharpenV3), vignette(DevelopmentVignetteV3), filter(DevelopmentFilterV3), optics(DevelopmentOpticsV3)
  case texture(DevelopmentDetailAmountV3), clarity(DevelopmentDetailAmountV3), dehaze(DevelopmentDetailAmountV3)
  public var id: DevelopmentAdjustmentID {
    switch self {
    case .light: return .light; case .color: return .color; case .blackAndWhite: return .blackAndWhite
    case .whiteBalance: return .whiteBalance; case .curves: return .curves; case .levels: return .levels
    case .definition: return .definition; case .selectiveColor: return .selectiveColor; case .noiseReduction: return .noiseReduction
    case .sharpen: return .sharpen; case .vignette: return .vignette; case .filter: return .filter; case .optics:return .optics
    case .texture:return .texture; case .clarity:return .clarity; case .dehaze:return .dehaze
    }
  }
}
public enum DevelopmentAnalysisPurpose: Equatable, Sendable {
  /// nil means one resolved global transaction; nonnil restricts the result to that one group.
  case automatic(DevelopmentAdjustmentID?)
  case whiteBalancePicker, curvesPicker, selectiveColorPicker, defringePicker, pointColorPicker
  case summary(DevelopmentAdjustmentID, amount: Double)
}
/// An ephemeral resolved command, not a persisted CIFilter or a request to run Auto during rendering.
public struct DevelopmentResolvedAdjustmentCommand: Equatable, Sendable {
  public let binding: DevelopmentAnalysisBinding
  public let purpose: DevelopmentAnalysisPurpose
  public let parameters: [DevelopmentAdjustmentParametersV3]
  public init(binding: DevelopmentAnalysisBinding, purpose: DevelopmentAnalysisPurpose, parameters: [DevelopmentAdjustmentParametersV3]) {
    self.binding = binding; self.purpose = purpose; self.parameters = parameters
  }
}
public enum DevelopmentAdjustmentCommand: Equatable, Sendable {
  case promoteToV3
  case setParameters(DevelopmentAdjustmentParametersV3)
  /// Explicit manual grain edit; nil retains the existing image/legacy interpretation.
  case setBlackAndWhiteGrain(amount: Double, sampling: DevelopmentGrainSamplingVersion?)
  case setEnabled(DevelopmentAdjustmentID, Bool)
  case reset(DevelopmentAdjustmentID)
  case resetAll
  case setLegacyBasis(DevelopmentLegacyBasis?)
  case setGeometry(DevelopmentGeometryV3)
  case setEffects(DevelopmentEffectsV3)
  case setGradingLUTs(DevelopmentLUTStack?)
  case setRawDetails(DevelopmentRawDetails?)
  case setAIDenoise(DevelopmentAIDenoiseV1?)
  case setMasks([DevelopmentMaskLayerV3])
  case appendLocal(DevelopmentLocalEdit)
  case appendResolvedLocalBatch(DevelopmentResolvedLocalBatch)
  case applyPreparedDehaze(DevelopmentResolvedDehazeV1, wantedAmount: Double)
  case removeLocal(UUID)
  case applyAnalysis(DevelopmentResolvedAdjustmentCommand)
}
public enum DevelopmentAdjustmentCommandError: Error, Equatable, Sendable { case requiresV3, missingSourceContext, staleAnalysis, mismatchedSource, invalidAnalysisResult, missingOperation, unsupportedGrainSampling }

extension DevelopmentAdjustmentsV3 {
  public mutating func setEnabled(_ enabled: Bool, for id: DevelopmentAdjustmentID) {
    switch id {
    case .light: light.enabled = enabled; case .color: color.enabled = enabled; case .blackAndWhite: blackAndWhite.enabled = enabled
    case .retouch: localEdits.retouchEnabled = enabled; case .redEye: localEdits.redEyeEnabled = enabled
    case .whiteBalance: whiteBalance.enabled = enabled; case .curves: curves.enabled = enabled; case .levels: levels.enabled = enabled
    case .definition: definition.enabled = enabled; case .selectiveColor: selectiveColor.enabled = enabled
    case .noiseReduction: noiseReduction.enabled = enabled; case .sharpen: sharpen.enabled = enabled
    case .vignette: vignette.enabled = enabled; case .filter: filter.enabled = enabled
    case .optics: var value=optics ?? .init();value.defringe.enabled=enabled;optics=value
    case .texture:advancedDetail.texture.enabled = enabled; case .clarity:advancedDetail.clarity.enabled = enabled; case .dehaze:advancedDetail.dehaze.enabled = enabled
    }
  }
  public func isEnabled(_ id: DevelopmentAdjustmentID) -> Bool {
    switch id {
    case .light: return light.enabled; case .color: return color.enabled; case .blackAndWhite: return blackAndWhite.enabled
    case .retouch: return localEdits.retouchEnabled; case .redEye: return localEdits.redEyeEnabled
    case .whiteBalance: return whiteBalance.enabled; case .curves: return curves.enabled; case .levels: return levels.enabled
    case .definition: return definition.enabled; case .selectiveColor: return selectiveColor.enabled
    case .noiseReduction: return noiseReduction.enabled; case .sharpen: return sharpen.enabled
    case .vignette: return vignette.enabled; case .filter: return filter.enabled; case .optics:return optics?.defringe.enabled == true
    case .texture:return advancedDetail.texture.enabled; case .clarity:return advancedDetail.clarity.enabled; case .dehaze:return advancedDetail.dehaze.enabled
    }
  }
  public mutating func reset(group id: DevelopmentAdjustmentID) {
    switch id {
    case .light: light = .init(); case .color: color = .init(); case .blackAndWhite: blackAndWhite = .init()
    case .whiteBalance: whiteBalance = .init(); case .curves: curves = .init(); case .levels: levels = .init()
    case .definition: definition = .init(); case .selectiveColor: selectiveColor = .init(); case .noiseReduction: noiseReduction = .init()
    case .sharpen: sharpen = .init(); case .vignette: vignette = .init(); case .filter: filter = .init(); case .optics:optics=nil
    case .texture:advancedDetail.texture = .init(); case .clarity:advancedDetail.clarity = .init(); case .dehaze:advancedDetail.dehaze = .init();advancedDetail.preparedDehaze=nil;advancedDetail.dehazeAlgorithmVersion=nil
    case .retouch, .redEye:
      let tool: DevelopmentLocalTool = id == .retouch ? .retouch : .redEye
      localEdits.operations.removeAll { $0.tool == tool }; setEnabled(false,for:id)
      if localEdits.operations.isEmpty { localEdits.sourceBinding = nil }
    }
  }
  mutating func set(_ value: DevelopmentAdjustmentParametersV3) {
    switch value {
    case .light(let p): light = p; case .color(let p): color = p; case .blackAndWhite(let p): blackAndWhite = p
    case .whiteBalance(let p): whiteBalance = p; case .curves(let p): curves = p; case .levels(let p): levels = p
    case .definition(let p): definition = p; case .selectiveColor(let p): selectiveColor = p; case .noiseReduction(let p): noiseReduction = p
    case .sharpen(let p): sharpen = p; case .vignette(let p): vignette = p; case .filter(let p): filter = p; case .optics(let p):optics = p
    case .texture(let p):advancedDetail.texture = p; case .clarity(let p):advancedDetail.clarity = p; case .dehaze(let p):advancedDetail.dehaze = p
    }
  }
}
extension DevelopmentRecipe {
  /// Pure, atomic value transaction. Controller owns undo coalescing and calls setRecipe once on success.
  /// Caller supplies the CURRENT admitted source generation and EXPECTED analysis stage; Core verifies
  /// those against the result and recomputes the actual recipe fingerprint itself. Renderer must attest
  /// which pixels/stage it sampled; Core cannot establish that from metadata.
  public func applying(_ command: DevelopmentAdjustmentCommand, context: DevelopmentAdjustmentCommandContext? = nil) throws -> DevelopmentRecipe {
    try validate()
    if case .promoteToV3 = command { return try finalizingDehazeV1(promotingToV3(),context:context) }
    if case .appendResolvedLocalBatch(let batch) = command { return try finalizingDehazeV1(applyingLocalBatchV1(batch,context:context),context:context) }
    if case let .applyPreparedDehaze(result,wantedAmount) = command { return try applyingPreparedDehazeV1(result,wantedAmount:wantedAmount,context:context) }
    guard schemaVersion == 3, var payload = adjustmentsV3 else { throw DevelopmentAdjustmentCommandError.requiresV3 }
    if let context {
      try context.source.validate()
      try payload.localEdits.validate(expectedSource:context.source)
    }
    switch command {
    case .promoteToV3: break
    case .applyPreparedDehaze: break // Handled before V3 guard.
    case .appendResolvedLocalBatch: break // Handled before V3 guard, including atomic legacy promotion.
    case .setParameters(let value): payload.set(value)
    case let .setBlackAndWhiteGrain(amount,sampling):
      try DevelopmentV3Validation.range([amount],0...1)
      if let sampling {
        guard let context, context.sourceGeneration > 0 else { throw DevelopmentAdjustmentCommandError.missingSourceContext }
        guard context.sourceCapability == .raw, context.supportedGrainSamplingVersions.contains(sampling),
          context.source.orientedWidth <= 50000, context.source.orientedHeight <= 50000 else {
          throw DevelopmentAdjustmentCommandError.unsupportedGrainSampling
        }
      }
      payload.blackAndWhite.grain = amount
      payload.blackAndWhite.grainSamplingVersion = amount == 0 ? nil:sampling
      payload.blackAndWhite.enabled = true // Preserve the existing manual scalar control behavior.
    case let .setEnabled(id,value): payload.setEnabled(value,for:id)
    case .reset(let id): payload.reset(group:id)
    case .resetAll: payload = payload.neutralForSameSource
    case .setLegacyBasis(let basis): payload.legacyBasis = basis
    case .setGeometry(let geometry): payload.geometry = geometry
    case .setEffects(let effects): payload.effects = effects
    case .setGradingLUTs(let stack): payload.gradingLUTs = stack
    case .setAIDenoise(let settings):
      if settings != nil, context?.sourceCapability == .image { throw EditingError.invalidRecipe }
      payload.aiDenoise = settings
    case .setRawDetails(let mode):
      if mode != nil, context?.sourceCapability == .image { throw EditingError.invalidRecipe }
      payload.rawDetails = mode
    case .setMasks(let masks):
      if masks.contains(where: { $0.semanticSnapshot != nil }) {
        guard let context else { throw DevelopmentAdjustmentCommandError.missingSourceContext }
        try DevelopmentMaskLayerV3.validateSource(masks, expected: context.source)
      }
      payload.masks = masks
    case .appendLocal(let operation):
      guard let context else { throw DevelopmentAdjustmentCommandError.missingSourceContext }
      guard operation.sourceContentID == context.source.sourceContentID else { throw DevelopmentAdjustmentCommandError.mismatchedSource }
      if let binding = payload.localEdits.sourceBinding, binding != context.source { throw DevelopmentAdjustmentCommandError.mismatchedSource }
      payload.localEdits.sourceBinding = context.source
      guard payload.localEdits.operations.count < DevelopmentLocalEditLimits.maximumOperations else { throw EditingError.invalidRecipe }
      payload.localEdits.operations.append(operation)
      payload.setEnabled(true,for:operation.tool == .retouch ? .retouch : .redEye)
    case .removeLocal(let id):
      guard let index = payload.localEdits.operations.firstIndex(where: { $0.id == id }) else { throw DevelopmentAdjustmentCommandError.missingOperation }
      payload.localEdits.operations.remove(at:index)
      if payload.localEdits.operations.isEmpty { payload.localEdits.sourceBinding = nil }
    case .applyAnalysis(let result):
      guard let context else { throw DevelopmentAdjustmentCommandError.missingSourceContext }
      let binding = result.binding
      guard EditingFingerprint.isSHA256(binding.sourceContentID), EditingFingerprint.isSHA256(binding.expectedRecipeFingerprint),
        binding.sourceContentID == context.source.sourceContentID, binding.sourceGeneration == context.sourceGeneration,
        binding.stage == context.analysisStage, binding.expectedRecipeFingerprint == (try EditingFingerprint.of(self)) else { throw DevelopmentAdjustmentCommandError.staleAnalysis }
      guard !result.parameters.isEmpty, result.parameters.count <= 6,
        Set(result.parameters.map(\.id)).count == result.parameters.count else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
      let ids = Set(result.parameters.map(\.id))
      switch result.purpose {
      case .automatic(let group):
        let supported: Set<DevelopmentAdjustmentID> = [.light,.color,.blackAndWhite,.whiteBalance,.curves,.levels]
        if let group {
          let explicit = supported.union([.definition,.noiseReduction,.sharpen,.vignette])
          guard explicit.contains(group), ids == [group] else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
        } else { guard ids.isSubset(of:supported) else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult } }
        for p in result.parameters {
          if case .noiseReduction(let nr) = p {
            guard let actual = context.sourceCapability else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
            try nr.validate(for:actual)
            guard nr.sourceCapability == actual else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
          }
        }
      case let .summary(group,amount):
        guard amount.isFinite, (-1...1).contains(amount), [.light,.color,.blackAndWhite].contains(group), ids == [group] else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
      case .whiteBalancePicker: guard ids == [.whiteBalance] else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
      case .curvesPicker: guard ids == [.curves] else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
      case .selectiveColorPicker: guard ids == [.selectiveColor] else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
      case .defringePicker: guard ids == [.optics] else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
      case .pointColorPicker: guard ids == [.selectiveColor] else { throw DevelopmentAdjustmentCommandError.invalidAnalysisResult }
      }
      for parameters in result.parameters { payload.set(parameters) }
    }
    if let resolved = payload.whiteBalance.resolvedState {
      guard let context, context.sourceCapability == resolved.sourceCapability else { throw DevelopmentAdjustmentCommandError.missingSourceContext }
      try resolved.validate(expectedSource:context.source)
    }
    var result = self; result.adjustmentsV3 = payload; try result.validate()
    let direct:Bool
    switch command {
    case .setParameters(.dehaze(_)),.setEnabled(.dehaze,true): direct=true
    default: direct=false
    }
    return try finalizingDehazeV1(result,context:context,directActivation:direct)
  }
}
