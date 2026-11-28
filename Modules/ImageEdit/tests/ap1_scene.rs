use rawmaster_image::scene::ap1::{render_cpu, Prepared, Region, Root, OPERATORS};
use rawmaster_image::scene::{SceneError, ViewSpec};
use rawmaster_image::Pixel;
use serde_json::{json, Value};

fn scene() -> Value {
    json!({"schemaVersion":1, "graph":{"output":"layer", "nodes":[
        {"id":"mask", "name":"Gradient", "operation":{"kind":"linearCoverage", "start":[0.23, 0.19], "end":[0.87, 0.66]}},
        {"id":"warm", "name":"Masked curve", "operation":{"kind":"corrector", "image":"$input", "mask":"mask",
            "exposureEV":1.25,"curve":[[-4.0,-3.0],[-1.0,-0.9],[2.0,1.5]],"strength":0.8,"enabled":true}},
        {"id":"dark", "name":"Cooler", "operation":{"kind":"corrector", "image":"$input", "mask":null,
            "exposureEV":-0.5,"curve":[],"strength":0.75,"enabled":true}},
        {"id":"off", "name":"Disabled", "operation":{"kind":"corrector", "image":"$input", "mask":null,
            "exposureEV":10.0,"curve":[],"strength":1.0,"enabled":false}},
        {"id":"zero", "name":"Zero weight", "operation":{"kind":"corrector", "image":"$input", "mask":null,
            "exposureEV":5.0,"curve":[],"strength":1.0,"enabled":true}},
        {"id":"layer", "name":"Ordered", "operation":{"kind":"layer", "base":"off","enabled":true,
            "layers":[{"image":"warm","weight":0.65,"mode":"normal"},{"image":"dark","weight":0.40,"mode":"normal"},
                      {"image":"zero","weight":0.0,"mode":"normal"}]}}
    ]}})
}

fn input() -> Vec<Pixel> {
    (0..27 * 13)
        .map(|i| match i % 5 {
            0 => [0.4, -0.3, 0.2, 0.0],
            1 => [1.4, 0.35, -0.125, 0.5],
            2 => [-0.55, -0.025, 0.065, 1.0],
            3 => [0.03125, 1.6, 2.1, 1.0],
            _ => [0.11, 0.07, 0.099, 0.18],
        })
        .collect()
}

fn six_mp_scene() -> Value {
    json!({"schemaVersion":1,"graph":{"output":"mix","nodes":[
        {"id":"ramp","name":"Ramp","operation":{"kind":"linearCoverage","start":[0.1,0],"end":[0.9,1]}},
        {"id":"ellipse","name":"Ellipse","operation":{"kind":"radialCoverage","center":[0.5,0.5],"radii":[0.4,0.6],"feather":0.2}},
        {"id":"mask","name":"Intersection","operation":{"kind":"combineCoverage","base":"ramp","other":"ellipse","mode":"intersect"}},
        {"id":"light","name":"Light","operation":{"kind":"corrector","image":"$input","mask":"mask","exposureEV":1.2,
            "curve":[[-4.0,-3.5],[0.0,0.0],[3.0,2.0]],"strength":0.8,"enabled":true}},
        {"id":"dark","name":"Dark","operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":-0.7,
            "curve":[],"strength":1,"enabled":true}},
        {"id":"mix","name":"Mix","operation":{"kind":"parallel","base":"$input","enabled":true,
            "layers":[{"image":"light","weight":0.65,"mode":"normal"},{"image":"dark","weight":0.35,"mode":"normal"}]}}
    ]}})
}

