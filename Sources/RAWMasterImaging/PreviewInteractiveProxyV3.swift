import Foundation
import CoreImage
import Metal
import RAWMasterCore

enum PreviewInteractiveProxyV3 {
  static let version="actual-parameters-linear-proxy-v1"
  private static let transportAlphaKernel: Result<CIKernel,Error> = Result {
    let source = #"""
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    [[stitchable]] float4 rmProxyTransportAlpha(sampler src,destination dest) {
      float4 p=src.sample(src.transform(dest.coord()));
      return float4(p.rgb,clamp(p.a,0.0,1.0));
    }
    } }
    """#
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries,
      let kernel=try CIKernel.kernels(withMetalString:source).first(where:{$0.name=="rmProxyTransportAlpha"}) else {
      throw DevelopmentError.unsupportedEngine
    }
    return kernel
  }
  /// Normalize only interpolation rounding at the proxy boundary. Canonical/local/advanced
  /// validators retain their original strict alpha contract and never see 1+ULP here.
  fileprivate static func transportAlpha(_ image:CIImage)throws->CIImage {
    guard let result=try transportAlphaKernel.get().apply(extent:image.extent,roiCallback:{_,r in r},arguments:[image.samplingNearest()]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return result
  }
  enum Reason:String,Equatable,Sendable {case schema,artifact,nonRawNoise,definition,sharpen,advanced,local,filter,grain,projective,adaptiveBrilliance}
  enum Support:Equatable {case eligible,canonical(Reason)}
  static func support(_ recipe:DevelopmentRecipe,sourceIsRAW:Bool,allowAdvancedDetail:Bool = false)throws->Support {
    try recipe.validate()
    guard recipe.schemaVersion==3,let p=recipe.adjustmentsV3 else{return .canonical(.schema)}
    try p.noiseReduction.validate(for:sourceIsRAW ? .raw:.image)
    if DevelopmentBrillianceAdaptiveV1.isActive(p.light){return .canonical(.adaptiveBrilliance)}
    if p.geometry.verticalPerspective != 0 || p.geometry.horizontalPerspective != 0{return .canonical(.projective)}
    if p.filter.enabled,p.filter.selection != .original,p.filter.intensity != 0{return .canonical(.filter)}
    if !sourceIsRAW,p.noiseReduction.enabled,p.noiseReduction.nonRawAmount != 0{return .canonical(.nonRawNoise)}
    if p.definition.enabled,p.definition.amount != 0{return .canonical(.definition)}
    if p.sharpen.enabled,p.sharpen.intensity != 0{return .canonical(.sharpen)}
    // Only the main interactive preview opts into proxy-scale Texture/Clarity. Legacy thumbnail
    // and analysis callers keep their original rejection contract. Dehaze always stays canonical.
    if p.advancedDetail.dehaze.enabled,p.advancedDetail.dehaze.amount != 0{return .canonical(.advanced)}
    if !allowAdvancedDetail,p.advancedDetail.hasEffects{return .canonical(.advanced)}
    if DevelopmentLocalEngineV3.active(p.localEdits){return .canonical(.local)}
    if p.blackAndWhite.enabled,p.blackAndWhite.grain != 0{return .canonical(.grain)}
    return .eligible
  }
  static func scale(_ size:CGSize)throws->Double {
    let width=Double(size.width),height=Double(size.height)
    guard width.isFinite,height.isFinite,width>=1,height>=1,width<=Double(DevelopmentLocalEditLimits.maximumSourceDimension),height<=Double(DevelopmentLocalEditLimits.maximumSourceDimension),width==floor(width),height==floor(height) else{throw PreviewPresentationError.invalidLayout}
    return min(1,2400.0/max(width,height))
  }
  static func inputLayout(_ size:CGSize)throws->PreviewInteractiveLayout {
    let s=try scale(size)
    return try .make(width:Int(ceil(Double(size.width)*s)),height:Int(ceil(Double(size.height)*s)),float:true)
  }
  struct Geometry {
    let mapping:DevelopmentGeometryMappingV3
    let transform:CGAffineTransform
    let outputScale:Double
    let layout:PreviewInteractiveLayout
  }
  static func geometry(_ p:DevelopmentGeometryV3,nativeSize:CGSize,inputScale:Double,maxPixel:Int)throws->Geometry {
    guard maxPixel>0,maxPixel<=2400,inputScale>0,inputScale<=1 else{throw PreviewPresentationError.invalidLayout}
    _ = try scale(nativeSize)
    let native=DevelopmentPixelSize(width:Int(nativeSize.width),height:Int(nativeSize.height))
    let mapping=try p.mapping(sourceSize:native),m=mapping.forwardMatrix
    guard p.verticalPerspective==0,p.horizontalPerspective==0,m.count==9,m[6]==0,m[7]==0,m[8]==1 else{throw PreviewPresentationError.unsupported}
    let w=Double(mapping.outputSize.width),h=Double(mapping.outputSize.height)
    let s=min(inputScale,min(1,Double(maxPixel)/max(w,h))),r=s/inputScale
    // Same native TOP-LEFT M: sOut * J(outputHeight) * M * J(nativeHeight) / sIn.
    // Crop/trim/late-D4 were already evaluated by Core on native dimensions, never on rounded FIT.
    let t=CGAffineTransform(a:r*m[0],b:-r*m[3],c:-r*m[1],d:r*m[4],tx:s*(m[1]*Double(nativeSize.height)+m[2]),ty:s*(h-m[4]*Double(nativeSize.height)-m[5]))
    let layout=try PreviewInteractiveLayout.make(width:Int(ceil(w*s)),height:Int(ceil(h*s)),float:false)
    return .init(mapping:mapping,transform:t,outputScale:s,layout:layout)
  }
  static func canvas(_ image:CIImage,width:Int,height:Int)->CIImage {
    let bounds=CGRect(x:0,y:0,width:width,height:height)
    let background=CIImage(color:CIColor(red:0,green:0,blue:0,alpha:0)).cropped(to:bounds)
    return image.composited(over:background).cropped(to:bounds)
  }
  static func validate(_ image:CIImage,using scratch:PreviewInteractiveProxyStorage,context:CIContext,check:()throws->Void)throws {
    try check()
    guard let mask=try DevelopmentLocalEngineV3.kernel("rmLocalInvalid").apply(extent:image.extent,roiCallback:{_,r in r},arguments:[image.samplingNearest()]) else{throw DevelopmentV3Error.invalidGraph}
    let one=CGRect(x:0,y:0,width:1,height:1)
    let maximum=mask.applyingFilter("CIAreaMaximum",parameters:[kCIInputExtentKey:CIVector(cgRect:image.extent)]).cropped(to:one)
    try scratch.fill(maximum,context:context,check:check)
    try scratch.withPixels{p,_ in
      let value=p.loadUnaligned(as:SIMD4<Float>.self)
      guard value.x.isFinite,value.x==0 else{throw DevelopmentError.invalidEncoding}
    }
  }
  static func suffix(_ p:DevelopmentAdjustmentsV3,source:CIImage,sourceIsRAW:Bool,nativeSize:CGSize,scale:Double,context:CIContext,check:@escaping ()throws->Void,illustrativeAdaptiveBrilliance:Bool=false)throws->CIImage {
    var image=source
    if !sourceIsRAW {
      if let b=p.legacyBasis {
        if !p.whiteBalance.enabled,case let .temperatureTint(t,v)=b.whiteBalance{image=image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:t,y:v),"inputTargetNeutral":CIVector(x:6500,y:0)])}
        if b.exposureEV != 0{image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:b.exposureEV])}
      }
      image=try DevelopmentWhiteBalanceEngineV3.applyImage(p.whiteBalance,to:image,context:context,checkCancellation:check)
    }
    // Both RAW and image use the same legacy point basis BEFORE Light, not image-only.
    if let color=p.legacyBasis?.color,!color.isNeutral{image=try DevelopmentColorEngineV2.apply(color,to:image)}
    if !sourceIsRAW,p.light.enabled,p.light.exposure != 0{image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:2*p.light.exposure])}
    try check()
    let radius=max(1,min(Double(nativeSize.width),Double(nativeSize.height))*DevelopmentSpatialEngineV3.radiusFraction)*scale
    if DevelopmentBrillianceAdaptiveV1.isActive(p.light) {
      // Only the independent thumbnail renderer may use this approximate, compact-domain
      // operator. Main preview admission remains canonical and cannot reach this branch.
      guard illustrativeAdaptiveBrilliance,max(image.extent.width,image.extent.height)<=256 else {throw PreviewPresentationError.unsupported}
      image=try DevelopmentBrillianceAdaptiveV1.apply(p.light,to:image,checkCancellation:check)
      var remainder=p.light;remainder.brilliance=0
      image=try DevelopmentSpatialEngineV3.applyLight(remainder,to:image,proxyRadius:radius)
    } else { image=try DevelopmentSpatialEngineV3.applyLight(p.light,to:image,proxyRadius:radius) }
    image=try DevelopmentColorEngineV3.applyPointwise(p,to:image)
    image=try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:image)
    image=try DevelopmentGlobalEngineV3.apply(p,to:image,sourceIsRAW:sourceIsRAW)
    let texture=p.advancedDetail.texture.enabled && p.advancedDetail.texture.amount != 0
    let clarity=p.advancedDetail.clarity.enabled && p.advancedDetail.clarity.amount != 0
    if texture || clarity {
      var bands=p.advancedDetail;bands.dehaze = .init()
      let proxySize=DevelopmentPixelSize(width:Int(image.extent.width),height:Int(image.extent.height))
      image=try DevelopmentAdvancedDetailEngineV3.apply(bands,to:image,sourceSize:proxySize,context:context,checkCancellation:check)
    }
    return image
  }
}

/// Immutable job prepared under the admitted actor lease. The geometry is computed ONCE on
/// actual native dimensions and retained through queued work, bitmap identity and native render.
struct PreviewInteractivePlan {
  let descriptor:PreviewInteractiveInputDescriptor?
  let geometry:PreviewInteractiveProxyV3.Geometry?
  let outputLayout:PreviewInteractiveLayout
  let fallback:PreviewInteractiveProxyV3.Reason?
  var isProxy:Bool{descriptor != nil}
  func keySuffix()throws->String {
    guard let descriptor,let geometry else{return ""}
    struct Key:Encodable {let version,input:String;let outputScaleBits:UInt64;let width,height:Int;let nativeMatrix:[Double]}
    let key=Key(version:PreviewInteractiveProxyV3.version,input:try descriptor.fingerprint(),outputScaleBits:geometry.outputScale.bitPattern,width:outputLayout.width,height:outputLayout.height,nativeMatrix:geometry.mapping.forwardMatrix)
    return ":interactive-proxy:"+(try EditingFingerprint.of(key))+":"
  }
}

extension PreviewNativeSource {
  /// Reads only immutable construction-time source/default facts, never mutable CIRAW/context.
  func interactivePlan(recipe:DevelopmentRecipe,sourceKey:String,generation:UInt64,verifiedContentID:String,maxPixel:Int)throws->PreviewInteractivePlan {
    try recipe.validate();guard !artifact,let p=recipe.adjustmentsV3,maxPixel>0,maxPixel<=2400 else{throw PreviewPresentationError.unsupported}
    let capability=try PreviewInteractiveProxyV3.support(recipe,sourceIsRAW:hasRAWFilter,allowAdvancedDetail:true)
    if case let .canonical(reason)=capability {
      let mapping=try p.geometry.mapping(sourceSize:.init(width:Int(nativeSize.width),height:Int(nativeSize.height)))
      let size=CGSize(width:mapping.outputSize.width,height:mapping.outputSize.height)
      let factor=min(1,Double(max(64,maxPixel))/max(Double(size.width),Double(size.height)))
      let layout=try PreviewInteractiveLayout.make(width:Int(ceil(Double(size.width)*factor)),height:Int(ceil(Double(size.height)*factor)),float:false)
      return .init(descriptor:nil,geometry:nil,outputLayout:layout,fallback:reason)
    }
    let scale=try PreviewInteractiveProxyV3.scale(nativeSize),layout=try PreviewInteractiveProxyV3.inputLayout(nativeSize)
    let params=hasRAWFilter ? try interactiveNativeParameters(p):nil
    var mode="image",temperature:UInt32?,tint:UInt32?
    if let params {
      switch params.whiteBalance {
      case .asShot:mode="original-neutral-untouched"
      case let .temperatureTint(t,v):mode="native-float-TT";temperature=Float(t).bitPattern;tint=Float(v).bitPattern
      }
    }
    let stamp=captureStamp
    let descriptor=PreviewInteractiveInputDescriptor(version:PreviewInteractiveProxyV3.version,sourceKey:sourceKey,verifiedContentID:verifiedContentID,captureID:captureID,generation:generation,device:stamp.device,inode:stamp.inode,byteCount:stamp.size,seconds:stamp.seconds,nanos:stamp.nanoseconds,changedSeconds:stamp.changedSeconds,changedNanos:stamp.changedNanoseconds,decoder:decoder,originalDefaults:originalNativeDefaultsFingerprint ?? "image-oriented-input-v1",nativeContract:DevelopmentRendererV3.nativeContract,sourceIsRAW:hasRAWFilter,orientation:originalEXIFOrientation,width:Int(nativeSize.width),height:Int(nativeSize.height),extentXBits:Double(orientedNativeExtent.minX).bitPattern,extentYBits:Double(orientedNativeExtent.minY).bitPattern,scaleBits:scale.bitPattern,proxyWidth:layout.width,proxyHeight:layout.height,rowBytes:layout.rowBytes,nativeExposureBits:params?.exposure.bitPattern,whiteBalanceMode:mode,nativeTemperatureBits:temperature,nativeTintBits:tint,nativeNoise:params?.noiseReduction)
    let geometry=try PreviewInteractiveProxyV3.geometry(p.geometry,nativeSize:nativeSize,inputScale:scale,maxPixel:maxPixel)
    return .init(descriptor:descriptor,geometry:geometry,outputLayout:geometry.layout,fallback:nil)
  }
  private func interactiveNativeParameters(_ p:DevelopmentAdjustmentsV3)throws->DevelopmentRendererV3.NativeParameters {
    guard let n=noiseReductionFacts.raw else{throw DevelopmentV3Error.unsupportedNativeParameters}
    let defaults=DevelopmentRAWNoiseReductionDefaultsV3(luminance:n.defaultLuminanceNoise,color:n.defaultColorNoise,detail:n.defaultDetail,luminanceSupported:n.luminanceNoiseSupported,colorSupported:n.colorNoiseSupported,detailSupported:n.detailSupported)
    return try .init(p,noiseDefaults:defaults,originalDefaultsFingerprint:originalNativeDefaultsFingerprint)
  }
  /// Worker-only, synchronous and bounded. No fallback after ANY fill/task has started.
  func renderInteractiveProxy(recipe:DevelopmentRecipe,maxPixel:Int,plan:PreviewInteractivePlan,pool:PreviewInteractiveProxyPool,scope:PreviewPresentationScope,rawBasePool:PreviewRawBasePool?,memoryLimit:Int,cancellation:DevelopmentAnalysisCancellation)throws->PreviewPixels {
    try validateCaptureAuthority();try cancellation.check();try scope.requireOpenAdmission()
    guard memoryLimit==512 else{throw PreviewPresentationError.unsupported}
    self.context.clearCaches() // Drop the prior canonical context cache before opt-in allocation.
    guard let p=recipe.adjustmentsV3 else{throw DevelopmentError.unsupportedEngine}
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryLimit])
    defer{context.clearCaches()}
    guard let device=MTLCreateSystemDefaultDevice(),device.hasUnifiedMemory else{throw PreviewPresentationError.unsupported}
    if let reason=plan.fallback {
      // Same actual complete canonical graph. Output is reserved BEFORE fresh native work;
      // this route never calls the old uncharged materializer after an opt-in capacity failure.
      let tickets=try scope.reserveSharedOperation(bytes:[plan.outputLayout.bytes])
      let output=PreviewInteractiveManagedOutput(layout:plan.outputLayout,ticket:tickets[0],device:device)
      let graph=try DevelopmentRendererV3.develop(capture,recipe:recipe,context:context,checkCancellation:{try cancellation.check()})
      let result=try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:maxPixel,managedOutput:output,managedFallbackReason:reason.rawValue,managedCheck:{try cancellation.check()})
      try validateCaptureAuthority();return result
    }
    guard let descriptor=plan.descriptor,let geometry=plan.geometry,descriptor.captureID==captureID,
      descriptor.width==Int(nativeSize.width),descriptor.height==Int(nativeSize.height),descriptor.decoder==decoder else{throw PreviewPresentationError.allocationProtocol}
    let binding=DevelopmentLocalEditSourceBinding(sourceContentID:descriptor.verifiedContentID,exifOrientation:originalEXIFOrientation,orientedWidth:descriptor.width,orientedHeight:descriptor.height)
    try p.localEdits.validate(expectedSource:binding);try p.whiteBalance.resolvedState?.validate(expectedSource:binding)
    var pin=try pool.lookup(descriptor)
    let buildID:UUID?
    if pin==nil{buildID=try pool.beginBuild(descriptor);pool.evictUnpinnedBeforeFill();rawBasePool?.evictUnpinned()}else{buildID=nil}
    defer{if let buildID{pool.endBuild(buildID)}}
    let proxyLayout=try PreviewInteractiveLayout.make(width:descriptor.proxyWidth,height:descriptor.proxyHeight,float:true)
    let validationLayout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
    // 64KiB reserved (not falsely registered as physically allocated) covers the known bounded
    // legacy/current curve+levels/6-color metadata Array/Data tables under existing Core16point
    // limits, their aliases and temporary parameters. CI-private/driver intermediates are unknown.
    let metadataPeak=65536
    var reservations=[plan.outputLayout.bytes,validationLayout.bytes,metadataPeak]
    if pin==nil{reservations.append(proxyLayout.bytes)}
    let tickets=try scope.reserveSharedOperation(bytes:reservations)
    defer{tickets[2].releaseAfterStorageReleased()}
    let output=PreviewInteractiveManagedOutput(layout:plan.outputLayout,ticket:tickets[0],device:device)
    let scratch=try PreviewInteractiveProxyStorage(layout:validationLayout,ticket:tickets[1],device:device)
    let check:()throws->Void={try cancellation.check();try scope.requireOpenAdmission();try pin?.check()}
    do {
      if pin==nil {
        let storage=try PreviewInteractiveProxyStorage(layout:proxyLayout,ticket:tickets[3],device:device)
        guard let currentBuildID=buildID else{throw PreviewPresentationError.allocationProtocol}
        try pool.attachBuildingStorage(storage,id:currentBuildID)
        try autoreleasepool {
          let input:CIImage
          if descriptor.sourceIsRAW {
            guard let fresh=CIRAWFilter(imageURL:capture)else{throw DevelopmentError.unreadable}
            guard fresh.decoderVersion.rawValue==descriptor.decoder else{throw DevelopmentV3Error.unsupportedNativeParameters}
            // asShot means no TT setter on this FRESH decoder; original chromaticity is untouched.
            try DevelopmentRendererV3.configure(fresh,parameters:interactiveNativeParameters(p))
            guard let image=fresh.outputImage else{throw DevelopmentError.unreadable};input=image
          }else{
            guard let image=CIImage(contentsOf:capture,options:[.applyOrientationProperty:true])else{throw DevelopmentError.unreadable};input=image
          }
          guard input.extent==orientedNativeExtent else{throw PreviewPresentationError.allocationProtocol}
          let normalized=input.transformed(by:.init(translationX:-input.extent.minX,y:-input.extent.minY))
          let scaled=normalized.samplingLinear().transformed(by:.init(scaleX:descriptor.scale,y:descriptor.scale))
          let canvas=try PreviewInteractiveProxyV3.transportAlpha(PreviewInteractiveProxyV3.canvas(scaled,width:proxyLayout.width,height:proxyLayout.height))
          try storage.fill(canvas,context:context,check:check);try storage.validateAllRGBA()
          try validateCaptureAuthority();try check();context.clearCaches()
        }
        guard let buildID else{throw PreviewPresentationError.allocationProtocol}
        pin=try pool.publish(descriptor,storage,buildID:buildID)
      }
      guard let acquired=pin else{throw PreviewPresentationError.allocationProtocol}
      let result=try acquired.storage.withImage{base in
        try check()
        let source=base.cropped(to:descriptor.contentRect)
        let suffix=try PreviewInteractiveProxyV3.suffix(p,source:source,sourceIsRAW:descriptor.sourceIsRAW,nativeSize:nativeSize,scale:descriptor.scale,context:context,check:check)
        try PreviewInteractiveProxyV3.validate(suffix,using:scratch,context:context,check:check)
        let transformed=suffix.samplingLinear().transformed(by:geometry.transform)
        let final=PreviewInteractiveProxyV3.canvas(transformed,width:plan.outputLayout.width,height:plan.outputLayout.height)
        try PreviewInteractiveProxyV3.validate(final,using:scratch,context:context,check:check)
        let canonical=CGSize(width:geometry.mapping.outputSize.width,height:geometry.mapping.outputSize.height)
        let approximation=PreviewApproximationInfo(version:PreviewInteractiveProxyV3.version,nativeInputSize:nativeSize,proxyInputSize:descriptor.proxySize,canonicalCanvasSize:canonical,outputPixelSize:CGSize(width:plan.outputLayout.width,height:plan.outputLayout.height),nativeToProxyScale:descriptor.scale)
        let value=try output.materialize(final,context:context,nativeSize:canonical,approximation:approximation,check:check)
        // No graph/context alias may outlive the pin; output provider owns a DIFFERENT allocation.
        context.clearCaches();return value
      }
      try validateCaptureAuthority();try check();pin=nil;return result
    }catch{
      context.clearCaches();pool.retire(sourceKey:descriptor.sourceKey);pin=nil
      do{try validateCaptureAuthority()}catch{throw error}
      throw error
    }
  }
}
