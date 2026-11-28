//! Submit the same frozen 039 AP1 input on physical Metal and Vulkan without a photo library.

use rawmaster_image::gpu::ap1_scene::{Backend, Program, SceneDevice, DEFAULT_BUDGET_BYTES};
use rawmaster_image::scene::ap1::{
    render_cpu, Prepared, Region, Root, AP1_PORT, OPERATORS, RGB_SCALED_TOLERANCE,
};
use rawmaster_image::scene::{parse, Endpoint};
use rawmaster_image::Pixel;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::error::Error;
use std::fs::{self, File};
use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

const BIT_COMPARISON: &str = "bit-exact-f32";
const FRAME_FILES: [&str; 4] = [
    "final-full.rgba32f",
    "final-roi.rgba32f",
    "monitor-full.rgba32f",
    "monitor-roi.rgba32f",
];
const USAGE: &str =
    "ap1_scene_probe --backend metal|vulkan --graph GRAPH.json --input INPUT.rgba32f \
    --width W --height H --roi X,Y,W,H --monitor NODE_ID --output-dir NEW_DIRECTORY";
type Result<T> = std::result::Result<T, Box<dyn Error>>;

struct Args {
    backend: Backend,
    graph: PathBuf,
    input: PathBuf,
    full: [u32; 2],
    roi: [u32; 4],
    monitor: String,
    output: PathBuf,
    legacy: Option<PathBuf>,
    legacy_manifest: Option<PathBuf>,
    peer: Option<PathBuf>,
    adapter: Option<String>,
    source_sha256: Option<String>,
    calibration_sha256: Option<String>,
    budget: u64,
}

impl Args {
    fn parse() -> Result<Self> {
        let mut supplied = HashMap::new();
        let mut arguments = std::env::args().skip(1);
        while let Some(flag) = arguments.next() {
            let value = arguments
                .next()
                .ok_or_else(|| format!("missing value for {flag}"))?;
            if supplied.insert(flag.clone(), value).is_some() {
                return Err(format!("duplicate flag {flag}").into());
            }
        }
        let mut required = |name: &str| {
            supplied
                .remove(name)
                .ok_or_else(|| format!("missing {name}"))
        };
        let backend = match required("--backend")?.as_str() {
            "metal" => Backend::Metal,
            "vulkan" => Backend::Vulkan,
            _ => return Err("select the physical platform backend metal or vulkan".into()),
        };
        let graph = required("--graph")?.into();
        let input = required("--input")?.into();
        let full = [
            required("--width")?.parse()?,
            required("--height")?.parse()?,
        ];
        let roi: [u32; 4] = required("--roi")?
            .split(',')
            .map(str::parse)
            .collect::<std::result::Result<Vec<u32>, _>>()?
            .try_into()
            .map_err(|_| "--roi needs X,Y,W,H")?;
        let monitor = required("--monitor")?;
        let output = required("--output-dir")?.into();
        let legacy = supplied.remove("--legacy-dir").map(PathBuf::from);
        let legacy_manifest = supplied.remove("--legacy-manifest").map(PathBuf::from);
        if legacy_manifest.is_some() && legacy.is_none() {
            return Err("--legacy-manifest requires --legacy-dir".into());
        }
        let peer = supplied.remove("--peer-dir").map(PathBuf::from);
        let adapter = supplied.remove("--adapter");
        let source_sha256 = digest_arg(supplied.remove("--source-sha256"))?;
        let calibration_sha256 = digest_arg(supplied.remove("--calibration-sha256"))?;
        let budget = supplied
            .remove("--budget-bytes")
            .map(|value| value.parse())
            .transpose()?
            .unwrap_or(DEFAULT_BUDGET_BYTES);
        if let Some(flag) = supplied.keys().next() {
            return Err(format!("unknown flag {flag}").into());
        }
        Ok(Self {
            backend,
            graph,
            input,
            full,
            roi,
            monitor,
            output,
            legacy,
            legacy_manifest,
            peer,
            adapter,
            source_sha256,
            calibration_sha256,
            budget,
        })
    }
}

