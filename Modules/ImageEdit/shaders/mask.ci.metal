#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
// RM_MASK_GEOMETRY
[[stitchable]] float4 rmMaskScopeCoverage(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,destination dest){
 float4 pixel=src.sample(src.coord());
 if(!all(isfinite(pixel))||pixel.a<=0)return float4(0.0);
 return float4(rmMaskCompute(pixel,subject,mode,line,radial,range,dest.coord()));
}
[[stitchable]] float4 rmMaskComposite(sampler src,sampler adjusted,sampler subject,float4 mode,float4 line,float4 radial,float4 range,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));float4 changed=adjusted.sample(adjusted.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(changed))||pixel.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);
 return float4(mix(pixel.rgb,changed.rgb,mask),pixel.a);
}
// RM_MASK_GRAIN_TRANSFER
[[stitchable]] float4 rmMaskGrain(sampler src,sampler noise,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float amount,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));float4 sample=noise.sample(noise.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(sample))||pixel.a<=0)return pixel;
 return rmCompositeGrain(pixel,sample.r,rmMaskCompute(pixel,subject,mode,line,radial,range,at),amount);
}
// RM_COLOR_GRAIN_LATTICE
[[stitchable]] float4 rmSourceMaskGrain(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float4 settings,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
 if(!all(isfinite(pixel))||pixel.a<=0)return pixel;
 return rmCompositeGrain(pixel,rmSourceGrainSample(at,settings),rmMaskCompute(pixel,subject,mode,line,radial,range,at),settings.x);
}
[[stitchable]] float4 rmMaskMoire(sampler src,sampler blurred,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float amount,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));float4 smooth=blurred.sample(blurred.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(smooth))||pixel.a<=0||smooth.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);if(mask<=0)return pixel;
 float3 c=pixel.rgb/pixel.a,b=smooth.rgb/smooth.a;
 float y=dot(c,float3(.2126,.7152,.0722)),by=dot(b,float3(.2126,.7152,.0722));
 float3 target=float3(y)+b-float3(by);c=mix(c,target,clamp(amount*mask,0.0,1.0));
 return float4(c*pixel.a,pixel.a);
}
[[stitchable]] float4 rmMaskDehaze(sampler src,sampler air,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float amount,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));float4 airlight=air.sample(air.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(airlight))||pixel.a<=0||airlight.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);if(mask<=0)return pixel;
 float3 u=pixel.rgb/pixel.a,a=airlight.rgb/airlight.a;
 float dark=clamp(1.0-dot(a,float3(.2126,.7152,.0722)),0.0,1.0),v=amount*mask;
 float3 j;if(v>=0){float t=clamp(1.0-.85*v*dark,.20,1.0);j=(u-a)/t+a;}
 else{float t=1.0/(1.0+.85*(-v)*dark);j=t*u+(1.0-t)*a;}
 return float4(j*pixel.a,pixel.a);
}
float3 rmMaskPointHSV(float3 c);
float3 rmMaskPointRGB(float3 hsv);
float4 rmMaskTone(float4 pixel,float mask,float4 adjustment,float4 tone,float4 color,float4 colorize){
 if(!all(isfinite(pixel))||pixel.a<=0||mask<=0)return pixel;
 float3 c=pixel.rgb/pixel.a;c*=exp2(2.0*adjustment.x*mask);
 float y=dot(c,float3(.2126,.7152,.0722));float encoded=clamp(rmMaskPointEncode(y),0.0,1.0);
 c*=1.0+.5*adjustment.y*rmMaskSmooth(.5,1.0,encoded)*mask;
 c*=1.0+.5*adjustment.z*(1.0-rmMaskSmooth(0.0,.5,encoded))*mask;
 y=dot(c,float3(.2126,.7152,.0722));encoded=rmMaskPointEncode(y);float contrast=tone.x*mask;
 if(encoded>0&&encoded<1&&contrast!=0){
  float pivot=.55,power=exp2(1.3*contrast);
  float target=encoded<pivot?pivot*pow(encoded/pivot,power):1.0-(1.0-pivot)*pow((1.0-encoded)/(1.0-pivot),power);
  float decoded=rmMaskPointDecode(target);c=abs(y)>1e-8?c*(decoded/y):c+float3(decoded-y);
 }
 float black=.05*tone.z*mask;c=(c-float3(black))/(1.0-black);
 float whiteWeight=smoothstep(.45,1.0,clamp(rmMaskPointEncode(dot(c,float3(.2126,.7152,.0722))),0.0,1.0));
 c*=1.0+.35*tone.y*whiteWeight*mask;
 float hue=color.x*color.y*mask;
 if(hue!=0){
  float3 e=float3(rmMaskPointEncode(c.r),rmMaskPointEncode(c.g),rmMaskPointEncode(c.b)),hsv=rmMaskPointHSV(e);
  hsv.x=fract(hsv.x+hue+1.0);float3 shifted=rmMaskPointRGB(hsv);
  c=float3(rmMaskPointDecode(shifted.r),rmMaskPointDecode(shifted.g),rmMaskPointDecode(shifted.b));
 }
 if(colorize.w>0&&color.z>0){
  float level=clamp(dot(c,float3(.2126,.7152,.0722)),0.0,1.0);
  c=mix(c,colorize.rgb*level,clamp(color.z*colorize.w*mask,0.0,1.0));
 }
 float gray=dot(c,float3(.2126,.7152,.0722));c=float3(gray)+(c-float3(gray))*(1.0+adjustment.w*mask);
 return float4(c*pixel.a,pixel.a);
}
[[stitchable]] float4 rmMaskLayerV7(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float4 adjustment,float4 tone,float4 color,float4 colorize,destination dest){
 float4 pixel=src.sample(src.coord());float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,dest.coord());
 return rmMaskTone(pixel,mask,adjustment,tone,color,colorize);
}
float3 rmMaskPointHSV(float3 c){float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo,h=0;
 if(d>1e-8){if(hi==c.r)h=(c.g-c.b)/d;else if(hi==c.g)h=2.0+(c.b-c.r)/d;else h=4.0+(c.r-c.g)/d;}
 h=h/6.0-floor(h/6.0);return float3(h,hi>1e-8?d/hi:0,hi);}
