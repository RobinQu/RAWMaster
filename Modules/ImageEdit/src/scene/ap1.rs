//! The first portable scene contract. The 039 document stays authoritative for validation.
//! This component accepts native pixel rectangles. Each supported operator is pointwise.

use super::{parse, Blend, CoverageCombine, Endpoint, Operation, SceneError, Scope};
use crate::Pixel;
use serde::Serialize;
use std::collections::HashMap;

const CURVE_POINTS: usize = 16;
const AP1_Y: [f32; 3] = [0.2722287168, 0.6740817658, 0.0536895174];
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
        let (_, scope) = parse(document)?;
        let lowering = Lowering::new(&scope);
        let endpoint = match root {
            Root::Final => scope.output.clone(),
            Root::Monitor(id) => {
                // The 039 top-level monitor takes this image root. Group paths are outside v1.
                if lowering.operation(id)?.is_coverage() {
                    return Err(SceneError::Unsupported(format!(
                        "coverage node {id} is not previewable"
                    )));
                }
                Endpoint::Node(id.into())
            }
        };
        lowering.finish(&endpoint)
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
}

struct Lowering<'a> {
    nodes: HashMap<&'a str, &'a Operation>,
    images: HashMap<String, Image>,
    coverages: HashMap<String, Coverage>,
    steps: Vec<Step>,
    rows: Vec<[f32; 4]>,
    next_image: usize,
}

impl<'a> Lowering<'a> {
    fn new(scope: &'a Scope) -> Self {
        Self {
            nodes: scope
                .nodes
                .iter()
                .map(|node| (node.id.as_str(), &node.operation))
                .collect(),
            images: HashMap::new(),
            coverages: HashMap::new(),
            steps: Vec::new(),
            rows: Vec::new(),
            next_image: 1,
        }
    }

    fn finish(mut self, endpoint: &Endpoint) -> Result<Prepared, SceneError> {
        let output = self.image(endpoint)?;
        Ok(Prepared {
            plan: Plan {
                steps: self.steps,
                output,
                images: self.next_image,
                coverages: self.coverages.len(),
            },
            parameters: Parameters { rows: self.rows },
        })
    }

    fn operation(&self, id: &str) -> Result<&'a Operation, SceneError> {
        self.nodes
            .get(id)
            .copied()
            .ok_or_else(|| SceneError::Invalid(format!("unknown scene node {id}")))
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

    fn coverage(&mut self, id: &str) -> Result<Coverage, SceneError> {
        if let Some(slot) = self.coverages.get(id) {
            return Ok(*slot);
        }
        let (output, step) = match self.operation(id)? {
            Operation::LinearCoverage { start, end } => {
                let row = self.row([start[0], start[1], end[0], end[1]]);
                let output = Coverage(self.coverages.len());
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
                let output = Coverage(self.coverages.len());
                (output, Step::RadialCoverage { output, row })
            }
            Operation::CombineCoverage {
                base,
                other,
                mode: CoverageCombine::Intersect,
            } => {
                let left = self.coverage(base)?;
                let right = self.coverage(other)?;
                let output = Coverage(self.coverages.len());
                (
                    output,
                    Step::IntersectCoverage {
                        left,
                        right,
                        output,
                    },
                )
            }
            _ => return Err(unsupported(id)),
        };
        self.steps.push(step);
        self.coverages.insert(id.into(), output);
        Ok(output)
    }

    fn image(&mut self, endpoint: &Endpoint) -> Result<Image, SceneError> {
        let Endpoint::Node(id) = endpoint else {
            return Ok(Image(0));
        };
        if let Some(slot) = self.images.get(id) {
            return Ok(*slot);
        }
        let output = match self.operation(id)? {
            Operation::Corrector {
                image,
                mask,
                exposure_ev,
                curve,
                strength,
                enabled,
            } => {
                let input = self.image(image)?;
                let neutral = *exposure_ev == 0.0 && curve.iter().all(|point| point[0] == point[1]);
                if !enabled || *strength == 0.0 || neutral {
                    input
                } else {
                    let coverage = mask
                        .as_deref()
                        .map(|mask| self.coverage(mask))
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
                let mut current = self.image(base)?;
                if *enabled {
                    for layer in layers.iter().filter(|layer| layer.weight > 0.0) {
                        if layer.mode != Blend::Normal {
                            return Err(unsupported(id));
                        }
                        let branch = self.image(&layer.image)?;
                        if branch == current {
                            continue;
                        }
                        if layer.weight == 1.0 {
                            current = branch;
                            continue;
                        }
                        let row = self.row([layer.weight, 0.0, 0.0, 0.0]);
                        let output = self.next_image();
                        self.steps.push(Step::NormalLayer {
                            bottom: current,
                            top: branch,
                            output,
                            row,
                        });
                        current = output;
                    }
                }
                current
            }
            Operation::Parallel {
                base,
                layers,
                enabled,
            } => {
                let base = self.image(base)?;
                let mut current = base;
                if *enabled {
                    for layer in layers.iter().filter(|layer| layer.weight > 0.0) {
                        // 039 validates Parallel's normal mode and skips the original base
                        // before its weight-one replacement. A repeated non-base still adds.
                        let branch = self.image(&layer.image)?;
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
            _ => return Err(unsupported(id)),
        };
        self.images.insert(id.clone(), output);
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
