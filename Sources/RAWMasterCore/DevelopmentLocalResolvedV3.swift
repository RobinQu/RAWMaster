import Foundation

/// Preparation/replay work budgets, separate from image-memory policy. No old
/// recipe/operation Codable representation is changed by these ephemeral types.
public enum DevelopmentLocalPreparationError: Error, Equatable, Sendable {
  case invalidInput, staleInput, invalidResolution, unresolvedOperation
  case donorOutOfBounds, localWorkBudgetExceeded
}
public enum DevelopmentLocalNoResult: String, Codable, Sendable {
  case noVisibleSamples, noRedPixels, noConfidentEyes, noUsableDonor, unchanged
}
public enum DevelopmentLocalResolution: Equatable, Sendable {
  case append([DevelopmentLocalEdit])
  case noResult(DevelopmentLocalNoResult)
}
public struct DevelopmentLocalInputV1: Equatable, Sendable {
  public static let stageIdentifier = "working-image-pregeometry/local-v1"
  public let source: DevelopmentLocalEditSourceBinding
  public let sourceGeneration: UInt64
  public let stageVersion: Int
  public let decoderContractFingerprint: String
  public let stageRecipeFingerprint: String
  public let targetTool: DevelopmentLocalTool
  public let prefixCount: Int
  public let orderedPrefixFingerprint: String
  public init(source: DevelopmentLocalEditSourceBinding, sourceGeneration: UInt64, stageVersion: Int = 1,
              decoderContractFingerprint: String, stageRecipeFingerprint: String,
              targetTool: DevelopmentLocalTool, prefixCount: Int, orderedPrefixFingerprint: String) {
    self.source=source;self.sourceGeneration=sourceGeneration;self.stageVersion=stageVersion
    self.decoderContractFingerprint=decoderContractFingerprint;self.stageRecipeFingerprint=stageRecipeFingerprint
    self.targetTool=targetTool;self.prefixCount=prefixCount;self.orderedPrefixFingerprint=orderedPrefixFingerprint
  }
  public func validate() throws {
    try source.validate()
    guard sourceGeneration>0,stageVersion==1,(0...DevelopmentLocalEditLimits.maximumOperations).contains(prefixCount),
      EditingFingerprint.isSHA256(decoderContractFingerprint),EditingFingerprint.isSHA256(stageRecipeFingerprint),
      EditingFingerprint.isSHA256(orderedPrefixFingerprint) else { throw DevelopmentLocalPreparationError.invalidInput }
  }
}
public struct DevelopmentResolvedLocalBatch: Equatable, Sendable {
  /// Expected is the immutable pre-enable V3 analysis recipe. Presented remains
  /// the original visible draft, which may be v1/v2; no pre-enable write occurs.
  public let binding: DevelopmentAnalysisBinding
  public let presentedRecipeFingerprint: String
  public let input: DevelopmentLocalInputV1
  public let resolution: DevelopmentLocalResolution
  public init(binding: DevelopmentAnalysisBinding, presentedRecipeFingerprint: String,
              input: DevelopmentLocalInputV1, resolution: DevelopmentLocalResolution) {
    self.binding=binding;self.presentedRecipeFingerprint=presentedRecipeFingerprint
    self.input=input;self.resolution=resolution
  }
  public func validate() throws {
    try input.validate()
    guard binding.sourceContentID==input.source.sourceContentID,binding.sourceGeneration==input.sourceGeneration,
      binding.stage == .workingImageBeforeGeometry,EditingFingerprint.isSHA256(binding.expectedRecipeFingerprint),
      EditingFingerprint.isSHA256(presentedRecipeFingerprint) else { throw DevelopmentLocalPreparationError.invalidInput }
    if case .append(let operations)=resolution {
      guard !operations.isEmpty,operations.count<=DevelopmentLocalEditLimits.maximumOperations else { throw DevelopmentLocalPreparationError.invalidResolution }
      var ids=Set<UUID>()
      for operation in operations {
        try operation.validate()
        guard operation.tool==input.targetTool,operation.sourceContentID==input.source.sourceContentID,
          ids.insert(operation.id).inserted else { throw DevelopmentLocalPreparationError.invalidResolution }
        try DevelopmentLocalWorkEstimatorV1.requireResolved(operation)
        guard operation.stroke.strength>0,operation.stroke.points.contains(where:{$0.pressure>0}) else { throw DevelopmentLocalPreparationError.invalidResolution }
        if operation.tool == .retouch,operation.sourceSample==operation.stroke.points.first?.position { throw DevelopmentLocalPreparationError.invalidResolution }
        // Core can reject metadata with no covered pixel, but only Imaging can
        // attest an actual visible/color change on that prepared input stage.
        let single=DevelopmentLocalEditsV3(sourceBinding:input.source,retouchEnabled:input.targetTool == .retouch,
          redEyeEnabled:input.targetTool == .redEye,operations:[operation])
        guard try DevelopmentLocalWorkEstimatorV1.estimate(single)>0 else { throw DevelopmentLocalPreparationError.invalidResolution }
      }
    }
  }
}
public struct DevelopmentLocalProjectionV1: Equatable, Sendable {
  /// Pre-enable/promoted immutable snapshot for AnalysisRequest.preview. Never
  /// substitute the projected enabled recipe's fingerprint as expected/presented.
  public let analysisRecipe: DevelopmentRecipe
  public let recipe: DevelopmentRecipe
  public let expectedRecipeFingerprint: String
  public let presentedRecipeFingerprint: String
  public let input: DevelopmentLocalInputV1
}

