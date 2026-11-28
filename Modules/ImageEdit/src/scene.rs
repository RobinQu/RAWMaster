//! Scene-linear AP1 graph execution for the 037/038 HDR path.
//!
//! This module deliberately does not reuse the portable point-recipe graph: the scene graph has
//! image/coverage ports, groups, and ordered mixers. The public entry points are in `scene_ffi.rs`.

use serde::Deserialize;
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};

pub mod ap1;

pub const MAX_NODES: usize = 96;
pub const MAX_DEPTH: usize = 5;
pub const MAX_LAYERS: usize = 8;

#[derive(Debug, Clone)]
pub enum SceneError {
    Invalid(String),
    Backend(String),
    Render(String),
    Budget(String),
    Unsupported(String),
}

impl std::fmt::Display for SceneError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invalid(s)
            | Self::Backend(s)
            | Self::Render(s)
            | Self::Budget(s)
            | Self::Unsupported(s) => f.write_str(s),
        }
    }
}
impl std::error::Error for SceneError {}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Endpoint {
    Input,
    Node(String),
}
impl<'de> Deserialize<'de> for Endpoint {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        if value == "$input" {
            Ok(Self::Input)
        } else if value.is_empty() {
            Err(serde::de::Error::custom("empty scene endpoint"))
        } else {
            Ok(Self::Node(value))
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub enum Blend {
    #[serde(rename = "normal")]
    Normal,
    #[serde(rename = "add")]
    Add,
    #[serde(rename = "subtract")]
    Subtract,
    #[serde(rename = "multiply")]
    Multiply,
    #[serde(rename = "screen")]
    Screen,
    #[serde(rename = "overlay")]
    Overlay,
    #[serde(rename = "soft-light")]
    SoftLight,
    #[serde(rename = "hard-light")]
    HardLight,
    #[serde(rename = "lighten")]
    Lighten,
    #[serde(rename = "darken")]
    Darken,
    #[serde(rename = "difference")]
    Difference,
    #[serde(rename = "color")]
    Color,
    #[serde(rename = "luminosity")]
    Luminosity,
}
impl Blend {
    #[cfg(all(target_os = "macos", feature = "metal-surface"))]
    fn code(self) -> u32 {
        match self {
            Self::Normal => 0,
            Self::Add => 1,
            Self::Subtract => 2,
            Self::Multiply => 3,
            Self::Screen => 4,
            Self::Overlay => 5,
            Self::SoftLight => 6,
            Self::HardLight => 7,
            Self::Lighten => 8,
            Self::Darken => 9,
            Self::Difference => 10,
            Self::Color => 11,
            Self::Luminosity => 12,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub enum CoverageCombine {
    #[serde(rename = "add")]
    Add,
    #[serde(rename = "subtract")]
    Subtract,
    #[serde(rename = "intersect")]
    Intersect,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Layer {
    pub image: Endpoint,
    pub weight: f32,
    pub mode: Blend,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Operation {
    Corrector {
        image: Endpoint,
        mask: Option<String>,
        #[serde(rename = "exposureEV")]
        exposure_ev: f32,
        curve: Vec<[f32; 2]>,
        strength: f32,
        enabled: bool,
    },
    Parallel {
        base: Endpoint,
        layers: Vec<Layer>,
        enabled: bool,
    },
    Layer {
        base: Endpoint,
        layers: Vec<Layer>,
        enabled: bool,
    },
    Group {
        image: Endpoint,
        graph: Scope,
        strength: f32,
        enabled: bool,
    },
    LinearCoverage {
        start: [f32; 2],
        end: [f32; 2],
    },
    RadialCoverage {
        center: [f32; 2],
        radii: [f32; 2],
        feather: f32,
    },
    CombineCoverage {
        base: String,
        other: String,
        mode: CoverageCombine,
    },
    AdjustCoverage {
        mask: String,
        strength: f32,
        inverted: bool,
    },
    ExternalCoverage {
        id: String,
    },
}

#[derive(Debug, Clone, Deserialize)]
pub struct Node {
    pub id: String,
    pub name: String,
    pub operation: Operation,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Scope {
    pub nodes: Vec<Node>,
    pub output: Endpoint,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Document {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    pub graph: Scope,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ViewSpec {
    #[serde(default = "default_target")]
    pub target: String,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default, rename = "groupPath")]
    pub group_path: Vec<String>,
    /// Source-edge origin of the rendered surface inside the full frame.
    #[serde(default)]
    pub origin: Option<[i64; 2]>,
    /// Full-frame geometry used by coverage coordinates.
    #[serde(default)]
    pub geometry: Option<[u32; 2]>,
    /// Upper bound for input, intermediates, pool and source-independent coverage cache.
    #[serde(default, rename = "surfaceBudget")]
    pub surface_budget: Option<u64>,
    /// Optional square-ish execution tile. Zero or absent renders the surface in one pass.
    #[serde(default, rename = "tileEdge")]
    pub tile_edge: Option<u32>,
    /// Caller-owned source generation. Non-zero enables the general intermediate cache; the
    /// caller must change it whenever the input pixels or bound model masks change.
    #[serde(default, rename = "sourceRevision")]
    pub source_revision: Option<u64>,
}
fn default_target() -> String {
    "final".into()
}
impl Default for ViewSpec {
    fn default() -> Self {
        Self {
            target: default_target(),
            id: None,
            group_path: vec![],
            origin: None,
            geometry: None,
            surface_budget: None,
            tile_edge: None,
            source_revision: None,
        }
    }
}

/// Select a root from a previously validated persisted graph. For a group monitor,
/// each ancestor supplies its own input and forwards its selected child at full strength.
/// The projected scope may leave nodes unreachable and is used only for execution.
fn monitor_graph<'a>(
    root: &'a Scope,
    view: &ViewSpec,
) -> Result<(Cow<'a, Scope>, Endpoint), SceneError> {
    fn endpoint(scope: &Scope, view: &ViewSpec) -> Result<Endpoint, SceneError> {
        match view.target.as_str() {
            "final" | "" => Ok(scope.output.clone()),
            "bypass" => Ok(Endpoint::Input),
            "node" => {
                let id = view
                    .id
                    .as_ref()
                    .ok_or_else(|| SceneError::Invalid("node view has no id".into()))?;
                let node = scope
                    .nodes
                    .iter()
                    .find(|n| &n.id == id)
                    .ok_or_else(|| SceneError::Invalid(format!("unknown scene node {id}")))?;
                if node.operation.is_coverage() {
                    return Err(SceneError::Unsupported(format!(
                        "coverage node {id} is not previewable"
                    )));
                }
                Ok(Endpoint::Node(id.clone()))
            }
            other => Err(SceneError::Invalid(format!(
                "unknown scene view target {other}"
            ))),
        }
    }
    if view.group_path.is_empty() {
        return Ok((Cow::Borrowed(root), endpoint(root, view)?));
    }
    let mut projected = root.clone();
    let mut scope = &mut projected;
    for id in &view.group_path {
        let node = scope.nodes.iter_mut().find(|n| &n.id == id);
        let Some(Operation::Group {
            graph,
            enabled,
            strength,
            ..
        }) = node.map(|n| &mut n.operation)
        else {
            return Err(SceneError::Invalid(format!("unknown scene group {id}")));
        };
        scope.output = Endpoint::Node(id.clone());
        *enabled = true;
        *strength = 1.0;
        scope = graph;
    }
    scope.output = endpoint(scope, view)?;
    let output = projected.output.clone();
    Ok((Cow::Owned(projected), output))
}

impl Operation {
    fn is_coverage(&self) -> bool {
        matches!(
            self,
            Self::LinearCoverage { .. }
                | Self::RadialCoverage { .. }
                | Self::CombineCoverage { .. }
                | Self::AdjustCoverage { .. }
                | Self::ExternalCoverage { .. }
        )
    }
    fn images(&self) -> Vec<&Endpoint> {
        match self {
            Self::Corrector { image, .. } | Self::Group { image, .. } => vec![image],
            Self::Parallel { base, layers, .. } | Self::Layer { base, layers, .. } => {
                let mut result = vec![base];
                result.extend(layers.iter().map(|layer| &layer.image));
                result
            }
            _ => vec![],
        }
    }
    fn coverages(&self) -> Vec<&str> {
        match self {
            Self::Corrector { mask, .. } => mask.iter().map(String::as_str).collect(),
            Self::CombineCoverage { base, other, .. } => vec![base.as_str(), other.as_str()],
            Self::AdjustCoverage { mask, .. } => vec![mask.as_str()],
            _ => vec![],
        }
    }
    /// Endpoints that must be evaluated before this operation. Coverage dependencies use the
    /// same node endpoint type; the executor checks the destination texture format.
    #[cfg(all(target_os = "macos", feature = "metal-surface"))]
    fn active_inputs(&self) -> Vec<Endpoint> {
        let mut result: Vec<Endpoint> = match self {
            Self::Corrector {
                image,
                exposure_ev,
                curve,
                strength,
                enabled,
                mask,
            } => {
                let neutral = *exposure_ev == 0.0 && curve.iter().all(|point| point[0] == point[1]);
                let mut result = vec![image.clone()];
                if *enabled && *strength > 0.0 && !neutral {
                    result.extend(mask.iter().map(|id| Endpoint::Node(id.clone())));
                }
                result
            }
            Self::Parallel {
                base,
                layers,
                enabled,
            }
            | Self::Layer {
                base,
                layers,
                enabled,
            } => {
                let mut result = vec![base.clone()];
                if *enabled {
                    result.extend(
                        layers
                            .iter()
                            .filter(|layer| layer.weight > 0.0)
                            .map(|layer| layer.image.clone()),
                    );
                }
                result
            }
            Self::Group { image, .. } => vec![image.clone()],
            Self::CombineCoverage { base, other, .. } => {
                vec![Endpoint::Node(base.clone()), Endpoint::Node(other.clone())]
            }
            Self::AdjustCoverage { mask, .. } => vec![Endpoint::Node(mask.clone())],
            Self::LinearCoverage { .. }
            | Self::RadialCoverage { .. }
            | Self::ExternalCoverage { .. } => vec![],
        };
        result.dedup();
        result
    }
}

impl Scope {
    pub fn validate(&self) -> Result<(), SceneError> {
        let mut all = HashSet::new();
        self.validate_inner(1, &mut all)
    }

    fn validate_inner(&self, depth: usize, all: &mut HashSet<String>) -> Result<(), SceneError> {
        if depth > MAX_DEPTH || self.nodes.len() > MAX_NODES.saturating_sub(all.len()) {
            return Err(SceneError::Invalid("scene graph budget exceeded".into()));
        }
        let mut by_id = HashMap::new();
        for node in &self.nodes {
            if !all.insert(node.id.clone()) {
                return Err(SceneError::Invalid(format!("duplicate node {}", node.id)));
            }
            if node.name.trim().is_empty() || node.name.len() > 256 {
                return Err(SceneError::Invalid(format!(
                    "invalid node name {}",
                    node.id
                )));
            }
            validate_operation(&node.operation)?;
            by_id.insert(node.id.as_str(), &node.operation);
        }
        // Charge all siblings before entering any child scope, as Swift does.
        for node in &self.nodes {
            if let Operation::Group { graph, .. } = &node.operation {
                graph.validate_inner(depth + 1, all)?;
            }
        }
        let mut active: HashSet<String> = HashSet::new();
        let mut resolved: HashSet<String> = HashSet::new();
        fn visit(
            endpoint: &Endpoint,
            coverage: bool,
            by_id: &HashMap<&str, &Operation>,
            active: &mut HashSet<String>,
            resolved: &mut HashSet<String>,
        ) -> Result<(), SceneError> {
            let Endpoint::Node(id) = endpoint else {
                return Ok(());
            };
            let operation = by_id
                .get(id.as_str())
                .copied()
                .ok_or_else(|| SceneError::Invalid(format!("missing node {id}")))?;
            if operation.is_coverage() != coverage {
                return Err(SceneError::Invalid(format!("incompatible port {id}")));
            }
            if resolved.contains(id.as_str()) {
                return Ok(());
            }
            if !active.insert(id.to_string()) {
                return Err(SceneError::Invalid(format!("scene graph cycle at {id}")));
            }
            for image in operation.images() {
                visit(image, false, by_id, active, resolved)?;
            }
            for mask in operation.coverages() {
                visit(
                    &Endpoint::Node(mask.to_string()),
                    true,
                    by_id,
                    active,
                    resolved,
                )?;
            }
            active.remove(id);
            resolved.insert(id.to_string());
            Ok(())
        }
        visit(&self.output, false, &by_id, &mut active, &mut resolved)?;
        if resolved.len() != self.nodes.len() {
            return Err(SceneError::Invalid("disconnected scene nodes".into()));
        }
        Ok(())
    }
}

fn validate_operation(operation: &Operation) -> Result<(), SceneError> {
    let unit = |value: f32| (0.0..=1.0).contains(&value);
    match operation {
        Operation::Corrector {
            exposure_ev,
            curve,
            strength,
            ..
        } => {
            if !(-12.0..=12.0).contains(exposure_ev) || !unit(*strength) {
                return Err(SceneError::Invalid(
                    "corrector parameter outside range".into(),
                ));
            }
            if !curve.is_empty() && !(2..=16).contains(&curve.len()) {
                return Err(SceneError::Invalid(
                    "corrector curve count outside range".into(),
                ));
            }
            for point in curve {
                if !(-24.0..=24.0).contains(&point[0])
                    || !(-24.0..=24.0).contains(&point[1])
                    || !point[0].is_finite()
                    || !point[1].is_finite()
                {
                    return Err(SceneError::Invalid(
                        "corrector curve point outside range".into(),
                    ));
                }
            }
            for pair in curve.windows(2) {
                if pair[1][0] - pair[0][0] < 0.001 || pair[1][1] < pair[0][1] {
                    return Err(SceneError::Invalid(
                        "corrector curve is not monotone".into(),
                    ));
                }
            }
        }
        Operation::Parallel { layers, .. } => {
            if !(1..=MAX_LAYERS).contains(&layers.len())
                || layers
                    .iter()
                    .any(|layer| !unit(layer.weight) || layer.mode != Blend::Normal)
            {
                return Err(SceneError::Invalid("invalid parallel mixer".into()));
            }
        }
        Operation::Layer { layers, .. } => {
            if !(1..=MAX_LAYERS).contains(&layers.len())
                || layers.iter().any(|layer| !unit(layer.weight))
            {
                return Err(SceneError::Invalid("invalid layer mixer".into()));
            }
        }
        Operation::Group { strength, .. } | Operation::AdjustCoverage { strength, .. } => {
            if !unit(*strength) {
                return Err(SceneError::Invalid("strength outside [0,1]".into()));
            }
        }
        Operation::LinearCoverage { start, end } => {
            for point in [start, end] {
                if !unit(point[0])
                    || !unit(point[1])
                    || !point[0].is_finite()
                    || !point[1].is_finite()
                {
                    return Err(SceneError::Invalid("coverage point outside [0,1]".into()));
                }
            }
            if (end[0] - start[0]).abs().max((end[1] - start[1]).abs()) < 0.0001 {
                return Err(SceneError::Invalid("linear coverage has no extent".into()));
            }
        }
        Operation::RadialCoverage {
            center,
            radii,
            feather,
        } => {
            if !unit(center[0])
                || !unit(center[1])
                || !(0.0001..=2.0).contains(&radii[0])
                || !(0.0001..=2.0).contains(&radii[1])
                || !unit(*feather)
            {
                return Err(SceneError::Invalid("radial coverage outside range".into()));
            }
        }
        Operation::CombineCoverage { .. } => {}
        Operation::ExternalCoverage { id } => {
            if id.is_empty() || id.len() > 128 {
                return Err(SceneError::Invalid("invalid external coverage id".into()));
            }
        }
    }
    Ok(())
}

/// Parsed, validated scene program. Metal resources are opened lazily by `SceneProgram::open`.
pub fn parse(document: &[u8]) -> Result<(Document, Scope), SceneError> {
    let document: Document = serde_json::from_slice(document)
        .map_err(|error| SceneError::Invalid(format!("scene graph JSON: {error}")))?;
    if document.schema_version != 1 {
        return Err(SceneError::Invalid("unsupported scene graph schema".into()));
    }
    document.graph.validate()?;
    Ok((document.clone(), document.graph))
}

#[cfg(all(target_os = "macos", feature = "metal-surface"))]
pub mod metal_exec;

#[cfg(all(target_os = "macos", feature = "metal-surface"))]
pub use metal_exec::SceneProgram;

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_str(document: &str) -> Result<(), SceneError> {
        parse(document.as_bytes()).map(|_| ())
    }

    const VALID: &str = r#"{
      "schemaVersion": 1,
      "graph": {
        "nodes": [
          {"id": "g", "name": "Ramp", "operation": {"kind": "linearCoverage", "start": [0, 0], "end": [1, 0]}},
          {"id": "c", "name": "Grade", "operation": {"kind": "corrector", "image": "$input", "mask": "g",
            "exposureEV": 1.0, "curve": [], "strength": 1.0, "enabled": true}}
        ],
        "output": "c"
      }
    }"#;

    #[test]
    fn accepts_a_bounded_image_and_coverage_graph() {
        parse_str(VALID).unwrap();
    }

    #[test]
    fn counts_all_group_and_sibling_nodes_independent_of_order() {
        fn corrector(id: String, image: Endpoint) -> Node {
            Node {
                name: id.clone(),
                id,
                operation: Operation::Corrector {
                    image,
                    mask: None,
                    exposure_ev: 0.5,
                    curve: vec![],
                    strength: 1.0,
                    enabled: true,
                },
            }
        }

        for children_first in [true, false] {
            for count in [MAX_NODES, MAX_NODES + 1] {
                let group = Node {
                    id: "group".into(),
                    name: "Group".into(),
                    operation: Operation::Group {
                        image: Endpoint::Input,
                        graph: Scope {
                            nodes: vec![
                                corrector("inner-a".into(), Endpoint::Input),
                                corrector("inner-b".into(), Endpoint::Node("inner-a".into())),
                            ],
                            output: Endpoint::Node("inner-b".into()),
                        },
                        strength: 1.0,
                        enabled: true,
                    },
                };
                let mut output = Endpoint::Node(group.id.clone());
                let mut nodes = Vec::new();
                for index in 0..count - 3 {
                    let id = format!("outer-{index}");
                    nodes.push(corrector(id.clone(), output));
                    output = Endpoint::Node(id);
                }
                if children_first {
                    nodes.insert(0, group);
                } else {
                    nodes.push(group);
                }
                assert_eq!(
                    Scope { nodes, output }.validate().is_ok(),
                    count == MAX_NODES
                );
            }
        }
    }

    #[test]
    fn rejects_cycles_and_incompatible_ports() {
        let cycle = r#"{"schemaVersion":1,"graph":{"nodes":[
          {"id":"a","name":"A","operation":{"kind":"corrector","image":"b","mask":null,"exposureEV":1,"curve":[],"strength":1,"enabled":true}},
          {"id":"b","name":"B","operation":{"kind":"corrector","image":"a","mask":null,"exposureEV":1,"curve":[],"strength":1,"enabled":true}}
        ],"output":"a"}}"#;
        assert!(parse_str(cycle).is_err());
        let port = r#"{"schemaVersion":1,"graph":{"nodes":[
          {"id":"a","name":"A","operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":1,"curve":[],"strength":1,"enabled":true}},
          {"id":"c","name":"C","operation":{"kind":"corrector","image":"$input","mask":"a","exposureEV":1,"curve":[],"strength":1,"enabled":true}}
        ],"output":"c"}}"#;
        assert!(parse_str(port).is_err());
    }

    #[test]
    fn rejects_duplicate_ids_disconnected_nodes_and_unknown_fields() {
        let duplicate = r#"{"schemaVersion":1,"graph":{"nodes":[
          {"id":"a","name":"A","operation":{"kind":"linearCoverage","start":[0,0],"end":[1,0]}},
          {"id":"a","name":"B","operation":{"kind":"linearCoverage","start":[0,1],"end":[1,1]}}
        ],"output":"a"}}"#;
        assert!(parse_str(duplicate).is_err());
        let disconnected = r#"{"schemaVersion":1,"graph":{"nodes":[
          {"id":"a","name":"A","operation":{"kind":"linearCoverage","start":[0,0],"end":[1,0]}},
          {"id":"b","name":"B","operation":{"kind":"linearCoverage","start":[0,1],"end":[1,1]}}
        ],"output":"a"}}"#;
        assert!(parse_str(disconnected).is_err());
        let unknown = r#"{"schemaVersion":1,"graph":{"nodes":[
          {"id":"a","name":"A","operation":{"kind":"grade","exposureEV":1}}
        ],"output":"a"}}"#;
        assert!(parse_str(unknown).is_err());
        assert!(
            parse_str(r#"{"schemaVersion":2,"graph":{"nodes":[],"output":"$input"}}"#).is_err()
        );
    }

    #[test]
    fn rejects_out_of_range_parameters_before_compilation() {
        let exposure = r#"{"schemaVersion":1,"graph":{"nodes":[
          {"id":"a","name":"A","operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":13,"curve":[],"strength":1,"enabled":true}}
        ],"output":"a"}}"#;
        assert!(parse_str(exposure).is_err());
        let blend = r#"{"schemaVersion":1,"graph":{"nodes":[
          {"id":"l","name":"L","operation":{"kind":"correctors","image":"$input","mask":null,"exposureEV":1,"curve":[],"strength":1,"enabled":true}}
        ],"output":"l"}}"#;
        assert!(parse_str(blend).is_err());
    }
}
