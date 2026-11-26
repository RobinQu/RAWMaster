use crate::weights::Weights;
use anyhow::{bail, Result};
use mlx_rs::{fast, nn, ops, Array, Dtype};
use std::collections::HashMap;

pub const HIDDEN: i32 = 3072;
pub const MLP: i32 = 9216;
pub const HEADS: i32 = 24;
pub const HEAD_DIM: i32 = 128;

pub struct Block {
    pub prefix: String,
}

pub struct Mods {
    pub early: HashMap<String, (Array, Array, Array)>,
    pub single: HashMap<String, (Array, Array, Array)>,
    pub fin: (Array, Array),
}

pub struct DiT {
    pub w: Weights,
    pub early: HashMap<String, Vec<Block>>,
    pub single: Vec<Block>,
    pub mods: Vec<Mods>,
    pub freqs: HashMap<String, (Array, Array)>,
    pub sizes: HashMap<String, i32>,
    pub order: Vec<String>,
    pub projected_text: Option<Array>,
    pub projected_reference: Option<Array>,
}

fn scaled_one() -> Array {
    Array::from_f32(1.0)
}

fn modulate(x: &Array, scale: &Array, shift: &Array) -> Result<Array> {
    let normalized = fast::layer_norm(x, None, None, 1e-6)?;
    Ok(normalized
        .multiply(&scale.add(&scaled_one())?)?
        .add(shift)?)
}

fn compact_normalize(x: &Array, shift: &Array, scale: &Array) -> Result<Array> {
    let normalized = fast::layer_norm(x, None, None, 1e-6)?;
    let y = normalized
        .multiply(&scale.add(&scaled_one())?)?
        .add(shift)?;
    Ok(y.divide(&Array::from_f32(256.0))?
        .as_dtype(Dtype::Float16)?)
}

fn timestep(t: f32) -> Result<Array> {
    let t = Array::from_slice(&[t], &[1])
        .as_dtype(Dtype::Float32)?
        .multiply(&Array::from_f32(1000.0))?;
    let index = ops::arange::<i32, f32>(0, 128, 1)?;
    let freq = ops::exp(&index.multiply(&Array::from_f32(-0.071_940_417))?)?;
    let args = t.expand_dims(1)?.multiply(&freq.expand_dims(0)?)?;
    Ok(ops::concatenate(&[args.cos()?, args.sin()?], -1)?)
}

pub fn rotary(ids: &[[f32; 4]]) -> (Array, Array) {
    let n = ids.len();
    let mut cos = Vec::with_capacity(n * 64);
    let mut sin = Vec::with_capacity(n * 64);
    for row in ids {
        for axis in 0..4 {
            for i in 0..16 {
                let angle = (row[axis] as f64) / 10_000f64.powf((2 * i) as f64 / 32.0);
                cos.push(angle.cos() as f32);
                sin.push(angle.sin() as f32);
            }
        }
    }
    (
        Array::from_slice(&cos, &[1, 1, n as i32, 64]),
        Array::from_slice(&sin, &[1, 1, n as i32, 64]),
    )
}

fn rms_rope(x: &Array, weight: &Array, cos: &Array, sin: &Array) -> Result<Array> {
    let n = x.shape()[2];
    let x = x
        .as_dtype(Dtype::Float32)?
        .multiply(&Array::from_f32(256.0))?;
    let weight = weight.as_dtype(Dtype::Float32)?;
    let normalized = fast::rms_norm(&x, Some(&weight), 1e-6)?;
    let paired = normalized.reshape(&[1, HEADS, n, HEAD_DIM / 2, 2])?;
    let parts = paired.split_at_indices(&[1], -1)?;
    let even = parts[0].squeeze_axes(&[-1])?;
    let odd = parts[1].squeeze_axes(&[-1])?;
    let out_even = even.multiply(cos)?.subtract(&odd.multiply(sin)?)?;
    let out_odd = even.multiply(sin)?.add(&odd.multiply(cos)?)?;
    Ok(ops::stack(&[out_even, out_odd], -1)?.reshape(&[1, HEADS, n, HEAD_DIM])?)
}

