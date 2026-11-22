use crate::{render_cpu, Frame, Pixel, Plan};
use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    ptr, slice, str,
};

enum Backend {
    Cpu,
    #[cfg(feature = "gpu")]
    Gpu(crate::gpu::Gpu, crate::gpu::Program),
}
pub struct RmiPlan {
    plan: Plan,
    backend: Backend,
}

#[no_mangle]
pub unsafe extern "C" fn rmi_open_v1(
    json: *const u8,
    bytes: usize,
    backend: u32,
    out: *mut *mut RmiPlan,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    *out = ptr::null_mut();
    catch_unwind(AssertUnwindSafe(|| {
        if json.is_null() || bytes == 0 || bytes > 128 * 1024 {
            return 1;
        }
        let Ok(text) = str::from_utf8(slice::from_raw_parts(json, bytes)) else {
            return 1;
        };
        let Ok(plan) = Plan::parse(text) else {
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
        *out = Box::into_raw(Box::new(RmiPlan { plan, backend }));
        0
    }))
    .unwrap_or(4)
}

#[no_mangle]
pub unsafe extern "C" fn rmi_render_v1(
    handle: *mut RmiPlan,
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
        let Some(n) = width
            .checked_mul(height)
            .filter(|n| *n > 0)
            .map(|n| n as usize)
        else {
            return 1;
        };
        if n > isize::MAX as usize / 16
            || rgba.is_null()
            || mask.is_null()
            || out.is_null()
            || rgba_count != 4 * n
            || mask_count != n
            || out_count != 4 * n
        {
            return 1;
        }
        let Ok(frame) = Frame::new(
            width,
            height,
            slice::from_raw_parts(rgba.cast::<Pixel>(), n),
            slice::from_raw_parts(mask, n),
        ) else {
            return 1;
        };
        let result = match &engine.backend {
            Backend::Cpu => render_cpu(&engine.plan, &frame),
            #[cfg(feature = "gpu")]
            Backend::Gpu(gpu, program) => gpu
                .render_bounded(program, &engine.plan, &frame, 256 << 20)
                .map(|(pixels, _)| pixels),
        };
        match result {
            Ok(pixels) => {
                ptr::copy_nonoverlapping(pixels.as_ptr(), out.cast::<Pixel>(), n);
                0
            }
            Err(_) => 3,
        }
    }))
    .unwrap_or(4)
}

#[no_mangle]
pub unsafe extern "C" fn rmi_close_v1(handle: *mut RmiPlan) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caller_buffers_and_handle_have_explicit_failure_semantics() {
        unsafe {
            let mut plan = ptr::null_mut();
            assert_eq!(rmi_open_v1(b"!".as_ptr(), 1, 0, &mut plan), 1);
            assert!(plan.is_null());
            assert_eq!(
                rmi_open_v1(crate::EXAMPLE.as_ptr(), crate::EXAMPLE.len(), 19, &mut plan),
                2
            );
            assert!(plan.is_null());
            assert_eq!(
                rmi_open_v1(crate::EXAMPLE.as_ptr(), crate::EXAMPLE.len(), 0, &mut plan),
                0
            );
            let src = [-0.1, 2.0, 0.3, 1.0];
            let mask = [0.5];
            let mut dst = [42.0; 4];
            assert_eq!(
                rmi_render_v1(
                    plan,
                    1,
                    1,
                    src.as_ptr(),
                    3,
                    mask.as_ptr(),
                    1,
                    dst.as_mut_ptr(),
                    4
                ),
                1
            );
            assert_eq!(dst, [42.0; 4]);
            assert_eq!(
                rmi_render_v1(
                    plan,
                    1,
                    1,
                    src.as_ptr(),
                    4,
                    mask.as_ptr(),
                    1,
                    dst.as_mut_ptr(),
                    4
                ),
                0
            );
            assert!(dst[0] < 0.0 && dst[1] > 1.0 && dst[3] == 1.0);
            rmi_close_v1(plan);
            rmi_close_v1(ptr::null_mut());
        }
    }
}
