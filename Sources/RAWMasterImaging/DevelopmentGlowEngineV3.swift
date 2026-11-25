import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// Source-scale, GPU-evaluated glow. Public CI blur is used for isotropic styles; directional
/// styles use an owned Metal sampler with one- or two-sided falloff.
enum DevelopmentGlowEngineV3 {
  static let operatorVersion = "rawmaster-glow-v1/highlight-range/isotropic-directional/f32"
  private struct Kernels { let source, directional, composite: CIKernel }
  private static let loaded: Result<Kernels,Error> = Result {
    guard DevelopmentKernelCapability.supported else { throw DevelopmentError.unsupportedEngine }
    let all = try CIKernel.kernels(withMetalString:metalSource)
    func get(_ name: String) throws -> CIKernel { guard let k = all.first(where: { $0.name == name }) else { throw DevelopmentError.unsupportedEngine }; return k }
    return try .init(source:get("rmGlowSource"),directional:get("rmGlowDirectional"),composite:get("rmGlowComposite"))
  }

  static func prewarm(){_ = try? loaded.get()}
  static func apply(_ effects: DevelopmentEffectsV3?, to input: CIImage) throws -> CIImage {
    guard let glow = effects?.glow else { return input }
    return try apply(glow,to:input)
  }

  static func apply(_ glow: DevelopmentGlowV3, to input: CIImage) throws -> CIImage {
    try glow.validate(); guard glow.isActive else { return input }
    let extent = input.extent, short = min(extent.width,extent.height)
    guard [extent.minX,extent.minY,extent.width,extent.height].allSatisfy(\.isFinite), !extent.isEmpty, short > 0 else { throw DevelopmentV3Error.invalidGraph }
    let kernels = try loaded.get()
    let threshold = max(0,1-glow.range/100)
    let style = styleCode(glow.style)
    guard let source = kernels.source.apply(extent:extent,roiCallback:{ _,r in r },arguments:[input,Float(threshold),style]) else { throw DevelopmentError.unreadable }
    let spreadPixels = max(1,short*(0.002+glow.spread/100*0.04))
    let blurred: CIImage
    if glow.style.usesDirectionalControls {
      let radians = Float(glow.direction)*Float.pi/180
      let direction = SIMD2<Float>(cos(radians),sin(radians))
      let softness = Float(glow.softness)/100
      let directionalSource = source.clampedToExtent()
      guard let result = kernels.directional.apply(extent:extent,roiCallback:{ _,r in r.insetBy(dx:-CGFloat(spreadPixels),dy:-CGFloat(spreadPixels)) },
        arguments:[directionalSource,CIVector(x:CGFloat(direction.x),y:CGFloat(direction.y)),Float(spreadPixels),softness,style]) else { throw DevelopmentError.unreadable }
      blurred = result.cropped(to:extent)
    } else {
      blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:spreadPixels]).cropped(to:extent)
    }
    let warmth = Float(glow.warmth)/100
    let amount = Float(glow.amount)/100
    guard let output = kernels.composite.apply(extent:extent,roiCallback:{ _,r in r },
      arguments:[input,blurred,amount,warmth,style]) else { throw DevelopmentError.unreadable }
    return output
  }

  private static func styleCode(_ style: DevelopmentGlowStyleV3) -> Float {
    switch style { case .bloom:0; case .diffusion:1; case .halation:2; case .motion:3; case .streak:4 }
  }

  private static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float glowY(float3 c) { return dot(c,float3(.2126,.7152,.0722)); }
float glowEncode(float x) { float a=abs(x);return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055); }
[[stitchable]] float4 rmGlowSource(sampler src,float threshold,float style,destination dest) {
 float4 p=src.sample(src.transform(dest.coord()));if(!all(isfinite(p))||p.a<=0)return p;
 float3 c=p.rgb/p.a;float y=clamp(glowEncode(glowY(c)),0.0,1.0);
 float w=smoothstep(max(0.0,threshold-.12),min(1.0,threshold+.12),y);
 if(style>0.5&&style<1.5)w=mix(w,.18,.35); // Diffusion retains some full-frame softness.
 return float4(c*w*p.a,p.a);
}
[[stitchable]] float4 rmGlowDirectional(sampler src,float2 direction,float spread,float softness,float style,destination dest) {
 float2 origin=dest.coord();float4 total=float4(0);float weight=0.0;
 const int taps=33;
 for(int i=0;i<taps;i++) {
  float unit=style<3.5?float(i)/32.0:float(i-16)/16.0;
  float distance=fabs(unit);float w=pow(max(0.0,1.0-distance),.5+softness*3.0);
  float2 p=origin-direction*unit*spread;
  total+=src.sample(p)*w;weight+=w;
 }
 return total/max(weight,1e-5);
}
float3 glowTint(float warmth,float style) {
 if(style>1.5&&style<2.5)return mix(float3(1.0,.55,.12),float3(1.0,.12,.04),clamp(warmth,0.0,1.0));
 float warm=clamp(warmth,-1.0,1.0);
 return warm>=0?mix(float3(1),float3(1.0,.72,.42),warm):mix(float3(1),float3(.55,.72,1.0),-warm);
}
[[stitchable]] float4 rmGlowComposite(sampler src,sampler glow,float amount,float warmth,float style,destination dest) {
 float2 at=dest.coord();float4 p=src.sample(src.transform(at)),g=glow.sample(glow.transform(at));
 if(!all(isfinite(p))||!all(isfinite(g))||p.a<=0)return p;
 float3 c=p.rgb/p.a,light=g.rgb/max(g.a,1e-6);
 float strength=amount*(style>2.5?1.1:1.35);
 float3 out=c+light*glowTint(warmth,style)*strength;
 if(style>0.5&&style<1.5)out=mix(c,mix(c,light,.45)+light*.2,amount);
 return float4(out*p.a,p.a);
}
} }
"""#
}
