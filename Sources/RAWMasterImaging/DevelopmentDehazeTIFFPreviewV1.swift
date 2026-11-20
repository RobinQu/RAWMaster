import AppKit
import CoreImage
import ImageIO
import Foundation
import RAWMasterCore

/// Preview-only, default-off contract. Export and persisted recipes retain their old meaning.
enum DevelopmentDehazeTIFFPreviewV1 {
  static let version="dehaze-positive-v2-opaque-TIFF-consistent-rf256-bank128-v1"
  static func bootstrap(bundleIdentifier:String?,environment:[String:String])->Bool{
    bundleIdentifier=="io.robinqu.RAWMaster.preview022" && environment["RAWMASTER_QA_DEHAZE_TIFF_PREVIEW_V1"]=="1"
  }
  static func makeContext()->CIContext{
    CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
  }
  static func recipeDomain(_ recipe:DevelopmentRecipe)->Bool{
    guard let p=recipe.adjustmentsV3,DevelopmentDehazeEngineV3.usesPositiveV2(p.advancedDetail),
      p.advancedDetail.dehaze.amount==25,p.legacyBasis?.isPixelNeutral ?? true else{return false}
    var geometry=p.geometry;geometry.version = .adjustV3
    guard geometry==DevelopmentGeometryV3() else{return false}
    var advanced=p.advancedDetail;advanced.dehaze = .init();advanced.preparedDehaze=nil
    guard advanced==DevelopmentAdvancedDetailV3() else{return false}
    var rest=p;rest.advancedDetail = .init();rest.geometry = .init();rest.legacyBasis=nil
    return rest==DevelopmentAdjustmentsV3()
  }
  static func sourceDomain(_ native:PreviewNativeSource)->Bool{
    guard !native.hasRAWFilter,!native.artifact,native.byteCount>0,native.byteCount<=512*1024*1024,native.nativePointwiseImageDepth==16,
      native.nativePointwiseImageICCIdentity?.hasPrefix("decoded-ICC-present:"+PreviewWindows.icc+":")==true,
      native.orientedNativeExtent.origin == .zero,native.orientedNativeExtent==native.orientedNativeExtent.integral,
      native.nativeSize.width>0,native.nativeSize.height>0,native.nativeSize.width<=9504,native.nativeSize.height<=6336,
      let input=CGImageSourceCreateWithURL(native.capture as CFURL,nil),
      let kind=CGImageSourceGetType(input),kind as String == "public.tiff" else{return false}
    return true
  }
  enum Phase:Sendable,Equatable{case inputJoined,prefixRetired,scalarSubmitted,scalarJoined,providerReady,bankJoined}
  struct Request{
    let id=UUID()
    let scope:PreviewPresentationScope
    let check:()throws->Void
    var observer:((Phase)throws->Void)?=nil
    func requireCurrent()throws{try Task.checkCancellation();try check();try scope.requireOpenAdmission()}
    func observe(_ phase:Phase)throws{try observer?(phase)}
  }
  struct Observation{
    let version:String,planeSHA256:String?,fallbackReason:String?
    let sourceBytes:Int64,scratchPeakBytes:Int
    let scratchReleased:Bool
  }
  enum Admission:Equatable{case opaque,legalNonopaque}
  enum RouteError:Error{case legalNonopaque}
  enum RenderOutcome{case produced(PreviewPixels),legacyFallback(Observation)}
  /// Separate components distinguish actual malformed alpha from a legal nonopaque fallback.
  /// This is a validation mask only; it is never inserted into the pixel graph.
  static let admissionMetal = #"""
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmDehazeTIFFAdmissionV1(sampler input) {
  float4 p=input.sample(input.coord());
  float finite=all(isfinite(p))?0.0:1.0;
  float invalidAlpha=(!isfinite(p.a)||p.a<0.0||p.a>1.0)?1.0:0.0;
  return float4(finite,invalidAlpha,p.a!=1.0?1.0:0.0,0.0);
}
}}
"""#
  static func classify(_ image:CIImage,context:CIContext,request:Request)throws->Admission{
    try request.requireCurrent()
    // Invocation callers have already completed the unchanged full finite checks.
    // Keep finite and alpha range explicit here too; nonopaque is never a catch-all error.
    let kernels=try CIKernel.kernels(withMetalString:admissionMetal)
    guard let kernel=kernels.first(where:{$0.name=="rmDehazeTIFFAdmissionV1"}),
      let mask=kernel.apply(extent:image.extent,roiCallback:{_,r in r},arguments:[image.samplingNearest()]) else{throw DevelopmentV3Error.invalidGraph}
    let value=try DevelopmentCheckedMaximumV3.maximum(mask,domain:image.extent,context:context,checkCancellation:request.requireCurrent)
    try request.requireCurrent()
    guard value.x==0,value.y==0,value.w==0 else{throw DevelopmentError.invalidEncoding}
    guard value.z==0 || value.z==1 else{throw DevelopmentError.invalidEncoding}
    return value.z==0 ? .opaque:.legalNonopaque
  }
  /// All candidate CI objects and providers are scoped to this synchronous, joined worker call.
  static func render(native:PreviewNativeSource,recipe:DevelopmentRecipe,request:Request,
    thumbnailNativeSink:((CIImage)throws->Void)?)throws->RenderOutcome{
    try request.requireCurrent()
    guard recipeDomain(recipe),sourceDomain(native) else{throw PreviewPresentationError.unsupported}
    let invocation=try DevelopmentDehazeTIFFInvocationV1(capture:native.capture,recipe:recipe,request:request)
    var pixels:PreviewPixels?,failure:Error?
    do{
      pixels=try autoreleasepool{
        defer{invocation.clearCurrentCaches()}
        let graph=try DevelopmentRendererV3.develop(native.capture,recipe:recipe,thumbnailNativeSink:thumbnailNativeSink,
          dehazeTIFFInvocation:invocation,checkCancellation:request.requireCurrent)
        return try V3PreviewMaterializer.materialize(graph,context:invocation.currentContext,maxPixel:2400,dehazeTIFFInvocation:invocation)
      }
    }catch{failure=error}
    // Even cancellation or fallback cannot release a live provider or skip a failed close.
    do{try invocation.finish()}catch{
      if let failure{throw NSError(domain:"RAWMaster.DehazeTIFFCleanup",code:1,userInfo:[NSUnderlyingErrorKey:failure,"cleanupError":error])}
      throw error
    }
    if let failure{
      if let route=failure as? RouteError,case .legalNonopaque=route{
        try request.requireCurrent();try native.validateCaptureAuthority()
        return .legacyFallback(.init(version:version,planeSHA256:nil,fallbackReason:"legal-nonopaque",
          sourceBytes:invocation.scratch.sourceBytes,scratchPeakBytes:invocation.scratch.planeBytes,scratchReleased:true))
      }
      throw failure
    }
    try request.requireCurrent();try native.validateCaptureAuthority()
    guard let pixels else{throw DevelopmentV3Error.invalidGraph}
    return .produced(pixels.recordingDehazeTIFF(.init(version:version,planeSHA256:invocation.planeSHA256,fallbackReason:nil,
      sourceBytes:invocation.scratch.sourceBytes,scratchPeakBytes:invocation.scratch.planeBytes,scratchReleased:true)))
  }
}

final class DevelopmentDehazeTIFFInvocationV1 {
  let request:DevelopmentDehazeTIFFPreviewV1.Request
  let scratch:DehazeRfScratchV1
  let state=DehazeRfStateV1()
  private let capture:URL,recipeFingerprint:String
  private var owner:CIContext?,provider:DehazeRfProviderV1?
  private var applied=false,finished=false
  private(set) var planeSHA256:String?
  init(capture:URL,recipe:DevelopmentRecipe,request:DevelopmentDehazeTIFFPreviewV1.Request)throws{
    self.capture=capture;self.request=request;recipeFingerprint=try EditingFingerprint.of(recipe)
    guard let size=recipe.adjustmentsV3?.advancedDetail.preparedDehaze?.sourceBinding.sourceSize else{throw DevelopmentDehazePreparationError.preparationRequired}
    scratch=try DehazeRfScratchV1(capture:capture,width:size.width,height:size.height)
    owner=autoreleasepool{DevelopmentDehazeTIFFPreviewV1.makeContext()}
  }
  var currentContext:CIContext{owner!}
  func clearCurrentCaches(){owner?.clearCaches()}
  func requireRequest(_ source:URL,recipe:DevelopmentRecipe,sourceIsRAW:Bool,applyGeometry:Bool)throws{
    guard source==capture,!sourceIsRAW,applyGeometry,DevelopmentDehazeTIFFPreviewV1.recipeDomain(recipe),
      try EditingFingerprint.of(recipe)==recipeFingerprint else{throw DevelopmentV3Error.invalidGraph}
    try request.requireCurrent()
  }
  func apply(_ parameters:DevelopmentAdvancedDetailV3,to image:CIImage,sourceSize:DevelopmentPixelSize)throws->CIImage{
    try parameters.validate();try sourceSize.validate();try request.requireCurrent()
    guard !applied,parameters.dehaze.enabled,parameters.dehaze.amount==25,
      DevelopmentDehazeEngineV3.usesPositiveV2(parameters),let prepared=parameters.preparedDehaze,
      prepared.sourceBinding.sourceSize==sourceSize,image.extent==CGRect(x:0,y:0,width:scratch.width,height:scratch.height) else{throw DevelopmentV3Error.invalidGraph}
    try prepared.validate();applied=true
    // Original pre-effect finite scan. The strict guide/restore still reject malformed alpha.
    try DevelopmentColorEngineV3.validateFinite(image,context:currentContext,checkCancellation:request.requireCurrent)
    try request.observe(.inputJoined)
    weak var prefix=owner
    autoreleasepool{owner?.clearCaches();owner=nil}
    guard prefix==nil else{throw PreviewPresentationError.allocationProtocol}
    try request.observe(.prefixRetired);try request.requireCurrent()
    weak var producer:CIContext?
    let producerResult:Result<Void,Error> = Result {
      try autoreleasepool{
        let context=DevelopmentDehazeTIFFPreviewV1.makeContext();producer=context;defer{context.clearCaches()}
        let guide=try DevelopmentDehazeColorGuideV2.guide(image,airlight:prepared.airlight,sourceSize:sourceSize)
        let scalar=try DevelopmentDehazeRfTransportV1.scalar(guide)
        try DevelopmentDehazeRfTransportV1.file(scalar,scratch:scratch,context:context,request:request)
      }
    }
    // Success and failure both leave the real pool before testing context retirement.
    guard producer==nil else{
      if case .failure(let original)=producerResult{
        throw NSError(domain:"RAWMaster.DehazeTIFFCleanup",code:2,
          userInfo:[NSUnderlyingErrorKey:original,"cleanupError":PreviewPresentationError.allocationProtocol])
      }
      throw PreviewPresentationError.allocationProtocol
    }
    try producerResult.get();try request.requireCurrent()
    owner=autoreleasepool{DevelopmentDehazeTIFFPreviewV1.makeContext()}
    let actualProvider=try DehazeRfProviderV1(scratch,state:state);provider=actualProvider
    let sampled=actualProvider.image()
    planeSHA256=try DevelopmentDehazeRfTransportV1.verify(sampled,scratch:scratch,state:state,context:currentContext,request:request)
    try request.observe(.providerReady);try request.requireCurrent()
    let result=try DevelopmentDehazeRfTransportV1.restore(image,sampled,airlight:prepared.airlight,amount:parameters.dehaze.amount)
    try DevelopmentColorEngineV3.validateFinite(result,context:currentContext,checkCancellation:request.requireCurrent)
    try state.check();try request.requireCurrent();return result
  }
  func materialize(_ graph:DevelopedV3Graph,maxPixel:Int)throws->PreviewPixels{
    guard graph.dehazeTIFFRequestID==request.id,maxPixel==2400,applied else{throw PreviewPresentationError.unsupported}
    try request.requireCurrent()
    guard try DevelopmentDehazeTIFFPreviewV1.classify(graph.image,context:currentContext,request:request) == .opaque else{
      throw DevelopmentDehazeTIFFPreviewV1.RouteError.legalNonopaque
    }
    let window=try PreviewWindows.Window.fit(native:graph.image.extent)
    guard window.ci==graph.image.extent,window.maximum==2400 else{throw PreviewPresentationError.unsupported}
    let pair=try PreviewBrillianceBankTransportV1.materializeBands(graph,context:currentContext,window:window,
      scope:request.scope,outerBytes:request.scope.ledger.statistics.chargedCPUBytes,
      check:{_ in try self.request.requireCurrent();try self.state.check()},phase:{_ in},
      observe:{_ in})
    // Observation cannot throw in the bank's publication closure; cancel after the joined bank.
    try request.observe(.bankJoined);try state.check();try request.requireCurrent();return pair.0
  }
  func finish()throws{
    guard !finished else{throw PreviewPresentationError.allocationProtocol};finished=true
    weak var context=owner;weak var reader=provider
    autoreleasepool{owner?.clearCaches();owner=nil;provider=nil}
    guard context==nil,reader==nil else{throw PreviewPresentationError.allocationProtocol}
    if scratch.providerOpened{guard state.storageReleased else{throw PreviewPresentationError.allocationProtocol}}
    try scratch.finish()
    try state.check()
  }
}
