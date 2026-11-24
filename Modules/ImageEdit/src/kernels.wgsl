struct Params {
    size: vec2<u32>,
    padding: vec2<u32>,
    rows: array<vec4<f32>>,
}

@group(0) @binding(0) var<storage, read> left: array<vec4<f32>>;
@group(0) @binding(1) var<storage, read> right: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> coverage: array<f32>;
@group(0) @binding(3) var<storage, read_write> target_pixels: array<vec4<f32>>;
@group(0) @binding(4) var<storage, read> params: Params;
@group(0) @binding(5) var<storage, read> atlas: array<vec4<f32>>;

