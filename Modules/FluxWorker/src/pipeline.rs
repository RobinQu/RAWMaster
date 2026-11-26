use crate::{image_prep, model, noise, text_encoder, tokenizer, vae};
use anyhow::{bail, Context, Result};
use mlx_rs::{Array, Dtype};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Instant;

pub struct PipelineRequest {
    pub model_root: PathBuf,
    pub input: PathBuf,
    pub prompt: String,
    pub width: i32,
    pub height: i32,
    pub seed: u64,
    pub steps: usize,
    pub grid: Option<Vec<usize>>,
    pub noise_fixture: Option<PathBuf>,
    pub fp16_weights: bool,
    pub cancel: Option<PathBuf>,
    pub parent_pid: Option<u32>,
}

pub struct PipelineOutput {
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub schedule: Vec<f32>,
    pub tokens: usize,
    pub reference_width: u32,
    pub reference_height: u32,
    pub stages: serde_json::Value,
    pub latent_sha: String,
    pub peak_mlx_bytes: i64,
    pub elapsed_seconds: f64,
}


pub fn configure_metal_library() -> Result<()> {
    let path = std::env::var_os("RAWMASTER_MLX_METALLIB")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|exe| exe.parent().map(|dir| dir.join("mlx.metallib")))
                .filter(|path| path.is_file())
        });
    if let Some(path) = path {
        mlx_rs::metal::set_metallib_path(
            path.to_str().context("Metal library path is not valid UTF-8")?,
        )?;
    }
    Ok(())
}

pub fn run(request: &PipelineRequest) -> Result<PipelineOutput> {
    configure_metal_library()?;
    mlx_rs::memory::reset_peak_memory()?;
    let total_start = Instant::now();
    let model_root = &request.model_root;
    let width = request.width;
    let height = request.height;
    let steps = request.steps;
    if !(64..=4096).contains(&width)
        || !(64..=4096).contains(&height)
        || width % 16 != 0
        || height % 16 != 0
    {
        bail!("width and height must be multiples of 16 in 64...4096");
    }

    let start = Instant::now();
    let tokens = tokenizer::encode(model_root, &request.prompt)?;
    let tokenize_seconds = start.elapsed().as_secs_f64();

    let start = Instant::now();
    let text = text_encoder::encode(model_root, &tokens)?;
    text.eval()?;
    let text_seconds = start.elapsed().as_secs_f64();

    let start = Instant::now();
    let prepared = image_prep::prepare_reference(&request.input)?;
    let image_seconds = start.elapsed().as_secs_f64();
    let reference_image = Array::from_slice(
        &prepared.pixels,
        &[prepared.height as i32, prepared.width as i32, 3],
    );
    let start = Instant::now();
    let encoder = vae::Vae::load(
        &model_root.join("vae-fp32/vae_encoder.safetensors"),
        Dtype::Float16,
    )?;
    let reference = encoder.encode(&reference_image)?;
    reference.eval()?;
    let reference_seconds = start.elapsed().as_secs_f64();
    drop(encoder);
    drop(reference_image);
    mlx_rs::memory::clear_cache()?;

    let mut image_ids = Vec::with_capacity((height / 16 * width / 16) as usize);
    for row in 0..height / 16 {
        for column in 0..width / 16 {
            image_ids.push([0.0, row as f32 * 0.5, column as f32 * 0.5, 0.0]);
        }
    }
    let mut reference_ids =
        Vec::with_capacity((prepared.height / 16 * prepared.width / 16) as usize);
    for row in 0..prepared.height / 16 {
        for column in 0..prepared.width / 16 {
            reference_ids.push([0.0, row as f32 * 0.5, column as f32 * 0.5, -1.0]);
        }
    }
    let text_ids: Vec<[f32; 4]> = tokens
        .ids
        .iter()
        .enumerate()
        .map(|(index, _)| [0.0, 0.0, 0.0, index as f32])
        .collect();
    let mut ids: HashMap<String, Vec<[f32; 4]>> = HashMap::new();
    ids.insert("image".into(), image_ids);
    ids.insert("image_cond".into(), reference_ids);
    ids.insert("text".into(), text_ids);

    let (noise, schedule) = if let Some(fixture) = &request.noise_fixture {
        noise::load_fixture(fixture, &fixture.with_file_name("schedule.npy"))?
    } else {
        noise::generate(
            request.seed,
            height / 16 * (width / 16),
            steps,
            request.grid.as_deref(),
        )
    };
    if schedule.len() != steps + 1 {
        bail!(
            "schedule has {} entries for {} steps",
            schedule.len(),
            steps
        );
    }

    let model_dir = model_root.join("q8");
    let start = Instant::now();
    let mut dit = model::DiT::load(&model_dir, schedule.len() - 1, request.fp16_weights)?;
    dit.prepare(&schedule, &ids)?;
    let dit_load_seconds = start.elapsed().as_secs_f64();

    let start = Instant::now();
    let mut image = noise;
    for step in 0..steps {
        if let Some(cancel) = &request.cancel {
            if cancel.exists() {
                bail!("cancelled");
            }
        }
        if let Some(parent) = request.parent_pid {
            if std::os::unix::process::parent_id() != parent {
                bail!("parent exited");
            }
        }
        let velocity = dit.forward(&image, &text, &reference, step)?;
        let delta = schedule[step + 1] - schedule[step];
        image = image.add(&velocity.multiply(&Array::from_f32(delta))?)?;
        image.eval()?;
    }
    let denoise_seconds = start.elapsed().as_secs_f64();
    let final_latent = image;
    final_latent.eval()?;
    let latent_sha = {
        let mut hasher = Sha256::new();
        hasher.update(bytemuck_cast(final_latent.as_slice::<f32>()));
        format!("{:x}", hasher.finalize())
    };
    drop(dit);
    mlx_rs::memory::clear_cache()?;

    let start = Instant::now();
    let decoder = vae::Vae::load(&model_root.join("vae-fp32/vae.safetensors"), Dtype::Float16)?;
    let decoded = decoder.decode(&final_latent, height, width)?;
    decoded.eval()?;
    let decode_seconds = start.elapsed().as_secs_f64();
    let values = decoded.as_slice::<f32>();
    let mut bytes = Vec::with_capacity(values.len());
    for value in values {
        bytes.push((((value.clamp(-1.0, 1.0) + 1.0) * 127.5).round()) as u8);
    }
    let peak_mlx_bytes = mlx_rs::memory::peak_memory()? as i64;
    let elapsed_seconds = total_start.elapsed().as_secs_f64();
    let stages = serde_json::json!({
        "tokenize": tokenize_seconds,
        "text": text_seconds,
        "image": image_seconds,
        "reference": reference_seconds,
        "ditLoad": dit_load_seconds,
        "denoise": denoise_seconds,
        "decode": decode_seconds,
        "total": elapsed_seconds,
    });
    Ok(PipelineOutput {
        bytes,
        width: width as u32,
        height: height as u32,
        schedule,
        tokens: tokens.ids.len(),
        reference_width: prepared.width,
        reference_height: prepared.height,
        stages,
        latent_sha,
        peak_mlx_bytes,
        elapsed_seconds,
    })
}

fn bytemuck_cast(values: &[f32]) -> &[u8] {
    unsafe {
        std::slice::from_raw_parts(values.as_ptr() as *const u8, std::mem::size_of_val(values))
    }
}
