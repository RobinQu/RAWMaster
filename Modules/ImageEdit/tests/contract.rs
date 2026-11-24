use rawmaster_image::{render_cpu, CoveragePlane, Frame, Plan};
use serde_json::{json, Value};
const EXAMPLE: &str = include_str!("local-look.json");

fn doc(nodes: Value, output: &str) -> String {
    versioned(1, nodes, output)
}

fn versioned(version: u32, nodes: Value, output: &str) -> String {
    json!({"version":version,"working":"extended-linear-srgb-premul-f32","output":output,"nodes":nodes})
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
        EXAMPLE.replace("\"version\": 1", "\"version\": 3"),
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

#[test]
fn named_coverage_follows_each_edge_and_preserves_float32_endpoints() {
    let sky = "é";
    let subject = "e\u{301}";
    let plan = Plan::parse(&versioned(
        2,
        json!([
            {"op":"blend","id":"out","base":"bright","layer":"dark","mask":subject},
            {"op":"mask","id":subject}, {"op":"source","id":"raw"}, {"op":"mask","id":sky},
            {"op":"masked_exposure","id":"dark","image":"raw","mask":subject,"ev":-2},
            {"op":"masked_exposure","id":"bright","image":"raw","mask":sky,"ev":2},
        ]),
        "out",
    ))
    .unwrap();
    assert_eq!(plan.recipe_version(), 2);
    assert_eq!(plan.mask_ids(), [sky, subject]);
    let p = [-0.5, 0.125, 2.0, 0.5];
    let pixels = [p, p, p, p, [0.0; 4]];
    let mask_a = CoveragePlane {
        id: sky,
        values: &[0.0, 0.5, 1.0, 0.5, 1.0],
    };
    let mask_b = CoveragePlane {
        id: subject,
        values: &[0.0, 0.0, 1.0, 0.5, 0.5],
    };
    let expected = [
        p,
        [-1.0, 0.25, 4.0, 0.5],
        [-0.125, 0.03125, 0.5, 0.5],
        [-0.625, 0.15625, 2.5, 0.5],
        [0.0; 4],
    ];
    for bindings in [[mask_a, mask_b], [mask_b, mask_a]] {
        let frame = Frame::with_named_coverage(5, 1, &pixels, &bindings, false).unwrap();
        assert_eq!(render_cpu(&plan, &frame).unwrap(), expected);
    }
    let swapped = [
        CoveragePlane { id: sky, ..mask_b },
        CoveragePlane {
            id: subject,
            ..mask_a
        },
    ];
    let frame = Frame::with_named_coverage(5, 1, &pixels, &swapped, false).unwrap();
    assert_eq!(
        render_cpu(&plan, &frame).unwrap()[1],
        [-0.375, 0.09375, 1.5, 0.5]
    );
}

#[test]
fn rejects_missing_extra_repeated_or_invalid_named_planes() {
    let pixels = [[0.25, 0.5, 1.0, 1.0]];
    let nodes = json!([{"id":"raw","op":"source"},{"id":"m","op":"mask"},
                       {"id":"out","op":"masked_exposure","image":"raw","mask":"m","ev":1}]);
    let v1 = Plan::parse(&versioned(1, nodes.clone(), "out")).unwrap();
    let v2 = Plan::parse(&versioned(2, nodes, "out")).unwrap();
    let identity = Plan::parse(&versioned(2, json!([{"id":"raw","op":"source"}]), "raw")).unwrap();
    let m = CoveragePlane {
        id: "m",
        values: &[0.5],
    };
    let extra = CoveragePlane { id: "other", ..m };
    let named = |planes: &[CoveragePlane<'static>]| {
        Frame::with_named_coverage(1, 1, &pixels, planes, false)
    };
    assert!(named(&[m, m]).is_err());
    assert!(named(&[CoveragePlane { id: "", ..m }]).is_err());
    assert!(named(&[m; 33]).is_err());
    for bad in [
        &[][..],
        &[f32::NAN],
        &[f32::INFINITY],
        &[-0.1],
        &[1.01],
        &[0.5, 0.5],
    ] {
        assert!(named(&[CoveragePlane {
            id: "m",
            values: bad
        }])
        .is_err());
    }
    for wrong in [vec![], vec![extra], vec![m, extra]] {
        assert!(render_cpu(&v2, &named(&wrong).unwrap()).is_err());
    }
    let anonymous = Frame::new(1, 1, &pixels, m.values).unwrap();
    let valid = named(&[m]).unwrap();
    assert_eq!(
        render_cpu(&v1, &anonymous).unwrap(),
        render_cpu(&v1, &valid).unwrap()
    );
    assert_eq!(
        render_cpu(&v1, &valid).unwrap(),
        render_cpu(&v2, &valid).unwrap()
    );
    assert!(render_cpu(&v2, &anonymous).is_err());
    assert!(render_cpu(&identity, &valid).is_err());
    assert!(render_cpu(&identity, &anonymous).is_err());
    assert_eq!(render_cpu(&identity, &named(&[]).unwrap()).unwrap(), pixels);
    assert_eq!(
        render_cpu(&identity, &Frame::new(1, 1, &pixels, &[]).unwrap()).unwrap(),
        pixels
    );
}

#[test]
fn graph_limits_preserve_legacy_and_address_all_32_planes_across_cpu_tiles() {
    fn chain(version: u32, masks: usize, nodes: usize) -> Result<Plan, String> {
        let mut graph = vec![json!({"id":"raw","op":"source"})];
        let mut image = String::from("raw");
        for slot in 0..masks {
            let mask = format!("mask-{slot}");
            let next = format!("local-{slot}");
            let ev = if slot % 2 == 0 { 1 } else { -1 };
            graph.push(json!({"op":"mask","id":mask}));
            graph.push(json!({"op":"masked_exposure","id":next,"image":image,"mask":mask,"ev":ev}));
            image = next;
        }
        while graph.len() < nodes {
            let next = format!("copy-{}", graph.len());
            graph.push(json!({"op":"exposure","id":next,"image":image,"ev":0}));
            image = next;
        }
        Plan::parse(&versioned(version, Value::Array(graph), &image))
    }
    assert!(chain(1, 1, 64).is_ok());
    assert!(chain(1, 1, 65).is_err());
    assert!(chain(1, 2, 5).is_err());
    assert!(chain(2, 33, 128).is_err());
    assert!(chain(2, 32, 129).is_err());
    let plan = chain(2, 32, 128).unwrap();
    let pixels = [[-0.5, 1.0, 2.0, 0.5]; 259];
    let values: Vec<Vec<f32>> = (0..32)
        .map(|slot| {
            (0..pixels.len())
                .map(|x| if x % 32 == slot { 1.0 } else { 0.0 })
                .collect()
        })
        .collect();
    let bindings: Vec<_> = plan
        .mask_ids()
        .iter()
        .zip(&values)
        .rev()
        .map(|(id, values)| CoveragePlane { id, values })
        .collect();
    let frame = Frame::with_named_coverage(37, 7, &pixels, &bindings, false).unwrap();
    for (x, out) in render_cpu(&plan, &frame).unwrap().iter().enumerate() {
        assert_eq!(
            *out,
            if x % 2 == 0 {
                [-1.0, 2.0, 4.0, 0.5]
            } else {
                [-0.25, 0.5, 1.0, 0.5]
            }
        );
    }
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires an actual Metal or Vulkan adapter"]
fn real_device_branch_fusion_and_parameter_rebinding() {
    use rawmaster_image::gpu::{Gpu, Mode};
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
