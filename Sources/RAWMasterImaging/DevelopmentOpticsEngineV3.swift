import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// Automatic lateral-CA and radial distortion operators, distinct from hue-band Defringe.
enum DevelopmentOpticsEngineV3 {
  static let operatorVersion="rawmaster-optics-v3/radial-distortion/automatic-chroma-edge-ca/lens-profile-correction"
  private struct Kernels{let distortion,ca:CIKernel;let vignette:CIColorKernel}
  private static let loaded:Result<Kernels,Error>=Result{
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries else{throw DevelopmentError.unsupportedEngine}
    let all=try CIKernel.kernels(withMetalString:metalSource)
    guard let distortion=all.first(where:{$0.name=="rmOpticsDistortion"}),let vignette=CIColorKernel(source:vignetteSource),let ca=CIKernel(source:caSource)else{throw DevelopmentError.unsupportedEngine}
    return .init(distortion:distortion,ca:ca,vignette:vignette)
  }
  static func prewarm(){_ = try? loaded.get()}
  static func apply(_ optics:DevelopmentOpticsV3?,to input:CIImage)throws->CIImage{
    guard let optics else{return input};try optics.validate()
    let distortion=optics.distortion ?? 0,removeCA=optics.removeChromaticAberration == true
    let profile=optics.lensProfileEnabled == true ? optics.lensProfile:nil
    let manualVignetting=optics.lensVignettingAmount ?? 0
    guard distortion != 0 || removeCA || profile != nil || manualVignetting != 0 else{return input}
    let extent=input.extent;guard !extent.isEmpty,extent.width.isFinite,extent.height.isFinite else{throw DevelopmentV3Error.invalidGraph}
    let telemetry=ImagePerformanceTelemetry.shared.begin(operation:"DevelopmentOpticsEngineV3.apply",stage:profile != nil || manualVignetting != 0 ? "lens-profile-vignetting":distortion != 0 ? "radial-distortion-ca":"automatic-ca",boundary:.graphBuild)
    var outcome=ImagePerformanceOutcome.failed;defer{ImagePerformanceTelemetry.shared.end(telemetry,outcome:outcome,pixelCount:Int(extent.width*extent.height))}
    var image=input;let kernels=try loaded.get()
    if distortion != 0 {
      let bounds=CIVector(x:extent.minX,y:extent.minY,z:extent.width,w:extent.height)
      guard let output=kernels.distortion.apply(extent:extent,roiCallback:{_,_ in extent},arguments:[image,bounds,distortion])else{throw DevelopmentError.unreadable}
      image=output
    }
    let bounds = CIVector(x:extent.minX, y:extent.minY, z:extent.width, w:extent.height)
    let profileDistortion = (profile?.distortion ?? 0) * (optics.profileDistortionAmount ?? 1)
    if profileDistortion != 0 {
      guard let warped = kernels.distortion.apply(extent:extent, roiCallback:{ _,_ in extent },
        arguments:[image,bounds,profileDistortion]) else { throw DevelopmentError.unreadable }
      image = warped
    }
    let gain = (profile?.vignetting ?? 0) * (optics.profileVignettingAmount ?? 1) + manualVignetting
    if gain != 0 {
      let midpoint = manualVignetting != 0 ? (optics.lensVignettingMidpoint ?? 0.5) : (profile?.midpoint ?? 0.5)
      guard let corrected = kernels.vignette.apply(extent:extent, arguments:[image,bounds,gain,midpoint]) else {
        throw DevelopmentError.unreadable
      }
      image = corrected
    }
    if removeCA {
      guard let output=kernels.ca.apply(extent:extent,roiCallback:{_,rect in rect.insetBy(dx:-2,dy:-2)},arguments:[image])else{throw DevelopmentError.unreadable}
      image=output
    }
    outcome = .succeeded;return image
  }
  private static let metalSource=#"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmOpticsDistortion(sampler src,float4 extent,float amount,destination dest){
 float2 halfSize=extent.zw*.5,center=extent.xy+halfSize,uv=(dest.coord()-center)/halfSize;
 float radius=dot(uv,uv),scale=1.0+amount*.25*radius;
 float2 at=center+uv*scale*halfSize;float4 p=src.sample(src.transform(at));
 return all(isfinite(p))?p:float4(0);
}
} }
"""#
  private static let vignetteSource = #"""
kernel vec4 rmLensVignetting(__sample pixel, vec4 bounds, float amount, float midpoint) {
 vec2 uv = 2.0 * (destCoord() - bounds.xy) / bounds.zw - 1.0;
 float shoulder = smoothstep(midpoint * 0.5, 1.0, length(uv) / sqrt(2.0));
 return vec4(pixel.rgb * exp2(amount * shoulder * shoulder), pixel.a);
}
"""#
  private static let caSource=#"""
float caEncode(float x){float a=abs(x);return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055);}
float caDecode(float x){float a=abs(x);return sign(x)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4));}
vec3 caEncoded(vec3 c){return vec3(caEncode(c.r),caEncode(c.g),caEncode(c.b));}
vec3 caRead(sampler src,vec2 at){return caEncoded(sample(src,samplerTransform(src,at)).rgb);}
kernel vec4 rmOpticsCA(sampler src){
 vec2 at=destCoord();vec4 p=sample(src,samplerTransform(src,at));if(p.a<=0)return p;
 vec3 c=p.rgb/p.a,e=caEncoded(c);
 vec3 mean=(caRead(src,at-vec2(2,0))+caRead(src,at+vec2(2,0))+caRead(src,at-vec2(0,2))+caRead(src,at+vec2(0,2)))*.25;
 float edge=smoothstep(.006,.06,length(e-mean));float chroma=max(e.r,max(e.g,e.b))-min(e.r,min(e.g,e.b));
 float weight=edge*smoothstep(.015,.08,chroma);if(weight<=0)return p;
 float y=dot(e,vec3(.2126,.7152,.0722));e=mix(e,vec3(y),clamp(weight,0.0,1.0));
 return vec4(caDecode(e.r),caDecode(e.g),caDecode(e.b),p.a)*vec4(p.a,p.a,p.a,1);
}
"""#
}
