import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// Owned native-scale log-band operators. This is not an ACR/Photos algorithm identity claim.
/// Guides use RGB=(logY*A,A,0), alpha=1: Gaussian filtering must NOT premultiply logY*A again.
enum DevelopmentAdvancedDetailEngineV3 {
  static let operatorVersion = "rawmaster-advanced-v2/logband-native-canonical-landscape/materialized-rgba32f/guide-logA-A-zero-one/Texture-.0003-.35/Clarity-.004-.60"
  private struct Kernels { let guide,band: CIKernel }
  private static let loaded: Result<Kernels,Error> = Result {
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries else { throw DevelopmentError.unsupportedEngine }
    let kernels=try CIKernel.kernels(withMetalString:metalSource)
    guard let guide=kernels.first(where:{$0.name == "rmAdvancedGuideV1"}),let band=kernels.first(where:{$0.name == "rmAdvancedBandV1"}) else { throw DevelopmentError.unsupportedEngine }
    return .init(guide:guide,band:band)
  }
  private static let cachedBandKernels: Result<(factor:CIKernel,restore:CIKernel),Error> = Result {
    let kernels=try CIKernel.kernels(withMetalString:cachedBandSource)
    guard let factor=kernels.first(where:{$0.name=="rmAdvancedBandFactor"}),let restore=kernels.first(where:{$0.name=="rmAdvancedBandRestore"}) else {throw DevelopmentError.unsupportedEngine}
    return (factor,restore)
  }
  static var hasCachedBandKernels: Bool { (try? cachedBandKernels.get()) != nil }
  enum Band: Equatable { case texture, clarity }
  struct Radii: Equatable { let texture,clarity: Double }
  struct Guides { let fine,wide: CIImage }
  static func radii(sourceSize: DevelopmentPixelSize) throws -> Radii {
    try sourceSize.validate();let short=Double(min(sourceSize.width,sourceSize.height))
    return .init(texture:max(0.5,short*0.0003),clarity:max(2,short*0.004))
  }
  static func makeGuide(_ image: CIImage) throws -> CIImage {
    guard let result=try loaded.get().guide.apply(extent:image.extent,roiCallback:{ _,r in r },arguments:[image.samplingNearest()]) else { throw DevelopmentV3Error.invalidGraph };return result
  }
  static func guides(_ image: CIImage,radius: Double) throws -> Guides {
    let guide=try makeGuide(image),extent=image.extent
    // Same linear working graph. No ICC/profile conversion, proxy or CPU blur approximation.
    func blur(_ r: Double) -> CIImage {
      guide.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:r]).cropped(to:extent)
    }
    return .init(fine:blur(radius),wide:blur(4*radius))
  }
  /// Evaluate the native graph exactly once. Later canvas/export reads sample this F32 result
  /// instead of letting Core Image select a different Gaussian path for each destination rect.
  private static func materialize(_ image: CIImage,context: CIContext,checkCancellation:(() throws -> Void)?) throws -> CIImage {
    let extent=image.extent,width=Int(extent.width),height=Int(extent.height)
    guard let device=MTLCreateSystemDefaultDevice(),width>0,height>0,width<=16384,height<=16384 else { throw DevelopmentV3Error.invalidGraph }
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage=[.shaderRead,.shaderWrite,.renderTarget]
    guard let texture=device.makeTexture(descriptor:descriptor) else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let destination=CIRenderDestination(mtlTexture:texture,commandBuffer:nil)
    destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
    destination.isFlipped=false;destination.isClamped=false;destination.isDithered=false
    try checkCancellation?()
    var task:CIRenderTask?
    do {
      task=try context.startTask(toRender:image,from:extent,to:destination,at:.zero)
      _=try task!.waitUntilCompleted()
    } catch {
      if let task { _=try? task.waitUntilCompleted() }
      throw error
    }
    try checkCancellation?()
    guard let result=CIImage(mtlTexture:texture,options:[.colorSpace:DevelopmentColorEngineV3.linearSRGB]) else { throw DevelopmentV3Error.invalidGraph }
    return extent.origin == .zero ? result:result.transformed(by:.init(translationX:extent.minX,y:extent.minY))
  }
  static func apply(_ parameters: DevelopmentAdvancedDetailV3,to image: CIImage,sourceSize: DevelopmentPixelSize,context: CIContext, checkCancellation: (() throws -> Void)? = nil,deferValidation:Bool = false, checkedInput: CIImage? = nil) throws -> CIImage {
    try parameters.validate()
    if parameters.dehaze.enabled && parameters.dehaze.amount != 0 { throw DevelopmentV3Error.unsupportedAdjustment(.dehaze) }
    let texture=parameters.texture.enabled && parameters.texture.amount != 0,clarity=parameters.clarity.enabled && parameters.clarity.amount != 0
    guard texture || clarity else { return image } // exact object/graph identity, not an evaluated copy
    let r=try radii(sourceSize:sourceSize),e=image.extent
    guard e.origin.x.isFinite,e.origin.y.isFinite,e.width == Double(sourceSize.width),e.height == Double(sourceSize.height) else { throw DevelopmentV3Error.invalidGraph }
    if e.height > e.width {
      // These isotropic operators must not depend on Core Image's portrait/landscape pass order.
      let normalized=image.oriented(.left)
      let result=try apply(parameters,to:normalized,sourceSize:.init(width:sourceSize.height,height:sourceSize.width),context:context,checkCancellation:checkCancellation,deferValidation:deferValidation,checkedInput: checkedInput === image ? normalized : nil)
      return result.oriented(.right)
    }
    // Interactive proxy performs one finite gate after the shared suffix surface. Canonical
    // callers retain the existing input and output validation pairs.
    if !deferValidation && image !== checkedInput { try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation) }
    var output=image
    if texture { output=try applyBand(.texture,amount:parameters.texture.amount,to:output,radius:r.texture) }
    if clarity { output=try applyBand(.clarity,amount:parameters.clarity.amount,to:output,radius:r.clarity) }
    output=try materialize(output,context:context,checkCancellation:checkCancellation)
    if !deferValidation { try DevelopmentColorEngineV3.validateFinite(output,context:context,checkCancellation:checkCancellation) }
    return output
  }
  static func applyBand(_ band: Band,amount: Double,to image: CIImage,radius: Double) throws -> CIImage {
    guard amount.isFinite,(-100...100).contains(amount),radius.isFinite,radius>0 else { throw DevelopmentV3Error.invalidGraph }
    if amount == 0 { return image }
    let g=try guides(image,radius:radius)
    guard let result=try loaded.get().band.apply(extent:image.extent,roiCallback:{ _,r in r },
      arguments:[image.samplingNearest(),g.fine.samplingNearest(),g.wide.samplingNearest(),CIVector(x:amount/100,y:band == .texture ? 0:1,z:0,w:0)]) else { throw DevelopmentV3Error.invalidGraph }
    return result
  }
  static func bandFactor(_ source:CIImage,radius:Double) throws -> CIImage {
    guard radius.isFinite,radius>0 else {throw DevelopmentV3Error.invalidGraph}
    let guide=try guides(source,radius:radius)
    guard let image=try cachedBandKernels.get().factor.apply(extent:source.extent,roiCallback:{_,r in r},
      arguments:[guide.fine.samplingNearest(),guide.wide.samplingNearest()]) else {throw DevelopmentV3Error.invalidGraph}
    return image
  }
  static func applyBand(_ band:Band,amount:Double,to image:CIImage,factor:CIImage) throws -> CIImage {
    guard amount.isFinite,(-100...100).contains(amount),factor.extent == image.extent else {throw DevelopmentV3Error.invalidGraph}
    if amount == 0 { return image }
    guard let result=try cachedBandKernels.get().restore.apply(extent:image.extent,roiCallback:{_,r in r},
      arguments:[image.samplingNearest(),factor.samplingNearest(),CIVector(x:amount/100,y:band == .texture ? 0:1,z:0,w:0)]) else { throw DevelopmentV3Error.invalidGraph }
    return result
  }
  /// CPU equations only: public CI Gaussian evaluation remains the authoritative blur primitive.
  /// Stable log ratio is algebraically log2(max(Y,2^-16)), without RGB/A overflow in a tiny-alpha guide.
  static func referenceGuide(_ p: SIMD4<Double>) throws -> SIMD4<Double> {
    guard [p.x,p.y,p.z,p.w].allSatisfy(\.isFinite),(0...1).contains(p.w) else { throw DevelopmentError.invalidEncoding }
    if p.w <= 0 { return .init(0,0,0,1) }
    let premultipliedY=p.x*0.2126729+p.y*0.7151522+p.z*0.0721750
    let logY=premultipliedY>0 ? max(-16,log2(premultipliedY)-log2(p.w)):-16
    return .init(logY*p.w,p.w,0,1)
  }
  static func referencePixel(_ p: SIMD4<Double>,fine: SIMD4<Double>,wide: SIMD4<Double>,band: Band,amount: Double) throws -> SIMD4<Double> {
    guard [p.x,p.y,p.z,p.w,fine.x,fine.y,wide.x,wide.y,amount].allSatisfy(\.isFinite),(0...1).contains(p.w),(-100...100).contains(amount) else { throw DevelopmentError.invalidEncoding }
    if amount == 0 || p.w < 1.0/65535 || fine.y < 1.0/65535 || wide.y < 1.0/65535 { return p }
    let y=(p.x*0.2126729+p.y*0.7151522+p.z*0.0721750)/p.w
    if y <= 0 { return p }
    let difference=min(1,max(-1,fine.x/fine.y-wide.x/wide.y)),a=amount/100
    let ev:Double
    switch band {
    case .texture:ev=0.35*a*difference
    case .clarity:
      let u=min(1,max(0,DevelopmentColorEngineV2.encode(y)));ev=0.60*a*4*u*(1-u)*difference
    }
    if ev == 0 { return p }
    let gain=exp2(ev);return .init(p.x*gain,p.y*gain,p.z*gain,p.w)
  }
  // Isolate these optional proxy kernels from the versioned canonical/export shader.
  private static let cachedBandSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float rmAdvancedEncodeV1(float x){return x<=.0031308?12.92*x:1.055*pow(x,1.0/2.4)-.055;}
