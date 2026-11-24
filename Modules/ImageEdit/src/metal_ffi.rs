use crate::{
    ffi::ImagePlan,
    gpu::{
        metal_surface::{SurfaceFrame, SurfaceProgram},
        Gpu,
    },
};
use foreign_types::ForeignTypeRef;
use std::{
    ffi::c_void,
    panic::{catch_unwind, AssertUnwindSafe},
    ptr, slice, str,
    sync::Arc,
};

extern "C" {
    fn rm_is_metal_device(object: *mut c_void) -> bool;
    fn rm_is_metal_texture(object: *mut c_void) -> bool;
}
type Release = extern "C" fn(*mut c_void);
type Current = extern "C" fn(*mut c_void, u64) -> u32;

#[repr(C)]
pub struct Surfaces {
    struct_size: u32,
    width: u32,
    height: u32,
    flags: u32,
    input: *mut c_void,
    coverage: *mut c_void,
    output: *mut c_void,
    lease_context: *mut c_void,
    release_lease: Option<Release>,
}
#[repr(C)]
pub struct CoverageV2 {
    id: *const u8,
    id_bytes: usize,
    texture: *mut c_void,
}

#[repr(C)]
pub struct SurfacesV2 {
    struct_size: u32,
    width: u32,
    height: u32,
    flags: u32,
    input: *mut c_void,
    output: *mut c_void,
    coverage: *const CoverageV2,
    coverage_count: usize,
    lease_context: *mut c_void,
    release_lease: Option<Release>,
}

pub struct MetalProgram {
    gpu: Arc<Gpu>,
    program: Arc<SurfaceProgram>,
}
struct Lease {
    context: *mut c_void,
    release: Option<Release>,
}
impl Drop for Lease {
    fn drop(&mut self) {
        if let Some(release) = self.release {
            release(self.context);
        }
    }
}
pub struct MetalFrame {
    frame: SurfaceFrame,
    _lease: Lease,
}

