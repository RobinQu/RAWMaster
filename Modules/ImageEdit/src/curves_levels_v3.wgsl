fn evaluate_curve_v3(value: f32, start: u32, count: u32) -> f32 {
    if value < 0.0 {
        return value + params.rows[start + 1u].z;
    }
    for (var i = 0u; i < count; i++) {
        let first = params.rows[start + i * 2u];
        let second = params.rows[start + i * 2u + 1u];
        if value <= first.y || i == count - 1u {
            if value > 1.0 {
                return value + (first.z + second.x + second.y + second.z) - 1.0;
            }
            let t = (value - first.x) / (first.y - first.x);
            return ((first.z * t + second.x) * t + second.y) * t + second.z;
        }
    }
    return value;
}

fn evaluate_levels_v3(value: f32, start: u32, count: u32) -> f32 {
    var left = params.rows[start].xy;
    if value <= left.x {
        return value + left.y - left.x;
    }
    for (var i = 1u; i < count; i++) {
        let right = params.rows[start + i].xy;
        if value <= right.x {
            return mix(left.y, right.y, (value - left.x) / (right.x - left.x));
        }
        left = right;
    }
    return value + left.y - left.x;
}

fn curves_levels_v3(pixel: vec4<f32>, table: u32, enabled: bool) -> vec4<f32> {
    let exponent_bits = vec4<u32>(0x7f800000u);
    if !enabled || pixel.a <= 0.0 || any((bitcast<vec4<u32>>(pixel) & exponent_bits) == exponent_bits) {
        return pixel;
    }
    let curve_counts = vec4<u32>(params.rows[table]);
    let level_counts = vec4<u32>(params.rows[table + 3u]);
    let blue_levels = u32(params.rows[table + 4u].x);
    let blacks = params.rows[table + 1u];
    let whites = params.rows[table + 2u];
    let curve_rows = table + 5u;
    let level_rows = table + 125u;
    let straight = pixel.rgb / pixel.a;
    if any((bitcast<vec3<u32>>(straight) & exponent_bits.xyz) == exponent_bits.xyz) {
        return invalid_pixel();
    }
    var rgb = basic_encode(straight);
    for (var channel = 0u; channel < 3u; channel++) {
        if curve_counts.x != 0u {
            rgb[channel] = evaluate_curve_v3((rgb[channel] - blacks.x) / (whites.x - blacks.x),
                                             curve_rows, curve_counts.x);
        }
        let index = channel + 1u;
        if curve_counts[index] != 0u {
            rgb[channel] = evaluate_curve_v3((rgb[channel] - blacks[index]) / (whites[index] - blacks[index]),
                                             curve_rows + index * 30u, curve_counts[index]);
        }
    }
    if level_counts.x != 0u {
        let luminance = dot(rgb, BASIC_LUMA);
        rgb += vec3<f32>(evaluate_levels_v3(luminance, level_rows, level_counts.x) - luminance);
    }
    let component_levels = vec3<u32>(level_counts.zw, blue_levels);
    for (var channel = 0u; channel < 3u; channel++) {
        if level_counts.y != 0u {
            rgb[channel] = evaluate_levels_v3(rgb[channel], level_rows + 5u, level_counts.y);
        }
        if component_levels[channel] != 0u {
            rgb[channel] = evaluate_levels_v3(rgb[channel], level_rows + (channel + 2u) * 5u,
                                              component_levels[channel]);
        }
    }
    return vec4<f32>(basic_decode(rgb) * pixel.a, pixel.a);
}
