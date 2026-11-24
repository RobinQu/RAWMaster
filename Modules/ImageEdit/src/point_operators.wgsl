fn filter_axis(i: u32) -> f32 {
    return f32((65535u * i + 31u) / 63u) / 65535.0;
}

fn filter_encode(linear: vec3<f32>) -> vec3<f32> {
    let nonlinear = 1.055 * pow(linear, vec3<f32>(1.0 / 2.4)) - 0.055;
    return select(nonlinear, 12.92 * linear, linear <= vec3<f32>(0.0031308));
}

// Each plane is a 64³ RGBA32F cube with red varying fastest.
fn cube(plane: u32, cell: vec3<u32>, f: vec3<f32>) -> vec3<f32> {
    let n = plane * 262144u + cell.x + 64u * cell.y + 4096u * cell.z;
    let a = mix(atlas[n].rgb, atlas[n + 1u].rgb, f.x);
    let b = mix(atlas[n + 64u].rgb, atlas[n + 65u].rgb, f.x);
    let c = mix(atlas[n + 4096u].rgb, atlas[n + 4097u].rgb, f.x);
    let d = mix(atlas[n + 4160u].rgb, atlas[n + 4161u].rgb, f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

fn invalid_pixel() -> vec4<f32> {
    return vec4<f32>(bitcast<f32>(0x7fc00000u));
}

// settings = blend weight, normalized amount, HDR mode, RAW alpha repair.
// planes = low index, high index, implicit zero low plane, identity flag.
fn photo_filter(input: vec4<f32>, settings: vec4<f32>, planes: vec4<f32>) -> vec4<f32> {
    if planes.w == 1.0 {
        return input;
    }
    let exponent_bits = vec4<u32>(0x7f800000u);
    if any((bitcast<vec4<u32>>(input) & exponent_bits) == exponent_bits) || input.a < 0.0 {
        return invalid_pixel();
    }
    var alpha = input.a;
    if alpha > 1.0 {
        if settings.w != 1.0 || bitcast<u32>(alpha) > 0x3f800003u {
            return invalid_pixel();
        }
        alpha = 1.0;
    }
    if alpha < 1.0 / 65535.0 {
        return input;
    }

    let linear = input.rgb / alpha;
    if any((bitcast<vec3<u32>>(linear) & exponent_bits.xyz) == exponent_bits.xyz) {
        return invalid_pixel();
    }
    let bounded = clamp(linear, vec3<f32>(0), vec3<f32>(1));
    let encoded = filter_encode(bounded);
    var cell = vec3<u32>(clamp(floor(encoded * 63.0), vec3<f32>(0), vec3<f32>(62)));
    var fraction: vec3<f32>;
    for (var c = 0u; c < 3u; c++) {
        var i = cell[c];
        if i > 0u && encoded[c] < filter_axis(i) {
            i = i - 1u;
        }
        if i < 62u && encoded[c] > filter_axis(i + 1u) {
            i = i + 1u;
        }
        cell[c] = i;
        fraction[c] = (encoded[c] - filter_axis(i)) / (filter_axis(i + 1u) - filter_axis(i));
    }

    var delta: vec3<f32>;
    if planes.z == 1.0 {
        delta = cube(u32(planes.y), cell, fraction) * settings.x;
    } else if settings.x == 0.0 {
        delta = cube(u32(planes.x), cell, fraction);
    } else {
        let low = cube(u32(planes.x), cell, fraction);
        let high = cube(u32(planes.y), cell, fraction);
        delta = mix(low, high, settings.x);
    }

    var color = linear + delta;
    if settings.z > 0.0 && any(linear != bounded) {
        let coefficients = vec3<f32>(0.2126, 0.7152, 0.0722);
        let residual = linear - bounded;
        color = bounded + delta + mix(residual, vec3<f32>(dot(residual, coefficients)), settings.y);
        if settings.z == 2.0 {
            color = vec3<f32>(dot(color, coefficients));
        }
    }
    return vec4<f32>(color * alpha, alpha);
}

fn masked_exposure(pixel: vec4<f32>, coverage_value: f32, ev: f32) -> vec4<f32> {
    if coverage_value == 0.0 || pixel.a <= 0.0 {
        return pixel;
    }
    let gain = exp2(ev * coverage_value);
    return vec4<f32>(((pixel.rgb / pixel.a) * gain) * pixel.a, pixel.a);
}

fn blend(a: vec4<f32>, b: vec4<f32>, w: f32) -> vec4<f32> {
    if w == 0.0 {
        return a;
    }
    if w == 1.0 {
        return b;
    }
    return vec4<f32>(a.rgb + (b.rgb - a.rgb) * w, a.a);
}

