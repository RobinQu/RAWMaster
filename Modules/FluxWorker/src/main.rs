mod image_prep;
mod model;
mod noise;
mod npy;
mod pipeline;
mod text_encoder;
mod tokenizer;
mod vae;
mod weights;

use anyhow::{bail, Context, Result};
use mlx_rs::{Array, Dtype};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn load_f32(path: &Path) -> Result<(Array, Vec<i32>)> {
    let npy = npy::load(path)?;
    let (values, shape) = npy.f32()?;
    Ok((Array::from_slice(values, shape), shape.to_vec()))
}

fn ids_from_rows(values: &[f32], shape: &[i32]) -> Vec<[f32; 4]> {
    let rows = shape[0] as usize;
    let mut ids = Vec::with_capacity(rows);
    for i in 0..rows {
        let o = i * 4;
        ids.push([values[o], values[o + 1], values[o + 2], values[o + 3]]);
    }
    ids
}

fn read_prompt(path: &Path) -> Result<String> {
    let text = std::fs::read_to_string(path)?;
    if path.extension().map(|e| e == "json").unwrap_or(false) {
        let value: serde_json::Value = serde_json::from_str(&text)?;
        Ok(value
            .get("prompt")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string())
    } else {
        Ok(text)
    }
}

fn run_worker() -> Result<()> {
    pipeline::configure_metal_library()?;
    unsafe { mlx_rs::Device::set_default(&mlx_rs::Device::gpu())? };
    mlx_rs::memory::set_cache_limit(512 * 1024 * 1024)?;
    let cwd = std::env::current_dir()?;
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(cwd.join("worker.lock"))?;
    fs2::FileExt::lock_exclusive(&lock)?;
    let cancel = cwd.with_extension("cancel");
    let request: serde_json::Value =
        serde_json::from_slice(&std::fs::read(cwd.join("request.json"))?)?;
    let prompt = request
        .get("prompt")
        .and_then(|v| v.as_str())
        .context("request.prompt")?
        .to_string();
    let seed = request
        .get("seed")
        .and_then(|v| v.as_u64().or_else(|| v.as_i64().map(|n| n as u64)))
        .unwrap_or(8521);
    let width = request
        .get("width")
        .and_then(|v| v.as_i64())
        .unwrap_or(1024) as i32;
    let height = request
        .get("height")
        .and_then(|v| v.as_i64())
        .unwrap_or(1024) as i32;
    let weights = request
        .get("weightsDirectory")
        .and_then(|v| v.as_str())
        .context("request.weightsDirectory")?;
    let parent = std::os::unix::process::parent_id();
    let start = Instant::now();
    let result = match pipeline::run(&pipeline::PipelineRequest {
        model_root: PathBuf::from(weights),
        input: cwd.join("input.png"),
        prompt,
        width,
        height,
        seed,
        steps: 16,
        grid: None,
        noise_fixture: None,
        fp16_weights: false,
        cancel: Some(cancel),
        parent_pid: Some(parent),
    }) {
        Ok(result) => result,
        Err(error) if error.to_string() == "cancelled" || error.to_string() == "parent exited" => {
            std::process::exit(130)
        }
        Err(error) => return Err(error),
    };
    let candidate_path = cwd.join("candidate.png");
    image::save_buffer(
        &candidate_path,
        &result.bytes,
        result.width,
        result.height,
        image::ColorType::Rgb8,
    )?;
    let png_bytes = std::fs::read(&candidate_path)?;
    let png_sha = {
        let mut hasher = Sha256::new();
        hasher.update(&png_bytes);
        format!("{:x}", hasher.finalize())
    };
    let receipt = serde_json::json!({
        "runtimeRevision": "rawmaster-flux-rust-mlx-v1",
        "weightsRevision": "d9790a1ceaba200e8b773fb236f7c9fa754283a7",
        "modelRevision": "1755314e2216b2a2c5cc0dd899d4e49ee3404d2c",
        "mlxVersion": "0.32.2",
        "rng": "chacha12+standardnormal+bf16",
        "preset": "q8-16",
        "outputSHA256": png_sha,
        "steps": 16,
        "seed": seed,
        "elapsedSeconds": start.elapsed().as_secs_f64(),
        "pipelineSeconds": result.elapsed_seconds,
        "peakMLXBytes": result.peak_mlx_bytes,
    });
    std::fs::write(
        cwd.join("worker-receipt.json"),
        serde_json::to_vec(&receipt)?,
    )?;
    let _ = fs2::FileExt::unlock(&lock);
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--tokens-only") {
        let model_root = PathBuf::from(arg(&args, "--model-root").context("--model-root")?);
        let prompt_file = PathBuf::from(arg(&args, "--prompt-file").context("--prompt-file")?);
        let prompt = read_prompt(&prompt_file)?;
        let tokens = tokenizer::encode(&model_root, &prompt)?;
        let report = serde_json::json!({
            "length": tokens.ids.len(),
            "ids": tokens.ids,
            "positions": tokens.positions,
            "valid": tokens.valid,
        });
        let out = PathBuf::from(arg(&args, "--tokens-out").unwrap_or_else(|| "tokens.json".into()));
        std::fs::write(&out, serde_json::to_string_pretty(&report)?)?;
        println!("tokens {} -> {}", tokens.ids.len(), out.display());
        return Ok(());
    }

    if args.iter().any(|a| a == "--text-only") {
        let model_root = PathBuf::from(arg(&args, "--model-root").context("--model-root")?);
        let fixtures = PathBuf::from(arg(&args, "--fixtures").context("--fixtures")?);
        let token_npy = npy::load(&fixtures.join("token_ids.npy"))?;
        let (ids, _) = token_npy.i64()?;
        let position_npy = npy::load(&fixtures.join("positions.npy"))?;
        let (positions, _) = position_npy.i64()?;
        let valid_npy = npy::load(&fixtures.join("valid.npy"))?;
        let (valid, _) = valid_npy.bool()?;
        let tokens = tokenizer::PromptTokens {
            ids: ids.iter().map(|&v| v as u32).collect(),
            positions: positions.iter().map(|&v| v as i32).collect(),
            valid: valid.to_vec(),
        };
        let start = Instant::now();
        let text = text_encoder::encode(Path::new(&model_root), &tokens)?;
        let seconds = start.elapsed().as_secs_f64();
        let out = PathBuf::from(arg(&args, "--text-out").unwrap_or_else(|| "text-rust.npy".into()));
        npy::save_f32(&out, text.as_slice::<f32>(), text.shape())?;
        println!(
            "text {:?} in {:.3}s -> {}",
            text.shape(),
            seconds,
            out.display()
        );
        return Ok(());
    }

    if args.iter().any(|a| a == "--vae-test") {
        let model_root = PathBuf::from(arg(&args, "--model-root").context("--model-root")?);
        let input = PathBuf::from(arg(&args, "--input").context("--input")?);
        let fixtures = PathBuf::from(arg(&args, "--fixtures").context("--fixtures")?);
        let out_dir = PathBuf::from(arg(&args, "--vae-out").unwrap_or_else(|| "vae-out".into()));
        std::fs::create_dir_all(&out_dir)?;
        let image = image::open(&input)?.to_rgb8();
        let (width, height) = image.dimensions();
        let mut pixels = Vec::with_capacity((width * height * 3) as usize);
        for pixel in image.pixels() {
            for channel in pixel.0 {
                pixels.push(channel as f32 / 127.5 - 1.0);
            }
        }
        let image_array = Array::from_slice(&pixels, &[height as i32, width as i32, 3]);

        let start = Instant::now();
        let encoder = vae::Vae::load(
            &model_root.join("vae-fp32/vae_encoder.safetensors"),
            Dtype::Float16,
        )?;
        let reference = encoder.encode(&image_array)?;
        reference.eval()?;
        let encode_seconds = start.elapsed().as_secs_f64();
        npy::save_f32(
            &out_dir.join("reference-rust.npy"),
            reference.as_slice::<f32>(),
            reference.shape(),
        )?;
        drop(encoder);
        drop(reference);
        mlx_rs::memory::clear_cache()?;

        let latent_npy = npy::load(&fixtures.join("final_latent.npy"))?;
        let (latent_values, latent_shape) = latent_npy.f32()?;
        let latent = Array::from_slice(latent_values, latent_shape);
        let start = Instant::now();
        let decoder = vae::Vae::load(&model_root.join("vae-fp32/vae.safetensors"), Dtype::Float16)?;
        let decoded = decoder.decode(&latent, height as i32, width as i32)?;
        decoded.eval()?;
        let decode_seconds = start.elapsed().as_secs_f64();
        let values = decoded.as_slice::<f32>();
        let mut bytes = Vec::with_capacity(values.len());
        for value in values {
            bytes.push((((value.clamp(-1.0, 1.0) + 1.0) * 127.5).round()) as u8);
        }
        image::save_buffer(
            out_dir.join("vae-decoded.png"),
            &bytes,
            width,
            height,
            image::ColorType::Rgb8,
        )?;
        println!(
            "vae encode {:.3}s decode {:.3}s -> {}",
            encode_seconds,
            decode_seconds,
            out_dir.display()
        );
        return Ok(());
    }

    if args.iter().any(|a| a == "--worker") {
        return run_worker();
    }

    unsafe { mlx_rs::Device::set_default(&mlx_rs::Device::gpu())? };
    mlx_rs::memory::set_cache_limit(512 * 1024 * 1024)?;

    if args.iter().any(|a| a == "--full") {
        let model_root = PathBuf::from(arg(&args, "--model-root").context("--model-root")?);
        let input = PathBuf::from(arg(&args, "--input").context("--input")?);
        let prompt_file = PathBuf::from(arg(&args, "--prompt-file").context("--prompt-file")?);
        let width: i32 = arg(&args, "--width")
            .unwrap_or_else(|| "1024".into())
            .parse()?;
        let height: i32 = arg(&args, "--height")
            .unwrap_or_else(|| "1024".into())
            .parse()?;
        let seed: u64 = arg(&args, "--seed")
            .unwrap_or_else(|| "8521".into())
            .parse()?;
        let grid: Option<Vec<usize>> = arg(&args, "--grid").map(|value| {
            value
                .split(',')
                .map(|item| item.trim().parse::<usize>().unwrap())
                .collect()
        });
        let steps: usize = grid
            .as_ref()
            .map(|values| values.len() - 1)
            .unwrap_or_else(|| {
                arg(&args, "--steps")
                    .unwrap_or_else(|| "16".into())
                    .parse()
                    .unwrap()
            });
        let noise_fixture = arg(&args, "--noise-fixture").map(PathBuf::from);
        let out = PathBuf::from(arg(&args, "--out").unwrap_or_else(|| "full.png".into()));
        let metrics_path =
            PathBuf::from(arg(&args, "--metrics").unwrap_or_else(|| "full.metrics.json".into()));
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let prompt = read_prompt(&prompt_file)?;
        let fp16_weights = args.iter().any(|a| a == "--fp16-weights");
        let result = pipeline::run(&pipeline::PipelineRequest {
            model_root: model_root.clone(),
            input: input.clone(),
            prompt,
            width,
            height,
            seed,
            steps,
            grid,
            noise_fixture: noise_fixture.clone(),
            fp16_weights,
            cancel: None,
            parent_pid: None,
        })?;
        image::save_buffer(
            &out,
            &result.bytes,
            result.width,
            result.height,
            image::ColorType::Rgb8,
        )?;
        let written = std::fs::read(&out)?;
        let written_sha = {
            let mut hasher = Sha256::new();
            hasher.update(&written);
            format!("{:x}", hasher.finalize())
        };
        let report = serde_json::json!({
            "modelID": "black-forest-labs/flux-3-image-klein",
            "modelRevision": "1755314e2216b2a2c5cc0dd899d4e49ee3404d2c",
            "weightsRevision": "d9790a1ceaba200e8b773fb236f7c9fa754283a7",
            "runtime": "rawmaster-flux-rust-mlx-v1",
            "precision": if fp16_weights { "q8-load-dequant-fp16-dense" } else { "q8-16-scaled-f16-standard-ops" },
            "backend": "mlx-rs 0.34 / MLX 0.32.2 / Metal",
            "rng": if noise_fixture.is_some() { "torch-fixture" } else { "chacha12+standardnormal+bf16" },
            "input": input.display().to_string(),
            "width": width,
            "height": height,
            "referenceWidth": result.reference_width,
            "referenceHeight": result.reference_height,
            "tokens": result.tokens,
            "steps": steps,
            "seed": seed,
            "schedule": result.schedule,
            "stages": result.stages,
            "finalLatentSHA256": result.latent_sha,
            "outputSHA256": written_sha,
            "peakMLXBytes": result.peak_mlx_bytes,
            "output": out.display().to_string(),
        });
        std::fs::write(&metrics_path, serde_json::to_string_pretty(&report)?)?;
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    let fixtures = PathBuf::from(arg(&args, "--fixtures").context("--fixtures")?);
    let model_dir = PathBuf::from(arg(&args, "--model-dir").context("--model-dir")?);
    let steps: usize = arg(&args, "--steps")
        .unwrap_or_else(|| "16".into())
        .parse()?;
    let timed_steps: usize = arg(&args, "--timed-steps")
        .unwrap_or_else(|| "3".into())
        .parse()?;
    let output = PathBuf::from(arg(&args, "--out").unwrap_or_else(|| "result.json".into()));

    unsafe { mlx_rs::Device::set_default(&mlx_rs::Device::gpu())? };
    mlx_rs::memory::set_cache_limit(512 * 1024 * 1024)?;

    let load_start = Instant::now();
    let (text, text_shape) = load_f32(&fixtures.join("text.npy"))?;
    let (reference, reference_shape) = load_f32(&fixtures.join("reference.npy"))?;
    let (noise, noise_shape) = load_f32(&fixtures.join("noise.npy"))?;
    let (schedule, schedule_shape) = load_f32(&fixtures.join("schedule.npy"))?;
    let (image_rows, image_shape) = load_f32(&fixtures.join("image_ids.npy"))?;
    let (reference_rows, reference_shape_ids) = load_f32(&fixtures.join("reference_ids.npy"))?;
    let token_npy = npy::load(&fixtures.join("token_ids.npy"))?;
    let (token_values, token_shape) = token_npy.i64()?;
    let schedule_vec: Vec<f32> = schedule.as_slice::<f32>().to_vec();
    if schedule_vec.len() < steps + 1 {
        bail!(
            "schedule has {} entries, need {}",
            schedule_vec.len(),
            steps + 1
        );
    }

    let image_ids_values = image_rows.as_slice::<f32>();
    let reference_ids_values = reference_rows.as_slice::<f32>();
    let image_ids = ids_from_rows(image_ids_values, &image_shape);
    let reference_ids = ids_from_rows(reference_ids_values, &reference_shape_ids);
    let text_ids: Vec<[f32; 4]> = token_values
        .iter()
        .enumerate()
        .map(|(i, _)| [0.0, 0.0, 0.0, i as f32])
        .collect();
    let mut ids: HashMap<String, Vec<[f32; 4]>> = HashMap::new();
    ids.insert("image".into(), image_ids);
    ids.insert("image_cond".into(), reference_ids);
    ids.insert("text".into(), text_ids);

    let mut dit = model::DiT::load(
        &model_dir,
        steps,
        args.iter().any(|a| a == "--fp16-weights"),
    )?;
    let load_seconds = load_start.elapsed().as_secs_f64();
    let prepare_start = Instant::now();
    dit.prepare(&schedule_vec[..steps + 1], &ids)?;
    let prepare_seconds = prepare_start.elapsed().as_secs_f64();

    let mut image = noise.clone();
    let warm_start = Instant::now();
    let velocity = dit.forward(&image, &text, &reference, 0)?;
    let dt = schedule_vec[1] - schedule_vec[0];
    image = image.add(&velocity.multiply(&Array::from_f32(dt))?)?;
    image.eval()?;
    let warm_seconds = warm_start.elapsed().as_secs_f64();

    let mut step_seconds = Vec::with_capacity(timed_steps);
    for step in 1..=timed_steps.min(steps - 1) {
        let start = Instant::now();
        let velocity = dit.forward(&image, &text, &reference, step)?;
        let dt = schedule_vec[step + 1] - schedule_vec[step];
        image = image.add(&velocity.multiply(&Array::from_f32(dt))?)?;
        image.eval()?;
        step_seconds.push(start.elapsed().as_secs_f64());
    }

    let bytes = image.as_slice::<f32>();
    let mut hasher = Sha256::new();
    hasher.update(bytemuck_cast(bytes));
    let sha = format!("{:x}", hasher.finalize());
    std::fs::write(output.with_extension("bin"), bytemuck_cast(bytes))?;
    let report = serde_json::json!({
        "shape": {
            "text": text_shape,
            "reference": reference_shape,
            "noise": noise_shape,
            "schedule": schedule_shape,
            "tokens": token_shape,
        },
        "load_seconds": load_seconds,
        "prepare_seconds": prepare_seconds,
        "warm_step_seconds": warm_seconds,
        "timed_step_seconds": step_seconds,
        "timed_steps": step_seconds.len(),
        "final_latent_sha256": sha,
        "final_latent_bin": output.with_extension("bin").display().to_string(),
    });
    std::fs::write(&output, serde_json::to_string_pretty(&report)?)?;
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}

fn bytemuck_cast(values: &[f32]) -> &[u8] {
    // f32 is plain old data; avoid an extra dependency for this research binary.
    unsafe {
        std::slice::from_raw_parts(values.as_ptr() as *const u8, std::mem::size_of_val(values))
    }
}
