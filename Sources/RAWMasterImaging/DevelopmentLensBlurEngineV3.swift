import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// GPU multi-level defocus over an explicit procedural focus plane, not an AI depth estimate.
enum DevelopmentLensBlurEngineV3 {
  static let operatorVersion="rawmaster-lens-blur-v8-scene-depth/sparse-refinement/native-device-map/procedural-radial-focus/two-gaussian-levels/five-bokeh-samplers/depth-preview/f32"
  private struct Kernels {let blur,bokeh,depth:CIKernel}
  private static let kernels:Result<Kernels,Error>=Result {
    guard DevelopmentKernelCapability.supported else{throw DevelopmentError.unsupportedEngine}
    let all=try CIKernel.kernels(withMetalString:metalSource)
    guard let blur=all.first(where:{$0.name=="rmLensBlurProcedural"}),let bokeh=all.first(where:{$0.name=="rmLensBlurBokeh"}),let depth=all.first(where:{$0.name=="rmLensBlurDepth"})else{throw DevelopmentError.unsupportedEngine}
    return .init(blur:blur,bokeh:bokeh,depth:depth)
  }
  static func prewarm(){_ = try? kernels.get()}
  static func apply(_ blur:DevelopmentLensBlurV3?,to input:CIImage)throws->CIImage {
    guard let blur else{return input};try blur.validate();guard blur.isActive,blur.visualiseDepth != true else{return input}
    let extent=input.extent,short=min(extent.width,extent.height)
    guard [extent.minX,extent.minY,extent.width,extent.height].allSatisfy(\.isFinite),!extent.isEmpty,short>0 else{throw DevelopmentV3Error.invalidGraph}
    let style=blur.bokehStyle ?? .circle
    let telemetry=ImagePerformanceTelemetry.shared.begin(operation:"DevelopmentLensBlurEngineV3.apply",stage:(blur.deviceDepth != nil ? "device-" : (blur.sceneDepth != nil ? "estimated-" : "procedural-"))+style.rawValue,boundary:.graphBuild)
    var outcome=ImagePerformanceOutcome.failed
    defer{ImagePerformanceTelemetry.shared.end(telemetry,outcome:outcome,pixelCount:Int(extent.width*extent.height))}
    let maximumRadius=max(0.5,short*0.04*blur.amount)
    let extentVector=CIVector(x:extent.minX,y:extent.minY,z:extent.width,w:extent.height)
    let controls=CIVector(x:blur.focusX,y:blur.focusY,z:blur.focusRange,w:blur.amount)
    let device=try blur.renderDepth.map{try depthImage($0)} ?? CIImage(color:.clear).cropped(to:CGRect(x:0,y:0,width:1,height:1))
    let deviceExtent=CIVector(x:device.extent.minX,y:device.extent.minY,z:device.extent.width,w:device.extent.height)
    let deviceMode=blur.renderDepth?.kind == .depth ? 1.0:blur.renderDepth?.kind == .disparity ? 2.0:0.0
    let refinement=try DevelopmentLensBlurRefinementEngineV3.apply(blur.refinementStrokes ?? [],to:input)
    let refinementImage=refinement ?? CIImage(color:.clear).cropped(to:CGRect(x:0,y:0,width:1,height:1))
    if style != .circle || (blur.catEyeAmount ?? 0)>0 || (blur.bokehBoost ?? 0)>0 {
      let padding=maximumRadius*(style == .anamorphic ? 2:1.2)
      let refinements=CIVector(x:blur.catEyeAmount ?? 0,y:blur.bokehBoost ?? 0,z:0,w:0)
      guard let result=try kernels.get().bokeh.apply(extent:extent,roiCallback:{index,r in
        if index==1{return deviceMode==0 ? .zero:device.extent}
        if index==2{return refinement == nil ? .zero:r}
        return r.insetBy(dx:-padding,dy:-padding)},
        arguments:[input,device,refinementImage,extentVector,controls,deviceExtent,Double(styleCode(style)),maximumRadius,refinements,deviceMode])else{throw DevelopmentError.unreadable}
      outcome = .succeeded;return result
    }
    let near=input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:maximumRadius*0.5]).cropped(to:extent)
    let far=input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:maximumRadius]).cropped(to:extent)
    guard let result=try kernels.get().blur.apply(extent:extent,roiCallback:{index,r in
      if index==3{return deviceMode==0 ? .zero:device.extent}
      if index==4{return refinement == nil ? .zero:r}
      return r},
      arguments:[input,near,far,device,refinementImage,extentVector,controls,deviceExtent,deviceMode])else{throw DevelopmentError.unreadable}
    outcome = .succeeded
    return result
  }
  private static func styleCode(_ style:DevelopmentLensBokehStyleV3)->Int {
    switch style {case .circle:0;case .bubble:1;case .fiveBlade:2;case .ring:3;case .anamorphic:4}
  }
  private static func depthImage(_ payload:DevelopmentLensBlurDepthPayloadV1)throws->CIImage {
    try payload.validate()
    let base=CIImage(bitmapData:payload.data,bytesPerRow:payload.width*MemoryLayout<Float>.size,
      size:.init(width:payload.width,height:payload.height),format:.Rf,colorSpace:nil)
    // Keep the native map small; the kernels map output coordinates into this texture.
    let flipped=base.oriented(.downMirrored)
    let normalized=flipped.transformed(by:.init(translationX:-flipped.extent.minX,y:-flipped.extent.minY))
    return normalized.samplingLinear().cropped(to:normalized.extent)
  }
  static func applyDepthPreview(_ blur:DevelopmentLensBlurV3?,to input:CIImage)throws->CIImage {
    guard let blur,blur.enabled,blur.visualiseDepth == true else{return input};try blur.validate()
    let extent=input.extent
    guard extent.width.isFinite,extent.height.isFinite,!extent.isEmpty else{throw DevelopmentV3Error.invalidGraph}
    let device=try blur.renderDepth.map{try depthImage($0)} ?? CIImage(color:.clear).cropped(to:CGRect(x:0,y:0,width:1,height:1))
    let deviceExtent=CIVector(x:device.extent.minX,y:device.extent.minY,z:device.extent.width,w:device.extent.height)
    let deviceMode=blur.renderDepth?.kind == .depth ? 1.0:blur.renderDepth?.kind == .disparity ? 2.0:0.0
    let refinement=try DevelopmentLensBlurRefinementEngineV3.apply(blur.refinementStrokes ?? [],to:input)
    let refinementImage=refinement ?? CIImage(color:.clear).cropped(to:CGRect(x:0,y:0,width:1,height:1))
    guard let result=try kernels.get().depth.apply(extent:extent,roiCallback:{index,r in
      if index==1{return deviceMode==0 ? .zero:device.extent}
      if index==2{return refinement == nil ? .zero:r}
      return r},arguments:[input,device,refinementImage,
      CIVector(x:extent.minX,y:extent.minY,z:extent.width,w:extent.height),
      CIVector(x:blur.focusX,y:blur.focusY,z:blur.focusRange,w:blur.amount),deviceExtent,deviceMode])else{throw DevelopmentError.unreadable}
    return result
  }
  private static let metalSource=#"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmLensBlurProcedural(sampler src,sampler near,sampler far,sampler deviceMap,sampler refinement,float4 extent,float4 controls,float4 deviceExtent,float deviceMode,destination dest){
 float2 at=dest.coord();float4 p=src.sample(src.transform(at)),a=near.sample(near.transform(at)),b=far.sample(far.transform(at));
 if(!all(isfinite(p))||!all(isfinite(a))||!all(isfinite(b))||p.a<=0)return p;
 float2 uv=(at-extent.xy)/extent.zw,shortSide=min(extent.z,extent.w);
 float2 delta=float2((uv.x-controls.x)*extent.z,(1.0-uv.y-controls.y)*extent.w)/shortSide;
 float depth=clamp(length(delta),0.0,1.0),defocus=controls.z>=1.0?0.0:smoothstep(controls.z,1.0,depth);
 if(deviceMode>.5){
  float2 focusAt=deviceExtent.xy+float2(controls.x,1.0-controls.y)*deviceExtent.zw;
  float2 actualAt=deviceExtent.xy+uv*deviceExtent.zw;
  float focusDepth=deviceMap.sample(deviceMap.transform(focusAt)).r,actualDepth=deviceMap.sample(deviceMap.transform(actualAt)).r;
  defocus=controls.z>=1.0?0.0:smoothstep(0.0,max(.001,controls.z),abs(actualDepth-focusDepth));
 }
 defocus=clamp(defocus+refinement.sample(refinement.transform(at)).r,0.0,1.0);
 float first=clamp(defocus*2.0,0.0,1.0),second=clamp((defocus-.35)*1.6,0.0,1.0);
 return float4(mix(mix(p.rgb,a.rgb,first),b.rgb,second),p.a);
}
[[stitchable]] float4 rmLensBlurBokeh(sampler src,sampler deviceMap,sampler refinement,float4 extent,float4 controls,float4 deviceExtent,float style,float maximumRadius,float4 refinements,float deviceMode,destination dest){
 float2 at=dest.coord();float4 p=src.sample(src.transform(at));if(!all(isfinite(p))||p.a<=0)return p;
 float2 uv=(at-extent.xy)/extent.zw,shortSide=min(extent.z,extent.w);
 float2 delta=float2((uv.x-controls.x)*extent.z,(1.0-uv.y-controls.y)*extent.w)/shortSide;
 float depth=clamp(length(delta),0.0,1.0),defocus=controls.z>=1.0?0.0:smoothstep(controls.z,1.0,depth);
 if(deviceMode>.5){
  float2 focusAt=deviceExtent.xy+float2(controls.x,1.0-controls.y)*deviceExtent.zw;
  float2 actualAt=deviceExtent.xy+uv*deviceExtent.zw;
  float focusDepth=deviceMap.sample(deviceMap.transform(focusAt)).r,actualDepth=deviceMap.sample(deviceMap.transform(actualAt)).r;
  defocus=controls.z>=1.0?0.0:smoothstep(0.0,max(.001,controls.z),abs(actualDepth-focusDepth));
 }
 defocus=clamp(defocus+refinement.sample(refinement.transform(at)).r,0.0,1.0);
 float radius=maximumRadius*defocus;if(radius<.01)return p;
 float edge=smoothstep(.2,.75,length((uv-.5)*2.0)),twist=refinements.x*edge*.65*(uv.x<.5?-1.0:1.0);
 float3 total=0;float weightSum=0;int mode=int(style+.5);
 for(int i=0;i<48;i++){
  float r=sqrt((float(i)+.5)/48.0),angle=float(i)*2.399963;
  float2 unit=float2(cos(angle),sin(angle))*r;
  unit=float2(unit.x*cos(twist)-unit.y*sin(twist),unit.x*sin(twist)+unit.y*cos(twist));
  float w=1;
  if(mode==1)w=.25+2.0*pow(r,6.0);
  else if(mode==2){float sector=2.0*M_PI_F/5.0;float boundary=cos(M_PI_F/5.0)/max(.1,cos(fmod(angle+M_PI_F/5.0,sector)-M_PI_F/5.0));if(r>boundary)continue;w=.4+1.6*pow(r,4.0);}
  else if(mode==3)w=.05+3.0*exp(-18.0*(r-.88)*(r-.88));
  w*=1.0-refinements.x*edge*.55*clamp(unit.x*(uv.x<.5?-1.0:1.0),0.0,1.0);
  float2 offset=unit*radius;if(mode==4)offset*=float2(1.8,.65);
  float4 q=src.sample(src.transform(at+offset));if(!all(isfinite(q)))return float4(as_type<float>(0x7fc00000u));
  if(q.a>0){float3 c=q.rgb/q.a;float light=smoothstep(.55,1.0,dot(c,float3(.2126,.7152,.0722)));total+=c*w*(1.0+refinements.y*2.0*light);weightSum+=w;}
 }
 return weightSum>0?float4(total/weightSum*p.a,p.a):p;
}
[[stitchable]] float4 rmLensBlurDepth(sampler src,sampler deviceMap,sampler refinement,float4 extent,float4 controls,float4 deviceExtent,float deviceMode,destination dest){
 float2 at=dest.coord();float4 p=src.sample(src.transform(at));if(!all(isfinite(p))||p.a<=0)return p;
 float2 uv=(at-extent.xy)/extent.zw,shortSide=min(extent.z,extent.w);
 float2 delta=float2((uv.x-controls.x)*extent.z,(1.0-uv.y-controls.y)*extent.w)/shortSide;
 float depth=clamp(length(delta),0.0,1.0),defocus=controls.z>=1.0?0.0:smoothstep(controls.z,1.0,depth);
 bool near=false;
 if(deviceMode>.5){
  float2 focusAt=deviceExtent.xy+float2(controls.x,1.0-controls.y)*deviceExtent.zw;
  float2 actualAt=deviceExtent.xy+uv*deviceExtent.zw;
  float focusDepth=deviceMap.sample(deviceMap.transform(focusAt)).r,actualDepth=deviceMap.sample(deviceMap.transform(actualAt)).r;
  float range=max(.001,controls.z),difference=abs(actualDepth-focusDepth);
  defocus=controls.z>=1.0?0.0:smoothstep(0.0,range,difference);
  near=deviceMode<1.5?actualDepth<focusDepth:actualDepth>focusDepth;
 }
 defocus=clamp(defocus+refinement.sample(refinement.transform(at)).r,0.0,1.0);
 float3 outside=deviceMode>.5?(near?float3(.95,.55,.1):float3(.08,.18,.55)):float3(.08,.18,.55)*(.35+.65*depth);
 float3 color=defocus<=.001?float3(.1,.9,.3):outside;
 return float4(color*p.a,p.a);
}
} }
"""#
}
