// Version-1.1 controlled-roll horizon crop Auto; native qualification is tracked separately.
import Foundation

public enum DevelopmentCropAutoNoResultV1: String, Equatable, Sendable {
  case unsupportedGeometry, unsupportedDetector, insufficientResolution, opaqueContentRequired
  case noHorizon, lowConfidence, inconsistentScales, excessiveRotation, failedVerification, unchanged
}
public struct DevelopmentCropAutoInputV1: Equatable, Sendable {
  public let baselineGeometryFingerprint: String
  public let aspectRatio: Double?
  public init(geometry: DevelopmentGeometryV3, aspectRatio: Double?) throws {
    try geometry.validate()
    if let aspectRatio { guard aspectRatio.isFinite, aspectRatio > 0 else { throw EditingError.invalidRecipe } }
    baselineGeometryFingerprint = try EditingFingerprint.of(geometry); self.aspectRatio = aspectRatio
  }
}
/// One actual VNrev1 observation after applying a known displayed-space roll to the corrected image.
/// residual is periodic correction - (-knownRoll); an absent observation cannot be represented here.
public struct DevelopmentCropAutoVerificationObservationV1: Equatable, Sendable {
  public let knownRollDegrees, correctionDegrees, confidence, residualDegrees: Double
  public init(knownRollDegrees: Double, correctionDegrees: Double, confidence: Double) {
    self.knownRollDegrees=knownRollDegrees;self.correctionDegrees=correctionDegrees;self.confidence=confidence
    residualDegrees=DevelopmentCropGeometryAutoV1.horizonDifference(correctionDegrees,-knownRollDegrees)
  }
}
/// v1.1 requires both real observations, in fixed +3 then -3 degree order. No summary-to-pair initializer.
public struct DevelopmentCropAutoVerificationPairV1: Equatable, Sendable {
  public let positiveRoll, negativeRoll: DevelopmentCropAutoVerificationObservationV1
  public init(positiveRoll: DevelopmentCropAutoVerificationObservationV1, negativeRoll: DevelopmentCropAutoVerificationObservationV1) {
    self.positiveRoll=positiveRoll;self.negativeRoll=negativeRoll
  }
  public var residualDegrees: Double { max(abs(positiveRoll.residualDegrees),abs(negativeRoll.residualDegrees)) }
  public var confidence: Double { min(positiveRoll.confidence,negativeRoll.confidence) }
  public func validate() throws {
    let p=positiveRoll,n=negativeRoll
    guard p.knownRollDegrees == 3,n.knownRollDegrees == -3,
      [p.knownRollDegrees,p.correctionDegrees,p.confidence,p.residualDegrees,n.knownRollDegrees,n.correctionDegrees,n.confidence,n.residualDegrees].allSatisfy(\.isFinite),
      (0.8...1).contains(p.confidence),(0.8...1).contains(n.confidence),
      abs(p.residualDegrees) <= 0.5,abs(n.residualDegrees) <= 0.5,
      abs(DevelopmentCropGeometryAutoV1.horizonDifference(p.residualDegrees,n.residualDegrees)) <= 0.75 else { throw EditingError.invalidRecipe }
  }
}
public struct DevelopmentCropAutoEvidenceV1: Equatable, Sendable {
  public let firstDegrees, secondDegrees, firstConfidence, secondConfidence: Double
  public let verificationPair: DevelopmentCropAutoVerificationPairV1
  /// Summaries derive only from the retained actual pair, never the reverse.
  public var residualDegrees: Double { verificationPair.residualDegrees }
  public var verificationConfidence: Double { verificationPair.confidence }
  public let detectorRevision: Int
  public init(firstDegrees: Double, secondDegrees: Double, firstConfidence: Double, secondConfidence: Double,
              verificationPair: DevelopmentCropAutoVerificationPairV1, detectorRevision: Int = 1) {
    self.firstDegrees=firstDegrees;self.secondDegrees=secondDegrees;self.firstConfidence=firstConfidence
    self.secondConfidence=secondConfidence;self.verificationPair=verificationPair;self.detectorRevision=detectorRevision
  }
}
public enum DevelopmentGeometryResolutionV1: Equatable, Sendable {
  case candidate(DevelopmentGeometryV3, DevelopmentCropAutoEvidenceV1)
  case noResult(DevelopmentCropAutoNoResultV1)
}
public struct DevelopmentResolvedGeometryV1: Equatable, Sendable {
  public let binding: DevelopmentAnalysisBinding
  public let source: DevelopmentLocalEditSourceBinding
  public let presentedRecipeFingerprint: String
  public let input: DevelopmentCropAutoInputV1
  public let resolution: DevelopmentGeometryResolutionV1
  public init(binding: DevelopmentAnalysisBinding, source: DevelopmentLocalEditSourceBinding,
              presentedRecipeFingerprint: String, input: DevelopmentCropAutoInputV1, resolution: DevelopmentGeometryResolutionV1) {
    self.binding=binding;self.source=source;self.presentedRecipeFingerprint=presentedRecipeFingerprint
    self.input=input;self.resolution=resolution
  }
  /// The App must additionally validate CURRENT operation/session/branch/epoch/full draft ticket before one command.
  public func validatedCandidate(baseline: DevelopmentGeometryV3, expectedSource: DevelopmentLocalEditSourceBinding,
                                 expectedInput: DevelopmentCropAutoInputV1) throws -> DevelopmentGeometryV3? {
    try source.validate();try baseline.validate()
    guard source == expectedSource, input == expectedInput,
      binding.sourceContentID == source.sourceContentID, binding.sourceGeneration > 0,
      binding.stage == .orientedSourceBeforeGeometry, EditingFingerprint.isSHA256(binding.expectedRecipeFingerprint),
      EditingFingerprint.isSHA256(presentedRecipeFingerprint),
      input.baselineGeometryFingerprint == (try EditingFingerprint.of(baseline)) else { throw EditingError.staleSource }
    guard case .candidate(let candidate,let e)=resolution else { return nil }
    try e.verificationPair.validate()
    guard DevelopmentCropGeometryAutoV1.supports(baseline), e.detectorRevision == 1,
      [e.firstDegrees,e.secondDegrees,e.firstConfidence,e.secondConfidence,e.residualDegrees,e.verificationConfidence].allSatisfy(\.isFinite),
      (0.8...1).contains(e.firstConfidence),(0.8...1).contains(e.secondConfidence),(0.8...1).contains(e.verificationConfidence),
      abs(DevelopmentCropGeometryAutoV1.horizonDifference(e.firstDegrees,e.secondDegrees)) <= 0.75,
      abs(DevelopmentCropGeometryAutoV1.horizonDifference(e.residualDegrees,0)) <= 0.5,
      abs(candidate.straightenDegrees) <= 15,
      abs(candidate.straightenDegrees-baseline.straightenDegrees) <= 15,
      abs(candidate.straightenDegrees-baseline.straightenDegrees) > 0.05 else { throw EditingError.invalidRecipe }
    let expected=try DevelopmentCropGeometryAutoV1.candidate(baseline:baseline,sourceSize:source.sourceSize,
      absoluteDegrees:e.firstDegrees,aspectRatio:input.aspectRatio)
    guard candidate == expected else { throw EditingError.invalidRecipe }
    _=try candidate.mapping(sourceSize:source.sourceSize)
    return candidate
  }
}