impl Block {
    pub fn forward(
        &self,
        w: &Weights,
        x: &Array,
        cos: &Array,
        sin: &Array,
        shift: &Array,
        scale: &Array,
        gate: &Array,
    ) -> Result<Array> {
        let normalized = compact_normalize(x, shift, scale)?;
        let projected = w.linear(&format!("{}.in_proj", self.prefix), &normalized, true, true)?;
        let parts = projected.split_at_indices(&[HIDDEN, 2 * HIDDEN, 3 * HIDDEN], -1)?;
        let q = parts[0]
            .reshape(&[1, -1, HEADS, HEAD_DIM])?
            .transpose_axes(&[0, 2, 1, 3])?;
        let k = parts[1]
            .reshape(&[1, -1, HEADS, HEAD_DIM])?
            .transpose_axes(&[0, 2, 1, 3])?;
        let v = parts[2]
            .reshape(&[1, -1, HEADS, HEAD_DIM])?
            .transpose_axes(&[0, 2, 1, 3])?
            .as_dtype(Dtype::Float16)?;
        let mlp = &parts[3];
        let qw = w.get(&format!("{}.norm.query_norm.scale", self.prefix))?;
        let kw = w.get(&format!("{}.norm.key_norm.scale", self.prefix))?;
        let q = rms_rope(&q, qw, cos, sin)?.as_dtype(Dtype::Float16)?;
        let k = rms_rope(&k, kw, cos, sin)?.as_dtype(Dtype::Float16)?;
        let attention = fast::scaled_dot_product_attention(
            &q,
            &k,
            &v,
            (HEAD_DIM as f32).sqrt().recip(),
            None::<fast::ScaledDotProductAttentionMask>,
            None::<&Array>,
        )?;
        let attention = attention
            .transpose_axes(&[0, 2, 1, 3])?
            .reshape(&[-1, HIDDEN])?;
        let mlp_parts = mlp.split_at_indices(&[MLP], -1)?;
        let gate_in = mlp_parts[0]
            .as_dtype(Dtype::Float32)?
            .multiply(&Array::from_f32(256.0))?;
        let up = mlp_parts[1]
            .as_dtype(Dtype::Float32)?
            .multiply(&Array::from_f32(256.0))?;
        let mlp_out = nn::silu(&gate_in)?
            .multiply(&up)?
            .divide(&Array::from_f32(256.0))?
            .as_dtype(Dtype::Float16)?;
        let packed = ops::concatenate(&[attention, mlp_out], -1)?;
        let out = w.linear(&format!("{}.out_proj", self.prefix), &packed, true, true)?;
        let residual = out
            .as_dtype(Dtype::Float32)?
            .multiply(&Array::from_f32(256.0))?;
        let gated = gate.multiply(&residual)?;
        Ok(x.add(&gated)?)
    }
}

impl DiT {
    pub fn load(model_dir: &std::path::Path, max_steps: usize, fp16_weights: bool) -> Result<Self> {
        let transformer = model_dir.join("transformer");
        let image_conditioning = model_dir.join("image_conditioning");
        if !transformer.is_dir() || !image_conditioning.is_dir() {
            bail!(
                "missing transformer or image_conditioning in {}",
                model_dir.display()
            );
        }
        let w = Weights::load_with(&[transformer, image_conditioning], fp16_weights)?;
        let mut early = HashMap::new();
        for (mode, prefix) in [
            ("image", "content_mode_blocks.image"),
            ("image_cond", "content_mode_blocks.image_cond"),
            ("text", "txt_mode_blocks"),
        ] {
            let mut blocks = Vec::new();
            for layer in 0..5 {
                blocks.push(Block {
                    prefix: format!("{prefix}.{layer}"),
                });
            }
            early.insert(mode.to_string(), blocks);
        }
        let mut single = Vec::new();
        for layer in 0..28 {
            single.push(Block {
                prefix: format!("single_blocks.{layer}"),
            });
        }
        Ok(Self {
            w,
            early,
            single,
            mods: Vec::with_capacity(max_steps),
            freqs: HashMap::new(),
            sizes: HashMap::new(),
            order: vec!["image".into(), "image_cond".into(), "text".into()],
            projected_text: None,
            projected_reference: None,
        })
    }

    fn embed(&self, prefix: &str, t: f32) -> Result<Array> {
        let x = timestep(t)?;
        let hidden = self
            .w
            .linear(&format!("{prefix}.in_layer"), &x, false, false)?;
        let hidden = nn::silu(&hidden)?;
        self.w
            .linear(&format!("{prefix}.out_layer"), &hidden, false, false)
    }