fn nested_scene() -> Value {
    serde_json::from_str(r#"{"schemaVersion":1,"graph":{"output":"tail","nodes":[
        {"id":"root-mask","name":"Horizontal","operation":{"kind":"linearCoverage","start":[0,0],"end":[1,0]}},
        {"id":"root-grade","name":"Parent input","operation":{"kind":"corrector","image":"$input","mask":"root-mask",
            "exposureEV":1,"curve":[],"strength":1,"enabled":true}},
        {"id":"outer","name":"Outer group","operation":{"kind":"group","image":"root-grade","strength":0.5,"enabled":false,
            "graph":{"output":"after-inner","nodes":[
                {"id":"child-input","name":"Inner input","operation":{"kind":"corrector","image":"$input","mask":null,
                    "exposureEV":1,"curve":[],"strength":1,"enabled":true}},
                {"id":"inner","name":"Inner group","operation":{"kind":"group","image":"child-input","strength":0.25,"enabled":true,
                    "graph":{"output":"inner-final","nodes":[
                        {"id":"inner-mask","name":"Vertical","operation":{"kind":"linearCoverage","start":[0,0],"end":[0,1]}},
                        {"id":"inner-grade","name":"Inner grade","operation":{"kind":"corrector","image":"$input","mask":"inner-mask",
                            "exposureEV":1,"curve":[],"strength":1,"enabled":true}},
                        {"id":"inner-final","name":"Inner final","operation":{"kind":"corrector","image":"inner-grade","mask":null,
                            "exposureEV":-1,"curve":[],"strength":1,"enabled":true}}
                    ]}}},
                {"id":"after-inner","name":"Outer final","operation":{"kind":"corrector","image":"inner","mask":null,
                    "exposureEV":1,"curve":[],"strength":1,"enabled":true}}
            ]}}},
        {"id":"tail","name":"Tail","operation":{"kind":"corrector","image":"outer","mask":"root-mask",
            "exposureEV":-1,"curve":[],"strength":1,"enabled":true}}
    ]}}"#)
    .unwrap()
}

fn group_view(path: &[&str], target: &str, id: Option<&str>) -> ViewSpec {
    ViewSpec {
        group_path: path.iter().map(|&id| id.into()).collect(),
        target: target.into(),
        id: id.map(str::to_owned),
        ..Default::default()
    }
}

fn assert_group_pixels(prepared: &Prepared, steps: usize, gain: impl Fn(f32, f32) -> f32) {
    assert_eq!(prepared.plan().step_count(), steps);
    let full = Region::new([8, 4], [0, 0], [8, 4]).unwrap();
    let roi = Region::new([8, 4], [3, 1], [5, 1]).unwrap();
    let colors = [
        [1.0, -0.25, 0.125, 0.5],
        [-0.5, 0.25, 1.5, 1.0],
        [-0.0, 0.25, -0.25, 0.0],
    ];
    let input: Vec<_> = colors
        .into_iter()
        .cycle()
        .take(full.pixel_count())
        .collect();
    let pixels = render_cpu(prepared, full, &input).unwrap();
    for (i, (&source, &output)) in input.iter().zip(&pixels).enumerate() {
        let x = (i as u32 % 8) as f32 / 8.0 + 1.0 / 16.0;
        let y = (i as u32 / 8) as f32 / 4.0 + 1.0 / 8.0;
        let [r, g, b, a] = source;
        let scale = gain(x, y);
        let expected = if a == 0.0 {
            [0.0; 4]
        } else {
            [r * scale, g * scale, b * scale, a]
        };
        assert_eq!(output.map(f32::to_bits), expected.map(f32::to_bits));
    }
    let cropped = render_cpu(prepared, roi, &roi.crop(&input).unwrap()).unwrap();
    for (a, b) in cropped.iter().zip(roi.crop(&pixels).unwrap()) {
        assert_eq!(a.map(f32::to_bits), b.map(f32::to_bits));
    }
}

