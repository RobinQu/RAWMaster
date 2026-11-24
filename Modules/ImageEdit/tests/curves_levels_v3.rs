use rawmaster_image::{render_cpu, Frame, Plan};
use serde_json::{json, Value};

fn recipe(version: u32, nodes: Vec<Value>) -> String {
    let output = nodes.last().unwrap()["id"].clone();
    let mut all = vec![json!({"id":"source","op":"source"})];
    all.extend(nodes);
    json!({"version":version,"working":"extended-linear-srgb-premul-f32","nodes":all,"output":output}).to_string()
}

fn node() -> Value {
    json!({"id":"curves","op":"curves_levels_v3","image":"source"})
}

fn curve(points: Vec<[f64; 2]>, black: f64, white: f64) -> Value {
    let pairs: Vec<_> = points
        .into_iter()
        .map(|[x, y]| json!({"x":x,"y":y}))
        .collect();
    json!({"points":pairs,"inputBlack":black,"inputWhite":white})
}

fn levels(output_black: f64, output_white: f64) -> Value {
    json!({"black":0,"shadows":0.25,"midtones":0.5,"highlights":0.75,"white":1,
           "outputBlack":output_black,"outputWhite":output_white})
}

fn render(nodes: Vec<Value>, pixels: &[[f32; 4]]) -> Result<Vec<[f32; 4]>, String> {
    let plan = Plan::parse(&recipe(2, nodes))?;
    let frame = Frame::with_named_coverage(pixels.len() as u32, 1, pixels, &[], false)?;
    render_cpu(&plan, &frame)
}

#[test]
fn only_v2_prepares_fully_validated_pchip_and_manual_handles() {
    assert!(Plan::parse(&recipe(1, vec![node()])).is_err());
    let mut n = node();
    let diagonal = vec![[0.0, 0.0], [1.0, 1.0]];
    let good = curve(diagonal.clone(), 0.0, 1.0);
    n["curves"] = json!({"red":good});
    assert!(Plan::parse(&recipe(2, vec![n.clone()])).is_ok());
    for bad in [
        curve(vec![[0.0, 0.0], [0.00009, 0.7], [1.0, 1.0]], 0.0, 1.0),
        curve(vec![[0.1, 0.2], [1.0, 1.0]], 0.0, 1.0),
        curve(vec![[0.0, 0.0], [1.0, 1.000000001]], 0.0, 1.0),
        curve((0..17).map(|i| [i as f64 / 16.0, 0.5]).collect(), 0.0, 1.0),
        curve(diagonal, 0.50000000001, 0.50000000002),
        Value::Null,
    ] {
        n["curves"]["red"] = bad;
        assert!(Plan::parse(&recipe(2, vec![n.clone()])).is_err());
    }
    let mut invalid_level = levels(0.1, 0.9);
    invalid_level["highlights"] = json!(0.4);
    for bad in [
        json!({"luminance":invalid_level}),
        json!({"red":levels(0.9,0.1)}),
        json!({"blue":null}),
        json!({"cyan":levels(0.0,1.0)}),
        Value::Null,
    ] {
        let mut n = node();
        n["levels"] = bad;
        assert!(Plan::parse(&recipe(2, vec![n])).is_err());
    }
}

#[test]
fn inactive_channels_and_transparent_pixels_are_bitwise_preserved() {
    let pixels = [[-0.0, 0.0, -0.0, 0.0], [1.03, -0.11, 0.2101, 0.41]];
    let mut neutral = node();
    neutral["curves"] = json!({"blue":curve(vec![[0.,0.],[0.37,0.37],[1.,1.]],0.,1.)});
    for n in [node(), neutral] {
        let out = render(vec![n], &pixels).unwrap();
        for (a, b) in out.iter().zip(pixels) {
            assert_eq!(a.map(f32::to_bits), b.map(f32::to_bits));
        }
    }
    let mut active = node();
    active["levels"] = json!({"blue":levels(0.15,0.85)});
    let out = render(vec![active.clone()], &pixels).unwrap();
    assert_eq!(out[0].map(f32::to_bits), pixels[0].map(f32::to_bits));
    assert_eq!(out[1][3].to_bits(), pixels[1][3].to_bits());
    assert_ne!(out[1][2], pixels[1][2]);
    assert!(render(vec![active], &[[f32::MAX, 0., 0., f32::MIN_POSITIVE]]).is_err());
}

#[test]
fn level_luma_then_master_then_channel_and_extended_range() {
    let mut n = node();
    n["curves"] = json!({"rgb":curve(vec![[0.,0.1],[1.,0.9]],0.,1.),
                         "red":curve(vec![[0.,0.15],[1.,0.95]],0.,1.)});
    n["levels"] =
        json!({"luminance":levels(0.02,0.91),"rgb":levels(0.03,0.97),"blue":levels(0.07,0.75)});
    let pixels = [[0.13, 0.040, 0.27, 0.5], [-0.23, 0.12, 1.7, 1.0]];
    let out = render(vec![n], &pixels).unwrap();
    let encode = |v: f64| {
        v.signum()
            * if v.abs() <= 0.0031308 {
                12.92 * v.abs()
            } else {
                1.055 * v.abs().powf(1.0 / 2.4) - 0.055
            }
    };
    let decode = |v: f64| {
        v.signum()
            * if v.abs() <= 0.04045 {
                v.abs() / 12.92
            } else {
                ((v.abs() + 0.055) / 1.055).powf(2.4)
            }
    };
    // Two-point line and equispaced handles both extrapolate with a unit slope outside.
    let mapping = |x: f64, low: f64, high: f64| {
        if x < 0.0 {
            x + low
        } else if x > 1.0 {
            x + high - 1.0
        } else {
            low + (high - low) * x
        }
    };
    for (p, result) in pixels.iter().zip(out) {
        let alpha = p[3] as f64;
        let mut c = [0.0; 3];
        for i in 0..3 {
            c[i] = mapping(encode(p[i] as f64 / alpha), 0.1, 0.9);
        }
        c[0] = mapping(c[0], 0.15, 0.95);
        let y = c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722;
        let delta = mapping(y, 0.02, 0.91) - y;
        for x in &mut c {
            *x = mapping(*x + delta, 0.03, 0.97);
        }
        c[2] = mapping(c[2], 0.07, 0.75);
        for i in 0..3 {
            assert!((result[i] as f64 - decode(c[i]) * alpha).abs() < 2e-6);
        }
        assert_eq!(result[3].to_bits(), p[3].to_bits());
    }
}

#[test]
fn multiple_nodes_keep_their_own_prepared_tables() {
    let mut a = node();
    a["levels"] = json!({"blue":levels(0.12,0.8)});
    let mut b = node();
    b["curves"] = json!({"rgb":curve(vec![[0.,0.11],[0.32,0.6],[1.,0.92]],0.03,0.95)});
    let pixels = [[-0.2, 0.17, 0.84, 1.0], [0.3, 0.07, 0.2, 0.5]];
    let first = render(vec![a.clone()], &pixels).unwrap();
    let second = render(vec![b.clone()], &first).unwrap();
    b["id"] = json!("end");
    b["image"] = json!("curves");
    let joint = render(vec![a, b], &pixels).unwrap();
    assert_eq!(joint, second);
}
