// Normalize the integer significands before division. Hardware float division
// can flush the subnormal input or change which side of an F32 tie it lands on.
fn unpremultiply_subnormal_f32(channel: f32, denominator: u32, alpha_leading: i32) -> f32 {
    let bits = bitcast<u32>(channel);
    let magnitude = bits & 0x7fffffffu;
    if magnitude == 0u || magnitude >= 0x7f800000u { return channel; }
    let sign_bit = bits & 0x80000000u;
    let exponent = i32(magnitude >> 23u);
    let significand = select(magnitude, 0x00800000u | (magnitude & 0x007fffffu), exponent != 0);
    let leading = i32(firstLeadingBit(significand));
    var quotient_exponent = max(exponent - 1, 0) + leading - alpha_leading;
    var numerator = significand << u32(23 - leading);
    if numerator < denominator {
        numerator <<= 1u;
        quotient_exponent -= 1;
    }
    if quotient_exponent > 127 { return bitcast<f32>(sign_bit | 0x7f800000u); }

    // A nonzero quotient is normal (at least 2^-23). Generate 23 mantissa
    // bits and one guard bit. The remainder is always below a 24-bit divisor.
    var remainder = numerator - denominator;
    var quotient = 1u;
    for (var byte = 0u; byte < 3u; byte++) {
        let dividend = remainder << 8u;
        let digit = dividend / denominator;
        quotient = (quotient << 8u) | digit;
        remainder = dividend - digit * denominator;
    }
    var rounded = quotient >> 1u;
    rounded += u32((quotient & 1u) != 0u && (remainder != 0u || (rounded & 1u) != 0u));
    return bitcast<f32>(sign_bit | ((u32(quotient_exponent + 126) << 23u) + rounded));
}

// Multiply by a subnormal alpha with a single ties-to-even rounding. The
// 24-bit RGB significand and the 23-bit alpha produce at most 47 bits.
fn premultiply_subnormal_f32(channel: f32, alpha: u32) -> f32 {
    let bits = bitcast<u32>(channel);
    let sign_bit = bits & 0x80000000u;
    let exponent = (bits >> 23u) & 255u;
    if exponent == 255u { return channel; }
    if exponent == 0u { return bitcast<f32>(sign_bit); }

    let significand = (bits & 0x007fffffu) | 0x00800000u;
    let low_product = (significand & 0xffffu) * (alpha & 0xffffu);
    let cross = (significand >> 16u) * (alpha & 0xffffu) + (significand & 0xffffu) * (alpha >> 16u);
    let low = low_product + (cross << 16u);
    let high = (significand >> 16u) * (alpha >> 16u) + (cross >> 16u) + u32(low < low_product);
    var leading = i32(firstLeadingBit(low));
    if high != 0u { leading = 32 + i32(firstLeadingBit(high)); }

    // The exact product is (high:low) × 2^(exponent − 299).
    // Keep either 24 significant bits or the bits above the subnormal unit.
    let result_exponent = max(0, leading + i32(exponent) - 172);
    let shift = u32(max(leading - 23, 150 - i32(exponent)));
    if shift >= 48u { return bitcast<f32>(sign_bit); }
    var rounded = low;
    if shift != 0u {
        let guard_shift = shift - 1u;
        var with_guard = low;
        var sticky = false;
        if guard_shift >= 32u {
            let top_shift = guard_shift - 32u;
            with_guard = high >> top_shift;
            sticky = low != 0u || extractBits(high, 0u, top_shift) != 0u;
        } else if guard_shift != 0u {
            with_guard = (low >> guard_shift) | (high << (32u - guard_shift));
            sticky = extractBits(low, 0u, guard_shift) != 0u;
        }
        rounded = with_guard >> 1u;
        rounded += u32((with_guard & 1u) != 0u && (sticky || (rounded & 1u) != 0u));
    }
    // A rounding carry can promote a subnormal or advance a normal exponent.
    return bitcast<f32>(sign_bit | ((u32(max(result_exponent - 1, 0)) << 23u) + rounded));
}
