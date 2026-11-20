import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// Own public-CI/Metal spatial/color definitions, shared by every canonical consumer.
/// First implementations require their separate frozen-reference qualification.
enum DevelopmentGlobalEngineV3 {
  static let vignetteOperatorVersion = "rawmaster-vignette-v3.3/destination-space/short-side-circle/square-shoulder/owned-radius-softness"
  // One fixed 8-point train fit; held-out observations support one canonical experiment only.
  // These coefficients do not establish Photos equivalence for other images or parameter values.
  static let vignetteFalloffCoefficient = 2.8448556565369496
  static let vignetteOnset = 0.8278076728203464
  static let operatorVersion = "rawmaster-global-v3.1/definition-log-guide/selective-hsv/imageNR-ci/sharp-guide/"+vignetteOperatorVersion
  private struct Kernels { let guide, definition, selective, sharp, vignette, alpha: CIKernel }
  private static let loaded: Result<Kernels,Error> = Result {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsDynamicLibraries else { throw DevelopmentError.unsupportedEngine }
    let all = try CIKernel.kernels(withMetalString:metalSource)
    func get(_ name: String) throws -> CIKernel { guard let k = all.first(where: { $0.name == name }) else { throw DevelopmentError.unsupportedEngine }; return k }
    return try .init(guide:get("rmGlobalGuide"),definition:get("rmDefinition"),selective:get("rmSelective"),sharp:get("rmSharp"),vignette:get("rmVignette"),alpha:get("rmRestoreAlpha"))
  }
  /// Radius is in native pixels, independent of the whole-image canvas. Preserve
  /// the existing 1024x768 reference calibration (1.107456px at falloff .69).
  /// This is an owned units correction, not a recovered Photos falloff formula.
  static func sharpenRadiusInNativePixels(falloff: Double) -> Double {
    max(0.5,768.0*(0.0002+0.0018*falloff))
  }
  static func apply(_ p: DevelopmentAdjustmentsV3, to input: CIImage, sourceIsRAW: Bool) throws -> CIImage {
    try p.validate(); try p.noiseReduction.validate(for:sourceIsRAW ? .raw:.image)
    var image = input
    let extent = input.extent, short = min(extent.width,extent.height)
    guard short.isFinite, short > 0 else { throw DevelopmentV3Error.invalidGraph }
    if p.definition.enabled, p.definition.amount != 0 {
      let k = try loaded.get()
      guard let guide = k.guide.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,1.0]) else { throw DevelopmentError.unreadable }
      let mean = guide.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(1,short*0.006)]).cropped(to:extent)
      guard let result = k.definition.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,mean,p.definition.amount]) else { throw DevelopmentError.unreadable }
      image = result
    }
    if p.selectiveColor.enabled, p.selectiveColor.colors.contains(where: { $0.hue != 0 || $0.saturation != 0 || $0.luminance != 0 }) {
      let values = p.selectiveColor.colors.sorted { a,b in DevelopmentSelectiveColorSlotV3.allCases.firstIndex(of:a.slot)! < DevelopmentSelectiveColorSlotV3.allCases.firstIndex(of:b.slot)! }
      var table = [Float](repeating:0,count:6*4)
      for (i,v) in values.enumerated() {
        var center = Double(i)/6
        if let sample = v.sampledColor {
          center = hue(.init(DevelopmentColorEngineV2.encode(sample.red),DevelopmentColorEngineV2.encode(sample.green),DevelopmentColorEngineV2.encode(sample.blue)))
        }
        table[i*4] = Float(center); table[i*4+1] = Float(v.hue/360); table[i*4+2] = Float(v.saturation/100); table[i*4+3] = Float(v.luminance/70)
      }
      let data = table.withUnsafeBytes { Data($0) }
      let texture = CIImage(bitmapData:data,bytesPerRow:6*16,size:.init(width:6,height:1),format:.RGBAf,colorSpace:nil).samplingNearest()
      let ranges = values.map(\.range)
      guard let result = try loaded.get().selective.apply(extent:extent,roiCallback:{ index,r in index == 1 ? CGRect(x:0,y:0,width:6,height:1):r },
        arguments:[image,texture,CIVector(x:ranges[0],y:ranges[1],z:ranges[2],w:ranges[3]),CIVector(x:ranges[4],y:ranges[5])]) else { throw DevelopmentError.unreadable }
      image = result
    }
    if !sourceIsRAW, p.noiseReduction.enabled, p.noiseReduction.nonRawAmount != 0 {
      let filtered = image.clampedToExtent().applyingFilter("CINoiseReduction",parameters:["inputNoiseLevel":p.noiseReduction.nonRawAmount*0.02,"inputSharpness":0.0]).cropped(to:extent)
      guard let restored = try loaded.get().alpha.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,filtered]) else { throw DevelopmentError.unreadable }
      image = restored
    }
    if p.sharpen.enabled, p.sharpen.intensity != 0 {
      let k = try loaded.get(), s = p.sharpen
      guard let guide = k.guide.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,0.0]) else { throw DevelopmentError.unreadable }
      let radius = sharpenRadiusInNativePixels(falloff:s.falloff)
      let mean = guide.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
      guard let result = k.sharp.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,mean,CIVector(x:s.intensity,y:s.edges,z:s.falloff,w:0)]) else { throw DevelopmentError.unreadable }
      image = result
    }
    if p.vignette.enabled, p.vignette.strength != 0 {
      let v = p.vignette
      guard let result = try loaded.get().vignette.apply(extent:extent,roiCallback:{ _,r in r },
        arguments:[image,CIVector(x:extent.minX,y:extent.minY,z:extent.width,w:extent.height),CIVector(x:v.strength,y:v.radius,z:v.softness,w:0),
          CIVector(x:vignetteFalloffCoefficient,y:vignetteOnset)]) else { throw DevelopmentError.unreadable }
      image = result
    }
    return image
  }
  static func hue(_ rgb: SIMD3<Double>) -> Double {
    let high = max(rgb.x,max(rgb.y,rgb.z)), low = min(rgb.x,min(rgb.y,rgb.z)), d = high-low
    if d < 1e-8 { return 0 }
    var h: Double
    if high == rgb.x { h = (rgb.y-rgb.z)/d }
    else if high == rgb.y { h = 2+(rgb.z-rgb.x)/d }
    else { h = 4+(rgb.x-rgb.y)/d }
    h /= 6; return h-floor(h)
  }
  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float ge(float x) { float a=abs(x); return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055); }
