const BASIC_LUMA = vec3<f32>(0.2126, 0.7152, 0.0722);
override refine_software_vulkan_srgb: bool = false;

fn refined_basic_encode(value: f32) -> f32 {
    let a = abs(value);
    if a <= 0.0031308 || bitcast<u32>(a) >= 0x7f800000u {
        let encoded = filter_encode(vec3<f32>(a)).x;
        return select(encoded, -encoded, value < 0.0);
    }
    // x^(5/12) = sqrt(sqrt(x)) * cbrt(sqrt(x)). Correct the cube-root
    // residual before re-encoding between successive color nodes.
    let root = sqrt(a);
    let q = pow(root, 1.0 / 3.0);
    let q2 = q * q;
    let corrected = q + fma(-q, q2, root) / (3.0 * q2);
    let encoded = 1.055 * (sqrt(root) * corrected) - 0.055;
    return select(encoded, -encoded, value < 0.0);
}

fn basic_encode(linear: vec3<f32>) -> vec3<f32> {
    if refine_software_vulkan_srgb {
        return vec3<f32>(refined_basic_encode(linear.r),
                         refined_basic_encode(linear.g),
                         refined_basic_encode(linear.b));
    }
    let encoded = filter_encode(abs(linear));
    return select(encoded, -encoded, linear < vec3<f32>(0));
}

fn basic_decode(encoded: vec3<f32>) -> vec3<f32> {
    let value = abs(encoded);
    let decoded = select(pow((value + 0.055) / 1.055, vec3<f32>(2.4)), value / 12.92,
                         value <= vec3<f32>(0.04045));
    return select(decoded, -decoded, encoded < vec3<f32>(0));
}

fn basic_contrast(value: f32, amount: f32) -> f32 {
    if value <= 0.0 || value >= 1.0 || amount == 0.0 {
        return value;
    }
    let pivot = 0.55;
    let exponent = exp2(1.3 * amount);
    if value < pivot {
        return pivot * pow(value / pivot, exponent);
    }
    return 1.0 - (1.0 - pivot) * pow((1.0 - value) / (1.0 - pivot), exponent);
}

// The software Vulkan Basic node uses the positive normal branch of the CPU's
// pinned libm 0.2.16 powf. Input sign handling remains with the color transfer.
/* origin: FreeBSD /usr/src/lib/msun/src/e_powf.c */
/*
 * Conversion to float by Ian Lance Taylor, Cygnus Support, ian@cygnus.com.
 */
/*
 * ====================================================
 * Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
 *
 * Developed at SunPro, a Sun Microsystems, Inc. business.
 * Permission to use, copy, modify, and distribute this
 * software is freely granted, provided that this notice
 * is preserved.
 * ====================================================
 */

/*
rust-lang/libm as a whole is available for use under the MIT license:

------------------------------------------------------------------------------
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
*/
fn software_pow_hi(value: f32) -> f32 {
    return bitcast<f32>(bitcast<u32>(value) & 0xfffff000u);
}

