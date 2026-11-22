import Foundation
import CoreImage
import Metal
import RAWMasterCore

struct PreviewInteractivePhaseProfile {
  static let enabled=ProcessInfo.processInfo.environment["RAWMASTER_INTERACTIVE_TIMING"] == "1"
  private var previous=DispatchTime.now().uptimeNanoseconds
  mutating func mark(_ label:String) {
    guard Self.enabled else{return}
    let now=DispatchTime.now().uptimeNanoseconds
    FileHandle.standardError.write(Data("INTERACTIVE-PHASE \(label) \(Double(now-previous)/1_000_000)\n".utf8))
    previous=now
  }
}

enum PreviewInteractiveProxyV3 {
  static let validatesJoinedTexture = ProcessInfo.processInfo.environment["RAWMASTER_PROXY_LEGACY_VALIDATION"] != "1"
  static let fusedDisplay = ProcessInfo.processInfo.environment["RAWMASTER_PROXY_FUSED_DISPLAY"] == "1"
  static let sourceOverlayVersion="flashraw-native-hue-sharpen-mask/source-lattice-local-grain-v1"
  enum NativeOverlay {
    case color, sharpen
    init?(_ p:DevelopmentAdjustmentsV3) {
      guard p.rawDecoder == .flashRaw031, p.aiDenoise == nil else { return nil }
      var remaining=p
      if p.sharpen.enabled && p.sharpen.visualiseMasking == true {
        self = .sharpen
        remaining.sharpen = .init()
      } else if p.selectiveColor.visualiseRange != nil || p.selectiveColor.visualiseIsolation != nil {
        self = .color
        remaining.selectiveColor = .init()
      } else { return nil }
      var neutral=p.neutralForSameSource
      neutral.rawDetails=p.rawDetails
      guard remaining == neutral else { return nil }
    }
    func image(_ p:DevelopmentAdjustmentsV3, source:CIImage) throws -> CIImage {
      switch self {
      case .color: return try DevelopmentGlobalEngineV3.apply(p,to:source,sourceIsRAW:true)
      case .sharpen: return try DevelopmentGlobalEngineV3.applySharpenMaskPreview(p,to:source)
      }
    }
  }
  static let version="actual-parameters-linear-proxy-v3-flashraw-neutral/integral-noise-snap-v1/filter-global-v1/point-cache-retract-v1/sharpen-noise-detail-v1"
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
  private static let invalidTileKernel: Result<CIKernel,Error> = Result {
    let source = #"""
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    [[stitchable]] float4 rmProxyInvalidTile(sampler src,float4 bounds,destination dest) {
      int2 tile=int2(floor(dest.coord()));
      float2 base=bounds.xy+float2(tile*16),end=bounds.xy+bounds.zw;
      float invalid=0;
      for(int y=0;y<16;y++)for(int x=0;x<16;x++) {
        float2 coord=base+float2(x,y)+0.5;
        if(coord.x<end.x && coord.y<end.y) {
          float4 p=src.sample(src.transform(coord));
          invalid=max(invalid,(!all(isfinite(p))||p.a<0||p.a>1)?1.0:0.0);
        }
      }
      return float4(invalid);
    }
    } }
    """#
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries,
      let kernel=try CIKernel.kernels(withMetalString:source).first(where:{$0.name=="rmProxyInvalidTile"}) else {
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
    if p.aiDenoise != nil && !sourceIsRAW { throw EditingError.invalidRecipe }
    try p.noiseReduction.validate(for:sourceIsRAW ? .raw:.image)
    if !allowAdvancedDetail,DevelopmentBrillianceAdaptiveV1.isActive(p.light){return .canonical(.adaptiveBrilliance)}
    if p.geometry.verticalPerspective != 0 || p.geometry.horizontalPerspective != 0{return .canonical(.projective)}
    if !sourceIsRAW,p.noiseReduction.enabled,p.noiseReduction.nonRawAmount != 0{return .canonical(.nonRawNoise)}
    if p.definition.enabled,p.definition.amount != 0{return .canonical(.definition)}
    if !allowAdvancedDetail,p.sharpen.enabled,p.sharpen.intensity != 0{return .canonical(.sharpen)}
    // Only the main interactive preview opts into proxy-scale local operators. Legacy thumbnail
    // and analysis callers keep their original rejection contract.
    if !allowAdvancedDetail,p.advancedDetail.hasEffects{return .canonical(.advanced)}
    if DevelopmentLocalEngineV3.active(p.localEdits){return .canonical(.local)}
    if p.blackAndWhite.enabled, p.blackAndWhite.grain != 0 || (p.effects?.enabled == true && (p.effects?.grain ?? 0) != 0) {return .canonical(.grain)}
    return .eligible
  }
  static func scale(_ size:CGSize)throws->Double {
    let width=Double(size.width),height=Double(size.height)
    guard width.isFinite,height.isFinite,width>=1,height>=1,width<=Double(DevelopmentLocalEditLimits.maximumSourceDimension),height<=Double(DevelopmentLocalEditLimits.maximumSourceDimension),width==floor(width),height==floor(height) else{throw PreviewPresentationError.invalidLayout}
    return min(1,2400.0/max(width,height))
  }
  /// Snap only floating-point noise around an integral pixel boundary; preserve ceil elsewhere.
  static func scaledPixelDimension(_ native:Double,scale:Double)throws->Int {
    guard native.isFinite,scale.isFinite,native>=1,scale>0 else{throw PreviewPresentationError.invalidLayout}
    let value=native*scale,nearest=value.rounded()
    let rounded=(nearest>=1 && abs(value-nearest)<=1e-9) ? nearest:ceil(value)
    guard rounded.isFinite,rounded>=1,rounded<=Double(Int.max) else{throw PreviewPresentationError.invalidLayout}
    return Int(rounded)
  }
  static func inputLayout(_ size:CGSize)throws->PreviewInteractiveLayout {
    let s=try scale(size)
    return try .make(width:scaledPixelDimension(Double(size.width),scale:s),height:scaledPixelDimension(Double(size.height),scale:s),float:true)
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
    let layout=try PreviewInteractiveLayout.make(width:scaledPixelDimension(w,scale:s),height:scaledPixelDimension(h,scale:s),float:false)
    return .init(mapping:mapping,transform:t,outputScale:s,layout:layout)
  }
  static func canvas(_ image:CIImage,width:Int,height:Int)->CIImage {
    let bounds=CGRect(x:0,y:0,width:width,height:height)
    let background=CIImage(color:CIColor(red:0,green:0,blue:0,alpha:0)).cropped(to:bounds)
    return image.composited(over:background).cropped(to:bounds)
  }
  static func validate(_ image:CIImage,using scratch:PreviewInteractiveProxyStorage,context:CIContext,check:()throws->Void)throws {
    try check()
    let extent=image.extent
    guard !extent.isEmpty,extent.minX.isFinite,extent.minY.isFinite,extent.width.isFinite,extent.height.isFinite,
      extent==extent.integral else{throw DevelopmentV3Error.invalidGraph}
    let tileWidth=(Int(extent.width)+15)/16,tileHeight=(Int(extent.height)+15)/16
    let bounds=CIVector(x:extent.minX,y:extent.minY,z:extent.width,w:extent.height)
    guard let tiles=try invalidTileKernel.get().apply(extent:CGRect(x:0,y:0,width:tileWidth,height:tileHeight),
      roiCallback:{_,_ in extent},arguments:[image.samplingNearest(),bounds]) else{throw DevelopmentV3Error.invalidGraph}
    let one=CGRect(x:0,y:0,width:1,height:1)
    let maximum=tiles.applyingFilter("CIAreaMaximum",parameters:[kCIInputExtentKey:CIVector(cgRect:tiles.extent)]).cropped(to:one)
    try scratch.fill(maximum,context:context,check:check)
    try scratch.withPixels{p,_ in
      let value=p.loadUnaligned(as:SIMD4<Float>.self)
      guard value.x.isFinite,value.x==0 else{throw DevelopmentError.invalidEncoding}
    }
  }
  static func suffix(_ p:DevelopmentAdjustmentsV3,source:CIImage,sourceIsRAW:Bool,nativeSize:CGSize,scale:Double,context:CIContext,check:@escaping ()throws->Void,illustrativeAdaptiveBrilliance:Bool=false,interactiveMapNamespace:String?=nil,flashRaw:Bool=false,asShotWhiteBalance:DevelopmentAsShotWhiteBalance?=nil,photoFilterResourceLease:((DevelopmentPhotoFilterResourceStore.Pair)throws->Void)?=nil)throws->CIImage {
    var image=source
    if flashRaw {
      image=try FlashRawImageFactory.applyInputAdjustments(p,to:image,asShotWhiteBalance:asShotWhiteBalance,proxyScale:scale)
    } else if !sourceIsRAW {
      if let b=p.legacyBasis {
        if !p.whiteBalance.enabled,case let .temperatureTint(t,v)=b.whiteBalance{image=image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:t,y:v),"inputTargetNeutral":CIVector(x:6500,y:0)])}
        if b.exposureEV != 0{image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:b.exposureEV])}
      }
      image=try DevelopmentWhiteBalanceEngineV3.applyImage(p.whiteBalance,to:image,context:context,checkCancellation:check)
    }
    // Both RAW and image use the same legacy point basis BEFORE Light, not image-only.
    if let color=p.legacyBasis?.color,!color.isNeutral{image=try DevelopmentColorEngineV2.apply(color,to:image)}
    if !flashRaw,!sourceIsRAW,p.light.enabled,p.light.exposure != 0{image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:2*p.light.exposure])}
    try check()
    let radius=max(1,min(Double(nativeSize.width),Double(nativeSize.height))*DevelopmentSpatialEngineV3.radiusFraction)*scale
    if DevelopmentBrillianceAdaptiveV1.isActive(p.light) {
      // Only the 31-cell map is reusable across strength changes. Its key includes the source,
      // proxy identity and all other parameters; settled/save/export retain native evaluation.
      var identity=p;identity.light.brilliance=0
      let key=try interactiveMapNamespace.map{$0+":"+(try EditingFingerprint.of(identity))}
      image=try DevelopmentBrillianceAdaptiveV1.apply(p.light,to:image,sourceIsRAW:sourceIsRAW,context:context,checkCancellation:check,interactiveMapKey:key,interactiveProxy:interactiveMapNamespace != nil)
      var remainder=p.light;remainder.brilliance=0
      image=try DevelopmentSpatialEngineV3.applyLight(remainder,to:image,proxyRadius:radius)
    } else { image=try DevelopmentSpatialEngineV3.applyLight(p.light,to:image,proxyRadius:radius) }
    image=try DevelopmentBlackAndWhiteMixerEngineV3.apply(p.blackAndWhite,to:image)
    image=try DevelopmentColorEngineV3.applyPointwise(p,to:image,context:context,checkCancellation:check,proxyScale:scale)
    image=try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:image)
    image=try DevelopmentGlobalEngineV3.apply(p,to:image,sourceIsRAW:sourceIsRAW)
    image=try DevelopmentGlowEngineV3.apply(p.effects,to:image)
    image=try DevelopmentPhotoFilterEngineV3.apply(p.filter,to:image,resourceLease:photoFilterResourceLease)
    image=try DevelopmentGradingLUTEngine.apply(p.gradingLUTs, to: image)
    image=try DevelopmentLensBlurEngineV3.apply(p.effects?.lensBlur,to:image)
    let proxySize=DevelopmentPixelSize(width:Int(image.extent.width),height:Int(image.extent.height))
    let advanced=p.advancedDetail,dehaze=advanced.dehaze
    if dehaze.enabled,dehaze.amount != 0 {
      guard let prepared=advanced.preparedDehaze else{throw DevelopmentDehazePreparationError.preparationRequired}
      // Airlight is prepared once on the source. Only the spatial guide is rebuilt at proxy
      // scale on each adjustment; native source bindings must not be applied to this image.
      if DevelopmentDehazeEngineV3.usesPositiveV2(advanced) {
        let guide=try DevelopmentDehazeColorGuideV2.guide(image,airlight:prepared.airlight,sourceSize:proxySize)
        image=try DevelopmentDehazeColorGuideV2.restore(image,guide:guide,airlight:prepared.airlight,amount:dehaze.amount)
      } else {
        let guide=try DevelopmentDehazeEngineV3.darkGuide(image,airlight:prepared.airlight,sourceSize:proxySize)
        image=try DevelopmentDehazeEngineV3.applyGuide(to:image,guide:guide,airlight:prepared.airlight,amount:dehaze.amount)
      }
    }
    let texture=advanced.texture.enabled && advanced.texture.amount != 0
    let clarity=advanced.clarity.enabled && advanced.clarity.amount != 0
    if texture || clarity {
      var bands=advanced;bands.dehaze = .init()
      image=try DevelopmentAdvancedDetailEngineV3.apply(bands,to:image,sourceSize:proxySize,context:context,checkCancellation:check,deferValidation:true)
    }
    image=try DevelopmentMaskEngineV3.apply(p.masks,to:image,context:context,glow:p.effects?.glow ?? .init(),optics:p.optics,checkCancellation:check,deferValidation:true,sourceGrainScale:flashRaw ? scale:nil)
    image=try DevelopmentGlobalEngineV3.applySharpenMaskPreview(p,to:image,sourceToImageScale:flashRaw ? scale:1)
    image=try DevelopmentLensBlurEngineV3.applyDepthPreview(p.effects?.lensBlur,to:image)
    image=try DevelopmentGlobalEngineV3.applyClippingPreview(p,to:image)
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
  var sourceOverlayVersion:String?
  var isProxy:Bool{descriptor != nil}
  func keySuffix()throws->String {
    guard let descriptor,let geometry else{return ""}
    struct Key:Encodable {let version,input:String;let outputScaleBits:UInt64;let width,height:Int;let nativeMatrix:[Double];let sourceOverlay:String?}
    let key=Key(version:PreviewInteractiveProxyV3.version,input:try descriptor.fingerprint(),outputScaleBits:geometry.outputScale.bitPattern,width:outputLayout.width,height:outputLayout.height,nativeMatrix:geometry.mapping.forwardMatrix,sourceOverlay:sourceOverlayVersion)
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
      let layout=try PreviewInteractiveLayout.make(width:PreviewInteractiveProxyV3.scaledPixelDimension(Double(size.width),scale:factor),height:PreviewInteractiveProxyV3.scaledPixelDimension(Double(size.height),scale:factor),float:false)
      return .init(descriptor:nil,geometry:nil,outputLayout:layout,fallback:reason)
    }
    let scale=try PreviewInteractiveProxyV3.scale(nativeSize),layout=try PreviewInteractiveProxyV3.inputLayout(nativeSize)
    let useFlashRaw = hasRAWFilter && DevelopmentRAWSourcePolicy.usesFlashRaw(p)
    let neural = p.aiDenoise
    if let neural, aiDenoiseCapability != neural.model { throw DevelopmentNeuralRaw9.Unavailable.source }
    // Demosaic/denoise belongs to the neutral base. WB, EV and independent noise sliders follow it.
    let params=hasRAWFilter && !useFlashRaw && neural == nil ? try interactiveNativeParameters(p):nil
    var mode=neural != nil ? "raw9-neutral" : (useFlashRaw ? "flashraw-neutral":"image"),temperature:UInt32?,tint:UInt32?
    if let params {
      switch params.whiteBalance {
      case .asShot:mode="original-neutral-untouched"
      case let .temperatureTint(t,v):mode="native-float-TT";temperature=Float(t).bitPattern;tint=Float(v).bitPattern
      }
    }
    let stamp=captureStamp
    let descriptor=PreviewInteractiveInputDescriptor(version:PreviewInteractiveProxyV3.version,sourceKey:sourceKey,verifiedContentID:verifiedContentID,captureID:captureID,generation:generation,device:stamp.device,inode:stamp.inode,byteCount:stamp.size,seconds:stamp.seconds,nanos:stamp.nanoseconds,changedSeconds:stamp.changedSeconds,changedNanos:stamp.changedNanoseconds,decoder:neural?.model.rawValue ?? decoder,originalDefaults:originalNativeDefaultsFingerprint ?? "image-oriented-input-v1",nativeContract:neural?.inputContract ?? (useFlashRaw ? (p.rawDetails?.rawValue ?? "flashraw-linear-f16-metal-v1"):DevelopmentRendererV3.nativeContract),proxyDecoder:neural?.model.rawValue ?? (useFlashRaw ? "flashraw-linear-f16-metal-v1":"core-image"),sourceIsRAW:hasRAWFilter,orientation:originalEXIFOrientation,width:Int(nativeSize.width),height:Int(nativeSize.height),extentXBits:Double(orientedNativeExtent.minX).bitPattern,extentYBits:Double(orientedNativeExtent.minY).bitPattern,scaleBits:scale.bitPattern,proxyWidth:layout.width,proxyHeight:layout.height,rowBytes:layout.rowBytes,nativeExposureBits:params?.exposure.bitPattern,whiteBalanceMode:mode,nativeTemperatureBits:temperature,nativeTintBits:tint,nativeNoise:params?.noiseReduction)
    let geometry=try PreviewInteractiveProxyV3.geometry(p.geometry,nativeSize:nativeSize,inputScale:scale,maxPixel:maxPixel)
    let sourceOverlay=useFlashRaw && (p.selectiveColor.visualiseRange != nil || p.selectiveColor.visualiseIsolation != nil
      || p.sharpen.visualiseMasking == true || p.masks.contains { $0.enabled && $0.opacity>0 && ($0.adjustments.grain ?? 0)>0 })
    return .init(descriptor:descriptor,geometry:geometry,outputLayout:geometry.layout,fallback:nil,
      sourceOverlayVersion:sourceOverlay ? PreviewInteractiveProxyV3.sourceOverlayVersion:nil)
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
    var profile=PreviewInteractivePhaseProfile()
    guard let p=recipe.adjustmentsV3 else{throw DevelopmentError.unsupportedEngine}
    // Running a parameterized Point Color mask after Curves/Grading on the same CIContext can
    // produce an empty first render. Reuse a distinct command context for this kernel family.
    let pointColor = p.masks.contains { $0.enabled && $0.opacity > 0 && $0.adjustments.pointColor?.isActive == true }
    let context=try interactiveContext(memoryLimit:memoryLimit,pointColor:pointColor)
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
      descriptor.width==Int(nativeSize.width),descriptor.height==Int(nativeSize.height),descriptor.decoder==(p.aiDenoise?.model.rawValue ?? decoder) else{throw PreviewPresentationError.allocationProtocol}
    let binding=DevelopmentLocalEditSourceBinding(sourceContentID:descriptor.verifiedContentID,exifOrientation:originalEXIFOrientation,orientedWidth:descriptor.width,orientedHeight:descriptor.height)
    try p.localEdits.validate(expectedSource:binding);try p.whiteBalance.resolvedState?.validate(expectedSource:binding)
    if p.advancedDetail.dehaze.enabled,p.advancedDetail.dehaze.amount != 0 {
      let context=try dehazeContext(source:binding,generation:descriptor.generation)
      guard (try recipe.dehazePreparationStatusV1(context:context)) == .ready else{throw DevelopmentDehazePreparationError.staleInput}
    }
    var pin=try pool.lookup(descriptor)
    if PreviewInteractivePhaseProfile.enabled {
      let key=(try? descriptor.fingerprint()) ?? "fingerprint-error"
      FileHandle.standardError.write(Data("PROXY-BASE-LOOKUP \(pin == nil ? "miss":"hit") \(key)\n".utf8))
      if pin == nil, let data=try? JSONEncoder().encode(descriptor),let text=String(data:data,encoding:.utf8) {
        FileHandle.standardError.write(Data("PROXY-BASE-DESCRIPTOR \(text)\n".utf8))
      }
    }
    let buildID:UUID?
    if pin==nil{buildID=try pool.beginBuild(descriptor);pool.evictUnpinnedBeforeFill(keepingPreviousFor: p.aiDenoise == nil ? nil : descriptor);rawBasePool?.evictUnpinned()}else{buildID=nil}
    defer{if let buildID{pool.endBuild(buildID)}}
    let proxyLayout=try PreviewInteractiveLayout.make(width:descriptor.proxyWidth,height:descriptor.proxyHeight,float:true)
    let validationLayout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
    let proxyBounds = CGRect(x:0,y:0,width:proxyLayout.width,height:proxyLayout.height)
    let directValidation = PreviewInteractiveProxyV3.validatesJoinedTexture && descriptor.usesFlashRaw
      && geometry.transform.isIdentity && descriptor.contentRect == proxyBounds
      && proxyLayout.width == plan.outputLayout.width && proxyLayout.height == plan.outputLayout.height
      && p.effects?.postCropVignette?.isActive != true && PreviewMetalFrameValidator.supports(device)
    // 64KiB reserved (not falsely registered as physically allocated) covers the known bounded
    // legacy/current curve+levels/6-color metadata Array/Data tables under existing Core16point
    // limits, their aliases and temporary parameters. CI-private/driver intermediates are unknown.
    let metadataPeak=65536
    // One explicitly shared suffix surface prevents validation and presentation from
    // re-evaluating the same uncached CI graph. It is charged independently of the base.
    let neuralOnly = p.aiDenoise.map { settings in
      var neutral = p.neutralForSameSource
      neutral.aiDenoise = settings
      return p == neutral && descriptor.contentRect == proxyBounds
    } ?? false
    var reservations=[plan.outputLayout.bytes,validationLayout.bytes,metadataPeak]
    let suffixTicketIndex = reservations.count
    if !neuralOnly { reservations.append(proxyLayout.bytes) }
    let coldTicketIndex = reservations.count
    if pin==nil{reservations.append(proxyLayout.bytes)}
    let validationTicketIndex = reservations.count
    if directValidation { reservations.append(PreviewMetalFrameValidator.allocation(width:proxyLayout.width,height:proxyLayout.height)) }
    if p.aiDenoise != nil && pin == nil { scope.ledger.registerOptionalNeuralInputs(pool) }
    let tickets = try scope.reserveSharedOperation(bytes: reservations)
    defer{tickets[2].releaseAfterStorageReleased()}
    let output=PreviewInteractiveManagedOutput(layout:plan.outputLayout,ticket:tickets[0],device:device)
    let scratch=try PreviewInteractiveProxyStorage(layout:validationLayout,ticket:tickets[1],device:device)
    let check:()throws->Void={try cancellation.check();try scope.requireOpenAdmission();try pin?.check()}
    do {
      if pin==nil {
        let storage=try PreviewInteractiveProxyStorage(layout:proxyLayout,ticket:tickets[coldTicketIndex],device:device)
        guard let currentBuildID=buildID else{throw PreviewPresentationError.allocationProtocol}
        try pool.attachBuildingStorage(storage,id:currentBuildID)
        try autoreleasepool {
          if descriptor.usesFlashRaw {
            let flash=try FlashRawSource.open(capture)
            guard flash.decoderVersion == "0.3.1" else { throw FlashRawError.unavailable("unexpected FlashRaw version") }
            let frame=try flash.decode(output:.linearRGBF16,backend:.gpu,demosaic:flash.demosaic(for:p.rawDetails, fallback:p.rawDecoder == nil ? .measurementOverride : .bilinear))
            let orientedSize=frame.info.orientation >= 5 && frame.info.orientation <= 8 ? CGSize(width:frame.info.height,height:frame.info.width):CGSize(width:frame.info.width,height:frame.info.height)
            guard orientedSize==nativeSize, frame.info.orientation == originalEXIFOrientation else{throw PreviewPresentationError.allocationProtocol}
            try storage.fillFlashRaw(frame,check:check)
          } else {
            let input:CIImage
            if let neural = p.aiDenoise {
              input = try DevelopmentNeuralRaw9.neutralImage(capture, settings: neural)
            } else if descriptor.sourceIsRAW {
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
            try storage.fill(canvas,context:context,check:check)
          }
          // Validate the already-joined IOSurface on GPU and read back only its 1px maximum.
          // The former full-frame CPU scan added a second complete memory pass on every cold fill.
          let _:Void=try storage.withImage{base in
            try PreviewInteractiveProxyV3.validate(base,using:scratch,context:context,check:check)
          }
          try validateCaptureAuthority();try check();
        }
        guard let buildID else{throw PreviewPresentationError.allocationProtocol}
        pin=try pool.publish(descriptor,storage,buildID:buildID)
      }
      guard let acquired=pin else{throw PreviewPresentationError.allocationProtocol}
      profile.mark("base-ready")
      let result=try acquired.storage.withImage{base in
        try check()
        if ProcessInfo.processInfo.environment["RAWMASTER_INTERACTIVE_CLEAR_CACHE"] == "1" { context.clearCaches() }
        if ProcessInfo.processInfo.environment["RAWMASTER_INTERACTIVE_DEBUG_ALPHA"] == "1" {
          let average=base.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:base.extent)]).cropped(to:CGRect(x:0,y:0,width:1,height:1))
          try scratch.fill(average,context:context,check:check)
          try scratch.withPixels{pixels,_ in
            let value=pixels.loadUnaligned(as:SIMD4<Float>.self)
            FileHandle.standardError.write(Data("INTERACTIVE-BASE-RGBA \(value.x) \(value.y) \(value.z) \(value.w)\n".utf8))
          }
        }
        let source=base.cropped(to:descriptor.contentRect)
        let suffixSurface: PreviewInteractiveProxyStorage
        if neuralOnly {
          // A pure denoise edit is already the validated neutral base. This also leaves room
          // for the previous amount while the window retains the currently displayed image.
          suffixSurface = acquired.storage
        } else {
          // Reduce the displayed size after measuring native hue/edges. Reducing the
          // input first can erase a narrow colour selection or create different edges.
          let nativeOverlay=descriptor.usesFlashRaw && descriptor.scale<1 ? PreviewInteractiveProxyV3.NativeOverlay(p):nil
          let nativePin:FlashRawCanonicalTexturePool.Pin?
          if nativeOverlay != nil {
            do { nativePin=try pinFlashRawSource(p,sourceKey:descriptor.sourceKey) }
            catch RawBaseCacheError.capacity { nativePin=nil }
          } else { nativePin=nil }
          defer { nativePin?.release() }
          var responsePin:FlashRawCanonicalTexturePool.Pin?
          defer { responsePin?.release() }
          let suffix:CIImage
          if let nativeOverlay,let nativePin {
            if nativeOverlay == .sharpen {
              let radius=p.sharpen.radius ?? DevelopmentGlobalEngineV3.sharpenRadiusInNativePixels(falloff:p.sharpen.falloff)
              let contract=(p.rawDetails?.rawValue ?? "bilinear")+"/sharp-response-r32f-v1/"+String(radius.bitPattern,radix:16)
              let key=FlashRawCanonicalTextureKey(sourceKey:descriptor.sourceKey,captureStamp:captureStamp,contract:contract,
                width:Int(nativeSize.width),height:Int(nativeSize.height),bytesPerPixel:4)
              do {
                responsePin=try FlashRawCanonicalTexturePool.shared.acquire(key) {
                  try DevelopmentGlobalEngineV3.nativeSharpResponse(nativePin.image,radius:radius,context:context,device:device,check:check)
                }
              } catch RawBaseCacheError.capacity { responsePin=nil }
            }
            let overlay=try responsePin.map { try DevelopmentGlobalEngineV3.nativeSharpMask(p.sharpen,response:$0.image) }
              ?? nativeOverlay.image(p,source:nativePin.image)
            suffix=overlay.transformed(by:.init(scaleX:descriptor.scale,y:descriptor.scale)).cropped(to:descriptor.contentRect)
            profile.mark("native-overlay-built")
          } else {
            suffix=try PreviewInteractiveProxyV3.suffix(p,source:source,sourceIsRAW:descriptor.sourceIsRAW,nativeSize:nativeSize,scale:descriptor.scale,context:context,check:check,interactiveMapNamespace:try descriptor.fingerprint(),flashRaw:descriptor.usesFlashRaw || p.aiDenoise != nil,asShotWhiteBalance:asShotWhiteBalance)
          }
          guard !directValidation || base.extent == proxyBounds else { throw PreviewPresentationError.invalidLayout }
          // A crop or rotation changes the final graph, but not an untouched input
          // texture. Keep its lease through validation and conversion of the actual crop.
          let canReuseBase = PreviewInteractiveProxyV3.validatesJoinedTexture && descriptor.usesFlashRaw
            && descriptor.contentRect == proxyBounds && base.extent == proxyBounds
          if canReuseBase && suffix === source {
            suffixSurface = acquired.storage
          } else {
            suffixSurface = try PreviewInteractiveProxyStorage(layout:proxyLayout,ticket:tickets[suffixTicketIndex],device:device)
            try suffixSurface.fill(suffix,context:context,check:check)
          }
        }
        defer { withExtendedLifetime(suffixSurface) {} }
        profile.mark("suffix-rendered-once")
        let settledSuffix=try suffixSurface.withImage{joined->CIImage in joined }
        profile.mark("suffix-joined")
        if ProcessInfo.processInfo.environment["RAWMASTER_INTERACTIVE_DEBUG_ALPHA"] == "1" {
          let average=settledSuffix.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:settledSuffix.extent)]).cropped(to:CGRect(x:0,y:0,width:1,height:1))
          try scratch.fill(average,context:context,check:check)
          try scratch.withPixels{pixels,_ in
            let value=pixels.loadUnaligned(as:SIMD4<Float>.self)
            FileHandle.standardError.write(Data("INTERACTIVE-SUFFIX-RGBA \(value.x) \(value.y) \(value.z) \(value.w)\n".utf8))
          }
        }
        let transformed=settledSuffix.samplingLinear().transformed(by:geometry.transform)
        let final=PreviewInteractiveProxyV3.canvas(transformed,width:plan.outputLayout.width,height:plan.outputLayout.height)
        let finalWithPostCrop=try DevelopmentPostCropVignetteEngineV3.apply(p.effects,to:final)
        let canonical=CGSize(width:geometry.mapping.outputSize.width,height:geometry.mapping.outputSize.height)
        let approximation=PreviewApproximationInfo(version:PreviewInteractiveProxyV3.version,nativeInputSize:nativeSize,proxyInputSize:descriptor.proxySize,canonicalCanvasSize:canonical,outputPixelSize:CGSize(width:plan.outputLayout.width,height:plan.outputLayout.height),nativeToProxyScale:descriptor.scale)
        let materialize = { try output.materialize(finalWithPostCrop,context:context,nativeSize:canonical,approximation:approximation,check:check) }
        let value: PreviewPixels
        if directValidation {
          value = try suffixSurface.withJoinedTexture { texture in
            if PreviewInteractiveProxyV3.fusedDisplay {
              return try output.materialize(finalWithPostCrop,context:context,nativeSize:canonical,approximation:approximation,
                validatedDisplay:(texture,tickets[validationTicketIndex]),check:check)
            }
            return try PreviewMetalFrameValidator.checked(texture,ticket:tickets[validationTicketIndex],requireVisible:true,check:check,rendering:materialize)
          }
          profile.mark("joined-validation-and-output")
        } else {
          try PreviewInteractiveProxyV3.validate(finalWithPostCrop,using:scratch,context:context,check:check)
          profile.mark("final-validated")
          value = try materialize()
        }
        profile.mark("output-materialized")
        // Point Color leaves a Core Image dynamic-kernel cache state that can blank the next
        // differently parameterized mask. Retract it only after this frame is fully materialized.
        if pointColor {
          context.clearCaches();profile.mark("point-color-cache-retracted")
        }
        // The sharpening dynamic-kernel path can likewise blank the following noise-detail graph.
        // Retract only after this frame owns its independent output; never clear in-flight state.
        if p.sharpen.enabled && (p.sharpen.intensity != 0 || p.sharpen.visualiseMasking == true) {
          context.clearCaches();profile.mark("sharpen-cache-retracted")
        }
        if p.masks.contains(where:{ layer in
          layer.enabled && layer.opacity>0 && ((layer.adjustments.sharpness ?? 0) != 0 || (layer.adjustments.noiseReduction ?? 0) != 0 || (layer.adjustments.moireReduction ?? 0) != 0)
        }) {
          context.clearCaches();profile.mark("local-detail-cache-retracted")
        }
        if p.effects?.lensBlur?.isActive == true || p.effects?.lensBlur?.visualiseDepth == true {
          context.clearCaches();profile.mark("lens-blur-cache-retracted")
        }
        // No graph/context alias may outlive the pin; output provider owns a DIFFERENT allocation.
        return value
      }
      try validateCaptureAuthority();try check();pin=nil;return result
    }catch{
      pool.retire(sourceKey:descriptor.sourceKey);pin=nil
      do{try validateCaptureAuthority()}catch{throw error}
      throw error
    }
  }
}
