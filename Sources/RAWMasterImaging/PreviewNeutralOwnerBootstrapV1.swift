import Foundation
import CoreImage
import CryptoKit
import Metal
import RAWMasterCore

/// QA-only experiment: initialize the same native source owner while displaying a legacy neutral
/// frame. This is not a finite-output proof and changes no recipe. Default rendering stays untouched.
enum PreviewNeutralOwnerBootstrapV1 {
  static let version = "qa-neutral-owner-bootstrap-v2/original-lazy-neutral"
  static func bootstrap(bundleIdentifier:String?,environment:[String:String])->Bool {
    PreviewCanonicalFiniteEvidenceV1.bootstrap(bundleIdentifier:bundleIdentifier,environment:environment) &&
      environment["RAWMASTER_QA_NEUTRAL_OWNER_BOOTSTRAP_V1"] == "1"
  }
  static func recipeDomain(_ recipe:DevelopmentRecipe)throws->Bool {
    try recipe.validate()
    return recipe == DevelopmentRecipe()
  }
  static func sourceDomain(_ native:PreviewNativeSource)->Bool {
    guard !native.hasRAWFilter,!native.artifact,native.nativePointwiseImageDepth == 16,
      native.originalEXIFOrientation == 1,
      native.orientedNativeExtent == CGRect(origin:.zero,size:native.nativeSize),
      let profile=PhotoRenderer.sRGB.copyICCData() as Data? else{return false}
    let hash=SHA256.hash(data:profile).map{String(format:"%02x",$0)}.joined()
    // Compare the actual embedded ICC hash, never an unverified color-space display name.
    // The complete metadata string remains part of the unchanged source descriptor.
    return native.nativePointwiseImageICCIdentity?.hasPrefix("decoded-ICC-present:"+hash+":") == true
  }
  static func plan(native:PreviewNativeSource,recipe:DevelopmentRecipe,sourceKey:String,
                   generation:UInt64,verifiedContentID:String,maxPixel:Int)throws->PreviewNativePointwisePlanV1? {
    guard maxPixel == 2400,try recipeDomain(recipe),sourceDomain(native) else{return nil}
    let descriptor=try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:sourceKey,
      generation:generation,verifiedContentID:verifiedContentID)
    // The admitted legacy recipe has identity geometry. Preserve its full-canvas FIT size;
    // the V3 layout helper deliberately rejects schema1 and is not a promotion mechanism.
    let scale=min(1,Double(maxPixel)/max(native.nativeSize.width,native.nativeSize.height))
    let layout=try PreviewInteractiveLayout.make(width:Int(ceil(native.nativeSize.width*scale)),
      height:Int(ceil(native.nativeSize.height*scale)),float:false)
    var result=PreviewNativePointwisePlanV1(descriptor:descriptor,grid:nil,outputLayout:layout,fallback:nil)
    result.neutralOwnerBootstrap=true
    // This first experiment cancels its own frame normally; no superseded fill is retained.
    // Subsequent V3 requests retain inputs using their existing separate authority policy.
    return result
  }
  /// Only this file can create the input capability, after real whole-buffer scan and authority checks.
  struct Input {
    fileprivate let native:PreviewNativeSource
    fileprivate let descriptor:PreviewNativePointwiseBaseDescriptorV1
    fileprivate let pin:RawBasePin
    fileprivate let authority:String
    var ownerIncarnation:UUID? {pin.ownerIncarnation}
    func image(for native:PreviewNativeSource,recipe:DevelopmentRecipe,maxPixel:Int)throws->CIImage {
      try native.validateCaptureAuthority()
      guard self.native === native,maxPixel == 2400,try PreviewNeutralOwnerBootstrapV1.recipeDomain(recipe),
        PreviewNeutralOwnerBootstrapV1.sourceDomain(native),
        descriptor == (try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:descriptor.sourceKey,
          generation:descriptor.generation,verifiedContentID:descriptor.verifiedContentID)),
        let certificate=pin.pointwiseInputCertificate,certificate.eligible,
        certificate.owner == pin.ownerIncarnation,certificate.authority == authority else {
        throw PreviewPresentationError.allocationProtocol
      }
      return try pin.image
    }
  }
  /// nil means capacity refused before the fill started. No post-fill failure becomes a delegate.
  static func withInput<T>(native:PreviewNativeSource,recipe:DevelopmentRecipe,maxPixel:Int,
                           descriptor:PreviewNativePointwiseBaseDescriptorV1,pool:PreviewRawBasePool,
                           scope:PreviewPresentationScope,device:MTLDevice,
                           cancellation:DevelopmentAnalysisCancellation,
                           body:(Input,Bool)throws->T)throws->T? {
    func check()throws {try cancellation.check();try scope.requireOpenAdmission();try native.validateCaptureAuthority()}
    try check()
    guard maxPixel == 2400,try recipeDomain(recipe),sourceDomain(native),
      descriptor == (try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:descriptor.sourceKey,
        generation:descriptor.generation,verifiedContentID:descriptor.verifiedContentID)),
      descriptor.deviceRegistryID == device.registryID else{throw PreviewPresentationError.allocationProtocol}
    let authority=try descriptor.fingerprint()
    var pin=pool.acquirePointwiseResident(descriptor)
    defer { native.context.clearCaches();pin?.releaseAfterJoinedPipeline();pin=nil }
    let cold=pin == nil
    do {
      if cold {
        try check()
        // Pool capacity checks happen before the fill closure, which alone retires the idle context.
        do {
          pin=try pool.acquirePointwise(descriptor,publicationGate:{ publish in
            try cancellation.withInputPublication(allowFrameSuperseded:false,publish)
          }) { storage in
            try check();try pool.checkpoint("neutral-bootstrap/fill-before")
            native.retireIdleCanonicalContextForIndependentWork()
            try autoreleasepool {
              let context=CIContext(mtlDevice:device,options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
                .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
              defer{context.clearCaches()}
              let input=try PreviewNativePointwiseBaseV1.input(native,descriptor:descriptor)
              try storage.fill(input,context:context,mode:.whole,checkpoint:{ label in
                try pool.checkpoint(label);try check()
              },pointwiseAuthority:authority)
              try check()
              guard storage.pointwiseInputCertificate?.eligible == true else{throw PreviewPresentationError.unsupported}
              try pool.checkpoint("neutral-bootstrap/fill-joined-scanned")
            }
            try check();try pool.checkpoint("neutral-bootstrap/cold-context-retired")
          }
        } catch RawBaseCacheError.capacity {return nil}
        catch RawBaseCacheError.inFlight(let underlying) {throw underlying}
      }
      guard let pin,let certificate=pin.pointwiseInputCertificate,certificate.eligible,
        certificate.owner == pin.ownerIncarnation,certificate.authority == authority else{throw PreviewPresentationError.unsupported}
      try check()
      let input=Input(native:native,descriptor:descriptor,pin:pin,authority:authority)
      let result=try body(input,cold)
      try check();try pool.checkpoint("neutral-bootstrap/output-joined")
      return result
    } catch {
      // Cancellation, source loss, partial alpha and backend failures cannot publish a bootstrap.
      // The real native task has joined before fill throws and before this pin retires.
      pin?.releaseAfterJoinedPipeline();pin=nil;pool.retire(sourceKey:descriptor.sourceKey)
      do{try native.validateCaptureAuthority()}catch{throw error}
      throw error
    }
  }
}
