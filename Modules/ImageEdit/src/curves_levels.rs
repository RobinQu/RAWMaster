use serde::{de::Error, Deserialize, Deserializer};
use serde_json::value::RawValue;

pub(crate) const TABLE_ROWS: usize = 150;
pub(crate) type Table = [[f32; 4]; TABLE_ROWS];

// This operator prepares its coefficients at the same binary64 values as Swift.
// Read the decimal token before serde_json's normal f64 conversion. Legacy graph
// operators intentionally retain their existing number parser.
#[derive(Clone, Copy)]
struct Number(f64);

impl<'de> Deserialize<'de> for Number {
    fn deserialize<D: Deserializer<'de>>(input: D) -> Result<Self, D::Error> {
        let token = <&RawValue>::deserialize(input)?;
        let value: f64 = token.get().parse().map_err(D::Error::custom)?;
        if !(0.0..=1.0).contains(&value) {
            return Err(D::Error::custom("expected a finite control in [0,1]"));
        }
        Ok(Self(value))
    }
}

// Only an absent channel denotes identity. An explicit manual level can have an
// identity-shaped mapping and still takes part in the signed sRGB round trip.
struct Channel<T>(Option<T>);

impl<T> Default for Channel<T> {
    fn default() -> Self {
        Self(None)
    }
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Channel<T> {
    fn deserialize<D: Deserializer<'de>>(input: D) -> Result<Self, D::Error> {
        T::deserialize(input).map(|value| Self(Some(value)))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Point {
    x: Number,
    y: Number,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Curve {
    points: Vec<Point>,
    input_black: Number,
    input_white: Number,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Levels {
    black: Number,
    shadows: Number,
    midtones: Number,
    highlights: Number,
    white: Number,
    output_black: Number,
    output_white: Number,
}

#[derive(Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct CurveChannels {
    rgb: Channel<Curve>,
    red: Channel<Curve>,
    green: Channel<Curve>,
    blue: Channel<Curve>,
}

#[derive(Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct LevelChannels {
    luminance: Channel<Levels>,
    rgb: Channel<Levels>,
    red: Channel<Levels>,
    green: Channel<Levels>,
    blue: Channel<Levels>,
}

#[derive(Deserialize)]
struct Parameters {
    #[serde(default)]
    curves: CurveChannels,
    #[serde(default)]
    levels: LevelChannels,
}

pub(crate) fn prepare(json: &str) -> Result<Box<Table>, String> {
    // The tagged graph node has already checked id, image, op and unknown keys.
    let p: Parameters = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let mut table = Box::new([[0.0; 4]; TABLE_ROWS]);
    table[2] = [1.0; 4];
    let curves = [p.curves.rgb, p.curves.red, p.curves.green, p.curves.blue];
    for (channel, curve) in curves.into_iter().enumerate() {
        if let Some(curve) = curve.0 {
            write_curve(&mut table, channel, &curve)?;
        }
    }
    let levels = [
        p.levels.luminance,
        p.levels.rgb,
        p.levels.red,
        p.levels.green,
        p.levels.blue,
    ];
    for (channel, levels) in levels.into_iter().enumerate() {
        if let Some(levels) = levels.0 {
            write_levels(&mut table, channel, &levels)?;
        }
    }
    Ok(table)
}

pub(crate) fn active(table: &Table) -> bool {
    table[0] != [0.0; 4] || table[3] != [0.0; 4] || table[4][0] != 0.0
}

fn endpoint(a: f64, b: f64, da: f64, db: f64) -> f64 {
    let slope = ((2.0 * a + b) * da - a * db) / (a + b);
    if slope * da <= 0.0 {
        0.0
    } else if da * db < 0.0 && slope.abs() > 3.0 * da.abs() {
        3.0 * da
    } else {
        slope
    }
}

fn write_curve(table: &mut Table, channel: usize, curve: &Curve) -> Result<(), String> {
    let points = &curve.points;
    let count = points.len();
    if !(2..=16).contains(&count)
        || points[0].x.0 != 0.0
        || points[count - 1].x.0 != 1.0
        || points
            .windows(2)
            .any(|pair| pair[1].x.0 < pair[0].x.0 + 1e-4)
    {
        return Err("invalid PCHIP curve points".into());
    }
    let (black, white) = (curve.input_black.0, curve.input_white.0);
    if black >= white || black as f32 >= white as f32 {
        return Err("curve input range collapses at render precision".into());
    }
    if black == 0.0 && white == 1.0 && points.iter().all(|p| p.x.0 == p.y.0) {
        return Ok(());
    }
    let last = count - 1;
    let mut h = [0.0; 15];
    let mut delta = [0.0; 15];
    let mut slopes = [0.0; 16];
    for (i, pair) in points.windows(2).enumerate() {
        h[i] = pair[1].x.0 - pair[0].x.0;
        delta[i] = (pair[1].y.0 - pair[0].y.0) / h[i];
    }
    if count == 2 {
        slopes[0] = delta[0];
        slopes[1] = delta[0];
    } else {
        slopes[0] = endpoint(h[0], h[1], delta[0], delta[1]);
        slopes[last] = endpoint(h[last - 1], h[last - 2], delta[last - 1], delta[last - 2]);
        for i in 1..last {
            if delta[i - 1] * delta[i] > 0.0 {
                let w1 = 2.0 * h[i] + h[i - 1];
                let w2 = h[i] + 2.0 * h[i - 1];
                slopes[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i]);
            }
        }
    }

    table[0][channel] = last as f32;
    table[1][channel] = black as f32;
    table[2][channel] = white as f32;
    for (i, pair) in points.windows(2).enumerate() {
        let (y0, y1) = (pair[0].y.0, pair[1].y.0);
        let (m0, m1) = (slopes[i], slopes[i + 1]);
        let a = 2.0 * y0 - 2.0 * y1 + h[i] * (m0 + m1);
        let b = -3.0 * y0 + 3.0 * y1 - h[i] * (2.0 * m0 + m1);
        let row = 5 + 30 * channel + 2 * i;
        table[row] = [pair[0].x.0 as f32, pair[1].x.0 as f32, a as f32, 1.0];
        table[row + 1] = [b as f32, (h[i] * m0) as f32, y0 as f32, 1.0];
    }
    Ok(())
}

fn write_levels(table: &mut Table, channel: usize, p: &Levels) -> Result<(), String> {
    let positions = [
        p.black.0,
        p.shadows.0,
        p.midtones.0,
        p.highlights.0,
        p.white.0,
    ];
    if positions.windows(2).any(|p| p[0] > p[1])
        || p.black.0 >= p.white.0
        || p.output_black.0 > p.output_white.0
    {
        return Err("invalid manual level handles".into());
    }
    let low = p.output_black.0;
    let span = p.output_white.0 - low;
    let targets = [
        low,
        low + span * 0.25,
        low + span * 0.5,
        low + span * 0.75,
        p.output_white.0,
    ];
    let priorities = [3, 1, 2, 1, 3];
    let rows = &mut table[125 + 5 * channel..130 + 5 * channel];
    let mut count = 0;
    let mut previous_priority = 0;
    for i in 0..5 {
        let x = positions[i] as f32;
        if count > 0 && rows[count - 1][0] == x {
            if priorities[i] <= previous_priority {
                continue;
            }
        } else {
            count += 1;
        }
        rows[count - 1] = [x, targets[i] as f32, 0.0, 1.0];
        previous_priority = priorities[i];
    }
    table[3 + channel / 4][channel % 4] = count as f32;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packed_coefficients_and_coincident_level_handles_match_swift() {
        // Float32 bit patterns from DevelopmentCurve.segments() and
        // DevelopmentColorEngineV3.levelPoints(.manual(...)) for these controls.
        let table = prepare(r#"{
          "curves":{"rgb":{"points":[{"x":0,"y":0.035},{"x":0.13,"y":0.31},
                    {"x":0.44,"y":0.22},{"x":0.76,"y":0.81},{"x":1,"y":0.93}],
                    "inputBlack":0,"inputWhite":1}},
          "levels":{"luminance":{"black":0.12,"shadows":0.5000000001,"midtones":0.5000000002,
                     "highlights":0.5000000003,"white":0.92,"outputBlack":0.08,"outputWhite":0.88},
                    "blue":{"black":0.7000000001,"shadows":0.7000000002,"midtones":0.7000000003,
                     "highlights":0.7000000004,"white":0.7000000005,"outputBlack":0.07,"outputWhite":0.9}}
        }"#).unwrap();
        let expected = [
            [0, 1040522936, 3191536442, 1065353216],
            [1035516340, 1052515325, 1024416809, 1065353216],
            [1040522936, 1054951342, 1043878380, 1065353216],
            [3196730737, 0, 1050589266, 1065353216],
            [1054951342, 1061326684, 3211745619, 1065353216],
            [1069756872, 0, 1046562734, 1065353216],
            [1061326684, 1065353216, 3177596000, 1065353216],
            [3153584880, 1044132215, 1062165545, 1065353216],
        ];
        for (row, expected) in table[5..13].iter().zip(expected) {
            assert_eq!(row.map(f32::to_bits), expected);
        }
        assert_eq!(table[0], [4., 0., 0., 0.]);
        assert_eq!(table[3], [3., 0., 0., 0.]);
        assert_eq!(table[4], [1., 0., 0., 0.]);
        let levels = [
            [1039516303, 1034147594],
            [1056964608, 1056293519],
            [1064011039, 1063339950],
        ];
        for (row, pair) in table[125..128].iter().zip(levels) {
            assert_eq!(
                row.map(f32::to_bits),
                [pair[0], pair[1], 0, 1.0_f32.to_bits()]
            );
        }
        assert_eq!(
            table[145].map(f32::to_bits),
            [1060320051, 1032805417, 0, 1.0_f32.to_bits()]
        );
    }

    #[test]
    fn decimal_midpoint_is_rounded_through_binary64() {
        // Parsing this token one binary64 ULP low selects the previous Float32.
        let table = prepare(
            r#"{"curves":{"green":{"points":[{"x":0,"y":0},{"x":1,"y":1}],
                                             "inputBlack":0.36062721908092499,"inputWhite":1}}}"#,
        )
        .unwrap();
        assert_eq!(table[1][2].to_bits(), 1052288034);
    }
}
