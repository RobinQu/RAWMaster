#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {

[[stitchable]] float4 rmImageLinearExposure(sample_t pixel, float gain) {
    return float4(pixel.rgb * gain, pixel.a);
}

} }
