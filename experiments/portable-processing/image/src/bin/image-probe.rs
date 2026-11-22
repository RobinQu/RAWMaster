use rawmaster_image_poc::{render_cpu, Frame, Pixel, Plan, EXAMPLE};
use serde_json::{json, Value};
use std::{env, time::Instant};

fn ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}
fn samples(values: Vec<f64>) -> Value {
    let mut sorted = values.clone();
    sorted.sort_by(f64::total_cmp);
    let n = sorted.len();
    json!({"p50_ms":sorted[(n-1)/2],"p95_ms":sorted[(n*95).div_ceil(100)-1],"samples_ms":values})
}
fn pattern(n: usize) -> (Vec<Pixel>, Vec<f32>) {
    let mut pixels = Vec::with_capacity(n);
    let mut mask = Vec::with_capacity(n);
    for i in 0..n {
        let a = (i % 257) as f32 / 256.0;
        pixels.push([
            ((i % 503) as f32 / 137.0 - 0.25) * a,
            (i % 89) as f32 / 61.0 * a,
            (i % 31) as f32 / 45.0 * a,
            a,
        ]);
        mask.push((i % 113) as f32 / 112.0);
    }
    (pixels, mask)
}
#[cfg(feature = "gpu")]
fn max_error(a: &[Pixel], b: &[Pixel]) -> Result<f32, String> {
    let err = a
        .iter()
        .flatten()
        .zip(b.iter().flatten())
        .fold(0.0f32, |m, (a, b)| m.max((a - b).abs()));
    if err > 2.0e-6 {
        return Err(format!("CPU/GPU error {err}"));
    }
    Ok(err)
}
#[cfg(feature = "gpu")]
fn compare(plan: &Plan, frame: &Frame, reference: &[Pixel], n: usize) -> Result<Value, String> {
    use rawmaster_image_poc::gpu::{Gpu, Mode};
    let start = Instant::now();
    let gpu = Gpu::open()?;
    let mut report = json!({"adapter":gpu.adapter,"open_ms":ms(start)});
    let edited = Plan::parse(&EXAMPLE.replace("-0.5", "-0.75"))?;
    let edited_reference = render_cpu(&edited, frame)?;
    let mut modes = [("staged", Mode::Staged), ("fused", Mode::Fused)];
    if env::var("RM035_FUSED_FIRST").as_deref() == Ok("1") {
        modes.reverse();
    }
    report["measurement_order"] = json!([modes[0].0, modes[1].0]);
    for (name, mode) in modes {
        let start = Instant::now();
        let program = gpu.compile(plan, mode)?;
        let compile_ms = ms(start);
        let resident = gpu.bind(&program, plan, frame)?;
        resident.submit();
        let initial_error = max_error(reference, &resident.read()?)?;
        let mut times = Vec::new();
        // Every sample updates uniforms, submits and waits for actual device completion.
        // The first round is warm. Two reference results exercise changed slider values.
        for i in 0..n {
            let start = Instant::now();
            resident.update(if i % 2 == 0 { &edited } else { plan })?;
            resident.submit();
            gpu.wait()?;
            times.push(ms(start));
        }
        let updated_error = max_error(
            if n % 2 == 1 {
                &edited_reference
            } else {
                reference
            },
            &resident.read()?,
        )?;
        let mut burst = Vec::new();
        const IN_FLIGHT: usize = 8;
        for _ in 0..n {
            let start = Instant::now();
            for i in 0..IN_FLIGHT {
                resident.update(if i % 2 == 0 { &edited } else { plan })?;
                resident.submit();
            }
            gpu.wait()?;
            burst.push(ms(start) / IN_FLIGHT as f64);
        }
        let burst_error = max_error(reference, &resident.read()?)?;
        let (passes, slots) = (resident.dispatches(), resident.rgba_slots());
        drop(resident);
        let mut full = Vec::new();
        let mut full_error = 0.0f32;
        for i in 0..n {
            let (recipe, expected) = if i % 2 == 0 {
                (&edited, edited_reference.as_slice())
            } else {
                (plan, reference)
            };
            let start = Instant::now();
            let resident = gpu.bind(&program, recipe, frame)?;
            resident.submit();
            let pixels = resident.read()?;
            full.push(ms(start));
            full_error = full_error.max(max_error(expected, &pixels)?);
        }
        report[name] = json!({"compile_ms":compile_ms,"dispatches":passes,"rgba_slots":slots,
            "max_abs_error":initial_error.max(updated_error).max(full_error).max(burst_error),
            "burst_frames":IN_FLIGHT,"resident_burst_ms_per_frame":samples(burst),
            "resident_update_fence":samples(times),"bind_upload_render_read_validate":samples(full)});
    }
    Ok(report)
}
fn run() -> Result<(), String> {
    let args: Vec<_> = env::args().skip(1).collect();
    if args.len() != 4 || !["cpu", "compare", "bounded"].contains(&args[0].as_str()) {
        return Err("usage: image-probe cpu|compare|bounded WIDTH HEIGHT ROUNDS".into());
    }
    let number = |i: usize| args[i].parse::<u32>().map_err(|e| e.to_string());
    let (w, h, rounds) = (number(1)?, number(2)?, number(3)? as usize);
    let n = w
        .checked_mul(h)
        .filter(|&n| n > 0 && n <= 64_000_000)
        .ok_or("expected 1..64M pixels")? as usize;
    if !(1..=100).contains(&rounds) {
        return Err("rounds must be in 1..100".into());
    }
    let (pixels, mask) = pattern(n);
    let start = Instant::now();
    let frame = Frame::new(w, h, &pixels, &mask)?;
    let validate_ms = ms(start);
    let plan = Plan::parse(EXAMPLE)?;
    let reference = render_cpu(&plan, &frame)?;
    let mut times = Vec::new();
    for _ in 0..rounds {
        let start = Instant::now();
        let output = render_cpu(&plan, &frame)?;
        times.push(ms(start));
        std::hint::black_box(output);
    }
    let mut data = json!({"width":w,"height":h,"rounds":rounds,"pattern":"extended-premul-v1",
        "cpu_threads":rayon::current_num_threads(),"cpu_render_validate":samples(times),
        "ingress_validate_ms":validate_ms,"reference_pixels":[reference[n/3],reference[n/2],reference[n-1]]});
    if args[0] != "cpu" {
        #[cfg(feature = "gpu")]
        {
            if args[0] == "compare" {
                data["gpu"] = compare(&plan, &frame, &reference, rounds)?;
            } else {
                use rawmaster_image_poc::gpu::{Gpu, Mode};
                let gpu = Gpu::open()?;
                let program = gpu.compile(&plan, Mode::Fused)?;
                let budget = 256 << 20;
                let mut times = Vec::new();
                let mut tiles = 0;
                let mut error = 0.0f32;
                for i in 0..=rounds {
                    let start = Instant::now();
                    let (out, count) = gpu.render_bounded(&program, &plan, &frame, budget)?;
                    if i != 0 {
                        times.push(ms(start));
                    }
                    tiles = count;
                    error = error.max(max_error(&reference, &out)?);
                }
                data["gpu"] = json!({"adapter":gpu.adapter, "explicit_buffer_budget_bytes":budget,
                    "tiles":tiles,"max_abs_error":error,"bind_upload_render_read_validate":samples(times)});
            }
        }
        #[cfg(not(feature = "gpu"))]
        {
            return Err("GPU support was disabled at build time".into());
        }
    } else {
        data["backend"] = json!("cpu");
    }
    println!("{}", serde_json::to_string_pretty(&data).unwrap());
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
