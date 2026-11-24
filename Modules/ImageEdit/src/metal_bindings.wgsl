struct Params {
    size: vec2<u32>,
    padding: vec2<u32>,
    rows: array<vec4<f32>>,
}

@group(0) @binding(0) var input_pixels: texture_2d<f32>;
@group(0) @binding(1) var input_mask: texture_2d<f32>;
@group(0) @binding(2) var output_pixels: texture_storage_2d<rgba32float,write>;
@group(0) @binding(3) var<storage, read_write> validation: atomic<u32>;
@group(0) @binding(4) var<storage, read> params: Params;
@group(0) @binding(5) var<storage, read> atlas: array<vec4<f32>>;
fn lawful_pixel(value: vec4<f32>, raw_ingress: bool) -> bool {
    let bits = bitcast<vec4<u32>>(value);
    let magnitude = bits & vec4<u32>(0x7fffffffu);
    if any(magnitude.rgb >= vec3<u32>(0x7f800000u)) { return false; }
    if magnitude.a == 0u { return all(magnitude.rgb == vec3<u32>(0u)); }
    return bits.a <= select(0x3f800000u, 0x3f800003u, raw_ingress);
}

fn lawful_coverage(value: f32) -> bool {
    let bits = bitcast<u32>(value);
    return bits <= 0x3f800000u || bits == 0x80000000u;
}
