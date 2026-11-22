import Foundation
import CoreImage
import Metal
import RAWMasterCore

enum DevelopmentWhiteBalanceEngineV3 {
  static let operatorVersion = "rawmaster-WB-v3.2/absolute-nativeTT/fresh-asShot/skin-locus-Bradford-v1/imageTT-reference5000"
  private static let kernel: Result<CIKernel,Error> = Result {
    let all = try CIKernel.kernels(withMetalString:#"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmAbsoluteWB(sampler src,float4 r,float4 g,float4 b) {
 float4 p=src.sample(src.coord());if(!all(isfinite(p))||p.a<=0)return p;
 float3 c=p.rgb/p.a;return float4(float3(dot(c,r.xyz),dot(c,g.xyz),dot(c,b.xyz))*p.a,p.a);
}
} }
"""#)
    guard let result = all.first(where: { $0.name == "rmAbsoluteWB" }) else { throw DevelopmentError.unsupportedEngine }; return result
  }
  static func prewarm(){_ = try? kernel.get()}
  static func initialState(source: DevelopmentLocalEditSourceBinding, rawDefault: DevelopmentAsShotWhiteBalance?) throws -> DevelopmentResolvedWhiteBalanceV3 {
    let result: DevelopmentResolvedWhiteBalanceV3
    if let rawDefault {
      let tt = DevelopmentNativeWhiteBalanceV3(temperature:rawDefault.temperature,tint:rawDefault.tint)
      let pick = DevelopmentRawWhiteBalancePickV3(baseline:tt,usesSourceDefaultAtZero:true)
      // Inactive manual-mode seed is within its UI domain; original/as-shot diagnostics and
      // default-derived pick baselines retain their actual values and are never assigned here.
      let manual = DevelopmentNativeWhiteBalanceV3(temperature:min(50000,max(2000,tt.temperature)),tint:tt.tint)
      result = .raw(source:source,state:.init(defaultTTDiagnostic:tt,temperatureTint:manual,gray:pick,skin:pick))
    } else {
      let neutral = DevelopmentImageWhiteBalancePickV3(baseline:.identity,sampledLinearRGB:.init(red:1,green:1,blue:1))
      // This is a direct-mode working reference candidate, not TIFF camera/as-shot metadata.
      result = .image(source:source,state:.init(temperatureTint:.init(temperature:5000,tint:0),gray:neutral,skin:neutral))
    }
    try result.validate(expectedSource:source); return result
  }
  static func nativeTarget(_ p: DevelopmentWhiteBalanceV3) throws -> DevelopmentWhiteBalance? {
    guard p.enabled else { return nil }
    if let resolved = p.resolvedState {
      guard case .raw(_,let s) = resolved else { throw EditingError.invalidRecipe }
      guard let tt = try s.nativeTarget() else { return .asShot }
      return .temperatureTint(temperature:Double(tt.temperature),tint:Double(tt.tint))
    }
    switch p.adjustment {
    case .asShot:return .asShot
    case let .temperatureTint(t,v):return .temperatureTint(temperature:t,tint:v)
    default:throw DevelopmentV3Error.unsupportedAdjustment(.whiteBalance)
    }
  }
  /// Shared linear-sRGB FlashRaw prefix. The base remains neutral; WB/EV are GPU operations on it.
  static func applyFlashRaw(_ p:DevelopmentAdjustmentsV3,to image:CIImage,asShotWhiteBalance:DevelopmentAsShotWhiteBalance?)throws->CIImage {
    var image=image
    if let basis=p.legacyBasis,basis.exposureEV != 0 { image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:basis.exposureEV]) }
    let requested=try nativeTarget(p.whiteBalance) ?? p.legacyBasis?.whiteBalance ?? .asShot
    if case let .temperatureTint(t,v)=requested {
      guard let original=asShotWhiteBalance else{throw DevelopmentV3Error.unsupportedNativeParameters}
      image=image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:CGFloat(original.temperature),y:CGFloat(original.tint)),"inputTargetNeutral":CIVector(x:t,y:v)])
    }
    if p.light.enabled,p.light.exposure != 0 { image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:2*p.light.exposure]) }
    return image
  }
  static func applyImage(_ p: DevelopmentWhiteBalanceV3, to image: CIImage, context: CIContext, checkCancellation: (() throws -> Void)? = nil) throws -> CIImage {
    guard p.enabled else { return image }
    var matrix: DevelopmentRGBMatrixV3?
    let adjustment: DevelopmentWhiteBalanceAdjustmentV3
    if let resolved = p.resolvedState {
      guard case .image(_,let s) = resolved else { throw EditingError.invalidRecipe }
      adjustment = resolved.displayAdjustment
      switch s.selectedMode { case .neutralGray:matrix = try s.gray!.matrix(); case .skinTone:matrix = try s.skin!.matrix(); default:break }
    } else { adjustment = p.adjustment }
    if let matrix {
      if matrix == .identity { return image }
      let m = matrix.values
      guard let result = try kernel.get().apply(extent:image.extent,roiCallback:{ _,r in r },arguments:[image,
        CIVector(x:m[0],y:m[1],z:m[2],w:0),CIVector(x:m[3],y:m[4],z:m[5],w:0),CIVector(x:m[6],y:m[7],z:m[8],w:0)]) else { throw DevelopmentError.unreadable }
      return result
    }
    switch adjustment {
    case .asShot:return image
    case let .temperatureTint(t,v):
      if t == 5000 && v == 0 { return image }
      try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation)
      return image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:t,y:v),"inputTargetNeutral":CIVector(x:5000,y:0)])
    default:throw DevelopmentV3Error.unsupportedAdjustment(.whiteBalance)
    }
  }
}
