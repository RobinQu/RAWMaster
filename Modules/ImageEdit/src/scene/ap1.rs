//! The first portable scene contract. The 039 document stays authoritative for validation.
//! This component accepts native pixel rectangles. Each supported operator is pointwise.

use super::{
    monitor_graph, parse, Blend, CoverageCombine, Endpoint, Operation, SceneError, Scope, ViewSpec,
};
use crate::Pixel;
use serde::Serialize;
use std::collections::HashMap;

const CURVE_POINTS: usize = 16;
const AP1_Y: [f32; 3] = [0.2722287168, 0.6740817658, 0.0536895174];
// Powers of two matching the pre-arithmetic bounds in ap1_scene_blend.wgsl.
const MULTIPLY_STRAIGHT_LIMIT: f32 = f32::from_bits((127 + 58) << 23);
const MULTIPLY_ALPHA_MIN: f32 = f32::from_bits((127 - 62) << 23);
const BLEND_STRAIGHT_LIMIT: f32 = f32::from_bits((127 + 120) << 23);
const MIN_MAX_STRAIGHT_LIMIT: f32 = f32::from_bits((127 + 127) << 23);
const MIN_MAX_MIX_LIMIT: f32 = f32::from_bits((127 + 126) << 23);
pub const MAX_PROBE_PIXELS: u64 = 6_000_000;
pub const RGB_SCALED_TOLERANCE: f64 = 2e-5;
pub const AP1_PORT: &str = "acescg-ap1-premul-rgba32f";
pub const COVERAGE_PORT: &str = "coverage-r32f";

#[derive(Serialize)]
pub struct Operator {
    pub id: &'static str,
    pub version: u32,
    pub inputs: &'static [&'static str],
    pub output: &'static str,
    pub roi: &'static str,
    pub precision: &'static str,
}