fn software_point_pow(base: f32, exponent: f32) -> f32 {
    let bits = bitcast<u32>(base);
    if bits < 0x00800000u || bits >= 0x7f800000u || !(exponent >= 0.25 && exponent <= 8.0) {
        return pow(base, exponent);
    }
    if base == 1.0 || exponent == 1.0 { return base; }
    if exponent == 2.0 { return base * base; }
    if exponent == 0.5 { return sqrt(base); }

    // Normalize into one of the two base intervals for the split log2 estimate.
    let fraction = bits & 0x007fffffu;
    var n = i32(bits >> 23u) - 127;
    var mantissa_bits = fraction | 0x3f800000u;
    let high_interval = fraction > 0x1cc471u && fraction < 0x5db3d7u;
    if fraction >= 0x5db3d7u {
        n += 1;
        mantissa_bits -= 0x00800000u;
    }
    let ax = bitcast<f32>(mantissa_bits);
    let bp = select(1.0f, 1.5f, high_interval);
    let dp_high = select(0.0f, bitcast<f32>(0x3f15c000u), high_interval);
    let dp_low = select(0.0f, bitcast<f32>(0x35d1cfdcu), high_interval);
    let numerator = ax - bp;
    let inv_sum = 1.0 / (ax + bp);
    let s = numerator * inv_sum;
    let sh = software_pow_hi(s);
    let th_bits = (((mantissa_bits >> 1u) & 0xfffff000u) | 0x20000000u) + 0x00400000u + select(0u, 0x00200000u, high_interval);
    let th = bitcast<f32>(th_bits);
    let tl = ax - (th - bp);
    let sl = inv_sum * ((numerator - sh * th) - sh * tl);
    var s2 = s * s;
    var r = s2 * s2 * (bitcast<f32>(0x3f19999au) + s2 * (bitcast<f32>(0x3edb6db7u) +
        s2 * (bitcast<f32>(0x3eaaaaabu) + s2 * (bitcast<f32>(0x3e8ba305u) +
        s2 * (bitcast<f32>(0x3e6c3255u) + s2 * bitcast<f32>(0x3e53f142u))))));
    r += sl * (sh + s);
    s2 = sh * sh;
    let th2 = software_pow_hi(3.0 + s2 + r);
    let tl2 = r - ((th2 - 3.0) - s2);
    let u0 = sh * th2;
    let v0 = sl * th2 + tl2 * s;
    var ph = software_pow_hi(u0 + v0);
    var pl = v0 - (ph - u0);
    let zh = bitcast<f32>(0x3f764000u) * ph;
    let zl = bitcast<f32>(0xb8f623c6u) * ph + pl * bitcast<f32>(0x3f76384fu) + dp_low;
    let log_high = software_pow_hi(((zh + zl) + dp_high) + f32(n));
    let log_low = zl - (((log_high - f32(n)) - dp_high) - zh);

    // Multiply the split logarithm, then evaluate exp2 on the reduced remainder.
    let exponent_high = software_pow_hi(exponent);
    pl = (exponent - exponent_high) * log_high + exponent * log_low;
    ph = exponent_high * log_high;
    var z = pl + ph;
    if z < -125.0 || z > 126.0 { return pow(base, exponent); }
    let zbits = bitcast<u32>(z);
    let mag = zbits & 0x7fffffffu;
    n = 0;
    if mag > 0x3f000000u {
        var k = i32(mag >> 23u) - 127;
        let rounded = zbits + (0x00800000u >> u32(k + 1));
        k = i32((rounded & 0x7fffffffu) >> 23u) - 127;
        let integral = bitcast<f32>(rounded & ~(0x007fffffu >> u32(k)));
        n = i32(((rounded & 0x007fffffu) | 0x00800000u) >> u32(23 - k));
        if z < 0.0 { n = -n; }
        ph -= integral;
    }
    var t = bitcast<f32>(bitcast<u32>(pl + ph) & 0xffff8000u);
    let u = t * bitcast<f32>(0x3f317200u);
    let v = (pl - (t - ph)) * bitcast<f32>(0x3f317218u) + t * bitcast<f32>(0x35bfbe8cu);
    z = u + v;
    let w = v - (z - u);
    t = z * z;
    let t1 = z - t * (bitcast<f32>(0x3e2aaaabu) + t * (bitcast<f32>(0xbb360b61u) +
        t * (bitcast<f32>(0x388ab355u) + t * (bitcast<f32>(0xb5ddea0eu) + t * bitcast<f32>(0x3331bb4cu)))));
    r = (z * t1) / (t1 - 2.0) - (w + z * w);
    z = 1.0 - (r - z);
    return bitcast<f32>(bitcast<u32>(z) + (u32(n) << 23u));
}


fn basic_node_encode(value: f32, reference: bool) -> f32 {
    if !reference { return basic_encode(vec3<f32>(value)).x; }
    let magnitude = abs(value);
    if magnitude <= 0.0031308 || bitcast<u32>(magnitude) >= 0x7f800000u {
        return refined_basic_encode(value);
    }
    let encoded = 1.055 * software_point_pow(magnitude, 1.0f / 2.4f) - 0.055;
    return select(encoded, -encoded, value < 0.0);
}

fn basic_node_luma_decode(value: f32, reference: bool) -> f32 {
    if !reference { return basic_decode(vec3<f32>(value)).x; }
    let magnitude = abs(value);
    if magnitude <= 0.04045 {
        let linear = magnitude / 12.92;
        return select(linear, -linear, value < 0.0);
    }
    let linear = software_point_pow((magnitude + 0.055) / 1.055, 2.4);
    return select(linear, -linear, value < 0.0);
}

fn basic_node_color_encode(value: vec3<f32>, reference: bool) -> vec3<f32> {
    if !reference { return basic_encode(value); }
    return vec3<f32>(basic_node_encode(value.r, true),
                     basic_node_encode(value.g, true),
                     basic_node_encode(value.b, true));
}


