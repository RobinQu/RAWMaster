//! Time the production Rust GPU executor on a photograph, its frozen sky mask and Vivid LUT.
//! Prepare with `python3 tests/replay_mask.py prepare <frames> --full-frame`, then run
//! `cargo run --locked --release --example gpu_performance -- <frames> <filter-dir> 3 21 fused-first Metal`.
//! Run again with `staged-first` to record the reverse order in a fresh process.
//! Append `--named-coverage` to use the native PortableFrozenCoverageTests receipt instead.
#[cfg(feature = "gpu")]
mod benchmark {
    use rawmaster_image::{
        gpu::{Gpu, Mode},
        render_cpu, CoveragePlane, Frame, Pixel, Plan,
    };
    use serde::Deserialize;
    use serde_json::{json, Value};
    use sha2::{Digest, Sha256};
    use std::{env, error::Error, fs, path::Path, time::Instant};

    type Result<T> = std::result::Result<T, Box<dyn Error>>;
    const BUDGET: u64 = 256 << 20;
    const AMOUNTS: [f64; 2] = [37.5, 43.75];
    const TOLERANCE: f32 = 2e-4;

    fn ms(start: Instant) -> f64 {
        start.elapsed().as_secs_f64() * 1000.0
    }

    fn hash(bytes: &[u8]) -> String {
        format!("{:x}", Sha256::digest(bytes))
    }

    fn summary(values: Vec<f64>) -> Value {
        let mut sorted = values.clone();
        sorted.sort_by(f64::total_cmp);
        let n = sorted.len();
        json!({
            "p50Ms": sorted[n.div_ceil(2) - 1],
            "p95Ms": sorted[(n * 95).div_ceil(100) - 1],
            "samplesMs": values,
        })
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Prepared {
        size: [u32; 2],
        #[serde(rename = "sourceF32SHA256")]
        image_hash: String,
        #[serde(rename = "maskF32SHA256")]
        mask_hash: String,
        binding: Value,
        sampling: String,
    }

    #[derive(Deserialize)]
    struct FileReceipt {
        filename: String,
        sha256: String,
    }

    #[derive(Deserialize)]
    struct NamedPlaneReceipt {
        id: String,
        #[serde(flatten)]
        file: FileReceipt,
    }

    #[derive(Deserialize)]
    struct NamedReceipt {
        width: u32,
        height: u32,
        decoder: String,
        frame: FileReceipt,
        cpu: FileReceipt,
        recipe: FileReceipt,
        film: FileReceipt,
        planes: Vec<NamedPlaneReceipt>,
    }

    fn read_plane(path: &Path, size: usize, expected: &str) -> Result<Vec<u8>> {
        if fs::metadata(path)?.len() != size as u64 {
            return Err(format!("unexpected byte count: {}", path.display()).into());
        }
        let data = fs::read(path)?;
        if data.len() != size || hash(&data) != expected {
            return Err(format!("unexpected input digest: {}", path.display()).into());
        }
        Ok(data)
    }

    fn recipe(amount: f64) -> Value {
        json!({
            "version":1, "working":"extended-linear-srgb-premul-f32", "output":"result",
            "nodes":[
                {"id":"src", "op":"source"},
                {"id":"sky", "op":"mask"},
                {"id":"global", "op":"exposure", "image":"src", "ev":0.25},
                {"id":"local", "op":"masked_exposure", "image":"global", "mask":"sky", "ev":-1.25},
                {"id":"look", "op":"photo_filter", "image":"local", "look":"vivid", "amount":amount},
                {"id":"result", "op":"blend", "base":"global", "layer":"look", "mask":"sky"}
            ]
        })
    }

    fn decode_pixels(bytes: &[u8]) -> Vec<Pixel> {
        bytes
            .as_chunks::<16>()
            .0
            .iter()
            .copied()
            .map(bytemuck::cast)
            .collect()
    }

    fn decode_coverage(bytes: &[u8]) -> Vec<f32> {
        bytes
            .as_chunks::<4>()
            .0
            .iter()
            .copied()
            .map(f32::from_le_bytes)
            .collect()
    }

    fn compare(a: &[Pixel], b: &[Pixel]) -> Result<f32> {
        if a.len() != b.len() {
            return Err("truncated render".into());
        }
        let max = a
            .iter()
            .flatten()
            .zip(b.iter().flatten())
            .fold(0.0_f32, |max, (a, b)| max.max((a - b).abs()));
        if max > TOLERANCE {
            return Err(format!("CPU/GPU pixel difference {max}").into());
        }
        Ok(max)
    }

    struct Run<'a> {
        gpu: &'a Gpu,
        plans: [Plan; 2],
        references: [Vec<Pixel>; 2],
        frame: Frame<'a>,
        plane_count: u64,
        node_count: u64,
        atlas_bytes: u64,
        warmups: usize,
        rounds: usize,
    }

