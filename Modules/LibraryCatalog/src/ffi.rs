use crate::{request, transaction, Result};
use rusqlite::{ffi, Connection};
use serde_json::{json, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::{ptr, slice, str};

#[repr(C)]
pub struct RMLibraryBytes {
    pub data: *mut u8,
    pub length: usize,
}

#[no_mangle]
pub extern "C" fn rm_library_abi_version() -> u32 {
    1
}

/// Foreign sqlite3 handles are only compatible with the library that allocated them.
#[no_mangle]
pub extern "C" fn rm_library_sqlite_identity_v1() -> unsafe extern "C" fn() -> std::ffi::c_int {
    ffi::sqlite3_libversion_number
}

unsafe fn input<'a>(data: *const u8, length: usize) -> Result<&'a [u8]> {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return Err("Missing or invalid input".into());
    }
    Ok(unsafe { slice::from_raw_parts(data, length) })
}

unsafe fn respond(out: *mut RMLibraryBytes, body: impl FnOnce() -> Result<Value>) -> i32 {
    if out.is_null() {
        return 2;
    }
    let (status, value) = match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(value)) => (0, value),
        Ok(Err(error)) => (1, json!({"error": error.to_string()})),
        Err(_) => (2, json!({"error": "Internal catalog failure"})),
    };
    let buffer = value.to_string().into_bytes().into_boxed_slice();
    let length = buffer.len();
    unsafe {
        out.write(RMLibraryBytes {
            data: Box::into_raw(buffer) as *mut u8,
            length,
        })
    };
    status
}

/// # Safety
/// The input slices and writable output must be valid until this call returns.
#[no_mangle]
pub unsafe extern "C" fn rm_library_request_v1(
    path: *const u8,
    path_length: usize,
    message: *const u8,
    length: usize,
    out: *mut RMLibraryBytes,
) -> i32 {
    unsafe {
        respond(out, || {
            let name = str::from_utf8(input(path, path_length)?)?;
            let value = serde_json::from_slice(input(message, length)?)?;
            request(Path::new(name), &value)
        })
    }
}

/// # Safety
/// The host must serialize all access to a live connection from the same SQLite library.
/// Buffer lifetime follows rm_library_request_v1. The connection remains owned by the host.
#[no_mangle]
pub unsafe extern "C" fn rm_library_transaction_v1(
    handle: *mut ffi::sqlite3,
    message: *const u8,
    length: usize,
    out: *mut RMLibraryBytes,
) -> i32 {
    unsafe {
        respond(out, || {
            if handle.is_null() {
                return Err("Missing host database".into());
            }
            let value = serde_json::from_slice(input(message, length)?)?;
            let db = Connection::from_handle(handle)?;
            transaction(&db, &value)
        })
    }
}

/// # Safety
/// Pass the same output structure filled by this library. Release before reusing it.
#[no_mangle]
pub unsafe extern "C" fn rm_library_release_v1(out: *mut RMLibraryBytes) {
    if let Some(buffer) = unsafe { out.as_mut() } {
        if !buffer.data.is_null() {
            unsafe {
                drop(Box::from_raw(ptr::slice_from_raw_parts_mut(
                    buffer.data,
                    buffer.length,
                )))
            };
            buffer.data = ptr::null_mut();
            buffer.length = 0;
        }
    }
}
