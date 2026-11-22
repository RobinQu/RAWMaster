use serde::Deserialize;
use std::collections::HashMap;

pub(crate) const SOURCE: u32 = 0;
pub(crate) const MASK: u32 = 1;
pub(crate) const EXPOSURE: u32 = 2;
pub(crate) const MATRIX: u32 = 3;
pub(crate) const BLEND: u32 = 4;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Recipe {
    version: u32,
    working: String,
    output: String,
    nodes: Vec<Node>,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "lowercase", deny_unknown_fields)]
enum Node {
    Source {
        id: String,
    },
    Mask {
        id: String,
    },
    Exposure {
        id: String,
        image: String,
        ev: f32,
    },
    Matrix {
        id: String,
        image: String,
        rows: [[f32; 3]; 3],
    },
    Blend {
        id: String,
        base: String,
        layer: String,
        mask: String,
    },
}
impl Node {
    fn id(&self) -> &str {
        match self {
            Self::Source { id }
            | Self::Mask { id }
            | Self::Exposure { id, .. }
            | Self::Matrix { id, .. }
            | Self::Blend { id, .. } => id,
        }
    }
}

// Layout shared only with the C++ point-operator oracle. Step references are
// indices in topological order. All mask nodes resolve to the one input plane.
#[repr(C)]
#[derive(Default, Clone)]
pub(crate) struct Step {
    pub op: u32,
    pub a: u32,
    pub b: u32,
    pub mask: u32,
    pub rows: [[f32; 4]; 3],
}
pub struct Plan {
    pub(crate) steps: Vec<Step>,
}

impl Plan {
    pub fn parse(json: &str) -> Result<Self, String> {
        if json.len() > 128 * 1024 {
            return Err("recipe byte limit exceeded".into());
        }
        let recipe: Recipe = serde_json::from_str(json).map_err(|e| e.to_string())?;
        if recipe.version != 1 || recipe.working != "extended-linear-srgb-premul-f32" {
            return Err("unsupported recipe version or working space".into());
        }
        if !(1..=64).contains(&recipe.nodes.len()) {
            return Err("expected 1..64 nodes".into());
        }
        let mut ids = HashMap::new();
        for (i, node) in recipe.nodes.iter().enumerate() {
            let id = node.id();
            if id.is_empty() || id.len() > 64 || ids.insert(id, i).is_some() {
                return Err("invalid or duplicate node ID".into());
            }
        }
        let root = *ids.get(recipe.output.as_str()).ok_or("missing output")?;
        let mut steps = Vec::new();
        let mut visiting = vec![false; recipe.nodes.len()];
        let mut ordered = vec![None; recipe.nodes.len()];
        // Depth is bounded before traversal. A revisited black node is a shared upstream value.
        fn visit(
            i: usize,
            nodes: &[Node],
            ids: &HashMap<&str, usize>,
            visiting: &mut [bool],
            ordered: &mut [Option<u32>],
            steps: &mut Vec<Step>,
        ) -> Result<u32, String> {
            if let Some(old) = ordered[i] {
                return Ok(old);
            }
            if visiting[i] {
                return Err(format!("cycle at {}", nodes[i].id()));
            }
            visiting[i] = true;
            let mut child = |id: &str, mask: bool| -> Result<u32, String> {
                let j = *ids.get(id).ok_or_else(|| format!("missing input {id}"))?;
                if matches!(nodes[j], Node::Mask { .. }) != mask {
                    return Err(format!("port type mismatch at {id}"));
                }
                visit(j, nodes, ids, visiting, ordered, steps)
            };
            let mut op = Step::default();
            op.op = match &nodes[i] {
                Node::Source { .. } => SOURCE,
                Node::Mask { .. } => MASK,
                Node::Exposure { image, ev, .. } => {
                    if !(-16.0..=16.0).contains(ev) {
                        return Err("EV outside supported range".into());
                    }
                    op.a = child(image, false)?;
                    op.rows[0][0] = ev.exp2(); // Shared uniform, computed once per recipe edit.
                    EXPOSURE
                }
                Node::Matrix { image, rows, .. } => {
                    op.a = child(image, false)?;
                    for (dst, src) in op.rows.iter_mut().zip(rows) {
                        if !src.iter().all(|v| (-16.0..=16.0).contains(v)) {
                            return Err("invalid matrix".into());
                        }
                        dst[..3].copy_from_slice(src);
                    }
                    MATRIX
                }
                Node::Blend {
                    base, layer, mask, ..
                } => {
                    op.a = child(base, false)?;
                    op.b = child(layer, false)?;
                    op.mask = child(mask, true)?;
                    BLEND
                }
            };
            let index = steps.len() as u32;
            steps.push(op);
            ordered[i] = Some(index);
            visiting[i] = false;
            Ok(index)
        }
        visit(
            root,
            &recipe.nodes,
            &ids,
            &mut visiting,
            &mut ordered,
            &mut steps,
        )?;
        if matches!(recipe.nodes[root], Node::Mask { .. })
            || steps.len() != recipe.nodes.len()
            || steps.iter().filter(|s| s.op == SOURCE).count() != 1
            || steps.iter().filter(|s| s.op == MASK).count() > 1
        {
            return Err(
                "expected one connected image output, one source and at most one coverage plane"
                    .into(),
            );
        }
        Ok(Self { steps })
    }

    #[cfg(feature = "gpu")]
    pub(crate) fn topology(&self) -> Vec<[u32; 4]> {
        self.steps
            .iter()
            .map(|s| [s.op, s.a, s.b, s.mask])
            .collect()
    }
}
