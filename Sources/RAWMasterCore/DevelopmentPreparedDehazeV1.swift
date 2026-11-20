import Foundation

/// Durable, closed version-1 estimate. These are linear-sRGB values rounded once to F32.
public struct DevelopmentDehazeAirlightV1: Codable, Equatable, Sendable {
  public var red, green, blue: Double
  public init(red:Double,green:Double,blue:Double) { self.red=red;self.green=green;self.blue=blue }
  public func validate() throws {
    guard [red,green,blue].allSatisfy({$0.isFinite && (1.0/65535.0...16).contains($0) && Double(Float($0)) == $0}) else { throw DevelopmentDehazePreparationError.invalidPreparation }
  }
  private enum CodingKeys:String,CodingKey { case red,green,blue }
  public init(from decoder:Decoder)throws {
    try RecipeCoding.requireKeys(decoder,["red","green","blue"]);let c=try decoder.container(keyedBy:CodingKeys.self)
    red=try c.decode(Double.self,forKey:.red);green=try c.decode(Double.self,forKey:.green);blue=try c.decode(Double.self,forKey:.blue);try validate()
  }
  public func encode(to encoder:Encoder)throws {
    try validate();var c=encoder.container(keyedBy:CodingKeys.self)
    try c.encode(red,forKey:.red);try c.encode(green,forKey:.green);try c.encode(blue,forKey:.blue)
  }
}
/// The encoded preparation keeps the existing integer algorithmVersion key.
public enum DevelopmentDehazeAlgorithm: Int, Equatable, Sendable {
  case v1 = 1
  case positiveColorGuideV2 = 2

  /// Initial v2 QA transport preserves the decoder's full, oriented native canvas.
  public static func supportsNativeV2Canvas(_ parameters:DevelopmentAdjustmentsV3)->Bool {
    let geometry=parameters.geometry
    return geometry.version != .projectiveV3_1 && geometry==DevelopmentGeometryV3(version:geometry.version) &&
      parameters.localEdits.operations.isEmpty
  }
}
public struct DevelopmentPreparedDehazeV1: Codable, Equatable, Sendable {
  public let version:Int
  public let sourceBinding:DevelopmentLocalEditSourceBinding
  public let inputStageVersion:Int
  public let inputFingerprint:String
  public let algorithmVersion:Int
  public let airlight:DevelopmentDehazeAirlightV1
  public init(sourceBinding:DevelopmentLocalEditSourceBinding,inputFingerprint:String,airlight:DevelopmentDehazeAirlightV1,
              version:Int=1,inputStageVersion:Int=1,algorithmVersion:Int=1) {
    self.sourceBinding=sourceBinding;self.inputFingerprint=inputFingerprint;self.airlight=airlight
    self.version=version;self.inputStageVersion=inputStageVersion;self.algorithmVersion=algorithmVersion
  }
  public func validate()throws {
    try sourceBinding.validate();try airlight.validate()
    guard version==1,inputStageVersion==1,DevelopmentDehazeAlgorithm(rawValue:algorithmVersion) != nil,EditingFingerprint.isSHA256(inputFingerprint) else { throw DevelopmentDehazePreparationError.invalidPreparation }
  }
  private enum CodingKeys:String,CodingKey { case version,sourceBinding,inputStageVersion,inputFingerprint,algorithmVersion,airlight }
  public init(from decoder:Decoder)throws {
    try RecipeCoding.requireKeys(decoder,["version","sourceBinding","inputStageVersion","inputFingerprint","algorithmVersion","airlight"])
    let c=try decoder.container(keyedBy:CodingKeys.self)
    version=try c.decode(Int.self,forKey:.version);sourceBinding=try c.decode(DevelopmentLocalEditSourceBinding.self,forKey:.sourceBinding)
    inputStageVersion=try c.decode(Int.self,forKey:.inputStageVersion);inputFingerprint=try c.decode(String.self,forKey:.inputFingerprint)
    algorithmVersion=try c.decode(Int.self,forKey:.algorithmVersion);airlight=try c.decode(DevelopmentDehazeAirlightV1.self,forKey:.airlight);try validate()
  }
  public func encode(to encoder:Encoder)throws {
    try validate();var c=encoder.container(keyedBy:CodingKeys.self)
    try c.encode(version,forKey:.version);try c.encode(sourceBinding,forKey:.sourceBinding);try c.encode(inputStageVersion,forKey:.inputStageVersion)
    try c.encode(inputFingerprint,forKey:.inputFingerprint);try c.encode(algorithmVersion,forKey:.algorithmVersion);try c.encode(airlight,forKey:.airlight)
  }
}
/// CURRENT admitted context only; deliberately not Codable. The pre-Dehaze decoder
/// contract excludes local/geometry stages and is not the B5 local decoder contract.
public struct DevelopmentDehazeContextV1: Equatable, Sendable {
  public let source:DevelopmentLocalEditSourceBinding
  public let sourceGeneration:UInt64
  public let decoderContractFingerprint:String
  public let stageVersion:Int
  public init(source:DevelopmentLocalEditSourceBinding,sourceGeneration:UInt64,decoderContractFingerprint:String,stageVersion:Int=1) {
    self.source=source;self.sourceGeneration=sourceGeneration;self.decoderContractFingerprint=decoderContractFingerprint;self.stageVersion=stageVersion
  }
  public func validate()throws {
    try source.validate()
    guard sourceGeneration>0,stageVersion==1,EditingFingerprint.isSHA256(decoderContractFingerprint) else { throw DevelopmentDehazePreparationError.invalidPreparation }
  }
}
public struct DevelopmentDehazeInputV1: Equatable, Sendable {
  public static let stageIdentifier="pre-dehaze-F32-I0-v1/after-global-texture-clarity/before-local-geometry/no-exact-legacy-delegate"
  public let context:DevelopmentDehazeContextV1
  public let algorithm:DevelopmentDehazeAlgorithm
  public let dependencyRecipeFingerprint:String
  public let inputFingerprint:String
}
public struct DevelopmentDehazeProjectionV1: Equatable, Sendable {
  public let analysisRecipe:DevelopmentRecipe
  public let samplingRecipe:DevelopmentRecipe
  public let expectedRecipeFingerprint:String
  public let presentedRecipeFingerprint:String
  public let input:DevelopmentDehazeInputV1
}
public enum DevelopmentDehazeNoResult:String,Sendable { case insufficientVisibleSamples,airlightOutsideDomain }
public enum DevelopmentDehazeResolutionV1:Equatable,Sendable {
  case prepared(DevelopmentPreparedDehazeV1),noResult(DevelopmentDehazeNoResult)
}
public struct DevelopmentResolvedDehazeV1:Equatable,Sendable {
  public let binding:DevelopmentAnalysisBinding
  public let presentedRecipeFingerprint:String
  public let input:DevelopmentDehazeInputV1
  public let resolution:DevelopmentDehazeResolutionV1
  public init(binding:DevelopmentAnalysisBinding,presentedRecipeFingerprint:String,input:DevelopmentDehazeInputV1,resolution:DevelopmentDehazeResolutionV1) {
    self.binding=binding;self.presentedRecipeFingerprint=presentedRecipeFingerprint;self.input=input;self.resolution=resolution
  }
}
public enum DevelopmentDehazePreparationStatusV1:Equatable,Sendable { case absent,ready,stale }
public enum DevelopmentDehazePreparationError:Error,Equatable,Sendable { case missingContext,staleInput,invalidPreparation,preparationRequired }

