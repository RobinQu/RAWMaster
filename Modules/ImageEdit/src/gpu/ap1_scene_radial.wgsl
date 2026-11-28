
fn radial_coverage(q: vec2<f32>, row: u32) -> f32 {
    let facts = row_f32(row);
    let feather = row_f32(row + 1u).x;
    let radius = length((q - facts.xy) / facts.zw);
    if feather == 0.0 {
        return select(0.0, 1.0, radius <= 1.0);
    }
    return clamp(1.0 - smoothstep(1.0 - feather, 1.0, radius), 0.0, 1.0);
}
