fn color_grading_v2(pixel: vec4<f32>, table: u32, enabled: bool) -> vec4<f32> {
    let exponent_bits = vec4<u32>(0x7f800000u);
    if !enabled || any((bitcast<vec4<u32>>(pixel) & exponent_bits) == exponent_bits) {
        return pixel;
    }
    if bitcast<i32>(pixel.a) <= 0 {
        return vec4<f32>(0.0, 0.0, 0.0, pixel.a);
    }
    let alpha_bits = bitcast<u32>(pixel.a);
    let subnormal_alpha = alpha_bits < 0x00800000u;
    var straight: vec3<f32>;
    if subnormal_alpha {
        let leading = i32(firstLeadingBit(alpha_bits));
        let denominator = alpha_bits << u32(23 - leading);
        straight = vec3<f32>(unpremultiply_subnormal_f32(pixel.r, denominator, leading),
                             unpremultiply_subnormal_f32(pixel.g, denominator, leading),
                             unpremultiply_subnormal_f32(pixel.b, denominator, leading));
    } else {
        straight = pixel.rgb / pixel.a;
    }
    if any((bitcast<vec3<u32>>(straight) & exponent_bits.xyz) == exponent_bits.xyz) {
        return invalid_pixel();
    }

    var rgb = basic_encode(straight);
    let u = clamp(dot(rgb, BASIC_LUMA), 0.0, 1.0);
    let controls = params.rows[table + 4u];
    let m = 0.5 - 0.25 * controls.y;
    let r = 0.1 + 0.4 * controls.x;
    let shadow = clamp((u - controls.z) / controls.w, 0.0, 1.0);
    let ws = 1.0 - shadow * shadow * (3.0 - 2.0 * shadow);
    let wh = smoothstep(m, m + r, u);
    let wheel = ws * params.rows[table] + (1.0 - ws - wh) * params.rows[table + 1u]
                + wh * params.rows[table + 2u];
    let global = params.rows[table + 3u];
    let envelope = 4.0 * u * (1.0 - u);
    rgb += wheel.rgb * envelope + vec3<f32>(wheel.a);
    rgb += global.rgb * envelope + vec3<f32>(global.a);
    let linear = basic_decode(rgb);
    if subnormal_alpha {
        return vec4<f32>(premultiply_subnormal_f32(linear.r, alpha_bits),
                         premultiply_subnormal_f32(linear.g, alpha_bits),
                         premultiply_subnormal_f32(linear.b, alpha_bits), pixel.a);
    }
    return vec4<f32>(linear * pixel.a, pixel.a);
}
