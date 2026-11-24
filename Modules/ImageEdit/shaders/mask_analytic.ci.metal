#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
// RM_MASK_GEOMETRY
// RM_MASK_GRAIN_TRANSFER
// RM_COLOR_GRAIN_LATTICE
[[stitchable]] float4 rmAnalyticalMaskGrain(sampler src,float4 mode,float4 line,float4 radial,float4 range,float4 settings,destination dest){
  float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
  if(!all(isfinite(pixel))||pixel.a<=0)return pixel;
  float mask=rmMaskCompute(pixel,src,mode,line,radial,range,at);
  return rmCompositeGrain(pixel,rmSourceGrainSample(at,settings),mask,settings.x);
}
} }