#[test]
fn cpu_group_final_and_monitors_use_their_own_input_and_strength() {
    let mut document = nested_scene();
    let encoded = serde_json::to_vec(&document).unwrap();
    let prepare = |path: &[&str], target, id| {
        Prepared::from_039_view(&encoded, &group_view(path, target, id)).unwrap()
    };
    let outer = ["outer"];
    let inner = ["outer", "inner"];
    let root_gain = |x: f32| 1.0 + x;
    let tail_gain = |x: f32| 1.0 - 0.5 * x;

    let final_plan = Prepared::from_039(&encoded, Root::Final).unwrap();
    assert_group_pixels(&final_plan, 3, |x, _| root_gain(x) * tail_gain(x));
    assert_group_pixels(&prepare(&outer, "final", None), 8, |x, y| {
        root_gain(x) * (3.5 + 0.5 * y)
    });
    assert_group_pixels(&prepare(&outer, "node", Some("inner")), 7, |x, y| {
        root_gain(x) * (1.75 + 0.25 * y)
    });
    assert_group_pixels(&prepare(&outer, "bypass", None), 2, |x, _| root_gain(x));
    assert_group_pixels(&prepare(&inner, "final", None), 6, |x, y| {
        root_gain(x) * (1.0 + y)
    });
    assert_group_pixels(&prepare(&inner, "node", Some("inner-grade")), 5, |x, y| {
        2.0 * root_gain(x) * (1.0 + y)
    });
    assert_group_pixels(&prepare(&inner, "bypass", None), 3, |x, _| {
        2.0 * root_gain(x)
    });
    assert_eq!(
        prepare(&[], "final", None).plan(),
        final_plan.plan(),
        "projection must leave the persisted final unchanged"
    );

    document["graph"]["nodes"][2]["operation"]["enabled"] = json!(true);
    let enabled = Prepared::from_039(&serde_json::to_vec(&document).unwrap(), Root::Final).unwrap();
    // The tail still reads the original horizontal mask after the group's vertical mask.
    assert_group_pixels(&enabled, 10, |x, y| {
        root_gain(x) * (2.25 + 0.25 * y) * tail_gain(x)
    });
    document["graph"]["nodes"][2]["operation"]["strength"] = json!(0);
    let zero = Prepared::from_039(&serde_json::to_vec(&document).unwrap(), Root::Final).unwrap();
    assert_group_pixels(&zero, 3, |x, _| root_gain(x) * tail_gain(x));
}

#[test]
fn cpu_group_selection_checks_persisted_graph_and_local_ports() {
    let mut document = nested_scene();
    let prepare = |doc: &Value, path: &[&str], target, id| {
        Prepared::from_039_view(
            &serde_json::to_vec(doc).unwrap(),
            &group_view(path, target, id),
        )
    };
    let inner = ["outer", "inner"];
    for path in [
        &["missing"][..],
        &["root-grade"],
        &["inner"],
        &["outer", "root-grade"],
    ] {
        assert!(matches!(
            prepare(&document, path, "final", None),
            Err(SceneError::Invalid(message)) if message.contains("unknown scene group")
        ));
    }
    assert!(matches!(
        prepare(&document, &inner, "node", Some("root-grade")),
        Err(SceneError::Invalid(message)) if message.contains("unknown scene node")
    ));
    assert!(matches!(
        prepare(&document, &inner, "node", Some("inner-mask")),
        Err(SceneError::Unsupported(message)) if message.contains("not previewable")
    ));
    document["graph"]["output"] = json!("root-grade");
    assert!(matches!(
        prepare(&document, &inner, "node", Some("inner-grade")),
        Err(SceneError::Invalid(message)) if message.contains("disconnected scene nodes")
    ));
    document["graph"]["output"] = json!("tail");
    document["graph"]["nodes"][2]["operation"]["graph"]["nodes"][1]["operation"]["graph"]
        ["nodes"][2]["operation"]["image"] = json!("root-grade");
    assert!(matches!(
        prepare(&document, &inner, "bypass", None),
        Err(SceneError::Invalid(message)) if message.contains("missing node root-grade")
    ));
}

