use rawmaster_image::{render_cpu, CoveragePlane, Frame, Plan};
use serde_json::json;

fn wire(control: &str, amount: f64) -> serde_json::Value {
    json!({"version": 2, "working": "extended-linear-srgb-premul-f32", "output": "adjust",
        "nodes": [{"op":"mask_tone_v3","id":"adjust","image":"image","mask":"sky","control":control,"amount":amount},
                  {"op":"mask","id":"sky"},{"op":"source","id":"image"}]})
}

#[test]
fn accepts_only_one_named_control_at_its_original_precision() {
    for (name, min, max) in [
        ("exposure", -2.0, 2.0),
        ("highlights", -1.0, 1.0),
        ("shadows", -1.0, 1.0),
        ("saturation", -1.0, 1.0),
        ("contrast", -1.0, 2.0),
        ("whites", -1.0, 1.0),
        ("blacks", -2.0, 2.0),
        ("hue", -1.0, 1.0),
    ] {
        for endpoint in [min, max] {
            let plan = Plan::parse(&wire(name, endpoint).to_string()).unwrap();
            assert_eq!(plan.mask_ids(), &["sky"]);
        }
        assert!(Plan::parse(&wire(name, max + 1e-12).to_string()).is_err());
    }
    let mut invalid = wire("exposure", 2.0);
    let decimal = invalid
        .to_string()
        .replace("\"amount\":2.0", "\"amount\":2.0000000000000004");
    assert!(Plan::parse(&decimal).is_err());
    invalid["version"] = json!(1);
    assert!(Plan::parse(&invalid.to_string()).is_err());
    for (field, value) in [
        ("control", json!("grain")),
        ("amount", json!("0.5")),
        ("mask", json!("image")),
        ("image", json!("sky")),
        ("secondControl", json!("whites")),
    ] {
        let mut recipe = wire("exposure", 1.0);
        recipe["nodes"][0][field] = value;
        assert!(Plan::parse(&recipe.to_string()).is_err());
    }
}

#[test]
fn zero_coverage_and_neutral_amount_preserve_bits_and_fractional_coverage_enters_the_control() {
    let pixels = [
        [0.25, 0.25, 0.25, 1.0],
        [-0.0, 0.0, -0.0, 0.0],
        [-0.0, 0.5, 2.0, 1.0],
    ];
    let coverage = [0.5, 1.0, 0.0];
    let planes = [CoveragePlane {
        id: "sky",
        values: &coverage,
    }];
    let frame = Frame::with_named_coverage(3, 1, &pixels, &planes, false).unwrap();
    let p = Plan::parse(&wire("exposure", 1.0).to_string()).unwrap();
    let out = render_cpu(&p, &frame).unwrap();
    assert_eq!(out[0], [0.5, 0.5, 0.5, 1.0]);
    for i in 1..3 {
        assert_eq!(out[i].map(f32::to_bits), pixels[i].map(f32::to_bits));
    }
    let neutral = Plan::parse(&wire("hue", 0.0).to_string()).unwrap();
    assert_eq!(
        render_cpu(&neutral, &frame).unwrap().map_bits(),
        pixels.as_slice().map_bits()
    );
    let anonymous = Frame::new(3, 1, &pixels, &coverage).unwrap();
    assert!(render_cpu(&p, &anonymous).is_err());
    let src = [[f32::MAX, 1.0, 1.0, f32::MIN_POSITIVE]];
    let on = [CoveragePlane {
        id: "sky",
        values: &[1.0],
    }];
    let extreme = Frame::with_named_coverage(1, 1, &src, &on, false).unwrap();
    assert!(render_cpu(&p, &extreme).is_err());
}

