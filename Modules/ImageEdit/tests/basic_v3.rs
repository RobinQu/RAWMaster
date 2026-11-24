use rawmaster_image::{render_cpu, CoveragePlane, Frame, Plan};
use serde_json::{json, Value};

fn recipe(version: u32, basic: Value) -> String {
    json!({"version":version, "working":"extended-linear-srgb-premul-f32", "output":"basic",
        "nodes":[{"id":"source","op":"source"},basic]})
    .to_string()
}

#[test]
fn v1_and_unrepresentable_controls_reject_before_execution() {
    let node = json!({"id":"basic","op":"basic_v3","image":"source",
        "light":{"brightness":2,"contrast":-1,"blackPoint":-2,"whites":1}});
    assert!(Plan::parse(&recipe(1, node.clone())).is_err());
    assert!(Plan::parse(&recipe(2, node.clone())).is_ok());
    let mut too_high = node.clone();
    too_high["light"]["brightness"] = json!(2.00000001);
    assert!(Plan::parse(&recipe(2, too_high)).is_err());
    let mut unsupported = node;
    unsupported["light"]["exposure"] = json!(0);
    assert!(Plan::parse(&recipe(2, unsupported)).is_err());
}

fn image_frame() -> [[f32; 4]; 6] {
    [
        [-0.04, 0.12, 1.4, 1.0],
        [0.41, 0.20, 0.10, 0.5],
        [0.04, 0.23, 0.49, 1.0],
        [0.5, 0.125, 0.0625, 1.0],
        [0.2, 0.3, 0.12, 0.75],
        [-0.0, 0.0, -0.0, 0.0],
    ]
}

fn blend_plan(amount: f64) -> Plan {
    Plan::parse(
        &json!({"version":2,"working":"extended-linear-srgb-premul-f32","output":"out",
        "nodes":[{"id":"out","op":"blend","base":"source","layer":"basic","mask":"coverage"},
            {"id":"coverage","op":"mask"},{"id":"source","op":"source"},
            {"id":"base","op":"exposure","image":"source","ev":-0.25},
            {"id":"basic","op":"basic_v3","image":"base",
             "light":{"brightness":0.34,"contrast":0.52,"blackPoint":-0.2,"whites":amount},
             "color":{"saturation":0.2,"vibrance":-0.25,"cast":0.31},
             "blackAndWhite":{"intensity":0,"neutrals":0.15,"tone":-0.25}}]})
        .to_string(),
    )
    .unwrap()
}

