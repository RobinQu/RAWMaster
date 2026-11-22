import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// Ordered saturation refinement after the existing curve/level stage.
enum DevelopmentRefineSaturationEngineV3 {
  static let operatorVersion="rawmaster-refine-saturation-v1/encoded-srgb-luma/f32"
  private static let kernel:Result<CIKernel,Error>=Result {
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries else{throw DevelopmentError.unsupportedEngine}
    let all=try CIKernel.kernels(withMetalString:metalSource)
    guard let value=all.first(where:{$0.name=="rmRefineSaturation"})else{throw DevelopmentError.unsupportedEngine};return value
  }
  static func prewarm(){_ = try? kernel.get()}
  static func apply(_ curves:DevelopmentCurvesV3,to input:CIImage)throws->CIImage {
    try curves.validate()
    guard curves.enabled,let amount=curves.refineSaturation,amount != 0 else{return input}
    guard let output=try kernel.get().apply(extent:input.extent,roiCallback:{_,r in r},arguments:[input,Float(amount/100)])else{throw DevelopmentError.unreadable}
    return output
  }
  private static let metalSource=#"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float rsEncode(float x){float a=abs(x);return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055);}
float rsDecode(float x){float a=abs(x);return sign(x)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4));}
[[stitchable]] float4 rmRefineSaturation(sampler src,float amount,destination dest){
 float4 p=src.sample(src.transform(dest.coord()));if(!all(isfinite(p))||p.a<=0)return p;
 float3 c=p.rgb/p.a,e=float3(rsEncode(c.r),rsEncode(c.g),rsEncode(c.b));
 float y=dot(e,float3(.2126,.7152,.0722));e=float3(y)+(e-float3(y))*(1.0+amount);
 c=float3(rsDecode(e.r),rsDecode(e.g),rsDecode(e.b));return float4(c*p.a,p.a);
}
} }
"""#
}