const SUBNORMAL_PIXELS: [[u32; 4]; 6] = [
    [3, 5, 0x80000003, 1],
    [0x00400000, 0x003fffff, 0x80400000, 0x00400000],
    [0x007fffff, 0x807fffff, 0x007fffff, 0x007fffff],
    [0x00800000, 0x80800000, 0x01000000, 1],
    [0x34ffffff, 0x34ffffff, 0x34ffffff, 1],
    [0x7f7fffff, 1, 0x80000001, 1],
];
const SUBNORMAL_COVERAGE: [f32; 6] = [1.0, 1.0, 1.0, 1.0, 1.0, -0.0];
const TINY_COVERAGE: [f32; 1] = [f32::from_bits(1)];
const SUBNORMAL_HALF_EXPOSURE: [[u32; 4]; 6] = [
    [2, 2, 0x80000002, 1],
    [0x00200000, 0x00200000, 0x80200000, 0x00400000],
    [0x00400000, 0x80400000, 0x00400000, 0x007fffff],
    [0x00400000, 0x80400000, 0x00800000, 1],
    [0x347fffff, 0x347fffff, 0x347fffff, 1],
    SUBNORMAL_PIXELS[5],
];

#[test]
fn subnormal_alpha_preserves_f32_rounding_and_rejects_overflow() {
    let plan = Plan::parse(&wire("exposure", -0.5).to_string()).unwrap();
    let pixels = SUBNORMAL_PIXELS.map(|p| p.map(f32::from_bits));
    let mut coverage = [CoveragePlane {
        id: "sky",
        values: &SUBNORMAL_COVERAGE,
    }];
    let frame =
        Frame::with_named_coverage(pixels.len() as u32, 1, &pixels, &coverage, false).unwrap();
    assert_eq!(
        render_cpu(&plan, &frame).unwrap().map_bits(),
        SUBNORMAL_HALF_EXPOSURE
    );

    coverage[0].values = &TINY_COVERAGE;
    let frame = Frame::with_named_coverage(1, 1, &pixels[5..], &coverage, false).unwrap();
    assert!(render_cpu(&plan, &frame).is_err());
}