fn basic_node_color_decode(value: vec3<f32>, reference: bool) -> vec3<f32> {
    if !reference { return basic_decode(value); }
    return vec3<f32>(basic_node_luma_decode(value.r, true),
                     basic_node_luma_decode(value.g, true),
                     basic_node_luma_decode(value.b, true));
}

fn basic_node_contrast(value: f32, amount: f32, reference: bool) -> f32 {
    if !reference { return basic_contrast(value, amount); }
    if value <= 0.0 || value >= 1.0 || amount == 0.0 { return value; }
    let pivot = 0.55;
    let exponent = exp2(1.3 * amount);
    if value < pivot { return pivot * software_point_pow(value / pivot, exponent); }
    return 1.0 - (1.0 - pivot) * software_point_pow((1.0 - value) / (1.0 - pivot), exponent);
}

fn basic_v3(pixel: vec4<f32>, light: vec4<f32>, color: vec4<f32>, mono: vec4<f32>) -> vec4<f32> {
    let flags = u32(color.w);
    let reference_transfer = refine_software_vulkan_srgb;
    if flags == 0u || pixel.a <= 0.0 {
        return pixel;
    }
    var rgb = pixel.rgb / pixel.a;
    let exponent_bits = vec3<u32>(0x7f800000u);
    if any((bitcast<vec3<u32>>(rgb) & exponent_bits) == exponent_bits) {
        return invalid_pixel();
    }
    if (flags & 1u) != 0u {
        let y = dot(rgb, BASIC_LUMA);
        let encoded = basic_node_encode(y, reference_transfer);
        let w = clamp(encoded, 0.0, 1.0);
        let tone = basic_node_contrast(encoded + 0.8 * light.x * w * (1.0 - w), light.y, reference_transfer);
        let linear = basic_node_luma_decode(tone, reference_transfer);
        if abs(y) > 1e-8 {
            rgb *= linear / y;
        } else {
            rgb += vec3<f32>(linear - y);
        }
        let black = 0.05 * light.z;
        rgb = (rgb - vec3<f32>(black)) / (1.0 - black);
        let white_weight = smoothstep(0.45, 1.0, clamp(basic_node_encode(dot(rgb, BASIC_LUMA), reference_transfer), 0.0, 1.0));
        rgb *= 1.0 + 0.35 * light.w * white_weight;
    }
    if (flags & 2u) != 0u {
        var encoded = basic_node_color_encode(rgb, reference_transfer);
        let y = dot(encoded, BASIC_LUMA);
        let top = max(encoded.r, max(encoded.g, encoded.b));
        let bottom = min(encoded.r, min(encoded.g, encoded.b));
        let saturation = clamp((top - bottom) / max(abs(top), 1e-4), 0.0, 1.0);
        let skin = select(1.0, 0.5, encoded.r > encoded.g && encoded.g > encoded.b);
        let warm = select(0.0, 1.0, encoded.r > encoded.b && encoded.g > encoded.b);
        let blue = max(0.0, encoded.b - max(encoded.r, encoded.g)) * (1.0 - clamp(y, 0.0, 1.0));
        let scale = (1.0 + color.x * (1.0 - 0.391 * warm)) * (1.0 + 1.35 * color.y * (1.0 - saturation) * skin);
        encoded = vec3<f32>(y) + (encoded - vec3<f32>(y)) * scale;
        encoded += blue * (color.x * vec3<f32>(-2.576, -0.364, 0.447) + color.y * vec3<f32>(-1.830, -0.494, -0.142));
        let tint = vec3<f32>(dot(encoded, vec3<f32>(0.0214143, 0.0479051, -0.0105798)) - 0.0019973,
                             0.0, dot(encoded, vec3<f32>(-0.0231834, -0.0894344, -0.0299565)) + 0.0047775);
        rgb = basic_node_color_decode(encoded + 2.0 * color.z * tint, reference_transfer);
    }
    if (flags & 4u) != 0u {
        let encoded = basic_encode(rgb);
        var gray = dot(encoded, BASIC_LUMA) + mono.x * (0.09 * (encoded.g - encoded.r) + 0.392 * (encoded.g - encoded.b));
        let w = clamp(gray, 0.0, 1.0);
        gray += 0.8 * mono.y * w * (1.0 - w);
        rgb = basic_decode(vec3<f32>(basic_contrast(gray, mono.z)));
    }
    return vec4<f32>(rgb * pixel.a, pixel.a);
}
