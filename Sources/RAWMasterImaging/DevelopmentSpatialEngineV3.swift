import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// A real source-pixel neighborhood operator. No FIT-only downsample/radius shortcut is used.
enum DevelopmentSpatialEngineV3 {
  static let operatorVersion = "rawmaster-local-light-v3.2/fixed256-residual-fit/log-guide-gaussian/source-shortedge-0.012"
  static let radiusFraction = 0.012
  private struct Kernels { let guide, light: CIKernel }
  private static let loaded: Result<Kernels,Error> = Result {
    guard DevelopmentKernelCapability.supported else { throw DevelopmentError.unsupportedEngine }
    let kernels = try CIKernel.kernels(withMetalString:metalSource)
    guard let guide = kernels.first(where:{$0.name == "rawmasterGuideV3"}), let light = kernels.first(where:{$0.name == "rawmasterLocalLightV3"}) else { throw DevelopmentError.unsupportedEngine }
    return .init(guide:guide,light:light)
  }
  static func isActive(_ p: DevelopmentLightV3) -> Bool { p.enabled && (p.brilliance != 0 || p.shadows != 0 || p.highlights != 0) }
  static func meanLogLuminance(_ image:CIImage, radius:Double) throws -> CIImage {
    let extent=image.extent
    guard let guide=try loaded.get().guide.apply(extent:extent,roiCallback:{_,rect in rect},arguments:[image]) else { throw DevelopmentError.unreadable }
    return guide.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
  }
  static func applyLight(_ p: DevelopmentLightV3, to image: CIImage, proxyRadius:Double? = nil,
                         preparedGuide:((CIImage,Double)throws->CIImage)?=nil) throws -> CIImage {
    try p.validate(); guard isActive(p) else { return image }
    let kernels = try loaded.get(), extent = image.extent
    guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { throw DevelopmentV3Error.invalidGraph }
    if let proxyRadius { guard proxyRadius.isFinite,proxyRadius>0 else{throw DevelopmentV3Error.invalidGraph} }
    let radius:CGFloat = proxyRadius.map{CGFloat($0)} ?? max(1,min(extent.width,extent.height)*radiusFraction)
    let mean=try preparedGuide?(image,radius) ?? meanLogLuminance(image,radius:radius)
    guard let result = kernels.light.apply(extent:extent,roiCallback:{ _,rect in rect },arguments:[image,mean,CIVector(x:p.brilliance,y:p.shadows,z:p.highlights,w:0)]) else { throw DevelopmentError.unreadable }
    return result
  }
  static func materializeScalar(_ image:CIImage,context:CIContext,device:MTLDevice,check:()throws->Void) throws -> CIImage {
    try check()
    let extent=image.extent
    guard extent.origin == .zero,extent==extent.integral,extent.width>0,extent.height>0,extent.width<=16384,extent.height<=16384 else {
      throw DevelopmentV3Error.invalidGraph
    }
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r32Float,width:Int(extent.width),height:Int(extent.height),mipmapped:false)
    descriptor.storageMode = .private
    descriptor.usage=[.shaderRead,.shaderWrite,.renderTarget]
    guard let texture=device.makeTexture(descriptor:descriptor) else {throw RawBaseCacheError.capacity}
    let destination=CIRenderDestination(mtlTexture:texture,commandBuffer:nil)
    destination.colorSpace=nil;destination.alphaMode = .none;destination.isFlipped=false
    destination.isClamped=false;destination.isDithered=false
    let task=try context.startTask(toRender:image,from:extent,to:destination,at:.zero)
    do { _ = try task.waitUntilCompleted() } catch { _ = try? task.waitUntilCompleted(); throw error }
    try check()
    guard let result=CIImage(mtlTexture:texture,options:[.colorSpace:NSNull()]) else {throw DevelopmentError.unreadable}
    return result
  }
  static func referenceGainEV(encodedLuminance: Double, localLogLuminance: Double, logLuminance: Double, brilliance: Double, shadows: Double, highlights: Double) -> Double {
    let base = DevelopmentColorEngineV2.encode(pow(2,localLogLuminance)), x = min(1,max(0,encodedLuminance))
    let shadow = (1-DevelopmentColorEngineV2.smooth(0.15,0.65,base))*(1-DevelopmentColorEngineV2.smooth(0.1,0.7,x))
    let hb = DevelopmentColorEngineV2.smooth(0.3,0.85,base), hx = DevelopmentColorEngineV2.smooth(0.25,0.95,x)
    let high = -2.450*hb*hx+1.216*hx+1.411*hb
    let detail = min(2,max(-2,logLuminance-localLogLuminance))
    return 1.5*shadows*shadow+highlights*high+brilliance*(1.506*(1-base)-0.192+0.123*detail)
  }
  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float slE(float x) { float a=abs(x); return (x<0?-1.0:1.0)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055); }
[[stitchable]] float4 rawmasterGuideV3(sampler src) {
  float4 p=src.sample(src.coord()); if(!all(isfinite(p))) return p;
  float y=p.a>0?dot(p.rgb/p.a,float3(.2126,.7152,.0722)):0.0;
  float value=log2(max(y,exp2(-20.0))); return float4(value,value,value,1.0);
}
[[stitchable]] float4 rawmasterLocalLightV3(sampler src,sampler guide,float4 params) {
  float4 p=src.sample(src.coord()); if(!all(isfinite(p)) || p.a<=0) return p;
  float3 c=p.rgb/p.a; float y=dot(c,float3(.2126,.7152,.0722));
  float logY=log2(max(y,exp2(-20.0))), local=guide.sample(guide.coord()).r, base=slE(exp2(local));
  float x=clamp(slE(y),0.0,1.0);
  float shadow=(1.0-smoothstep(.15,.65,base))*(1.0-smoothstep(.1,.7,x));
  float hb=smoothstep(.3,.85,base), hx=smoothstep(.25,.95,x);
  float high=-2.450*hb*hx+1.216*hx+1.411*hb;
  float detail=clamp(logY-local,-2.0,2.0);
  float ev=1.5*params.y*shadow+params.z*high+params.x*(1.506*(1.0-base)-.192+.123*detail);
  return float4(c*exp2(ev)*p.a,p.a);
}
} }
"""#
}
