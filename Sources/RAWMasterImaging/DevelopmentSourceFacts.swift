import Foundation
import RAWMasterCore

/// Describes the decoder actually constructed for the admitted capture, not a filename guess.
public enum DevelopmentSourceKind: String, Sendable { case raw, image, generatedArtifact }

public struct DevelopmentRAWNoiseReductionFacts: Equatable, Sendable {
  public let luminanceNoiseSupported, colorNoiseSupported, detailSupported: Bool
  /// Original decoder values, before any recipe mutates its native parameters.
  public let defaultLuminanceNoise, defaultColorNoise, defaultDetail: Float
  public init(luminanceNoiseSupported: Bool, colorNoiseSupported: Bool, detailSupported: Bool,
              defaultLuminanceNoise: Float, defaultColorNoise: Float, defaultDetail: Float) {
    self.luminanceNoiseSupported = luminanceNoiseSupported; self.colorNoiseSupported = colorNoiseSupported; self.detailSupported = detailSupported
    self.defaultLuminanceNoise = defaultLuminanceNoise; self.defaultColorNoise = defaultColorNoise; self.defaultDetail = defaultDetail
  }
}
public struct DevelopmentNoiseReductionFacts: Equatable, Sendable {
  public let sourceCapability: DevelopmentNoiseReductionSourceCapability
  /// Nil for rendered images/artifacts; these use the distinct nonRawAmount domain.
  public let raw: DevelopmentRAWNoiseReductionFacts?
  public init(sourceCapability: DevelopmentNoiseReductionSourceCapability, raw: DevelopmentRAWNoiseReductionFacts?) { self.sourceCapability = sourceCapability; self.raw = raw }
}
public struct DevelopmentAsShotWhiteBalance: Equatable, Sendable {
  public let temperature, tint: Float
  public init(temperature: Float, tint: Float) { self.temperature = temperature; self.tint = tint }
}
public enum DevelopmentLocalCapability: String, Sendable {
  case manualRetouch, automaticDonor, manualRedEye, automaticRedEye
}

public struct DevelopmentSourceFacts: Equatable, Sendable {
  public let supportedGrainSamplingVersions: Set<DevelopmentGrainSamplingVersion>
  public let supportsCropAutomatic: Bool
  public let dehazeContextV1: DevelopmentDehazeContextV1?
  public let localDecoderContractFingerprint: String?
  public let localCapabilities: Set<DevelopmentLocalCapability>
  public let sourceBinding: DevelopmentLocalEditSourceBinding
  public let sourceGeneration: UInt64
  public let sourceKind: DevelopmentSourceKind
  /// Captured camera/lens metadata, when ImageIO actually exposes it.
  public let lensMetadata: DevelopmentLensMetadata?
  /// Actual ImageIO depth/disparity auxiliary-data presence, not a file-extension guess.
  public let rawDetailsCapability: DevelopmentRawDetails?
  public let aiDenoiseCapability: DevelopmentAIDenoiseV1.Model?
  public let deviceDepthAvailable: Bool
  public let decoderVersion: String
  public let noiseReduction: DevelopmentNoiseReductionFacts
  /// Nil for image/artifact sources; 6500/0 is not fabricated as captured metadata.
  public let asShotWhiteBalance: DevelopmentAsShotWhiteBalance?
  /// Actual engine implementations, not a claim of Photos-reference qualification.
  public let implementedAdjustments: Set<DevelopmentAdjustmentID>
  public let automaticAdjustments: Set<DevelopmentAdjustmentID>
  public let initialWhiteBalanceState: DevelopmentResolvedWhiteBalanceV3?
  public let supportedGeometryVersions: Set<DevelopmentGeometryVersionV3>
  public let supportedPhotoFilters: Set<DevelopmentPhotoFilterV3>
  public let photoFilterResourceVersion: String?
  public init(sourceBinding: DevelopmentLocalEditSourceBinding, sourceGeneration: UInt64, sourceKind: DevelopmentSourceKind,
              decoderVersion: String, noiseReduction: DevelopmentNoiseReductionFacts, asShotWhiteBalance: DevelopmentAsShotWhiteBalance?,
              implementedAdjustments: Set<DevelopmentAdjustmentID>, automaticAdjustments: Set<DevelopmentAdjustmentID> = [],
              initialWhiteBalanceState: DevelopmentResolvedWhiteBalanceV3? = nil,
              supportedGeometryVersions: Set<DevelopmentGeometryVersionV3> = [],
              localDecoderContractFingerprint: String? = nil, localCapabilities: Set<DevelopmentLocalCapability> = [], dehazeContextV1: DevelopmentDehazeContextV1? = nil,
              supportedPhotoFilters: Set<DevelopmentPhotoFilterV3> = [.original], photoFilterResourceVersion: String? = nil, supportsCropAutomatic: Bool = false, supportedGrainSamplingVersions: Set<DevelopmentGrainSamplingVersion> = [],
              lensMetadata: DevelopmentLensMetadata? = nil, deviceDepthAvailable: Bool = false, rawDetailsCapability: DevelopmentRawDetails? = nil, aiDenoiseCapability: DevelopmentAIDenoiseV1.Model? = nil) {
    self.aiDenoiseCapability = aiDenoiseCapability
    self.rawDetailsCapability = rawDetailsCapability
    self.lensMetadata=lensMetadata; self.deviceDepthAvailable=deviceDepthAvailable
    self.supportedGrainSamplingVersions = supportedGrainSamplingVersions
    self.supportsCropAutomatic = supportsCropAutomatic
    self.supportedPhotoFilters = supportedPhotoFilters; self.photoFilterResourceVersion = photoFilterResourceVersion
    self.dehazeContextV1 = dehazeContextV1
    self.localDecoderContractFingerprint = localDecoderContractFingerprint; self.localCapabilities = localCapabilities
    self.sourceBinding = sourceBinding; self.sourceGeneration = sourceGeneration; self.sourceKind = sourceKind
    self.decoderVersion = decoderVersion; self.noiseReduction = noiseReduction; self.asShotWhiteBalance = asShotWhiteBalance
    self.implementedAdjustments = implementedAdjustments; self.automaticAdjustments = automaticAdjustments; self.initialWhiteBalanceState = initialWhiteBalanceState
    self.supportedGeometryVersions = supportedGeometryVersions
  }
}
