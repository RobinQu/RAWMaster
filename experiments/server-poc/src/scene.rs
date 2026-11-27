//! 038 scene-graph contract and validator for the 040/041 backbone PoC.
//!
//! This deliberately mirrors `DevelopmentSceneGraphV1`'s JSON shape. It does not
//! execute pixels; the first PoC validates that a headless host can freeze, parse,
//! budget and receipt the same bounded graph before we port the Vulkan executor.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

pub const MAX_NODES: usize = 96;
pub const MAX_DEPTH: usize = 5;
pub const MAX_LAYERS: usize = 8;

#[derive(Debug, Clone, Eq, PartialEq, Hash, Deserialize, Serialize)]
#[serde(transparent)]
pub struct Endpoint(pub String);

impl Endpoint {
    pub fn input() -> Self {
        Self("$input".into())
    }
    pub fn node(id: impl Into<String>) -> Self {
        Self(id.into())
    }
    pub fn node_id(&self) -> Option<&str> {
        (self.0 != "$input").then_some(self.0.as_str())
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Blend {
    Normal,
    Add,
    Subtract,
    Multiply,
    Screen,
    Overlay,
    #[serde(rename = "soft-light")]
    SoftLight,
    #[serde(rename = "hard-light")]
    HardLight,
    Lighten,
    Darken,
    Difference,
    Color,
    Luminosity,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CoverageCombine {
    Add,
    Subtract,
    Intersect,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Layer {
    pub image: Endpoint,
    pub weight: f32,
    pub mode: Blend,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
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

impl Operation {
    pub fn is_coverage(&self) -> bool {
        matches!(
            self,
            Self::LinearCoverage { .. }
                | Self::RadialCoverage { .. }
                | Self::CombineCoverage { .. }
                | Self::AdjustCoverage { .. }
                | Self::ExternalCoverage { .. }
        )
    }

    pub fn images(&self) -> Vec<&Endpoint> {
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

    pub fn coverages(&self) -> Vec<&str> {
        match self {
            Self::Corrector { mask, .. } => mask.iter().map(String::as_str).collect(),
            Self::CombineCoverage { base, other, .. } => vec![base.as_str(), other.as_str()],
            Self::AdjustCoverage { mask, .. } => vec![mask.as_str()],
            _ => vec![],
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Node {
    pub id: String,
    pub name: String,
    pub operation: Operation,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Scope {
    pub nodes: Vec<Node>,
    pub output: Endpoint,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Document {
    pub schema_version: u32,
    pub graph: Scope,
    /// 038 delivery state is carried by the Swift document but is not needed to execute pixels.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneReceipt {
    pub backend: &'static str,
    pub tiles: u32,
    pub nodes: u32,
    pub dispatches: u32,
    pub coverage_nodes: u32,
    pub peak_bytes: u64,
    pub budget_bytes: u64,
    pub cpu_ms: f64,
}

pub fn parse(bytes: &[u8]) -> Result<(Document, SceneReceipt), String> {
    let started = std::time::Instant::now();
    let document: Document =
        serde_json::from_slice(bytes).map_err(|error| format!("scene graph JSON: {error}"))?;
    if document.schema_version != 1 {
        return Err(format!(
            "unsupported scene graph schema {}",
            document.schema_version
        ));
    }
    document.graph.validate()?;
    let nodes = count_nodes(&document.graph);
    let coverage = count_coverage(&document.graph);
    Ok((
        document,
        SceneReceipt {
            backend: "cpu-contract-poc",
            tiles: 1,
            nodes,
            dispatches: nodes,
            coverage_nodes: coverage,
            peak_bytes: 0,
            budget_bytes: 0,
            cpu_ms: started.elapsed().as_secs_f64() * 1000.0,
        },
    ))
}

fn count_nodes(scope: &Scope) -> u32 {
    scope
        .nodes
        .iter()
        .map(|node| {
            1 + match &node.operation {
                Operation::Group { graph, .. } => count_nodes(graph),
                _ => 0,
            }
        })
        .sum()
}

fn count_coverage(scope: &Scope) -> u32 {
    scope
        .nodes
        .iter()
        .map(|node| {
            u32::from(node.operation.is_coverage())
                + match &node.operation {
                    Operation::Group { graph, .. } => count_coverage(graph),
                    _ => 0,
                }
        })
        .sum()
}

impl Scope {
    pub fn validate(&self) -> Result<(), String> {
        let mut all = HashSet::new();
        self.validate_inner(1, &mut all)
    }

    fn validate_inner(&self, depth: usize, all: &mut HashSet<String>) -> Result<(), String> {
        if depth > MAX_DEPTH || self.nodes.len() > MAX_NODES.saturating_sub(all.len()) {
            return Err("scene graph budget exceeded".into());
        }
        let mut by_id = HashMap::new();
        for node in &self.nodes {
            if node.id.is_empty() || !all.insert(node.id.clone()) {
                return Err(format!("duplicate or empty node id {}", node.id));
            }
            if node.name.trim().is_empty() || node.name.len() > 256 {
                return Err(format!("invalid node name {}", node.id));
            }
            validate_operation(&node.operation)?;
            if let Operation::Group { graph, .. } = &node.operation {
                graph.validate_inner(depth + 1, all)?;
            }
            by_id.insert(node.id.as_str(), &node.operation);
        }
        let mut active = HashSet::new();
        let mut resolved = HashSet::new();
        fn visit(
            endpoint: &Endpoint,
            coverage: bool,
            by_id: &HashMap<&str, &Operation>,
            active: &mut HashSet<String>,
            resolved: &mut HashSet<String>,
        ) -> Result<(), String> {
            let Some(id) = endpoint.node_id() else {
                return Ok(());
            };
            let operation = by_id
                .get(id)
                .copied()
                .ok_or_else(|| format!("missing node {id}"))?;
            if operation.is_coverage() != coverage {
                return Err(format!("incompatible port {id}"));
            }
            if resolved.contains(id) {
                return Ok(());
            }
            if !active.insert(id.to_string()) {
                return Err(format!("scene graph cycle at {id}"));
            }
            for image in operation.images() {
                visit(image, false, by_id, active, resolved)?;
            }
            for mask in operation.coverages() {
                visit(&Endpoint::node(mask), true, by_id, active, resolved)?;
            }
            active.remove(id);
            resolved.insert(id.to_string());
            Ok(())
        }
        visit(&self.output, false, &by_id, &mut active, &mut resolved)?;
        if resolved.len() != self.nodes.len() {
            return Err("disconnected scene nodes".into());
        }
        Ok(())
    }
}

fn validate_operation(operation: &Operation) -> Result<(), String> {
    let unit = |value: f32| (0.0..=1.0).contains(&value);
    match operation {
        Operation::Corrector {
            exposure_ev,
            curve,
            strength,
            ..
        } => {
            if !(-12.0..=12.0).contains(exposure_ev) || !unit(*strength) {
                return Err("corrector parameter outside range".into());
            }
            if !curve.is_empty() && !(2..=16).contains(&curve.len()) {
                return Err("corrector curve count outside range".into());
            }
            for point in curve {
                if !(-24.0..=24.0).contains(&point[0])
                    || !(-24.0..=24.0).contains(&point[1])
                    || !point[0].is_finite()
                    || !point[1].is_finite()
                {
                    return Err("corrector curve point outside range".into());
                }
            }
            for pair in curve.windows(2) {
                if pair[1][0] - pair[0][0] < 0.001 || pair[1][1] < pair[0][1] {
                    return Err("corrector curve is not monotone".into());
                }
            }
        }
        Operation::Parallel { layers, .. } => {
            if !(1..=MAX_LAYERS).contains(&layers.len())
                || layers
                    .iter()
                    .any(|layer| !unit(layer.weight) || layer.mode != Blend::Normal)
            {
                return Err("invalid parallel mixer".into());
            }
        }
        Operation::Layer { layers, .. } => {
            if !(1..=MAX_LAYERS).contains(&layers.len())
                || layers.iter().any(|layer| !unit(layer.weight))
            {
                return Err("invalid layer mixer".into());
            }
        }
        Operation::Group { strength, .. } | Operation::AdjustCoverage { strength, .. } => {
            if !unit(*strength) {
                return Err("strength outside [0,1]".into());
            }
        }
        Operation::LinearCoverage { start, end } => {
            for point in [start, end] {
                if !unit(point[0])
                    || !unit(point[1])
                    || !point[0].is_finite()
                    || !point[1].is_finite()
                {
                    return Err("coverage point outside [0,1]".into());
                }
            }
            if (end[0] - start[0]).abs().max((end[1] - start[1]).abs()) < 0.0001 {
                return Err("linear coverage has no extent".into());
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
                return Err("radial coverage outside range".into());
            }
        }
        Operation::CombineCoverage { .. } => {}
        Operation::ExternalCoverage { id } => {
            if id.is_empty() || id.len() > 128 {
                return Err("invalid external coverage id".into());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal() -> Scope {
        let node = Node {
            id: "n1".into(),
            name: "Neutral".into(),
            operation: Operation::Corrector {
                image: Endpoint::input(),
                mask: None,
                exposure_ev: 0.0,
                curve: vec![],
                strength: 1.0,
                enabled: true,
            },
        };
        Scope {
            nodes: vec![node],
            output: Endpoint::node("n1"),
        }
    }

    #[test]
    fn accepts_minimal_graph() {
        minimal().validate().unwrap();
    }

    #[test]
    fn rejects_cycle() {
        let a = Node {
            id: "a".into(),
            name: "a".into(),
            operation: Operation::Corrector {
                image: Endpoint::node("b"),
                mask: None,
                exposure_ev: 0.0,
                curve: vec![],
                strength: 1.0,
                enabled: true,
            },
        };
        let b = Node {
            id: "b".into(),
            name: "b".into(),
            operation: Operation::Corrector {
                image: Endpoint::node("a"),
                mask: None,
                exposure_ev: 0.0,
                curve: vec![],
                strength: 1.0,
                enabled: true,
            },
        };
        let scope = Scope {
            nodes: vec![a, b],
            output: Endpoint::node("a"),
        };
        assert!(scope.validate().unwrap_err().contains("cycle"));
    }

    #[test]
    fn rejects_disconnected_node() {
        let mut scope = minimal();
        scope.nodes.push(Node {
            id: "unused".into(),
            name: "unused".into(),
            operation: Operation::Corrector {
                image: Endpoint::input(),
                mask: None,
                exposure_ev: 0.0,
                curve: vec![],
                strength: 1.0,
                enabled: true,
            },
        });
        assert!(scope.validate().unwrap_err().contains("disconnected"));
    }

    #[test]
    fn parses_json_fixture() {
        let bytes = include_bytes!("../fixtures/scene-basic.json");
        let (document, receipt) = parse(bytes).unwrap();
        assert_eq!(document.schema_version, 1);
        assert_eq!(receipt.nodes, 3);
        assert_eq!(receipt.coverage_nodes, 0);
    }

    #[test]
    fn parses_group_and_coverage_fixture() {
        let bytes = include_bytes!("../fixtures/scene-group-coverage.json");
        let (document, receipt) = parse(bytes).unwrap();
        assert_eq!(document.graph.output.0, "inner");
        assert_eq!(receipt.nodes, 4);
        assert_eq!(receipt.coverage_nodes, 1);
    }
}