public enum DevelopmentLocalWorkEstimatorV1 {
  /// Source-sampling work charge, not a bound on metadata reads, ALU or GPU duration.
  /// A covered Retouch pixel uses at most205 source float4 samples with explicit bilinear;
  /// 212 includes seven charge units of allowance. Per-dab boxes intentionally charge overlap.
  /// The192MiB metadata/analysis union and source/session admission remain independent guards.
  public static let workContractVersion = "local-work-v2/source-bilinear4/retouch212/redEye2"
  public static let retouchWorkUnitsPerPixel:Int64 = 212
  public static let redEyeWorkUnitsPerPixel:Int64 = 2
  public static let maximumWorkUnits:Int64 = 256*1024*1024
  public static let metadataUnionBytes=64*1024*1024
  public static let analysisUnionBytes=128*1024*1024
  public static let combinedUnionBytes=metadataUnionBytes+analysisUnionBytes
  /// Overflow helpers are also used by pure tests: no wrapping or saturation.
  static func checkedAdd(_ a:Int64,_ b:Int64)throws->Int64 {
    let (v,overflow)=a.addingReportingOverflow(b)
    guard a>=0,b>=0,!overflow else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded };return v
  }
  static func checkedMultiply(_ a:Int64,_ b:Int64)throws->Int64 {
    let (v,overflow)=a.multipliedReportingOverflow(by:b)
    guard a>=0,b>=0,!overflow else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded };return v
  }
  static func requireResolved(_ operation:DevelopmentLocalEdit)throws {
    guard operation.patch==nil,operation.toolVersion==1,
      operation.tool != .retouch || operation.sourceSample != nil else { throw DevelopmentLocalPreparationError.unresolvedOperation }
  }
  private struct Box { let x0,y0,x1,y1:Int64;var empty:Bool{x1<x0 || y1<y0} }
  private static func box(_ point:DevelopmentSourcePoint,radius:Double,size:DevelopmentPixelSize)throws->Box {
    let w=Double(size.width),h=Double(size.height),cx=point.x*w,cy=point.y*h
    let values=[max(0,ceil(cx-radius-0.5)),max(0,ceil(cy-radius-0.5)),min(w-1,floor(cx+radius-0.5)),min(h-1,floor(cy+radius-0.5))]
    guard values.allSatisfy({$0.isFinite && $0>=Double(Int32.min) && $0<=Double(Int32.max)}) else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded }
    return .init(x0:Int64(values[0]),y0:Int64(values[1]),x1:Int64(values[2]),y1:Int64(values[3]))
  }
  public static func estimate(_ edits:DevelopmentLocalEditsV3)throws->Int64 {
    try edits.validate()
    guard !edits.operations.isEmpty else { return 0 }
    guard let binding=edits.sourceBinding else { throw DevelopmentLocalPreparationError.invalidInput }
    let size=binding.sourceSize,short=Double(min(size.width,size.height));var total:Int64=0
    for operation in edits.operations where operation.tool == .retouch ? edits.retouchEnabled:edits.redEyeEnabled {
      try requireResolved(operation)
      let radius=operation.stroke.radiusInShortEdge*short
      guard radius.isFinite,radius>0 else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded }
      if operation.stroke.strength==0 { continue }
      let donor=operation.sourceSample,first=operation.stroke.points[0].position
      let dx=(donor?.x ?? first.x)-first.x,dy=(donor?.y ?? first.y)-first.y
      try operation.stroke.forEachDab(sourceSize:size) { dab in
        if dab.pressure==0 { return }
        let b=try box(dab.position,radius:radius,size:size)
        if b.empty { return }
        let width=try checkedAdd(b.x1-b.x0,1),height=try checkedAdd(b.y1-b.y0,1)
        let units=operation.tool == .redEye ? redEyeWorkUnitsPerPixel:(operation.retouchMode == .clone ? 5:retouchWorkUnitsPerPixel)
        let area=try checkedMultiply(width,height),cost=try checkedMultiply(area,units)
        total=try checkedAdd(total,cost)
        guard total<=maximumWorkUnits else { throw DevelopmentLocalPreparationError.localWorkBudgetExceeded }
        if operation.tool == .retouch {
          let minX=Double(b.x0)+0.5+dx*Double(size.width),maxX=Double(b.x1)+0.5+dx*Double(size.width)
          let minY=Double(b.y0)+0.5+dy*Double(size.height),maxY=Double(b.y1)+0.5+dy*Double(size.height)
          guard minX>=0.5,maxX<=Double(size.width)-0.5,minY>=0.5,maxY<=Double(size.height)-0.5 else { throw DevelopmentLocalPreparationError.donorOutOfBounds }
        }
      }
    }
    return total
  }
}

