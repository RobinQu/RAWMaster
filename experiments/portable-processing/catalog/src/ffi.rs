use crate::{response, Queue};
use std::ffi::{c_char, CStr, CString};
use std::panic::catch_unwind;
use std::path::Path;

#[no_mangle]
pub extern "C" fn rmq_abi_version() -> u32 {
    1
}

/// # Safety
/// Both inputs must be valid NUL-terminated strings for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn rmq_request_v1(
    path: *const c_char,
    request: *const c_char,
) -> *mut c_char {
    let reply = catch_unwind(|| {
        response((|| {
            if path.is_null() || request.is_null() {
                return Err("null input".into());
            }
            let path = unsafe { CStr::from_ptr(path) }.to_str()?;
            let body = unsafe { CStr::from_ptr(request) }.to_bytes();
            let request = serde_json::from_slice(body)?;
            Queue::open(Path::new(path))?.request(request)
        })())
    })
    .unwrap_or_else(|_| serde_json::json!({"ok": false, "error": "internal queue failure"}));
    // JSON serialization escapes literal NULs.
    CString::new(reply.to_string())
        .expect("serialized JSON")
        .into_raw()
}

/// # Safety
/// Pass a null pointer or a reply from rmq_request_v1 exactly once.
#[no_mangle]
pub unsafe extern "C" fn rmq_release_v1(reply: *mut c_char) {
    if !reply.is_null() {
        drop(unsafe { CString::from_raw(reply) });
    }
}
