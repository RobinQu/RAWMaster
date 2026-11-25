import CoreImage
import Metal
import RAWMasterCore

/// Positive rendering operator for explicitly prepared algorithm version 2.
enum DevelopmentDehazeColorGuideV2 {
  static let version = "rawmaster-dehaze-v2/channel-min-luma/native-light-support/split-inverse"
  private struct Kernels { let guide, restore: CIKernel }
  private static let loaded: Result<Kernels,Error> = Result {
    guard DevelopmentKernelCapability.supported else {
      throw DevelopmentError.unsupportedEngine
    }
    let kernels = try CIKernel.kernels(withMetalString: metalSource)
    guard let guide = kernels.first(where: { $0.name == "rmDehazeColorGuideV2" }),
          let restore = kernels.first(where: { $0.name == "rmDehazeSplitRestoreV2" }) else {
      throw DevelopmentError.unsupportedEngine
    }
    return .init(guide: guide, restore: restore)
  }

  static func neighborhoodMinimum(_ guide: CIImage, radius: Double) -> CIImage {
    let extent = guide.extent
    return guide.clampedToExtent().applyingFilter("CIMorphologyMinimum",
      parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
  }

  static func guide(_ image: CIImage, airlight: DevelopmentDehazeAirlightV1,
                    sourceSize: DevelopmentPixelSize) throws -> CIImage {
    let normalized = try normalizedGuide(image, airlight: airlight)
    let radius = max(1, Double(min(sourceSize.width,sourceSize.height))*DevelopmentSpatialEngineV3.radiusFraction)
    return blurred(neighborhoodMinimum(normalized, radius: radius), radius: radius)
  }

  /// This input already contains exact opaque per-channel native minima.
  static func guide(afterNativeMinimum image: CIImage, airlight: DevelopmentDehazeAirlightV1,
                    sourceSize: DevelopmentPixelSize) throws -> CIImage {
    let checked = try PreviewFITCoverageV1.normalize(image, extent: image.extent)
    let normalized = try normalizedGuide(checked, airlight: airlight)
    let radius = max(1, Double(min(sourceSize.width,sourceSize.height))*DevelopmentSpatialEngineV3.radiusFraction)
    return blurred(normalized, radius: radius)
  }

  private static func normalizedGuide(_ image: CIImage, airlight: DevelopmentDehazeAirlightV1) throws -> CIImage {
    let air = CIVector(x: airlight.red, y: airlight.green, z: airlight.blue, w: 0)
    guard let normalized = try loaded.get().guide.apply(extent: image.extent,
      roiCallback: { _, rect in rect }, arguments: [image.samplingNearest(), air]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return normalized
  }

  private static func blurred(_ eroded: CIImage, radius: Double) -> CIImage {
    eroded.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5,radius/2)])
      .cropped(to: eroded.extent)
  }

  static func restore(_ image: CIImage, guide: CIImage, airlight: DevelopmentDehazeAirlightV1,
                      amount: Double) throws -> CIImage {
    guard amount.isFinite, (0...100).contains(amount), image.extent == guide.extent else {
      throw DevelopmentV3Error.invalidGraph
    }
    if amount == 0 { return image }
    let air = CIVector(x: airlight.red, y: airlight.green, z: airlight.blue, w: amount/100)
    guard let output = try loaded.get().restore.apply(extent: image.extent,
      roiCallback: { _, rect in rect }, arguments: [image.samplingNearest(), guide.samplingNearest(), air]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return output
  }

  static let metalSource = #"""
  #include <metal_stdlib>
  #include <CoreImage/CoreImage.h>
  using namespace metal;
  extern "C" { namespace coreimage {
  [[stitchable]] float4 rmDehazeColorGuideV2(sampler src, float4 air, destination dest) {
    float4 p=src.sample(src.transform(dest.coord()));
    if (!all(isfinite(p)) || p.a<0 || p.a>1) return float4(as_type<float>(0x7fc00000u));
    if (p.a<1.0/65535.0) return float4(1.0);
    float3 q=max(p.rgb/p.a,float3(0))/air.rgb;
    if (!all(isfinite(q))) return float4(as_type<float>(0x7fc00000u));
    return float4(clamp(q,0.0,1.0),1.0);
  }
  [[stitchable]] float4 rmDehazeSplitRestoreV2(sampler src, sampler guide, float4 air, destination dest) {
    float2 d=dest.coord();
    float4 p=src.sample(src.transform(d));
    if (!all(isfinite(p)) || p.a<0 || p.a>1) return float4(as_type<float>(0x7fc00000u));
    if (p.a<1.0/65535.0) return p;
    float3 m=guide.sample(guide.transform(d)).rgb;
    if (!all(isfinite(m))) return float4(as_type<float>(0x7fc00000u));
    float3 w=float3(.2126,.7152,.0722);
    float t=clamp(1.0-.85*air.a*clamp(dot(m,w),0.0,1.0),.20,1.0);
    if (t==1.0) return p;
    float3 difference=p.rgb/p.a-air.rgb;
    float brightness=dot(difference,w);
    float3 chroma=difference-float3(brightness);
    float3 restored=air.rgb+float3(brightness/t)+chroma/(t*t);
    return float4(restored*p.a,p.a);
  }
  }}
  """#
}
