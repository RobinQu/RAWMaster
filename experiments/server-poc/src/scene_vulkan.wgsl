// WGSL port of the 039 scene executor's color and analytic-coverage kernels.
// Inputs and outputs are AP1 premultiplied F32; coverage is R32F in [0,1].

struct Params {
  scalars: vec4<f32>,
  geometry: vec4<u32>,
  kind: u32,
  parameter: u32,
  pad0: u32,
  pad1: u32,
};

const AP1_Y = vec3<f32>(0.2722287168, 0.6740817658, 0.0536895174);

fn finite1(v: f32) -> bool {
  return v == v && abs(v) < 3.0e38;
}
fn finite4(v: vec4<f32>) -> bool {
  return finite1(v.x) && finite1(v.y) && finite1(v.z) && finite1(v.w);
}
fn finite3(v: vec3<f32>) -> bool {
  return finite1(v.x) && finite1(v.y) && finite1(v.z);
}

fn exposure_delta(ev: f32, count: u32) -> f32 {
  if (count == 0u) { return 0.0; }
  let first = ccurve[0];
  if (ev <= first.x) { return first.y - first.x; }
  for (var i: u32 = 1u; i < count; i = i + 1u) {
    let a = ccurve[i - 1u];
    let b = ccurve[i];
    if (ev <= b.x) {
      return mix(a.y - a.x, b.y - b.x, (ev - a.x) / (b.x - a.x));
    }
  }
  let last = ccurve[count - 1u];
  return last.y - last.x;
}

fn soft_light(b: vec3<f32>, s: vec3<f32>) -> vec3<f32> {
  let poly = ((16.0 * b - 12.0) * b + 4.0) * b;
  let d = select(sqrt(max(b, vec3<f32>(0.0))), poly, b <= vec3<f32>(0.25));
  return select(b + (2.0 * s - 1.0) * (d - b),
                b - (1.0 - 2.0 * s) * b * (1.0 - b),
                s <= vec3<f32>(0.5));
}

fn blend(b: vec3<f32>, s: vec3<f32>, mode: u32) -> vec3<f32> {
  switch (mode) {
    case 0u: { return s; }
    case 1u: { return b + s; }
    case 2u: { return b - s; }
    case 3u: { return b * s; }
    case 8u: { return max(b, s); }
    case 9u: { return min(b, s); }
    case 10u: { return abs(b - s); }
    case 11u: { return s + vec3<f32>(dot(b, AP1_Y) - dot(s, AP1_Y)); }
    case 12u: { return b + vec3<f32>(dot(s, AP1_Y) - dot(b, AP1_Y)); }
    default: {}
  }
  let x = clamp(b, vec3<f32>(0.0), vec3<f32>(1.0));
  let y = clamp(s, vec3<f32>(0.0), vec3<f32>(1.0));
  let screen = vec3<f32>(1.0) - 2.0 * (vec3<f32>(1.0) - x) * (vec3<f32>(1.0) - y);
  let multiply = 2.0 * x * y;
  var z: vec3<f32>;
  if (mode == 4u) {
    z = x + y - x * y;
  } else if (mode == 5u) {
    z = select(screen, multiply, x <= vec3<f32>(0.5));
  } else if (mode == 6u) {
    z = soft_light(x, y);
  } else {
    z = select(screen, multiply, y <= vec3<f32>(0.5));
  }
  return z + (b - x) + (s - y);
}

@group(0) @binding(0) var<uniform> cp: Params;
@group(0) @binding(1) var<storage, read> ccurve: array<vec2<f32>>;
@group(0) @binding(2) var cinput: texture_2d<f32>;
@group(0) @binding(3) var cmask: texture_2d<f32>;
@group(0) @binding(4) var coutput: texture_storage_2d<rgba32float, write>;

@compute @workgroup_size(8, 8, 1)
fn color_corrector(@builtin(global_invocation_id) gid: vec3<u32>) {
  let size = textureDimensions(coutput);
  if (gid.x >= size.x || gid.y >= size.y) { return; }
  let coord = vec2<i32>(i32(gid.x), i32(gid.y));
  let a = textureLoad(cinput, coord, 0);
  if (!finite4(a) || a.a < 0.0 || a.a > 1.0) { return; }
  if (a.a == 0.0) {
    textureStore(coutput, coord, vec4<f32>(0.0));
    return;
  }
  let mask = textureLoad(cmask, coord, 0).r;
  let w = cp.scalars.y * select(mask, 1.0, cp.scalars.w == 0.0);
  let gain0 = cp.scalars.x;
  let luma = dot(a.rgb, AP1_Y);
  var gain = gain0;
  if (cp.scalars.z > 0.0 && luma > 0.0) {
    let delta = exposure_delta(log2(luma) - log2(a.a) + log2(gain0), u32(cp.scalars.z));
    gain = gain * exp2(delta);
  }
  var rgb = a.rgb;
  if (w != 0.0) {
    rgb = a.rgb * mix(vec3<f32>(1.0), vec3<f32>(gain), vec3<f32>(w));
  }
  if (!finite3(rgb)) { return; }
  textureStore(coutput, coord, vec4<f32>(rgb, a.a));
}

@group(0) @binding(0) var<uniform> mp: Params;
@group(0) @binding(1) var<storage, read> mcurve: array<vec2<f32>>;
@group(0) @binding(2) var minput: texture_2d<f32>;
@group(0) @binding(3) var mother: texture_2d<f32>;
@group(0) @binding(4) var mbase: texture_2d<f32>;
@group(0) @binding(5) var moutput: texture_storage_2d<rgba32float, write>;

