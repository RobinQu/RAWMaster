use rawmaster_image::{render_cpu, FilterBinding, Frame, Pixel, Plan};
use serde_json::json;
use std::{
    fs,
    path::{Path, PathBuf},
};

const LOOKS: [&str; 12] = [
    "vivid",
    "vividWarm",
    "vividCool",
    "dramatic",
    "dramaticWarm",
    "dramaticCool",
    "mono",
    "silvertone",
    "noir",
    "spektraPortra400Endura",
    "spektraVelvia100",
    "spektraVision250D2383",
];
const PIXELS: [Pixel; 6] = [
    [0.0; 4],
    [0.000001, 0.000002, 0.00001, 0.00001],
    [0.0625, 0.2, 0.18, 0.25],
    [-0.25, 1.2, 0.7, 0.5],
    [1.0, 0.0, 1.0, 1.0],
    [0.039, 0.42, 0.0031308, 1.0],
];
fn root() -> PathBuf {
    std::env::var_os("RAWMASTER_TEST_FILTERS")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../Sources/RAWMasterImaging/Resources/PhotoFilters")
        })
}
fn filter(look: &str, amount: f64, repair: bool) -> String {
    json!({"version":1,"working":"extended-linear-srgb-premul-f32","output":"f","nodes":[
        {"id":"f","op":"photo_filter","image":"s","look":look,"amount":amount,"repairRawAlpha":repair},{"id":"s","op":"source"}]}).to_string()
}
fn plan(look: &str, amount: f64, repair: bool) -> Plan {
    Plan::parse_with_resources(&filter(look, amount, repair), Some(&root())).unwrap()
}
fn plane(look: &str, level: u32) -> Vec<u8> {
    let root = root();
    let directory = if look.starts_with("spektra") {
        root.join("Spektrafilm")
    } else {
        root
    };
    fs::read(directory.join(format!("{look}-{level:03}.delta64.rgba32f"))).unwrap()
}

