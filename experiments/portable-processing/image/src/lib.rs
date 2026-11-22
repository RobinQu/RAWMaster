//! Headless edit-graph experiment. Backend selection is explicit for comparable runs.
mod ffi;
#[cfg(feature = "gpu")]
pub mod gpu;
mod graph;
pub use graph::Plan;
use rayon::prelude::*;

pub const EXAMPLE: &str = include_str!("../examples/local-look.json");
pub type Pixel = [f32; 4];

pub struct Frame<'a> {
    width: u32,
    height: u32,
    pixels: &'a [Pixel],
    mask: &'a [f32],
}

impl<'a> Frame<'a> {
    pub fn new(
        width: u32,
        height: u32,
        pixels: &'a [Pixel],
        mask: &'a [f32],
    ) -> Result<Self, String> {
        let count = width
            .checked_mul(height)
            .filter(|n| *n > 0)
            .ok_or("invalid extent")? as usize;
        if pixels.len() != count || mask.len() != count {
            return Err("image and coverage must match the declared extent".into());
        }
        if !pixels.par_iter().all(|p| {
            p.iter().all(|v| v.is_finite())
                && (0.0..=1.0).contains(&p[3])
                && (p[3] != 0.0 || p[..3] == [0.0; 3])
        }) || !mask.par_iter().all(|v| (0.0..=1.0).contains(v))
        {
            return Err("invalid premultiplied pixels or mask coverage".into());
        }
        Ok(Self {
            width,
            height,
            pixels,
            mask,
        })
    }
    pub fn extent(&self) -> (u32, u32) {
        (self.width, self.height)
    }
}

extern "C" {
    fn rmi_reference_tile(
        steps: *const graph::Step,
        count: usize,
        rgba: *const Pixel,
        mask: *const f32,
        out: *mut Pixel,
        pixels: usize,
    );
}

pub fn render_cpu(plan: &Plan, frame: &Frame) -> Result<Vec<Pixel>, String> {
    const TILE: usize = 256;
    let mut result = vec![[0.0; 4]; frame.pixels.len()];
    result
        .par_chunks_mut(TILE)
        .enumerate()
        .for_each(|(tile, chunk)| {
            let start = tile * TILE;
            // The validated, topologically sorted graph contains at most 64 steps.
            // Each worker reads one immutable tile and writes its own disjoint slice.
            unsafe {
                rmi_reference_tile(
                    plan.steps.as_ptr(),
                    plan.steps.len(),
                    frame.pixels[start..].as_ptr(),
                    frame.mask[start..].as_ptr(),
                    chunk.as_mut_ptr(),
                    chunk.len(),
                );
            }
        });
    check_output(result)
}

fn check_output(result: Vec<Pixel>) -> Result<Vec<Pixel>, String> {
    if result.par_iter().any(|p| p.iter().any(|v| !v.is_finite())) {
        return Err("non-finite output".into());
    }
    Ok(result)
}
