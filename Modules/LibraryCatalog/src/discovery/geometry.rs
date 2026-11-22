use crate::Result;
use serde_json::Value;
use std::f64::consts::PI;
const EARTH: f64 = 6_371_008.8;
const EPS: f64 = 2e-10;
type V = [f64; 3];
pub type Bounds = (f64, f64, f64, f64);
pub struct Fence(Shape);
enum Shape {
    Circle(f64, f64, f64),
    Polygon { vertices: Vec<V>, orientation: f64 },
}
fn dot(a: V, b: V) -> f64 {
    a.iter().zip(b).map(|(a, b)| a * b).sum()
}
fn cross(a: V, b: V) -> V {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn norm(p: V) -> f64 {
    dot(p, p).sqrt()
}
fn scale(a: V, s: f64) -> V {
    a.map(|x| x * s)
}
fn unit(a: V) -> V {
    scale(a, 1. / norm(a))
}
fn vec(lat: f64, lon: f64) -> V {
    let (a, b) = (lat.to_radians(), lon.to_radians());
    [a.cos() * b.cos(), a.cos() * b.sin(), a.sin()]
}
fn arc(a: V, b: V) -> f64 {
    norm(cross(a, b)).atan2(dot(a, b))
}
fn on(a: V, b: V, p: V) -> bool {
    let n = cross(a, b);
    let len = norm(n);
    if len < EPS {
        return arc(a, p) <= EPS;
    }
    dot(n, p).abs() <= EPS * len && arc(a, p) + arc(p, b) <= arc(a, b) + EPS
}
pub fn valid(lat: f64, lon: f64) -> bool {
    lat.is_finite()
        && lon.is_finite()
        && (-90.0..=90.0).contains(&lat)
        && (-180.0..=180.0).contains(&lon)
}
impl Fence {
    pub fn parse(v: &Value) -> Result<Self> {
        let number = |x: &Value| {
            x.as_f64()
                .filter(|x| x.is_finite())
                .ok_or("expected coordinate")
        };
        match v["kind"].as_str() {
            Some("circle") => {
                let (a, b, r) = (
                    number(&v["latitude"])?,
                    number(&v["longitude"])?,
                    number(&v["radiusMeters"])?,
                );
                if !valid(a, b) || !(0.0..=EARTH * PI).contains(&r) {
                    return Err("invalid circle".into());
                }
                Ok(Self(Shape::Circle(a, b, r / EARTH)))
            }
            Some("polygon") => {
                let points = v["vertices"]
                    .as_array()
                    .filter(|p| (3..=256).contains(&p.len()))
                    .ok_or("expected 3–256 polygon vertices")?;
                let mut verts = Vec::new();
                for p in points {
                    let pair = p
                        .as_array()
                        .filter(|p| p.len() == 2)
                        .ok_or("vertex needs latitude and longitude")?;
                    let a = number(&pair[0])?;
                    let b = number(&pair[1])?;
                    if !valid(a, b) {
                        return Err("coordinate outside the globe".into());
                    }
                    verts.push(vec(a, b));
                }
                if verts.len() > 3 && arc(verts[0], *verts.last().unwrap()) <= EPS {
                    verts.pop();
                }
                let n = verts.len();
                let mut area = 0.0;
                for i in 0..n {
                    let (a, b) = (verts[i], verts[(i + 1) % n]);
                    let d = arc(a, b);
                    if d < EPS || PI - d < EPS {
                        return Err("degenerate polygon edge".into());
                    }
                    if i > 0 && i + 1 < n {
                        let p = verts[0];
                        area +=
                            2. * dot(p, cross(a, b)).atan2(1. + dot(p, a) + dot(a, b) + dot(b, p));
                    }
                    for j in i + 2..n {
                        if i == 0 && j + 1 == n {
                            continue;
                        }
                        let (c, d) = (verts[j], verts[(j + 1) % n]);
                        let axis = cross(cross(a, b), cross(c, d));
                        let length = norm(axis);
                        let crosses = if length < EPS * norm(cross(a, b)) * norm(cross(c, d)) {
                            on(a, b, c) || on(a, b, d) || on(c, d, a) || on(c, d, b)
                        } else {
                            let p = unit(axis);
                            (on(a, b, p) && on(c, d, p))
                                || (on(a, b, scale(p, -1.)) && on(c, d, scale(p, -1.)))
                        };
                        if crosses {
                            return Err("self-intersecting polygon".into());
                        }
                    }
                }
                let signed = (area + 2. * PI).rem_euclid(4. * PI) - 2. * PI;
                if signed.abs() < 1e-14 || (2. * PI - signed.abs()).abs() < EPS {
                    return Err("ambiguous polygon interior".into());
                }
                Ok(Self(Shape::Polygon {
                    vertices: verts,
                    orientation: signed.signum(),
                }))
            }
            _ => Err("unknown geographic geometry".into()),
        }
    }
    pub fn contains(&self, lat: f64, lon: f64) -> bool {
        if !valid(lat, lon) {
            return false;
        }
        let p = vec(lat, lon);
        match &self.0 {
            Shape::Circle(a, b, r) => arc(vec(*a, *b), p) <= r + EPS,
            Shape::Polygon {
                vertices,
                orientation,
            } => {
                let mut winding = 0.;
                for (a, b) in vertices
                    .iter()
                    .copied()
                    .zip(vertices.iter().copied().cycle().skip(1))
                {
                    if on(a, b, p) {
                        return true;
                    }
                    winding += dot(p, cross(a, b)).atan2(dot(a, b) - dot(a, p) * dot(b, p));
                }
                winding * orientation > PI
            }
        }
    }
    pub fn bounds(&self) -> Vec<Bounds> {
        match &self.0 {
            Shape::Circle(lat, lon, r) => {
                let lo = (lat - r.to_degrees() - 1e-7).max(-90.);
                let hi = (lat + r.to_degrees() + 1e-7).min(90.);
                if lo <= -90. || hi >= 90. {
                    return vec![(lo, hi, -180., 180.)];
                }
                let delta = (r.sin() / lat.to_radians().cos())
                    .clamp(-1., 1.)
                    .asin()
                    .to_degrees()
                    + 1e-7;
                if lon - delta < -180. {
                    vec![
                        (lo, hi, lon - delta + 360., 180.),
                        (lo, hi, -180., lon + delta),
                    ]
                } else if lon + delta > 180. {
                    vec![
                        (lo, hi, lon - delta, 180.),
                        (lo, hi, -180., lon + delta - 360.),
                    ]
                } else {
                    vec![(lo, hi, lon - delta, lon + delta)]
                }
            }
            Shape::Polygon { vertices, .. } => {
                let mut lo = 90.0_f64;
                let mut hi = -90.0_f64;
                let north = [0., 0., 1.];
                for (a, b) in vertices
                    .iter()
                    .copied()
                    .zip(vertices.iter().copied().cycle().skip(1))
                {
                    let lat = a[2].clamp(-1., 1.).asin().to_degrees();
                    lo = lo.min(lat);
                    hi = hi.max(lat);
                    let n = unit(cross(a, b));
                    let pole = [-n[2] * n[0], -n[2] * n[1], 1. - n[2] * n[2]];
                    if norm(pole) > EPS {
                        let v = unit(pole);
                        if on(a, b, v) {
                            hi = hi.max(dot(north, v).clamp(-1., 1.).asin().to_degrees());
                        }
                        let s = scale(v, -1.);
                        if on(a, b, s) {
                            lo = lo.min(s[2].clamp(-1., 1.).asin().to_degrees());
                        }
                    }
                }
                if self.contains(90., 0.) {
                    hi = 90.;
                }
                if self.contains(-90., 0.) {
                    lo = -90.;
                }
                vec![((lo - 1e-7).max(-90.), (hi + 1e-7).min(90.), -180., 180.)]
            }
        }
    }
}
