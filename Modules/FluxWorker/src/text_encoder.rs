use crate::tokenizer::PromptTokens;
use crate::weights::Weights;
use anyhow::{Context, Result};
use mlx_rs::{fast, memory, nn, ops, Array, Dtype};
use std::path::Path;

const HEADS: i32 = 32;
const KV_HEADS: i32 = 8;
const HEAD_DIM: i32 = 128;
const FFN: i32 = 9728;
const TAPS: i32 = 8;

fn text_norm(x: &Array, weight: &Array) -> Result<Array> {
    let norm = fast::rms_norm(x.as_dtype(Dtype::Float32)?, None, 1e-6)?;
    Ok(norm.multiply(&weight.as_dtype(Dtype::Float32)?)?)
}

fn text_rope(x: &Array, cos: &Array, sin: &Array) -> Result<Array> {
    let half = x.shape()[3] / 2;
    let parts = x.split_at_indices(&[half], -1)?;
    let negated = parts[1].multiply(&Array::from_f32(-1.0))?;
    let rotated = ops::concatenate(&[negated, parts[0].clone()], -1)?;
    Ok(x.multiply(cos)?.add(&rotated.multiply(sin)?)?)
}

fn build_rope(positions: &[i32]) -> (Array, Array) {
    let length = positions.len();
    let mut cos = Vec::with_capacity(length * 128);
    let mut sin = Vec::with_capacity(length * 128);
    for &position in positions {
        let mut row_cos = Vec::with_capacity(64);
        let mut row_sin = Vec::with_capacity(64);
        for i in 0..64 {
            let angle = (position as f64) / 5_000_000f64.powf((2 * i) as f64 / 128.0);
            row_cos.push(angle.cos() as f32);
            row_sin.push(angle.sin() as f32);
        }
        cos.extend_from_slice(&row_cos);
        cos.extend_from_slice(&row_cos);
        sin.extend_from_slice(&row_sin);
        sin.extend_from_slice(&row_sin);
    }
    (
        Array::from_slice(&cos, &[1, 1, length as i32, 128]),
        Array::from_slice(&sin, &[1, 1, length as i32, 128]),
    )
}

fn build_mask(valid: &[bool]) -> Array {
    let length = valid.len();
    let mut mask = vec![false; length * length];
    for i in 0..length {
        for j in 0..=i {
            mask[i * length + j] = valid[j];
        }
    }
    Array::from_slice(&mask, &[1, 1, length as i32, length as i32])
}

fn layer_forward(
    w: &Weights,
    x: &Array,
    cos: &Array,
    sin: &Array,
    mask: &Array,
    p: &str,
) -> Result<Array> {
    let y = text_norm(x, w.get(&format!("{p}input_layernorm.weight"))?)?;
    let qkv = w.linear(&format!("{p}self_attn.qkv_proj"), &y, false, false)?;
    let parts = qkv.split_at_indices(&[4096, 5120], -1)?;
    let q = parts[0].reshape(&[1, -1, HEADS, HEAD_DIM])?;
    let k = parts[1].reshape(&[1, -1, KV_HEADS, HEAD_DIM])?;
    let v = parts[2]
        .reshape(&[1, -1, KV_HEADS, HEAD_DIM])?
        .transpose_axes(&[0, 2, 1, 3])?;
    let q = text_norm(&q, w.get(&format!("{p}self_attn.q_norm.weight"))?)?
        .transpose_axes(&[0, 2, 1, 3])?;
    let k = text_norm(&k, w.get(&format!("{p}self_attn.k_norm.weight"))?)?
        .transpose_axes(&[0, 2, 1, 3])?;
    let q = text_rope(&q, cos, sin)?.as_dtype(Dtype::Float16)?;
    let k = text_rope(&k, cos, sin)?.as_dtype(Dtype::Float16)?;
    let v = v.as_dtype(Dtype::Float16)?;
    let attention = fast::scaled_dot_product_attention(
        &q,
        &k,
        &v,
        (HEAD_DIM as f32).sqrt().recip(),
        mask,
        None::<&Array>,
    )?;
    let attention = attention
        .transpose_axes(&[0, 2, 1, 3])?
        .reshape(&[1, -1, HEADS * HEAD_DIM])?;
    let mut x = x.add(&w.linear(&format!("{p}self_attn.o_proj"), &attention, false, false)?)?;
    let y = text_norm(&x, w.get(&format!("{p}post_attention_layernorm.weight"))?)?;
    let gate_up = w.linear(&format!("{p}mlp.gate_up_proj"), &y, false, false)?;
    let parts = gate_up.split_at_indices(&[FFN], -1)?;
    let activated = nn::silu(&parts[0])?.multiply(&parts[1])?;
    x = x.add(&w.linear(&format!("{p}mlp.down_proj"), &activated, false, false)?)?;
    Ok(x)
}

pub fn encode(model_root: &Path, tokens: &PromptTokens) -> Result<Array> {
    let dir = model_root.join("q8/text_encoder");
    let embedding = Weights::from_file(&dir.join("embedding.safetensors"))?;
    let ids: Vec<i32> = tokens.ids.iter().map(|&id| id as i32).collect();
    let x = embedding.embedding(&ids)?.expand_dims(0)?;
    x.eval()?;
    drop(embedding);
    memory::clear_cache()?;

    let (cos, sin) = build_rope(&tokens.positions);
    let mask = build_mask(&tokens.valid);
    let mut taps = Vec::with_capacity(TAPS as usize);
    let mut x = x;
    for layer in 0..32 {
        let path = dir.join(format!("layer-{layer:02}.safetensors"));
        let w = Weights::from_file(&path).with_context(|| format!("load {}", path.display()))?;
        x = layer_forward(&w, &x, &cos, &sin, &mask, &format!("layers.{layer}."))?;
        x.eval()?;
        if (layer + 1) % 4 == 0 {
            taps.push(x.clone());
        }
        drop(w);
        memory::clear_cache()?;
    }
    let length = tokens.ids.len() as i32;
    let text = ops::stack(&taps, 2)?.reshape(&[length, 20480])?;
    text.eval()?;
    Ok(text.as_dtype(Dtype::Float32)?)
}