extension DevelopmentRecipe {
  /// Shared PURE projection used by Service preparation and Core append. The
  /// resulting recipe enables old target-tool ops, but never includes new ops.
  public func prospectiveLocalInputV1(source:DevelopmentLocalEditSourceBinding,sourceGeneration:UInt64,
                                    decoderContractFingerprint:String,targetTool:DevelopmentLocalTool)throws->DevelopmentLocalProjectionV1 {
    try validate();try source.validate()
    guard sourceGeneration>0,EditingFingerprint.isSHA256(decoderContractFingerprint) else { throw DevelopmentLocalPreparationError.invalidInput }
    let analysis=try promotingToV3();var payload=analysis.adjustmentsV3!
    try payload.localEdits.validate(expectedSource:source)
    payload.localEdits.sourceBinding=source
    if targetTool == .retouch { payload.localEdits.retouchEnabled=true } else { payload.localEdits.redEyeEnabled=true }
    _=try DevelopmentLocalWorkEstimatorV1.estimate(payload.localEdits)
    let projected=DevelopmentRecipe(adjustmentsV3:payload);try projected.validate()
    let prefix=try EditingFingerprint.of(payload.localEdits)
    // Geometry version preserves the legacy-basis branch contract; only its
    // geometric parameters are removed from this pixel-stage fingerprint.
    var stage=payload;stage.localEdits = .init();stage.geometry = .init(version:stage.geometry.version)
    let descriptor=DevelopmentLocalInputV1(source:source,sourceGeneration:sourceGeneration,decoderContractFingerprint:decoderContractFingerprint,
      stageRecipeFingerprint:try EditingFingerprint.of(DevelopmentRecipe(adjustmentsV3:stage)),targetTool:targetTool,
      prefixCount:payload.localEdits.operations.count,orderedPrefixFingerprint:prefix)
    try descriptor.validate()
    return .init(analysisRecipe:analysis,recipe:projected,expectedRecipeFingerprint:try EditingFingerprint.of(analysis),
      presentedRecipeFingerprint:try EditingFingerprint.of(self),input:descriptor)
  }
  func applyingLocalBatchV1(_ batch:DevelopmentResolvedLocalBatch,context:DevelopmentAdjustmentCommandContext?)throws->DevelopmentRecipe {
    guard let context,let expected=context.localInputV1 else { throw DevelopmentAdjustmentCommandError.missingSourceContext }
    try batch.validate();try expected.validate()
    guard context.source==batch.input.source,context.sourceGeneration==batch.input.sourceGeneration,
      context.analysisStage == .workingImageBeforeGeometry,expected==batch.input else { throw DevelopmentLocalPreparationError.staleInput }
    let projection=try prospectiveLocalInputV1(source:context.source,sourceGeneration:context.sourceGeneration,
      decoderContractFingerprint:expected.decoderContractFingerprint,targetTool:expected.targetTool)
    guard projection.input==batch.input,projection.expectedRecipeFingerprint==batch.binding.expectedRecipeFingerprint,
      projection.presentedRecipeFingerprint==batch.presentedRecipeFingerprint else { throw DevelopmentLocalPreparationError.staleInput }
    if case .noResult = batch.resolution { return self }
    guard case .append(let operations)=batch.resolution else { throw DevelopmentLocalPreparationError.invalidResolution }
    var result=projection.recipe,payload=result.adjustmentsV3!
    guard operations.count<=DevelopmentLocalEditLimits.maximumOperations-payload.localEdits.operations.count else { throw DevelopmentLocalPreparationError.invalidResolution }
    payload.localEdits.operations.append(contentsOf:operations)
    try payload.localEdits.validate(expectedSource:context.source)
    _=try DevelopmentLocalWorkEstimatorV1.estimate(payload.localEdits)
    if let resolved=payload.whiteBalance.resolvedState {
      guard context.sourceCapability==resolved.sourceCapability else { throw DevelopmentAdjustmentCommandError.missingSourceContext }
      try resolved.validate(expectedSource:context.source)
    }
    result.adjustmentsV3=payload;try result.validate();return result
  }
}
