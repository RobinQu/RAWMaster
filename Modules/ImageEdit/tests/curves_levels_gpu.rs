#![cfg(feature = "gpu")]

use rawmaster_image::{
    gpu::{Gpu, Mode},
    render_cpu, CoveragePlane, Frame, Plan,
};
use serde_json::json;

fn graph(midtone: Option<f64>) -> Plan {
    let mut points = vec![json!({"x":0,"y":0.06})];
    if let Some(midtone) = midtone {
        points.push(json!({"x":0.45,"y":midtone}));
    }
    points.push(json!({"x":1,"y":0.93}));
    let curve = json!({"points":points,"inputBlack":0.03,"inputWhite":0.94});
    let handles = json!({"black":0.08,"shadows":0.24,"midtones":0.51,"highlights":0.51,"white":0.92,
        "outputBlack":0.04,"outputWhite":0.96});
    Plan::parse(
        &json!({"version":2,"working":"extended-linear-srgb-premul-f32","output":"out","nodes":[
            {"id":"out","op":"blend","base":"source","layer":"second","mask":"subject"},
            {"id":"subject","op":"mask"},{"id":"source","op":"source"},
            {"id":"first","op":"curves_levels_v3","image":"source","curves":{"rgb":curve}},
            {"id":"second","op":"curves_levels_v3","image":"first","levels":{"luminance":handles,"blue":handles}}
        ]})
        .to_string(),
    )
    .unwrap()
}

#[test]
#[ignore = "requires a Metal or Vulkan adapter"]
fn curves_levels_tables_rebind_in_fused_staged_and_bounded_dispatch() {
    let width = 19;
    let height = 7;
    let count = width * height;
    let pixels: Vec<_> = (0..count)
        .map(|i| {
            let x = (i % width) as f32 / (width - 1) as f32;
            match i % 5 {
                0 => [-0.0, 0.0, 0.0, -0.0],
                1 => [x * 0.66, (1.0 - x) * 0.24, x * 0.33 - 0.015, 0.5],
                _ => [x * 1.3, 0.98 - x * 0.8, x * x, 1.0],
            }
        })
        .collect();
    let coverage: Vec<_> = (0..count).map(|i| (i % 3) as f32 * 0.5).collect();
    let planes = [CoveragePlane {
        id: "subject",
        values: &coverage,
    }];
    let frame = Frame::with_named_coverage(width, height, &pixels, &planes, false).unwrap();
    let first = graph(Some(0.61));
    let updated = graph(None);
    let overflow = [[f32::MAX, 0.0, 0.0, f32::MIN_POSITIVE]];
    let full = [CoveragePlane {
        id: "subject",
        values: &[1.0],
    }];
    let invalid = Frame::with_named_coverage(1, 1, &overflow, &full, false).unwrap();
    assert!(render_cpu(&first, &invalid).is_err());
    let expected_first = render_cpu(&first, &frame).unwrap();
    let expected_updated = render_cpu(&updated, &frame).unwrap();
    assert_ne!(expected_first, expected_updated);
    let compare = |results: &[rawmaster_image::Pixel], expected: &[rawmaster_image::Pixel]| {
        assert_eq!(results.len(), pixels.len());
        for (i, (actual, reference)) in results.iter().zip(expected).enumerate() {
            assert_eq!(actual[3].to_bits(), pixels[i][3].to_bits());
            if coverage[i] == 0.0 {
                assert_eq!(actual.map(f32::to_bits), pixels[i].map(f32::to_bits));
            }
            for c in 0..3 {
                assert!(
                    (actual[c] - reference[c]).abs() <= 2e-6,
                    "{i}: {actual:?} != {reference:?}"
                );
            }
        }
    };

    let gpu = Gpu::open().unwrap();
    for mode in [Mode::Fused, Mode::Staged] {
        let program = gpu.compile(&first, mode).unwrap();
        let resident = gpu.bind(&program, &first, &frame).unwrap();
        for (plan, expected) in [
            (&first, &expected_first),
            (&updated, &expected_updated),
            (&first, &expected_first),
        ] {
            resident.update(plan).unwrap();
            resident.submit();
            compare(&resident.read().unwrap(), expected);
        }
        assert!(gpu
            .render_bounded(&program, &updated, &frame, 4096)
            .is_err());
        let (result, tiles) = gpu
            .render_bounded(&program, &updated, &frame, 8000)
            .unwrap();
        assert!(tiles > 1);
        compare(&result, &expected_updated);
        let rejected = gpu.bind(&program, &first, &invalid).unwrap();
        rejected.submit();
        assert!(rejected.read().is_err());
    }
}
