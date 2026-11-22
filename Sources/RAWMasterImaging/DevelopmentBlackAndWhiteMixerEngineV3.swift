import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// Preconditions chromatic luminance immediately before the existing B&W conversion.
/// Keeping this as a separate stage preserves the sealed point/grain shader and legacy recipes.
enum DevelopmentBlackAndWhiteMixerEngineV3 {
  static let operatorVersion = "rawmaster-bw-mixer-v1/eight-hue-bands/pre-pointwise-f32"
  private static let kernel: Result<CIKernel,Error> = Result {
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries else{throw DevelopmentError.unsupportedEngine}
    let all=try CIKernel.kernels(withMetalString:metalSource)
    guard let result=all.first(where:{$0.name=="rmBlackAndWhiteMixer"})else{throw DevelopmentError.unsupportedEngine}
    return result
  }
  static func prewarm(){_ = try? kernel.get()}
  static func apply(_ bw:DevelopmentBlackAndWhiteV3,to input:CIImage)throws->CIImage {
    try bw.validate()
    guard bw.enabled,let mixer=bw.mixer,mixer.isActive else{return input}
    let values=mixer.values
    let args:[Any]=[input,
      CIVector(x:values[0],y:values[1],z:values[2],w:values[3]),
      CIVector(x:values[4],y:values[5],z:values[6],w:values[7])]
    guard let output=try kernel.get().apply(extent:input.extent,roiCallback:{_,r in r},arguments:args)else{throw DevelopmentError.unreadable}
    return output
  }
  private static let metalSource=#"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float bwMixEncode(float x){float a=abs(x);return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055);}
float bwMixWeight(float hue,float center){float d=abs(hue-center);d=min(d,360.0-d);return 1.0-smoothstep(15.0,55.0,d);}
[[stitchable]] float4 rmBlackAndWhiteMixer(sampler src,float4 first,float4 second,destination dest){
 float4 p=src.sample(src.transform(dest.coord()));if(!all(isfinite(p))||p.a<=0)return p;
 float3 c=p.rgb/p.a;
 float3 e=float3(bwMixEncode(c.r),bwMixEncode(c.g),bwMixEncode(c.b));
 float hi=max(e.r,max(e.g,e.b)),lo=min(e.r,min(e.g,e.b));
 float chroma=clamp((hi-lo)/max(abs(hi),1e-4),0.0,1.0);
 if(chroma<=0)return p;
 float hue=atan2(sqrt(3.0)*(e.g-e.b),2.0*e.r-e.g-e.b)*180.0/M_PI_F;if(hue<0)hue+=360.0;
 float centers[8]={0,30,60,120,180,240,275,320};
 float amounts[8]={first.x,first.y,first.z,first.w,second.x,second.y,second.z,second.w};
 float adjustment=0;for(int i=0;i<8;i++)adjustment+=amounts[i]*bwMixWeight(hue,centers[i]);
 c*=exp2(.65*adjustment*chroma);
 return float4(c*p.a,p.a);
}
} }
"""#
}