    impl Run<'_> {
        fn measure(&self, mode: Mode) -> Result<Value> {
            let Self {
                gpu,
                plans,
                references,
                frame,
                plane_count,
                node_count,
                atlas_bytes,
                warmups,
                rounds,
            } = self;
            let start = Instant::now();
            let program = gpu.compile(&plans[0], mode)?;
            gpu.wait()?;
            let compile_ms = ms(start);
            let start = Instant::now();
            let resident = gpu.bind(&program, &plans[0], frame)?;
            gpu.wait()?;
            let initial_upload_ms = ms(start);

            // Verify both actual states against the C++ reference outside the warm sample series.
            let mut first = Vec::new();
            let mut oracle_error = [0.0; 2];
            let mut expected = Vec::new();
            for state in 0..2 {
                let start = Instant::now();
                resident.update(&plans[state])?;
                resident.submit();
                let image = resident.read()?;
                first.push(ms(start));
                oracle_error[state] = compare(&image, &references[state])?;
                expected.push(image);
            }
            if expected[0] == expected[1] {
                return Err("the two LUT control states produced identical pixels".into());
            }

            let mut update = Vec::new();
            let mut completed = Vec::new();
            let mut copy = Vec::new();
            let mut total = Vec::new();
            let mut states = Vec::new();
            for i in 0..(warmups + rounds) {
                let state = i % 2;
                let start = Instant::now();
                resident.update(&plans[state])?;
                let update_ms = ms(start);
                resident.submit();
                gpu.wait()?;
                let fence_ms = ms(start);
                let read_start = Instant::now();
                let image = resident.read()?;
                let read_ms = ms(read_start);
                let total_ms = ms(start);
                // Byte comparison stays outside both timers. This also catches stale parameter bindings.
                if bytemuck::cast_slice::<Pixel, u8>(&image)
                    != bytemuck::cast_slice::<Pixel, u8>(&expected[state])
                {
                    return Err(format!("wrong resident output in state {state}").into());
                }
                if i >= *warmups {
                    states.push(state);
                    update.push(update_ms);
                    completed.push(fence_ms);
                    copy.push(read_ms);
                    total.push(total_ms);
                }
            }
            let passes = resident.dispatches();
            let slots = resident.rgba_slots();
            drop(resident);

            // In this series each call binds fresh image/mask storage. render_bounded performs its
            // own copy-to-staging and final finite validation. The caller already has a valid Frame.
            let mut full = Vec::new();
            let mut tile_counts = Vec::new();
            for i in 0..(warmups + rounds) {
                let state = i % 2;
                let start = Instant::now();
                let (image, tiles) = gpu.render_bounded(&program, &plans[state], frame, BUDGET)?;
                let full_ms = ms(start);
                if bytemuck::cast_slice::<Pixel, u8>(&image)
                    != bytemuck::cast_slice::<Pixel, u8>(&expected[state])
                {
                    return Err(format!("wrong complete readback in state {state}").into());
                }
                if i >= *warmups {
                    full.push(full_ms);
                    tile_counts.push(tiles);
                }
            }
            let (width, height) = frame.extent();
            let n = u64::from(width) * u64::from(height);
            let parameters = 16 + 48 * node_count;
            let mask_bytes = 4 * plane_count;
            Ok(json!({
                "compileAndJoinMs":compile_ms, "initialBindAndJoinMs":initial_upload_ms,
                "firstUpdateSubmitReadbackMs":first, "statesInSampleOrder":states,
                "dispatchesPerTile":passes, "rgbaStorageSlotsIncludingSource":slots,
                "atlasBufferBytes":atlas_bytes, "parameterUploadBytesPerResidentUpdate":parameters,
                "frameUploadBytesPerFreshBind":n * (16 + mask_bytes), "fullFrameReadbackBytes":n * 16,
                "explicitResidentBytes":atlas_bytes + parameters + n * (slots as u64 * 16 + mask_bytes),
                "explicitBytesWithReadback":atlas_bytes + parameters + n * program.bytes_per_pixel_with_readback(),
                "maxAbsVsCPUByState":oracle_error,
                "verifiedOutputSHA256":expected.iter().map(|im| hash(bytemuck::cast_slice(im))).collect::<Vec<_>>(),
                "residentParameterWriteCPU":summary(update),
                "residentUpdateSubmitComplete":summary(completed),
                "readbackAfterCompletion":summary(copy),
                "residentUpdateThroughReadback":summary(total),
                "freshBindUploadRenderReadback":summary(full), "freshRenderTiles":tile_counts,
            }))
        }
    }

    struct NamedFixture {
        receipt: NamedReceipt,
        binding: Value,
        pixels: Vec<Pixel>,
        coverage: Vec<Vec<f32>>,
        recipes: [Value; 2],
        atlas_bytes: usize,
    }

    impl NamedFixture {
        fn read(inputs: &Path, filters: &Path) -> Result<Self> {
            let manifest = fs::read(inputs.join("manifest.json"))?;
            let receipt: NamedReceipt = serde_json::from_slice(&manifest)?;
            let binding: Value = serde_json::from_slice(&manifest)?;
            let count = receipt.width as usize * receipt.height as usize;
            if [receipt.width, receipt.height] != [2400, 1600] || receipt.planes.len() != 2 {
                return Err("expected the two-plane 2400×1600 frozen RAW fixture".into());
            }
            let pixels = decode_pixels(&read_plane(
                &inputs.join(&receipt.frame.filename),
                count * 16,
                &receipt.frame.sha256,
            )?);
            let coverage = receipt
                .planes
                .iter()
                .map(|plane| {
                    read_plane(
                        &inputs.join(&plane.file.filename),
                        count * 4,
                        &plane.file.sha256,
                    )
                    .map(|bytes| decode_coverage(&bytes))
                })
                .collect::<Result<Vec<_>>>()?;
            let graph_bytes = fs::read(inputs.join(&receipt.recipe.filename))?;
            if hash(&graph_bytes) != receipt.recipe.sha256 {
                return Err("unexpected recipe digest".into());
            }
            let graph: Value = serde_json::from_slice(&graph_bytes)?;
            let mut alternate = graph.clone();
            let film = alternate["nodes"]
                .as_array_mut()
                .and_then(|nodes| nodes.iter_mut().find(|node| node["op"] == "photo_filter"))
                .ok_or("the named fixture requires a film node")?;
            film["amount"] = json!(AMOUNTS[1]);
            let atlas_bytes = 64_usize.pow(3) * 16;
            read_plane(
                &filters.join(&receipt.film.filename),
                atlas_bytes,
                &receipt.film.sha256,
            )?;
            Ok(Self {
                receipt,
                binding,
                pixels,
                coverage,
                recipes: [graph, alternate],
                atlas_bytes,
            })
        }
    }

    pub fn run() -> Result<()> {
        let args: Vec<_> = env::args().skip(1).collect();
        let named_fixture = args.get(6).is_some_and(|flag| flag == "--named-coverage");
        if args.len() != if named_fixture { 7 } else { 6 } {
            return Err("usage: gpu_performance INPUT_DIR FILTER_ROOT WARMUPS SAMPLES fused-first|staged-first Metal|Vulkan [--named-coverage]".into());
        }
        if !cfg!(target_endian = "little") {
            return Err("the receipt stores RGBA32F little endian".into());
        }
        let inputs = Path::new(&args[0]);
        let filters = Path::new(&args[1]);
        let warmups: usize = args[2].parse()?;
        let rounds: usize = args[3].parse()?;
        if !(1..=100).contains(&warmups) || !(2..=1000).contains(&rounds) {
            return Err("supply 1..100 warmups and 2..1000 samples per mode".into());
        }
        let order = match args[4].as_str() {
            "fused-first" => [("fused", Mode::Fused), ("staged", Mode::Staged)],
            "staged-first" => [("staged", Mode::Staged), ("fused", Mode::Fused)],
            _ => return Err("unknown measurement order".into()),
        };
        if !matches!(args[5].as_str(), "Metal" | "Vulkan") {
            return Err("unknown expected backend".into());
        }
        if named_fixture {
            return run_named(inputs, filters, warmups, rounds, order, &args[4], &args[5]);
        }
        let prep: Prepared = serde_json::from_slice(&fs::read(inputs.join("prepared.json"))?)?;
        let [width, height] = prep.size;
        if !matches!(prep.size, [160, 107] | [1600, 1067] | [3840, 2160])
            || prep.binding["sourceSHA256"]
                != "503aa25139ab5cabccdc919c4e76643b97e51cf202643766d9606ad36406c442"
            || prep.binding["maskSHA256"]
                != "c4dd3d1d32ba59b5dcee9e505958fd7f815622bb45b5ce2069ddedf73b3c2c9e"
            || prep.binding["modelSHA256"]
                != "e6df30d2fa120b86364e0b5158a278f4550fd9f1ebeda3ec342683da55872f7d"
        {
            return Err("expected the pinned photograph and frozen EfficientViT sky mask".into());
        }
        let n = width as usize * height as usize;
        let pixels = decode_pixels(&read_plane(
            &inputs.join("source.rgba32fle"),
            n * 16,
            &prep.image_hash,
        )?);
        let mask = decode_coverage(&read_plane(
            &inputs.join("mask.r32fle"),
            n * 4,
            &prep.mask_hash,
        )?);
        let start = Instant::now();
        let frame = Frame::new(width, height, &pixels, &mask)?;
        let ingress_ms = ms(start);
        let start = Instant::now();
        let parse = |amount| Plan::parse_with_resources(&recipe(amount).to_string(), Some(filters));
        let plans = [parse(AMOUNTS[0])?, parse(AMOUNTS[1])?];
        let parse_ms = ms(start);
        let references = [
            render_cpu(&plans[0], &frame)?,
            render_cpu(&plans[1], &frame)?,
        ];
        let reference_hashes: Vec<_> = references
            .iter()
            .map(|im| hash(bytemuck::cast_slice(im)))
            .collect();
        let start = Instant::now();
        let gpu = Gpu::open()?;
        let open_ms = ms(start);
        if !gpu
            .adapter
            .split(" / ")
            .any(|component| component == args[5])
        {
            return Err(format!("expected {}, selected {}", args[5], gpu.adapter).into());
        }
        let run = Run {
            gpu: &gpu,
            plans,
            references,
            frame,
            plane_count: 1,
            node_count: recipe(AMOUNTS[0])["nodes"].as_array().unwrap().len() as u64,
            atlas_bytes: 2 * 64_u64.pow(3) * 16,
            warmups,
            rounds,
        };
        let mut results = serde_json::Map::new();
        for (name, mode) in order {
            results.insert(name.to_owned(), run.measure(mode)?);
        }
        let binary = fs::read(env::current_exe()?)?;
        let mut atlas_files = Vec::new();
        for filename in ["vivid-025.delta64.rgba32f", "vivid-050.delta64.rgba32f"] {
            atlas_files.push(
                json!({"file": filename, "sha256": hash(&fs::read(filters.join(filename))?)}),
            );
        }
        let report = json!({
            "schema":1, "crate":env!("CARGO_PKG_NAME"),"crateVersion":env!("CARGO_PKG_VERSION"),
            "entryPoints":["rawmaster_image::Plan::parse_with_resources","rawmaster_image::gpu::Gpu::{compile,bind,render_bounded}","rawmaster_image::gpu::Resident::{update,submit,read}"],
            "profile":if cfg!(debug_assertions) {"debug"}else{"release"},"benchmarkBinarySHA256":hash(&binary),
            "cargoLockSHA256":hash(include_bytes!("../Cargo.lock")),
            "productionGPUExecutorSHA256":hash(include_bytes!("../src/gpu.rs")),
            "productionWGSLSHA256":hash(concat!(include_str!("../src/kernels.wgsl"), include_str!("../src/point_operators.wgsl"), include_str!("../src/point_entry.wgsl")).as_bytes()),
            "extent":prep.size,"fixtureBinding":prep.binding,"sampling":prep.sampling,
            "sourceF32SHA256":prep.image_hash,"maskF32SHA256":prep.mask_hash,
            "zeroCoverage":mask.iter().filter(|&&v|v==0.0).count(),
            "fractionalCoverage":mask.iter().filter(|&&v|v>0.0 && v<1.0).count(),
            "plans":AMOUNTS.map(recipe), "atlasFiles":atlas_files,
            "cpuOracleSHA256":reference_hashes,"tolerance":TOLERANCE,"gpuAdapter":gpu.adapter,
            "frameValidationMs":ingress_ms,"twoPlanParseAndVerifyMs":parse_ms,"gpuOpenMs":open_ms,
            "warmupsPerSeries":warmups,"samplesPerSeries":rounds,"order":args[4],"budgetBytes":BUDGET,
            "clock":"wall milliseconds from Instant; update/submit/queue completion and staging/host copies have separate endpoints",
            "statistics":"nearest-rank p50/p95; state alternates, pixels compared after each timed interval; all raw samples in acquisition order",
            "memory":"explicit buffer sizes; driver allocations, C++ references and host copies excluded",
            "results":results,
        });
        println!("{}", serde_json::to_string_pretty(&report)?);
        Ok(())
    }

    fn run_named(
        inputs: &Path,
        filters: &Path,
        warmups: usize,
        rounds: usize,
        modes: [(&str, Mode); 2],
        sample_order: &str,
        backend: &str,
    ) -> Result<()> {
        let fixture = NamedFixture::read(inputs, filters)?;
        let NamedReceipt {
            width,
            height,
            frame: source,
            cpu,
            decoder,
            ..
        } = &fixture.receipt;
        let planes: Vec<_> = fixture
            .receipt
            .planes
            .iter()
            .zip(&fixture.coverage)
            .rev()
            .map(|(plane, values)| CoveragePlane {
                id: &plane.id,
                values,
            })
            .collect();
        let start = Instant::now();
        let frame = Frame::with_named_coverage(*width, *height, &fixture.pixels, &planes, false)?;
        let validation_ms = ms(start);
        let start = Instant::now();
        let parse = |value: &Value| Plan::parse_with_resources(&value.to_string(), Some(filters));
        let plans = [parse(&fixture.recipes[0])?, parse(&fixture.recipes[1])?];
        let parse_ms = ms(start);
        let references = [
            render_cpu(&plans[0], &frame)?,
            render_cpu(&plans[1], &frame)?,
        ];
        let cpu_hashes = references
            .each_ref()
            .map(|pixels| hash(bytemuck::cast_slice(pixels)));
        if cpu_hashes[0] != cpu.sha256 {
            return Err("CPU output differs from the native fixture".into());
        }
        let start = Instant::now();
        let gpu = Gpu::open()?;
        let open_ms = ms(start);
        if !gpu
            .adapter
            .split(" / ")
            .any(|component| component == backend)
        {
            return Err(format!("expected {backend}, selected {}", gpu.adapter).into());
        }
        let run = Run {
            gpu: &gpu,
            plans,
            references,
            frame,
            warmups,
            rounds,
            plane_count: planes.len() as u64,
            node_count: fixture.recipes[0]["nodes"]
                .as_array()
                .ok_or("missing named nodes")?
                .len() as u64,
            atlas_bytes: fixture.atlas_bytes as u64,
        };
        let mut results = serde_json::Map::new();
        for (name, mode) in modes {
            results.insert(name.to_owned(), run.measure(mode)?);
        }
        let report = json!({
            "schema":1, "gpuAdapter":gpu.adapter, "extent":[width,height], "order":sample_order,
            "frameValidationMs":validation_ms, "twoPlanParseAndVerifyMs":parse_ms, "gpuOpenMs":open_ms,
            "warmupsPerSeries":warmups, "samplesPerSeries":rounds, "budgetBytes":BUDGET,
            "sourceSHA256":fixture.binding["sourceSHA256"], "sourceF32SHA256":source.sha256, "decoder":decoder,
            "planeReceipts":fixture.binding["planes"], "atlasReceipt":fixture.binding["film"], "plans":fixture.recipes,
            "cpuOracleSHA256":cpu_hashes, "tolerance":TOLERANCE,
            "benchmarkBinarySHA256":hash(&fs::read(env::current_exe()?)?),
            "productionGPUExecutorSHA256":hash(include_bytes!("../src/gpu.rs")),
            "results":results,
        });
        println!("{}", serde_json::to_string_pretty(&report)?);
        Ok(())
    }
}

#[cfg(feature = "gpu")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    benchmark::run()
}
#[cfg(not(feature = "gpu"))]
fn main() -> Result<(), &'static str> {
    Err("gpu_performance requires the gpu feature")
}