#[test]
fn cpu_group_elides_inactive_and_identity_branches_and_rejects_active_unsupported_operations() {
    let mut document = nested_scene();
    let inner = group_view(&["outer", "inner"], "final", None);
    fn child_nodes(doc: &mut Value) -> &mut Value {
        &mut doc["graph"]["nodes"][2]["operation"]["graph"]["nodes"][1]["operation"]["graph"]
            ["nodes"]
    }
    child_nodes(&mut document)[0]["operation"] =
        json!({"kind":"externalCoverage","id":"model-mask"});
    let encoded = serde_json::to_vec(&document).unwrap();
    assert_eq!(
        Prepared::from_039(&encoded, Root::Final)
            .unwrap()
            .plan()
            .step_count(),
        3
    );
    assert!(matches!(
        Prepared::from_039_view(&encoded, &inner),
        Err(SceneError::Unsupported(message)) if message.contains("inner-mask")
    ));
    let bypass = group_view(&["outer", "inner"], "bypass", None);
    assert_eq!(
        Prepared::from_039_view(&encoded, &bypass)
            .unwrap()
            .plan()
            .step_count(),
        3
    );

    child_nodes(&mut document)[0]["operation"] =
        json!({"kind":"linearCoverage","start":[0,0],"end":[0,1]});
    child_nodes(&mut document)[2]["operation"] = json!({"kind":"layer","base":"$input","enabled":true,
        "layers":[{"image":"inner-grade","weight":0.5,"mode":"screen"}]});
    assert!(matches!(
        Prepared::from_039_view(&serde_json::to_vec(&document).unwrap(), &inner),
        Err(SceneError::Unsupported(message)) if message.contains("inner-final")
    ));

    let identity = br#"{"schemaVersion":1,"graph":{"output":"group","nodes":[
      {"id":"group","name":"Identity","operation":{"kind":"group","image":"$input","strength":0.25,"enabled":true,
        "graph":{"output":"$input","nodes":[]}}}
    ]}}"#;
    let prepared = Prepared::from_039(identity, Root::Final).unwrap();
    assert_eq!(prepared.plan().step_count(), 0);
    let pixel = [-0.0, 0.125, -0.25, 0.0];
    let region = Region::new([1, 1], [0, 0], [1, 1]).unwrap();
    assert_eq!(
        render_cpu(&prepared, region, &[pixel]).unwrap()[0].map(f32::to_bits),
        pixel.map(f32::to_bits)
    );
}

#[test]
fn cpu_six_mp_shape_uses_typed_coverage_and_ordered_parallel() {
    let mut graph = six_mp_scene();
    let encoded = serde_json::to_vec(&graph).unwrap();
    let prepare = |root| Prepared::from_039(&encoded, root).unwrap();
    let base = input();
    let full = Region::new([27, 13], [0, 0], [27, 13]).unwrap();
    let roi = Region::new([27, 13], [4, 2], [17, 8]).unwrap();
    let final_plan = prepare(Root::Final);
    let light = render_cpu(&prepare(Root::Monitor("light")), full, &base).unwrap();
    let dark = render_cpu(&prepare(Root::Monitor("dark")), full, &base).unwrap();
    let actual = render_cpu(&final_plan, full, &base).unwrap();
    assert_eq!(final_plan.plan().step_count(), 7);
    for (((base, light), dark), actual) in base.iter().zip(light).zip(dark).zip(&actual) {
        if base[3] == 0.0 {
            assert_eq!(*actual, [0.0; 4]);
        } else {
            for c in 0..3 {
                let after_light = base[c] + 0.65 * (light[c] - base[c]);
                assert_eq!(actual[c], after_light + 0.35 * (dark[c] - base[c]));
            }
            assert_eq!(actual[3].to_bits(), base[3].to_bits());
        }
    }
    assert_eq!(
        render_cpu(&final_plan, roi, &roi.crop(&base).unwrap()).unwrap(),
        roi.crop(&actual).unwrap()
    );
    for (id, output) in [
        ("scene.radial_coverage", "coverage-r32f"),
        ("scene.intersect_coverage", "coverage-r32f"),
        ("scene.normal_ordered_parallel", "acescg-ap1-premul-rgba32f"),
    ] {
        assert!(OPERATORS.iter().any(|op| op.id == id
            && op.output == output
            && op.version == 1
            && op.precision == "f32"));
    }
    graph["graph"]["nodes"][1]["operation"]["feather"] = json!(0.4);
    let rebound = Prepared::from_039(&serde_json::to_vec(&graph).unwrap(), Root::Final).unwrap();
    assert_eq!(final_plan.plan(), rebound.plan());
    graph["graph"]["nodes"][2]["operation"]["mode"] = json!("add");
    assert!(matches!(
        Prepared::from_039(&serde_json::to_vec(&graph).unwrap(), Root::Final),
        Err(SceneError::Unsupported(_))
    ));
}

