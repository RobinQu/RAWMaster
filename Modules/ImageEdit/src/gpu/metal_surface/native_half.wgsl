struct HalfParams { size: vec2<u32>, band_y: u32, mode: u32, rows: array<vec4<f32>> }
@group(0) @binding(0) var half_source: texture_2d<f32>;
@group(0) @binding(1) var half_target: texture_storage_2d<rgba32float, write>;
@group(0) @binding(2) var<storage,read_write> half_receipts: array<u32>;
@group(0) @binding(3) var<storage,read> params: HalfParams;
@group(0) @binding(4) var linear_sampler: sampler;
// Shared point-operator source also declares filter helpers; this port admits no atlas operator.
@group(0) @binding(5) var<storage,read> atlas: array<vec4<f32>>;
var<workgroup> visits: atomic<u32>;
fn opaque_finite(v: vec4<f32>) -> bool {
    let exponents = vec4<u32>(0x7f800000u);
    return v.a == 1.0 && all((bitcast<vec4<u32>>(v) & exponents) != exponents);
}
fn start_receipt(lane: u32) {
    if lane == 0u { atomicStore(&visits, 0u); }
    workgroupBarrier();
}
fn finish_receipt(lane: u32, slot: u32, count: u32) {
    accumulate_receipt(lane, count);
    workgroupBarrier();
    if lane == 0u { half_receipts[slot] = 0xa5000000u | atomicLoad(&visits); }
}
