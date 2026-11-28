use rawmaster_image::scene::ap1::{render_cpu, Prepared, Region, Root};
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
