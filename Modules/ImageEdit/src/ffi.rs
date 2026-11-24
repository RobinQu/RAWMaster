use crate::{exposure_gain, render_cpu, CoveragePlane, FilterBinding, Frame, Pixel, Plan};
use std::{
    mem::size_of,
    ops::Range,
    panic::{catch_unwind, AssertUnwindSafe},
    path::Path,
    ptr, slice, str,
};

enum Backend {
    Cpu,
    #[cfg(feature = "gpu")]
    Gpu(crate::gpu::Gpu, crate::gpu::Program),
}
pub struct ImagePlan {
    pub(crate) plan: Plan,
    backend: Backend,
}

#[repr(C)]
pub struct NamedCoverage {
    id: *const u8,
    id_bytes: usize,
    values: *const f32,
    count: usize,
}

#[no_mangle]
pub extern "C" fn rm_image_abi_version() -> u32 {
    1
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_filter_binding_v1(
    family: u32,
    amount: f64,
    repair: u32,
    out: *mut FilterBinding,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    match FilterBinding::new(family, amount, repair) {
        Ok(value) => {
            out.write(value);
            0
        }
        Err(_) => 1,
    }
}
#[no_mangle]
pub extern "C" fn rm_image_exposure_gain_v1(ev: f64) -> f64 {
    exposure_gain(ev)
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_kernel_source_v1(kind: u32, length: *mut usize) -> *const u8 {
    if length.is_null() {
        return ptr::null();
    }
    let source: &[u8] = match kind {
        1 => include_bytes!("../shaders/photo_filter.ci.metal"),
        2 => include_bytes!("../shaders/exposure.ci.metal"),
        3 => include_bytes!(concat!(env!("OUT_DIR"), "/mask.ci.metal")),
        4 => include_bytes!(concat!(env!("OUT_DIR"), "/mask_analytic.ci.metal")),
        5 => include_bytes!("../shaders/color_grain_lattice.ci.metal"),
        _ => {
            length.write(0);
            return ptr::null();
        }
    };
    length.write(source.len());
    source.as_ptr()
}
unsafe fn utf8<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() || len > isize::MAX as usize {
        return None;
    }
    str::from_utf8(slice::from_raw_parts(ptr, len)).ok()
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_plan_open_v1(
    json: *const u8,
    n: usize,
    resource_root: *const u8,
    path_len: usize,
    backend: u32,
    out: *mut *mut ImagePlan,
) -> i32 {
    open_plan(json, n, resource_root, path_len, backend, out, 1)
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_plan_open_v2(
    json: *const u8,
    n: usize,
    resource_root: *const u8,
    path_len: usize,
    backend: u32,
    out: *mut *mut ImagePlan,
) -> i32 {
    open_plan(json, n, resource_root, path_len, backend, out, 2)
}

unsafe fn open_plan(
    json: *const u8,
    n: usize,
    resource_root: *const u8,
    path_len: usize,
    backend: u32,
    out: *mut *mut ImagePlan,
    maximum_version: u32,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    out.write(ptr::null_mut());
    catch_unwind(AssertUnwindSafe(|| {
        if n == 0 || n > 128 * 1024 {
            return 1;
        }
        let Some(recipe) = utf8(json, n) else {
            return 1;
        };
        let root = if path_len == 0 {
            None
        } else {
            let Some(path) = utf8(resource_root, path_len) else {
                return 1;
            };
            Some(Path::new(path))
        };
        let Ok(plan) = Plan::parse_with_version_limit(recipe, root, maximum_version) else {
            return 1;
        };
        let backend = match backend {
            0 => Backend::Cpu,
            #[cfg(feature = "gpu")]
            1 => {
                let Ok(gpu) = crate::gpu::Gpu::open() else {
                    return 2;
                };
                let Ok(program) = gpu.compile(&plan, crate::gpu::Mode::Fused) else {
                    return 2;
                };
                Backend::Gpu(gpu, program)
            }
            _ => return 2,
        };
        out.write(Box::into_raw(Box::new(ImagePlan { plan, backend })));
        0
    }))
    .unwrap_or(4)
}

unsafe fn render_plan(engine: &ImagePlan, frame: &Frame, out: *mut f32) -> i32 {
    let result = match &engine.backend {
        Backend::Cpu => render_cpu(&engine.plan, frame),
        #[cfg(feature = "gpu")]
        Backend::Gpu(g, p) => g
            .render_bounded(p, &engine.plan, frame, 256 << 20)
            .map(|(pixels, _)| pixels),
    };
    match result {
        Ok(pixels) => {
            ptr::copy_nonoverlapping(pixels.as_ptr(), out.cast::<Pixel>(), pixels.len());
            0
        }
        Err(_) => 3,
    }
}

fn extent_count(width: u32, height: u32) -> Option<usize> {
    let n = width.checked_mul(height)? as usize;
    (n > 0 && n <= isize::MAX as usize / size_of::<Pixel>()).then_some(n)
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_plan_render_v1(
    handle: *mut ImagePlan,
    width: u32,
    height: u32,
    rgba: *const f32,
    rgba_count: usize,
    mask: *const f32,
    mask_count: usize,
    out: *mut f32,
    out_count: usize,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = handle.as_ref() else {
            return 1;
        };
        let Some(n) = extent_count(width, height) else {
            return 1;
        };
        if engine.plan.recipe_version() != 1
            || rgba.is_null()
            || out.is_null()
            || rgba_count != 4 * n
            || out_count != 4 * n
            || (mask_count != 0 && (mask_count != n || mask.is_null()))
        {
            return 1;
        }
        if engine.plan.needs_mask() && mask_count != n {
            return 1;
        }
        let coverage = if mask_count == 0 {
            &[]
        } else {
            slice::from_raw_parts(mask, mask_count)
        };
        let Ok(frame) = Frame::with_transport(
            width,
            height,
            slice::from_raw_parts(rgba.cast::<Pixel>(), n),
            coverage,
            engine.plan.accepts_raw_transport(),
        ) else {
            return 1;
        };
        render_plan(engine, &frame, out)
    }))
    .unwrap_or(4)
}

fn buffer_range<T>(pointer: *const T, count: usize) -> Option<Range<usize>> {
    let bytes = count.checked_mul(size_of::<T>())?;
    if pointer.is_null() || !pointer.is_aligned() || bytes > isize::MAX as usize {
        return None;
    }
    let start = pointer as usize;
    Some(start..start.checked_add(bytes)?)
}

fn overlaps(a: &Range<usize>, b: &Range<usize>) -> bool {
    a.start < b.end && b.start < a.end
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_plan_render_v2(
    handle: *mut ImagePlan,
    width: u32,
    height: u32,
    rgba: *const f32,
    rgba_count: usize,
    coverage: *const NamedCoverage,
    coverage_count: usize,
    out: *mut f32,
    out_count: usize,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(engine), Some(n)) = (handle.as_ref(), extent_count(width, height)) else {
            return 1;
        };
        if rgba_count != 4 * n
            || out_count != 4 * n
            || coverage_count != engine.plan.mask_ids().len()
        {
            return 1;
        }
        let (Some(source_range), Some(out_range)) =
            (buffer_range(rgba, rgba_count), buffer_range(out, out_count))
        else {
            return 1;
        };
        if overlaps(&source_range, &out_range) {
            return 1;
        }
        let entries = if coverage_count == 0 {
            &[]
        } else {
            let Some(descriptor_range) = buffer_range(coverage, coverage_count) else {
                return 1;
            };
            if overlaps(&descriptor_range, &out_range) {
                return 1;
            }
            slice::from_raw_parts(coverage, coverage_count)
        };
        let mut planes = Vec::with_capacity(coverage_count);
        for entry in entries {
            if entry.count != n || !(1..=64).contains(&entry.id_bytes) {
                return 1;
            }
            let (Some(id_range), Some(value_range)) = (
                buffer_range(entry.id, entry.id_bytes),
                buffer_range(entry.values, entry.count),
            ) else {
                return 1;
            };
            if overlaps(&id_range, &out_range) || overlaps(&value_range, &out_range) {
                return 1;
            }
            let Some(id) = utf8(entry.id, entry.id_bytes) else {
                return 1;
            };
            planes.push(CoveragePlane {
                id,
                values: slice::from_raw_parts(entry.values, entry.count),
            });
        }
        if engine
            .plan
            .order_masks(planes.iter().map(|plane| (plane.id, ())))
            .is_err()
        {
            return 1;
        }
        let Ok(frame) = Frame::with_named_coverage(
            width,
            height,
            slice::from_raw_parts(rgba.cast::<Pixel>(), n),
            &planes,
            engine.plan.accepts_raw_transport(),
        ) else {
            return 1;
        };
        render_plan(engine, &frame, out)
    }))
    .unwrap_or(4)
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_plan_close_v1(plan: *mut ImagePlan) {
    if !plan.is_null() {
        drop(Box::from_raw(plan));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn version_sources_and_rejected_binding_are_stable() {
        assert_eq!(rm_image_abi_version(), 1);
        assert_eq!(rm_image_exposure_gain_v1(-1.0), 0.5);
        assert!(rm_image_exposure_gain_v1(f64::NAN).is_nan());
        assert!(rm_image_exposure_gain_v1(2048.0).is_nan());
        let mut binding = FilterBinding::new(0, 37.5, 0).unwrap();
        let before = binding;
        unsafe {
            assert_eq!(rm_image_filter_binding_v1(0, 101.0, 0, &mut binding), 1);
            assert_eq!(binding, before);
            assert_eq!(rm_image_filter_binding_v1(2, 100.0, 1, ptr::null_mut()), 1);
            for kind in 1..=5 {
                let mut length = 0;
                let ptr = rm_image_kernel_source_v1(kind, &mut length);
                assert_eq!(ptr, rm_image_kernel_source_v1(kind, &mut length));
                let text = utf8(ptr, length).unwrap();
                assert!(!text.is_empty());
                assert!(text
                    .lines()
                    .all(|line| !line.trim_start().starts_with("// RM_")));
            }
            let mut n = 4;
            assert!(rm_image_kernel_source_v1(8, &mut n).is_null());
            assert_eq!(n, 0);
        }
    }
    #[test]
    fn caller_owns_only_successful_plans_and_pixels() {
        let recipe=br#"{"version":1,"working":"extended-linear-srgb-premul-f32","output":"x","nodes":[{"id":"s","op":"source"},{"id":"x","op":"exposure","image":"s","ev":1}]}"#;
        let mut plan = ptr::null_mut();
        unsafe {
            assert_eq!(
                rm_image_plan_open_v1(b"?".as_ptr(), 1, ptr::null(), 0, 0, &mut plan),
                1
            );
            assert!(plan.is_null());
            assert_eq!(
                rm_image_plan_open_v1(recipe.as_ptr(), recipe.len(), ptr::null(), 0, 12, &mut plan),
                2
            );
            assert!(plan.is_null());
            assert_eq!(
                rm_image_plan_open_v1(recipe.as_ptr(), recipe.len(), ptr::null(), 0, 0, &mut plan),
                0
            );
            let src = [-0.25, 0.1, 1.5, 0.5];
            let mut dst = [42.0; 4];
            assert_eq!(
                rm_image_plan_render_v1(
                    plan,
                    1,
                    1,
                    src.as_ptr(),
                    3,
                    ptr::null(),
                    0,
                    dst.as_mut_ptr(),
                    4
                ),
                1
            );
            assert_eq!(dst, [42.0; 4]);
            assert_eq!(
                rm_image_plan_render_v1(
                    plan,
                    1,
                    1,
                    [f32::MAX, 0.0, 0.4, 1.0].as_ptr(),
                    4,
                    ptr::null(),
                    0,
                    dst.as_mut_ptr(),
                    4
                ),
                3
            );
            assert_eq!(dst, [42.0; 4]);
            assert_eq!(
                rm_image_plan_render_v1(
                    plan,
                    1,
                    1,
                    src.as_ptr(),
                    4,
                    ptr::null(),
                    0,
                    dst.as_mut_ptr(),
                    4
                ),
                0
            );
            assert_eq!(dst, [-0.5, 0.2, 3.0, 0.5]);
            rm_image_plan_close_v1(plan);
            rm_image_plan_close_v1(ptr::null_mut());
        }
    }

    #[test]
    fn named_bindings_are_exact_and_failure_leaves_destination_intact() {
        let film_recipe = r#"{"version":2,"working":"extended-linear-srgb-premul-f32","output":"film","nodes":[
          {"id":"s","op":"source"},{"id":"film","op":"photo_filter","image":"s","look":"vivid","amount":37.5}]}"#;
        assert_eq!(
            Plan::parse_with_version_limit(film_recipe, None, 1)
                .err()
                .as_deref(),
            Some("unsupported recipe version or working space")
        );
        let recipe =
            br#"{"version":2,"working":"extended-linear-srgb-premul-f32","output":"y","nodes":[
          {"id":"y","op":"masked_exposure","image":"x","mask":"o\u0301","ev":-1},
          {"id":"s","op":"source"},{"id":"\u00f3","op":"mask"},
          {"id":"x","op":"masked_exposure","image":"s","mask":"\u00f3","ev":1},
          {"id":"o\u0301","op":"mask"}]}"#;
        let mut plan = ptr::null_mut();
        let mut source = [-0.25, 0.125, 1.5, 1.0, -0.25, 0.125, 1.5, 1.0];
        let mut output = [42.0; 8];
        let up = [1.0, 0.0];
        let down = [0.0, 1.0];
        let composed = "\u{00f3}";
        let decomposed = "o\u{0301}";
        let descriptor = |id: &str, values: &[f32]| NamedCoverage {
            id: id.as_ptr(),
            id_bytes: id.len(),
            values: values.as_ptr(),
            count: values.len(),
        };
        unsafe {
            assert_eq!(
                rm_image_plan_open_v1(recipe.as_ptr(), recipe.len(), ptr::null(), 0, 0, &mut plan),
                1
            );
            assert!(plan.is_null());
            assert_eq!(
                rm_image_plan_open_v2(recipe.as_ptr(), recipe.len(), ptr::null(), 0, 0, &mut plan),
                0
            );
            let named = [descriptor(decomposed, &down), descriptor(composed, &up)];
            let duplicate = [descriptor(composed, &down), descriptor(composed, &up)];
            let unknown = [descriptor(decomposed, &down), descriptor("missing", &up)];
            let invalid = [0.0, f32::NAN];
            let bad_samples = [descriptor(decomposed, &invalid), descriptor(composed, &up)];
            for bindings in [&named[..1], &duplicate[..], &unknown[..], &bad_samples[..]] {
                assert_eq!(
                    rm_image_plan_render_v2(
                        plan,
                        2,
                        1,
                        source.as_ptr(),
                        source.len(),
                        bindings.as_ptr(),
                        bindings.len(),
                        output.as_mut_ptr(),
                        output.len()
                    ),
                    1
                );
                assert_eq!(output, [42.0; 8]);
            }
            assert_eq!(
                rm_image_plan_render_v1(
                    plan,
                    2,
                    1,
                    source.as_ptr(),
                    source.len(),
                    up.as_ptr(),
                    up.len(),
                    output.as_mut_ptr(),
                    output.len()
                ),
                1
            );
            let input = source;
            assert_eq!(
                rm_image_plan_render_v2(
                    plan,
                    2,
                    1,
                    source.as_ptr(),
                    source.len(),
                    named.as_ptr(),
                    named.len(),
                    source.as_mut_ptr(),
                    source.len()
                ),
                1
            );
            assert_eq!(source, input);
            assert_eq!(
                rm_image_plan_render_v2(
                    plan,
                    2,
                    1,
                    source.as_ptr(),
                    source.len(),
                    named.as_ptr(),
                    named.len(),
                    output.as_mut_ptr(),
                    output.len()
                ),
                0
            );
            assert_eq!(output, [-0.5, 0.25, 3.0, 1.0, -0.125, 0.0625, 0.75, 1.0]);
            rm_image_plan_close_v1(plan);
        }
    }
}
