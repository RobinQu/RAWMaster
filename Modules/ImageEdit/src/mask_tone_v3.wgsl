// The local kernel consumes frozen F32 coverage inside each adjustment.
fn mask_smooth(lo: f32, hi: f32, x: f32) -> f32 {
    let t = clamp((x - lo) / max(hi - lo, 1e-5), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn mask_encode(x: f32) -> f32 {
    let a = abs(x);
    if a <= 0.0031308 { return sign(x) * (12.92 * a); }
    return sign(x) * (1.055 * pow(a, 1.0 / 2.4) - 0.055);
}

fn mask_decode(x: f32) -> f32 {
    let a = abs(x);
    if a <= 0.04045 { return sign(x) * (a / 12.92); }
    return sign(x) * pow((a + 0.055) / 1.055, 2.4);
}

override refine_software_vulkan_hue: bool = false;

fn mask_hue_encode(x: f32) -> f32 {
    let a = abs(x);
    if !refine_software_vulkan_hue || a <= 0.0031308 || (bitcast<u32>(a) & 0x7f800000u) == 0x7f800000u {
        return mask_encode(x);
    }
    // a^(5/12) = sqrt(sqrt(a)) * cbrt(sqrt(a)). Refine the cube root once
    // before HSV sector selection magnifies the software Vulkan pow error.
    let root = sqrt(a);
    let estimate = pow(root, 1.0 / 3.0);
    let cube_root = (2.0 * estimate + root / (estimate * estimate)) / 3.0;
    return sign(x) * (1.055 * (sqrt(root) * cube_root) - 0.055);
}

fn mask_hsv(rgb: vec3<f32>) -> vec3<f32> {
    let hi = max(rgb.r, max(rgb.g, rgb.b));
    let lo = min(rgb.r, min(rgb.g, rgb.b));
    let d = hi - lo;
    var h = 0.0;
    if d > 1e-8 {
        if hi == rgb.r { h = (rgb.g - rgb.b) / d; }
        else if hi == rgb.g { h = 2.0 + (rgb.b - rgb.r) / d; }
        else { h = 4.0 + (rgb.r - rgb.g) / d; }
    }
    var s = 0.0;
    if hi > 1e-8 { s = d / hi; }
    // Replacing the following expression with fract changes native RGB on negative hues.
    h = h / 6.0 - floor(h / 6.0);
    return vec3<f32>(h, s, hi);
}

fn mask_rgb(hsv: vec3<f32>) -> vec3<f32> {
    let p = abs(fract(hsv.xxx + vec3<f32>(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return hsv.z * mix(vec3<f32>(1.0), clamp(p - 1.0, vec3<f32>(0.0), vec3<f32>(1.0)), hsv.y);
}

fn mask_tone_v3(pixel: vec4<f32>, mask: f32, adjust: vec4<f32>, tone: vec4<f32>, enabled: f32) -> vec4<f32> {
    if enabled == 0.0 || (bitcast<u32>(mask) & 0x7fffffffu) == 0u || bitcast<i32>(pixel.a) <= 0 { return pixel; }
    let alpha_bits = bitcast<u32>(pixel.a);
    let subnormal_alpha = alpha_bits < 0x00800000u;
    var rgb: vec3<f32>;
    if subnormal_alpha {
        let leading = i32(firstLeadingBit(alpha_bits));
        let denominator = alpha_bits << u32(23 - leading);
        rgb = vec3<f32>(unpremultiply_subnormal_f32(pixel.r, denominator, leading),
                        unpremultiply_subnormal_f32(pixel.g, denominator, leading),
                        unpremultiply_subnormal_f32(pixel.b, denominator, leading));
    } else {
        rgb = pixel.rgb / pixel.a;
    }
    let exponent = vec3<u32>(0x7f800000u);
    if any((bitcast<vec3<u32>>(rgb) & exponent) == exponent) { return invalid_pixel(); }
    let luma = vec3<f32>(0.2126, 0.7152, 0.0722);
    rgb *= exp2(2.0 * adjust.x * mask);
    var y = dot(rgb, luma);
    var encoded = clamp(mask_encode(y), 0.0, 1.0);
    rgb *= 1.0 + 0.5 * adjust.y * mask_smooth(0.5, 1.0, encoded) * mask;
    rgb *= 1.0 + 0.5 * adjust.z * (1.0 - mask_smooth(0.0, 0.5, encoded)) * mask;
    y = dot(rgb, luma);
    encoded = mask_encode(y);
    let contrast = tone.x * mask;
    if encoded > 0.0 && encoded < 1.0 && contrast != 0.0 {
        let pivot = 0.55;
        let power = exp2(1.3 * contrast);
        var goal = 0.0;
        if encoded < pivot { goal = pivot * pow(encoded / pivot, power); }
        else { goal = 1.0 - (1.0 - pivot) * pow((1.0 - encoded) / (1.0 - pivot), power); }
        let decoded = mask_decode(goal);
        if abs(y) > 1e-8 { rgb *= decoded / y; }
        else { rgb += vec3<f32>(decoded - y); }
    }
    // Preserve Core Image's rounded control scale before applying the per-pixel coverage.
    let black_scale = 0.05 * tone.z;
    rgb = fma(vec3<f32>(-black_scale), vec3<f32>(mask), rgb) / fma(-black_scale, mask, 1.0);
    let white = smoothstep(0.45, 1.0, clamp(mask_encode(dot(rgb, luma)), 0.0, 1.0));
    rgb *= 1.0 + fma(0.35, tone.y, 0.0) * white * mask;
    let hue = tone.w * mask;
    if hue != 0.0 {
        var hsv = mask_hsv(vec3<f32>(mask_hue_encode(rgb.r), mask_hue_encode(rgb.g), mask_hue_encode(rgb.b)));
        hsv.x = fract(hsv.x + hue + 1.0);
        let shifted = mask_rgb(hsv);
        rgb = vec3<f32>(mask_decode(shifted.r), mask_decode(shifted.g), mask_decode(shifted.b));
    }
    let gray = dot(rgb, luma);
    rgb = vec3<f32>(gray) + (rgb - vec3<f32>(gray)) * (1.0 + adjust.w * mask);
    if subnormal_alpha {
        return vec4<f32>(premultiply_subnormal_f32(rgb.r, alpha_bits), premultiply_subnormal_f32(rgb.g, alpha_bits),
                         premultiply_subnormal_f32(rgb.b, alpha_bits), pixel.a);
    }
    return vec4<f32>(rgb * pixel.a, pixel.a);
}
