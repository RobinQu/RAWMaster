import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// One invocation's exact context construction, not caller-asserted options or a persistent context.
final class PreviewCanonicalFiniteContextV1 {
  let context:CIContext
  let deviceRegistryID:UInt64
  let optionsVersion=PreviewNativePointwiseV1.contextVersion
  private init(device:MTLDevice) {
    deviceRegistryID=device.registryID
    context=CIContext(mtlDevice:device,options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
      .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
  }
  static func make(device:MTLDevice)->PreviewCanonicalFiniteContextV1 {.init(device:device)}
}

/// Non-Codable, single-use, worker-scoped evidence. Constructed only from the real held input pin.
/// It authorizes one named finite scan replacement, never a bitmap/renderer substitution.
final class PreviewCanonicalFiniteEvidenceV1 {
  static let version="canonical-graph/global-output-proven-finite-v1"
  static let stage="global-output-after-photo-filter"
  static func bootstrap(bundleIdentifier:String?,environment:[String:String])->Bool {
    bundleIdentifier=="io.robinqu.RAWMaster.preview022" &&
      environment["RAWMASTER_QA_NATIVE_POINTWISE_V1"]=="1" &&
      environment["RAWMASTER_QA_CANONICAL_FINITE_V1"]=="1"
  }
  private weak var native:PreviewNativeSource?
  private weak var pin:RawBasePin?
  private weak var contextOwner:PreviewCanonicalFiniteContextV1?
  private weak var base:CIImage?
  private let descriptor:PreviewNativePointwiseBaseDescriptorV1
  private let grid:PreviewNativePointwiseCertificateV1.Grid
  private let owner:UUID
  private let authority:String
  private let binding:PreviewNativePointwiseCertificateV2.Binding
  private let sampler:PreviewNativePointwiseCertificateV1.Sampler
  let proofID:String
  let bindingFingerprint:String
  private var active=true
  private(set) var consumed=false
  private init(native:PreviewNativeSource,pin:RawBasePin,base:CIImage,contextOwner:PreviewCanonicalFiniteContextV1,
               descriptor:PreviewNativePointwiseBaseDescriptorV1,grid:PreviewNativePointwiseCertificateV1.Grid,
               owner:UUID,authority:String,binding:PreviewNativePointwiseCertificateV2.Binding,
               sampler:PreviewNativePointwiseCertificateV1.Sampler,proofID:String,bindingFingerprint:String) {
    self.native=native;self.pin=pin;self.base=base;self.contextOwner=contextOwner;self.descriptor=descriptor
    self.grid=grid;self.owner=owner;self.authority=authority;self.binding=binding;self.sampler=sampler
    self.proofID=proofID;self.bindingFingerprint=bindingFingerprint
  }
  private struct Identity:Encodable {
    let version,stage,authority,proof,recipeFingerprint,pointSHA,witnessSHA,samplerABI,options,os:String
    let owner:UUID;let generation,device,scaleBits:UInt64
    let width,height,nativeWidth,nativeHeight:Int
    let pointwiseActive:Bool;let floatBits:[UInt32]
  }
  private static func expectedSampler(owner:UUID,authority:String,grid:PreviewNativePointwiseCertificateV1.Grid,
                                      descriptor:PreviewNativePointwiseBaseDescriptorV1,common:Bool)->PreviewNativePointwiseCertificateV1.Sampler {
    .init(owner:owner,authority:authority,grid:grid,device:descriptor.deviceRegistryID,
      pointSHA256:DevelopmentColorEngineV3.sourceSHA256,witnessSHA256:PreviewNativePointwiseCertificateV1.witnessSHA256,
      samplerABI:common ? PreviewNativePointwiseCertificateV2.samplerVersion:PreviewNativePointwiseCertificateV1.samplerVersion,
      os:descriptor.os,optionsVersion:PreviewNativePointwiseV1.contextVersion)
  }
  static func withEvidence<T>(native:PreviewNativeSource,pin:RawBasePin,base:CIImage,
                             contextOwner:PreviewCanonicalFiniteContextV1?,descriptor:PreviewNativePointwiseBaseDescriptorV1,
                             grid:PreviewNativePointwiseCertificateV1.Grid,recipe:DevelopmentRecipe,
                             check:()throws->Void,_ body:(PreviewCanonicalFiniteEvidenceV1?)throws->T)throws->T {
    // Default/nil route performs no new source-stat or proof work.
    guard let contextOwner else{return try body(nil)}
    try check();try native.validateCaptureAuthority()
    guard try PreviewNativePointwiseV1.routeEligibility(recipe,size:native.nativeSize)==nil,
      try PreviewNativeInputProfileV1.domain(recipe,size:native.nativeSize),
      contextOwner.deviceRegistryID==descriptor.deviceRegistryID,
      contextOwner.context.workingFormat == .RGBAf,
      let space=contextOwner.context.workingColorSpace,CFEqual(space,DevelopmentColorEngineV3.linearSRGB),
      contextOwner.optionsVersion==PreviewNativePointwiseV1.contextVersion,
      DevelopmentColorEngineV3.sourceSHA256==PreviewNativePointwiseCertificateV1.pointSourceSHA256,
      grid == (try PreviewNativePointwiseCertificateV1.grid(width:descriptor.width,height:descriptor.height)),
      descriptor == (try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:descriptor.sourceKey,generation:descriptor.generation,verifiedContentID:descriptor.verifiedContentID)),
      let owner=pin.ownerIncarnation,let input=pin.pointwiseInputCertificate,
      input.owner==owner,input.eligible,input.maximumAbsoluteRGB.isFinite,
      input.maximumAbsoluteRGB<=PreviewNativePointwiseCertificateV1.bound,
      input.pixels==descriptor.width*descriptor.height,
      base === (try pin.image),base.extent==CGRect(x:0,y:0,width:descriptor.width,height:descriptor.height) else {return try body(nil)}
    try PreviewNativeInputProfileV1.verify(recipe,native:native,descriptor:descriptor)
    let authority=try descriptor.fingerprint()
    guard input.authority==authority else{return try body(nil)}
    let common=try PreviewNativePointwiseCertificateV2.binding(recipe,size:native.nativeSize) != nil
    let closed=common ? PreviewNativePointwiseCertificateV2.samplerEnvelopeClosed(grid):grid.envelopeClosed
    let sampler=expectedSampler(owner:owner,authority:authority,grid:grid,descriptor:descriptor,common:common)
    guard closed,pin.pointwiseSamplerCertificate==sampler else{return try body(nil)}
    let binding=try PreviewNativePointwiseCertificateV2.Binding(recipe)
    let proofID=common ? PreviewNativePointwiseCertificateV2.version:PreviewNativePointwiseCertificateV1.version
    let identity=Identity(version:version,stage:stage,authority:authority,proof:proofID,
      recipeFingerprint:binding.recipeFingerprint,pointSHA:DevelopmentColorEngineV3.sourceSHA256,
      witnessSHA:PreviewNativePointwiseCertificateV1.witnessSHA256,samplerABI:sampler.samplerABI,
      options:contextOwner.optionsVersion,os:descriptor.os,owner:owner,generation:descriptor.generation,
      device:contextOwner.deviceRegistryID,scaleBits:grid.scale.bitPattern,width:grid.width,height:grid.height,
      nativeWidth:grid.nativeWidth,nativeHeight:grid.nativeHeight,pointwiseActive:binding.pointwiseActive,floatBits:binding.floatBits)
    let evidence=PreviewCanonicalFiniteEvidenceV1(native:native,pin:pin,base:base,contextOwner:contextOwner,
      descriptor:descriptor,grid:grid,owner:owner,authority:authority,binding:binding,sampler:sampler,
      proofID:proofID,bindingFingerprint:try EditingFingerprint.of(identity))
    defer{evidence.active=false}
    try check();try native.validateCaptureAuthority()
    return try body(evidence)
  }
  /// Called only at RendererV3's named stage. Mismatched/unavailable evidence uses the original scan.
  /// Cancellation/source/allocation/render errors still propagate; they are never converted to a proof.
  func consumeGlobalOutput(recipe:DevelopmentRecipe,capture:URL,context:CIContext,suppliedBase:CIImage?,
                           sourceIsRAW:Bool,sourceSize:CGSize,check:(()throws->Void)?)throws->Bool {
    guard active,!consumed,let native,let pin,let contextOwner,let base else{return false}
    try check?();try native.validateCaptureAuthority()
    guard capture==native.capture,context === contextOwner.context,suppliedBase === base,
      sourceIsRAW==native.hasRAWFilter,sourceSize==native.nativeSize,
      context.workingFormat == .RGBAf,let space=context.workingColorSpace,CFEqual(space,DevelopmentColorEngineV3.linearSRGB),
      contextOwner.deviceRegistryID==descriptor.deviceRegistryID,contextOwner.optionsVersion==PreviewNativePointwiseV1.contextVersion,
      DevelopmentColorEngineV3.sourceSHA256==PreviewNativePointwiseCertificateV1.pointSourceSHA256,
      try PreviewNativePointwiseV1.routeEligibility(recipe,size:sourceSize)==nil,
      try PreviewNativeInputProfileV1.domain(recipe,size:sourceSize),
      binding == (try PreviewNativePointwiseCertificateV2.Binding(recipe)),
      descriptor == (try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:descriptor.sourceKey,generation:descriptor.generation,verifiedContentID:descriptor.verifiedContentID)),
      pin.ownerIncarnation==owner,let input=pin.pointwiseInputCertificate,input.owner==owner,input.authority==authority,
      input.eligible,input.pixels==descriptor.width*descriptor.height,input.maximumAbsoluteRGB<=PreviewNativePointwiseCertificateV1.bound,
      pin.pointwiseSamplerCertificate==sampler,base === (try pin.image),
      grid == (try PreviewNativePointwiseCertificateV1.grid(width:descriptor.width,height:descriptor.height)) else{return false}
    try PreviewNativeInputProfileV1.verify(recipe,native:native,descriptor:descriptor)
    try check?();try native.validateCaptureAuthority();consumed=true;return true
  }
}
