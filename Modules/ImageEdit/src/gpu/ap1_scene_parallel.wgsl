
fn normal_parallel(accumulator: vec4<f32>, branch: vec4<f32>, original: vec4<f32>, row: u32) -> vec4<f32> {
    if accumulator.a == 0.0 {
        return vec4<f32>(0.0);
    }
    return vec4<f32>(accumulator.rgb + row_f32(row).x * (branch.rgb - original.rgb), accumulator.a);
}