#[test]
fn cpu_radial_edge_feather_absolute_roi_and_zero_intersection() {
    let mut graph = six_mp_scene();
    graph["graph"]["nodes"][0]["operation"]["start"] = json!([0.375, 0.0]);
    graph["graph"]["nodes"][0]["operation"]["end"] = json!([0.875, 0.0]);
    graph["graph"]["nodes"][1]["operation"]["center"] = json!([0.375, 0.5]);
    graph["graph"]["nodes"][1]["operation"]["radii"] = json!([0.25, 1.0]);
    graph["graph"]["nodes"][1]["operation"]["feather"] = json!(0.0);
    graph["graph"]["nodes"][3]["operation"]["exposureEV"] = json!(1.0);
    graph["graph"]["nodes"][3]["operation"]["curve"] = json!([]);
    graph["graph"]["nodes"][3]["operation"]["strength"] = json!(1.0);
    let color = [0.5, -0.25, 1.0, 0.75];
    let prepared =
        Prepared::from_039(&serde_json::to_vec(&graph).unwrap(), Root::Monitor("light")).unwrap();
    let full = Region::new([4, 1], [0, 0], [4, 1]).unwrap();
    let hard = render_cpu(&prepared, full, &[color; 4]).unwrap();
    assert_eq!(hard, [color, color, [0.75, -0.375, 1.5, 0.75], color]);
    // The pixel at r=1 has half the linear coverage; outside returns zero even at full ramp.
    let corner = Region::new([4, 1], [2, 0], [2, 1]).unwrap();
    assert_eq!(
        render_cpu(&prepared, corner, &[color; 2]).unwrap(),
        hard[2..]
    );

    graph["graph"]["nodes"][0]["operation"]["start"] = json!([0.125, 0.0]);
    graph["graph"]["nodes"][0]["operation"]["end"] = json!([0.625, 0.0]);
    graph["graph"]["nodes"][1]["operation"]["center"] = json!([0.4375, 0.5]);
    graph["graph"]["nodes"][1]["operation"]["radii"] = json!([0.5, 1.0]);
    graph["graph"]["nodes"][1]["operation"]["feather"] = json!(0.5);
    let prepared =
        Prepared::from_039(&serde_json::to_vec(&graph).unwrap(), Root::Monitor("light")).unwrap();
    let feather = Region::new([8, 1], [6, 0], [2, 1]).unwrap();
    let feathered = render_cpu(&prepared, feather, &[color; 2]).unwrap();
    assert_eq!(feathered[0], [0.75, -0.375, 1.5, 0.75]); // r=0.75, the midpoint of [0.5,1].
    assert_eq!(feathered[1], color); // r=1, the feather ends at zero.
    graph["graph"]["nodes"][1]["operation"]["feather"] = json!(f32::EPSILON / 8.0);
    assert!(matches!(
        Prepared::from_039(&serde_json::to_vec(&graph).unwrap(), Root::Monitor("light")),
        Err(SceneError::Unsupported(message)) if message.contains("no nonzero F32 interval")
    ));
}

