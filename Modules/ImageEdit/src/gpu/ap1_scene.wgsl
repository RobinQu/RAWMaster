// AP1 scene operator contract v1. Slots and the entry point are generated from the typed plan.
@group(0) @binding(0) var<storage, read> source: array<vec4<f32>>;
@group(0) @binding(1) var<storage, read_write> target_pixels: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> params: array<vec4<u32>>;
@group(0) @binding(3) var<storage, read_write> invalid: atomic<u32>;

const AP1_Y = vec3<f32>(0.2722287168, 0.6740817658, 0.0536895174);

fn row_f32(i: u32) -> vec4<f32> {
    return bitcast<vec4<f32>>(params[2u + i]);
}

fn lawful(pixel: vec4<f32>) -> bool {
    return all((bitcast<vec4<u32>>(pixel) & vec4<u32>(0x7fffffffu)) < vec4<u32>(0x7f800000u))
        && pixel.a >= 0.0 && pixel.a <= 1.0;
}

fn linear_coverage(q: vec2<f32>, row: u32) -> f32 {
    let points = row_f32(row);
    let axis = points.zw - points.xy;
    return clamp(dot(q - points.xy, axis) / dot(axis, axis), 0.0, 1.0);
}

fn exposure_delta(ev: f32, offset: u32, count: u32) -> f32 {
    let start = row_f32(offset).xy;
    if ev <= start.x {
        return start.y - start.x;
    }
    for (var i = 1u; i < count; i += 1u) {
        let a = row_f32(offset + i - 1u).xy;
        let b = row_f32(offset + i).xy;
        if ev <= b.x {
            let first = a.y - a.x;
            let last = b.y - b.x;
            return first + (last - first) * ((ev - a.x) / (b.x - a.x));
        }
    }
    let end = row_f32(offset + count - 1u).xy;
    return end.y - end.x;
}

fn corrector(pixel: vec4<f32>, coverage: f32, row: u32) -> vec4<f32> {
    if pixel.a == 0.0 {
        return vec4<f32>(0.0);
    }
    let facts = row_f32(row);
    let weight = facts.y * coverage;
    if weight == 0.0 {
        return pixel;
    }
    var gain = facts.x;
    let luma = dot(pixel.rgb, AP1_Y);
    let count = u32(facts.z);
    if count > 0u && luma > 0.0 {
        let ev = log2(luma) - log2(pixel.a) + log2(gain);
        gain *= exp2(exposure_delta(ev, row + 1u, count));
    }
    return vec4<f32>(pixel.rgb * (1.0 + (gain - 1.0) * weight), pixel.a);
}

fn normal_layer(bottom: vec4<f32>, top: vec4<f32>, row: u32) -> vec4<f32> {
    if bottom.a == 0.0 {
        return vec4<f32>(0.0);
    }
    return vec4<f32>(bottom.rgb + (top.rgb - bottom.rgb) * row_f32(row).x, bottom.a);
}
