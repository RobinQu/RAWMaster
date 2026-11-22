import Foundation
import AppKit
import CoreImage
import Metal
import RAWMasterCore

/// Default-OFF preview route. Does not change the canonical renderer, shader, export or pool size.
enum PreviewNativePointwiseV1 {
  static let version = "native-F32-pointwise-certificate-v1/public-canonical-FIT-target"
  static let fullValidationVersion = "native-F32-pointwise-v1/full-native-validation/public-canonical-FIT-target"
  static let contextVersion = "CI-default-device/linear-sRGB-RGBAf/cachefalse/512Mi/v1"
  static let sharedFITIntermediateVersion = "same-invocation-FIT-intermediate-v1"
  /// One invocation only. Cacheable is not proof of a cache hit or one evaluation.
  static func joinedFITImage(_ image:CIImage,insertingIntermediate:Bool)->CIImage {
    insertingIntermediate ? image.insertingIntermediate(cache:true):image
  }
  static let canonicalSharedFITVersion = "canonical-proven/same-invocation-FIT-intermediate-v1"
  static func canonicalSharedFITEligible(requested:Bool,proven:Bool,sourceCold:Bool,samplerCold:Bool)->Bool {
    requested && proven && !sourceCold && !samplerCold
  }
  static func canonicalSharedFITKeySuffix(requested:Bool)->String {
    requested ? "/qa-canonical-shared-fit:"+canonicalSharedFITVersion:""
  }
  static func canonicalSharedFITReplayMatches(_ receipt:PreviewNativePointwiseReceiptV1,requested:Bool)->Bool {
    requested ? (receipt.sharedFITIntermediateInserted && receipt.canonicalGlobalFITTransport==canonicalSharedFITVersion &&
      !receipt.sourceCold && !receipt.samplerCold):
      (!receipt.sharedFITIntermediateInserted && receipt.canonicalGlobalFITTransport==nil)
  }
  static let naturalSharedFITVersion = "natural-proven/same-invocation-FIT-intermediate-v1"
  static func naturalSharedFITEligible(requested:Bool,proven:Bool,synthetic:Bool,sourceCold:Bool,samplerCold:Bool)->Bool {
    requested && proven && !synthetic && !sourceCold && !samplerCold
  }
  static func naturalSharedFITKeySuffix(requested:Bool)->String {
    requested ? "/qa-natural-shared-fit:"+naturalSharedFITVersion:""
  }
  static func naturalSharedFITReplayMatches(_ receipt:PreviewNativePointwiseReceiptV1,requested:Bool)->Bool {
    requested ? (receipt.sharedFITIntermediateInserted && receipt.canonicalNaturalFITTransport==naturalSharedFITVersion):
      (!receipt.sharedFITIntermediateInserted && receipt.canonicalNaturalFITTransport==nil)
  }
  struct NaturalFIT {
    let checkedFIT:CIImage,outputGraph:DevelopedV3Graph
    let inserted:Bool
  }
  /// Same-invocation transport only. Production admission occurs after the real natural proof is consumed.
  /// Synthetic tests may inspect this primitive without acquiring production RAW qualification.
  static func prepareNaturalFIT(_ graph:DevelopedV3Graph,grid:PreviewNativePointwiseCertificateV1.Grid,insertingIntermediate:Bool)throws->NaturalFIT {
    let fitted=fit(graph.image,grid:grid)
    guard fitted.extent==grid.extent else{throw PreviewPresentationError.allocationProtocol}
    let checked=joinedFITImage(fitted,insertingIntermediate:insertingIntermediate)
    let outputGraph:DevelopedV3Graph
    if insertingIntermediate {
      outputGraph = .init(image:checked,sourceDepth:graph.sourceDepth,sourceSize:graph.sourceSize,
        canonicalSize:graph.canonicalSize,graphDescriptor:graph.graphDescriptor+"/"+naturalSharedFITVersion)
    }else{outputGraph=graph}
    return .init(checkedFIT:checked,outputGraph:outputGraph,inserted:insertingIntermediate)
  }
  enum Reason: String, Equatable { case recipe, geometry, legacyDelegate, viewport, nativePoolDisabled, sourceProfile, certificateDomain, grainCanonical }
  static func eligibility(_ recipe: DevelopmentRecipe,size: CGSize) throws -> Reason? {
    try recipe.validate()
    guard let p=recipe.adjustmentsV3,recipe.schemaVersion==3 else { return .recipe }
    // Historical neutral/zero uses its original half/context delegate, even with basis=nil.
    if try DevelopmentRendererV3.legacyEquivalent(recipe) != nil { return .legacyDelegate }
    return try saturationDomainReason(recipe,size:size)
  }
  static func saturationDomainReason(_ recipe: DevelopmentRecipe,size: CGSize) throws -> Reason? {
    try recipe.validate()
    guard let p=recipe.adjustmentsV3,recipe.schemaVersion==3 else { return .recipe }
    var projection=p
    if let b=p.legacyBasis {
      try b.validate()
      guard b.whiteBalance == .asShot,b.exposureEV==0,b.color?.isNeutral ?? true else { return .recipe }
      projection.legacyBasis=nil
    }
    projection.geometry.version=DevelopmentGeometryV3().version
    var fresh=DevelopmentAdjustmentsV3();fresh.color=p.color
    guard projection==fresh,
      p.color == DevelopmentColorV3() || (p.color.enabled && p.color.vibrance==0 && p.color.cast==0 && (-1...2).contains(p.color.saturation)) else { return .recipe }
    guard size.width>0,size.height>0,size.width==floor(size.width),size.height==floor(size.height),
      size.width<=Double(DevelopmentLocalEditLimits.maximumSourceDimension),size.height<=Double(DevelopmentLocalEditLimits.maximumSourceDimension) else { return .geometry }
    let native=DevelopmentPixelSize(width:Int(size.width),height:Int(size.height))
    let map=try p.geometry.mapping(sourceSize:native),identity:[Double]=[1,0,0,0,1,0,0,0,1]
    let full=DevelopmentContinuousRectV3(x:0,y:0,width:Double(native.width),height:Double(native.height))
    guard map.sourceSize==native,map.outputSize==native,map.forwardMatrix==identity,
      try map.inverseMatrix==identity,map.cropPlane.forwardMatrix==identity,map.cropPlane.inverseMatrix==identity,
      map.cropPlane.rect==full,map.cropPlane.identityRasterRect==full,map.cropPlane.actualRasterRect==full else { return .geometry }
    return nil
  }
  /// Route selection extends only the reviewed common-point domain. The original
  /// eligibility API and its sealed sat-v1 result/priority remain unchanged.
  static func routeEligibility(_ recipe: DevelopmentRecipe,size: CGSize) throws -> Reason? {
    try recipe.validate()
    if recipe.schemaVersion==3,let p=recipe.adjustmentsV3,p.blackAndWhite.grain != 0 || (p.effects?.enabled == true && (p.effects?.grain ?? 0) != 0) { return .grainCanonical }
    let old=try eligibility(recipe,size:size)
    if old==nil || old == .legacyDelegate { return old }
    return try PreviewNativePointwiseCertificateV2.domainReason(recipe,size:size)
  }
  static func layout(recipe: DevelopmentRecipe,size: CGSize,maxPixel: Int) throws -> PreviewInteractiveLayout {
    guard let p=recipe.adjustmentsV3,maxPixel>0 else { throw PreviewPresentationError.unsupported }
    let map=try p.geometry.mapping(sourceSize:.init(width:Int(size.width),height:Int(size.height)))
    let multiplier:Double = p.superResolution == nil ? 1:2
    let w=Double(map.outputSize.width)*multiplier,h=Double(map.outputSize.height)*multiplier
    let scale=min(1,Double(max(64,min(4096,maxPixel)))/max(w,h))
    return try .make(width:PreviewInteractiveProxyV3.scaledPixelDimension(w,scale:scale),height:PreviewInteractiveProxyV3.scaledPixelDimension(h,scale:scale),float:false)
  }
  static func prefix(_ p: DevelopmentAdjustmentsV3,input: CIImage,sourceIsRAW: Bool,
                     context: CIContext,check: @escaping () throws -> Void) throws -> CIImage {
    var image=input.transformed(by:.init(translationX:-input.extent.minX,y:-input.extent.minY))
    if !sourceIsRAW { image=try DevelopmentWhiteBalanceEngineV3.applyImage(p.whiteBalance,to:image,context:context,checkCancellation:check) }
    // Eligibility proves legacyWB/EV/color and newEV are neutral; keep original engine calls.
    image=try DevelopmentSpatialEngineV3.applyLight(p.light,to:image)
    image=try DevelopmentColorEngineV3.applyPointwise(p,to:image)
    image=try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:image)
    image=try DevelopmentGlobalEngineV3.apply(p,to:image,sourceIsRAW:sourceIsRAW)
    return try DevelopmentPhotoFilterEngineV3.apply(p.filter,to:image)
  }
  static func geometry(_ p: DevelopmentAdjustmentsV3,input: CIImage,context: CIContext,
                       check: @escaping () throws -> Void) throws -> CIImage {
    let image=try DevelopmentLocalEngineV3.apply(p.localEdits,to:input,context:context,checkCancellation:check)
    let developed: CIImage
    if p.geometry.version == .legacyV1 || p.geometry.version == .legacyV2 {
      developed = try PhotoRenderer.applyV2Geometry(image,DevelopmentRendererV3.legacyRecipe(p))
    } else {
      developed = try DevelopmentGeometryEngineV3.apply(p.geometry,to:image)
    }
    return try DevelopmentPostCropVignetteEngineV3.apply(p.effects,to:developed)
  }
  static func fit(_ image: CIImage,grid: PreviewNativePointwiseCertificateV1.Grid) -> CIImage {
    grid.scale < 1 ? image.transformed(by:.init(scaleX:grid.scale,y:grid.scale)):image
  }
}