float4 rmAdvancedGain(float4 p,float band,float4 params){
 float y=dot(p.rgb,float3(.2126729,.7151522,.0721750))/p.a;
 if(!isfinite(y))return float4(as_type<float>(0x7fc00000u));if(y<=0)return p;
 float ev;
 if(params.y<.5)ev=.35*params.x*band;
 else{float u=clamp(rmAdvancedEncodeV1(y),0.0,1.0);ev=.60*params.x*4*u*(1-u)*band;}
 if(ev==0)return p;
 return float4(p.rgb*exp2(ev),p.a);
}
[[stitchable]] float4 rmAdvancedBandFactor(sampler fine,sampler wide,destination dest){
 float2 d=dest.coord();float4 f=fine.sample(fine.transform(d)),w=wide.sample(wide.transform(d));
 if(!all(isfinite(f))||!all(isfinite(w)))return float4(as_type<float>(0x7fc00000u));
 // Every actual factor is in [-1,1]. Preserve the original low-coverage early return.
 float band=f.g<1.0/65535.0||w.g<1.0/65535.0?2.0:clamp(f.r/f.g-w.r/w.g,-1.0,1.0);
 return float4(band,band,band,1);
}
[[stitchable]] float4 rmAdvancedBandRestore(sampler src,sampler factor,float4 params,destination dest){
 float2 d=dest.coord();float4 p=src.sample(src.transform(d));
 if(!all(isfinite(p))||p.a < -0.000001 || p.a > 1.000001)return float4(as_type<float>(0x7fc00000u));
 if(p.a<1.0/65535.0)return p;
 float v=factor.sample(factor.transform(d)).r;
 if(!isfinite(v))return float4(as_type<float>(0x7fc00000u));
 if(v==2.0)return p;
 return rmAdvancedGain(p,v,params);
}
} }
"""#
  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float rmAdvancedEncodeV1(float x){return x<=.0031308?12.92*x:1.055*pow(x,1.0/2.4)-.055;}
// log2 of a positive Float, including subnormal alpha, without log2(0)-log2(0).
// Normal F32 dot/product rounding (including underflow) remains the guide's evaluation domain;
// a nonpositive premultiplied dot goes directly to the specified -16 floor. Nonfinite F32
// dot/output arithmetic rejects through the finite gate; it is never silently clamped. No low-alpha
// neighbor is excluded: actual source alpha is copied unchanged into the guide's green slot.
float rmAdvancedPositiveLogV1(float v){
 uint bits=as_type<uint>(v);uint exponent=(bits>>23)&255u;
 return exponent==0u?log2(float(bits&0x7fffffu))-149.0:log2(v);
}
[[stitchable]] float4 rmAdvancedGuideV1(sampler src,destination dest){
 float4 p=src.sample(src.transform(dest.coord()));
 if(!all(isfinite(p))||p.a < -0.000001 || p.a > 1.000001)return float4(as_type<float>(0x7fc00000u));
 uint alphaBits=as_type<uint>(p.a);
 if((alphaBits&0x80000000u)!=0u||(alphaBits&0x7fffffffu)==0u)return float4(0,0,0,1);
 float py=dot(p.rgb,float3(.2126729,.7151522,.0721750));
 if(!isfinite(py))return float4(as_type<float>(0x7fc00000u));
 float l=py>0?max(-16.0,rmAdvancedPositiveLogV1(py)-rmAdvancedPositiveLogV1(p.a)):-16.0;
 return float4(l*p.a,p.a,0,1);
}
[[stitchable]] float4 rmAdvancedBandV1(sampler src,sampler fine,sampler wide,float4 params,destination dest){
 float2 d=dest.coord();float4 p=src.sample(src.transform(d));
 if(!all(isfinite(p))||p.a < -0.000001 || p.a > 1.000001)return float4(as_type<float>(0x7fc00000u));
 if(p.a<1.0/65535.0)return p;
 float4 f=fine.sample(fine.transform(d)),w=wide.sample(wide.transform(d));
 if(!all(isfinite(f))||!all(isfinite(w)))return float4(as_type<float>(0x7fc00000u));
 if(f.g<1.0/65535.0||w.g<1.0/65535.0)return p;
 float y=dot(p.rgb,float3(.2126729,.7151522,.0721750))/p.a;
 if(!isfinite(y))return float4(as_type<float>(0x7fc00000u));if(y<=0)return p;
 float band=clamp(f.r/f.g-w.r/w.g,-1.0,1.0),ev;
 if(params.y<.5)ev=.35*params.x*band;
 else{float u=clamp(rmAdvancedEncodeV1(y),0.0,1.0);ev=.60*params.x*4*u*(1-u)*band;}
 if(ev==0)return p;
 return float4(p.rgb*exp2(ev),p.a);
}
} }
"""#
}
