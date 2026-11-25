import CoreImage
import Metal
import RAWMasterCore

/// RAW v1 only: bounded F32 coverage correction witnessed at the native decoder boundary.
/// No image-source tolerance and no change to the dehaze formula or legal-alpha samples.
enum DevelopmentDehazeRAWCoverageV1 {
  static let version="raw-dehaze-v1-upper-coverage-maxbits-1065353219-v1"
  static let maximumAlpha=Float(bitPattern:1065353219) // 1 + 3 F32 ULP; actual native A witness.
  private static let kernel:Result<CIKernel,Error> = Result {
    guard DevelopmentKernelCapability.supported else {
      throw DevelopmentError.unsupportedEngine
    }
    let source = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmDehazeRAWCoverageV1(sampler source,destination dest) {
  float4 p=source.sample(source.transform(dest.coord()));
  if(all(isfinite(p)) && p.a>1.0 && p.a<=as_type<float>(0x3f800003u)) {
    return float4(p.rgb/p.a,1.0);
  }
  return p;
}
}}
"""#
    guard let k=try CIKernel.kernels(withMetalString:source).first(where:{$0.name=="rmDehazeRAWCoverageV1"}) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return k
  }
  static func normalize(_ image:CIImage)throws->CIImage {
    let e=image.extent
    guard !e.isEmpty,!e.isInfinite,e.origin == .zero,e==e.integral else {
      throw PreviewPresentationError.allocationProtocol
    }
    guard let output=try kernel.get().apply(extent:e,roiCallback:{_,r in r},arguments:[image.samplingNearest()]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return output
  }
}
