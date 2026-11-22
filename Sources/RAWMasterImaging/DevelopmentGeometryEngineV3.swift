import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// Consumes the one Core geometry descriptor. No independent angle, projection or trim formula.
enum DevelopmentGeometryEngineV3 {
  static let operatorVersion = "rawmaster-geometry-v3.1/late-D4-v1/Core-top-left-map/linear-premultiplied-sampling"
  private static let loaded: Result<CIKernel,Error> = Result {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsDynamicLibraries else { throw DevelopmentError.unsupportedEngine }
    let all = try CIKernel.kernels(withMetalString:metalSource)
    guard let kernel = all.first(where: { $0.name == "rmProjectiveGeometry" }) else { throw DevelopmentError.unsupportedEngine }
    return kernel
  }
  static func apply(_ geometry: DevelopmentGeometryV3, to input: CIImage) throws -> CIImage {
    let e = input.extent
    guard e.width.isFinite, e.height.isFinite, e.width > 0, e.height > 0,
      e.width == floor(e.width), e.height == floor(e.height),
      e.width <= Double(DevelopmentLocalEditLimits.maximumSourceDimension), e.height <= Double(DevelopmentLocalEditLimits.maximumSourceDimension) else { throw DevelopmentV3Error.invalidGraph }
    let sourceSize = DevelopmentPixelSize(width:Int(e.width),height:Int(e.height))
    let mapping = try geometry.mapping(sourceSize:sourceSize)
    let image = e.origin == .zero ? input : input.transformed(by:.init(translationX:-e.minX,y:-e.minY))
    let output = CGRect(x:0,y:0,width:mapping.outputSize.width,height:mapping.outputSize.height)
    if mapping.projective == nil {
      let m = mapping.forwardMatrix
      if m == [1,0,0,0,1,0,0,0,1], output.size == image.extent.size { return image }
      // Conjugate the Core top-left affine map by the source/output Y-axis reflections.
      let transform = CGAffineTransform(a:m[0],b:-m[3],c:-m[1],d:m[4],
        tx:m[1]*e.height+m[2],ty:output.height-m[4]*e.height-m[5])
      return image.transformed(by:transform).cropped(to:output)
    }
    let inverse = try mapping.inverseMatrix, descriptor = mapping.projective!
    let pre = descriptor.prePerspectiveMatrix, clip = descriptor.intermediateClip
    let roi = try DevelopmentProjectiveSourceROIV3(mapping:mapping,sourceExtent:image.extent,outputExtent:output)
    func row(_ m: [Double],_ i: Int) -> CIVector { .init(x:m[i*3],y:m[i*3+1],z:m[i*3+2],w:0) }
    let args: [Any] = [image.clampedToExtent().samplingLinear(),row(inverse,0),row(inverse,1),row(inverse,2),
      row(pre,0),row(pre,1),row(pre,2),CIVector(x:clip.x,y:clip.y,z:clip.width,w:clip.height),
      CIVector(x:e.width,y:e.height,z:output.width,w:output.height)]
    guard let result = try loaded.get().apply(extent:output,roiCallback:{ _, rect in roi.sourceRect(for:rect) },arguments:args) else { throw DevelopmentError.unreadable }
    return result
  }
  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmProjectiveGeometry(sampler src,float4 i0,float4 i1,float4 i2,
 float4 p0,float4 p1,float4 p2,float4 clip,float4 sizes,destination dest) {
 float2 d=dest.coord();float3 output=float3(d.x,sizes.w-d.y,1.0);
 float3 h=float3(dot(i0.xyz,output),dot(i1.xyz,output),dot(i2.xyz,output));
 if(!all(isfinite(h))||h.z<1e-4)return float4(as_type<float>(0x7fc00000u));
 float2 top=h.xy/h.z;
 float3 before=float3(dot(p0.xyz,float3(top,1)),dot(p1.xyz,float3(top,1)),dot(p2.xyz,float3(top,1)));
 if(!all(isfinite(before))||before.z<1e-4)return float4(as_type<float>(0x7fc00000u));
 float2 q=before.xy/before.z;
 // This clip is part of the Core descriptor. Reject outside points; never clamp a hit into it.
 if(any(q<clip.xy-1e-3)||any(q>clip.xy+clip.zw+1e-3))return float4(0);
 if(any(top<float2(-1e-3))||any(top>sizes.xy+1e-3))return float4(0);
 return src.sample(src.transform(float2(top.x,sizes.y-top.y)));
}
} }
"""#
}
