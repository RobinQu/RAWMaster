//! Portable, linear-light image recipe execution for desktop and headless hosts.
mod color_grading;
mod curves_levels;
mod ffi;
mod filters;
#[cfg(all(target_os = "macos", feature = "metal-surface"))]
mod metal_ffi;
pub use filters::{exposure_gain, FilterBinding};
#[cfg(feature = "gpu")]
pub mod gpu;
mod graph;
pub use graph::Plan;
use rayon::prelude::*;

pub type Pixel = [f32; 4];

/// A frozen scalar coverage image bound to the exact UTF-8 ID of a mask node.
#[derive(Clone, Copy)]
pub struct CoveragePlane<'a> {
    pub id: &'a str,
    pub values: &'a [f32],
}

enum Coverage<'a> {
    Anonymous(&'a [f32]),
    Named(Vec<CoveragePlane<'a>>),
}

pub struct Frame<'a> {
    width: u32,
    height: u32,
    pixels: &'a [Pixel],
    coverage: Coverage<'a>,
}

impl<'a> Frame<'a> {
    pub fn new(
        width: u32,
        height: u32,
        pixels: &'a [Pixel],
        mask: &'a [f32],
    ) -> Result<Self, String> {
        Self::with_transport(width, height, pixels, mask, false)
    }
    /// RAW ingress can carry an alpha overshoot of one to three F32 ULPs.
    /// An active filter must explicitly repair it before an image can be published.
    pub fn with_transport(
        width: u32,
        height: u32,
        pixels: &'a [Pixel],
        mask: &'a [f32],
        repair: bool,
    ) -> Result<Self, String> {
        Self::from_coverage(width, height, pixels, Coverage::Anonymous(mask), repair)
    }

    pub fn with_named_coverage(
        width: u32,
        height: u32,
        pixels: &'a [Pixel],
        coverage: &[CoveragePlane<'a>],
        repair: bool,
    ) -> Result<Self, String> {
        if coverage.len() > graph::MAX_MASKS {
            return Err("too many coverage planes".into());
        }
        for (index, plane) in coverage.iter().enumerate() {
            if plane.id.is_empty()
                || plane.id.len() > 64
                || coverage[..index].iter().any(|p| p.id == plane.id)
            {
                return Err("invalid or duplicate coverage plane ID".into());
            }
        }
        Self::from_coverage(
            width,
            height,
            pixels,
            Coverage::Named(coverage.to_vec()),
            repair,
        )
    }

    fn from_coverage(
        width: u32,
        height: u32,
        pixels: &'a [Pixel],
        coverage: Coverage<'a>,
        repair: bool,
    ) -> Result<Self, String> {
        let count = width
            .checked_mul(height)
            .filter(|n| *n > 0)
            .ok_or("invalid extent")? as usize;
        if pixels.len() != count {
            return Err("image and coverage must match the declared extent".into());
        }
        let validate_plane = |values: &[f32]| -> Result<(), String> {
            if values.len() != count {
                return Err("image and coverage must match the declared extent".into());
            }
            if !values.par_iter().all(|v| (0.0..=1.0).contains(v)) {
                return Err("invalid premultiplied pixels or mask coverage".into());
            }
            Ok(())
        };
        match &coverage {
            Coverage::Named(planes) => {
                for plane in planes {
                    validate_plane(plane.values)?;
                }
            }
            Coverage::Anonymous(values) if !values.is_empty() => validate_plane(values)?,
            Coverage::Anonymous(_) => {}
        }
        if !pixels.par_iter().all(|p| {
            p.iter().all(|v| v.is_finite())
                && ((0.0..=1.0).contains(&p[3])
                    || (repair && (0x3f800001..=0x3f800003).contains(&p[3].to_bits())))
                && (p[3] != 0.0 || p[..3] == [0.0; 3])
        }) {
            return Err("invalid premultiplied pixels or mask coverage".into());
        }
        Ok(Self {
            width,
            height,
            pixels,
            coverage,
        })
    }
    pub fn extent(&self) -> (u32, u32) {
        (self.width, self.height)
    }
}

// Share one transcendental implementation across macOS and headless Linux. The C++
// hot loop receives these functions explicitly; no symbols enter the public C ABI.
extern "C" fn encode_srgb(value: f32) -> f32 {
    if value <= 0.0031308 {
        12.92 * value
    } else {
        1.055 * libm::powf(value, 1.0_f32 / 2.4) - 0.055
    }
}
extern "C" fn mask_gain(ev: f32) -> f32 {
    libm::exp2f(ev)
}
extern "C" fn power(base: f32, exponent: f32) -> f32 {
    libm::powf(base, exponent)
}

extern "C" {
    fn rm_image_reference_tile(
        steps: *const graph::Step,
        count: usize,
        atlas: *const Pixel,
        parameter_rows: *const Pixel,
        rgba: *const Pixel,
        masks: *const *const f32,
        out: *mut Pixel,
        pixels: usize,
        encode: extern "C" fn(f32) -> f32,
        gain: extern "C" fn(f32) -> f32,
        power: extern "C" fn(f32, f32) -> f32,
    );
}

pub fn render_cpu(plan: &Plan, frame: &Frame) -> Result<Vec<Pixel>, String> {
    let masks = plan.resolve_masks(frame)?;
    // The C++ tile scratch holds 16,384 RGBA intermediates per worker.
    let tile_pixels = if plan.steps.len() <= 64 { 256 } else { 128 };
    let mut result = vec![[0.0; 4]; frame.pixels.len()];
    result
        .par_chunks_mut(tile_pixels)
        .enumerate()
        .for_each(|(tile, chunk)| {
            let start = tile * tile_pixels;
            let mut tile_masks = [std::ptr::null(); graph::MAX_MASKS];
            for (destination, plane) in tile_masks.iter_mut().zip(&masks) {
                *destination = plane[start..].as_ptr();
            }
            // Each worker borrows its coverage rows and writes a disjoint output slice.
            unsafe {
                rm_image_reference_tile(
                    plan.steps.as_ptr(),
                    plan.steps.len(),
                    plan.assets.pixels.as_ptr(),
                    plan.parameter_rows.as_ptr(),
                    frame.pixels[start..].as_ptr(),
                    tile_masks.as_ptr(),
                    chunk.as_mut_ptr(),
                    chunk.len(),
                    encode_srgb,
                    mask_gain,
                    power,
                );
            }
        });
    check_output(result)
}

impl Plan {
    /// Bind immutable frame data to this plan before any pixel is rendered.
    pub fn resolve_masks<'a>(&self, frame: &Frame<'a>) -> Result<Vec<&'a [f32]>, String> {
        match &frame.coverage {
            Coverage::Named(planes) => self.order_masks(planes.iter().map(|p| (p.id, p.values))),
            Coverage::Anonymous(values) if values.is_empty() => {
                if self.needs_mask() {
                    Err("graph requires a coverage plane".into())
                } else {
                    Ok(Vec::new())
                }
            }
            Coverage::Anonymous(values) if self.recipe_version() == 1 => Ok(if self.needs_mask() {
                vec![*values]
            } else {
                Vec::new()
            }),
            Coverage::Anonymous(_) => Err("version 2 coverage planes must be named".into()),
        }
    }
}

fn check_output(result: Vec<Pixel>) -> Result<Vec<Pixel>, String> {
    if result
        .par_iter()
        .any(|p| p.iter().any(|v| !v.is_finite()) || !(0.0..=1.0).contains(&p[3]))
    {
        return Err("non-finite output or invalid alpha".into());
    }
    Ok(result)
}
