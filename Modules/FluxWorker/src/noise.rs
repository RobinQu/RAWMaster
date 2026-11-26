use anyhow::Result;
use half::bf16;
use mlx_rs::Array;
use rand::SeedableRng;
use rand_chacha::ChaCha12Rng;
use rand_distr::{Distribution, StandardNormal};
use std::path::Path;

use crate::npy;

pub const ALPHA: f32 = 6.93;

fn official_schedule() -> Vec<f32> {
    (0..=16)
        .map(|i| {
            let t = 1.0 - i as f32 / 16.0;
            ALPHA * t / (1.0 + (ALPHA - 1.0) * t)
        })
        .collect()
}

pub fn schedule(steps: usize, grid: Option<&[usize]>) -> Vec<f32> {
    if let Some(grid) = grid {
        let full = official_schedule();
        return grid.iter().map(|&index| full[index]).collect();
    }
    (0..=steps)
        .map(|i| {
            let t = 1.0 - i as f32 / steps as f32;
            ALPHA * t / (1.0 + (ALPHA - 1.0) * t)
        })
        .collect()
}

pub fn generate(seed: u64, tokens: i32, steps: usize, grid: Option<&[usize]>) -> (Array, Vec<f32>) {
    let mut rng = ChaCha12Rng::seed_from_u64(seed);
    let mut values = Vec::with_capacity(tokens as usize * 128);
    for _ in 0..tokens as usize * 128 {
        let value: f64 = StandardNormal.sample(&mut rng);
        // The reference torch worker stores init noise as bfloat16 before denoise.
        values.push(bf16::from_f32(value as f32).to_f32());
    }
    (
        Array::from_slice(&values, &[tokens, 128]),
        schedule(steps, grid),
    )
}

pub fn load_fixture(path: &Path, schedule_path: &Path) -> Result<(Array, Vec<f32>)> {
    let noise_npy = npy::load(path)?;
    let (noise, shape) = noise_npy.f32()?;
    let schedule_npy = npy::load(schedule_path)?;
    let (schedule_values, _) = schedule_npy.f32()?;
    Ok((Array::from_slice(noise, shape), schedule_values.to_vec()))
}
