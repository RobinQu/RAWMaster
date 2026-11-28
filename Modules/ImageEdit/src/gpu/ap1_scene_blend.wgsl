
// Conservative bounds keep the Layer blend intermediates finite before evaluation.
const MULTIPLY_STRAIGHT_LIMIT = 0x1p58f;
const MULTIPLY_ALPHA_MIN = 0x1p-62f;
const BLEND_STRAIGHT_LIMIT = 0x1p120f;
const MIN_MAX_STRAIGHT_LIMIT = 0x1p127f;
const MIN_MAX_MIX_LIMIT = 0x1p126f;

struct BlendResult {
    pixel: vec4<f32>,
    supported: bool,
}

fn blend_alpha_is_subnormal(alpha: f32) -> bool {
    let magnitude = bitcast<u32>(alpha) & 0x7fffffffu;
    return magnitude != 0u && magnitude < 0x00800000u;
}

fn blend_rgb_within(rgb: vec3<f32>, limit: f32) -> bool {
    let magnitude = bitcast<vec3<u32>>(rgb) & vec3<u32>(0x7fffffffu);
    return all(magnitude <= vec3<u32>(bitcast<u32>(limit)));
}

fn soft_light(x: vec3<f32>, y: vec3<f32>) -> vec3<f32> {
    let d = select(sqrt(x), ((16.0 * x - 12.0) * x + 4.0) * x, x <= vec3<f32>(0.25));
    return select(
        x + (2.0 * y - 1.0) * (d - x),
        x - (1.0 - 2.0 * y) * x * (1.0 - x),
        y <= vec3<f32>(0.5),
    );
}

// Mode codes match the 039 Blend enum. The bounded modes restore both operands' residuals.
fn blend_rgb(b: vec3<f32>, s: vec3<f32>, mode: u32) -> vec3<f32> {
    switch mode {
        case 0u: { return s; }
        case 1u: { return b + s; }
        case 2u: { return b - s; }
        case 3u: { return b * s; }
        case 10u: { return abs(b - s); }
        case 11u: { return s + (dot(b, AP1_Y) - dot(s, AP1_Y)); }
        case 12u: { return b + (dot(s, AP1_Y) - dot(b, AP1_Y)); }
        default: {}
    }
    let x = clamp(b, vec3<f32>(0.0), vec3<f32>(1.0));
    let y = clamp(s, vec3<f32>(0.0), vec3<f32>(1.0));
    let screen = 1.0 - 2.0 * (1.0 - x) * (1.0 - y);
    let multiply = 2.0 * x * y;
    var core: vec3<f32>;
    switch mode {
        case 4u: { core = x + y - x * y; }
        case 5u: { core = select(screen, multiply, x <= vec3<f32>(0.5)); }
        case 6u: { core = soft_light(x, y); }
        default: { core = select(screen, multiply, y <= vec3<f32>(0.5)); }
    }
    return core + (b - x) + (s - y);
}

fn layer_blend(current: vec4<f32>, branch: vec4<f32>, row: u32) -> BlendResult {
    // Source alpha was checked by its bits before any earlier operator could flush it to zero.
    let rejected = BlendResult(vec4<f32>(0.0), false);
    if current.a == 0.0 {
        return BlendResult(vec4<f32>(0.0), true);
    }
    let facts = row_f32(row);
    let weight = facts.x;
    let mode = u32(facts.y);
    var premultiplied: vec3<f32>;
    if mode == 8u || mode == 9u {
        // Positive alpha is identical along both branches. Comparing premultiplied
        // operands avoids dividing a discarded operand that could overflow.
        let selected = select(min(current.rgb, branch.rgb), max(current.rgb, branch.rgb), mode == 8u);
        if !blend_rgb_within(selected, current.a * MIN_MAX_STRAIGHT_LIMIT) {
            return rejected;
        }
        if weight != 1.0 && (!blend_rgb_within(current.rgb, MIN_MAX_MIX_LIMIT) ||
                             !blend_rgb_within(selected, MIN_MAX_MIX_LIMIT)) {
            return rejected;
        }
        premultiplied = (selected / current.a) * current.a;
    } else {
        // Keep alpha squared and its reciprocal normal if the compiler reassociates Multiply.
        if mode == 3u && current.a < MULTIPLY_ALPHA_MIN {
            return rejected;
        }
        let limit = select(BLEND_STRAIGHT_LIMIT, MULTIPLY_STRAIGHT_LIMIT, mode == 3u);
        let bound = current.a * limit;
        if !blend_rgb_within(current.rgb, bound) || !blend_rgb_within(branch.rgb, bound) {
            return rejected;
        }
        let blended = blend_rgb(current.rgb / current.a, branch.rgb / branch.a, mode);
        premultiplied = blended * current.a;
    }
    if weight == 1.0 {
        return BlendResult(vec4<f32>(premultiplied, current.a), true);
    }
    let rgb = current.rgb * (1.0 - weight) + premultiplied * weight;
    return BlendResult(vec4<f32>(rgb, current.a), true);
}
