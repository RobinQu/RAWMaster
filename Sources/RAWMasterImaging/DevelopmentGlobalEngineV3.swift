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
  static let operatorVersion = "rawmaster-global-v3.11-point-uniforms/clipping-preview/hue-isolation/definition-log-guide/selective-hsv-legacy6-current8-variance-v1/defringe-v1/imageNR-ci/noise-luminance-contrast-color-detail-v1/sharp-radius-detail-masking-preview-v1/"+vignetteOperatorVersion+"/"+DevelopmentOpticsEngineV3.operatorVersion
  private struct Kernels { let guide, definition, selective, selectiveVariance, selectivePointCloud, noiseDetail, sharp, sharpResponse, sharpMask, vignette, alpha, clipping: CIKernel }
  private static let loaded: Result<Kernels,Error> = Result {
    guard DevelopmentKernelCapability.supported else { throw DevelopmentError.unsupportedEngine }
    let all = try CIKernel.kernels(withMetalString:metalSource)
    func get(_ name: String) throws -> CIKernel { guard let k = all.first(where: { $0.name == name }) else { throw DevelopmentError.unsupportedEngine }; return k }
    return try .init(guide:get("rmGlobalGuide"),definition:get("rmDefinition"),selective:get("rmSelective"),selectiveVariance:get("rmSelectiveVariance"),selectivePointCloud:get("rmSelectivePointCloud"),noiseDetail:get("rmNoiseDetail"),sharp:get("rmSharp"),sharpResponse:get("rmNativeSharpResponse"),sharpMask:get("rmNativeSharpMask"),vignette:get("rmVignette"),alpha:get("rmRestoreAlpha"),clipping:get("rmClippingPreview"))
  }
  /// Radius is in native pixels, independent of the whole-image canvas. Preserve
  /// the existing 1024x768 reference calibration (1.107456px at falloff .69).
  /// This is an owned units correction, not a recovered Photos falloff formula.
  static func sharpenRadiusInNativePixels(falloff: Double) -> Double {
    max(0.5,768.0*(0.0002+0.0018*falloff))
  }
  static func prewarm(){_ = try? loaded.get(); _ = DevelopmentPointColorKernelV3.kernel}
  static func apply(_ p: DevelopmentAdjustmentsV3, to input: CIImage, sourceIsRAW: Bool, preparedSharpMean:CIImage? = nil,
                    noiseDomain: PreviewNativeNoiseDomain? = nil) throws -> CIImage {
    try p.validate(); try p.noiseReduction.validate(for:sourceIsRAW ? .raw:.image)
    var image = try DevelopmentOpticsEngineV3.apply(p.optics,to:input)
    let extent = input.extent, short = min(extent.width,extent.height)
    guard short.isFinite, short > 0 else { throw DevelopmentV3Error.invalidGraph }
    if p.definition.enabled, p.definition.amount != 0 {
      let k = try loaded.get()
      guard let guide = k.guide.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,1.0]) else { throw DevelopmentError.unreadable }
      let mean = guide.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(1,short*0.006)]).cropped(to:extent)
      guard let result = k.definition.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,mean,p.definition.amount]) else { throw DevelopmentError.unreadable }
      image = result
    }
    let pointValues=(p.selectiveColor.pointColors ?? []).filter(\.isActive).map { sample in
      DevelopmentSelectiveColorAdjustmentV3(slot:.red,sampledColor:sample.sampledColor,hue:sample.hue,
        saturation:sample.saturation,luminance:sample.luminance,range:sample.range,variance:sample.variance)
    }
    let fixedActive=p.selectiveColor.colors.contains { $0.hue != 0 || $0.saturation != 0 || $0.luminance != 0 || ($0.variance ?? 0) != 0 }
    if (p.selectiveColor.enabled && (fixedActive || !pointValues.isEmpty)) || p.selectiveColor.visualiseRange != nil || p.selectiveColor.visualiseIsolation != nil {
      let fixed = p.selectiveColor.colors.sorted { a,b in DevelopmentSelectiveColorSlotV3.allCases.firstIndex(of:a.slot)! < DevelopmentSelectiveColorSlotV3.allCases.firstIndex(of:b.slot)! }
      let values = fixed + pointValues
      let count = values.count, hasVariance=values.contains { ($0.variance ?? 0) != 0 }
      // Two RGBAf rows: H/S/L shifts, then range, variance and sampled S/V targets.
      // The entire legacy second row, including unused zero channels, stays bit-exact without Variance.
      var table = [Float](repeating:0,count:count*8)
      for (i,v) in values.enumerated() {
        var center = Double(i)/Double(fixed.count), targetSaturation = 1.0, targetValue = 1.0
        if let sample = v.sampledColor {
          let encoded=SIMD3<Double>(DevelopmentColorEngineV2.encode(sample.red),DevelopmentColorEngineV2.encode(sample.green),DevelopmentColorEngineV2.encode(sample.blue))
          center = hue(encoded)
          let high=max(encoded.x,max(encoded.y,encoded.z)),low=min(encoded.x,min(encoded.y,encoded.z))
          targetSaturation=high>1e-8 ? (high-low)/high:0;targetValue=high
        }
        table[i*4] = Float(center); table[i*4+1] = Float(v.hue/360); table[i*4+2] = Float(v.saturation/100); table[i*4+3] = Float(v.luminance/70)
        table[count*4+i*4] = Float(v.range)
        if hasVariance {
          table[count*4+i*4+1] = Float((v.variance ?? 0)/100)
          table[count*4+i*4+2] = Float(targetSaturation);table[count*4+i*4+3] = Float(targetValue)
        }
      }
      let preview = p.selectiveColor.visualiseIsolation ?? p.selectiveColor.visualiseRange
      let singlePoint = !fixedActive && pointValues.count == 1
      if preview != nil || singlePoint {
        let index: Int
        if let preview {
          guard let slot = fixed.firstIndex(where: { $0.slot == preview }) else { throw DevelopmentV3Error.invalidGraph }
          index = slot
        } else {
          index = fixed.count
        }
        guard index < count, let kernel = DevelopmentPointColorKernelV3.kernel else { throw DevelopmentV3Error.invalidGraph }
        let offset = index * 4, target = count * 4 + offset
        let shifts = CIVector(x:CGFloat(table[offset]), y:CGFloat(table[offset+1]), z:CGFloat(table[offset+2]), w:CGFloat(table[offset+3]))
        let options = CIVector(x:CGFloat(table[target]), y:CGFloat(table[target+1]), z:CGFloat(table[target+2]), w:CGFloat(table[target+3]))
        let mode: Double = p.selectiveColor.visualiseIsolation != nil ? 2 : (preview != nil ? 1 : 0)
        guard let result = kernel.apply(extent:extent, arguments:[image, shifts, options, mode]) else {
          throw DevelopmentError.unreadable
        }
        image = result
      } else {
        let data = table.withUnsafeBytes { Data($0) }
        let texture = CIImage(bitmapData:data, bytesPerRow:count*16, size:.init(width:count,height:2), format:.RGBAf,colorSpace:nil).samplingNearest()
        let kernels = try loaded.get()
        let selective = !pointValues.isEmpty ? kernels.selectivePointCloud:(hasVariance ? kernels.selectiveVariance:kernels.selective)
        guard let result = selective.apply(extent:extent,roiCallback:{ index,r in index == 1 ? CGRect(x:0,y:0,width:count,height:2):r },
          arguments:[image,texture,Double(count)]) else { throw DevelopmentError.unreadable }
        image = result
      }
    }
    if !DevelopmentMaskEngineV3.usesDefringe(p.masks) {
      image = try DevelopmentDefringeEngineV3.apply(p.optics,to:image)
    }
    if !sourceIsRAW, p.noiseReduction.enabled, p.noiseReduction.nonRawAmount != 0 {
      let filtered = image.clampedToExtent().applyingFilter("CINoiseReduction",parameters:["inputNoiseLevel":p.noiseReduction.nonRawAmount*0.02,"inputSharpness":0.0]).cropped(to:extent)
      guard let restored = try loaded.get().alpha.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,filtered]) else { throw DevelopmentError.unreadable }
      image = restored
    }
    let luminanceContrast=p.noiseReduction.luminanceContrast ?? 0,colorDetail=p.noiseReduction.colorDetail ?? 0
    if p.noiseReduction.enabled,luminanceContrast != 0 || colorDetail != 0 {
      let local = noiseDomain?.gaussian(for: image, controls: p.noiseReduction) ?? noiseDetailGaussian(image, extent: extent)
      let uniforms = CIVector(x: luminanceContrast, y: colorDetail, z: 0, w: 0)
      guard let result=try loaded.get().noiseDetail.apply(extent:extent,roiCallback:{ _,r in r },
        arguments:[image,local,uniforms])else{throw DevelopmentError.unreadable}
      noiseDomain?.bind(input: image, gaussian: local, controls: p.noiseReduction, uniforms: uniforms, output: result)
      image=result
    }
    if p.sharpen.enabled, p.sharpen.intensity != 0, p.sharpen.visualiseMasking != true {
      let k = try loaded.get(), s = p.sharpen
      let usesAdvancedControls = s.radius != nil || s.detail != nil || s.masking != nil
      let radius = s.radius ?? sharpenRadiusInNativePixels(falloff:s.falloff)
      let mean = try preparedSharpMean ?? sharpeningMean(image,radius:radius)
      let advanced = CIVector(x:s.detail ?? 0,y:s.masking ?? 0,z:usesAdvancedControls ? 1:0,w:0)
      guard let result = k.sharp.apply(extent:extent,roiCallback:{ _,r in r },arguments:[image,mean,CIVector(x:s.intensity,y:s.edges,z:s.falloff,w:0),advanced]) else { throw DevelopmentError.unreadable }
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
  static func noiseDetailGaussian(_ image: CIImage, extent: CGRect? = nil) -> CIImage {
    image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: extent ?? image.extent)
  }

  static func sharpeningMean(_ image:CIImage,radius:Double) throws -> CIImage {
    guard let guide = try loaded.get().guide.apply(extent:image.extent,roiCallback:{ _,r in r },arguments:[image,0.0]) else { throw DevelopmentError.unreadable }
    return guide.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:image.extent)
  }
  static func applyClippingPreview(_ p:DevelopmentAdjustmentsV3,to image:CIImage)throws->CIImage {
    guard let mode=p.light.clippingPreview else{return image}
    let extent=image.extent
    guard extent.width.isFinite,extent.height.isFinite,!extent.isEmpty else{throw DevelopmentV3Error.invalidGraph}
    let code=mode == .shadows ? 0.0:mode == .highlights ? 1.0:2.0
    guard let result=try loaded.get().clipping.apply(extent:extent,roiCallback:{_,r in r},arguments:[image,code])else{throw DevelopmentError.unreadable}
    return result
  }
  /// Final ephemeral visualization before geometry. It never doubles as the actual sharpen operation.
  static func applySharpenMaskPreview(_ p:DevelopmentAdjustmentsV3,to image:CIImage,sourceToImageScale:Double=1,
                                      preparedSharpMean:CIImage?=nil)throws->CIImage {
    let s=p.sharpen
    guard s.enabled,s.visualiseMasking == true else{return image}
    let extent=image.extent
    guard extent.width.isFinite,extent.height.isFinite,extent.width>0,extent.height>0,sourceToImageScale>0,sourceToImageScale<=1 else{throw DevelopmentV3Error.invalidGraph}
    let k=try loaded.get()
    let radius=(s.radius ?? sharpenRadiusInNativePixels(falloff:s.falloff))*sourceToImageScale
    let mean=try preparedSharpMean ?? sharpeningMean(image,radius:radius)
    let advanced=CIVector(x:s.detail ?? 0,y:s.masking ?? 0,z:s.radius != nil || s.detail != nil || s.masking != nil ? 1:0,w:1)
    guard let result=k.sharp.apply(extent:extent,roiCallback:{_,r in r},arguments:[image,mean,CIVector(x:0,y:s.edges,z:s.falloff,w:0),advanced])else{throw DevelopmentError.unreadable}
    return result
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
  /// Native RAW sensor textures are opaque. A single response channel preserves the
  /// same Gaussian/luminance calculation across edits to masking, detail and edges.
  static func nativeSharpResponse(_ source:CIImage, radius:Double, context:CIContext, device:MTLDevice, check:()throws->Void) throws -> CIImage {
    try check()
    let k=try loaded.get(),extent=source.extent
    guard let guide=k.guide.apply(extent:extent,roiCallback:{_,r in r},arguments:[source,0.0]) else {throw DevelopmentError.unreadable}
    let blurred=guide.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
    guard let response=k.sharpResponse.apply(extent:extent,roiCallback:{_,r in r},arguments:[source,blurred]) else {throw DevelopmentError.unreadable}
    return try DevelopmentSpatialEngineV3.materializeScalar(response,context:context,device:device,check:check)
  }
  static func nativeSharpMask(_ s:DevelopmentSharpenV3, response:CIImage) throws -> CIImage {
    let advanced=CIVector(x:s.detail ?? 0,y:s.masking ?? 0,z:s.radius != nil || s.detail != nil || s.masking != nil ? 1:0,w:1)
    let controls=CIVector(x:0,y:s.edges,z:s.falloff,w:0)
    guard let result=try loaded.get().sharpMask.apply(extent:response.extent,roiCallback:{_,r in r},
      arguments:[response,controls,advanced]) else {throw DevelopmentError.unreadable}
    return result
  }
  static let sharpWeightMetal = #"""
float rmSharpWeight(float d,float4 params,float4 advanced) {
 float threshold=.01+.3*params.y,mask=smoothstep(threshold,threshold+.02+.1*params.z,d);
 if(advanced.z>.5){
  // Detail admits finer luminance transitions; Masking retains stronger edge transitions.
  threshold=mix(threshold,.003,clamp(advanced.x,0.0,1.0));
  mask=smoothstep(threshold,threshold+.02+.1*params.z,d);
  float edgeOnly=smoothstep(.015+.30*advanced.y,.03+.35*advanced.y,d);
  mask*=mix(1.0,edgeOnly,clamp(advanced.y,0.0,1.0));
 }
 return mask;
}
"""#
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
[[stitchable]] float4 rmSelective(sampler src,sampler table,float count) {
 float4 p=src.sample(src.coord()); if(!all(isfinite(p))||p.a<=0) return p;
 float3 c=p.rgb/p.a,e=float3(ge(c.r),ge(c.g),ge(c.b)),hsv=ghsv(e); float3 delta=0;float total=0;
 int n=int(count+.5);
 for(int i=0;i<8;i++) { if(i>=n)break;float4 v=table.sample(float2(float(i)+.5,.5));float range=table.sample(float2(float(i)+.5,1.5)).r;
  float d=abs(hsv.x-v.x);d=min(d,1.0-d);float width=max(.005,.2*range);
  float w=(1.0-smoothstep(width*.3,width,d))*smoothstep(.015,.12,hsv.y);delta+=w*v.yzw;total+=w;
 }
 delta/=max(1.0,total);if(all(delta==float3(0)))return p;
 hsv.x=fract(hsv.x+delta.x+1.0);hsv.y=max(0.0,hsv.y*(1.0+delta.y));
 float3 out=grgb(hsv);float y=gy(out),u=clamp(y,0.0,1.0);out+=delta.z*.35*4*u*(1-u);
 return float4(float3(gd(out.r),gd(out.g),gd(out.b))*p.a,p.a);
}
[[stitchable]] float4 rmSelectiveVariance(sampler src,sampler table,float count) {
 float4 p=src.sample(src.coord()); if(!all(isfinite(p))||p.a<=0) return p;
 float3 c=p.rgb/p.a,e=float3(ge(c.r),ge(c.g),ge(c.b)),hsv=ghsv(e); float3 delta=0;float total=0;
 float3 variance=float3(0);float varianceNorm=0;
 int n=int(count+.5);
 for(int i=0;i<8;i++) { if(i>=n)break;float4 v=table.sample(float2(float(i)+.5,.5));float4 options=table.sample(float2(float(i)+.5,1.5));
  float d=abs(hsv.x-v.x);d=min(d,1.0-d);float width=max(.005,.2*options.x);
  float w=(1.0-smoothstep(width*.3,width,d))*smoothstep(.015,.12,hsv.y);delta+=w*v.yzw;total+=w;
  if(options.y!=0){float hd=v.x-hsv.x;hd-=floor(hd+.5);
   variance+=w*options.y*float3(hd,options.z-hsv.y,options.w-hsv.z);varianceNorm+=w*abs(options.y);}
 }
 delta/=max(1.0,total);if(all(delta==float3(0))&&varianceNorm==0)return p;
 float varianceScale=.5/max(1.0,varianceNorm);variance*=varianceScale;
 hsv.x=fract(hsv.x+delta.x+variance.x+1.0);hsv.y=max(0.0,hsv.y*(1.0+delta.y)+variance.y);hsv.z+=variance.z;
 float3 out=grgb(hsv);float y=gy(out),u=clamp(y,0.0,1.0);out+=delta.z*.35*4*u*(1-u);
 return float4(float3(gd(out.r),gd(out.g),gd(out.b))*p.a,p.a);
}
[[stitchable]] float4 rmSelectivePointCloud(sampler src,sampler table,float count) {
 float4 p=src.sample(src.coord()); if(!all(isfinite(p))||p.a<=0) return p;
 float3 c=p.rgb/p.a,e=float3(ge(c.r),ge(c.g),ge(c.b)),hsv=ghsv(e); float3 delta=0;float total=0;
 float3 variance=float3(0);float varianceNorm=0;
 int n=int(count+.5);
 for(int i=0;i<16;i++) { if(i>=n)break;float4 v=table.sample(float2(float(i)+.5,.5));float4 options=table.sample(float2(float(i)+.5,1.5));
  float d=abs(hsv.x-v.x);d=min(d,1.0-d);float width=max(.005,.2*options.x);
  float w=(1.0-smoothstep(width*.3,width,d))*smoothstep(.015,.12,hsv.y);delta+=w*v.yzw;total+=w;
  if(options.y!=0){float hd=v.x-hsv.x;hd-=floor(hd+.5);
   variance+=w*options.y*float3(hd,options.z-hsv.y,options.w-hsv.z);varianceNorm+=w*abs(options.y);}
 }
 delta/=max(1.0,total);if(all(delta==float3(0))&&varianceNorm==0)return p;
 float varianceScale=.5/max(1.0,varianceNorm);variance*=varianceScale;
 hsv.x=fract(hsv.x+delta.x+variance.x+1.0);hsv.y=max(0.0,hsv.y*(1.0+delta.y)+variance.y);hsv.z+=variance.z;
 float3 out=grgb(hsv);float y=gy(out),u=clamp(y,0.0,1.0);out+=delta.z*.35*4*u*(1-u);
 return float4(float3(gd(out.r),gd(out.g),gd(out.b))*p.a,p.a);
}
[[stitchable]] float4 rmClippingPreview(sampler src,float mode) {
 float4 p=src.sample(src.coord());if(!all(isfinite(p))||p.a<=0)return p;
 float3 c=p.rgb/p.a;float encoded=ge(gy(c));
 float shadows=(mode<.5||mode>1.5)?1.0-smoothstep(0.0,.02,encoded):0.0;
 float highlights=(mode>.5)?smoothstep(.98,1.0,encoded):0.0;
 c=mix(c,float3(.05,.25,1.0),shadows*.8);c=mix(c,float3(1.0,.05,.08),highlights*.8);
 return float4(c*p.a,p.a);
}
[[stitchable]] float4 rmNoiseDetail(sampler src,sampler local,float4 params) {
 float4 p=src.sample(src.coord()),q=local.sample(local.coord());
 if(!all(isfinite(p))||p.a<=0)return p;if(!all(isfinite(q))||q.a<=0)return float4(as_type<float>(0x7fc00000u));
 float3 c=p.rgb/p.a,b=q.rgb/q.a;float y=gy(c),by=gy(b);
 float3 chroma=c-float3(y),localChroma=b-float3(by);
 float outY=y+.35*params.x*(y-by);
 float3 outChroma=chroma+.25*params.y*(chroma-localChroma);
 return float4((float3(outY)+outChroma)*p.a,p.a);
}
\#(sharpWeightMetal)
[[stitchable]] float4 rmNativeSharpResponse(sampler src,sampler blurred) {
 float4 p=src.sample(src.coord());if(!all(isfinite(p))||p.a<=0)return p;
 float y=gy(p.rgb/p.a),mean=blurred.sample(blurred.coord()).r,d=abs(y-mean)/max(.005,abs(y)+abs(mean));
 return float4(d,d,d,1.0);
}
[[stitchable]] float4 rmNativeSharpMask(sampler response,float4 params,float4 advanced) {
 float d=response.sample(response.coord()).r,mask=rmSharpWeight(d,params,advanced);
 return float4(mask,mask,mask,1.0);
}
[[stitchable]] float4 rmSharp(sampler src,sampler guide,float4 params,float4 advanced) {
 float4 p=src.sample(src.coord());if(!all(isfinite(p))||p.a<=0)return p;float3 c=p.rgb/p.a;
 float y=gy(c),mean=guide.sample(guide.coord()).r,d=abs(y-mean)/max(.005,abs(y)+abs(mean));
 float mask=rmSharpWeight(d,params,advanced);
 if(advanced.w>.5)return float4(mask*p.a,mask*p.a,mask*p.a,p.a);
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
