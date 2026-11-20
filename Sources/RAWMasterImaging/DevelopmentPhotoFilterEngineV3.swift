import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// An owned observed look, not Photos' private LUT/algorithm or a strict-reference PASS claim.
/// The canonical hook is intentionally a later grant; this standalone engine is default closed.
enum DevelopmentPhotoFilterEngineV3 {
  static let operatorVersion="photo-filter-v1/observed-delta64/planes0-1-25-50-100/manual-trilinear-f32/linear-strength/HDR-boundary-residual-mono-noir-endpoint-v2/alpha-bypass65535"
  static let alphaMinimum:Float=1.0/65535
  private static let loaded: Result<CIKernel,Error> = Result {
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries else{throw DevelopmentPhotoFilterError.unavailableDevice}
    let kernels=try CIKernel.kernels(withMetalString:metalSource)
    guard let kernel=kernels.first(where:{$0.name=="rmPhotoFilterV1"}) else{throw DevelopmentPhotoFilterError.invalidGraph}
    return kernel
  }
  static func capabilities(resources:DevelopmentPhotoFilterResourceStore = .shared)->DevelopmentPhotoFilterResourceStore.Capabilities {
    let value=resources.capabilities()
    guard value.filters.count>1 else{return value}
    guard (try? loaded.get()) != nil else{return .init(filters:[.original],resourceVersion:nil)}
    return value
  }
  /// Runtime implementation identity, never part of a Core recipe fingerprint or RAW key.
  static func activeResourceIdentity(_ filter:DevelopmentFilterV3,
                                     resources:DevelopmentPhotoFilterResourceStore = .shared)throws->String? {
    try filter.validate()
    guard filter.enabled,filter.selection != .original,filter.intensity != 0 else{return nil}
    try resources.validate(filter) // Actual payload authority before any bitmap/scalar cache replay.
    _ = try loaded.get()
    let available=resources.capabilities()
    guard available.filters.contains(filter.selection),let version=available.resourceVersion else{throw DevelopmentPhotoFilterError.unavailableFilter}
    return operatorVersion+"/catalog:"+version
  }
  static func activeResourceIdentity(_ recipe:DevelopmentRecipe,
                                     resources:DevelopmentPhotoFilterResourceStore = .shared)throws->String? {
    try recipe.validate()
    guard recipe.schemaVersion==3,let payload=recipe.adjustmentsV3 else{return nil}
    return try activeResourceIdentity(payload.filter,resources:resources)
  }
  /// An unavailable bundle/kernel is an explicitly closed implementation, not active fallback.
  static func stageIdentity(resources:DevelopmentPhotoFilterResourceStore = .shared)throws->String {
    let available=capabilities(resources:resources)
    guard available.filters.count>1,let version=available.resourceVersion else{return "photo-filter-closed-v1"}
    return operatorVersion+"/catalog:"+version
  }
  static func apply(_ filter:DevelopmentFilterV3,to image:CIImage,resources:DevelopmentPhotoFilterResourceStore = .shared,
                    resourceLease:((DevelopmentPhotoFilterResourceStore.Pair)throws->Void)? = nil)throws->CIImage {
    try filter.validate() // Even malformed disabled/zero parameters must never bypass validation.
    guard filter.enabled,filter.selection != .original,filter.intensity != 0 else{return image}
    try resources.validate(filter)
    let kernel=try loaded.get(),pair=try resources.pair(filter)
    try resourceLease?(pair)
    let extent=image.extent
    guard extent.minX.isFinite,extent.minY.isFinite,extent.width.isFinite,extent.height.isFinite,
      extent.width>0,extent.height>0,!extent.isInfinite else{throw DevelopmentPhotoFilterError.invalidGraph}
    let monochrome=filter.selection == .mono || filter.selection == .noir
    // Endpoint flag follows actual Double100, not a rounded Floatt just below100.
    let hdrFlag:CGFloat=monochrome ? (filter.intensity==100 ? 2:1):0
    let params=CIVector(x:CGFloat(pair.weight),y:pair.zeroLower ? 1:0,z:hdrFlag,w:CGFloat(filter.normalizedIntensity))
    let atlas=CGRect(x:0,y:0,width:512,height:512)
    guard let graph=kernel.apply(extent:extent,roiCallback:{index,rect in index==0 ? rect.intersection(extent):atlas},
      arguments:[image.samplingNearest(),pair.lower.image.samplingNearest(),pair.upper.image.samplingNearest(),params]) else{throw DevelopmentPhotoFilterError.invalidGraph}
    // CI graph/texture aliases keep their actual MTLBuffer and its charge alive after pair dies.
    // No actual task is launched here; canonical callers keep their existing checked finite/join.
    return graph
  }
  static func encode(_ value:Double)->Double {value<=0.0031308 ? 12.92*value:1.055*pow(value,1/2.4)-0.055}
  static func axis(_ index:Int)->Double {Double((65535*index+31)/63)/65535}
  /// Double reference uses the actual stored Float table nodes. No simulated hardware fractions.
  static func reference(_ pixel:SIMD4<Double>,intensity:Double,selection:DevelopmentPhotoFilterV3 = .vivid,
                        sample:(Int,Int,Int,Int)throws->SIMD3<Double>)throws->SIMD4<Double> {
    guard [pixel.x,pixel.y,pixel.z,pixel.w,intensity].allSatisfy(\.isFinite),(0...1).contains(pixel.w),(0...100).contains(intensity) else{throw DevelopmentError.invalidEncoding}
    if intensity==0 || pixel.w<Double(alphaMinimum){return pixel}
    let u=SIMD3(pixel.x,pixel.y,pixel.z)/pixel.w
    guard [u.x,u.y,u.z].allSatisfy(\.isFinite) else{throw DevelopmentError.invalidEncoding}
    var cell=SIMD3<Int>.zero,weight=SIMD3<Double>.zero
    for c in 0..<3 {
      let q=encode(min(1,max(0,u[c])))
      var i=min(62,max(0,Int(floor(q*63))))
      if i>0 && q<axis(i){i-=1};if i<62 && q>axis(i+1){i+=1}
      cell[c]=i;weight[c]=(q-axis(i))/(axis(i+1)-axis(i))
    }
    let high=DevelopmentPhotoFilterCatalog.intensities.first(where:{Double($0)>=intensity}) ?? 100
    let low=DevelopmentPhotoFilterCatalog.intensities.last(where:{Double($0)<intensity}) ?? 0
    func table(_ percent:Int)throws->SIMD3<Double> {
      if percent==0{return .zero}
      var result=SIMD3<Double>.zero
      for b in 0...1 {for g in 0...1 {for r in 0...1 {
        let wr=r==0 ? 1-weight.x:weight.x,wg=g==0 ? 1-weight.y:weight.y,wb=b==0 ? 1-weight.z:weight.z
        let node=try sample(percent,cell.x+r,cell.y+g,cell.z+b)
        result += node*(wr*wg*wb)
      }}}
      return result
    }
    let delta:SIMD3<Double>
    if intensity==Double(high){delta=try table(high)}
    else{let t=(intensity-Double(low))/Double(high-low);let a=try table(low),b=try table(high);delta=a*(1-t)+b*t}
    var color=u+delta
    if (selection == .mono || selection == .noir) && (u.x<0 || u.y<0 || u.z<0 || u.x>1 || u.y>1 || u.z>1) {
      let bounded=SIMD3(min(1,max(0,u.x)),min(1,max(0,u.y)),min(1,max(0,u.z)))
      let residual=u-bounded,t=intensity/100
      let y=residual.x*0.2126+residual.y*0.7152+residual.z*0.0722
      color=bounded+delta+residual*(1-t)+SIMD3<Double>(repeating:y)*t
      if intensity==100 {
        let luminance=color.x*0.2126+color.y*0.7152+color.z*0.0722
        color=SIMD3<Double>(repeating:luminance)
      }
    }
    let v=color*pixel.w
    guard [v.x,v.y,v.z].allSatisfy(\.isFinite) else{throw DevelopmentError.invalidEncoding}
    return .init(v.x,v.y,v.z,pixel.w)
  }
  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float rmFilterAxisV1(int k){return float((65535*k+31)/63)/65535.0;}
float rmFilterEncodeV1(float x){return x<=.0031308?12.92*x:1.055*pow(x,1.0/2.4)-.055;}
float3 rmFilterNodeV1(sampler table,int3 node){
 int index=node.x+64*node.y+4096*node.z;
 float2 at=float2(float(index%512)+.5,float(index/512)+.5);
 return table.sample(table.transform(at)).rgb;
}
float3 rmFilterCubeV1(sampler table,int3 cell,float3 f){
 float3 a=mix(rmFilterNodeV1(table,cell),rmFilterNodeV1(table,cell+int3(1,0,0)),f.x);
 float3 b=mix(rmFilterNodeV1(table,cell+int3(0,1,0)),rmFilterNodeV1(table,cell+int3(1,1,0)),f.x);
 float3 c=mix(rmFilterNodeV1(table,cell+int3(0,0,1)),rmFilterNodeV1(table,cell+int3(1,0,1)),f.x);
 float3 d=mix(rmFilterNodeV1(table,cell+int3(0,1,1)),rmFilterNodeV1(table,cell+int3(1,1,1)),f.x);
 return mix(mix(a,b,f.y),mix(c,d,f.y),f.z);
}
[[stitchable]] float4 rmPhotoFilterV1(sampler source,sampler lower,sampler upper,float4 params,destination dest){
 float4 p=source.sample(source.transform(dest.coord()));
 if(!all(isfinite(p))||p.a<0||p.a>1)return float4(as_type<float>(0x7fc00000u));
 if(p.a<1.0/65535.0)return p;
 float3 u=p.rgb/p.a;if(!all(isfinite(u)))return float4(as_type<float>(0x7fc00000u));
 float3 bounded=clamp(u,0.0,1.0);
 float3 q=float3(rmFilterEncodeV1(bounded.r),rmFilterEncodeV1(bounded.g),rmFilterEncodeV1(bounded.b));
 int3 cell=int3(clamp(floor(q*63.0),0.0,62.0));float3 f;
 for(int c=0;c<3;c++){
  if(cell[c]>0&&q[c]<rmFilterAxisV1(cell[c]))cell[c]--;
  if(cell[c]<62&&q[c]>rmFilterAxisV1(cell[c]+1))cell[c]++;
  f[c]=(q[c]-rmFilterAxisV1(cell[c]))/(rmFilterAxisV1(cell[c]+1)-rmFilterAxisV1(cell[c]));
 }
 float3 delta;
 if(params.y>.5)delta=rmFilterCubeV1(upper,cell,f)*params.x;
 else if(params.x==0)delta=rmFilterCubeV1(lower,cell,f);
 else delta=mix(rmFilterCubeV1(lower,cell,f),rmFilterCubeV1(upper,cell,f),params.x);
 float3 v=u+delta;
 // Only outside the captured cube: Mono/Noir residuals lose chroma continuously withglobalt.
 // Exact100 then projects FINALv tostrictgray. Cube/lowalpha paths andSilvertone are untouched.
 if(params.z>.5&&(any(u<0.0)||any(u>1.0))){
  float3 base=clamp(u,0.0,1.0),residual=u-base;
  float luminance=dot(residual,float3(.2126,.7152,.0722));
  v=base+delta+mix(residual,float3(luminance),params.w);
  if(params.z>1.5){float y=dot(v,float3(.2126,.7152,.0722));v=float3(y);}
 }
 return float4(v*p.a,p.a); // No linearRGB clamp; actual sourcealpha is preserved.
}
} }
"""#
}
