//! C ABI for the scene-linear AP1 graph executor (macOS Metal only).

use crate::scene::{metal_exec::SceneProgram, ViewSpec};
use foreign_types::ForeignTypeRef;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;
use std::sync::Arc;

type Current = extern "C" fn(*mut c_void, u64) -> u32;

#[no_mangle]
pub extern "C" fn rm_scene_abi_version() -> u32 {
    1
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_open_v1(
    graph: *const u8,
    graph_bytes: usize,
    device: *mut c_void,
    out: *mut *mut SceneProgram,
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
        let program = match SceneProgram::open(device, document) {
            Ok(program) => program,
            Err(crate::scene::SceneError::Invalid(_)) => return 1,
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
        if input.is_null() || output.is_null() {
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
        let output = metal::TextureRef::from_ptr(output.cast());
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
            Ok(()) => 0,
            Err(crate::scene::SceneError::Invalid(_)) => 1,
            Err(crate::scene::SceneError::Backend(_)) => 2,
            Err(crate::scene::SceneError::Render(message)) if message.contains("stale") => 5,
            Err(crate::scene::SceneError::Render(_)) => 3,
            Err(crate::scene::SceneError::Budget(_)) => 6,
        }
    }))
    .unwrap_or(4)
}

#[no_mangle]
pub unsafe extern "C" fn rm_scene_program_close_v1(program: *mut SceneProgram) {
    if !program.is_null() {
        drop(Box::from_raw(program));
    }
}
