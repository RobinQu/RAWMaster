#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
    bool inOpaqueNoiseRange(float4 value) {
        uint4 bits = as_type<uint4>(value);
        return all((bits.rgb & uint3(0x7fffffffu)) <= uint3(0x41000000u)) && bits.a == 0x3f800000u;
    }
    [[stitchable]] float4 checkedNoiseInputs(sampler raw, sampler src, sampler local) {
        bool inside = inOpaqueNoiseRange(raw.sample(raw.coord())) && inOpaqueNoiseRange(src.sample(src.coord())) &&
                      inOpaqueNoiseRange(local.sample(local.coord()));
        return float4(inside ? 0.0f : 1.0f, 0.0f, 0.0f, 1.0f);
    }
} }
