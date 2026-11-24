use serde::{de::Error, Deserialize, Deserializer};
use serde_json::value::RawValue;
use std::f64::consts::PI;

#[derive(Clone, Copy)]
struct Control(f64);

impl<'de> Deserialize<'de> for Control {
    fn deserialize<D: Deserializer<'de>>(input: D) -> Result<Self, D::Error> {
        let token = <&RawValue>::deserialize(input)?;
        token.get().parse().map(Self).map_err(D::Error::custom)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Wheel {
    hue_degrees: Control,
    saturation: Control,
    luminance: Control,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Grading {
    shadows: Wheel,
    midtones: Wheel,
    highlights: Wheel,
    global: Wheel,
    blending: Control,
    balance: Control,
}

pub(crate) struct Table {
    pub rows: [[f32; 4]; 5],
    pub active: bool,
}

pub(crate) fn prepare(json: &str) -> Result<Table, String> {
    #[derive(Deserialize)]
    struct Parameters {
        grading: Grading,
    }

    let Parameters { grading } = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let (blending, balance) = (grading.blending.0, grading.balance.0);
    if !(0.0..=100.0).contains(&blending) || !(-100.0..=100.0).contains(&balance) {
        return Err("color_grading_v2 blending or balance outside its control range".into());
    }
    let mut table = Table {
        rows: [[0.0; 4]; 5],
        active: false,
    };
    for (row, wheel) in table.rows.iter_mut().zip([
        grading.shadows,
        grading.midtones,
        grading.highlights,
        grading.global,
    ]) {
        let (h, s, l) = (wheel.hue_degrees.0, wheel.saturation.0, wheel.luminance.0);
        if !(0.0..360.0).contains(&h)
            || !(0.0..=100.0).contains(&s)
            || !(-100.0..=100.0).contains(&l)
        {
            return Err("color_grading_v2 wheel outside its control range".into());
        }
        table.active |= s != 0.0 || l != 0.0;
        let angle = h * PI / 180.0;
        let r = libm::cos(angle);
        let g = libm::cos(angle - 2.0 * PI / 3.0);
        let b = libm::cos(angle + 2.0 * PI / 3.0);
        let gray = r * 0.2126 + g * 0.7152 + b * 0.0722;
        let scale = 0.15 * s / 100.0;
        *row = [r - gray, g - gray, b - gray, 0.0].map(|v| (v * scale) as f32);
        row[3] = (0.25 * l / 100.0) as f32;
    }
    let blend = (blending / 100.0) as f32;
    let balance = (balance / 100.0) as f32;
    let radius = 0.4_f32.mul_add(blend, 0.1);
    let center = (-0.25_f32).mul_add(balance, 0.5);
    // Store the rounded lower edge and radius separately. Subtracting that
    // edge from the center can round to a different shadow interval on Metal.
    table.rows[4] = [blend, balance, center - radius, radius];
    Ok(table)
}
