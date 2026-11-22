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

fn blend(a: vec4<f32>, b: vec4<f32>, w: f32) -> vec4<f32> {
    if w == 0.0 { return a; }
    if w == 1.0 { return b; }
    return vec4<f32>(a.rgb + (b.rgb - a.rgb) * w, a.a);
}

@compute @workgroup_size(16, 16)
fn run(@builtin(global_invocation_id) gid: vec3<u32>) {
    if any(gid.xy >= params.size) { return; }
    let i = gid.y * params.size.x + gid.x;