#[test]
fn cpu_parallel_preserves_base_skip_weight_one_replacement_and_early_finite_gate() {
    let mut graph = json!({"schemaVersion":1,"graph":{"output":"mix","nodes":[
        {"id":"a","name":"Brighter","operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":1.0,"curve":[],"strength":1,"enabled":true}},
        {"id":"b","name":"Darker","operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":-1.0,"curve":[],"strength":1,"enabled":true}},
        {"id":"mix","name":"Mix","operation":{"kind":"parallel","base":"$input","enabled":true,
            "layers":[{"image":"a","weight":0.25,"mode":"normal"},{"image":"$input","weight":1,"mode":"normal"},
                      {"image":"b","weight":0.5,"mode":"normal"}]}}
    ]}});
    let full = Region::new([1, 1], [0, 0], [1, 1]).unwrap();
    let run = |document: &Value, input| {
        let plan = Prepared::from_039(&serde_json::to_vec(document).unwrap(), Root::Final).unwrap();
        render_cpu(&plan, full, &[input])
    };
    let color = [1.0, -0.5, 0.25, 1.0];
    assert_eq!(run(&graph, color).unwrap(), [color]);
    let layers = &mut graph["graph"]["nodes"][2]["operation"]["layers"];
    *layers = json!([{"image":"a","weight":0.25,"mode":"normal"},{"image":"b","weight":1,"mode":"normal"},
                     {"image":"a","weight":0.75,"mode":"normal"}]);
    assert_eq!(run(&graph, color).unwrap(), [[1.25, -0.625, 0.3125, 1.0]]);
    let mut layers = vec![json!({"image":"a","weight":0.75,"mode":"normal"}); 5];
    layers.push(json!({"image":"b","weight":1,"mode":"normal"}));
    graph["graph"]["nodes"][2]["operation"]["layers"] = json!(layers);
    // Both branch results are finite. A repeated accumulation overflows before the final
    // weight-one replacement can hide it.
    assert!(matches!(
        run(&graph, [f32::MAX * 0.25, 0.0, 0.0, 1.0]),
        Err(SceneError::Render(_))
    ));
}

#[test]
fn cpu_ap1_top_level_roots_and_non_centered_roi() {
    let mut document = scene();
    let encoded = serde_json::to_vec(&document).unwrap();
    let final_plan = Prepared::from_039(&encoded, Root::Final).unwrap();
    let monitor = Prepared::from_039(&encoded, Root::Monitor("warm")).unwrap();
    let disabled = Prepared::from_039(&encoded, Root::Monitor("off")).unwrap();
    let full = Region::new([27, 13], [0, 0], [27, 13]).unwrap();
    let roi = Region::new([27, 13], [4, 2], [17, 8]).unwrap();
    let input = input();
    let final_pixels = render_cpu(&final_plan, full, &input).unwrap();
    let monitor_pixels = render_cpu(&monitor, full, &input).unwrap();
    assert_eq!(final_plan.plan().step_count(), 5);
    assert_eq!(monitor.plan().step_count(), 2);
    assert_eq!(disabled.plan().step_count(), 0);
    assert_eq!(render_cpu(&disabled, full, &input).unwrap(), input);
    assert_eq!(monitor_pixels[0], [0.0; 4]);
    assert_eq!(
        monitor_pixels[1], input[1],
        "zero coverage must preserve signed or superwhite RGB"
    );
    assert!(final_pixels.iter().any(|p| p[2] > 1.0));
    assert!(final_pixels.iter().any(|p| p[2] < 0.0));
    assert!(final_pixels.iter().zip(&input).all(|(a, b)| a[3] == b[3]));
    assert_ne!(monitor_pixels, final_pixels);
    for (prepared, pixels) in [(&final_plan, &final_pixels), (&monitor, &monitor_pixels)] {
        assert_eq!(
            render_cpu(prepared, roi, &roi.crop(&input).unwrap()).unwrap(),
            roi.crop(pixels).unwrap()
        );
    }
    document["graph"]["nodes"][5]["operation"]["layers"]
        .as_array_mut()
        .unwrap()
        .swap(0, 1);
    let reversed =
        Prepared::from_039(&serde_json::to_vec(&document).unwrap(), Root::Final).unwrap();
    assert_ne!(render_cpu(&reversed, full, &input).unwrap(), final_pixels);
    assert!(Prepared::from_039(&encoded, Root::Monitor("mask")).is_err());
    assert!(Prepared::from_039(&encoded, Root::Monitor("group/node")).is_err());
    document["graph"]["nodes"][5]["operation"]["layers"][0]["mode"] = json!("screen");
    assert!(Prepared::from_039(&serde_json::to_vec(&document).unwrap(), Root::Final).is_err());
    assert!(Region::new([27, 13], [26, 0], [2, 1]).is_err());
}

