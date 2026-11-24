// Rows 9 and 10 follow the three immutable source/mask/tone step records.
// All coordinates are in the optical image's logical, bottom-up domain.
@group(0) @binding(6) var frozen_mask: texture_2d<f32>;

@compute @workgroup_size(8,8)
fn native_band(@builtin(global_invocation_id) id: vec3<u32>, @builtin(local_invocation_index) lane: u32,
               @builtin(workgroup_id) group: vec3<u32>, @builtin(num_workgroups) groups: vec3<u32>) {
    start_receipt(lane);
    let rect = vec4<u32>(params.rows[9]);
    let span = vec2<u32>(params.rows[10].xy);
    let rows = min(256u, params.size.y - params.band_y);
    var count = 0u;
    if id.x < span.y && id.y < rows {
        let band_position = id.xy + vec2<u32>(span.x, 0u);
        let p = band_position + vec2<u32>(0u, params.band_y);
        let src = textureLoad(half_source, vec2<u32>(p.x, params.size.y - 1u - p.y), 0);
        var coverage = 0.0;
        if all(p >= rect.xy) && all(p < rect.xy + rect.zw) {
            coverage = textureLoad(frozen_mask, p - rect.xy, 0).r;
        }
        let bits = bitcast<u32>(coverage);
        if opaque_finite(src) && (bits <= 0x3f800000u || bits == 0x80000000u) {
            let pixel = mask_tone_v3(src, coverage, params.rows[6], params.rows[7], params.rows[8].x);
            textureStore(half_target, band_position, pixel);
            count = select(0u, 1u, opaque_finite(pixel));
        }
    }
    finish_receipt(lane, group.y * groups.x + group.x, count);
}

@compute @workgroup_size(8,8)
fn sampled_half(@builtin(global_invocation_id) id: vec3<u32>, @builtin(local_invocation_index) lane: u32,
                @builtin(workgroup_id) group: vec3<u32>, @builtin(num_workgroups) groups: vec3<u32>) {
    start_receipt(lane);
    let span = vec2<u32>(params.rows[10].xy);
    let rows = min(256u, params.size.y - params.band_y);
    var count = 0u;
    if id.x < span.y / 2u && id.y < rows / 2u {
        let p = 2u * id.xy + vec2<u32>(span.x, 0u);
        // Use the original full-width band, physical absolute address and hardware interpolation.
        let uv = vec2<f32>(p + vec2<u32>(1u)) / vec2<f32>(textureDimensions(half_source));
        let value = textureSampleLevel(half_source, linear_sampler, uv, 0.0);
        if opaque_finite(value) {
            textureStore(half_target, id.xy + vec2<u32>(span.x / 2u, params.band_y / 2u), value);
            count = 4u;
        }
    }
    let native_slots = ((span.y + 7u) / 8u) * ((rows + 7u) / 8u);
    finish_receipt(lane, native_slots + group.y * groups.x + group.x, count);
}
