import Foundation
import CoreImage
import RAWMasterCore

/// Caller has verified this immutable source/depth against its complete cache descriptor.
struct DevelopmentSuppliedImageBaseV1 {
  let image:CIImage
  let sourceDepth:Int
}

/// Closed cancellation authority. Destructive causes win even after a delivery was disabled.
enum PreviewNativeCancellationCauseV1: Int, Sendable {
  case frameSuperseded = 1, consumerClosing = 2, sourceInvalidated = 3, pressure = 4, unknown = 5
  var destructive: Bool { self != .frameSuperseded }
}

enum PreviewNativeInputProfileV1 {
  static let version = "qa-native-input-share-v1/canonical-all-checks"
  static func bootstrap(bundleIdentifier: String?,environment: [String:String]) -> Bool {
    guard environment["RAWMASTER_QA_NATIVE_POINTWISE_V1"] == "1" else { return false }
    return bundleIdentifier == "io.robinqu.RAWMaster.preview021" ||
      bundleIdentifier == "io.robinqu.RAWMaster.preview022"
  }
  static func sharedFITBootstrap(bundleIdentifier: String?, environment: [String:String]) -> Bool {
    bundleIdentifier == "io.robinqu.RAWMaster.preview022" &&
      bootstrap(bundleIdentifier:bundleIdentifier,environment:environment) &&
      environment["RAWMASTER_QA_SHARED_FIT_V1"] == "1"
  }
  /// A strict actual-recipe domain, distinct from general pixel-neutral delegation.
  static func domain(_ recipe: DevelopmentRecipe,size: CGSize) throws -> Bool {
    try recipe.validate()
    guard recipe.schemaVersion==3 else { return false }
    return try PreviewNativePointwiseV1.saturationDomainReason(recipe,size:size)==nil ||
      PreviewNativePointwiseCertificateV2.domainReason(recipe,size:size)==nil
  }
  /// Recipe-native parameters must agree with the actual immutable descriptor, not
  /// merely a requested recipe FP or a numerically similar native temperature.
  static func verify(_ recipe: DevelopmentRecipe,native: PreviewNativeSource,
                     descriptor: PreviewNativePointwiseBaseDescriptorV1) throws {
    guard let p=recipe.adjustmentsV3,try domain(recipe,size:native.nativeSize),
      descriptor == (try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:descriptor.sourceKey,
        generation:descriptor.generation,verifiedContentID:descriptor.verifiedContentID)) else { throw PreviewPresentationError.allocationProtocol }
    switch descriptor.source {
    case .rawDefaults(let defaults):
      let parameters=try DevelopmentRendererV3.NativeParameters(p,originalDefaultsFingerprint:defaults)
      guard native.hasRAWFilter,defaults==native.originalNativeDefaultsFingerprint,
        parameters.exposure.bitPattern==Float(0).bitPattern,parameters.whiteBalance == .asShot,
        parameters.noiseReduction==nil else { throw PreviewPresentationError.unsupported }
    case .imageOrientedDecode(let profile):
      guard !native.hasRAWFilter,profile==native.nativePointwiseImageICCIdentity else { throw PreviewPresentationError.allocationProtocol }
    }
  }
  static func cause(_ error: DevelopmentPreviewError) -> PreviewNativeCancellationCauseV1 {
    switch error {
    case .superseded:return .frameSuperseded
    case .closed:return .consumerClosing
    case .sourceInvalidated:return .sourceInvalidated
    case .memoryBudgetExceeded:return .pressure
    default:return .unknown
    }
  }
  static func frameFailure(_ error: Error) -> Bool {
    if let value=error as? DevelopmentPreviewError { return value == .superseded }
    return error is CancellationError
  }
}

/// Request-policy capability only: no alpha certificate, pixel ownership, or render authorization.
/// The admitted lease owns the source identity; every actual render still validates its full request.
public struct PreviewCanonicalGestureCapability: Sendable {
  public let sessionID: DevelopmentPreviewSessionID
  public let sourceGeneration: UInt64
  public let sourceIdentity: String
  private let nativeSize: CGSize
  init(sessionID:DevelopmentPreviewSessionID,sourceGeneration:UInt64,sourceIdentity:String,nativeSize:CGSize) {
    self.sessionID=sessionID;self.sourceGeneration=sourceGeneration
    self.sourceIdentity=sourceIdentity;self.nativeSize=nativeSize
  }
  static func bootstrap(bundleIdentifier:String?,environment:[String:String])->Bool {
    bundleIdentifier == "io.robinqu.RAWMaster.preview022" &&
      PreviewNativeInputProfileV1.bootstrap(bundleIdentifier:bundleIdentifier,environment:environment) &&
      environment["RAWMASTER_QA_CANONICAL_GESTURE_V1"] == "1"
  }
  static func admitted(native:PreviewNativeSource,sessionID:DevelopmentPreviewSessionID,generation:UInt64,
                       sourceKey:String,verifiedContentID:String)throws->Self? {
    guard !native.hasRAWFilter,!native.artifact,
      native.nativeSize.width.isFinite,native.nativeSize.height.isFinite,
      native.nativeSize.width >= 1,native.nativeSize.height >= 1,
      native.nativeSize.width == floor(native.nativeSize.width),native.nativeSize.height == floor(native.nativeSize.height),
      native.nativeSize.width <= Double(DevelopmentLocalEditLimits.maximumSourceDimension),
      native.nativeSize.height <= Double(DevelopmentLocalEditLimits.maximumSourceDimension),
      native.orientedNativeExtent == CGRect(origin:.zero,size:native.nativeSize) else{return nil}
    _ = try PreviewNativePointwiseCertificateV1.grid(width:Int(native.nativeSize.width),height:Int(native.nativeSize.height))
    _ = try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:sourceKey,generation:generation,verifiedContentID:verifiedContentID)
    return .init(sessionID:sessionID,sourceGeneration:generation,sourceIdentity:sourceKey,nativeSize:native.nativeSize)
  }
  public func supports(_ recipe:DevelopmentRecipe)throws->Bool {
    try PreviewNativeInputProfileV1.domain(recipe,size:nativeSize) &&
      PreviewNativePointwiseV1.routeEligibility(recipe,size:nativeSize) == nil
  }
}
