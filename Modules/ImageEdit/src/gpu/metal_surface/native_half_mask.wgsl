// The mask producer uses absolute Core Image coordinates; row zero is already
// the logical bottom row. Only the original optical texture needs a Y flip.
@group(0) @binding(6) var frozen_mask: texture_2d<f32>;
fn half_point_graph(source: vec4<f32>, logical_position: vec2<u32>) -> vec4<f32> {
    let coverage = textureLoad(frozen_mask, logical_position, 0).r;
    let bits = bitcast<u32>(coverage);
    if bits > 0x3f800000u && bits != 0x80000000u { return invalid_pixel(); }
    return mask_tone_v3(source, coverage, params.rows[6], params.rows[7], params.rows[8].x);
}
