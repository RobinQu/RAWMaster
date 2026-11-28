use crate::runtime::{Cancellation, EMBEDDING_LENGTH, Engine};
use crate::{Error, Image, PixelFormat, Point};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::{ptr, slice, str};

const MAX_IMAGE_BYTES: usize = 256 * 1024 * 1024;
const MAX_IMAGE_EDGE: u32 = 16_384;
const MAX_PATH_BYTES: usize = 16_384;

#[repr(C)]
pub struct ImageV1 {
    data: *const u8,
    len: usize,
    stride: usize,
    width: u32,
    height: u32,
    format: u32,
    roi_x: u32,
    roi_y: u32,
    roi_width: u32,
    roi_height: u32,
}

impl ImageV1 {
    fn validate(&self) -> Result<PixelFormat, Error> {
        let format = match self.format {
            1 => PixelFormat::Rgba8,
            2 => PixelFormat::Bgra8,
            _ => return Err(Error::InvalidImage),
        };
        if self.data.is_null()
            || self.width == 0
            || self.height == 0
            || self.roi_x != 0
            || self.roi_y != 0
            || self.roi_width != self.width
            || self.roi_height != self.height
        {
            return Err(Error::InvalidImage);
        }
        if self.width > MAX_IMAGE_EDGE || self.height > MAX_IMAGE_EDGE || self.len > MAX_IMAGE_BYTES
        {
            return Err(Error::BudgetExceeded);
        }
        let row_bytes = self.width as usize * 4;
        let last_pixel_end = self
            .stride
            .checked_mul(self.height as usize - 1)
            .and_then(|bytes| bytes.checked_add(row_bytes))
            .ok_or(Error::BudgetExceeded)?;
        if self.stride < row_bytes || self.len < last_pixel_end {
            return Err(Error::InvalidImage);
        }
        Ok(format)
    }
}

fn status(body: impl FnOnce() -> Result<(), Error>) -> i32 {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => error as i32,
        Err(_) => Error::Internal as i32,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn rm_core_ai_abi_version() -> u32 {
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rm_core_ai_open_v1(
    contents: *const u8,
    len: usize,
    out: *mut *mut Engine,
) -> i32 {
    status(|| unsafe {
        let out = out.as_mut().ok_or(Error::InvalidArgument)?;
        *out = ptr::null_mut();
        if contents.is_null() || !(1..=MAX_PATH_BYTES).contains(&len) {
            return Err(Error::InvalidArgument);
        }
        let path = str::from_utf8(slice::from_raw_parts(contents, len))
            .map_err(|_| Error::InvalidArgument)?;
        if path.as_bytes().contains(&0) {
            return Err(Error::InvalidArgument);
        }
        *out = Box::into_raw(Box::new(Engine::open(Path::new(path))?));
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rm_core_ai_close_v1(engine: *mut Engine) {
    if !engine.is_null() {
        let _ = status(|| {
            unsafe { drop(Box::from_raw(engine)) };
            Ok(())
        });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rm_core_ai_evict_v1(engine: *const Engine) -> i32 {
    status(|| unsafe { engine.as_ref().ok_or(Error::InvalidArgument)?.evict() })
}

#[unsafe(no_mangle)]
pub extern "C" fn rm_core_ai_cancellation_create_v1() -> *mut Cancellation {
    Box::into_raw(Box::new(Cancellation::default()))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rm_core_ai_cancellation_request_v1(token: *const Cancellation) -> i32 {
    status(|| unsafe { token.as_ref().ok_or(Error::InvalidArgument)?.cancel() })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rm_core_ai_cancellation_close_v1(token: *mut Cancellation) {
    if !token.is_null() {
        let _ = status(|| {
            unsafe { drop(Box::from_raw(token)) };
            Ok(())
        });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rm_core_ai_embed_face_v1(
    engine: *const Engine,
    cancel: *const Cancellation,
    raw_image: *const ImageV1,
    landmarks: *const Point,
    landmark_count: usize,
    output: *mut f32,
    output_len: usize,
) -> i32 {
    status(|| unsafe {
        let engine = engine.as_ref().ok_or(Error::InvalidArgument)?;
        let cancel = cancel.as_ref().ok_or(Error::InvalidArgument)?;
        let image = raw_image.as_ref().ok_or(Error::InvalidArgument)?;
        if output.is_null() || output_len != EMBEDDING_LENGTH {
            return Err(Error::InvalidArgument);
        }
        if landmarks.is_null() || landmark_count != 5 {
            return Err(Error::InvalidLandmarks);
        }
        let format = image.validate()?;
        let image = Image {
            data: slice::from_raw_parts(image.data, image.len),
            stride: image.stride,
            width: image.width as usize,
            height: image.height as usize,
            format,
        };
        let points = &*landmarks.cast::<[Point; 5]>();
        let vector = engine.embed(&image, points, cancel)?;
        cancel.publish(|| ptr::copy_nonoverlapping(vector.as_ptr(), output, EMBEDDING_LENGTH))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn image_layout_requires_a_complete_final_row_and_full_roi() {
        let mut image = ImageV1 {
            data: ptr::dangling(),
            len: 19,
            stride: 11,
            width: 2,
            height: 2,
            format: 1,
            roi_x: 0,
            roi_y: 0,
            roi_width: 2,
            roi_height: 2,
        };
        assert!(image.validate().is_ok());
        image.len = 18;
        assert!(matches!(image.validate(), Err(Error::InvalidImage)));
        image.len = 19;
        image.roi_height = 1;
        assert!(matches!(image.validate(), Err(Error::InvalidImage)));
        image.roi_height = 2;
        image.stride = usize::MAX;
        assert!(matches!(image.validate(), Err(Error::BudgetExceeded)));
    }
}
