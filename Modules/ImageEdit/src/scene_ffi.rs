//! C ABI for the scene-linear AP1 graph executor (macOS Metal only).

use crate::gpu::ap1_scene::metal_texture::{admits_source, MetalProgram, MetalReceipt};
use crate::scene::{
    metal_exec::{Receipt, SceneProgram},
    SceneError, ViewSpec,
};
use foreign_types::{ForeignType, ForeignTypeRef};
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;
use std::sync::Arc;
use std::time::Instant;

type Current = extern "C" fn(*mut c_void, u64) -> u32;

#[no_mangle]
pub extern "C" fn rm_scene_abi_version() -> u32 {
    2
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_open_v1(
    graph: *const u8,
    graph_bytes: usize,
    device: *mut c_void,
    out: *mut *mut SceneProgram,
) -> i32 {
    open(graph, graph_bytes, device, out, None)
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_open_frozen_delivery_v1(
    graph: *const u8,
    graph_bytes: usize,
    device: *mut c_void,
    library_api_calls: *mut u32,
    out: *mut *mut SceneProgram,
) -> i32 {
    if !library_api_calls.is_null() {
        library_api_calls.write(0);
    }
    open(graph, graph_bytes, device, out, Some(library_api_calls))
}

unsafe fn open(
    graph: *const u8,
    graph_bytes: usize,
    device: *mut c_void,
    out: *mut *mut SceneProgram,
    frozen_library_api_calls: Option<*mut u32>,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    out.write(std::ptr::null_mut());
    catch_unwind(AssertUnwindSafe(|| {
        if graph.is_null() || graph_bytes == 0 || device.is_null() {
            return 1;
        }
        let document = slice::from_raw_parts(graph, graph_bytes);
        let result = if let Some(library_api_calls) = frozen_library_api_calls {
            let mut ignored_calls = 0;
            let calls = library_api_calls.as_mut().unwrap_or(&mut ignored_calls);
            SceneProgram::open_frozen_delivery(device, document, calls)
        } else {
            SceneProgram::open(device, document)
        };
        let program = match result {
            Ok(program) => program,
            Err(SceneError::Invalid(_) | SceneError::Unsupported(_)) => return 1,
            Err(crate::scene::SceneError::Backend(_)) => return 2,
            Err(crate::scene::SceneError::Render(_)) | Err(crate::scene::SceneError::Budget(_)) => {
                return 3
            }
        };
        out.write(Box::into_raw(Box::new(program)));
        0
    }))
    .unwrap_or(4)
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_update_v1(
    program: *const SceneProgram,
    graph: *const u8,
    graph_bytes: usize,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(program) = program.as_ref() else {
            return 1;
        };
        if graph.is_null() || graph_bytes == 0 {
            return 1;
        }
        let document = slice::from_raw_parts(graph, graph_bytes);
        match program.update(document) {
            Ok(()) => 0,
            Err(SceneError::Invalid(_) | SceneError::Unsupported(_)) => 1,
            Err(crate::scene::SceneError::Backend(_)) => 2,
            Err(crate::scene::SceneError::Budget(_)) | Err(crate::scene::SceneError::Render(_)) => {
                3
            }
        }
    }))
    .unwrap_or(4)
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_render_v1(
    program: *const SceneProgram,
    input: *mut c_void,
    output: *mut c_void,
    view_json: *const u8,
    view_bytes: usize,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    render(
        program,
        input,
        output,
        std::ptr::null_mut(),
        view_json,
        view_bytes,
        std::ptr::null(),
        std::ptr::null(),
        0,
        revision,
        current,
        context,
    )
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_render_coverages_v1(
    program: *const SceneProgram,
    input: *mut c_void,
    output: *mut c_void,
    view_json: *const u8,
    view_bytes: usize,
    coverage_ids: *const *const c_char,
    coverage_textures: *const *mut c_void,
    coverage_count: usize,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    render(
        program,
        input,
        output,
        std::ptr::null_mut(),
        view_json,
        view_bytes,
        coverage_ids,
        coverage_textures,
        coverage_count,
        revision,
        current,
        context,
    )
}

/// Returns a +1 Metal texture. A single-tile identity plan can return the input texture.
#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_render_surface_v1(
    program: *const SceneProgram,
    input: *mut c_void,
    retained_output: *mut *mut c_void,
    view_json: *const u8,
    view_bytes: usize,
    coverage_ids: *const *const c_char,
    coverage_textures: *const *mut c_void,
    coverage_count: usize,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    if retained_output.is_null() {
        return 1;
    }
    retained_output.write(std::ptr::null_mut());
    render(
        program,
        input,
        std::ptr::null_mut(),
        retained_output,
        view_json,
        view_bytes,
        coverage_ids,
        coverage_textures,
        coverage_count,
        revision,
        current,
        context,
    )
}

unsafe fn render(
    program: *const SceneProgram,
    input: *mut c_void,
    output: *mut c_void,
    retained_output: *mut *mut c_void,
    view_json: *const u8,
    view_bytes: usize,
    coverage_ids: *const *const c_char,
    coverage_textures: *const *mut c_void,
    coverage_count: usize,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(program) = program.as_ref() else {
            return 1;
        };
        if input.is_null() || (output.is_null() && retained_output.is_null()) {
            return 1;
        }
        let view: ViewSpec = if view_json.is_null() || view_bytes == 0 {
            ViewSpec::default()
        } else {
            match serde_json::from_slice(slice::from_raw_parts(view_json, view_bytes)) {
                Ok(view) => view,
                Err(_) => return 1,
            }
        };
        let check = || {
            current
                .map(|callback| callback(context, revision) != 0)
                .unwrap_or(true)
        };
        let input = metal::TextureRef::from_ptr(input.cast());
        let output = (!output.is_null()).then(|| metal::TextureRef::from_ptr(output.cast()));
        let mut coverages: HashMap<String, Arc<metal::Texture>> = HashMap::new();
        if coverage_count > 0 {
            if coverage_ids.is_null() || coverage_textures.is_null() {
                return 1;
            }
            for index in 0..coverage_count {
                let id = *coverage_ids.add(index);
                let texture = *coverage_textures.add(index);
                if id.is_null() || texture.is_null() {
                    return 1;
                }
                let name = match CStr::from_ptr(id).to_str() {
                    Ok(name) if !name.is_empty() => name.to_string(),
                    _ => return 1,
                };
                let texture = metal::TextureRef::from_ptr(texture.cast()).to_owned();
                coverages.insert(name, Arc::new(texture));
            }
        }
        match program.render(input, output, &view, &coverages, check) {
            Ok(result) => {
                if !retained_output.is_null() {
                    retained_output.write(result.as_ref().to_owned().into_ptr().cast());
                }
                0
            }
            Err(SceneError::Invalid(_) | SceneError::Unsupported(_)) => 1,
            Err(crate::scene::SceneError::Backend(_)) => 2,
            Err(crate::scene::SceneError::Render(message)) if message.contains("stale") => 5,
            Err(crate::scene::SceneError::Render(_)) => 3,
            Err(crate::scene::SceneError::Budget(_)) => 6,
        }
    }))
    .unwrap_or(4)
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_receipt_v1(
    program: *const SceneProgram,
    out: *mut Receipt,
) -> i32 {
    let Some(program) = program.as_ref() else {
        return 1;
    };
    if out.is_null() {
        return 1;
    }
    out.write(program.receipt());
    0
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_close_v1(program: *mut SceneProgram) {
    if !program.is_null() {
        drop(Box::from_raw(program));
    }
}

extern "C" {
    fn rm_is_metal_device(object: *mut c_void) -> bool;
}

fn ap1_status(error: SceneError) -> i32 {
    match error {
        SceneError::Invalid(_) => 1,
        SceneError::Backend(_) => 2,
        SceneError::Render(_) => 3,
        SceneError::Budget(_) => 6,
        SceneError::Unsupported(_) => 7,
    }
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_ap1_metal_open_v1(
    metal_device: *mut c_void,
    out: *mut *mut MetalProgram,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    out.write(std::ptr::null_mut());
    catch_unwind(AssertUnwindSafe(|| {
        if metal_device.is_null() || !rm_is_metal_device(metal_device) {
            return 1;
        }
        let device = metal::DeviceRef::from_ptr(metal_device.cast());
        match MetalProgram::open(device) {
            Ok(program) => {
                out.write(Box::into_raw(Box::new(program)));
                0
            }
            Err(error) => ap1_status(error),
        }
    }))
    .unwrap_or(4)
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_ap1_metal_render_v1(
    program: *mut MetalProgram,
    graph: *const u8,
    graph_bytes: usize,
    input: *mut c_void,
    retained_output: *mut *mut c_void,
    view_json: *const u8,
    view_bytes: usize,
    receipt: *mut MetalReceipt,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    if !retained_output.is_null() {
        retained_output.write(std::ptr::null_mut());
    }
    if !receipt.is_null() {
        receipt.write(MetalReceipt::default());
    }
    if program.is_null()
        || graph.is_null()
        || input.is_null()
        || retained_output.is_null()
        || receipt.is_null()
        || !(1..=1024 * 1024).contains(&graph_bytes)
        || view_bytes > 4096
        || (view_json.is_null() && view_bytes != 0)
    {
        return 1;
    }
    let started = Instant::now();
    catch_unwind(AssertUnwindSafe(|| {
        let check = || {
            current
                .map(|callback| callback(context, revision) != 0)
                .unwrap_or(true)
        };
        if !check() {
            return 5;
        }
        if !admits_source(input) {
            return 1;
        }
        let view = if view_bytes == 0 {
            ViewSpec::default()
        } else {
            match serde_json::from_slice(slice::from_raw_parts(view_json, view_bytes)) {
                Ok(view) => view,
                Err(_) => return 1,
            }
        };
        let source = metal::TextureRef::from_ptr(input.cast());
        let document = slice::from_raw_parts(graph, graph_bytes);
        // Serial C callers make this exclusive borrow cover the cache and synchronous queue work.
        let (output, mut result) = match (&mut *program).render(document, &view, source) {
            Ok(rendered) => rendered,
            Err(error) => return ap1_status(error),
        };
        if !check() {
            return 5;
        }
        result.cpu_ms = started.elapsed().as_secs_f64() * 1_000.0;
        receipt.write(result);
        retained_output.write(output.into_ptr().cast());
        0
    }))
    .unwrap_or(4)
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_ap1_metal_close_v1(program: *mut MetalProgram) {
    if !program.is_null() {
        drop(Box::from_raw(program));
    }
}

#[cfg(test)]
mod ap1_tests {
    use super::*;

    #[test]
    fn native_ap1_receipt_matches_the_v1_c_layout() {
        use std::mem::{offset_of, size_of};
        assert_eq!(size_of::<MetalReceipt>(), 72);
        assert_eq!(offset_of!(MetalReceipt, pipeline_builds), 16);
        assert_eq!(offset_of!(MetalReceipt, peak_bytes), 24);
        assert_eq!(offset_of!(MetalReceipt, frame_copy_bytes), 40);
        assert_eq!(offset_of!(MetalReceipt, validation_bytes), 48);
        assert_eq!(offset_of!(MetalReceipt, submit_wait_ns), 56);
        assert_eq!(offset_of!(MetalReceipt, cpu_ms), 64);
    }
}