extension DevelopmentRecipe {
  /// Pure prefix projection; never renders, estimates, enables, or writes the draft.
  func dehazeSamplingRecipeV1()throws->DevelopmentRecipe {
    var p=try promotingToV3().adjustmentsV3!
    p.advancedDetail.dehaze = .init();p.advancedDetail.preparedDehaze=nil;p.advancedDetail.dehazeAlgorithmVersion=nil
    p.localEdits = .init();p.geometry = .init(version:.adjustV3)
    let recipe=DevelopmentRecipe(adjustmentsV3:p);try recipe.validate();return recipe
  }
  public func prospectiveDehazeInputV1(context:DevelopmentDehazeContextV1,algorithm:DevelopmentDehazeAlgorithm = .v1)throws->DevelopmentDehazeProjectionV1 {
    try validate();try context.validate()
    let analysis=try promotingToV3(),sampling=try dehazeSamplingRecipeV1(),dependency=try EditingFingerprint.of(sampling)
    struct Identity:Encodable {
      let sourceBinding:DevelopmentLocalEditSourceBinding
      let inputStageVersion:Int
      let decoderContractFingerprint:String
      let dependencyRecipeFingerprint:String
      let algorithmVersion:Int
    }
    let fp=try EditingFingerprint.of(Identity(sourceBinding:context.source,inputStageVersion:1,
      decoderContractFingerprint:context.decoderContractFingerprint,dependencyRecipeFingerprint:dependency,algorithmVersion:algorithm.rawValue))
    return .init(analysisRecipe:analysis,samplingRecipe:sampling,expectedRecipeFingerprint:try EditingFingerprint.of(analysis),
      presentedRecipeFingerprint:try EditingFingerprint.of(self),input:.init(context:context,algorithm:algorithm,dependencyRecipeFingerprint:dependency,inputFingerprint:fp))
  }
  public func dehazePreparationStatusV1(context:DevelopmentDehazeContextV1)throws->DevelopmentDehazePreparationStatusV1 {
    guard let prepared=adjustmentsV3?.advancedDetail.preparedDehaze else {
      _=try prospectiveDehazeInputV1(context:context) // Keep absent input validation unchanged.
      return .absent
    }
    try prepared.validate()
    guard let algorithm=DevelopmentDehazeAlgorithm(rawValue:prepared.algorithmVersion) else { throw DevelopmentDehazePreparationError.invalidPreparation }
    let projection=try prospectiveDehazeInputV1(context:context,algorithm:algorithm)
    return prepared.sourceBinding==context.source && prepared.inputFingerprint==projection.input.inputFingerprint ? .ready:.stale
  }
  func applyingPreparedDehazeV1(_ resolved:DevelopmentResolvedDehazeV1,wantedAmount:Double,
                              context:DevelopmentAdjustmentCommandContext?)throws->DevelopmentRecipe {
    guard let context,let actual=context.dehazeContextV1 else { throw DevelopmentDehazePreparationError.missingContext }
    try actual.validate();try DevelopmentV3Validation.range([wantedAmount],-100...100)
    guard actual.source==context.source,actual.sourceGeneration==context.sourceGeneration,
      context.analysisStage == .workingImageBeforeGeometry else { throw DevelopmentDehazePreparationError.staleInput }
    let p=try prospectiveDehazeInputV1(context:actual,algorithm:resolved.input.algorithm),b=resolved.binding
    guard resolved.input==p.input,resolved.presentedRecipeFingerprint==p.presentedRecipeFingerprint,
      b.sourceContentID==actual.source.sourceContentID,b.sourceGeneration==actual.sourceGeneration,
      b.stage == .workingImageBeforeGeometry,b.expectedRecipeFingerprint==p.expectedRecipeFingerprint else { throw DevelopmentDehazePreparationError.staleInput }
    if case .noResult = resolved.resolution { return self }
    guard case .prepared(let prepared)=resolved.resolution else { throw DevelopmentDehazePreparationError.invalidPreparation }
    try prepared.validate()
    guard prepared.sourceBinding==actual.source,prepared.inputFingerprint==p.input.inputFingerprint,
      prepared.algorithmVersion==p.input.algorithm.rawValue else { throw DevelopmentDehazePreparationError.staleInput }
    if let existing=adjustmentsV3?.advancedDetail.selectedDehazeAlgorithm,existing.rawValue != prepared.algorithmVersion {
      throw DevelopmentDehazePreparationError.staleInput
    }
    if wantedAmount==0 { return self }
    if let wb=p.analysisRecipe.adjustmentsV3!.whiteBalance.resolvedState {
      guard context.sourceCapability==wb.sourceCapability else { throw DevelopmentAdjustmentCommandError.missingSourceContext }
      try wb.validate(expectedSource:actual.source)
    }
    var result=p.analysisRecipe
    result.adjustmentsV3!.advancedDetail.dehaze = .init(enabled:true,amount:wantedAmount)
    result.adjustmentsV3!.advancedDetail.preparedDehaze=prepared
    return try finalizingDehazeV1(result,context:context,directActivation:true)
  }
  /// Every successful command path converges here. No-result/identical values are
  /// untouched; a dependency edit invalidates A and pauses the effect atomically.
  func finalizingDehazeV1(_ candidate:DevelopmentRecipe,context:DevelopmentAdjustmentCommandContext?,directActivation:Bool=false)throws->DevelopmentRecipe {
    if candidate==self { return self }
    guard var payload=candidate.adjustmentsV3 else { try candidate.validate();return candidate }
    let before=try dehazeSamplingRecipeV1(),after=try candidate.dehazeSamplingRecipeV1()
    func paused()->DevelopmentRecipe {
      // Retain only the selected algorithm before discarding a now-invalid estimate.
      // No old recipe is migrated by decode/display; this accompanies the actual edit.
      if let selected=payload.advancedDetail.selectedDehazeAlgorithm {
        payload.advancedDetail.dehazeAlgorithmVersion=selected.rawValue
      }
      payload.advancedDetail.preparedDehaze=nil
      if payload.advancedDetail.dehaze.amount != 0 { payload.advancedDetail.dehaze.enabled=false }
      var r=candidate;r.adjustmentsV3=payload;return r
    }
    if before != after { let r=paused();try r.validate();return r }
    let active=payload.advancedDetail.dehaze.enabled && payload.advancedDetail.dehaze.amount != 0
    if let actual=context?.dehazeContextV1 {
      try actual.validate()
      guard actual.source==context!.source,actual.sourceGeneration==context!.sourceGeneration else { throw DevelopmentDehazePreparationError.staleInput }
      if try candidate.dehazePreparationStatusV1(context:actual) != .ready {
        if active && directActivation { throw DevelopmentDehazePreparationError.preparationRequired }
        if payload.advancedDetail.preparedDehaze != nil || active { let r=paused();try r.validate();return r }
      }
    } else if active {
      throw directActivation ? DevelopmentDehazePreparationError.preparationRequired:DevelopmentDehazePreparationError.missingContext
    }
    try candidate.validate();return candidate
  }
}