#[no_mangle]
pub extern "C" fn rm_image_metal_surface_abi_version() -> u32 {
    1
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_program_open_v1(
    recipe: *const ImagePlan,
    device: *mut c_void,
    out: *mut *mut MetalProgram,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    out.write(ptr::null_mut());
    catch_unwind(AssertUnwindSafe(|| {
        let Some(recipe) = recipe.as_ref() else {
            return 1;
        };
        if device.is_null() || !rm_is_metal_device(device) {
            return 1;
        }
        let wanted = metal::DeviceRef::from_ptr(device.cast());
        let Ok(gpu) = Gpu::open_for_native_device(wanted) else {
            return 2;
        };
        let Ok(program) = gpu.compile_metal_surfaces(&recipe.plan) else {
            return 2;
        };
        out.write(Box::into_raw(Box::new(MetalProgram {
            gpu: Arc::new(gpu),
            program: Arc::new(program),
        })));
        0
    }))
    .unwrap_or(4)
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_frame_bind_v1(
    program: *const MetalProgram,
    recipe: *const ImagePlan,
    surfaces: *const Surfaces,
    out: *mut *mut MetalFrame,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    out.write(ptr::null_mut());
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(program), Some(recipe)) = (program.as_ref(), recipe.as_ref()) else {
            return 1;
        };
        if recipe.plan.recipe_version() != 1
            || surfaces.is_null()
            || !surfaces.is_aligned()
            || surfaces.cast::<u32>().read() != std::mem::size_of::<Surfaces>() as u32
        {
            return 1;
        }
        let s = &*surfaces;
        if s.flags != 0
            || s.width == 0
            || s.height == 0
            || !rm_is_metal_texture(s.input)
            || !rm_is_metal_texture(s.output)
            || (s.release_lease.is_none() && !s.lease_context.is_null())
        {
            return 1;
        }
        let mask = if recipe.plan.needs_mask() {
            if !rm_is_metal_texture(s.coverage) {
                return 1;
            }
            s.coverage
        } else {
            if !s.coverage.is_null() {
                return 1;
            }
            s.input
        };
        let textures = [s.input, mask, s.output].map(|t| metal::TextureRef::from_ptr(t.cast()));
        if textures[0].width() != u64::from(s.width) || textures[0].height() != u64::from(s.height)
        {
            return 1;
        }
        let Ok(frame) = program
            .gpu
            .bind_metal_surfaces(&program.program, &recipe.plan, textures)
        else {
            return 1;
        };
        out.write(Box::into_raw(Box::new(MetalFrame {
            frame,
            _lease: Lease {
                context: s.lease_context,
                release: s.release_lease,
            },
        })));
        0
    }))
    .unwrap_or(4)
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_frame_bind_v2(
    program: *const MetalProgram,
    recipe: *const ImagePlan,
    surfaces: *const SurfacesV2,
    out: *mut *mut MetalFrame,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    out.write(ptr::null_mut());
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(program), Some(recipe)) = (program.as_ref(), recipe.as_ref()) else {
            return 1;
        };
        if surfaces.is_null()
            || !surfaces.is_aligned()
            || surfaces.cast::<u32>().read() != std::mem::size_of::<SurfacesV2>() as u32
        {
            return 1;
        }
        let s = &*surfaces;
        if s.flags != 0
            || s.width == 0
            || s.height == 0
            || (s.release_lease.is_none() && !s.lease_context.is_null())
            || s.coverage_count != recipe.plan.mask_ids().len()
            || !rm_is_metal_texture(s.input)
            || !rm_is_metal_texture(s.output)
        {
            return 1;
        }
        let input = metal::TextureRef::from_ptr(s.input.cast());
        let output = metal::TextureRef::from_ptr(s.output.cast());
        if input.width() != u64::from(s.width) || input.height() != u64::from(s.height) {
            return 1;
        }
        let mut coverage = Vec::with_capacity(s.coverage_count);
        if s.coverage_count != 0 {
            if s.coverage.is_null() || !s.coverage.is_aligned() {
                return 1;
            }
            for plane in slice::from_raw_parts(s.coverage, s.coverage_count) {
                if plane.id.is_null()
                    || !(1..=64).contains(&plane.id_bytes)
                    || !rm_is_metal_texture(plane.texture)
                {
                    return 1;
                }
                let Ok(id) = str::from_utf8(slice::from_raw_parts(plane.id, plane.id_bytes)) else {
                    return 1;
                };
                coverage.push((id, metal::TextureRef::from_ptr(plane.texture.cast())));
            }
        }
        let Ok(frame) = program.gpu.bind_named_metal_surfaces(
            &program.program,
            &recipe.plan,
            input,
            &coverage,
            output,
        ) else {
            return 1;
        };
        out.write(Box::into_raw(Box::new(MetalFrame {
            frame,
            _lease: Lease {
                context: s.lease_context,
                release: s.release_lease,
            },
        })));
        0
    }))
    .unwrap_or(4)
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_frame_render_v1(
    frame: *mut MetalFrame,
    recipe: *const ImagePlan,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(f), Some(p)) = (frame.as_mut(), recipe.as_ref()) else {
            return 1;
        };
        let allowed = || current.is_none_or(|check| check(context, revision) == 1);
        if !allowed() {
            return 5;
        }
        if f.frame.update(&p.plan).is_err() {
            return 1;
        }
        let mut obsolete = false;
        let joined = f.frame.submit_join(|| {
            if allowed() {
                Ok(())
            } else {
                obsolete = true;
                Err("obsolete revision".into())
            }
        });
        if obsolete {
            return 5;
        }
        if joined.is_err() {
            return 3;
        }
        if allowed() {
            0
        } else {
            5
        }
    }))
    .unwrap_or(4)
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_frame_close_v1(frame: *mut MetalFrame) {
    if !frame.is_null() {
        drop(Box::from_raw(frame))
    }
}
#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_program_close_v1(program: *mut MetalProgram) {
    if !program.is_null() {
        drop(Box::from_raw(program))
    }
}