#[test]
fn cpu_ap1_curve_uses_exposed_unpremultiplied_luma_and_preserves_alpha() {
    let graph = json!({"schemaVersion":1,"graph":{"output":"curve","nodes":[{"id":"curve","name":"Curve",
        "operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":1.0,
                     "curve":[[-2.0,-2.0],[0.0,0.5],[2.0,2.0]],"strength":1.0,"enabled":true}}]}});
    let frame = Region::new([3, 1], [0, 0], [3, 1]).unwrap();
    let plan = Prepared::from_039(&serde_json::to_vec(&graph).unwrap(), Root::Final).unwrap();
    let input = [
        [0.25, 0.25, 0.25, 0.5],
        [-0.125, -0.25, -0.5, 0.75],
        [-0.2, 6.0, 0.0, 0.0],
    ];
    let got = render_cpu(&plan, frame, &input).unwrap();
    assert!((got[0][1] - 0.5 * 2f32.sqrt()).abs() < 1e-6);
    assert_eq!(got[0][3], 0.5);
    assert_eq!(got[1], [-0.25, -0.5, -1.0, 0.75]);
    assert_eq!(got[2], [0.0; 4]);
    assert!(render_cpu(&plan, frame, &[[f32::INFINITY, 0.0, 0.0, 1.0]; 3]).is_err());
    assert!(render_cpu(&plan, frame, &[[f32::MAX, 0.0, 0.0, 1.0]; 3]).is_err());
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires physical Metal on macOS or physical Vulkan on Linux"]
fn strict_wgsl_ap1_matches_cpu_and_rebinds_the_same_plan() {
    use rawmaster_image::gpu::ap1_scene::{Backend, SceneDevice, DEFAULT_BUDGET_BYTES};
    let backend = if cfg!(target_os = "macos") {
        Backend::Metal
    } else {
        Backend::Vulkan
    };
    let mut device = SceneDevice::open(
        backend,
        std::env::var("RAWMASTER_AP1_ADAPTER").ok().as_deref(),
    )
    .unwrap();
    let mut document = scene();
    let frame = Region::new([27, 13], [0, 0], [27, 13]).unwrap();
    let roi = Region::new([27, 13], [4, 2], [17, 8]).unwrap();
    let source = input();
    for root in [Root::Final, Root::Monitor("warm"), Root::Monitor("off")] {
        let untouched = matches!(&root, Root::Monitor("off"));
        let masked = matches!(&root, Root::Monitor("warm"));
        let prepared = Prepared::from_039(&serde_json::to_vec(&document).unwrap(), root).unwrap();
        let program = device.compile(prepared.plan()).unwrap();
        let (full, receipt) = device
            .render(&program, &prepared, frame, &source, DEFAULT_BUDGET_BYTES)
            .unwrap();
        let (sub, _) = device
            .render(
                &program,
                &prepared,
                roi,
                &roi.crop(&source).unwrap(),
                DEFAULT_BUDGET_BYTES,
            )
            .unwrap();
        assert!(device
            .render(&program, &prepared, frame, &source, 0)
            .is_err());
        assert_pixels(&full, &render_cpu(&prepared, frame, &source).unwrap());
        assert_bit_exact(&sub, &roi.crop(&full).unwrap());
        assert_pixels(
            &sub,
            &render_cpu(&prepared, roi, &roi.crop(&source).unwrap()).unwrap(),
        );
        if untouched {
            assert_bit_exact(&full, &source);
        }
        if masked {
            assert_bit_exact(&full[..1], &[[0.0; 4]]);
            assert_bit_exact(&full[1..2], &source[1..2]);
        }
        let report = serde_json::to_value(receipt).unwrap();
        assert_eq!(report["executor"], "wgpu");
        assert_eq!(report["graphicsAPI"], backend.name());
        assert_eq!(report["fallbackCount"], 0);
        assert_eq!(report["dispatches"], 1);
        assert_eq!(report["nodes"], prepared.plan().step_count());
    }
    let initial = Prepared::from_039(&serde_json::to_vec(&document).unwrap(), Root::Final).unwrap();
    let program = device.compile(initial.plan()).unwrap();
    document["graph"]["nodes"][1]["operation"]["exposureEV"] = json!(0.5);
    let changed = Prepared::from_039(&serde_json::to_vec(&document).unwrap(), Root::Final).unwrap();
    assert_eq!(changed.plan(), initial.plan());
    let (actual, _) = device
        .render(&program, &changed, frame, &source, DEFAULT_BUDGET_BYTES)
        .unwrap();
    assert_pixels(&actual, &render_cpu(&changed, frame, &source).unwrap());
    assert_ne!(actual, render_cpu(&initial, frame, &source).unwrap());
}

