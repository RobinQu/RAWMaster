use rawmaster_image_poc::{render_cpu, Frame, Plan, EXAMPLE};
use serde_json::{json, Value};

fn doc(nodes: Value, output: &str) -> String {
    json!({"version":1,"working":"extended-linear-srgb-premul-f32","output":output,"nodes":nodes})
        .to_string()
}

#[test]
fn rejects_invalid_or_ambiguous_recipes() {
    let source = json!({"id":"s","op":"source"});
    for nodes in [
        json!([source, source]),
        json!([source, {"id":"unused","op":"source"}]),
        json!([{"id":"s","op":"exposure","image":"s","ev":1}]),
        json!([{"id":"s","op":"exposure","image":"missing","ev":1}]),
        json!([{"id":"s","op":"exposure","image":"m","ev":1}, {"id":"m","op":"mask"}]),
        json!([{"id":"s","op":"external_shader"}]),
        json!([{"id":"s","op":"source","typo":0}]),
        json!([{"id":"s","op":"mask"}]),
    ] {
        assert!(Plan::parse(&doc(nodes, "s")).is_err());
    }
    for bad in [
        EXAMPLE.replace("-0.5", "99"),
        EXAMPLE.replace("srgb", "p3"),
        EXAMPLE.replace("\"version\": 1", "\"version\": 2"),
    ] {
        assert!(Plan::parse(&bad).is_err());
    }
}
#[test]
fn rejects_invalid_image_mask_and_nonfinite_output() {
    let valid = [[0.2, 0.3, 0.4, 1.0]];
    for coverage in [f32::NAN, -0.1, 1.2] {
        assert!(Frame::new(1, 1, &valid, &[coverage]).is_err());
    }
    assert!(Frame::new(0, 1, &valid, &[1.0]).is_err());
    assert!(Frame::new(2, 1, &valid, &[1.0]).is_err());
    assert!(Frame::new(1, 1, &[[f32::NAN, 0.0, 0.0, 1.0]], &[1.0]).is_err());
    assert!(Frame::new(1, 1, &[[1.0, 0.0, 0.0, 0.0]], &[1.0]).is_err());
    let probe = Frame::new(1, 1, &[[f32::MAX, 0.0, 0.0, 1.0]], &[0.0]).unwrap();
    assert!(render_cpu(&Plan::parse(EXAMPLE).unwrap(), &probe).is_err());
}
#[test]
fn branch_math_alpha_hdr_and_batch_inputs() {
    let recipe = doc(
        json!([
            {"id":"out","op":"blend","base":"s","layer":"x","mask":"m"},
            {"id":"x","op":"exposure","image":"s","ev":1.0},{"id":"s","op":"source"},{"id":"m","op":"mask"}
        ]),
        "out",
    );
    let graph = Plan::parse(&recipe).unwrap();
    let p = [-0.5, 0.125, 2.0, 0.5];
    for (mask, expected) in [
        (0.0, p),
        (0.5, [-0.75, 0.1875, 3.0, 0.5]),
        (1.0, [-1.0, 0.25, 4.0, 0.5]),
    ] {
        let pixels = [p, [0.0; 4]];
        let coverage = [mask, mask];
        let frame = Frame::new(2, 1, &pixels, &coverage).unwrap();
        assert_eq!(render_cpu(&graph, &frame).unwrap(), [expected, [0.0; 4]]);
    }
    // Same compiled plan, a different photo and extent, no old frame state.
    let frame = Frame::new(1, 1, &[[0.1, 0.4, 0.2, 1.0]], &[1.0]).unwrap();
    assert_eq!(render_cpu(&graph, &frame).unwrap(), [[0.2, 0.8, 0.4, 1.0]]);
    let identity = Plan::parse(&doc(json!([{"id":"s","op":"source"}]), "s")).unwrap();
    assert_eq!(
        render_cpu(&identity, &frame).unwrap(),
        [[0.1, 0.4, 0.2, 1.0]]
    );
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires an actual Metal or Vulkan adapter"]
fn real_device_branch_fusion_and_parameter_rebinding() {
    use rawmaster_image_poc::gpu::{Gpu, Mode};
    let gpu = Gpu::open().unwrap();
    let plan = Plan::parse(EXAMPLE).unwrap();
    let edited = Plan::parse(&EXAMPLE.replace("-0.5", "1.0")).unwrap();
    let pixels = vec![[-0.1, 1.6, 0.25, 0.5]; 37 * 7];
    let mask: Vec<_> = (0..pixels.len()).map(|i| (i % 7) as f32 / 6.0).collect();
    let frame = Frame::new(37, 7, &pixels, &mask).unwrap();
    for mode in [Mode::Fused, Mode::Staged] {
        let program = gpu.compile(&plan, mode).unwrap();
        let (strips, count) = gpu
            .render_bounded(
                &program,
                &plan,
                &frame,
                400 + 2 * 37 * program.bytes_per_pixel_with_readback(),
            )
            .unwrap();
        assert_eq!(count, 4);
        assert!(gpu.render_bounded(&program, &plan, &frame, 128).is_err());
        let expected = render_cpu(&plan, &frame).unwrap();
        assert!(strips
            .iter()
            .flatten()
            .zip(expected.iter().flatten())
            .all(|(a, b)| (a - b).abs() < 2e-6));
        let resident = gpu.bind(&program, &plan, &frame).unwrap();
        for recipe in [&plan, &edited, &plan] {
            resident.update(recipe).unwrap();
            resident.submit();
            let actual = resident.read().unwrap();
            let expected = render_cpu(recipe, &frame).unwrap();
            assert!(actual
                .iter()
                .flatten()
                .zip(expected.iter().flatten())
                .all(|(a, b)| (a - b).abs() < 2e-6));
        }
        let other = Plan::parse(&doc(json!([{"id":"s","op":"source"}]), "s")).unwrap();
        assert!(resident.update(&other).is_err());
    }
}