float3 rmMaskPointRGB(float3 hsv){float3 p=abs(fract(hsv.xxx+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0);
 return hsv.z*mix(float3(1),clamp(p-1.0,0.0,1.0),hsv.y);}
float4 rmMaskPointColorPixel(float4 pixel,float mask,float4 point,float4 options){
 if(!all(isfinite(pixel))||pixel.a<=0||mask<=0)return pixel;
 float3 c=pixel.rgb/pixel.a,e=float3(rmMaskPointEncode(c.r),rmMaskPointEncode(c.g),rmMaskPointEncode(c.b));
 float3 hsv=rmMaskPointHSV(e);float d=abs(hsv.x-point.x);d=min(d,1.0-d);
 float w=mask*(1.0-smoothstep(max(.005,.2*options.x)*.3,max(.005,.2*options.x),d))*smoothstep(.015,.12,hsv.y);
 if(w>0){
  float hd=point.x-hsv.x;hd-=floor(hd+.5);float variance=options.y;
  hsv.x=fract(hsv.x+w*point.y+.5*w*variance*hd+1.0);
  hsv.y=max(0.0,hsv.y*(1.0+w*point.z)+.5*w*variance*(options.z-hsv.y));
  hsv.z+=.5*w*variance*(options.w-hsv.z);
  float3 out=rmMaskPointRGB(hsv);float y=dot(out,float3(.2126,.7152,.0722)),u=clamp(y,0.0,1.0);
  out+=point.w*w*.35*4*u*(1-u);
  pixel=float4(float3(rmMaskPointDecode(out.r),rmMaskPointDecode(out.g),rmMaskPointDecode(out.b))*pixel.a,pixel.a);
 }
 return pixel;
}
[[stitchable]] float4 rmMaskPointColorOnly(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,
 float4 point,float4 options,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
 if(!all(isfinite(pixel))||pixel.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);
 return rmMaskPointColorPixel(pixel,mask,point,options);
}
[[stitchable]] float4 rmMaskPointColorV7(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,
 float4 adjustment,float4 tone,float4 color,float4 colorize,float4 point,float4 options,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
 if(!all(isfinite(pixel))||pixel.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);
 return rmMaskTone(rmMaskPointColorPixel(pixel,mask,point,options),mask,adjustment,tone,color,colorize);
}
[[stitchable]] float4 rmMaskGlowLayerV7(sampler src,sampler glow,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float4 adjustment,float4 tone,float4 color,float4 colorize,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
 float4 lighted=glow.sample(glow.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(lighted))||pixel.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);
 float4 composited=float4(mix(pixel.rgb,lighted.rgb,mask),pixel.a);
 return rmMaskTone(composited,mask,adjustment,tone,color,colorize);
}
} }
