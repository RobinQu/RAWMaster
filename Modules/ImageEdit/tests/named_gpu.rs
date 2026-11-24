#![cfg(feature = "gpu")]

use rawmaster_image::gpu::{Gpu, Mode};
use rawmaster_image::{render_cpu, CoveragePlane, Frame, Pixel, Plan};
use serde_json::json;

fn two_masks(ev: f32, sky: &str) -> Plan {
    let recipe = json!({"version":2, "working":"extended-linear-srgb-premul-f32", "output":"out",
        "nodes":[{"id":"out","op":"blend","base":"source","layer":"local","mask":"near"},
                 {"id":sky,"op":"mask"},{"id":"near","op":"mask"},{"id":"source","op":"source"},
                 {"id":"local","op":"masked_exposure","image":"source","ev":ev,"mask":sky}]});
    Plan::parse(&recipe.to_string()).unwrap()
}

fn matches_cpu(got: &[Pixel], expected: &[Pixel]) {
    assert_eq!(got.len(), expected.len());
    for (pixel, reference) in got.iter().zip(expected) {
        for (a, b) in pixel.iter().zip(reference) {
            assert!((a - b).abs() < 2e-6, "{pixel:?} != {reference:?}");
        }
    }
}

#[test]
#[ignore = "requires a Metal or Vulkan adapter"]
fn named_gpu_fused_staged_tiles_and_immutable_rebinding() {
    let (w, h) = (37, 7);
    let n = (w * h) as usize;
    let pixels = vec![[-0.25, 0.125, 2.0, 0.5]; n];
    let sky: Vec<_> = (0..n).map(|i| (i % 13) as f32 / 12.0).collect();
    let near: Vec<_> = (0..n).map(|i| (i / 7 % 5) as f32 / 4.0).collect();
    let planes = [
        CoveragePlane {
            id: "sky",
            values: &sky,
        },
        CoveragePlane {
            id: "near",
            values: &near,
        },
    ];
    let frame = Frame::with_named_coverage(w, h, &pixels, &planes, false).unwrap();
    let base = two_masks(-1.25, "sky");
    let edit = two_masks(0.75, "sky");
    let renamed = two_masks(-1.25, "sky2");
    let gpu = Gpu::open().unwrap();
    for mode in [Mode::Fused, Mode::Staged] {
        let program = gpu.compile(&base, mode).unwrap();
        let resident = gpu.bind(&program, &base, &frame).unwrap();
        let bindings = if matches!(mode, Mode::Fused) { 1 } else { 2 };
        assert_eq!(resident.dispatches(), bindings);
        assert_eq!(
            program.bytes_per_pixel_with_readback(),
            16 * resident.rgba_slots() as u64 + 8 + 16
        );
        for plan in [&base, &edit, &base] {
            resident.update(plan).unwrap();
            resident.submit();
            matches_cpu(
                &resident.read().unwrap(),
                &render_cpu(plan, &frame).unwrap(),
            );
        }
        assert!(resident.update(&renamed).is_err());
        resident.submit();
        matches_cpu(
            &resident.read().unwrap(),
            &render_cpu(&base, &frame).unwrap(),
        );
        let one_row = u64::from(w) * program.bytes_per_pixel_with_readback();
        let fixed_bytes = 16 + 48 * 5 + 16;
        assert!(gpu
            .render_bounded(&program, &base, &frame, fixed_bytes + one_row - 1)
            .is_err());
        let (from_strips, strips) = gpu
            .render_bounded(&program, &base, &frame, fixed_bytes + 2 * one_row)
            .unwrap();
        assert_eq!(strips, 4);
        matches_cpu(&from_strips, &render_cpu(&base, &frame).unwrap());
        let reversed = [
            CoveragePlane {
                id: "near",
                values: &near,
            },
            CoveragePlane {
                id: "sky",
                values: &sky,
            },
        ];
        let same = Frame::with_named_coverage(w, h, &pixels, &reversed, false).unwrap();
        let (pixels_again, _) = gpu
            .render_bounded(&program, &base, &same, fixed_bytes + 2 * one_row)
            .unwrap();
        assert_eq!(pixels_again, from_strips);
    }
}

#[test]
#[ignore = "requires a Metal or Vulkan adapter"]
fn maximum_named_gpu_plan_uses_every_plane_in_the_last_short_strip() {
    let ids: Vec<_> = (0..32).map(|i| format!("mask{i:02}")).collect();
    let mut nodes = vec![json!({"id":"source","op":"source"})];
    let mut previous = "source".to_string();
    for (i, id) in ids.iter().enumerate() {
        nodes.push(json!({"id":id,"op":"mask"}));
        let next = format!("local{i}");
        nodes.push(json!({"id":next,"op":"masked_exposure","image":previous,"mask":id,"ev":1.0}));
        previous = next;
    }
    for i in 0..63 {
        let next = format!("identity{i}");
        nodes.push(json!({"id":next,"op":"exposure","image":previous,"ev":0.0}));
        previous = next;
    }
    assert_eq!(nodes.len(), 128);
    let recipe = json!({"version":2,"working":"extended-linear-srgb-premul-f32","output":previous,"nodes":nodes});
    let plan = Plan::parse(&recipe.to_string()).unwrap();
    let (w, h) = (11, 3);
    let n = (w * h) as usize;
    let pixels = vec![[0.125, 0.25, -0.25, 1.0]; n];
    // Pixel k enables only plane k. The final pixel checks simultaneous coverage in all 32 planes.
    let masks: Vec<_> = (0..32)
        .map(|slot| {
            (0..n)
                .map(|p| {
                    if p == slot {
                        (slot + 1) as f32 / 32.0
                    } else if p == n - 1 {
                        1.0 / 32.0
                    } else {
                        0.0
                    }
                })
                .collect::<Vec<_>>()
        })
        .collect();
    let planes: Vec<_> = ids
        .iter()
        .zip(&masks)
        .rev()
        .map(|(id, values)| CoveragePlane { id, values })
        .collect();
    let frame = Frame::with_named_coverage(w, h, &pixels, &planes, false).unwrap();
    let gpu = Gpu::open().unwrap();
    let program = gpu.compile(&plan, Mode::Fused).unwrap();
    assert_eq!(
        program.bytes_per_pixel_with_readback(),
        16 * 2 + 4 * 32 + 16
    );
    let (actual, strips) = gpu
        .render_bounded(
            &program,
            &plan,
            &frame,
            16 + 48 * 128 + 16 + 2 * u64::from(w) * program.bytes_per_pixel_with_readback(),
        )
        .unwrap();
    assert_eq!(strips, 2);
    matches_cpu(&actual, &render_cpu(&plan, &frame).unwrap());
}
