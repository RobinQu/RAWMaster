import CoreImage
import RAWMasterCore

/// RAWMaster's source-space noise reduction for the versioned FlashRaw linear input.
/// Luminance and two independent chroma components share a brightness-guided neighbourhood.
enum FlashRawNoiseReduction {
  private static let kernel: Result<CIKernel, Error> = Result {
    let source = #"""
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    [[stitchable]] float4 rmFlashRawNoise(sampler src, float4 controls, destination dest) {
      const float3 luma=float3(.2126,.7152,.0722);
      float2 at=dest.coord(); float4 input=src.sample(src.transform(at));
      if (!all(isfinite(input)) || input.a<=0) return input;
      float3 rgb=input.rgb/input.a; float y=dot(rgb,luma);
      // A darker region needs a narrower radiometric threshold to keep its edges.
      float tolerance=.018+.10*sqrt(clamp(y,0.0,4.0));
      float3 sum=4.0*rgb; float total=4.0;
      for (int dy=-1;dy<=1;++dy) for (int dx=-1;dx<=1;++dx) {
        if (dx==0 && dy==0) continue;
        float4 q=src.sample(src.transform(at+float2(dx,dy)*controls.w));
        if (!all(isfinite(q)) || q.a<=0) continue;
        float3 color=q.rgb/q.a;
        float delta=(dot(color,luma)-y)/tolerance;
        float weight=(dx==0 || dy==0 ? 2.0:1.0)/(1.0+delta*delta);
        sum+=weight*color; total+=weight;
      }
      float3 delta=sum/total-rgb; float dy=dot(delta,luma);
      // Positive detail restores high-frequency luminance independently of chroma.
      float luminance=controls.x-controls.z*(max(controls.x,0.0)+.12);
      return float4((rgb+luminance*dy+controls.y*(delta-dy))*input.a,input.a);
    }
    } }
    """#
    guard let kernel = try CIKernel.kernels(withMetalString: source).first(where: { $0.name == "rmFlashRawNoise" }) else {
      throw DevelopmentError.unsupportedEngine
    }
    return kernel
  }

  static func apply(_ controls: DevelopmentNoiseReductionV3, to image: CIImage, proxyScale: Double) throws -> CIImage {
    try controls.validate(for: .raw)
    guard controls.enabled, controls.luminanceNoise != 0 || controls.colorNoise != 0 || controls.detail != 0 else { return image }
    guard proxyScale > 0, proxyScale <= 1 else { throw DevelopmentV3Error.invalidGraph }
    let radius = 1.5 * proxyScale
    let extent = image.extent
    let parameters = CIVector(x: controls.luminanceNoise, y: controls.colorNoise, z: controls.detail / 3, w: radius)
    let padding = ceil(radius) + 1
    guard let result = try kernel.get().apply(extent: extent,
      roiCallback: { _, rect in rect.insetBy(dx: -padding, dy: -padding) },
      arguments: [image.clampedToExtent().samplingLinear(), parameters]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return result
  }
}