trait PixelBits {
    fn map_bits(&self) -> Vec<[u32; 4]>;
}
impl PixelBits for [[f32; 4]] {
    fn map_bits(&self) -> Vec<[u32; 4]> {
        self.iter().map(|p| p.map(f32::to_bits)).collect()
    }
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires a Metal or Vulkan adapter"]
fn gpu_mask_tone_handles_subnormal_alpha_in_fused_and_staged_programs() {
    use rawmaster_image::gpu::{Gpu, Mode};
    let gpu = Gpu::open().unwrap();
    let plan = Plan::parse(&wire("exposure", -0.5).to_string()).unwrap();
    let pixels = SUBNORMAL_PIXELS.map(|p| p.map(f32::from_bits));
    let mut coverage = [CoveragePlane {
        id: "sky",
        values: &SUBNORMAL_COVERAGE,
    }];
    let frame =
        Frame::with_named_coverage(pixels.len() as u32, 1, &pixels, &coverage, false).unwrap();
    coverage[0].values = &TINY_COVERAGE;
    let overflow = Frame::with_named_coverage(1, 1, &pixels[5..], &coverage, false).unwrap();
    let up = Plan::parse(&wire("exposure", 0.5).to_string()).unwrap();
    for mode in [Mode::Fused, Mode::Staged] {
        let program = gpu.compile(&plan, mode).unwrap();
        let resident = gpu.bind(&program, &plan, &frame).unwrap();
        resident.submit();
        assert_eq!(resident.read().unwrap().map_bits(), SUBNORMAL_HALF_EXPOSURE);
        assert_eq!(
            gpu.render_bounded(&program, &plan, &frame, 64 << 20)
                .unwrap()
                .0
                .map_bits(),
            SUBNORMAL_HALF_EXPOSURE
        );

        let edge = Frame::with_named_coverage(1, 1, &pixels[1..2], &coverage, false).unwrap();
        let edge = gpu.bind(&program, &up, &edge).unwrap();
        edge.submit();
        assert_eq!(edge.read().unwrap().map_bits(), [SUBNORMAL_PIXELS[1]]);

        let one = [CoveragePlane {
            id: "sky",
            values: &[1.0],
        }];
        let carry = Frame::with_named_coverage(1, 1, &pixels[1..2], &one, false).unwrap();
        let carry = gpu.bind(&program, &up, &carry).unwrap();
        carry.submit();
        assert_eq!(
            carry.read().unwrap().map_bits(),
            [[0x00800000, 0x007ffffe, 0x80800000, 0x00400000]]
        );

        let invalid = gpu.bind(&program, &plan, &overflow).unwrap();
        invalid.submit();
        assert!(invalid.read().is_err());
    }
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires a Metal or Vulkan adapter"]
fn masked_hue_matches_the_native_hdr_pixel() {
    use rawmaster_image::gpu::{Gpu, Mode};
    // Native linear F32 with frozen coverage 1 from a FlashRaw RGBA16F source.
    let pixels = [[0x3f940000, 0x3f292000, 0x3e608000, 0x3f800000].map(f32::from_bits)];
    let native = [0x3e607ffe, 0x3f4d0808, 0x3f93ffff, 0x3f800000].map(f32::from_bits);
    let mask = [CoveragePlane {
        id: "sky",
        values: &[1.0],
    }];
    let frame = Frame::with_named_coverage(1, 1, &pixels, &mask, false).unwrap();
    let plan = Plan::parse(&wire("hue", 0.45).to_string()).unwrap();
    let check = |pixel: [f32; 4]| {
        for (result, expected) in pixel.into_iter().zip(native) {
            assert!((result - expected).abs() <= 2e-6, "{result} vs {expected}");
        }
        assert_eq!(pixel[3].to_bits(), native[3].to_bits());
    };
    check(render_cpu(&plan, &frame).unwrap()[0]);
    let gpu = Gpu::open().unwrap();
    for mode in [Mode::Fused, Mode::Staged] {
        let program = gpu.compile(&plan, mode).unwrap();
        let resident = gpu.bind(&program, &plan, &frame).unwrap();
        resident.submit();
        check(resident.read().unwrap()[0]);
    }
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires a Metal or Vulkan adapter"]
fn frozen_tone_rebinds_each_control_on_the_same_fused_and_staged_program() {
    use rawmaster_image::gpu::{Gpu, Mode};
    let gpu = Gpu::open().unwrap();
    let coverage = [0.0, 0.5, 1.0, 0.17];
    let pixels = [
        [-0.0, 0.3, 1.2, 1.0],
        [0.24, 0.1, 0.15, 0.5],
        [0.2, 0.05, 0.12, 1.0],
        [0.0, 0.0, 0.0, 0.0],
    ];
    let named = [CoveragePlane {
        id: "sky",
        values: &coverage,
    }];
    let f = Frame::with_named_coverage(4, 1, &pixels, &named, false).unwrap();
    let p = Plan::parse(&wire("exposure", 0.25).to_string()).unwrap();
    for mode in [Mode::Fused, Mode::Staged] {
        let prog = gpu.compile(&p, mode).unwrap();
        let frame = gpu.bind(&prog, &p, &f).unwrap();
        for kind in [
            "exposure",
            "shadows",
            "highlights",
            "blacks",
            "whites",
            "saturation",
            "contrast",
            "hue",
        ] {
            let edit = Plan::parse(&wire(kind, 0.55).to_string()).unwrap();
            frame.update(&edit).unwrap();
            frame.submit();
            let actual = frame.read().unwrap();
            let expected = render_cpu(&edit, &f).unwrap();
            for (a, e) in actual.iter().zip(expected) {
                for (g, c) in a.iter().zip(e) {
                    assert!((*g - c).abs() <= 2e-6, "{kind} {g} {c}");
                }
            }
        }
    }
}
