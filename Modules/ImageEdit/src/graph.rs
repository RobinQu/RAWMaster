use crate::filters::{AtlasLoader, AtlasSet};
use crate::{color_grading, curves_levels, exposure_gain};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

pub(crate) const SOURCE: u32 = 0;
pub(crate) const MASK: u32 = 1;
pub(crate) const EXPOSURE: u32 = 2;
pub(crate) const MATRIX: u32 = 3;
pub(crate) const BLEND: u32 = 4;
pub(crate) const PHOTO_FILTER: u32 = 5;
pub(crate) const MASKED_EXPOSURE: u32 = 6;
pub(crate) const BASIC_V3: u32 = 7;
pub(crate) const CURVES_LEVELS_V3: u32 = 8;
pub(crate) const MASK_TONE_V3: u32 = 9;
pub(crate) const COLOR_GRADING_V2: u32 = 10;
pub(crate) const MAX_MASKS: usize = 32;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Recipe {
    version: u32,
    working: String,
    output: String,
    nodes: Vec<Node>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BasicLight {
    brightness: f64,
    contrast: f64,
    black_point: f64,
    whites: f64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BasicColor {
    saturation: f64,
    vibrance: f64,
    cast: f64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BasicBlackAndWhite {
    intensity: f64,
    neutrals: f64,
    tone: f64,
}

fn basic_rows(
    light: Option<&BasicLight>,
    color: Option<&BasicColor>,
    black_and_white: Option<&BasicBlackAndWhite>,
) -> Result<[[f32; 4]; 3], String> {
    // Validate the recipe in its original precision before narrowing controls to shader uniforms.
    let light_values = light.map_or([0.0; 4], |p| {
        [p.brightness, p.contrast, p.black_point, p.whites]
    });
    let color_values = color.map_or([0.0; 3], |p| [p.saturation, p.vibrance, p.cast]);
    let mono_values = black_and_white.map_or([0.0; 3], |p| [p.intensity, p.neutrals, p.tone]);
    let controls = light_values
        .into_iter()
        .chain(color_values)
        .chain(mono_values);
    let limits = [
        (-2.0, 2.0),
        (-1.0, 2.0),
        (-2.0, 2.0),
        (-1.0, 1.0),
        (-1.0, 2.0),
        (-1.0, 2.0),
        (-1.0, 1.0),
        (0.0, 1.0),
        (-1.0, 1.0),
        (-1.0, 1.0),
    ];
    if !controls
        .zip(limits)
        .all(|(value, (min, max))| (min..=max).contains(&value))
    {
        return Err("basic_v3 control outside supported range".into());
    }
    let active = black_and_white.is_some()
        || light_values
            .into_iter()
            .chain(color_values)
            .any(|v| v != 0.0);
    // A zero-valued enabled group still participates if another group makes the V3 point pass active.
    let flags = if active {
        u32::from(light.is_some())
            | (u32::from(color.is_some()) << 1)
            | (u32::from(black_and_white.is_some()) << 2)
    } else {
        0
    };
    Ok([
        light_values.map(|v| v as f32),
        [
            color_values[0] as f32,
            color_values[1] as f32,
            color_values[2] as f32,
            flags as f32,
        ],
        [
            mono_values[0] as f32,
            mono_values[1] as f32,
            mono_values[2] as f32,
            0.0,
        ],
    ])
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum MaskToneControl {
    Exposure,
    Highlights,
    Shadows,
    Saturation,
    Contrast,
    Whites,
    Blacks,
    Hue,
}

impl MaskToneControl {
    fn rows(self, amount: f64) -> Result<[[f32; 4]; 3], String> {
        let (index, min, max) = match self {
            Self::Exposure => (0, -2.0, 2.0),
            Self::Highlights => (1, -1.0, 1.0),
            Self::Shadows => (2, -1.0, 1.0),
            Self::Saturation => (3, -1.0, 1.0),
            Self::Contrast => (4, -1.0, 2.0),
            Self::Whites => (5, -1.0, 1.0),
            Self::Blacks => (6, -2.0, 2.0),
            Self::Hue => (7, -1.0, 1.0),
        };
        if !(min..=max).contains(&amount) {
            return Err("mask_tone_v3 amount outside its control range".into());
        }
        let mut rows = [[0.0; 4]; 3];
        rows[index / 4][index % 4] = amount as f32;
        // The native layer is skipped only if the stored binary64 adjustment is neutral.
        rows[2][0] = u32::from(amount != 0.0) as f32;
        Ok(rows)
    }
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
    #[serde(rename = "photo_filter")]
    PhotoFilter {
        id: String,
        image: String,
        look: String,
        amount: f64,
        #[serde(default, rename = "repairRawAlpha")]
        repair: bool,
    },
    #[serde(rename = "masked_exposure")]
    MaskedExposure {
        id: String,
        image: String,
        mask: String,
        ev: f32,
    },
    #[serde(rename = "mask_tone_v3")]
    MaskToneV3 {
        id: String,
        image: String,
        mask: String,
        control: MaskToneControl,
        #[serde(rename = "amount")]
        _amount: serde::de::IgnoredAny,
        #[serde(skip)]
        rows: [[f32; 4]; 3],
    },
    #[serde(rename = "basic_v3")]
    BasicV3 {
        id: String,
        image: String,
        light: Option<BasicLight>,
        color: Option<BasicColor>,
        #[serde(rename = "blackAndWhite")]
        black_and_white: Option<BasicBlackAndWhite>,
    },
    #[serde(rename = "curves_levels_v3")]
    CurvesLevelsV3 {
        id: String,
        image: String,
        #[serde(rename = "curves")]
        _curves: Option<serde::de::IgnoredAny>,
        #[serde(rename = "levels")]
        _levels: Option<serde::de::IgnoredAny>,
        #[serde(skip)]
        table: Option<Box<curves_levels::Table>>,
    },
    #[serde(rename = "color_grading_v2")]
    ColorGradingV2 {
        id: String,
        image: String,
        #[serde(rename = "grading")]
        _grading: serde::de::IgnoredAny,
        #[serde(skip)]
        table: Option<color_grading::Table>,
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
            | Self::PhotoFilter { id, .. }
            | Self::MaskedExposure { id, .. }
            | Self::MaskToneV3 { id, .. }
            | Self::BasicV3 { id, .. }
            | Self::CurvesLevelsV3 { id, .. }
            | Self::ColorGradingV2 { id, .. }
            | Self::Matrix { id, .. }
            | Self::Blend { id, .. } => id,
        }
    }
}

// Layout shared with the C++ point-operator oracle. Image and mask references
// are topological step indices. A MASK step stores its coverage slot in `a`.
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
    version: u32,
    mask_ids: Vec<String>,
    pub(crate) steps: Vec<Step>,
    pub(crate) assets: AtlasSet,
    pub(crate) parameter_rows: Vec<[f32; 4]>,
}

impl Plan {
    pub fn parse(json: &str) -> Result<Self, String> {
        Self::parse_with_resources(json, None)
    }
    /// An active photo filter pins the verified atlas bytes for the lifetime of this plan.
    pub fn parse_with_resources(json: &str, resource_root: Option<&Path>) -> Result<Self, String> {
        Self::parse_with_version_limit(json, resource_root, 2)
    }

    pub(crate) fn parse_with_version_limit(
        json: &str,
        resource_root: Option<&Path>,
        maximum_version: u32,
    ) -> Result<Self, String> {
        if json.len() > 128 * 1024 {
            return Err("recipe byte limit exceeded".into());
        }
        let mut recipe: Recipe = serde_json::from_str(json).map_err(|e| e.to_string())?;
        if recipe.version > maximum_version || recipe.working != "extended-linear-srgb-premul-f32" {
            return Err("unsupported recipe version or working space".into());
        }
        let (max_nodes, max_masks) = match recipe.version {
            1 => (64, 1),
            2 => (128, MAX_MASKS),
            _ => return Err("unsupported recipe version or working space".into()),
        };
        if recipe.version == 1
            && recipe
                .nodes
                .iter()
                .any(|node| matches!(node, Node::BasicV3 { .. }))
        {
            return Err("basic_v3 requires recipe version 2".into());
        }
        if recipe.version == 1
            && recipe
                .nodes
                .iter()
                .any(|node| matches!(node, Node::ColorGradingV2 { .. }))
        {
            return Err("color_grading_v2 requires recipe version 2".into());
        }
        if !(1..=max_nodes).contains(&recipe.nodes.len()) {
            return Err(format!("expected 1..{max_nodes} nodes"));
        }
        if recipe
            .nodes
            .iter()
            .filter(|node| matches!(node, Node::Mask { .. }))
            .count()
            > max_masks
        {
            return Err(format!("expected at most {max_masks} coverage planes"));
        }
        if recipe.nodes.iter().any(|n| {
            matches!(
                n,
                Node::CurvesLevelsV3 { .. } | Node::MaskToneV3 { .. } | Node::ColorGradingV2 { .. }
            )
        }) {
            if recipe.version != 2 {
                return Err("curves_levels_v3 and mask_tone_v3 require recipe version 2".into());
            }
            #[derive(Deserialize)]
            struct RawNodes<'a> {
                #[serde(borrow)]
                nodes: Vec<&'a serde_json::value::RawValue>,
            }
            // Internally tagged serde enums buffer numeric fields. For this operator
            // recover the original decimal tokens before validating and preparing binary64 controls.
            let raw: RawNodes = serde_json::from_str(json).map_err(|e| e.to_string())?;
            for (node, raw_node) in recipe.nodes.iter_mut().zip(raw.nodes) {
                match node {
                    Node::CurvesLevelsV3 { table, .. } => {
                        *table = Some(curves_levels::prepare(raw_node.get())?);
                    }
                    Node::ColorGradingV2 { table, .. } => {
                        *table = Some(color_grading::prepare(raw_node.get())?);
                    }
                    Node::MaskToneV3 { control, rows, .. } => {
                        #[derive(Deserialize)]
                        struct NativeAmount<'a> {
                            #[serde(borrow)]
                            amount: &'a serde_json::value::RawValue,
                        }
                        let raw: NativeAmount =
                            serde_json::from_str(raw_node.get()).map_err(|e| e.to_string())?;
                        let amount = raw.amount.get().parse::<f64>().map_err(|e| e.to_string())?;
                        *rows = control.rows(amount)?;
                    }
                    _ => {}
                }
            }
        }
        let mut ids = HashMap::new();
        for (i, node) in recipe.nodes.iter().enumerate() {
            let id = node.id();
            if id.is_empty() || id.len() > 64 || ids.insert(id, i).is_some() {
                return Err("invalid or duplicate node ID".into());
            }
        }
        let root = *ids.get(recipe.output.as_str()).ok_or("missing output")?;
        let mut plan = Self {
            version: recipe.version,
            mask_ids: Vec::new(),
            steps: Vec::with_capacity(recipe.nodes.len()),
            assets: AtlasSet::default(),
            parameter_rows: Vec::new(),
        };
        let mut visiting = vec![false; recipe.nodes.len()];
        let mut ordered = vec![None; recipe.nodes.len()];
        let mut loader = AtlasLoader::new(resource_root);
        // Depth is bounded before traversal. A revisited black node is a shared upstream value.
        fn visit(
            i: usize,
            nodes: &[Node],
            ids: &HashMap<&str, usize>,
            visiting: &mut [bool],
            ordered: &mut [Option<u32>],
            plan: &mut Plan,
            loader: &mut AtlasLoader,
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
                visit(j, nodes, ids, visiting, ordered, plan, loader)
            };
            let mut op = Step::default();
            op.op = match &nodes[i] {
                Node::Source { .. } => SOURCE,
                Node::Mask { id } => {
                    op.a = plan.mask_ids.len() as u32;
                    plan.mask_ids.push(id.clone());
                    MASK
                }
                Node::Exposure { image, ev, .. } => {
                    if !(-16.0..=16.0).contains(ev) {
                        return Err("EV outside supported range".into());
                    }
                    op.a = child(image, false)?;
                    op.rows[0][0] = exposure_gain(f64::from(*ev)) as f32;
                    EXPOSURE
                }
                Node::PhotoFilter {
                    image,
                    look,
                    amount,
                    repair,
                    ..
                } => {
                    op.a = child(image, false)?;
                    op.rows = loader.parameters(look, *amount, *repair)?;
                    PHOTO_FILTER
                }
                Node::MaskedExposure {
                    image, mask, ev, ..
                } => {
                    if !(-16.0..=16.0).contains(ev) {
                        return Err("EV outside supported range".into());
                    }
                    op.a = child(image, false)?;
                    op.mask = child(mask, true)?;
                    op.rows[0][0] = *ev;
                    MASKED_EXPOSURE
                }
                Node::MaskToneV3 {
                    image, mask, rows, ..
                } => {
                    op.a = child(image, false)?;
                    op.mask = child(mask, true)?;
                    op.rows = *rows;
                    MASK_TONE_V3
                }
                Node::BasicV3 {
                    image,
                    light,
                    color,
                    black_and_white,
                    ..
                } => {
                    op.rows = basic_rows(light.as_ref(), color.as_ref(), black_and_white.as_ref())?;
                    op.a = child(image, false)?;
                    BASIC_V3
                }
                Node::CurvesLevelsV3 { image, table, .. } => {
                    op.a = child(image, false)?;
                    let table = table.as_deref().ok_or("missing curve parameters")?;
                    op.rows[0][0] = plan.parameter_rows.len() as f32;
                    op.rows[0][1] = u32::from(curves_levels::active(table)) as f32;
                    plan.parameter_rows.extend_from_slice(table);
                    CURVES_LEVELS_V3
                }
                Node::ColorGradingV2 { image, table, .. } => {
                    op.a = child(image, false)?;
                    let table = table.as_ref().ok_or("missing color grading parameters")?;
                    op.rows[0][0] = plan.parameter_rows.len() as f32;
                    op.rows[0][1] = u32::from(table.active) as f32;
                    plan.parameter_rows.extend_from_slice(&table.rows);
                    COLOR_GRADING_V2
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
            let index = plan.steps.len() as u32;
            plan.steps.push(op);
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
            &mut plan,
            &mut loader,
        )?;
        if matches!(recipe.nodes[root], Node::Mask { .. })
            || plan.steps.len() != recipe.nodes.len()
            || plan.steps.iter().filter(|s| s.op == SOURCE).count() != 1
        {
            return Err("expected one connected image output and one source".into());
        }
        plan.assets = loader.assets;
        Ok(plan)
    }

    pub fn recipe_version(&self) -> u32 {
        self.version
    }
    /// Coverage node IDs in the order used by all executors.
    pub fn mask_ids(&self) -> &[String] {
        &self.mask_ids
    }
    pub fn needs_mask(&self) -> bool {
        !self.mask_ids.is_empty()
    }
    pub(crate) fn order_masks<'a, T>(
        &self,
        inputs: impl IntoIterator<Item = (&'a str, T)>,
    ) -> Result<Vec<T>, String> {
        let mut ordered: Vec<Option<T>> = self.mask_ids.iter().map(|_| None).collect();
        for (id, value) in inputs {
            let slot = self
                .mask_ids
                .iter()
                .position(|expected| expected == id)
                .ok_or("unknown coverage plane")?;
            if ordered[slot].replace(value).is_some() {
                return Err(format!("duplicate coverage plane {id}"));
            }
        }
        ordered
            .into_iter()
            .zip(&self.mask_ids)
            .map(|(value, id)| value.ok_or_else(|| format!("missing coverage plane {id}")))
            .collect()
    }
    pub fn accepts_raw_transport(&self) -> bool {
        self.steps
            .iter()
            .any(|s| s.op == PHOTO_FILTER && s.rows[0][3] == 1.0)
    }
    #[cfg(feature = "gpu")]
    pub(crate) fn topology(&self) -> Vec<[u32; 4]> {
        self.steps
            .iter()
            .map(|s| [s.op, s.a, s.b, s.mask])
            .collect()
    }
}