// Independent double-precision oracle: locate each bounding axis coordinate by binary search,
// weight eight stored float nodes, then interpolate endpoint results in control space.
fn reference(
    look: &str,
    amount: f64,
    pixel: Pixel,
    lo: u32,
    hi: u32,
    lower: &[u8],
    upper: &[u8],
) -> Pixel {
    let p = pixel.map(f64::from);
    let alpha = p[3];
    if amount == 0.0 || pixel[3] < 1.0 / 65535.0 {
        return pixel;
    }
    let rgb = [p[0] / alpha, p[1] / alpha, p[2] / alpha];
    let bounded = rgb.map(|v| v.clamp(0.0, 1.0));
    let axes: [f64; 64] = std::array::from_fn(|i| ((65535 * i + 31) / 63) as f64 / 65535.0);
    let cell = bounded.map(|v| {
        let q = if v <= 0.0031308 {
            12.92 * v
        } else {
            1.055 * v.powf(1.0 / 2.4) - 0.055
        };
        let i = axes
            .partition_point(|&axis| axis <= q)
            .saturating_sub(1)
            .min(62);
        (i, (q - axes[i]) / (axes[i + 1] - axes[i]))
    });
    let sample = |table: &[u8], c: usize| {
        if table.is_empty() {
            return 0.0;
        }
        (0..8)
            .map(|corner| {
                let mut weight = 1.0;
                let mut address = 0;
                for (dim, (i, t)) in cell.iter().enumerate() {
                    let bit = (corner >> dim) & 1;
                    weight *= if bit == 1 { *t } else { 1.0 - t };
                    address += (i + bit) << (dim * 6);
                }
                let byte = 16 * address + 4 * c;
                weight
                    * f64::from(f32::from_le_bytes(
                        table[byte..byte + 4].try_into().unwrap(),
                    ))
            })
            .sum()
    };
    let t = if lo == hi {
        1.0
    } else {
        (amount - f64::from(lo)) / f64::from(hi - lo)
    };
    let delta: [f64; 3] =
        std::array::from_fn(|c| (1.0 - t) * sample(lower, c) + t * sample(upper, c));
    let mut out: [f64; 3] = std::array::from_fn(|c| rgb[c] + delta[c]);
    if matches!(look, "mono" | "noir") && rgb != bounded {
        let residual: [f64; 3] = std::array::from_fn(|c| rgb[c] - bounded[c]);
        let luma = |v: [f64; 3]| v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722;
        out = std::array::from_fn(|c| {
            bounded[c]
                + delta[c]
                + (1.0 - amount / 100.0) * residual[c]
                + amount / 100.0 * luma(residual)
        });
        if amount == 100.0 {
            out = [luma(out); 3];
        }
    }
    [
        (out[0] * alpha) as f32,
        (out[1] * alpha) as f32,
        (out[2] * alpha) as f32,
        pixel[3],
    ]
}
fn verify(look: &str, amount: f64, actual: &[Pixel]) -> f32 {
    let stops: &[u32] = if look.starts_with("spektra") {
        &[0, 100]
    } else {
        &[0, 1, 25, 50, 100]
    };
    let lo = *stops
        .iter()
        .rev()
        .find(|&&p| f64::from(p) <= amount)
        .unwrap();
    let hi = *stops.iter().find(|&&p| f64::from(p) >= amount).unwrap();
    let lower = if lo > 0 && lo != hi {
        plane(look, lo)
    } else {
        vec![]
    };
    let upper = plane(look, hi);
    let mut max = 0.0_f32;
    for (&input, &actual) in PIXELS.iter().zip(actual) {
        let expected = reference(look, amount, input, lo, hi, &lower, &upper);
        for channel in 0..3 {
            max = max.max((actual[channel] - expected[channel]).abs());
        }
        assert_eq!(actual[3].to_bits(), input[3].to_bits());
        if input[3] < 1.0 / 65535.0 {
            assert_eq!(actual, input);
        }
        if matches!(look, "mono" | "noir") && amount == 100.0 && input[0] < 0.0 {
            assert_eq!(actual[0], actual[1]);
            assert_eq!(actual[1], actual[2]);
        }
    }
    assert!(max < 2e-4, "{look} at {amount}: {max}");
    max
}
#[test]
fn fixed_abi_boundaries_preserve_double_endpoint_intent() {
    assert_eq!(std::mem::size_of::<FilterBinding>(), 24);
    for (family, amount, lo, hi, w) in [
        (0, 0.0, 0, 0, 0.0),
        (0, 0.5, 0, 1, 0.5),
        (0, 1.0, 1, 1, 0.0),
        (0, 37.5, 25, 50, 0.5),
        (0, 100.0, 100, 100, 0.0),
        (2, 0.5, 0, 100, 0.005),
        (2, 100.0, 100, 100, 0.0),
    ] {
        let b = FilterBinding::new(family, amount, 1).unwrap();
        assert_eq!(
            (b.low_percent, b.high_percent, b.weight, b.repair_raw_alpha),
            (lo, hi, w, 1)
        );
        assert_eq!(b.normalized_amount, (amount / 100.0) as f32);
    }
    assert_eq!(FilterBinding::new(1, 100.0, 0).unwrap().hdr_mode, 2);
    assert_eq!(
        FilterBinding::new(1, f64::from_bits(100.0f64.to_bits() - 1), 0)
            .unwrap()
            .hdr_mode,
        1
    );
    for args in [
        (0, f64::NAN, 0),
        (1, 100.01, 0),
        (2, -1.0, 1),
        (3, 0.0, 0),
        (0, 0.0, 2),
    ] {
        assert!(FilterBinding::new(args.0, args.1, args.2).is_err());
    }
}
#[test]
fn all_shipped_looks_and_planes_match_stored_float_nodes() {
    let frame = Frame::new(6, 1, &PIXELS, &[]).unwrap();
    let mut maximum = 0.0_f32;
    for (look, amount) in LOOKS.into_iter().map(|look| (look, 100.0)).chain([
        ("vivid", 0.5),
        ("vivid", 1.0),
        ("vivid", 13.0),
        ("vivid", 25.0),
        ("vivid", 37.5),
        ("vivid", 50.0),
        ("vivid", 75.0),
        ("mono", 99.9999999),
        ("spektraVelvia100", 0.5),
    ]) {
        let result = render_cpu(&plan(look, amount, false), &frame).unwrap();
        maximum = maximum.max(verify(look, amount, &result));
    }
    println!("12 release looks / 21 amounts / CPU against double oracle maxAbs={maximum}");
}
#[test]
fn raw_alpha_repair_is_explicit_and_limited_to_three_ulps() {
    let root = root();
    let repaired = plan("mono", 37.0, true);
    let strict = plan("mono", 37.0, false);
    let original = [0.07, 0.21, 0.7, 1.0];
    let expected = render_cpu(&repaired, &Frame::new(1, 1, &[original], &[]).unwrap()).unwrap();
    for offset in 1..=3 {
        let pixels = [[
            original[0],
            original[1],
            original[2],
            f32::from_bits(1.0f32.to_bits() + offset),
        ]];
        assert!(Frame::new(1, 1, &pixels, &[]).is_err());
        let input = Frame::with_transport(1, 1, &pixels, &[], true).unwrap();
        assert_eq!(render_cpu(&repaired, &input).unwrap(), expected);
        assert!(render_cpu(&strict, &input).is_err());
    }
    assert!(Frame::with_transport(
        1,
        1,
        &[[0.1, 0.2, 0.3, f32::from_bits(1.0f32.to_bits() + 4)]],
        &[],
        true
    )
    .is_err());
    assert!(Plan::parse(&filter("vivid", 1.0, false)).is_err());
    assert!(Plan::parse(&filter("vivid", 0.0, false)).is_ok());
    assert!(Plan::parse(&filter("original", 25.0, true)).is_ok());
    assert!(Plan::parse_with_resources(&filter("unknown", 0.0, false), Some(&root)).is_err());
}
#[test]
fn masked_exposure_uses_ev_times_frozen_coverage() {
    let recipe=json!({"version":1,"working":"extended-linear-srgb-premul-f32","output":"x","nodes":[{"id":"x","op":"masked_exposure","image":"s","mask":"m","ev":2},{"id":"s","op":"source"},{"id":"m","op":"mask"}]}).to_string();
    let p = [-0.25, 0.125, 1.5, 0.5];
    let pixels = [p; 3];
    let graph = Plan::parse(&recipe).unwrap();
    assert!(render_cpu(&graph, &Frame::new(3, 1, &pixels, &[]).unwrap()).is_err());
    let result = render_cpu(
        &graph,
        &Frame::new(3, 1, &pixels, &[0.0, 0.5, 1.0]).unwrap(),
    )
    .unwrap();
    for (i, gain) in [1.0, 2.0, 4.0].into_iter().enumerate() {
        assert_eq!(result[i], [p[0] * gain, p[1] * gain, p[2] * gain, p[3]]);
    }
}
#[test]
fn a_plan_pins_verified_planes_and_rejects_missing_or_modified_resources() {
    use sha2::{Digest, Sha256};
    use std::time::{SystemTime, UNIX_EPOCH};
    let serial = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory =
        std::env::temp_dir().join(format!("rawmaster-image-{}-{serial}", std::process::id()));
    fs::create_dir(&directory).unwrap();
    struct Temp(PathBuf);
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Temp(directory.clone());
    let recipe = filter("vivid", 100.0, false);
    let name = "vivid-100.delta64.rgba32f";
    let manifest = directory.join("catalog-v1.json");
    fs::copy(root().join("catalog-v1.json"), &manifest).unwrap();
    assert!(Plan::parse_with_resources(&recipe, Some(&directory)).is_err());
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(root().join(name), directory.join(name)).unwrap();
        assert!(Plan::parse_with_resources(&recipe, Some(&directory)).is_err());
        fs::remove_file(directory.join(name)).unwrap();
    }
    fs::copy(root().join(name), directory.join(name)).unwrap();
    let graph = Plan::parse_with_resources(&recipe, Some(&directory)).unwrap();
    let frame = Frame::new(6, 1, &PIXELS, &[]).unwrap();
    let expected = render_cpu(&graph, &frame).unwrap();
    let mut bytes = fs::read(directory.join(name)).unwrap();
    bytes[12..16].copy_from_slice(&0.0f32.to_le_bytes());
    fs::write(directory.join(name), &bytes).unwrap();
    assert!(Plan::parse_with_resources(&recipe, Some(&directory)).is_err());
    let mut catalog: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest).unwrap()).unwrap();
    let look = catalog["looks"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|l| l["id"] == "vivid")
        .unwrap();
    let plane = look["planes"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|p| p["file"] == name)
        .unwrap();
    plane["sha256"] = format!("{:x}", Sha256::digest(&bytes)).into();
    fs::write(&manifest, serde_json::to_vec(&catalog).unwrap()).unwrap();
    assert!(Plan::parse_with_resources(&recipe, Some(&directory)).is_err());
    assert_eq!(render_cpu(&graph, &frame).unwrap(), expected);
}
#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires an actual Metal or Vulkan adapter"]
fn real_device_matches_shipped_looks_and_rejects_stale_atlases() {
    use rawmaster_image::gpu::{Gpu, Mode};
    let gpu = Gpu::open().unwrap();
    let frame = Frame::new(6, 1, &PIXELS, &[]).unwrap();
    let mut maximum = 0.0_f32;
    for look in LOOKS {
        let graph = plan(look, 100.0, false);
        let program = gpu.compile(&graph, Mode::Fused).unwrap();
        let (pixels, _) = gpu
            .render_bounded(&program, &graph, &frame, 16 << 20)
            .unwrap();
        maximum = maximum.max(verify(look, 100.0, &pixels));
    }
    let graph = plan("noir", 37.5, false);
    let program = gpu.compile(&graph, Mode::Staged).unwrap();
    let resident = gpu.bind(&program, &graph, &frame).unwrap();
    resident.submit();
    maximum = maximum.max(verify("noir", 37.5, &resident.read().unwrap()));
    let raw = plan("vivid", 37.5, true);
    let raw_program = gpu.compile(&raw, Mode::Fused).unwrap();
    for offset in 1..=3 {
        let rgb = [[-0.2, 0.125, 1.2, f32::from_bits(1.0f32.to_bits() + offset)]];
        let frame = Frame::with_transport(1, 1, &rgb, &[], true).unwrap();
        let pixels = gpu
            .render_bounded(&raw_program, &raw, &frame, 16 << 20)
            .unwrap()
            .0;
        assert_eq!(pixels[0][3], 1.0);
        let direct = render_cpu(&raw, &frame).unwrap();
        assert!((0..3).all(|c| (direct[0][c] - pixels[0][c]).abs() < 2e-5));
    }
    let other = plan("vivid", 37.5, false);
    assert!(resident.update(&other).is_err());
    assert!(gpu.bind(&program, &other, &frame).is_err());
    println!(
        "{} / 12 release looks / GPU against double oracle maxAbs={maximum}",
        gpu.adapter
    );
}