float gd(float x) { float a=abs(x); return sign(x)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4)); }
float gy(float3 c) { return dot(c,float3(.2126,.7152,.0722)); }
float3 ghsv(float3 c) {
 float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo,h=0;
 if(d>1e-8) { if(hi==c.r) h=(c.g-c.b)/d; else if(hi==c.g) h=2.0+(c.b-c.r)/d; else h=4.0+(c.r-c.g)/d; }
 h=h/6.0-floor(h/6.0); return float3(h,hi>1e-8?d/hi:0.0,hi);
}
float3 grgb(float3 hsv) {
 float3 p=abs(fract(hsv.xxx+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0);
 return hsv.z*mix(float3(1),clamp(p-1.0,0.0,1.0),hsv.y);
}
[[stitchable]] float4 rmGlobalGuide(sampler src,float logarithmic) {
 float4 p=src.sample(src.coord()); if(!all(isfinite(p))) return p;
 float y=p.a>0?gy(p.rgb/p.a):0;
 if(logarithmic>0) y=log2(max(y,exp2(-20.0))); return float4(y,y,y,1);
}
[[stitchable]] float4 rmDefinition(sampler src,sampler guide,float amount) {
 float4 p=src.sample(src.coord()); if(!all(isfinite(p))||p.a<=0) return p;
 float3 c=p.rgb/p.a; float y=gy(c),u=clamp(ge(y),0.0,1.0),local=guide.sample(guide.coord()).r;
 float gain=exp2(amount*.45*(4*u*(1-u))*clamp(log2(max(y,exp2(-20.0)))-local,-3.0,3.0));
 return float4(c*gain*p.a,p.a);
}
[[stitchable]] float4 rmSelective(sampler src,sampler table,float4 ranges,float2 tail) {
 float4 p=src.sample(src.coord()); if(!all(isfinite(p))||p.a<=0) return p;
 float3 c=p.rgb/p.a,e=float3(ge(c.r),ge(c.g),ge(c.b)),hsv=ghsv(e); float3 delta=0;float total=0;
 for(int i=0;i<6;i++) { float4 v=table.sample(float2(float(i)+.5,.5));float range=i<4?ranges[i]:tail[i-4];
  float d=abs(hsv.x-v.x);d=min(d,1.0-d);float width=max(.005,.2*range);
  float w=(1.0-smoothstep(width*.3,width,d))*smoothstep(.015,.12,hsv.y);delta+=w*v.yzw;total+=w;
 }
 delta/=max(1.0,total);if(all(delta==float3(0)))return p;
 hsv.x=fract(hsv.x+delta.x+1.0);hsv.y=max(0.0,hsv.y*(1.0+delta.y));
 float3 out=grgb(hsv);float y=gy(out),u=clamp(y,0.0,1.0);out+=delta.z*.35*4*u*(1-u);
 return float4(float3(gd(out.r),gd(out.g),gd(out.b))*p.a,p.a);
}
[[stitchable]] float4 rmSharp(sampler src,sampler guide,float4 params) {
 float4 p=src.sample(src.coord());if(!all(isfinite(p))||p.a<=0)return p;float3 c=p.rgb/p.a;
 float y=gy(c),mean=guide.sample(guide.coord()).r,d=abs(y-mean)/max(.005,abs(y)+abs(mean));
 float threshold=.01+.3*params.y,mask=smoothstep(threshold,threshold+.02+.1*params.z,d);
 float out=y+2.0*params.x*(y-mean)*mask;float3 rgb=abs(y)>1e-8?c*(out/y):c+float3(out-y);
 return float4(rgb*p.a,p.a);
}
[[stitchable]] float4 rmVignette(sampler src,float4 extent,float4 params,float2 fit,destination dest) {
 float2 world=dest.coord();float4 p=src.sample(src.transform(world));if(!all(isfinite(p))||p.a<=0)return p;
 // Working-space distance, with the same physical scale on both axes. Sampler coordinates
 // need not be world pixels, and normalizing axes independently would make an ellipse.
 float2 xy=(world-(extent.xy+extent.zw*.5))/(min(extent.z,extent.w)*.5);
 // Owned v3.3 semantics: radius moves the shoulder; softness reduces its quadratic slope.
 float shoulder=max(0.0,length(xy)-(fit.y+params.y-.5));
 float ev=-2.0*params.x*fit.x*shoulder*shoulder/(1.0+2.0*params.z);
 return float4(p.rgb*exp2(ev),p.a);
}
[[stitchable]] float4 rmRestoreAlpha(sampler src,sampler filtered) {
 float4 p=src.sample(src.coord()),q=filtered.sample(filtered.coord());
 if(!all(isfinite(p)))return p;if(!all(isfinite(q)))return q;if(p.a<=0)return p;
 if(q.a<=0)return float4(as_type<float>(0x7fc00000u));return float4(q.rgb/q.a*p.a,p.a);
}
} }
"""#
}
