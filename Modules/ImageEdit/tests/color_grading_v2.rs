use rawmaster_image::{render_cpu, Frame, Plan};
use serde_json::{json, Value};

fn wire() -> Value {
    let neutral = json!({"hueDegrees": 0, "saturation": 0, "luminance": 0});
    json!({"version": 2, "working": "extended-linear-srgb-premul-f32", "output": "grade", "nodes": [
        {"id": "grade", "op": "color_grading_v2", "image": "source", "grading": {
            "shadows": {"hueDegrees": 25, "saturation": 50, "luminance": 40},
            "midtones": neutral,
            "highlights": {"hueDegrees": 220, "saturation": 55, "luminance": 0},
            "global": {"hueDegrees": 0, "saturation": 0, "luminance": 20},
            "blending": 50, "balance": 0
        }}, {"id": "source", "op": "source"}
    ]})
}

#[test]
fn range_validation_precedes_narrowing_and_requires_v2() {
    let wire = wire();
    assert!(Plan::parse(&wire.to_string()).is_ok());
    let mut old = wire.clone();
    old["version"] = json!(1);
    assert!(Plan::parse(&old.to_string()).is_err());
    for (field, value) in [("balance", -100.001), ("blending", 100.001)] {
        let mut invalid = wire.clone();
        invalid["nodes"][0]["grading"][field] = json!(value);
        assert!(Plan::parse(&invalid.to_string()).is_err());
    }
    let mut invalid = wire.clone();
    invalid["nodes"][0]["grading"]["shadows"]["hueDegrees"] = json!(360);
    assert!(Plan::parse(&invalid.to_string()).is_err());
    let invalid = wire
        .to_string()
        .replace("\"blending\":50", "\"blending\":100.00000000000001");
    assert!(Plan::parse(&invalid).is_err());
}

#[test]
fn grading_preserves_alpha_and_neutral_is_bitwise_passthrough() {
    let pixels = [
        [0.0, 0.0, 0.0, 1.0],
        [-0.0, -0.0, 0.0, -0.0],
        [-0.08, 0.2, 1.3, 0.5],
        [1.75, 0.28, 1.2, 1.0],
    ];
    let frame = Frame::new(4, 1, &pixels, &[]).unwrap();
    let wire = wire();
    let plan = Plan::parse(&wire.to_string()).unwrap();
    let result = render_cpu(&plan, &frame).unwrap();
    let expected = ((0.15_f64 + 0.055) / 1.055).powf(2.4) as f32;
    assert!(result[0][..3].iter().all(|p| (p - expected).abs() < 1e-7));
    assert_ne!(result[2], pixels[2]);
    assert!(result[3].iter().all(|v| v.is_finite()));
    assert!(result
        .iter()
        .zip(pixels)
        .all(|(a, b)| a[3].to_bits() == b[3].to_bits()));

    let mut neutral = wire;
    let grading = &mut neutral["nodes"][0]["grading"];
    grading["balance"] = json!(-100);
    for wheel in ["shadows", "midtones", "highlights", "global"] {
        grading[wheel]["saturation"] = json!(0);
        grading[wheel]["luminance"] = json!(0);
    }
    let neutral = Plan::parse(&neutral.to_string()).unwrap();
    let result = render_cpu(&neutral, &frame).unwrap();
    assert!(result
        .iter()
        .zip(pixels)
        .all(|(a, b)| a.map(f32::to_bits) == b.map(f32::to_bits)));
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires a Metal or Vulkan adapter"]
fn fused_and_staged_grading_rebinds_wheels_and_handles_subnormal_alpha() {
    use rawmaster_image::gpu::{Gpu, Mode};
    let gpu = Gpu::open().unwrap();
    let tiny = f32::from_bits(1);
    let pixels = [
        [0.12, 0.23, 0.37, 1.0],
        [-0.1, 0.25, 0.9, 0.5],
        [tiny, tiny, tiny, tiny],
    ];
    let frame = Frame::new(3, 1, &pixels, &[]).unwrap();
    let mut wire = wire();
    let standalone = Plan::parse(&wire.to_string()).unwrap();
    wire["nodes"][0]["image"] = json!("identity");
    wire["nodes"].as_array_mut().unwrap().push(json!({
        "id": "identity", "op": "curves_levels_v3", "image": "source"
    }));
    let plan = Plan::parse(&wire.to_string()).unwrap();
    assert_eq!(
        render_cpu(&standalone, &frame).unwrap(),
        render_cpu(&plan, &frame).unwrap()
    );
    wire["nodes"][0]["grading"]["balance"] = json!(-100);
    wire["nodes"][0]["grading"]["global"]["luminance"] = json!(100);
    let edited = Plan::parse(&wire.to_string()).unwrap();
    let overflow_pixel = [[f32::MAX, 0.0, 0.0, tiny]];
    let overflow = Frame::new(1, 1, &overflow_pixel, &[]).unwrap();
    assert!(render_cpu(&plan, &overflow).is_err());

    for mode in [Mode::Fused, Mode::Staged] {
        let program = gpu.compile(&plan, mode).unwrap();
        let bound = gpu.bind(&program, &plan, &frame).unwrap();
        for current in [&plan, &edited] {
            bound.update(current).unwrap();
            bound.submit();
            let actual = bound.read().unwrap();
            let expected = render_cpu(current, &frame).unwrap();
            for (a, b) in actual[..2].iter().zip(&expected[..2]) {
                assert!(a.iter().zip(b).all(|(a, b)| (a - b).abs() <= 2e-6));
            }
            assert_eq!(actual[2].map(f32::to_bits), expected[2].map(f32::to_bits));
        }
        let rejected = gpu.bind(&program, &plan, &overflow).unwrap();
        rejected.submit();
        assert!(rejected.read().is_err());
    }
}