pub const OPERATORS: &[Operator] = &[
    Operator {
        id: "scene.linear_coverage",
        version: 1,
        inputs: &[],
        output: COVERAGE_PORT,
        roi: "pointwise-full-frame-pixel-center",
        precision: "f32",
    },
    Operator {
        id: "scene.ap1_corrector",
        version: 1,
        inputs: &[AP1_PORT, COVERAGE_PORT],
        output: AP1_PORT,
        roi: "pointwise-optional-coverage-port",
        precision: "f32",
    },
    Operator {
        id: "scene.normal_ordered_layer",
        version: 1,
        inputs: &[AP1_PORT, AP1_PORT],
        output: AP1_PORT,
        roi: "pointwise-ordered-pair",
        precision: "f32",
    },
    Operator {
        id: "scene.radial_coverage",
        version: 1,
        inputs: &[],
        output: COVERAGE_PORT,
        roi: "pointwise-full-frame-pixel-center",
        precision: "f32",
    },
    Operator {
        id: "scene.intersect_coverage",
        version: 1,
        inputs: &[COVERAGE_PORT, COVERAGE_PORT],
        output: COVERAGE_PORT,
        roi: "pointwise",
        precision: "f32",
    },
    Operator {
        id: "scene.normal_ordered_parallel",
        version: 1,
        inputs: &[AP1_PORT, AP1_PORT, AP1_PORT],
        output: AP1_PORT,
        roi: "pointwise-ordered-accumulator-with-original-base",
        precision: "f32",
    },
    Operator {
        id: "scene.layer_blend",
        version: 1,
        inputs: &[AP1_PORT, AP1_PORT],
        output: AP1_PORT,
        roi: "pointwise-ordered-pair",
        precision: "f32",
    },
    Operator {
        id: "scene.add_coverage",
        version: 1,
        inputs: &[COVERAGE_PORT, COVERAGE_PORT],
        output: COVERAGE_PORT,
        roi: "pointwise",
        precision: "f32",
    },
    Operator {
        id: "scene.subtract_coverage",
        version: 1,
        inputs: &[COVERAGE_PORT, COVERAGE_PORT],
        output: COVERAGE_PORT,
        roi: "pointwise",
        precision: "f32",
    },
    Operator {
        id: "scene.adjust_coverage",
        version: 1,
        inputs: &[COVERAGE_PORT],
        output: COVERAGE_PORT,
        roi: "pointwise",
        precision: "f32",
    },
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct Region {
    full: [u32; 2],
    origin: [u32; 2],
    extent: [u32; 2],
}

impl Region {
    pub fn new(full: [u32; 2], origin: [u32; 2], extent: [u32; 2]) -> Result<Self, SceneError> {
        let region = Self::native(full, origin, extent)?;
        if region.pixel_count() as u64 > MAX_PROBE_PIXELS {
            return Err(SceneError::Budget(
                "scene probe exceeds 6,000,000 bound pixels".into(),
            ));
        }
        Ok(region)
    }

    pub(crate) fn native(
        full: [u32; 2],
        origin: [u32; 2],
        extent: [u32; 2],
    ) -> Result<Self, SceneError> {
        for axis in 0..2 {
            if !(1..=16_384).contains(&full[axis])
                || extent[axis] == 0
                || extent[axis] > full[axis]
                || origin[axis] > full[axis] - extent[axis]
            {
                return Err(SceneError::Invalid(
                    "scene ROI is outside its full geometry".into(),
                ));
            }
        }
        Ok(Self {
            full,
            origin,
            extent,
        })
    }

    pub fn extent(self) -> [u32; 2] {
        self.extent
    }

    pub fn origin(self) -> [u32; 2] {
        self.origin
    }

    pub fn pixel_count(self) -> usize {
        (self.extent[0] * self.extent[1]) as usize
    }

    pub fn crop(self, full_pixels: &[Pixel]) -> Result<Vec<Pixel>, SceneError> {
        if full_pixels.len() != (self.full[0] * self.full[1]) as usize {
            return Err(SceneError::Invalid(
                "packed AP1 input does not match full geometry".into(),
            ));
        }
        let mut pixels = Vec::with_capacity(self.pixel_count());
        for y in self.origin[1]..self.origin[1] + self.extent[1] {
            let start = (y * self.full[0] + self.origin[0]) as usize;
            pixels.extend_from_slice(&full_pixels[start..start + self.extent[0] as usize]);
        }
        Ok(pixels)
    }

    pub fn validate_pixels(self, pixels: &[Pixel]) -> Result<(), SceneError> {
        if pixels.len() != self.pixel_count() {
            return Err(SceneError::Invalid(
                "packed AP1 input does not match the ROI extent".into(),
            ));
        }
        if let Some(index) = pixels.iter().position(|pixel| !lawful(*pixel)) {
            return Err(SceneError::Invalid(format!(
                "invalid AP1 input pixel {index}"
            )));
        }
        Ok(())
    }

    #[cfg(feature = "gpu")]
    pub(crate) fn header(self) -> [[u32; 4]; 2] {
        [
            [
                self.extent[0],
                self.extent[1],
                self.origin[0],
                self.origin[1],
            ],
            [self.full[0], self.full[1], 0, 0],
        ]
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Root<'a> {
    Final,
    Monitor(&'a str),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Image(pub(crate) usize);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Coverage(pub(crate) usize);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "operator", rename_all = "camelCase")]
pub(crate) enum Step {
    LinearCoverage {
        output: Coverage,
        row: usize,
    },
    Corrector {
        input: Image,
        coverage: Option<Coverage>,
        output: Image,
        row: usize,
    },
    NormalLayer {
        bottom: Image,
        top: Image,
        output: Image,
        row: usize,
    },
    RadialCoverage {
        output: Coverage,
        row: usize,
    },
    IntersectCoverage {
        left: Coverage,
        right: Coverage,
        output: Coverage,
    },
    NormalParallel {
        current: Image,
        branch: Image,
        base: Image,
        output: Image,
        row: usize,
    },
    LayerBlend {
        current: Image,
        branch: Image,
        output: Image,
        row: usize,
    },
    AddCoverage {
        left: Coverage,
        right: Coverage,
        output: Coverage,
    },
    SubtractCoverage {
        left: Coverage,
        right: Coverage,
        output: Coverage,
    },
    AdjustCoverage {
        input: Coverage,
        output: Coverage,
        row: usize,
    },
}

/// A topology with typed slots and stable parameter positions. Selector IDs and recipe values
/// are not part of the compiled shape. Identity pruning is reflected in the slot topology.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Plan {
    pub(crate) steps: Vec<Step>,
    pub(crate) output: Image,
    images: usize,
    coverages: usize,
}

#[derive(Debug, Serialize)]
pub struct Parameters {
    pub(crate) rows: Vec<[f32; 4]>,
}

pub struct Prepared {
    plan: Plan,
    parameters: Parameters,
}

impl Prepared {
    pub fn from_039(document: &[u8], root: Root<'_>) -> Result<Self, SceneError> {
        let mut view = ViewSpec::default();
        if let Root::Monitor(id) = root {
            view.target = "node".into();
            view.id = Some(id.into());
        }
        Self::from_039_view(document, &view)
    }

    /// Validate the persisted document before selecting a root and lowering the reachable graph.
    pub fn from_039_view(document: &[u8], view: &ViewSpec) -> Result<Self, SceneError> {
        let (_, root) = parse(document)?;
        let (scope, endpoint) = monitor_graph(&root, view)?;
        Lowering::prepare(&scope, &endpoint)
    }

    pub fn parameters(&self) -> &Parameters {
        &self.parameters
    }

    pub fn plan(&self) -> &Plan {
        &self.plan
    }
}

impl Plan {
    pub fn step_count(&self) -> usize {
        self.steps.len()
    }

    pub(crate) fn has_layer_blend(&self) -> bool {
        self.steps
            .iter()
            .any(|step| matches!(step, Step::LayerBlend { .. }))
    }
}

struct ScopeSlots<'a> {
    input: Image,
    nodes: HashMap<&'a str, &'a Operation>,
    images: HashMap<String, Image>,
    coverages: HashMap<String, Coverage>,
}

impl<'a> ScopeSlots<'a> {
    fn new(scope: &'a Scope, input: Image) -> Self {
        Self {
            input,
            nodes: scope
                .nodes
                .iter()
                .map(|node| (node.id.as_str(), &node.operation))
                .collect(),
            images: HashMap::new(),
            coverages: HashMap::new(),
        }
    }

    fn operation(&self, id: &str) -> Result<&'a Operation, SceneError> {
        self.nodes
            .get(id)
            .copied()
            .ok_or_else(|| SceneError::Invalid(format!("unknown scene node {id}")))
    }
}

#[derive(Default)]
struct Lowering {
    steps: Vec<Step>,
    rows: Vec<[f32; 4]>,
    next_image: usize,
    next_coverage: usize,
}

impl Lowering {
    fn prepare(scope: &Scope, endpoint: &Endpoint) -> Result<Prepared, SceneError> {
        let mut lowering = Self::default();
        let input = lowering.next_image();
        let output = lowering.image(&mut ScopeSlots::new(scope, input), endpoint)?;
        Ok(Prepared {
            plan: Plan {
                steps: lowering.steps,
                output,
                images: lowering.next_image,
                coverages: lowering.next_coverage,
            },
            parameters: Parameters {
                rows: lowering.rows,
            },
        })
    }

    fn row(&mut self, value: [f32; 4]) -> usize {
        let row = self.rows.len();
        self.rows.push(value);
        row
    }

    fn next_image(&mut self) -> Image {
        let slot = Image(self.next_image);
        self.next_image += 1;
        slot
    }

    fn next_coverage(&mut self) -> Coverage {
        let slot = Coverage(self.next_coverage);
        self.next_coverage += 1;
        slot
    }

    fn normal_layer(&mut self, bottom: Image, top: Image, weight: f32) -> Image {
        if bottom == top || weight == 1.0 {
            return top;
        }
        let row = self.row([weight, 0.0, 0.0, 0.0]);
        let output = self.next_image();
        self.steps.push(Step::NormalLayer {
            bottom,
            top,
            output,
            row,
        });
        output
    }

    fn coverage(&mut self, scope: &mut ScopeSlots<'_>, id: &str) -> Result<Coverage, SceneError> {
        if let Some(slot) = scope.coverages.get(id) {
            return Ok(*slot);
        }
        let (output, step) = match scope.operation(id)? {
            Operation::LinearCoverage { start, end } => {
                let row = self.row([start[0], start[1], end[0], end[1]]);
                let output = self.next_coverage();
                (output, Step::LinearCoverage { output, row })
            }
            Operation::RadialCoverage {
                center,
                radii,
                feather,
            } => {
                if *feather > 0.0 && 1.0_f32 - *feather == 1.0 {
                    return Err(SceneError::Unsupported(format!(
                        "radial coverage {id} feather has no nonzero F32 interval"
                    )));
                }
                let row = self.row([center[0], center[1], radii[0], radii[1]]);
                self.row([*feather, 0.0, 0.0, 0.0]);
                let output = self.next_coverage();
                (output, Step::RadialCoverage { output, row })
            }
            Operation::CombineCoverage { base, other, mode } => {
                let left = self.coverage(scope, base)?;
                let right = self.coverage(scope, other)?;
                let output = self.next_coverage();
                let step = match mode {
                    CoverageCombine::Add => Step::AddCoverage {
                        left,
                        right,
                        output,
                    },
                    CoverageCombine::Subtract => Step::SubtractCoverage {
                        left,
                        right,
                        output,
                    },
                    CoverageCombine::Intersect => Step::IntersectCoverage {
                        left,
                        right,
                        output,
                    },
                };
                (output, step)
            }
            Operation::AdjustCoverage {
                mask,
                strength,
                inverted,
            } => {
                let input = self.coverage(scope, mask)?;
                let row = self.row([*strength, *inverted as u32 as f32, 0.0, 0.0]);
                let output = self.next_coverage();
                (output, Step::AdjustCoverage { input, output, row })
            }
            _ => return Err(unsupported(id)),
        };
        self.steps.push(step);
        scope.coverages.insert(id.into(), output);
        Ok(output)
    }

    fn image(
        &mut self,
        scope: &mut ScopeSlots<'_>,
        endpoint: &Endpoint,
    ) -> Result<Image, SceneError> {
        let Endpoint::Node(id) = endpoint else {
            return Ok(scope.input);
        };
        if let Some(slot) = scope.images.get(id) {
            return Ok(*slot);
        }
        let output = match scope.operation(id)? {
            Operation::Corrector {
                image,
                mask,
                exposure_ev,
                curve,
                strength,
                enabled,
            } => {
                let input = self.image(scope, image)?;
                let neutral = *exposure_ev == 0.0 && curve.iter().all(|point| point[0] == point[1]);
                if !enabled || *strength == 0.0 || neutral {
                    input
                } else {
                    let coverage = mask
                        .as_deref()
                        .map(|mask| self.coverage(scope, mask))
                        .transpose()?;
                    let row = self.row([
                        libm::exp2f(*exposure_ev),
                        *strength,
                        curve.len() as f32,
                        0.0,
                    ]);
                    self.rows
                        .extend(curve.iter().map(|point| [point[0], point[1], 0.0, 0.0]));
                    self.rows.resize(row + 1 + CURVE_POINTS, [0.0; 4]);
                    let output = self.next_image();
                    self.steps.push(Step::Corrector {
                        input,
                        coverage,
                        output,
                        row,
                    });
                    output
                }
            }
            Operation::Layer {
                base,
                layers,
                enabled,
            } => {
                let mut current = self.image(scope, base)?;
                if *enabled {
                    for layer in layers.iter().filter(|layer| layer.weight > 0.0) {
                        if layer.mode != Blend::Normal && layer.weight.is_subnormal() {
                            return Err(SceneError::Unsupported(format!(
                                "AP1 layer {id} uses a subnormal blend weight"
                            )));
                        }
                        let branch = self.image(scope, &layer.image)?;
                        current = if layer.mode == Blend::Normal {
                            self.normal_layer(current, branch, layer.weight)
                        } else {
                            // Self blends and weight-one blends still change the color.
                            let row = self.row([layer.weight, layer.mode.code() as f32, 0.0, 0.0]);
                            let output = self.next_image();
                            self.steps.push(Step::LayerBlend {
                                current,
                                branch,
                                output,
                                row,
                            });
                            output
                        };
                    }
                }
                current
            }
            Operation::Parallel {
                base,
                layers,
                enabled,
            } => {
                let base = self.image(scope, base)?;
                let mut current = base;
                if *enabled {
                    for layer in layers.iter().filter(|layer| layer.weight > 0.0) {
                        // 039 validates Parallel's normal mode and skips the original base
                        // before its weight-one replacement. A repeated non-base still adds.
                        let branch = self.image(scope, &layer.image)?;
                        if branch == base {
                            continue;
                        }
                        if layer.weight == 1.0 {
                            current = branch;
                            continue;
                        }
                        let row = self.row([layer.weight, 0.0, 0.0, 0.0]);
                        let output = self.next_image();
                        self.steps.push(Step::NormalParallel {
                            current,
                            branch,
                            base,
                            output,
                            row,
                        });
                        current = output;
                    }
                }
                current
            }
            Operation::Group {
                image,
                graph,
                strength,
                enabled,
            } => {
                let base = self.image(scope, image)?;
                if !enabled || *strength == 0.0 {
                    base
                } else {
                    let child = self.image(&mut ScopeSlots::new(graph, base), &graph.output)?;
                    self.normal_layer(base, child, *strength)
                }
            }
            _ => return Err(unsupported(id)),
        };
        scope.images.insert(id.clone(), output);
        Ok(output)
    }
}

fn unsupported(id: &str) -> SceneError {
    SceneError::Unsupported(format!(
        "node {id} uses an operation outside the portable AP1 scene subset"
    ))
}

fn lawful(pixel: Pixel) -> bool {
    pixel.iter().all(|value| value.is_finite()) && (0.0..=1.0).contains(&pixel[3])
}

fn checked_coverage(value: f32, index: usize) -> Result<f32, SceneError> {
    if !value.is_finite() {
        return Err(SceneError::Render(format!(
            "non-finite AP1 coverage at pixel {index}"
        )));
    }
    Ok(value.clamp(0.0, 1.0))
}

fn layer_blend(current: Pixel, branch: Pixel, mode: Blend, weight: f32) -> Option<Pixel> {
    let alpha = current[3];
    if alpha == 0.0 {
        return Some([0.0; 4]);
    }
    let bottom = [current[0], current[1], current[2]];
    let top = [branch[0], branch[1], branch[2]];
    let within = |rgb: [f32; 3], limit| rgb.iter().all(|value| value.abs() <= limit);
    let premultiplied = if matches!(mode, Blend::Lighten | Blend::Darken) {
        let selected = std::array::from_fn(|c| {
            if mode == Blend::Lighten {
                bottom[c].max(top[c])
            } else {
                bottom[c].min(top[c])
            }
        });
        if !within(selected, alpha * MIN_MAX_STRAIGHT_LIMIT)
            || (weight != 1.0
                && (!within(bottom, MIN_MAX_MIX_LIMIT) || !within(selected, MIN_MAX_MIX_LIMIT)))
        {
            return None;
        }
        selected.map(|value| (value / alpha) * alpha)
    } else {
        let limit = if mode == Blend::Multiply {
            if alpha < MULTIPLY_ALPHA_MIN {
                return None;
            }
            MULTIPLY_STRAIGHT_LIMIT
        } else {
            BLEND_STRAIGHT_LIMIT
        };
        if !within(bottom, alpha * limit) || !within(top, alpha * limit) {
            return None;
        }
        blend_rgb(
            bottom.map(|value| value / alpha),
            top.map(|value| value / branch[3]),
            mode,
        )
        .map(|value| value * alpha)
    };
    let [r, g, b] = if weight == 1.0 {
        premultiplied
    } else {
        std::array::from_fn(|c| bottom[c] * (1.0 - weight) + premultiplied[c] * weight)
    };
    Some([r, g, b, alpha])
}

fn unsupported_blend_pixel(index: usize) -> SceneError {
    SceneError::Unsupported(format!("AP1 layer blend numeric domain at pixel {index}"))
}

fn blend_rgb(bottom: [f32; 3], top: [f32; 3], mode: Blend) -> [f32; 3] {
    let luma = |rgb: [f32; 3]| rgb[0] * AP1_Y[0] + rgb[1] * AP1_Y[1] + rgb[2] * AP1_Y[2];
    match mode {
        Blend::Color => {
            let delta = luma(bottom) - luma(top);
            top.map(|s| s + delta)
        }
        Blend::Luminosity => {
            let delta = luma(top) - luma(bottom);
            bottom.map(|b| b + delta)
        }
        _ => std::array::from_fn(|c| {
            let b = bottom[c];
            let s = top[c];
            match mode {
                Blend::Normal => s,
                Blend::Add => b + s,
                Blend::Subtract => b - s,
                Blend::Multiply => b * s,
                Blend::Difference => (b - s).abs(),
                Blend::Screen | Blend::Overlay | Blend::HardLight | Blend::SoftLight => {
                    bounded_blend(b, s, mode)
                }
                Blend::Color | Blend::Luminosity | Blend::Lighten | Blend::Darken => unreachable!(),
            }
        }),
    }
}

fn bounded_blend(bottom: f32, top: f32, mode: Blend) -> f32 {
    let x = bottom.clamp(0.0, 1.0);
    let y = top.clamp(0.0, 1.0);
    let core = match mode {
        Blend::Screen => x + y - x * y,
        Blend::Overlay | Blend::HardLight => {
            let pivot = if mode == Blend::Overlay { x } else { y };
            if pivot <= 0.5 {
                2.0 * x * y
            } else {
                1.0 - 2.0 * (1.0 - x) * (1.0 - y)
            }
        }
        Blend::SoftLight if y <= 0.5 => x - (1.0 - 2.0 * y) * x * (1.0 - x),
        Blend::SoftLight => {
            let d = if x <= 0.25 {
                ((16.0 * x - 12.0) * x + 4.0) * x
            } else {
                libm::sqrtf(x)
            };
            x + (2.0 * y - 1.0) * (d - x)
        }
        _ => unreachable!(),
    };
    core + (bottom - x) + (top - y)
}

fn correct(pixel: Pixel, coverage: f32, rows: &[[f32; 4]]) -> Pixel {
    if pixel[3] == 0.0 {
        return [0.0; 4];
    }
    let weight = rows[0][1] * coverage;
    if weight == 0.0 {
        return pixel;
    }
    let mut gain = rows[0][0];
    let luma = pixel[0] * AP1_Y[0] + pixel[1] * AP1_Y[1] + pixel[2] * AP1_Y[2];
    let count = rows[0][2] as usize;
    if count > 0 && luma > 0.0 {
        let exposed_ev = libm::log2f(luma) - libm::log2f(pixel[3]) + libm::log2f(gain);
        let points = &rows[1..=count];
        let delta = if exposed_ev <= points[0][0] {
            points[0][1] - points[0][0]
        } else if let Some(pair) = points.windows(2).find(|pair| exposed_ev <= pair[1][0]) {
            let [a, b] = [pair[0], pair[1]];
            let first = a[1] - a[0];
            let last = b[1] - b[0];
            first + (last - first) * ((exposed_ev - a[0]) / (b[0] - a[0]))
        } else {
            let last = points[count - 1];
            last[1] - last[0]
        };
        gain *= libm::exp2f(delta);
    }
    let gain = 1.0 + (gain - 1.0) * weight;
    [pixel[0] * gain, pixel[1] * gain, pixel[2] * gain, pixel[3]]
}

fn radial(pixel_center: [f32; 2], facts: [f32; 4], feather: f32) -> f32 {
    let x = (pixel_center[0] - facts[0]) / facts[2];
    let y = (pixel_center[1] - facts[1]) / facts[3];
    let radius = libm::sqrtf(x * x + y * y);
    if feather == 0.0 {
        return if radius <= 1.0 { 1.0 } else { 0.0 };
    }
    let inner = 1.0 - feather;
    let t = ((radius - inner) / (1.0 - inner)).clamp(0.0, 1.0);
    (1.0 - t * t * (3.0 - 2.0 * t)).clamp(0.0, 1.0)
}

/// Independent scalar evaluation of the supported AP1 operators. A checked scalar step cannot
/// hide an invalid value behind a later shader identity or blend.
pub fn render_cpu(
    prepared: &Prepared,
    region: Region,
    input: &[Pixel],
) -> Result<Vec<Pixel>, SceneError> {
    region.validate_pixels(input)?;
    if prepared.plan.has_layer_blend() {
        if let Some(index) = input.iter().position(|pixel| pixel[3].is_subnormal()) {
            return Err(unsupported_blend_pixel(index));
        }
    }
    let mut images = vec![[0.0; 4]; prepared.plan.images];
    let mut coverage = vec![0.0; prepared.plan.coverages];
    let mut result = Vec::with_capacity(input.len());
    for (index, pixel) in input.iter().copied().enumerate() {
        let x = index as u32 % region.extent[0];
        let y = index as u32 / region.extent[0];
        let px = ((region.origin[0] + x) as f32 + 0.5) / region.full[0] as f32;
        let py = ((region.origin[1] + y) as f32 + 0.5) / region.full[1] as f32;
        images[0] = pixel;
        for step in &prepared.plan.steps {
            let image_output = match *step {
                Step::LinearCoverage { output, row } => {
                    let [x0, y0, x1, y1] = prepared.parameters.rows[row];
                    let dx = x1 - x0;
                    let dy = y1 - y0;
                    coverage[output.0] =
                        (((px - x0) * dx + (py - y0) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
                    if !coverage[output.0].is_finite() {
                        return Err(SceneError::Render(format!(
                            "non-finite AP1 coverage at pixel {index}"
                        )));
                    }
                    None
                }
                Step::Corrector {
                    input,
                    coverage: mask,
                    output,
                    row,
                } => {
                    images[output.0] = correct(
                        images[input.0],
                        mask.map_or(1.0, |slot| coverage[slot.0]),
                        &prepared.parameters.rows[row..],
                    );
                    Some(output)
                }
                Step::NormalLayer {
                    bottom,
                    top,
                    output,
                    row,
                } => {
                    let a = images[bottom.0];
                    let b = images[top.0];
                    let weight = prepared.parameters.rows[row][0];
                    images[output.0] = if a[3] == 0.0 {
                        [0.0; 4]
                    } else {
                        [
                            a[0] + (b[0] - a[0]) * weight,
                            a[1] + (b[1] - a[1]) * weight,
                            a[2] + (b[2] - a[2]) * weight,
                            a[3],
                        ]
                    };
                    Some(output)
                }
                Step::RadialCoverage { output, row } => {
                    let rows = &prepared.parameters.rows;
                    let value = radial([px, py], rows[row], rows[row + 1][0]);
                    if !value.is_finite() {
                        return Err(SceneError::Render(format!(
                            "non-finite AP1 radial coverage at pixel {index}"
                        )));
                    }
                    coverage[output.0] = value;
                    None
                }
                Step::IntersectCoverage {
                    left,
                    right,
                    output,
                } => {
                    // Both coverage operands have already passed the finite [0, 1] boundary.
                    coverage[output.0] = coverage[left.0] * coverage[right.0];
                    None
                }
                Step::NormalParallel {
                    current,
                    branch,
                    base,
                    output,
                    row,
                } => {
                    let a = images[current.0];
                    let b = images[branch.0];
                    let original = images[base.0];
                    let weight = prepared.parameters.rows[row][0];
                    images[output.0] = if a[3] == 0.0 {
                        [0.0; 4]
                    } else {
                        [
                            a[0] + weight * (b[0] - original[0]),
                            a[1] + weight * (b[1] - original[1]),
                            a[2] + weight * (b[2] - original[2]),
                            a[3],
                        ]
                    };
                    Some(output)
                }
                Step::LayerBlend {
                    current,
                    branch,
                    output,
                    row,
                } => {
                    let [weight, mode, ..] = prepared.parameters.rows[row];
                    images[output.0] = layer_blend(
                        images[current.0],
                        images[branch.0],
                        Blend::from_code(mode as u32),
                        weight,
                    )
                    .ok_or_else(|| unsupported_blend_pixel(index))?;
                    Some(output)
                }
                Step::AddCoverage {
                    left,
                    right,
                    output,
                } => {
                    let a = coverage[left.0];
                    let b = coverage[right.0];
                    coverage[output.0] = checked_coverage(a + b * (1.0 - a), index)?;
                    None
                }
                Step::SubtractCoverage {
                    left,
                    right,
                    output,
                } => {
                    coverage[output.0] =
                        checked_coverage(coverage[left.0] * (1.0 - coverage[right.0]), index)?;
                    None
                }
                Step::AdjustCoverage { input, output, row } => {
                    let [strength, inverted, ..] = prepared.parameters.rows[row];
                    let mut value = coverage[input.0];
                    if inverted != 0.0 {
                        value = 1.0 - value;
                    }
                    coverage[output.0] = checked_coverage(value * strength, index)?;
                    None
                }
            };
            if image_output.is_some_and(|slot| !lawful(images[slot.0])) {
                return Err(SceneError::Render(format!(
                    "non-finite AP1 result at pixel {index}"
                )));
            }
        }
        result.push(images[prepared.plan.output.0]);
    }
    Ok(result)
}
