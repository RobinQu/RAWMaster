import CoreImage
import Metal
import RAWMasterCore

/// Repairs the upper bound of coverage at the native and FIT graph boundaries.
enum PreviewFITCoverageV1 {
  static let version = "native-fit-upper-coverage-straight-rgb-v2"

  static let metalSource = """
  #include <metal_stdlib>
  #include <CoreImage/CoreImage.h>
  using namespace metal;
  extern "C" { namespace coreimage {
  [[stitchable]] float4 rmFITUpperCoverageV1(sampler source, destination dest) {
    float4 pixel = source.sample(source.transform(dest.coord()));
    if (pixel.a > 1.0 && all(isfinite(pixel))) {
      // Preserve the straight color represented by the associated sample.
      return float4(pixel.rgb / pixel.a, 1.0);
    }
    return pixel;
  }
  }}
  """

  private static let kernel: Result<CIKernel, Error> = Result {
    guard DevelopmentKernelCapability.supported else {
      throw DevelopmentError.unsupportedEngine
    }
    guard let kernel = try CIKernel.kernels(withMetalString: metalSource).first(where: { $0.name == "rmFITUpperCoverageV1" }) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return kernel
  }

  static func usesSingleNativeCheck(_ geometry: DevelopmentGeometryVersionV3?) -> Bool {
    geometry == .legacyV1 || geometry == .legacyV2
  }

  static func normalize(_ input: CIImage, extent: CGRect) throws -> CIImage {
    guard input.extent == extent, !extent.isEmpty, !extent.isInfinite,
          extent.origin == .zero, extent == extent.integral else {
      throw PreviewPresentationError.allocationProtocol
    }
    guard let image = try kernel.get().apply(extent: extent, roiCallback: { _, rect in rect },
                                             arguments: [input.samplingNearest()]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return image
  }
}