#[cfg(feature = "gpu")]
fn assert_pixels(actual: &[Pixel], expected: &[Pixel]) {
    use rawmaster_image::scene::ap1::RGB_SCALED_TOLERANCE;
    assert_eq!(actual.len(), expected.len());
    for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
        assert_eq!(actual[3].to_bits(), expected[3].to_bits());
        for channel in 0..3 {
            let absolute = (f64::from(actual[channel]) - f64::from(expected[channel])).abs();
            assert!(
                absolute <= RGB_SCALED_TOLERANCE * f64::from(expected[channel].abs().max(1.0)),
                "pixel {index} channel {channel}: {actual:?} vs {expected:?}"
            );
        }
    }
}

#[cfg(feature = "gpu")]
fn assert_bit_exact(actual: &[Pixel], expected: &[Pixel]) {
    assert_eq!(actual.len(), expected.len());
    for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
        assert_eq!(
            actual.map(f32::to_bits),
            expected.map(f32::to_bits),
            "pixel {index}"
        );
    }
}

#[cfg(feature = "gpu")]
#[test]
#[ignore = "requires physical Metal on macOS or physical Vulkan on Linux"]
fn strict_wgsl_six_mp_shape_matches_cpu_on_small_full_and_roi() {
    use rawmaster_image::gpu::ap1_scene::{Backend, SceneDevice, DEFAULT_BUDGET_BYTES};
    let backend = if cfg!(target_os = "macos") {
        Backend::Metal
    } else {
        Backend::Vulkan
    };
    let mut device = SceneDevice::open(
        backend,
        std::env::var("RAWMASTER_AP1_ADAPTER").ok().as_deref(),
    )
    .unwrap();
    let encoded = serde_json::to_vec(&six_mp_scene()).unwrap();
    let full = Region::new([27, 13], [0, 0], [27, 13]).unwrap();
    let roi = Region::new([27, 13], [4, 2], [17, 8]).unwrap();
    let input = input();
    let crop = roi.crop(&input).unwrap();
    for root in [Root::Final, Root::Monitor("light")] {
        let prepared = Prepared::from_039(&encoded, root).unwrap();
        let program = device.compile(prepared.plan()).unwrap();
        let (actual, _) = device
            .render(&program, &prepared, full, &input, DEFAULT_BUDGET_BYTES)
            .unwrap();
        let (part, _) = device
            .render(&program, &prepared, roi, &crop, DEFAULT_BUDGET_BYTES)
            .unwrap();
        assert_pixels(&actual, &render_cpu(&prepared, full, &input).unwrap());
        assert_pixels(&part, &render_cpu(&prepared, roi, &crop).unwrap());
        assert_bit_exact(&part, &roi.crop(&actual).unwrap());
    }
}
