import Foundation
import CoreImage
import Metal
import Darwin
import RAWMasterCore

/// Own versioned public-math hypothesis, not a Photos profile/HDR/algorithm identity claim.
/// F32 source image; only the explicitly versioned 512-sample curve DATA is IEEE half.
enum DevelopmentNaturalCubicCurvesV1 {
  static let operatorVersion = "natural-cubic-gamma512-luma-v1/F32-Thomas/gamma2.2/RGBAh-data/manual2nearest/RGB-before-master-.30-.59-.11"
  static let sampleCount=512,tableRows=4,tableBytes=16384
  struct Model { let x,y,b,c,d,second:[Float] }
  struct Tables {
    /// Rows R,G,B,master; each stored sample is half-rounded then promoted to F32.
    let rows:[[Float]]
    let data:Data
    func image()->CIImage {
      CIImage(bitmapData:data,bytesPerRow:512*8,size:.init(width:512,height:4),format:.RGBAh,colorSpace:nil).samplingNearest()
    }
  }
  @inline(__always) static func finite(_ value:Float)throws->Float {
    guard value.isFinite else {throw DevelopmentV3Error.unrepresentableParameters};return value
  }
  static func model(_ curve:DevelopmentCurve)throws->Model {
    try curve.validate()
    let x=curve.points.map{Float($0.x)},y=curve.points.map{Float($0.y)},n=x.count
    guard x.allSatisfy(\.isFinite),y.allSatisfy(\.isFinite) else {throw DevelopmentV3Error.unrepresentableParameters}
    var h=[Float]();h.reserveCapacity(n-1)
    for i in 0..<n-1 {let gap=try finite(x[i+1]-x[i]);guard gap>0 else{throw DevelopmentV3Error.unrepresentableParameters};h.append(gap)}
    var second=[Float](repeating:0,count:n)
    if n>2 {
      var diag=[Float](),rhs=[Float]();diag.reserveCapacity(n-2);rhs.reserveCapacity(n-2)
      for i in 0..<n-2 {
        diag.append(try finite(2*(h[i]+h[i+1])))
        let right=try finite((y[i+2]-y[i+1])/h[i+1]),left=try finite((y[i+1]-y[i])/h[i])
        rhs.append(try finite(6*(right-left)))
      }
      if diag.count>1 {for j in 1..<diag.count {
        guard diag[j-1]>0 else {throw DevelopmentV3Error.unrepresentableParameters}
        let w=try finite(h[j]/diag[j-1]),dh=try finite(w*h[j]),dr=try finite(w*rhs[j-1])
        diag[j]=try finite(diag[j]-dh);rhs[j]=try finite(rhs[j]-dr)
      }}
      guard diag.last!>0 else {throw DevelopmentV3Error.unrepresentableParameters}
      second[n-2]=try finite(rhs.last!/diag.last!)
      if diag.count>1 {for j in stride(from:diag.count-2,through:0,by:-1) {
        guard diag[j]>0 else {throw DevelopmentV3Error.unrepresentableParameters}
        let product=try finite(h[j+1]*second[j+2]),numerator=try finite(rhs[j]-product)
        second[j+1]=try finite(numerator/diag[j])
      }}
    }
    var bs=[Float](),cs=[Float](),ds=[Float]()
    for i in 0..<n-1 {
      let slope=try finite((y[i+1]-y[i])/h[i]),sum=try finite(2*second[i]+second[i+1])
      let correction=try finite(h[i]*sum/6)
      bs.append(try finite(slope-correction));cs.append(try finite(second[i]/2))
      ds.append(try finite((second[i+1]-second[i])/(6*h[i])))
    }
    return .init(x:x,y:y,b:bs,c:cs,d:ds,second:second)
  }
  static func evaluate(_ model:Model,_ value:Float)throws->Float {
    _ = try finite(value);let n=model.x.count
    if value<model.x[0] {let offset=try finite(value-model.x[0]),delta=try finite(model.b[0]*offset);return try finite(model.y[0]+delta)}
    if value>model.x[n-1] {
      let i=n-2,dx=try finite(model.x[n-1]-model.x[n-2])
      let c=try finite(2*model.c[i]*dx),d=try finite(3*model.d[i]*dx*dx)
      let tangent=try finite(try finite(model.b[i]+c)+d),delta=try finite(tangent*(value-model.x[n-1]))
      return try finite(model.y[n-1]+delta)
    }
    var i=0;while i+1<n-1&&value>=model.x[i+1]{i+=1}
    let z=try finite(value-model.x[i]),dz=try finite(z*model.d[i]),inner=try finite(model.c[i]+dz)
    let mid=try finite(model.b[i]+(try finite(z*inner)))
    return try finite(model.y[i]+(try finite(z*mid)))
  }
  static func row(_ channel:DevelopmentCurveChannelV3)throws->[Float] {
    try channel.validate()
    let black=Float(channel.inputBlack),white=Float(channel.inputWhite),span=try finite(white-black)
    guard black.isFinite,white.isFinite,black<white,span>0 else {throw DevelopmentV3Error.unrepresentableParameters}
    let spline=try model(channel.curve);var result=[Float]();result.reserveCapacity(sampleCount)
    for i in 0..<sampleCount {
      let t=try finite((Float(2)*Float(i))/Float(511))
      let warped=try finite(Darwin.powf(t,Float(1.0/2.2)))
      // Tiny positive Float white can make this overflow: reject BEFORE spline/clamp.
      let coordinate=try finite((warped-black)/span)
      let ordinate=try evaluate(spline,coordinate)
      _ = try finite(ordinate) // NEVER use a clamp to hide overflow/NaN.
      let clipped=min(Float(2),max(Float(0),ordinate))
      let powered=try finite(Darwin.powf(clipped,Float(2.2)))
      let half=Float16(powered);guard half.isFinite else{throw DevelopmentV3Error.unrepresentableParameters}
      result.append(Float(half))
    }
    return result
  }
  static func tables(_ curves:DevelopmentCurvesV3)throws->Tables {
    try curves.validate()
    let rows=try [curves.red,curves.green,curves.blue,curves.rgb].map{try row($0)}
    var half=[Float16]();half.reserveCapacity(512*4*4)
    // Alpha1 DATA rows prevent scalar LUT values from being treated as alpha.
    for values in rows {for v in values {let h=Float16(v);half.append(h);half.append(h);half.append(h);half.append(1)}}
    let data=half.withUnsafeBytes{Data($0)}
    guard data.count==tableBytes else {throw DevelopmentV3Error.invalidGraph}
    return .init(rows:rows,data:data)
  }
  static func sample(_ row:[Float],_ value:Float)throws->Float {
    guard row.count==sampleCount,row.allSatisfy(\.isFinite) else{throw DevelopmentV3Error.invalidGraph}
    _ = try finite(value)
    let raw=try finite(value/Float(2)),normalized=min(Float(0.9999),max(Float(0.0001),raw))
    let first=try finite(Float(511.0/512.0)*normalized),u=try finite(first+Float(1.0/1024.0))
    let position=try finite((try finite(u*Float(512)))-Float(0.5))
    let left=Int(floor(position)),fraction=try finite(position-Float(left))
    guard left>=0,left+1<sampleCount,fraction>=0,fraction<=1 else {throw DevelopmentV3Error.invalidGraph}
    let a=try finite(row[left]*(1-fraction)),b=try finite(row[left+1]*fraction)
    return try finite(a+b)
  }
  static func scalarTransfer(_ color:SIMD3<Float>,mapped:Float)throws->SIMD3<Float> {
    guard [color.x,color.y,color.z].allSatisfy(\.isFinite) else{throw DevelopmentV3Error.unrepresentableParameters}
    _ = try finite(mapped)
    let rg=try finite(color.x*Float(0.30)+color.y*Float(0.59)),luma=try finite(rg+color.z*Float(0.11))
    let limit=try finite(Float(8)*abs(luma)),portion=min(limit,max(-limit,mapped))
    let gain:Float
    if luma==0 {gain=0} else {gain=try finite(portion/luma)}
    let offset=try finite(mapped-portion)
    return .init(try finite(try finite(gain*color.x)+offset),try finite(try finite(gain*color.y)+offset),try finite(try finite(gain*color.z)+offset))
  }
  /// Shared renderer-order F32 RGB LUT evaluation and master input for natural Picker.
  static func mappedRGBAndLuma(_ straight:SIMD3<Float>,tables:Tables)throws->(color:SIMD3<Float>,luma:Float) {
    let color=SIMD3<Float>(try sample(tables.rows[0],straight.x),try sample(tables.rows[1],straight.y),try sample(tables.rows[2],straight.z))
    let luma=try finite(try finite(color.x*Float(0.30)+color.y*Float(0.59))+color.z*Float(0.11))
    return (color,luma)
  }
  static func referencePixel(_ pixel:SIMD4<Float>,tables:Tables)throws->SIMD4<Float> {
    if pixel.w<=0{return pixel} // Keep original NaN/negative-alpha pixels for existing full finite gate.
    guard [pixel.x,pixel.y,pixel.z,pixel.w].allSatisfy(\.isFinite) else{throw DevelopmentV3Error.unrepresentableParameters}
    let straight=SIMD3<Float>(try finite(pixel.x/pixel.w),try finite(pixel.y/pixel.w),try finite(pixel.z/pixel.w))
    let (color,luma)=try mappedRGBAndLuma(straight,tables:tables)
    let mapped=try sample(tables.rows[3],luma),result=try scalarTransfer(color,mapped:mapped)
    return .init(try finite(result.x*pixel.w),try finite(result.y*pixel.w),try finite(result.z*pixel.w),pixel.w)
  }
  private static let loaded:Result<CIKernel,Error> = Result {
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries else{throw DevelopmentError.unsupportedEngine}
    guard let kernel=try CIKernel.kernels(withMetalString:metalSource).first(where:{$0.name=="rmNaturalCubicCurvesV1"})else{throw DevelopmentError.unsupportedEngine};return kernel
  }
  /// Immutable actual data/lookup object passed to the same kernel invocation, never a regenerated guess.
  final class ActualLUTWitness {
    let data:Data,lookup:CIImage,recipeCurvesFingerprint:String,kernelSHA256:String
    fileprivate init(_ curves:DevelopmentCurvesV3)throws {
      let actual=try tables(curves)
      data=actual.data;lookup=actual.image();recipeCurvesFingerprint=try EditingFingerprint.of(curves)
      kernelSHA256=PreviewNaturalCurveFiniteEvidenceV1.kernelSHA256
    }
  }
  static func apply(_ curves:DevelopmentCurvesV3,to image:CIImage,canonicalNaturalEvidence:PreviewNaturalCurveFiniteEvidenceV1? = nil)throws->CIImage {
    try curves.validate()
    guard DevelopmentColorEngineV3.curvesActive(curves) else{return image}
    guard curves.algorithm == .naturalCubicGamma512LumaV1 else{throw DevelopmentV3Error.unsupportedAdjustment(.curves)}
    if let canonicalNaturalEvidence {
      let actual=try ActualLUTWitness(curves)
      guard let result=try loaded.get().apply(extent:image.extent,roiCallback:{index,r in index==1 ? CGRect(x:0,y:0,width:512,height:4):r},arguments:[image,actual.lookup])else{throw DevelopmentV3Error.invalidGraph}
      canonicalNaturalEvidence.recordActualLUT(actual,output:result)
      return result
    }
    let lookup=try tables(curves).image()
    guard let result=try loaded.get().apply(extent:image.extent,roiCallback:{index,r in index==1 ? CGRect(x:0,y:0,width:512,height:4):r},arguments:[image,lookup])else{throw DevelopmentV3Error.invalidGraph};return result
  }
  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float rmNaturalLookupV1(sampler table,float value,int row){
 if(!isfinite(value))return as_type<float>(0x7fc00000u);
 float raw=value/2.0;if(!isfinite(raw))return as_type<float>(0x7fc00000u);
 float n=clamp(raw,.0001,.9999);float u=(511.0/512.0)*n+(1.0/1024.0);float position=u*512.0-.5;
 if(!isfinite(u)||!isfinite(position))return as_type<float>(0x7fc00000u);
 float left=floor(position),fraction=position-left;
 float a=table.sample(table.transform(float2(left+.5,float(3-row)+.5))).r;
 float b=table.sample(table.transform(float2(left+1.5,float(3-row)+.5))).r;
 if(!isfinite(a)||!isfinite(b)||!isfinite(fraction))return as_type<float>(0x7fc00000u);
 float result=a*(1.0-fraction)+b*fraction;return isfinite(result)?result:as_type<float>(0x7fc00000u);
}
[[stitchable]] float4 rmNaturalCubicCurvesV1(sampler src,sampler table,destination dest){
 float4 p=src.sample(src.transform(dest.coord()));if(p.a<=0)return p;
 if(!all(isfinite(p)))return float4(as_type<float>(0x7fc00000u));
 float3 straight=p.rgb/p.a;if(!all(isfinite(straight)))return float4(as_type<float>(0x7fc00000u));
 // All three RGB LUTs (including identity channels) precede the master in an active group.
 float3 c=float3(rmNaturalLookupV1(table,straight.r,0),rmNaturalLookupV1(table,straight.g,1),rmNaturalLookupV1(table,straight.b,2));
 if(!all(isfinite(c)))return float4(as_type<float>(0x7fc00000u));
 float luma=(c.r*.30+c.g*.59)+c.b*.11;if(!isfinite(luma))return float4(as_type<float>(0x7fc00000u));
 float mapped=rmNaturalLookupV1(table,luma,3),limit=8.0*abs(luma);
 if(!isfinite(mapped)||!isfinite(limit))return float4(as_type<float>(0x7fc00000u));
 float portion=clamp(mapped,-limit,limit),gain=luma==0?0:portion/luma,offset=mapped-portion;
 if(!isfinite(portion)||!isfinite(gain)||!isfinite(offset))return float4(as_type<float>(0x7fc00000u));
 float3 color=(gain*c+offset)*p.a;
 if(!all(isfinite(color)))return float4(as_type<float>(0x7fc00000u));return float4(color,p.a);
}
} }
"""#
}
