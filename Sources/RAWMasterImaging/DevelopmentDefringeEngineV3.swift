import CoreImage
import Foundation
import RAWMasterCore

/// GPU hue-band and local-edge defringe. This is an owned approximation, not a recovered ACR model.
enum DevelopmentDefringeEngineV3 {
  static let operatorVersion="rawmaster-defringe-v1/purple-green-hue-ranges/local-edge-f32"
  private static let kernel:Result<CIKernel,Error>=Result {
    guard let value=CIKernel(source:source)else{throw DevelopmentError.unsupportedEngine};return value
  }
  static func prewarm(){_ = try? kernel.get()}
  static func apply(_ optics:DevelopmentOpticsV3?,to input:CIImage)throws->CIImage {
    guard let optics else{return input};try optics.validate();let d=optics.defringe;guard d.isActive else{return input}
    let extent=input.extent
    guard extent.width.isFinite,extent.height.isFinite,!extent.isEmpty else{throw DevelopmentV3Error.invalidGraph}
    let args:[Any]=[input,
      CIVector(x:d.purpleAmount/100,y:d.greenAmount/100),
      CIVector(x:d.purpleHueLower,y:d.purpleHueUpper,z:d.greenHueLower,w:d.greenHueUpper)]
    guard let output=try kernel.get().apply(extent:extent,roiCallback:{_,r in r.insetBy(dx:-2,dy:-2)},arguments:args)else{throw DevelopmentError.unreadable}
    return output
  }
  private static let source=#"""
float dfEncode(float x){float a=abs(x);return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055);}
float dfDecode(float x){float a=abs(x);return sign(x)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4));}
vec3 dfEncoded3(vec3 c){return vec3(dfEncode(c.r),dfEncode(c.g),dfEncode(c.b));}
float dfHue(vec3 c){float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo,h=0.0;
 if(d>1e-8){if(hi==c.r)h=(c.g-c.b)/d;else if(hi==c.g)h=2.0+(c.b-c.r)/d;else h=4.0+(c.r-c.g)/d;}
 h*=60.0;return h<0.0?h+360.0:h;}
float dfBand(float hue,vec2 range){float feather=4.0;
 return smoothstep(range.x-feather,range.x+feather,hue)*(1.0-smoothstep(range.y-feather,range.y+feather,hue));}
vec3 dfRead(sampler src,vec2 p){return dfEncoded3(sample(src,samplerTransform(src,p)).rgb);}
kernel vec4 rmDefringe(sampler src,vec2 amount,vec4 ranges){
 vec2 at=destCoord();vec4 p=sample(src,samplerTransform(src,at));if(p.a<=0.0)return p;
 vec3 c=p.rgb/p.a,e=dfEncoded3(c);
 vec3 mean=(dfRead(src,at-vec2(2,0))+dfRead(src,at+vec2(2,0))
   +dfRead(src,at+vec2(0,2))+dfRead(src,at-vec2(0,2)))*.25;
 float edge=smoothstep(.008,.08,length(e-mean));float hue=dfHue(e);
 float w=edge*(amount.x*dfBand(hue,ranges.xy)+amount.y*dfBand(hue,ranges.zw));
 if(w<=0.0)return p;
 float y=dot(e,vec3(.2126,.7152,.0722));e=mix(e,vec3(y),clamp(w,0.0,1.0));
 c=vec3(dfDecode(e.r),dfDecode(e.g),dfDecode(e.b));return vec4(c*p.a,p.a);
}
"""#
}
