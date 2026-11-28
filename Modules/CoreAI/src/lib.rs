mod face;
mod face_detector;
mod ffi;
mod runtime;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
enum Error {
    InvalidArgument = 1,
    IncompatibleRuntime = 2,
    ModelRejected = 3,
    InvalidImage = 4,
    InvalidLandmarks = 5,
    Busy = 6,
    BudgetExceeded = 7,
    Cancelled = 8,
    InferenceFailed = 9,
    Internal = 10,
}

#[derive(Clone, Copy)]
enum PixelFormat {
    Rgba8,
    Bgra8,
}

struct Image<'a> {
    data: &'a [u8],
    width: usize,
    height: usize,
    stride: usize,
    format: PixelFormat,
}

#[derive(Clone, Copy)]
#[repr(C)]
struct Point {
    x: f64,
    y: f64,
}

#[derive(Clone, Copy)]
#[repr(C)]
struct FaceDetection {
    bounds: [f64; 4],
    landmarks: [Point; 5],
    confidence: f64,
}
