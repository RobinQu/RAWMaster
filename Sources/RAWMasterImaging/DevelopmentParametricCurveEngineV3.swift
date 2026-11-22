import CoreImage
import Foundation
import RAWMasterCore

/// Parametric tone has 16 equally spaced knots. The GPU can index its original
/// PCHIP polynomial directly, including the same left segment at exact boundaries.
enum DevelopmentParametricCurveEngineV3 {
  private static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_PARAMETRIC_DIRECT"] != "0"
  private static let kernel = try? CIKernel.kernels(withMetalString: source).first { $0.name == "parametricCurve" }

  static func prewarm() {
    if enabled { _ = kernel }
  }

  static func apply(_ curve: DevelopmentCurve, to image: CIImage) throws -> CIImage? {
    guard enabled, let kernel else { return nil }
    let segments = try curve.segments()
    guard segments.count == 15, curve.points.enumerated().allSatisfy({ $0.element.x == Double($0.offset)/15 }) else { return nil }
    var coefficients = [Float]()
    coefficients.reserveCapacity(15*8)
    for s in segments {
      coefficients.append(contentsOf:[Float(s.lowerX),Float(s.upperX),Float(s.a),1,Float(s.b),Float(s.c),Float(s.d),1])
    }
    let width = 2*segments.count
    let table = CIImage(bitmapData:coefficients.withUnsafeBytes { Data($0) },bytesPerRow:width*16,
                        size:CGSize(width:width,height:1),format:.RGBAf,colorSpace:nil).samplingNearest()
    return kernel.apply(extent:image.extent,roiCallback:{ input,rect in input == 0 ? rect : table.extent },
                        arguments:[image,table])
  }

  private static let source = #"""
  #include <metal_stdlib>
  #include <CoreImage/CoreImage.h>
  using namespace metal;
  extern "C" { namespace coreimage {
  float toneEncode(float x) {
    float a=abs(x); return (x<0?-1.0:1.0)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055);
  }
  float toneDecode(float x) {
    float a=abs(x); return (x<0?-1.0:1.0)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4));
  }
  float applyTone(sampler table, float x) {
    int i=min(14,int(clamp(x,0.0,1.0)*15.0));
    float4 a=table.sample(float2(float(2*i)+.5,.5));
    // Compare actual stored float endpoints to handle rounding at a knot.
    if ((i>0 && x<=a.r) || (i<14 && x>a.g)) {
      i += x<=a.r ? -1 : 1;
      a=table.sample(float2(float(2*i)+.5,.5));
    }
    float4 b=table.sample(float2(float(2*i)+1.5,.5));
    if (x<0) return x+b.b;
    if (x>1) return x+(a.b+b.r+b.g+b.b)-1.0;
    float t=(x-a.r)/(a.g-a.r);
    return ((a.b*t+b.r)*t+b.g)*t+b.b;
  }
  [[stitchable]] float4 parametricCurve(sampler src,sampler table) {
    float4 p=src.sample(src.coord());
    if(!all(isfinite(p)) || p.a<=0) return p;
    float3 c=p.rgb/p.a;
    for (int i=0;i<3;i++) c[i]=toneDecode(applyTone(table,toneEncode(c[i])));
    return float4(c*p.a,p.a);
  }
  } }
  """#
}