fn digest_arg(value: Option<String>) -> Result<Option<String>> {
    value.map(normalize_digest).transpose()
}

fn normalize_digest(value: String) -> Result<String> {
    if value.len() != 64 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("a declared SHA-256 must contain 64 hexadecimal digits".into());
    }
    Ok(value.to_ascii_lowercase())
}

fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn engine_source_sha256() -> String {
    let mut digest = Sha256::new();
    let files: &[&[u8]] = &[
        include_bytes!("../Cargo.toml"),
        include_bytes!("../src/lib.rs"),
        include_bytes!("../src/scene.rs"),
        include_bytes!("../src/scene/ap1.rs"),
        include_bytes!("../src/gpu.rs"),
        include_bytes!("../src/gpu/ap1_scene.rs"),
        include_bytes!("../src/gpu/ap1_scene.wgsl"),
        include_bytes!("../src/gpu/ap1_scene_radial.wgsl"),
        include_bytes!("../src/gpu/ap1_scene_parallel.wgsl"),
        include_bytes!("ap1_scene_probe.rs"),
    ];
    for bytes in files {
        digest.update((bytes.len() as u64).to_le_bytes());
        digest.update(bytes);
    }
    digest.update(RGB_SCALED_TOLERANCE.to_bits().to_le_bytes());
    format!("{:x}", digest.finalize())
}

fn read_ap1(path: &Path, region: Region) -> Result<(Vec<Pixel>, String)> {
    let size = region.pixel_count() * 16;
    let file = File::open(path)?;
    if file.metadata()?.len() != size as u64 {
        return Err(format!(
            "{} must contain exactly {size} bytes of packed RGBA F32 LE",
            path.display()
        )
        .into());
    }
    let mut bytes = Vec::with_capacity(size);
    file.take(size as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() != size {
        return Err(format!("{} changed size while reading", path.display()).into());
    }
    let digest = sha256(&bytes);
    let pixels: Vec<_> = bytes
        .chunks_exact(16)
        .map(|pixel| {
            std::array::from_fn(|channel| {
                f32::from_le_bytes(pixel[channel * 4..channel * 4 + 4].try_into().unwrap())
            })
        })
        .collect();
    region.validate_pixels(&pixels)?;
    Ok((pixels, digest))
}

fn write_ap1(path: &Path, pixels: &[Pixel]) -> Result<String> {
    let mut output = BufWriter::new(File::create_new(path)?);
    let mut digest = Sha256::new();
    for pixel in pixels {
        let mut bytes = [0; 16];
        for (channel, value) in pixel.iter().enumerate() {
            bytes[channel * 4..channel * 4 + 4].copy_from_slice(&value.to_le_bytes());
        }
        output.write_all(&bytes)?;
        digest.update(bytes);
    }
    output.flush()?;
    Ok(format!("{:x}", digest.finalize()))
}

fn compare(actual: &[Pixel], expected: &[Pixel], region: Region, bit_exact: bool) -> Value {
    assert_eq!(actual.len(), expected.len());
    let mut max_abs = 0f64;
    let mut max_scaled = 0f64;
    let mut bit_mismatches = [0u32; 4];
    let mut mismatched = 0;
    let mut worst = None;
    let mut first_failure = None;
    for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
        let mut pixel_differs = false;
        for channel in 0..4 {
            let (actual, expected) = (actual[channel], expected[channel]);
            let differs = actual.to_bits() != expected.to_bits();
            bit_mismatches[channel] += u32::from(differs);
            let error = (f64::from(actual) - f64::from(expected)).abs();
            let scaled = error / f64::from(expected.abs().max(1.0));
            let sample = (index, channel, actual, expected);
            if channel != 3 {
                max_abs = max_abs.max(error);
                if scaled > max_scaled {
                    max_scaled = scaled;
                    worst = Some(sample);
                }
            }
            let exceeds_tolerance = if bit_exact || channel == 3 {
                differs
            } else {
                scaled > RGB_SCALED_TOLERANCE
            };
            if exceeds_tolerance {
                pixel_differs = true;
                first_failure.get_or_insert(sample);
            }
        }
        mismatched += u32::from(pixel_differs);
    }
    let witness = |(index, channel, actual, expected): (usize, usize, f32, f32)| {
        let width = region.extent()[0] as usize;
        let [x, y] = region.origin();
        let channel_name = ["r", "g", "b", "a"][channel];
        json!({"pixelIndex":index,"x":x as usize + index % width,"y":y as usize + index / width,
            "channel":channel_name,"actual":actual,"reference":expected,
            "actualBits":actual.to_bits(),"referenceBits":expected.to_bits()})
    };
    json!({
        "passed":mismatched == 0, "pixels":actual.len(), "maxAbsRGB":max_abs, "maxScaledRGB":max_scaled,
        "mode":if bit_exact {BIT_COMPARISON} else {"scaled-rgb-exact-alpha"},
        "rgbScaledTolerance":(!bit_exact).then_some(RGB_SCALED_TOLERANCE),
        "alphaBitMismatches":bit_mismatches[3],"bitMismatchesRGBA":bit_mismatches,"mismatchedPixels":mismatched,
        "worstScaledRGB":worst.map(witness),"firstFailure":first_failure.map(witness),
    })
}