#[test]
fn basic_v3_preserves_neutral_transparent_and_masked_pixels() {
    let pixels = image_frame();
    let neutral = Plan::parse(&recipe(
        2,
        json!({"id":"basic","op":"basic_v3","image":"source",
        "color":{"saturation":0,"vibrance":0,"cast":0}}),
    ))
    .unwrap();
    let frame = Frame::with_named_coverage(3, 2, &pixels, &[], false).unwrap();
    let result = render_cpu(&neutral, &frame).unwrap();
    for (original, actual) in pixels.iter().zip(&result) {
        assert_eq!(original.map(f32::to_bits), actual.map(f32::to_bits));
    }
    let coverage = [0.0, 0.5, 1.0, 0.25, 1.0, 1.0];
    let planes = [CoveragePlane {
        id: "coverage",
        values: &coverage,
    }];
    let frame = Frame::with_named_coverage(3, 2, &pixels, &planes, false).unwrap();
    let result = render_cpu(&blend_plan(0.45), &frame).unwrap();
    assert_eq!(result[0].map(f32::to_bits), pixels[0].map(f32::to_bits));
    assert_eq!(result[5].map(f32::to_bits), pixels[5].map(f32::to_bits));
    assert_ne!(result[1], pixels[1]);
    for index in [2, 4] {
        assert_eq!(result[index][0], result[index][1]);
        assert_eq!(result[index][1], result[index][2]);
    }
    for (original, actual) in pixels.iter().zip(&result) {
        assert_eq!(original[3].to_bits(), actual[3].to_bits());
    }
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires a Metal or Vulkan adapter"]
fn basic_v3_matches_cpu_with_fusion_partition_and_rebinding() {
    use rawmaster_image::gpu::{Gpu, Mode};
    let pixels = image_frame();
    let coverage = [0.0, 0.5, 1.0, 0.25, 1.0, 1.0];
    let planes = [CoveragePlane {
        id: "coverage",
        values: &coverage,
    }];
    let frame = Frame::with_named_coverage(3, 2, &pixels, &planes, false).unwrap();
    let first = blend_plan(0.45);
    let changed = blend_plan(-0.45);
    let gpu = Gpu::open().unwrap();
    for mode in [Mode::Fused, Mode::Staged] {
        let program = gpu.compile(&first, mode).unwrap();
        let resident = gpu.bind(&program, &first, &frame).unwrap();
        for plan in [&first, &changed, &first] {
            resident.update(plan).unwrap();
            resident.submit();
            let result = resident.read().unwrap();
            let expected = render_cpu(plan, &frame).unwrap();
            assert_eq!(result.len(), expected.len());
            assert_eq!(result[0].map(f32::to_bits), pixels[0].map(f32::to_bits));
            assert_eq!(result[5][3].to_bits(), 0);
            for (actual, reference) in result.iter().zip(&expected) {
                assert_eq!(actual[3].to_bits(), reference[3].to_bits());
                for channel in 0..3 {
                    assert!(
                        (actual[channel] - reference[channel]).abs() < 2e-6,
                        "{actual:?} != {reference:?}"
                    );
                }
            }
        }
    }
}

#[cfg(all(feature = "gpu", target_os = "linux"))]
#[test]
#[ignore = "requires a software Vulkan adapter"]
fn software_vulkan_combined_basic_and_curves_match_cpu_on_raw_rounding_cases() {
    use rawmaster_image::gpu::{Gpu, Mode};

    // Unchanged Float32 bits of the nine opaque pixels whose compound result
    // exceeded the color tolerance on the software Vulkan reference adapter.
    let pixels = [
        [0x3f22e000, 0x3f228000, 0x3f2bc000],
        [0x3f27e000, 0x3f274000, 0x3f366000],
        [0x3f220000, 0x3f26a000, 0x3f330000],
        [0x3f24e000, 0x3f250000, 0x3f2c2000],
        [0x3f248000, 0x3f27c000, 0x3f326000],
        [0x3f1e8000, 0x3f20e000, 0x3f2a2000],
        [0x3f286000, 0x3f28c000, 0x3f2c4000],
        [0x3f1ec000, 0x3f274000, 0x3f2ce000],
        [0x3f234000, 0x3f274000, 0x3f2c8000],
    ]
    .map(|bits| {
        let [red, green, blue] = bits.map(f32::from_bits);
        [red, green, blue, 1.0]
    });
    let plan = Plan::parse(
        &json!({"version":2,"working":"extended-linear-srgb-premul-f32","output":"curves",
            "nodes":[{"id":"source","op":"source"},
                {"id":"basic","op":"basic_v3","image":"source",
                 "light":{"brightness":0.34,"contrast":0.52,"blackPoint":-0.2,"whites":0.45},
                 "color":{"saturation":0.45,"vibrance":0.34,"cast":0.31}},
                {"id":"curves","image":"basic","op":"curves_levels_v3","curves":{
                    "rgb":{"inputBlack":0,"inputWhite":1,"points":[{"x":0,"y":0},{"x":0.26,"y":0.32},{"x":0.68,"y":0.59},{"x":1,"y":1}]},
                    "red":{"inputBlack":0,"inputWhite":1,"points":[{"x":0,"y":0},{"x":0.48,"y":0.53},{"x":1,"y":1}]}}}]
        })
        .to_string(),
    )
    .unwrap();
    let frame = Frame::with_named_coverage(pixels.len() as u32, 1, &pixels, &[], false).unwrap();
    let expected = render_cpu(&plan, &frame).unwrap();
    let gpu = Gpu::open().unwrap();
    assert!(gpu.adapter.ends_with(" / Vulkan / Cpu"), "{}", gpu.adapter);
    let render = |mode| {
        let program = gpu.compile(&plan, mode).unwrap();
        let resident = gpu.bind(&program, &plan, &frame).unwrap();
        resident.submit();
        resident.read().unwrap()
    };
    let fused = render(Mode::Fused);
    assert_eq!(fused, render(Mode::Staged));
    for (actual, expected) in fused.iter().zip(&expected) {
        assert_eq!(actual[3].to_bits(), expected[3].to_bits());
        for channel in 0..3 {
            assert!(
                (actual[channel] - expected[channel]).abs() <= 2e-6,
                "{actual:?} != {expected:?}"
            );
        }
    }
}