@compute @workgroup_size(8, 8, 1)
fn color_mix(@builtin(global_invocation_id) gid: vec3<u32>) {
  let size = textureDimensions(moutput);
  if (gid.x >= size.x || gid.y >= size.y) { return; }
  let coord = vec2<i32>(i32(gid.x), i32(gid.y));
  let a = textureLoad(minput, coord, 0);
  let b = textureLoad(mother, coord, 0);
  if (!finite4(a) || a.a < 0.0 || a.a > 1.0) { return; }
  if (!finite4(b) || a.a != b.a) { return; }
  var rgb: vec3<f32>;
  if (mp.kind == 2u) {
    let base = textureLoad(mbase, coord, 0);
    rgb = a.rgb + mp.scalars.x * (b.rgb - base.rgb);
  } else if (mp.scalars.y == 0.0) {
    rgb = mix(a.rgb, b.rgb, mp.scalars.x);
  } else {
    rgb = mix(a.rgb, blend(a.rgb / a.a, b.rgb / b.a, u32(mp.scalars.y)) * a.a, mp.scalars.x);
  }
  if (!finite3(rgb)) { return; }
  textureStore(moutput, coord, vec4<f32>(rgb, a.a));
}

@group(0) @binding(0) var<uniform> lp: Params;
@group(0) @binding(1) var loutput: texture_storage_2d<r32float, write>;

@compute @workgroup_size(8, 8, 1)
fn coverage_linear(@builtin(global_invocation_id) gid: vec3<u32>) {
  let size = textureDimensions(loutput);
  if (gid.x >= size.x || gid.y >= size.y) { return; }
  let coord = vec2<i32>(i32(gid.x), i32(gid.y));
  let q = (vec2<f32>(f32(lp.geometry.x + gid.x), f32(lp.geometry.y + gid.y)) + vec2<f32>(0.5))
        / vec2<f32>(f32(lp.geometry.z), f32(lp.geometry.w));
  let axis = lp.scalars.zw - lp.scalars.xy;
  let c = clamp(dot(q - lp.scalars.xy, axis) / dot(axis, axis), 0.0, 1.0);
  textureStore(loutput, coord, vec4<f32>(c, 0.0, 0.0, 1.0));
}

@group(0) @binding(0) var<uniform> rp: Params;
@group(0) @binding(1) var routput: texture_storage_2d<r32float, write>;

@compute @workgroup_size(8, 8, 1)
fn coverage_radial(@builtin(global_invocation_id) gid: vec3<u32>) {
  let size = textureDimensions(routput);
  if (gid.x >= size.x || gid.y >= size.y) { return; }
  let coord = vec2<i32>(i32(gid.x), i32(gid.y));
  let q = (vec2<f32>(f32(rp.geometry.x + gid.x), f32(rp.geometry.y + gid.y)) + vec2<f32>(0.5))
        / vec2<f32>(f32(rp.geometry.z), f32(rp.geometry.w));
  let f = bitcast<f32>(rp.parameter);
  let r = length((q - rp.scalars.xy) / rp.scalars.zw);
  var c: f32;
  if (f == 0.0) {
    c = select(0.0, 1.0, r <= 1.0);
  } else {
    c = 1.0 - smoothstep(1.0 - f, 1.0, r);
  }
  textureStore(routput, coord, vec4<f32>(clamp(c, 0.0, 1.0), 0.0, 0.0, 1.0));
}

@group(0) @binding(0) var<uniform> xp: Params;
@group(0) @binding(1) var xinput: texture_2d<f32>;
@group(0) @binding(2) var xother: texture_2d<f32>;
@group(0) @binding(3) var xoutput: texture_storage_2d<r32float, write>;

@compute @workgroup_size(8, 8, 1)
fn coverage_combine(@builtin(global_invocation_id) gid: vec3<u32>) {
  let size = textureDimensions(xoutput);
  if (gid.x >= size.x || gid.y >= size.y) { return; }
  let coord = vec2<i32>(i32(gid.x), i32(gid.y));
  let a = textureLoad(xinput, coord, 0).r;
  let b = textureLoad(xother, coord, 0).r;
  var c: f32;
  if (xp.scalars.x == 0.0) {
    c = a + b * (1.0 - a);
  } else if (xp.scalars.x == 1.0) {
    c = a * (1.0 - b);
  } else {
    c = a * b;
  }
  textureStore(xoutput, coord, vec4<f32>(clamp(c, 0.0, 1.0), 0.0, 0.0, 1.0));
}

@group(0) @binding(0) var<uniform> ap: Params;
@group(0) @binding(1) var ainput: texture_2d<f32>;
@group(0) @binding(2) var aoutput: texture_storage_2d<r32float, write>;

@compute @workgroup_size(8, 8, 1)
fn coverage_adjust(@builtin(global_invocation_id) gid: vec3<u32>) {
  let size = textureDimensions(aoutput);
  if (gid.x >= size.x || gid.y >= size.y) { return; }
  let coord = vec2<i32>(i32(gid.x), i32(gid.y));
  let a = textureLoad(ainput, coord, 0).r;
  let c = select(a, 1.0 - a, ap.scalars.y == 1.0) * ap.scalars.x;
  textureStore(aoutput, coord, vec4<f32>(clamp(c, 0.0, 1.0), 0.0, 0.0, 1.0));
}
