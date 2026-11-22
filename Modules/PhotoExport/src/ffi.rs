//! Versioned, synchronous C ABI for hosts that cannot link the Rust API directly.
use crate::{
    encode, encode_rgbx8, geometry, normalize_preset, output_stem, publish, validate_count,
    validate_template, Dimensions, ExportError, Format, Raster, Result, MAX_BATCH_PHOTOS,
};
use serde_json::{json, Value};
use std::{
    ffi::{c_char, CStr},
    fs::OpenOptions,
    io::{self, BufWriter},
    panic::{catch_unwind, AssertUnwindSafe},
    path::Path,
    ptr, slice,
};

#[no_mangle]
pub extern "C" fn rm_photo_export_abi() -> u32 {
    1
}

#[no_mangle]
pub extern "C" fn rm_photo_export_limit() -> usize {
    MAX_BATCH_PHOTOS
}

fn request(op: u32, bytes: &[u8]) -> Result<Value> {
    let parse = |_| ExportError::Options;
    match op {
        1 => {
            let data = normalize_preset(bytes)?;
            serde_json::from_slice(&data).map_err(parse)
        }
        2 => serde_json::to_value(geometry(serde_json::from_slice(bytes).map_err(parse)?)?)
            .map_err(parse),
        3 => Ok(json!(output_stem(
            &serde_json::from_slice(bytes).map_err(parse)?
        )?)),
        4 => {
            validate_template(std::str::from_utf8(bytes).map_err(|_| ExportError::Filename)?)?;
            Ok(Value::Null)
        }
        5 => {
            validate_count(serde_json::from_slice(bytes).map_err(parse)?)?;
            Ok(Value::Null)
        }
        _ => Err(ExportError::Options),
    }
}

/// The caller keeps `input_len` bytes readable and provides writable storage for `out_len`.
/// Release the returned buffer with `rm_photo_export_free`.
#[no_mangle]
pub unsafe extern "C" fn rm_photo_export_request(
    op: u32,
    input: *const u8,
    input_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() || input.is_null() || input_len > 2 * 1024 * 1024 {
        return ptr::null_mut();
    }
    let response = catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { slice::from_raw_parts(input, input_len) };
        match request(op, bytes) {
            Ok(value) => json!({"value": value}),
            Err(error) => json!({"error": error.to_string(), "code": status(&error)}),
        }
    }));
    let Ok(response) = response else {
        return ptr::null_mut();
    };
    let Ok(bytes) = serde_json::to_vec(&response) else {
        return ptr::null_mut();
    };
    let mut bytes = bytes.into_boxed_slice();
    unsafe { *out_len = bytes.len() };
    let result = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    result
}

/// `output` and `length` come from one successful request.
#[no_mangle]
pub unsafe extern "C" fn rm_photo_export_free(output: *mut u8, length: usize) {
    if !output.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(output, length)) });
    }
}

fn status(error: &ExportError) -> i32 {
    match error {
        ExportError::Io(error) if error.kind() == io::ErrorKind::AlreadyExists => 2,
        ExportError::Io(_) => 3,
        ExportError::CaptureDate => 4,
        ExportError::Encoding(_) => 5,
        _ => 1,
    }
}

fn run(f: impl FnOnce() -> Result<()>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => status(&error),
        Err(_) => 5,
    }
}

unsafe fn path<'a>(ptr: *const c_char) -> Result<&'a Path> {
    if ptr.is_null() {
        return Err(ExportError::Filename);
    }
    let text = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| ExportError::Filename)?;
    Ok(Path::new(text))
}

/// Paths are NUL-terminated UTF-8. Pixels are still borrowed when this function returns.
/// pixel_format 1 = opaque RGBX8; 2 = straight-alpha native-endian RGBA16.
#[no_mangle]
pub unsafe extern "C" fn rm_photo_export_encode(
    output_path: *const c_char,
    pixels: *const u8,
    width: u32,
    height: u32,
    stride: usize,
    len: usize,
    pixel_format: u32,
    output_format: u32,
    quality: u8,
) -> i32 {
    run(|| {
        let path = unsafe { path(output_path)? };
        let size = Dimensions { width, height };
        let area = size.area()?;
        let format = match output_format {
            1 => Format::Jpeg,
            2 => Format::Png,
            3 => Format::Tiff,
            _ => return Err(ExportError::Options),
        };
        if pixels.is_null()
            || len > isize::MAX as usize
            || stride.checked_mul(height as usize) != Some(len)
        {
            return Err(ExportError::Pixels);
        }
        let samples = unsafe { slice::from_raw_parts(pixels, len) };
        let file = OpenOptions::new().write(true).create_new(true).open(path)?;
        let mut file = BufWriter::new(file);
        let result = match pixel_format {
            1 if format == Format::Jpeg => encode_rgbx8(&mut file, samples, size, stride, quality),
            2 if len == area * 8 => {
                let samples = bytemuck::try_cast_slice(samples).map_err(|_| ExportError::Pixels)?;
                encode(
                    &mut file,
                    Raster {
                        pixels: samples,
                        size,
                    },
                    format,
                    quality,
                )
            }
            _ => Err(ExportError::Pixels),
        };
        use std::io::Write;
        let result = result.and_then(|()| file.flush().map_err(Into::into));
        if result.is_err() {
            drop(file);
            let _ = std::fs::remove_file(path);
        }
        result
    })
}

/// Both paths point to closed files in the destination filesystem.
#[no_mangle]
pub unsafe extern "C" fn rm_photo_export_publish(from: *const c_char, to: *const c_char) -> i32 {
    run(|| publish(unsafe { path(from)? }, unsafe { path(to)? }))
}
