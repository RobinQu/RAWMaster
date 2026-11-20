import Foundation
import CoreImage
import Metal
import RAWMasterCore

extension PreviewNativeSource {
  /// Closed native-input key. Suffix recipe/summary changes do not reopen RAW; native WB/EV/NR do.
  func thumbnailInputFingerprint(recipe:DevelopmentRecipe,source:DevelopmentLocalEditSourceBinding,generation:UInt64)throws->String {
    try DevelopmentThumbnailEngine.checkSupport(recipe,sourceIsRAW:hasRAWFilter)
    guard !artifact,let p=recipe.adjustmentsV3 else{throw DevelopmentThumbnailError.unsupportedGraph}
    struct Signature:Encodable {
      let source:DevelopmentLocalEditSourceBinding;let generation:UInt64
      let decoderContract,encoding:String
      let nativeExposure:UInt32?;let nativeWB:DevelopmentWhiteBalance?;let nativeNR:DevelopmentNoiseReductionV3?
    }
    let params:DevelopmentRendererV3.NativeParameters?
    if hasRAWFilter {
      let n=noiseReductionFacts.raw!
      params=try .init(p,noiseDefaults:.init(luminance:n.defaultLuminanceNoise,color:n.defaultColorNoise,detail:n.defaultDetail,
        luminanceSupported:n.luminanceNoiseSupported,colorSupported:n.colorNoiseSupported,detailSupported:n.detailSupported))
    }else{params=nil}
    return try EditingFingerprint.of(Signature(source:source,generation:generation,decoderContract:localDecoderContractFingerprint,
      encoding:DevelopmentThumbnailEngine.version,nativeExposure:params?.exposure.bitPattern,nativeWB:params?.whiteBalance,
      nativeNR:hasRAWFilter ? p.noiseReduction:nil))
  }
  /// Quiet cold preparation is ONE step for a native-input key, never one decode per candidate.
  /// A settled hook may pass its current native image instead, without retaining that graph here.
  func prepareThumbnailProxy(recipe:DevelopmentRecipe,source:DevelopmentLocalEditSourceBinding,generation:UInt64,
                             ledger:ThumbnailLedger,device:MTLDevice,contextOwner:ThumbnailWorkerContextV1? = nil,settledNativeImage:CIImage?=nil,
                             interest:()->Bool={true})throws->ThumbnailProxy {
    try validateCaptureAuthority();guard interest()else{throw DevelopmentThumbnailError.cancelled}
    let start=DispatchTime.now().uptimeNanoseconds,key=try thumbnailInputFingerprint(recipe:recipe,source:source,generation:generation)
    let p=recipe.adjustmentsV3!
    var created:ThumbnailSurface?
    do {
    let result=try DevelopmentThumbnailEngine.withContext(ledger:ledger,device:device,contextOwner:contextOwner){context in
      let image:CIImage,bakedEV:Float
      if let settledNativeImage {
        image=settledNativeImage;bakedEV=hasRAWFilter ? Float((p.legacyBasis?.exposureEV ?? 0)+(p.light.enabled ? 2*p.light.exposure:0)):0
      }else if hasRAWFilter {
        guard let raw=CIRAWFilter(imageURL:capture)else{throw DevelopmentError.unreadable}
        let original=try DevelopmentRendererV3.decoderDefaultsFingerprint(raw)
        let actual=try DevelopmentRendererV3.localDecoderFingerprint(decoder:raw.decoderVersion.rawValue,
          originalDefaults:original,orientation:Int(raw.orientation.rawValue),size:nativeSize)
        guard actual==localDecoderContractFingerprint else{throw DevelopmentThumbnailError.staleSource}
        let parameters=try DevelopmentRendererV3.NativeParameters(p,noiseDefaults:DevelopmentRendererV3.noiseDefaults(raw),originalDefaultsFingerprint:original)
        try DevelopmentRendererV3.configure(raw,parameters:parameters)
        guard let output=raw.outputImage,output.extent.size==nativeSize else{throw DevelopmentError.unreadable}
        image=output;bakedEV=raw.exposure
      }else{
        guard let decoded=CIImage(contentsOf:capture,options:[.applyOrientationProperty:true])else{throw DevelopmentError.unreadable}
        image=decoded;bakedEV=0 // Image WB/legacyEV remain strictly unbaked.
      }
      guard interest()else{throw DevelopmentThumbnailError.cancelled}
      let e=image.extent,s=min(1,256.0/max(e.width,e.height))
      let w=Int(ceil(e.width*s)),h=Int(ceil(e.height*s))
      let normalized=image.transformed(by:.init(translationX:-e.minX,y:-e.minY))
      let small=PreviewInteractiveProxyV3.canvas(normalized.samplingLinear().transformed(by:.init(scaleX:s,y:s)),width:w,height:h)
      let owner=try ThumbnailSurface(width:w,height:h,float:true,kind:.proxy,ledger:ledger,device:device)
      created=owner
        try owner.fill(small,context:context)
        if hasRAWFilter {
          // Exact one-ULP RAW proxy alpha roundoff only; legal partial/zero alpha is untouched.
          // Producer owns the surface until CPU unlock and all CI/context aliases drain.
          try owner.normalizeRawProxyAlphaRoundoff()
        }else{
          try owner.withFloatPixels{bytes,row in
            for y in 0..<owner.height{let values=bytes.advanced(by:y*row).assumingMemoryBound(to:Float.self)
              for x in 0..<(owner.width*4){guard values[x].isFinite else{throw DevelopmentThumbnailError.invalidEncoding}}}
          }
        }
        try validateCaptureAuthority();guard interest()else{throw DevelopmentThumbnailError.cancelled}
        return ThumbnailProxy(surface:owner,fingerprint:key,sourceBinding:source,sourceGeneration:generation,
          sourceIsRAW:hasRAWFilter,bakedBaseEV:bakedEV,preparationNanoseconds:DispatchTime.now().uptimeNanoseconds-start,cold:settledNativeImage==nil)
    }
    result.surface.finishProducer() // Context/native/CI views drained before producer pin ends.
    try validateCaptureAuthority();return result
    }catch{created?.finishProducer();created?.retire();throw error}
  }
}