    pub fn prepare(
        &mut self,
        schedule: &[f32],
        ids: &HashMap<String, Vec<[f32; 4]>>,
    ) -> Result<()> {
        let fixed = self.embed("time_in", 0.0)?;
        for step in 0..schedule.len().saturating_sub(1) {
            let reference_time = self.embed("ref_time_in", schedule[step + 1])?;
            let image_vec = self
                .embed("time_in", schedule[step])?
                .add(&reference_time)?;
            let other_vec = fixed.add(&reference_time)?;
            let mut early = HashMap::new();
            let mut single = HashMap::new();
            for mode in ["image", "image_cond", "text"] {
                let key = if mode == "text" { "txt" } else { mode };
                let vec = if mode == "image" {
                    &image_vec
                } else {
                    &other_vec
                };
                let activated = nn::silu(vec)?;
                let e = self.w.linear(
                    &format!("early_stream_modulations.{key}.lin"),
                    &activated,
                    false,
                    false,
                )?;
                let e = e.split_at_indices(&[HIDDEN, 2 * HIDDEN], -1)?;
                early.insert(mode.to_string(), (e[0].clone(), e[1].clone(), e[2].clone()));
                let s = self.w.linear(
                    &format!("single_stream_modulations.{key}.lin"),
                    &activated,
                    false,
                    false,
                )?;
                let s = s.split_at_indices(&[HIDDEN, 2 * HIDDEN], -1)?;
                single.insert(mode.to_string(), (s[0].clone(), s[1].clone(), s[2].clone()));
            }
            let finishing = self.w.linear(
                "final_layer.image.adaLN_modulation.1",
                &nn::silu(&image_vec)?,
                false,
                false,
            )?;
            let f = finishing.split_at_indices(&[HIDDEN], -1)?;
            self.mods.push(Mods {
                early,
                single,
                fin: (f[0].clone(), f[1].clone()),
            });
        }
        for mode in ["image", "image_cond", "text"] {
            self.sizes.insert(mode.to_string(), ids[mode].len() as i32);
            self.freqs.insert(mode.to_string(), rotary(&ids[mode]));
        }
        let mut all = Vec::new();
        for mode in ["image", "image_cond", "text"] {
            all.extend_from_slice(&ids[mode]);
        }
        self.freqs.insert("single".into(), rotary(&all));
        Ok(())
    }

    pub fn forward(
        &mut self,
        image: &Array,
        text: &Array,
        reference: &Array,
        step: usize,
    ) -> Result<Array> {
        if self.projected_text.is_none() {
            let p = self
                .w
                .linear("txt_in", &text.as_dtype(Dtype::Float32)?, false, false)?;
            self.projected_text = Some(p);
        }
        if self.projected_reference.is_none() {
            let p = self.w.linear(
                "emb_in.image_cond",
                &reference.as_dtype(Dtype::Float32)?,
                false,
                false,
            )?;
            self.projected_reference = Some(p);
        }
        let image_proj = self.w.linear(
            "emb_in.image",
            &image.as_dtype(Dtype::Float32)?,
            false,
            false,
        )?;
        let mut x: Vec<(String, Array)> = vec![
            ("image".into(), image_proj),
            (
                "image_cond".into(),
                self.projected_reference.as_ref().unwrap().clone(),
            ),
            ("text".into(), self.projected_text.as_ref().unwrap().clone()),
        ];
        let mods = &self.mods[step];
        for layer in 0..5 {
            for (mode, value) in x.iter_mut() {
                let (shift, scale, gate) = &mods.early[mode];
                let (cos, sin) = &self.freqs[mode];
                *value = self.early[mode][layer]
                    .forward(&self.w, value, cos, sin, shift, scale, gate)?;
            }
        }
        let mut single_mods: Vec<Array> = Vec::with_capacity(3);
        for index in 0..3 {
            let mut rows = Vec::with_capacity(self.order.len());
            for mode in &self.order {
                let (a, b, c) = &mods.single[mode];
                let row = match index {
                    0 => a,
                    1 => b,
                    _ => c,
                };
                rows.push(ops::broadcast_to(row, &[self.sizes[mode], HIDDEN])?);
            }
            single_mods.push(ops::concatenate(&rows, 0)?);
        }
        let values: Vec<Array> = x.into_iter().map(|(_, value)| value).collect();
        let mut h = ops::concatenate(&values, 0)?;
        let (cos, sin) = &self.freqs["single"];
        for block in &self.single {
            h = block.forward(
                &self.w,
                &h,
                cos,
                sin,
                &single_mods[0],
                &single_mods[1],
                &single_mods[2],
            )?;
        }
        let (shift, scale) = &mods.fin;
        let image_size = self.sizes["image"];
        let image_tokens = h.split_at_indices(&[image_size], 0)?[0].clone();
        let final_input = modulate(&image_tokens, scale, shift)?;
        self.w
            .linear("final_layer.image.linear", &final_input, false, false)
    }
}
