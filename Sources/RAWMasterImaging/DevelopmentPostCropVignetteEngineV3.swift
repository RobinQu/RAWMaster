import CoreImage
import Foundation
import Metal
import RAWMasterCore

enum DevelopmentPostCropVignetteEngineV3 {
  static let operatorVersion = "rawmaster-post-crop-vignette-v2/final-canvas/style-highlight-feather"
  private static let kernel: Result<CIKernel,Error> = Result {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsDynamicLibraries else { throw DevelopmentError.unsupportedEngine }
    let all = try CIKernel.kernels(withMetalString:metalSource)
    guard let result = all.first(where: { $0.name == "rmPostCropVignette" }) else { throw DevelopmentError.unsupportedEngine }
    return result
  }
  static func prewarm(){_ = try? kernel.get()}
  static func apply(_ effects: DevelopmentEffectsV3?, to input: CIImage) throws -> CIImage {
    guard let value = effects?.postCropVignette else { return input }
    try value.validate(); guard value.isActive else { return input }
    let extent = input.extent
    guard !extent.isEmpty, [extent.minX,extent.minY,extent.width,extent.height].allSatisfy(\.isFinite) else { throw DevelopmentV3Error.invalidGraph }
    let style: Double = switch value.style { case .highlightPriority:0; case .colorPriority:1; case .paintOverlay:2 }
    let args:[Any] = [input,CIVector(x:extent.minX,y:extent.minY,z:extent.width,w:extent.height),
      CIVector(x:value.amount/100,y:value.midpoint/100,z:value.roundness/100),
      CIVector(x:value.feather/100,y:value.highlights/100,z:style)]
    guard let output = try kernel.get().apply(extent:extent,roiCallback:{ _,r in r },arguments:args) else { throw DevelopmentError.unreadable }
    return output
  }
  static let pixelTransferMetal = #"""
 float roundness=clamp(amount.z,-1.0,1.0);
 float2 xy=mix(oval,circle,roundness);
 if(roundness<0)xy.x*=1.0+abs(roundness)*.35;
 float distance=length(xy);
 float onset=.32+amount.y*.58;
 float feather=.06+options.x*.62;
 float coverage=smoothstep(onset,onset+feather,distance);
 float strength=amount.x;
 float style=options.z;
 float highlight=smoothstep(.62,1.0,clamp(pcvY(p.rgb/max(p.a,1e-6)),0.0,1.0))*options.y;
 if(strength<0&&style<1.5)coverage*=1.0-highlight*.85;
 float3 c=p.rgb/p.a;
 if(style>1.5) {
  float3 target=strength<0?float3(0):float3(1);
  c=mix(c,target,coverage*abs(strength));
 } else if (style < .5) {
  // A luminance shoulder protects bright edges. Color Priority scales all channels together.
  float shoulder=smoothstep(.35,1.0,max(0.0,pcvY(c)));
  c*=exp2(strength*coverage*1.15*(1.0-.5*shoulder));
 } else {
  c*=exp2(strength*coverage*1.15);
 }
 return float4(c*p.a,p.a);
"""#
  private static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float pcvY(float3 c) { return dot(c,float3(.2126,.7152,.0722)); }
[[stitchable]] float4 rmPostCropVignette(sampler src,float4 extent,float4 amount,float4 options,destination dest) {
 float4 p=src.sample(src.transform(dest.coord()));if(!all(isfinite(p))||p.a<=0)return p;
 float2 center=extent.xy+extent.zw*.5;
 float2 oval=(dest.coord()-center)/(extent.zw*.5);
 float2 circle=(dest.coord()-center)/(min(extent.z,extent.w)*.5);
\#(pixelTransferMetal)
}
} }
"""#
}