struct PreviewNativePointwisePlanV1 {
  let descriptor: PreviewNativePointwiseBaseDescriptorV1?
  let grid: PreviewNativePointwiseCertificateV1.Grid?
  let outputLayout: PreviewInteractiveLayout
  let fallback: PreviewNativePointwiseV1.Reason?
  var commonPointBinding: PreviewNativePointwiseCertificateV2.Binding? = nil
  var proofID: String {
    commonPointBinding?.proofID ?? (fallback == .grainCanonical ? PreviewNativePointwiseCertificateV2.version:PreviewNativePointwiseCertificateV1.version)
  }
  var neutralOwnerBootstrap=false
  var canonicalFullChecks=false
  var canonicalNaturalFiniteProofEnabled=false
  var naturalCurveBinding:PreviewNaturalCurveFiniteEvidenceV1.Binding? = nil
  var canonicalGlobalFiniteProofEnabled=false
  var canonicalGlobalRecipeBinding:PreviewNativePointwiseCertificateV2.Binding? = nil
  var preserveVerifiedInput=false
  var semanticLegacy=false
  var fitCoverageGeometryVersion: DevelopmentGeometryVersionV3? = nil
  var mayNormalizeFITCoverage: Bool {
    guard !canonicalFullChecks, fallback == nil, commonPointBinding != nil,
          let descriptor, case .rawDefaults = descriptor.source,
          let grid, grid.scale < 1, PreviewFITCoverageV1.usesSingleNativeCheck(fitCoverageGeometryVersion) else {
      return false
    }
    return PreviewNativePointwiseCertificateV2.samplerEnvelopeClosed(grid)
  }
  func keySuffix() throws -> String {
    if neutralOwnerBootstrap {
      guard let descriptor else{throw PreviewPresentationError.allocationProtocol}
      return ":"+PreviewNeutralOwnerBootstrapV1.version+":"+(try descriptor.fingerprint())+":"
    }
    if let naturalCurveBinding {
      struct NaturalKey:Encodable {let version,input,context,route:String;let binding:PreviewNaturalCurveFiniteEvidenceV1.Binding;let width,height:Int;let scaleBits:UInt64}
      return ":native-natural:"+(try EditingFingerprint.of(NaturalKey(version:PreviewNaturalCurveFiniteEvidenceV1.version,
        input:try descriptor?.fingerprint() ?? "whole-canonical",context:PreviewNativePointwiseV1.contextVersion,
        route:canonicalNaturalFiniteProofEnabled ? "proven-global":"scanned-global",binding:naturalCurveBinding,
        width:outputLayout.width,height:outputLayout.height,scaleBits:grid?.scale.bitPattern ?? 0)))+":"
    }
    struct Key: Encodable { let version, input, route, proof, sampler, pointSHA, transport: String;let width,height:Int;let scaleBits:UInt64 }
    let proofKey:String
    if let binding=commonPointBinding { proofKey=binding.proofID+"/"+(try binding.fingerprint()) }
    else { proofKey=proofID }
    let oldTransport = "managed-IOSurface-BGRA8-public-FIT-v1"
    let transport = mayNormalizeFITCoverage ? oldTransport + "/" + PreviewFITCoverageV1.version : oldTransport
    let k=Key(version:PreviewNativePointwiseV1.version,input:try descriptor?.fingerprint() ?? "whole-canonical",
      route:canonicalFullChecks ? (canonicalGlobalFiniteProofEnabled ? PreviewCanonicalFiniteEvidenceV1.version:"canonical-all-checks"):(fallback?.rawValue ?? "source-certificate"),proof:proofKey,
      sampler:commonPointBinding == nil && fallback != .grainCanonical ? PreviewNativePointwiseCertificateV1.samplerVersion:PreviewNativePointwiseCertificateV2.samplerVersion,pointSHA:DevelopmentColorEngineV3.sourceSHA256,
      transport:transport,width:outputLayout.width,height:outputLayout.height,scaleBits:grid?.scale.bitPattern ?? 0)
    if canonicalFullChecks && canonicalGlobalFiniteProofEnabled {
      guard let canonicalGlobalRecipeBinding else{throw PreviewPresentationError.allocationProtocol}
      struct ProofKey:Encodable {let original:Key;let actualRecipeBinding:PreviewNativePointwiseCertificateV2.Binding}
      return ":native-pointwise:"+(try EditingFingerprint.of(ProofKey(original:k,actualRecipeBinding:canonicalGlobalRecipeBinding)))+":"
    }
    return ":native-pointwise:"+(try EditingFingerprint.of(k))+":"
  }
}
struct PreviewNativePointwiseReceiptV1: Sendable {
  let certified, sourceCold, samplerCold: Bool
  var proofID = PreviewNativePointwiseCertificateV1.version
  var canonicalFullChecks=false
  var canonicalGlobalFiniteProofID:String? = nil
  var canonicalGlobalFiniteBinding:String? = nil
  var canonicalGlobalFiniteStage:String? = nil
  var canonicalProofFITChecked=false
  var canonicalNaturalLUTSHA256:String? = nil
  var canonicalNaturalGlobalScans:Int? = nil
  var canonicalNaturalProofConsumptions:Int? = nil
  var canonicalNaturalSynthetic=false
  var canonicalNaturalFITTransport:String? = nil
  var canonicalGlobalFITTransport:String? = nil
  var canonicalGrainFinalTransport:String? = nil
  var sharedFITIntermediateInserted=false
  var fitCoverageTransport: String? = nil
  /// nil: untouched canonical delegate is not instrumented; never invent a zero count.
  let fullNativeChecks: Int?
  let owner: UUID?
  let reason: String?
}
extension PreviewPixels {
  func nativePointwiseReceipt(_ receipt: PreviewNativePointwiseReceiptV1,approximation: PreviewApproximationInfo? = nil) -> Self {
    .init(image:image,nativeSize:nativeSize,outputSize:outputSize,bytes:bytes,approximation:approximation ?? self.approximation,
      interactiveCanonicalFallbackReason:interactiveCanonicalFallbackReason,presentationTicket:presentationTicket,nativePointwise:receipt,
      actualGrainFinalTransport:actualGrainFinalTransport ?? receipt.canonicalGrainFinalTransport)
  }
}
extension PreviewNativeSource {
  /// Actor-side immutable facts only. Recipe is NOT modified by eligibility's neutral projection.
  func nativePointwisePlan(recipe: DevelopmentRecipe,sourceKey: String,generation: UInt64,
                           verifiedContentID: String,maxPixel: Int) throws -> PreviewNativePointwisePlanV1 {
    try recipe.validate()
    let layout=try PreviewNativePointwiseV1.layout(recipe:recipe,size:nativeSize,maxPixel:maxPixel)
    if maxPixel != 2400 || artifact { return .init(descriptor:nil,grid:nil,outputLayout:layout,fallback:.viewport) }
    if recipe.adjustmentsV3?.aiDenoise != nil || recipe.adjustmentsV3?.superResolution != nil { return .init(descriptor:nil,grid:nil,outputLayout:layout,fallback:.sourceProfile) }
    if let reason=try PreviewNativePointwiseV1.routeEligibility(recipe,size:nativeSize) {
      return .init(descriptor:nil,grid:nil,outputLayout:layout,fallback:reason)
    }
    guard orientedNativeExtent==CGRect(origin:.zero,size:nativeSize) else {
      return .init(descriptor:nil,grid:nil,outputLayout:layout,fallback:.geometry)
    }
    let grid: PreviewNativePointwiseCertificateV1.Grid
    do { grid=try PreviewNativePointwiseCertificateV1.grid(width:Int(nativeSize.width),height:Int(nativeSize.height)) }
    catch PreviewPresentationError.unsupported { return .init(descriptor:nil,grid:nil,outputLayout:layout,fallback:.viewport) }
    let descriptor: PreviewNativePointwiseBaseDescriptorV1
    do { descriptor=try PreviewNativePointwiseBaseV1.descriptor(self,sourceKey:sourceKey,generation:generation,verifiedContentID:verifiedContentID) }
    catch PreviewPresentationError.unsupported { return .init(descriptor:nil,grid:nil,outputLayout:layout,fallback:.sourceProfile) }
    var plan=PreviewNativePointwisePlanV1(descriptor:descriptor,grid:grid,outputLayout:layout,fallback:nil)
    plan.commonPointBinding=try PreviewNativePointwiseCertificateV2.binding(recipe,size:nativeSize)
    plan.fitCoverageGeometryVersion = recipe.adjustmentsV3?.geometry.version
    return plan
  }
  /// Separate RAW-only canonical domain; OFF remains the same full-native graph with its original scan.
  func nativeNaturalCurvePlan(recipe:DevelopmentRecipe,sourceKey:String,generation:UInt64,
                             verifiedContentID:String,maxPixel:Int,proofEnabled:Bool)throws->PreviewNativePointwisePlanV1 {
    guard maxPixel==2400,!artifact,hasRAWFilter,recipe.adjustmentsV3?.aiDenoise == nil,recipe.adjustmentsV3?.superResolution == nil,try PreviewNaturalCurveFiniteEvidenceV1.domain(recipe,size:nativeSize) else {
      return try nativePointwisePlan(recipe:recipe,sourceKey:sourceKey,generation:generation,verifiedContentID:verifiedContentID,maxPixel:maxPixel)
    }
    let layout=try PreviewNativePointwiseV1.layout(recipe:recipe,size:nativeSize,maxPixel:maxPixel)
    guard orientedNativeExtent==CGRect(origin:.zero,size:nativeSize)else{return .init(descriptor:nil,grid:nil,outputLayout:layout,fallback:.geometry)}
    let grid:PreviewNativePointwiseCertificateV1.Grid
    do{grid=try PreviewNativePointwiseCertificateV1.grid(width:Int(nativeSize.width),height:Int(nativeSize.height))}
    catch PreviewPresentationError.unsupported{return .init(descriptor:nil,grid:nil,outputLayout:layout,fallback:.viewport)}
    let descriptor=try PreviewNativePointwiseBaseV1.descriptor(self,sourceKey:sourceKey,generation:generation,verifiedContentID:verifiedContentID)
    try PreviewNaturalCurveFiniteEvidenceV1.verify(recipe,native:self,descriptor:descriptor)
    var plan=PreviewNativePointwisePlanV1(descriptor:descriptor,grid:grid,outputLayout:layout,fallback:nil)
    plan.canonicalFullChecks=true;plan.preserveVerifiedInput=true
    plan.naturalCurveBinding=try .init(recipe);plan.canonicalNaturalFiniteProofEnabled=proofEnabled
    return plan
  }
  /// Preserve the service's actual NativeSource.render operation, including its source key and pool policy,
  /// for every canonical fallback reason. Cache capacity/disabled fallback remains owned by that operation.
  /// Only AFTER its owned 8bit output is complete is it passed to managed display transport.
  private func nativePointwiseLegacyDelegate(canonicalRender: () throws -> PreviewPixels,
      layout: PreviewInteractiveLayout,scope: PreviewPresentationScope,device: MTLDevice,
      transportContext: CIContext,check: @escaping () throws -> Void,
      thumbnailNativeSink:((CIImage)throws->Void)? = nil,
      canonicalReason:PreviewNativePointwiseV1.Reason = .legacyDelegate,
      qaNeutralPretransportObserver:(@Sendable(PreviewPixels)throws->Void)? = nil) throws -> PreviewPixels {
    let (temporaryPeak,overflow)=layout.bytes.multipliedReportingOverflow(by:4)
    guard !overflow else { throw PreviewPresentationError.displayCapacity }
    // Existing body has: CI RGBA8 result, CGContext copy, its ownedCG, NSBitmap copy.
    // Their backing aliases are opaque. Reserve four full padded display payloads rather
    // than claiming four measured allocations, GPU0, or releasing at delegate return.
    // Actual CI-private/native decode intermediates remain independently measured/unknown.
    let tickets=try scope.reserveSharedOperation(bytes:[layout.bytes,temporaryPeak,65536])
    let output=PreviewInteractiveManagedOutput(layout:layout,ticket:tickets[0],device:device)
    var original: PreviewPixels?
    defer {
      self.context.clearCaches();transportContext.clearCaches();original=nil
      tickets[1].releaseAfterStorageReleased();tickets[2].releaseAfterStorageReleased()
    }
    original=try autoreleasepool {
      // This is the original public NativeSource path, not RendererV3.develop in a new F32 context.
      try canonicalRender()
    }
    let result=try autoreleasepool {
      defer { self.context.clearCaches();transportContext.clearCaches() }
      guard let original,original.bytes>0,original.bytes<=layout.bytes,
        original.outputSize==CGSize(width:layout.width,height:layout.height),
        let cg=original.image.cgImage(forProposedRect:nil,context:nil,hints:nil),
        cg.width==layout.width,cg.height==layout.height,cg.bitsPerComponent==8,cg.bitsPerPixel==32,
        cg.bytesPerRow>=layout.width*4,cg.bytesPerRow<=layout.rowBytes else { throw PreviewPresentationError.allocationProtocol }
      // Test-only synchronous observation of the already-owned compact bitmap. It cannot replace
      // pixels; errors follow the existing joined failure path. Product callers always pass nil.
      if let qaNeutralPretransportObserver {
        try check();try qaNeutralPretransportObserver(original);try check()
      }
      // Pure display transport of the already canonical bitmap. No native graph is replayed
      // under this F32 context; no neutral base/cache is created as an alternative decoder.
      let image=CIImage(cgImage:cg)
      try check()
      return try output.materialize(image,context:transportContext,nativeSize:original.nativeSize,
        fallback:canonicalReason.rawValue,check:check)
    }
    // Both autorelease pools and their CG/CI/task aliases have drained. The last explicit
    // original image owner is cleared BEFORE its conservative temporary reservation.
    let grainTransport=original?.actualGrainFinalTransport
    original=nil
    var receipt=PreviewNativePointwiseReceiptV1(certified:false,sourceCold:false,samplerCold:false,
      fullNativeChecks:nil,owner:nil,reason:canonicalReason.rawValue)
    receipt.canonicalGrainFinalTransport=grainTransport
    if canonicalReason == .grainCanonical { receipt.proofID=PreviewNativePointwiseCertificateV2.version }
    return result.nativePointwiseReceipt(receipt)
  }
  /// Runs solely on the service's existing native worker. Every task is synchronously joined.
  func renderNativePointwise(recipe: DevelopmentRecipe,maxPixel: Int,plan: PreviewNativePointwisePlanV1,
                             pool: PreviewRawBasePool?,scope: PreviewPresentationScope,memoryLimit: Int,
                             cancellation: DevelopmentAnalysisCancellation,thumbnailNativeSink:((CIImage)throws->Void)? = nil,
                             qaIPTiming:PreviewQALifecycleTrace.IPTiming? = nil,qaSkipJoinedOutputClear:Bool = false,qaSharedFITIntermediate:Bool = false,qaNeutralPretransportObserver:(@Sendable(PreviewPixels)throws->Void)? = nil,canonicalRender: () throws -> PreviewPixels) throws -> PreviewPixels {
    try recipe.validate();try validateCaptureAuthority();try cancellation.check();try scope.requireOpenAdmission()
    guard memoryLimit==512 else { throw PreviewPresentationError.unsupported }
    guard qaNeutralPretransportObserver == nil || plan.neutralOwnerBootstrap else {throw PreviewPresentationError.allocationProtocol}
    if plan.canonicalGlobalFiniteProofEnabled {
      guard plan.canonicalFullChecks,
        plan.canonicalGlobalRecipeBinding == (try PreviewNativePointwiseCertificateV2.Binding(recipe)) else {throw PreviewPresentationError.allocationProtocol}
    }
    let qaIdle=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
    self.context.clearCaches()
    if let qaIdle{qaIPTiming?.idleClear(qaIdle)}
    guard let device=MTLCreateSystemDefaultDevice(),device.hasUnifiedMemory else { throw PreviewPresentationError.unsupported }
    if plan.neutralOwnerBootstrap {
      guard !plan.canonicalFullChecks,!plan.canonicalGlobalFiniteProofEnabled,!plan.preserveVerifiedInput,
        !plan.semanticLegacy,plan.fallback == nil,let descriptor=plan.descriptor else {throw PreviewPresentationError.allocationProtocol}
      if let pool,let result=try PreviewNeutralOwnerBootstrapV1.withInput(native:self,recipe:recipe,maxPixel:maxPixel,
          descriptor:descriptor,pool:pool,scope:scope,device:device,cancellation:cancellation,body:{ input,cold in
        try autoreleasepool {
          // The verified F32 owner is for the next actual adjustment. Preserve the original
          // lazy-source neutral graph; its separate evaluation is included in request cost/peak.
          let transport=CIContext(mtlDevice:device,options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
            .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryLimit])
          defer{transport.clearCaches();self.context.clearCaches()}
          let check:()throws->Void={try cancellation.check();try scope.requireOpenAdmission();try self.validateCaptureAuthority()}
          let result=try nativePointwiseLegacyDelegate(canonicalRender:{
            try check()
            return try canonicalRender()
          },layout:plan.outputLayout,scope:scope,device:device,transportContext:transport,check:check,qaNeutralPretransportObserver:qaNeutralPretransportObserver)
          try check()
          var receipt=PreviewNativePointwiseReceiptV1(certified:false,sourceCold:cold,samplerCold:false,
            fullNativeChecks:nil,owner:input.ownerIncarnation,reason:PreviewNeutralOwnerBootstrapV1.version)
          receipt.proofID=PreviewNeutralOwnerBootstrapV1.version
          return result.nativePointwiseReceipt(receipt)
        }
      }) {return result}
      // Disabled pool or exact capacity refusal occurred before a new source fill. Preserve delegate.
      return try canonicalRender()
    }
    func makeContext() -> CIContext {
      let began=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
      let created=CIContext(mtlDevice:device,options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
        .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryLimit])
      if let began{qaIPTiming?.created(began)};return created
    }
    // Do not instantiate post context while a cold decoder/fill context is still alive.
    // Fallbacks use the same options, and a resident hit goes directly to this post scope.
    var renderContext: CIContext? = nil
    var canonicalContextOwner:PreviewCanonicalFiniteContextV1? = nil
    var context: CIContext {
      if let renderContext { return renderContext }
      if plan.canonicalFullChecks && (plan.canonicalGlobalFiniteProofEnabled || plan.canonicalNaturalFiniteProofEnabled) {
        let owner=PreviewCanonicalFiniteContextV1.make(device:device)
        canonicalContextOwner=owner;renderContext=owner.context;return owner.context
      }
      let created=makeContext();renderContext=created;return created
    }
    defer { let began=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
      renderContext?.clearCaches();renderContext=nil;canonicalContextOwner=nil
      if let began{qaIPTiming?.clear(began)} }
    let check: () throws -> Void = { try cancellation.check();try scope.requireOpenAdmission() }
    let inputCheck: () throws -> Void = {
      if plan.preserveVerifiedInput { try cancellation.checkInputAuthority() } else { try cancellation.check() }
      try scope.requireOpenAdmission()
    }
    let reason=plan.fallback ?? (pool == nil ? .nativePoolDisabled:nil)
    if let reason {
      _ = context // Preserve the existing whole-fallback context before its work/reservations.
      // Do not force a cache path or evict its warm input here. NativeSource.render retains
      // the normal requested policy and its own capacity/ineligible/disabled fallback semantics.
      let result=try nativePointwiseLegacyDelegate(canonicalRender:canonicalRender,layout:plan.outputLayout,
        scope:scope,device:device,transportContext:context,check:check,thumbnailNativeSink:thumbnailNativeSink,canonicalReason:reason)
      try validateCaptureAuthority();try check();return result
    }
    guard let pool,let descriptor=plan.descriptor,let grid=plan.grid,let p=recipe.adjustmentsV3,
      descriptor.captureID==captureID,descriptor.deviceRegistryID==device.registryID,
      (plan.naturalCurveBinding != nil ? try PreviewNaturalCurveFiniteEvidenceV1.domain(recipe,size:nativeSize):try PreviewNativePointwiseV1.routeEligibility(recipe,size:nativeSize)==nil) else { throw PreviewPresentationError.allocationProtocol }
    guard plan.commonPointBinding == (try PreviewNativePointwiseCertificateV2.binding(recipe,size:nativeSize)) else { throw PreviewPresentationError.allocationProtocol }
    if let binding=plan.naturalCurveBinding {
      guard plan.canonicalFullChecks,!plan.canonicalGlobalFiniteProofEnabled,binding == (try PreviewNaturalCurveFiniteEvidenceV1.Binding(recipe)) else{throw PreviewPresentationError.allocationProtocol}
      try PreviewNaturalCurveFiniteEvidenceV1.verify(recipe,native:self,descriptor:descriptor)
    } else if plan.preserveVerifiedInput || plan.canonicalFullChecks {
      try PreviewNativeInputProfileV1.verify(recipe,native:self,descriptor:descriptor)
    }
    let authority=try descriptor.fingerprint()
    var pin=pool.acquirePointwiseResident(descriptor)
    defer { let began=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
      renderContext?.clearCaches();renderContext=nil;canonicalContextOwner=nil
      if let began{qaIPTiming?.clear(began)}
      pin?.releaseAfterJoinedPipeline();pin=nil }
    let sourceCold=pin==nil
    if sourceCold {
      try inputCheck()
      try pool.checkpoint("idle-canonical-context/retire-before")
      retireIdleCanonicalContextForIndependentWork()
      // The old joined canonical context's explicit owner and autoreleases have
      // ended before ANY new cold storage/guard allocation. Private driver pools
      // remain actually measured; this never claims their byte count is zero.
      try pool.checkpoint("idle-canonical-context/retire-after")
      try inputCheck()
    }
    var samplerKey: PreviewNativePointwiseCertificateV1.Sampler? {
      guard let owner=pin?.ownerIncarnation else { return nil }
      if plan.naturalCurveBinding != nil{return PreviewNaturalCurveFiniteEvidenceV1.sampler(owner:owner,authority:authority,grid:grid,descriptor:descriptor)}
      return .init(owner:owner,authority:authority,grid:grid,device:device.registryID,
        pointSHA256:DevelopmentColorEngineV3.sourceSHA256,
        witnessSHA256:PreviewNativePointwiseCertificateV1.witnessSHA256,
        samplerABI:plan.commonPointBinding == nil ? PreviewNativePointwiseCertificateV1.samplerVersion:PreviewNativePointwiseCertificateV2.samplerVersion,os:descriptor.os,optionsVersion:PreviewNativePointwiseV1.contextVersion)
    }
    let samplerCold = (plan.canonicalNaturalFiniteProofEnabled || plan.canonicalGlobalFiniteProofEnabled || !plan.canonicalFullChecks) && (pin==nil || pin?.pointwiseSamplerCertificate != samplerKey)
    let scratchLayout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
    let guardBytes=try RawBaseStorage.layout(width:grid.width,height:grid.height).bytes
    // The native owner is charged by the ONE 1GiB pool; only compact guard/output/scratch
    // and bounded metadata enter the existing shared CPU256/GPU128 presentation union.
    var reservations=[plan.outputLayout.bytes,scratchLayout.bytes,plan.naturalCurveBinding == nil ? 65536:262144]
    if samplerCold { reservations.append(guardBytes) }
    let tickets=try scope.reserveSharedOperation(bytes:reservations)
    defer { tickets[2].releaseAfterStorageReleased() }
    let output=PreviewInteractiveManagedOutput(layout:plan.outputLayout,ticket:tickets[0],device:device)
    let scratch=try PreviewInteractiveProxyStorage(layout:scratchLayout,ticket:tickets[1],device:device)
    scratch.qaIPTiming=qaIPTiming;scratch.qaIPPurpose = .fitCheck;output.qaIPTiming=qaIPTiming
    do {
      if pin==nil {
        try check() // Do not start a source build for a frame already superseded.
        let publicationGate: ((() -> RawBasePin) throws -> RawBasePin)? = plan.preserveVerifiedInput ? { publish in
          try cancellation.withInputPublication(publish)
        }:nil
        pin=try pool.acquirePointwise(descriptor,publicationGate:publicationGate) { storage in
          try inputCheck();try pool.checkpoint("pointwise-native-fill/before")
          try autoreleasepool {
            // Only this scope owns the cold context and input graph. Nothing returns
            // either into the post scope; the already charged F32 storage is the boundary.
            var coldContext: CIContext?=makeContext()
            defer { coldContext?.clearCaches();coldContext=nil }
            try inputCheck();let input=try PreviewNativePointwiseBaseV1.input(self,descriptor:descriptor)
            try storage.fill(input,context:coldContext!,mode:.whole,checkpoint:{ label in
              try inputCheck();try pool.checkpoint(label)
            },pointwiseAuthority:authority)
            try validateCaptureAuthority();try inputCheck()
            try pool.checkpoint("pointwise-native-fill/joined-scanned")
            try pool.checkpoint("pointwise-cold-context/retire-before")
          }
          // Above: real task joined, CPU scan/authority complete, input/context strong
          // refs ended and autoreleases drained. This does NOT assert CI-private pools0.
          try pool.checkpoint("pointwise-cold-context/retire-after")
          try inputCheck();try validateCaptureAuthority()
        }
      }
      guard let acquired=pin,let inputCertificate=acquired.pointwiseInputCertificate,
        inputCertificate.owner==acquired.ownerIncarnation,inputCertificate.authority==authority else { throw PreviewPresentationError.allocationProtocol }
      try check();try pool.checkpoint("pointwise-post/prepare-before")
      _ = context // First post context creation is AFTER the successful cold scope has drained.
      return try autoreleasepool {
        if plan.canonicalFullChecks {
          // Same immutable source owner; canonical authority comes from the REAL renderer
          // with either its original scans or the separately enabled named-stage evidence.
          let base=try acquired.image
          let suppliedImage:DevelopmentSuppliedImageBaseV1?
          if hasRAWFilter { suppliedImage=nil }
          else {
            guard let depth=descriptor.sourceDepth,depth>0 else { throw PreviewPresentationError.allocationProtocol }
            suppliedImage = .init(image:base,sourceDepth:depth)
          }
          if plan.naturalCurveBinding != nil {
            if samplerCold {
              if inputCertificate.eligible && grid.envelopeClosed {
                let passed=try autoreleasepool { () throws -> Bool in
                  defer{context.clearCaches()}
                  let guardOwner=try PreviewNativePointwiseGuardV1(grid:grid,ticket:tickets[3])
                  let witness=try PreviewNativePointwiseCertificateV1.vetoImage(base)
                  return try guardOwner.veto(PreviewNativePointwiseV1.fit(witness,grid:grid),context:context,check:check)
                }
                if passed{acquired.pointwiseSamplerCertificate=samplerKey}
              }else{tickets[3].releaseAfterStorageReleased()}
            }
            let observation=PreviewNaturalCurveFiniteObservation()
            return try PreviewNaturalCurveFiniteEvidenceV1.withEvidence(native:self,pin:acquired,base:base,
              contextOwner:plan.canonicalNaturalFiniteProofEnabled ? canonicalContextOwner:nil,
              descriptor:descriptor,grid:grid,recipe:recipe,check:check) { evidence in
              let graph=try DevelopmentRendererV3.develop(capture,recipe:recipe,suppliedRawBase:base,
                context:context,thumbnailNativeSink:thumbnailNativeSink,canonicalNaturalEvidence:evidence,
                naturalFiniteObservation:observation,checkCancellation:check)
              let proven=evidence?.consumed==true
              let sharedFIT=PreviewNativePointwiseV1.naturalSharedFITEligible(requested:qaSharedFITIntermediate,
                proven:proven,synthetic:evidence?.syntheticOnly ?? true,sourceCold:sourceCold,samplerCold:samplerCold)
              var outputGraph=graph
              if proven {
                let prepared=try PreviewNativePointwiseV1.prepareNaturalFIT(graph,grid:grid,insertingIntermediate:sharedFIT)
                try PreviewInteractiveProxyV3.validate(prepared.checkedFIT,using:scratch,context:context,check:check)
                outputGraph=prepared.outputGraph
              }
              let result=try V3PreviewMaterializer.materialize(outputGraph,context:context,maxPixel:maxPixel,managedOutput:output,managedCheck:check)
              try validateCaptureAuthority();try check();context.clearCaches();try pool.checkpoint("natural-canonical/output-joined")
              var receipt=PreviewNativePointwiseReceiptV1(certified:false,sourceCold:sourceCold,samplerCold:samplerCold,
                fullNativeChecks:nil,owner:acquired.ownerIncarnation,reason:nil)
              receipt.proofID=PreviewNaturalCurveFiniteEvidenceV1.version;receipt.canonicalFullChecks = !proven
              receipt.sharedFITIntermediateInserted=sharedFIT
              receipt.canonicalNaturalFITTransport=sharedFIT ? PreviewNativePointwiseV1.naturalSharedFITVersion:nil
              receipt.canonicalNaturalGlobalScans=observation.joinedGlobalScans;receipt.canonicalNaturalProofConsumptions=evidence?.consumptionCount ?? 0
              if proven,let evidence {
                receipt.canonicalGlobalFiniteProofID=PreviewNaturalCurveFiniteEvidenceV1.version
                receipt.canonicalGlobalFiniteBinding=evidence.bindingFingerprint;receipt.canonicalGlobalFiniteStage=PreviewNaturalCurveFiniteEvidenceV1.stage
                receipt.canonicalProofFITChecked=true;receipt.canonicalNaturalLUTSHA256=evidence.actualLUTSHA256
                receipt.canonicalNaturalSynthetic=evidence.syntheticOnly
              }
              return result.nativePointwiseReceipt(receipt)
            }
          }
          var samplerVetoed=false
          if plan.canonicalGlobalFiniteProofEnabled && samplerCold {
            let closed = plan.commonPointBinding == nil ? grid.envelopeClosed:PreviewNativePointwiseCertificateV2.samplerEnvelopeClosed(grid)
            if inputCertificate.eligible && closed &&
              DevelopmentColorEngineV3.sourceSHA256==PreviewNativePointwiseCertificateV1.pointSourceSHA256 {
              try check();try pool.checkpoint("canonical-sampler-veto/before")
              let passed=try autoreleasepool { () throws -> Bool in
                defer{context.clearCaches()}
                let guardOwner=try PreviewNativePointwiseGuardV1(grid:grid,ticket:tickets[3])
                let witness=try PreviewNativePointwiseCertificateV1.vetoImage(base)
                return try guardOwner.veto(PreviewNativePointwiseV1.fit(witness,grid:grid),context:context,check:check)
              }
              samplerVetoed=true
              // The guard task and its private storage have joined before publication.
              try pool.checkpoint("canonical-sampler-veto/joined")
              try check();try validateCaptureAuthority()
              if passed{acquired.pointwiseSamplerCertificate=samplerKey}
            }else{tickets[3].releaseAfterStorageReleased()}
          }
          return try PreviewCanonicalFiniteEvidenceV1.withEvidence(native:self,pin:acquired,base:base,
            contextOwner:plan.canonicalGlobalFiniteProofEnabled ? canonicalContextOwner:nil,
            descriptor:descriptor,grid:grid,recipe:recipe,check:check) { evidence in
            let graph=try DevelopmentRendererV3.develop(capture,recipe:recipe,
              suppliedRawBase:hasRAWFilter ? base:nil,suppliedImageBase:suppliedImage,
              context:context,thumbnailNativeSink:thumbnailNativeSink,canonicalFiniteEvidence:evidence,checkCancellation:check)
            let proven=evidence?.consumed==true
            let sharedFIT=PreviewNativePointwiseV1.canonicalSharedFITEligible(requested:qaSharedFITIntermediate,
              proven:proven,sourceCold:sourceCold,samplerCold:samplerCold)
            var outputGraph=graph
            if proven {
              // The original joined FIT check remains mandatory. Only the opt-in warm
              // proven path shares its exact checked node with this invocation's output.
              let fitted=PreviewNativePointwiseV1.fit(graph.image,grid:grid)
              guard fitted.extent==grid.extent else{throw PreviewPresentationError.allocationProtocol}
              let checked=PreviewNativePointwiseV1.joinedFITImage(fitted,insertingIntermediate:sharedFIT)
              guard checked.extent==grid.extent else{throw PreviewPresentationError.allocationProtocol}
              try PreviewInteractiveProxyV3.validate(checked,using:scratch,context:context,check:check)
              if sharedFIT {
                outputGraph = .init(image:checked,sourceDepth:graph.sourceDepth,sourceSize:graph.sourceSize,
                  canonicalSize:graph.canonicalSize,graphDescriptor:graph.graphDescriptor+"/"+PreviewNativePointwiseV1.canonicalSharedFITVersion)
              }
            }
            let result=try V3PreviewMaterializer.materialize(outputGraph,context:context,maxPixel:maxPixel,
              managedOutput:output,managedCheck:check)
            try validateCaptureAuthority();try check();context.clearCaches()
            try pool.checkpoint("pointwise-post/output-joined")
            var receipt=PreviewNativePointwiseReceiptV1(certified:false,sourceCold:sourceCold,samplerCold:samplerVetoed,
              fullNativeChecks:nil,owner:acquired.ownerIncarnation,reason:nil)
            receipt.canonicalFullChecks = !proven;receipt.proofID=plan.proofID
            receipt.sharedFITIntermediateInserted=sharedFIT
            receipt.canonicalGlobalFITTransport=sharedFIT ? PreviewNativePointwiseV1.canonicalSharedFITVersion:nil
            if proven,let evidence {
              receipt.canonicalGlobalFiniteProofID=PreviewCanonicalFiniteEvidenceV1.version
              receipt.canonicalGlobalFiniteBinding=evidence.bindingFingerprint
              receipt.canonicalGlobalFiniteStage=PreviewCanonicalFiniteEvidenceV1.stage
              receipt.canonicalProofFITChecked=true
            }
            return result.nativePointwiseReceipt(receipt)
          }
        }
        let envelopeClosed=plan.commonPointBinding == nil ? grid.envelopeClosed:PreviewNativePointwiseCertificateV2.samplerEnvelopeClosed(grid)
        var certified=inputCertificate.eligible && envelopeClosed &&
          DevelopmentColorEngineV3.sourceSHA256==PreviewNativePointwiseCertificateV1.pointSourceSHA256
        var didVeto=false
        if samplerCold {
          if certified {
            var guardOwner: PreviewNativePointwiseGuardV1?
            defer { guardOwner=nil }
            // Drain task/destination/CI graph aliases BEFORE the guard owner retires its charge.
            certified=try autoreleasepool {
              defer { context.clearCaches() }
              guardOwner=try PreviewNativePointwiseGuardV1(grid:grid,ticket:tickets[3])
              let witness=try PreviewNativePointwiseCertificateV1.vetoImage(acquired.image)
              let fitted=PreviewNativePointwiseV1.fit(witness,grid:grid)
              let passed=try guardOwner!.veto(fitted,context:context,check:check)
              context.clearCaches();return passed
            }
            guardOwner=nil;didVeto=true
          } else { tickets[3].releaseAfterStorageReleased() }
          if certified { acquired.pointwiseSamplerCertificate=samplerKey }
        } else {
          certified = certified && acquired.pointwiseSamplerCertificate==samplerKey
        }
        qaIPTiming?.route(sourceCold:sourceCold,samplerCold:didVeto,certified:certified)
        try check()
        let qaGraph=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
        var image=try PreviewNativePointwiseV1.prefix(p,input:acquired.image,sourceIsRAW:hasRAWFilter,context:context,check:check)
        var fullChecks=0
        let normalizeFITCoverage = plan.mayNormalizeFITCoverage && !certified
        if !certified && !normalizeFITCoverage {
          try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:check)
          fullChecks+=1
        }
        image=try PreviewNativePointwiseV1.geometry(p,input:image,context:context,check:check)
        if normalizeFITCoverage {
          guard hasRAWFilter, plan.fitCoverageGeometryVersion == p.geometry.version,
                image.extent == CGRect(origin:.zero,size:nativeSize),
                image.extent == CGRect(x:0,y:0,width:grid.nativeWidth,height:grid.nativeHeight) else {
            throw PreviewPresentationError.allocationProtocol
          }
          // Use the same normalized native graph for strict validation and the following FIT.
          image=try PreviewFITCoverageV1.normalize(image,extent:image.extent)
          try DevelopmentLocalEngineV3.validatePixels(image,context:context,checkCancellation:check)
          fullChecks+=1
        } else if !certified,p.geometry.version != .legacyV1,p.geometry.version != .legacyV2 {
          try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:check);fullChecks+=1
        }
        let final=PreviewNativePointwiseV1.fit(image,grid:grid)
        guard final.extent==grid.extent else { throw PreviewPresentationError.allocationProtocol }
        let sharedFIT=qaSharedFITIntermediate && certified && !sourceCold && !samplerCold
        let checkedFIT = normalizeFITCoverage ? try PreviewFITCoverageV1.normalize(final,extent:grid.extent)
          : PreviewNativePointwiseV1.joinedFITImage(final,insertingIntermediate:sharedFIT)
        guard checkedFIT.extent==grid.extent else{throw PreviewPresentationError.allocationProtocol}
        if let qaGraph{qaIPTiming?.graph(qaGraph)}
        // Final actual FIT finite/alpha readback is ALWAYS joined, including warm proof hits.
        let qaFit=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
        try PreviewInteractiveProxyV3.validate(checkedFIT,using:scratch,context:context,check:check)
        if let qaFit{qaIPTiming?.fit(qaFit)}
        let version:String
        if plan.commonPointBinding != nil {
          version=certified ? PreviewNativePointwiseCertificateV2.routeVersion:PreviewNativePointwiseCertificateV2.fullValidationVersion
        } else { version=certified ? PreviewNativePointwiseV1.version:PreviewNativePointwiseV1.fullValidationVersion }
        let fitTransport = normalizeFITCoverage ? PreviewFITCoverageV1.version : nil
        let actualVersion=sharedFIT ? version+"/"+PreviewNativePointwiseV1.sharedFITIntermediateVersion
          : fitTransport.map { version+"/"+$0 } ?? version
        let approximation=PreviewApproximationInfo(version:actualVersion,nativeInputSize:nativeSize,proxyInputSize:nativeSize,
          canonicalCanvasSize:nativeSize,outputPixelSize:grid.extent.size,nativeToProxyScale:1)
        // The materializer sees the same checked FIT node and skips its affine on these transports.
        let graph=DevelopedV3Graph(image:(sharedFIT || normalizeFITCoverage) ? checkedFIT:image,sourceDepth:nil,sourceSize:nativeSize,canonicalSize:nativeSize,
          graphDescriptor:actualVersion+"/"+DevelopmentColorEngineV3.operatorVersion)
        // Use the EXISTING managed branch; the default materializer body is untouched.
        let qaOutput=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
        let result=try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:maxPixel,
          managedOutput:output,managedFallbackReason:certified ? nil:PreviewNativePointwiseV1.Reason.certificateDomain.rawValue,managedCheck:check)
        if let qaOutput{qaIPTiming?.output(qaOutput)}
        try validateCaptureAuthority();try check()
        // Research-only opt-in: the warm certified IP output and FIT tasks have
        // already joined. The unchanged inner defer still clears/releases this
        // context before releasing the input pin. A skipped clear is not timed.
        if !(qaSkipJoinedOutputClear && certified && !sourceCold && !samplerCold) {
          let qaClear=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
          context.clearCaches()
          if let qaClear{qaIPTiming?.clear(qaClear)}
        }
        try pool.checkpoint("pointwise-post/output-joined")
        var receipt=PreviewNativePointwiseReceiptV1(certified:certified,sourceCold:sourceCold,samplerCold:didVeto,
          fullNativeChecks:fullChecks,owner:acquired.ownerIncarnation,reason:certified ? nil:PreviewNativePointwiseV1.Reason.certificateDomain.rawValue)
        receipt.proofID=plan.proofID;receipt.sharedFITIntermediateInserted=sharedFIT
        receipt.fitCoverageTransport = fitTransport
        return result.nativePointwiseReceipt(receipt,approximation:approximation)
      }
    } catch {
      let qaClear=qaIPTiming.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
      renderContext?.clearCaches();renderContext=nil;canonicalContextOwner=nil
      if let qaClear{qaIPTiming?.clear(qaClear)}
      // Preserve ONLY a joined, verified source owner on a frame-only failure. Actual
      // source/pressure/close revocation and any backend/nonfinite error still retire.
      var frameOnly=false
      if plan.preserveVerifiedInput,PreviewNativeInputProfileV1.frameFailure(error) {
        do {
          try validateCaptureAuthority();try scope.requireOpenAdmission();try cancellation.checkInputAuthority()
          frameOnly=cancellation.isFrameOnlyCancellation
          if frameOnly,pin?.pointwiseInputCertificate?.authority==authority {
            _ = cancellation.recordPreservedInputIfFrameOnly()
          }
        } catch { frameOnly=false }
      }
      pin?.releaseAfterJoinedPipeline();pin=nil
      // A pre-build frame cancellation also must not retire other verified same-source
      // entries. Destructive commands remain actor-fenced and retire before the next pump.
      if !frameOnly { pool.retire(sourceKey:descriptor.sourceKey) }
      do { try validateCaptureAuthority() } catch { throw error }
      throw error
    }
  }
}