fn passed(comparison: &Value) -> bool {
    comparison["passed"] == true
}

struct ReferenceFrame {
    sha256: String,
    steps: Option<usize>,
}

struct ReferenceSet {
    directory: PathBuf,
    proof_sha256: String,
    frames: HashMap<String, ReferenceFrame>,
}

impl ReferenceSet {
    fn load(&self, file: &str, region: Region, steps: usize) -> Result<(Vec<Pixel>, String)> {
        let frame = self
            .frames
            .get(file)
            .ok_or_else(|| format!("missing reference entry for {file}"))?;
        if frame.steps.is_some_and(|expected| expected != steps) {
            return Err(
                format!("peer frame {file} reports different lowered operator steps").into(),
            );
        }
        let path = self.directory.join(file);
        let (pixels, digest) = read_ap1(&path, region)?;
        if digest != frame.sha256 {
            return Err(format!("reference SHA-256 mismatch for {}", path.display()).into());
        }
        Ok((pixels, digest))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyManifest {
    schema_version: u32,
    port: String,
    photo_dimensions: [u32; 2],
    roi: [u32; 4],
    #[serde(rename = "monitorID")]
    monitor_id: String,
    legacy_executor: String,
    #[serde(rename = "inputSHA256")]
    input_sha256: String,
    #[serde(rename = "graphSHA256")]
    graph_sha256: String,
    #[serde(rename = "calibrationSHA256")]
    calibration_sha256: String,
    #[serde(rename = "sourceSHA256")]
    source_sha256: String,
    #[serde(rename = "legacyOutputSHA256")]
    output_sha256: HashMap<String, String>,
}

fn set_provenance(declared: &mut Option<String>, field: &str, from_manifest: String) -> Result<()> {
    let from_manifest = normalize_digest(from_manifest)?;
    if declared
        .as_ref()
        .is_some_and(|expected| expected != &from_manifest)
    {
        return Err(format!("declared {field} differs from the 039 manifest").into());
    }
    *declared = Some(from_manifest);
    Ok(())
}

fn load_legacy(args: &mut Args, graph: &str, ap1: &str) -> Result<Option<ReferenceSet>> {
    let Some(directory) = &args.legacy else {
        return Ok(None);
    };
    let path = args
        .legacy_manifest
        .clone()
        .map_or_else(|| directory.join("../manifest.json"), |explicit| explicit);
    let bytes = fs::read(&path)?;
    let manifest: LegacyManifest = serde_json::from_slice(&bytes)?;
    if manifest.schema_version != 1
        || manifest.legacy_executor != "039 Rust Metal"
        || manifest.port != "AP1 premultiplied RGBA F32LE"
        || manifest.input_sha256 != ap1
        || manifest.graph_sha256 != graph
        || manifest.photo_dimensions != args.full
        || manifest.roi != args.roi
        || manifest.monitor_id != args.monitor
        || manifest.output_sha256.len() != FRAME_FILES.len()
    {
        return Err("039 manifest differs from the selected input, graph, geometry, monitor or reference format".into());
    }
    let calibration_path = path.with_file_name("calibration.json");
    let calibration = sha256(&fs::read(calibration_path)?);
    if calibration != manifest.calibration_sha256 {
        return Err("039 calibration.json SHA-256 differs from its manifest".into());
    }
    set_provenance(
        &mut args.source_sha256,
        "source SHA-256",
        manifest.source_sha256,
    )?;
    set_provenance(
        &mut args.calibration_sha256,
        "calibration SHA-256",
        calibration,
    )?;
    let mut frames = HashMap::new();
    for file in FRAME_FILES {
        let known = manifest
            .output_sha256
            .get(file)
            .ok_or_else(|| format!("039 manifest lacks {file}"))?;
        frames.insert(
            file.into(),
            ReferenceFrame {
                sha256: normalize_digest(known.clone())?,
                steps: None,
            },
        );
    }
    Ok(Some(ReferenceSet {
        directory: directory.clone(),
        proof_sha256: sha256(&bytes),
        frames,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Executor {
    Wgpu,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Outcome {
    Passed,
    Failed,
}

#[derive(Deserialize)]
enum PhysicalDevice {
    IntegratedGpu,
    DiscreteGpu,
}

#[derive(Deserialize)]
struct PeerAdapter {
    #[serde(rename = "type")]
    _physical_type: PhysicalDevice,
    backend: Backend,
}

#[derive(Deserialize)]
struct ReportedRegion {
    full: [u32; 2],
    origin: [u32; 2],
    extent: [u32; 2],
}

impl ReportedRegion {
    fn matches(&self, expected: Region) -> Result<bool> {
        Ok(Region::new(self.full, self.origin, self.extent)? == expected)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PeerReceipt {
    #[serde(rename = "graphicsAPI")]
    graphics_api: Backend,
    #[serde(rename = "executor")]
    _executor: Executor,
    fallback_count: u32,
    region: ReportedRegion,
    nodes: usize,
    dispatches: u32,
}

#[derive(Deserialize)]
struct PeerFrame {
    artifact: String,
    sha256: String,
    receipt: PeerReceipt,
}

impl PeerFrame {
    fn validate(self, file: &str, backend: Backend, region: Region) -> Result<ReferenceFrame> {
        if self.artifact != file
            || self.receipt.graphics_api != backend
            || self.receipt.fallback_count != 0
            || self.receipt.dispatches != 1
            || !self.receipt.region.matches(region)?
        {
            return Err(format!("peer frame has an incompatible receipt for {file}").into());
        }
        Ok(ReferenceFrame {
            sha256: normalize_digest(self.sha256)?,
            steps: Some(self.receipt.nodes),
        })
    }
}

#[derive(Deserialize)]
struct PeerCropMatch {
    mode: String,
    passed: bool,
}

#[derive(Deserialize)]
struct PeerRoot {
    full: PeerFrame,
    roi: PeerFrame,
    #[serde(rename = "roiVsWgpuFullCrop")]
    crop_match: PeerCropMatch,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PeerReport {
    schema_version: u32,
    outcome: Outcome,
    #[serde(rename = "graphicsAPI")]
    graphics_api: Backend,
    #[serde(rename = "executor")]
    _executor: Executor,
    adapter: PeerAdapter,
    fallback_count: u32,
    physical_adapter: bool,
    #[serde(rename = "ap1SHA256")]
    ap1_sha256: String,
    #[serde(rename = "graphSHA256")]
    graph_sha256: String,
    #[serde(rename = "sourceSHA256")]
    source_sha256: Option<String>,
    #[serde(rename = "calibrationSHA256")]
    calibration_sha256: Option<String>,
    #[serde(rename = "cargoLockSHA256")]
    cargo_lock_sha256: String,
    #[serde(rename = "engineSourceSHA256")]
    engine_source_sha256: String,
    monitor_node: String,
    full: ReportedRegion,
    roi: ReportedRegion,
    #[serde(rename = "final")]
    final_root: PeerRoot,
    monitor: PeerRoot,
}

struct FrameResult {
    pixels: Vec<Pixel>,
    report: Value,
    passed: bool,
}

struct Probe<'a> {
    args: &'a Args,
    device: SceneDevice,
    legacy: Option<ReferenceSet>,
    peer: Option<ReferenceSet>,
}

impl Probe<'_> {
    fn run_frame(
        &mut self,
        file: &str,
        prepared: &Prepared,
        program: &Program,
        region: Region,
        input: &[Pixel],
    ) -> Result<FrameResult> {
        let started = Instant::now();
        let expected = render_cpu(prepared, region, input)?;
        let cpu_wall_ns = started.elapsed().as_nanos();
        let (pixels, receipt) =
            self.device
                .render(program, prepared, region, input, self.args.budget)?;
        let digest = write_ap1(&self.args.output.join(file), &pixels)?;
        let cpu = compare(&pixels, &expected, region, false);
        let mut good = passed(&cpu);
        let mut report = json!({"artifact":file,"sha256":digest,"cpuWallNs":cpu_wall_ns,
            "receipt":receipt,"wgpuVsCpu":cpu});
        for (key, references) in [
            ("wgpuVsLegacy039", &self.legacy),
            ("wgpuVsPeer", &self.peer),
        ] {
            if let Some(references) = references {
                let (reference, digest) =
                    references.load(file, region, prepared.plan().step_count())?;
                let mut parity = compare(&pixels, &reference, region, false);
                parity["referenceSHA256"] = json!(digest);
                good &= passed(&parity);
                report[key] = parity;
            }
        }
        Ok(FrameResult {
            pixels,
            report,
            passed: good,
        })
    }

    fn run_root(
        &mut self,
        name: &str,
        root: Root<'_>,
        graph: &[u8],
        full: Region,
        roi: Region,
        input: &[Pixel],
        cropped: &[Pixel],
    ) -> Result<(Value, bool)> {
        let started = Instant::now();
        let prepared = Prepared::from_039(graph, root)?;
        let prepare_ns = started.elapsed().as_nanos();
        let started = Instant::now();
        let program = self.device.compile(prepared.plan())?;
        let compile_ns = started.elapsed().as_nanos();
        let large = self.run_frame(
            &format!("{name}-full.rgba32f"),
            &prepared,
            &program,
            full,
            input,
        )?;
        let small = self.run_frame(
            &format!("{name}-roi.rgba32f"),
            &prepared,
            &program,
            roi,
            cropped,
        )?;
        let crop_consistency = compare(&small.pixels, &roi.crop(&large.pixels)?, roi, true);
        let good = large.passed && small.passed && passed(&crop_consistency);
        Ok((
            json!({"plan":prepared.plan(),"loweredOperatorSteps":prepared.plan().step_count(),
            "parameterSHA256":sha256(&serde_json::to_vec(prepared.parameters())?),
            "shaderSHA256":sha256(program.shader().as_bytes()),"prepareWallNs":prepare_ns,"compileWallNs":compile_ns,
            "full":large.report,"roi":small.report,"roiVsWgpuFullCrop":crop_consistency}),
            good,
        ))
    }
}

fn command_output(command: &mut Command) -> Option<String> {
    let output = command.output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn load_peer(
    args: &Args,
    graph: &str,
    ap1: &str,
    full: Region,
    roi: Region,
) -> Result<Option<ReferenceSet>> {
    let Some(directory) = &args.peer else {
        return Ok(None);
    };
    let bytes = fs::read(directory.join("report.json"))?;
    let peer: PeerReport = serde_json::from_slice(&bytes)?;
    let opposite = match args.backend {
        Backend::Metal => Backend::Vulkan,
        Backend::Vulkan => Backend::Metal,
    };
    if peer.schema_version != 1
        || !matches!(peer.outcome, Outcome::Passed)
        || peer.graphics_api != opposite
        || peer.adapter.backend != opposite
        || peer.fallback_count != 0
        || !peer.physical_adapter
        || peer.graph_sha256 != graph
        || peer.ap1_sha256 != ap1
        || peer.monitor_node != args.monitor
        || !peer.full.matches(full)?
        || !peer.roi.matches(roi)?
        || peer.source_sha256 != args.source_sha256
        || peer.calibration_sha256 != args.calibration_sha256
        || peer.cargo_lock_sha256 != sha256(include_bytes!("../Cargo.lock"))
        || peer.engine_source_sha256 != engine_source_sha256()
    {
        return Err("peer run differs in backend, fallback, input, graph, monitor, region, provenance, build sources or outcome".into());
    }
    for root in [&peer.final_root, &peer.monitor] {
        if root.crop_match.mode != BIT_COMPARISON || !root.crop_match.passed {
            return Err("peer report lacks passing bit-exact ROI evidence".into());
        }
    }
    let mut frames = HashMap::new();
    for (file, receipt, region) in [
        (FRAME_FILES[0], peer.final_root.full, full),
        (FRAME_FILES[1], peer.final_root.roi, roi),
        (FRAME_FILES[2], peer.monitor.full, full),
        (FRAME_FILES[3], peer.monitor.roi, roi),
    ] {
        frames.insert(file.into(), receipt.validate(file, opposite, region)?);
    }
    Ok(Some(ReferenceSet {
        directory: directory.clone(),
        proof_sha256: sha256(&bytes),
        frames,
    }))
}

fn main() -> Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--help") {
        println!("{USAGE}");
        println!("Optional flags: --adapter EXACT_NAME --legacy-dir DIR --legacy-manifest PATH --peer-dir DIR --source-sha256 HEX --calibration-sha256 HEX --budget-bytes BYTES");
        return Ok(());
    }
    let mut args = Args::parse().map_err(|error| format!("{error}\n{USAGE}"))?;
    let full = Region::new(args.full, [0, 0], args.full)?;
    let [x, y, width, height] = args.roi;
    let roi = Region::new(args.full, [x, y], [width, height])?;
    if [x, y] == [0, 0] {
        return Err("the comparison ROI needs a nonzero origin".into());
    }
    let graph = fs::read(&args.graph)?;
    let (_, scope) = parse(&graph)?;
    if scope.output == Endpoint::Node(args.monitor.clone()) {
        return Err("the monitor node must differ from the frozen final root".into());
    }
    let graph_digest = sha256(&graph);
    let (input, input_digest) = read_ap1(&args.input, full)?;
    let cropped = roi.crop(&input)?;
    let legacy = load_legacy(&mut args, &graph_digest, &input_digest)?;
    let peer = load_peer(&args, &graph_digest, &input_digest, full, roi)?;
    let started = Instant::now();
    let device = SceneDevice::open(args.backend, args.adapter.as_deref())?;
    let open_ns = started.elapsed().as_nanos();
    fs::create_dir(&args.output)?;
    let mut probe = Probe {
        args: &args,
        device,
        legacy,
        peer,
    };
    let (final_report, final_ok) =
        probe.run_root("final", Root::Final, &graph, full, roi, &input, &cropped)?;
    let (monitor_report, monitor_ok) = probe.run_root(
        "monitor",
        Root::Monitor(&args.monitor),
        &graph,
        full,
        roi,
        &input,
        &cropped,
    )?;
    let info = probe.device.adapter();
    let limits = probe.device.limits();
    let source_commit = command_output(
        Command::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(env!("CARGO_MANIFEST_DIR")),
    );
    let source_dirty = command_output(
        Command::new("git")
            .args(["status", "--porcelain"])
            .current_dir(env!("CARGO_MANIFEST_DIR")),
    )
    .map(|value| !value.is_empty());
    let ok = final_ok && monitor_ok;
    let report = json!({
        "schemaVersion":1,"outcome":if ok {"passed"} else {"failed"},
        "executor":"wgpu","graphicsAPI":args.backend,"fallbackCount":0,"physicalAdapter":true,
        "adapter":{"name":info.name,"type":format!("{:?}",info.device_type),"vendor":info.vendor,"device":info.device,
            "driver":info.driver,"driverInfo":info.driver_info,"backend":args.backend},
        "limits":{"maxStorageBufferBindingSize":limits.max_storage_buffer_binding_size,
            "maxBufferSize":limits.max_buffer_size,"maxComputeInvocationsPerWorkgroup":limits.max_compute_invocations_per_workgroup,
            "maxComputeWorkgroupsPerDimension":limits.max_compute_workgroups_per_dimension},
        "platform":{"os":std::env::consts::OS,"arch":std::env::consts::ARCH,
            "kernel":command_output(Command::new("uname").arg("-srv")),
            "macOSBuild":if cfg!(target_os="macos") {command_output(Command::new("sw_vers").arg("-buildVersion"))} else {None}},
        "build":{"probeSHA256":sha256(&fs::read(std::env::current_exe()?)?),
            "sourceCommitAtRun":source_commit,"sourceDirtyAtRun":source_dirty,"crateVersion":env!("CARGO_PKG_VERSION")},
        "cargoLockSHA256":sha256(include_bytes!("../Cargo.lock")),
        "engineSourceSHA256":engine_source_sha256(),
        "ap1Port":AP1_PORT,"ap1SHA256":input_digest,"graphSHA256":graph_digest,
        "sourceSHA256":args.source_sha256,"calibrationSHA256":args.calibration_sha256,
        "legacyManifestSHA256":probe.legacy.as_ref().map(|reference| &reference.proof_sha256),
        "peerReportSHA256":probe.peer.as_ref().map(|reference| &reference.proof_sha256),
        "full":full,"roi":roi,"monitorNode":args.monitor,"deviceOpenWallNs":open_ns,
        "operators":OPERATORS,"frozenDocumentNodes":scope.nodes.len(),"final":final_report,"monitor":monitor_report,
        "measurement":{"memory":"accounted bound buffers; no driver or process peak",
            "gpuClock":"unavailable; host completion and readback wall intervals",
            "transport":"CPU-uploaded buffers; no native texture borrow","legacyCompared":args.legacy.is_some(),
            "peerCompared":args.peer.is_some()},
    });
    let path = args.output.join("report.json");
    serde_json::to_writer_pretty(File::create_new(&path)?, &report)?;
    println!("{}", path.display());
    if !ok {
        return Err("AP1 parity tolerance exceeded; inspect report.json".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bit_exact_roi_rejects_signed_zero_and_locates_the_difference() {
        let region = Region::new([8, 8], [3, 5], [1, 1]).unwrap();
        let actual = [[-0.0, 0.75, 2.0, 0.5]];
        let expected = [[0.0, 0.75, 2.0, 0.5]];
        assert!(passed(&compare(&actual, &expected, region, false)));
        let exact = compare(&actual, &expected, region, true);
        assert!(!passed(&exact));
        assert_eq!(exact["bitMismatchesRGBA"], json!([1, 0, 0, 0]));
        assert_eq!(exact["firstFailure"]["x"], 3);
        assert_eq!(exact["firstFailure"]["y"], 5);
        assert_eq!(exact["firstFailure"]["channel"], "r");
    }

    #[test]
    fn peer_frame_requires_the_claimed_backend_executor_and_zero_fallback() {
        let region = Region::new([8, 8], [3, 5], [1, 1]).unwrap();
        let file = FRAME_FILES[1];
        let mut frame = json!({"artifact":file,"sha256":"a".repeat(64),
            "receipt":{"executor":"wgpu","graphicsAPI":"metal","fallbackCount":0,
                "region":region,"nodes":5,"dispatches":1}});
        let decode = |value: &Value| serde_json::from_value::<PeerFrame>(value.clone());
        assert!(decode(&frame)
            .unwrap()
            .validate(file, Backend::Metal, region)
            .is_ok());
        assert!(decode(&frame)
            .unwrap()
            .validate(file, Backend::Vulkan, region)
            .is_err());
        frame["receipt"]["fallbackCount"] = json!(1);
        assert!(decode(&frame)
            .unwrap()
            .validate(file, Backend::Metal, region)
            .is_err());
        frame["receipt"]["executor"] = json!("cpu");
        assert!(decode(&frame).is_err());
    }
}
