import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// Own version-1 atmospheric-like operation, not an ACR/Photos identity claim.
/// No estimator, hidden Auto, spatial proxy or RGB clipping is used by rendering.
enum DevelopmentDehazeEngineV3 {
  static let operatorVersion="rawmaster-dehaze-v1/native-min-.003/gaussian-half/.85-tmin.20/linear-F32"
  static func usesPositiveV2(_ parameters: DevelopmentAdvancedDetailV3?) -> Bool {
    guard let parameters else { return false }
    return parameters.dehaze.enabled && parameters.dehaze.amount > 0 &&
      parameters.preparedDehaze?.algorithmVersion == DevelopmentDehazeAlgorithm.positiveColorGuideV2.rawValue
  }
  /// Shared render/cache identity. Only the real RAW caller may opt into this boundary.
  /// Preparation and its decoder fingerprint remain unchanged: this stage follows estimation.
  static func rawPositiveV2CoverageSuffix(_ parameters:DevelopmentAdvancedDetailV3?,sourceIsRAW:Bool)->String {
    guard sourceIsRAW,let parameters,parameters.dehaze.enabled,parameters.dehaze.amount != 0 else { return "" }
    // Keep the existing positive-v2 identity unchanged. The historical function name is
    // also used by the shared bitmap-key/graph descriptor callers for the new v1 repair.
    if usesPositiveV2(parameters) {
      return "/raw-positive-v2/native-upper-coverage-v1/"+PreviewFITCoverageV1.version
    }
    // Algorithm 2 uses the unchanged v1 math for negative amounts. Apply the same
    // narrowly bounded native RAW coverage repair when that signed route is selected.
    return parameters.preparedDehaze != nil ? "/"+DevelopmentDehazeRAWCoverageV1.version:""
  }
  private struct Kernels { let guide,apply:CIKernel }
  private static let loaded: Result<Kernels,Error> = Result {
    guard DevelopmentKernelCapability.supported else { throw DevelopmentError.unsupportedEngine }
    let kernels=try CIKernel.kernels(withMetalString:metalSource)
    guard let guide=kernels.first(where:{$0.name=="rmDehazeGuideV1"}),let apply=kernels.first(where:{$0.name=="rmDehazeApplyV1"}) else { throw DevelopmentError.unsupportedEngine }
    return .init(guide:guide,apply:apply)
  }
  static func apply(_ parameters:DevelopmentAdvancedDetailV3,to image:CIImage,sourceSize:DevelopmentPixelSize,
                    sourceIsRAW:Bool=false,context:CIContext,checkCancellation:(()throws->Void)?=nil,
                    checkedInput:CIImage?=nil,residentGuide:DevelopmentResidentDehazeGuide?=nil)throws->CIImage {
    try parameters.validate()
    let value=parameters.dehaze
    guard value.enabled,value.amount != 0 else { return image }
    guard let prepared=parameters.preparedDehaze else { throw DevelopmentDehazePreparationError.preparationRequired }
    try prepared.validate();try sourceSize.validate()
    guard prepared.sourceBinding.sourceSize==sourceSize else { throw DevelopmentDehazePreparationError.preparationRequired }
    guard image.extent.width==Double(sourceSize.width),image.extent.height==Double(sourceSize.height) else { throw DevelopmentV3Error.invalidGraph }
    if checkedInput === image {
      try Task.checkCancellation()
      try checkCancellation?()
    } else {
      try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation)
    }
    let result: CIImage
    if usesPositiveV2(parameters) {
      guard image.extent.origin == .zero else { throw DevelopmentV3Error.invalidGraph }
      // Native RAW may carry finite upper coverage. Preserve its straight color before
      // both strict operators; malformed values still reach their original rejection.
      let input:CIImage
      let proofInput: DevelopmentDehazeRestoreProof.NativeInput?
      if rawPositiveV2CoverageSuffix(parameters,sourceIsRAW:sourceIsRAW).isEmpty {
        input=image; proofInput=nil
      } else if DevelopmentDehazeRestoreProof.enabled, let residentGuide, residentGuide.mayCertifyRestore, checkedInput === image {
        let pair = try DevelopmentDehazeRestoreProof.NativeInput(normalizing:image)
        input=pair.normalized; proofInput=pair
      } else {
        input=try PreviewFITCoverageV1.normalize(image,extent:image.extent); proofInput=nil
      }
      if let guide = try residentGuide?.acquire(input:input,checkedSource:sourceIsRAW && checkedInput === image ? image : nil,
                                                positive:true,airlight:prepared.airlight,
                                                size:sourceSize,check:checkCancellation) {
        if let proofInput, let residentGuide,
           let restored = try residentGuide.certifiedRestore(proofInput,guide:guide,airlight:prepared.airlight,
                                                            amount:value.amount,context:context) {
          try Task.checkCancellation()
          try checkCancellation?()
          return restored
        }
        result = try DevelopmentDehazeRfTransportV1.restoreNative(input,guide,airlight:prepared.airlight,amount:value.amount)
      } else if let bounded=try DevelopmentDehazeNativeRfV1.apply(.positiveV2,to:input,airlight:prepared.airlight,
        sourceSize:sourceSize,amount:value.amount,context:context,checkCancellation:checkCancellation){result=bounded}
      else{
        let guide=try DevelopmentDehazeColorGuideV2.guide(input,airlight:prepared.airlight,sourceSize:sourceSize)
        result=try DevelopmentDehazeColorGuideV2.restore(input,guide:guide,airlight:prepared.airlight,amount:value.amount)
      }
    } else {
      let input:CIImage
      if sourceIsRAW {
        input=try DevelopmentDehazeRAWCoverageV1.normalize(image)
      }else{input=image}
      if let guide = try residentGuide?.acquire(input:input,positive:false,airlight:prepared.airlight,
                                                size:sourceSize,check:checkCancellation) {
        result = try applyGuide(to:input,guide:guide,airlight:prepared.airlight,amount:value.amount)
      } else if let bounded=try DevelopmentDehazeNativeRfV1.apply(.signedV1,to:input,airlight:prepared.airlight,
        sourceSize:sourceSize,amount:value.amount,context:context,checkCancellation:checkCancellation){result=bounded}
      else{
        let guide=try darkGuide(input,airlight:prepared.airlight,sourceSize:sourceSize)
        result=try applyGuide(to:input,guide:guide,airlight:prepared.airlight,amount:value.amount)
      }
    }
    let finalCheck: (() throws -> Void)?
    if let residentGuide, residentGuide.usesHalfErosion {
      finalCheck = { try checkCancellation?(); try residentGuide.check() }
    } else { finalCheck = checkCancellation }
    try DevelopmentColorEngineV3.validateFinite(result,context:context,checkCancellation:finalCheck)
    return result
  }
  static func makeGuide(_ image:CIImage,airlight:DevelopmentDehazeAirlightV1)throws->CIImage {
    try airlight.validate()
    guard let guide=try loaded.get().guide.apply(extent:image.extent,roiCallback:{ _,r in r },
      arguments:[image.samplingNearest(),CIVector(x:airlight.red,y:airlight.green,z:airlight.blue,w:0)]) else { throw DevelopmentV3Error.invalidGraph };return guide
  }
  static func darkGuide(_ image:CIImage,airlight:DevelopmentDehazeAirlightV1,sourceSize:DevelopmentPixelSize)throws->CIImage {
    try sourceSize.validate();let e=image.extent,guide=try makeGuide(image,airlight:airlight)
    let radius=max(1,Double(min(sourceSize.width,sourceSize.height))*0.003)
    let minimum=guide.clampedToExtent().applyingFilter("CIMorphologyMinimum",parameters:[kCIInputRadiusKey:radius]).cropped(to:e)
    return minimum.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(0.5,radius/2)]).cropped(to:e)
  }
  static func applyGuide(to image:CIImage,guide:CIImage,airlight:DevelopmentDehazeAirlightV1,amount:Double)throws->CIImage {
    try airlight.validate()
    guard amount.isFinite,(-100...100).contains(amount) else { throw DevelopmentV3Error.invalidGraph }
    if amount==0 { return image }
    guard let result=try loaded.get().apply.apply(extent:image.extent,roiCallback:{ _,r in r },
      arguments:[image.samplingNearest(),guide.samplingNearest(),CIVector(x:airlight.red,y:airlight.green,z:airlight.blue,w:amount/100)]) else { throw DevelopmentV3Error.invalidGraph };return result
  }
  static func referencePixel(_ p:SIMD4<Double>,airlight:DevelopmentDehazeAirlightV1,dark:Double,amount:Double)throws->SIMD4<Double> {
    try airlight.validate()
    guard [p.x,p.y,p.z,p.w,dark,amount].allSatisfy(\.isFinite),(0...1).contains(p.w),(-100...100).contains(amount),(0...1).contains(dark) else { throw DevelopmentError.invalidEncoding }
    if amount==0 || p.w<1.0/65535 { return p }
    let u=SIMD3(p.x,p.y,p.z)/p.w,a=SIMD3(airlight.red,airlight.green,airlight.blue),v=amount/100
    let j:SIMD3<Double>
    if v>=0 { let t=min(1,max(0.2,1-0.85*v*dark));j=(u-a)/t+a }
    else { let t=1/(1+0.85*(-v)*dark);j=t*u+(1-t)*a }
    let result=SIMD4(j.x*p.w,j.y*p.w,j.z*p.w,p.w)
    guard [result.x,result.y,result.z,result.w].allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding };return result
  }
  static let metalSource=#"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmDehazeGuideV1(sampler src,float4 air,destination dest){
 float4 p=src.sample(src.transform(dest.coord()));
 if(!all(isfinite(p))||p.a<0||p.a>1)return float4(as_type<float>(0x7fc00000u));
 if(p.a<1.0/65535.0)return float4(1,0,0,1);
 float3 u=max(p.rgb/p.a,float3(0))/air.rgb;
 if(!all(isfinite(u)))return float4(as_type<float>(0x7fc00000u));
 return float4(clamp(min(u.r,min(u.g,u.b)),0.0,1.0),0,0,1);
}
[[stitchable]] float4 rmDehazeApplyV1(sampler src,sampler guide,float4 air,destination dest){
 float2 d=dest.coord();float4 p=src.sample(src.transform(d));
 if(!all(isfinite(p))||p.a<0||p.a>1)return float4(as_type<float>(0x7fc00000u));
 if(p.a<1.0/65535.0)return p;
 float dark=guide.sample(guide.transform(d)).r;
 if(!isfinite(dark))return float4(as_type<float>(0x7fc00000u));
 float3 u=p.rgb/p.a,j;float a=air.a;
 if(a>=0){float t=clamp(1-.85*a*dark,.20,1.0);j=(u-air.rgb)/t+air.rgb;}
 else{float t=1/(1+.85*(-a)*dark);j=t*u+(1-t)*air.rgb;}
 return float4(j*p.a,p.a);
}
} }
"""#
}
