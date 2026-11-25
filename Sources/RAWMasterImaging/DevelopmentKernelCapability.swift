import CoreImage
import Metal

/// Core Image compiles stitchable Metal kernels at runtime. The device's
/// `supportsDynamicLibraries` flag describes a different Metal feature and is
/// false on virtualized GPUs that still compile these kernels, so probe the
/// operation the engines actually perform instead of inferring it from device
/// properties.
enum DevelopmentKernelCapability {
  static let supported: Bool = {
    guard MTLCreateSystemDefaultDevice() != nil else { return false }
    let source = #"""
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    [[stitchable]] float4 rmCapabilityProbe(sampler src, destination dest) {
      return src.sample(src.coord());
    }
    } }
    """#
    guard let kernels = try? CIKernel.kernels(withMetalString: source) else { return false }
    return kernels.contains { $0.name == "rmCapabilityProbe" }
  }()
}
