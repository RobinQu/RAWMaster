use anyhow::{Context, Result};
use half::f16;
use mlx_rs::{fast, nn, ops, Array, Dtype};
use safetensors::SafeTensors;
use std::collections::HashMap;
use std::path::Path;

pub struct Vae {
    w: HashMap<String, Array>,
    bn_mean: Array,
    bn_var: Array,
    dtype: Dtype,
}

fn load_weights(path: &Path) -> Result<HashMap<String, Array>> {
    let bytes = std::fs::read(path)?;
    let tensors = SafeTensors::deserialize(&bytes)?;
    let mut w = HashMap::new();
    for (name, view) in tensors.tensors() {
        w.insert(name.to_string(), Array::try_from(view)?);
    }
    Ok(w)
}

impl Vae {
    pub fn load(path: &Path, dtype: Dtype) -> Result<Self> {
        let raw = load_weights(path)?;
        let bn_mean = raw
            .get("bn.running_mean")
            .context("bn.running_mean")?
            .as_dtype(Dtype::Float32)?;
        let bn_var = raw
            .get("bn.running_var")
            .context("bn.running_var")?
            .as_dtype(Dtype::Float32)?;
        let mut w = HashMap::new();
        for (name, value) in raw {
            if name.starts_with("bn.") {
                continue;
            }
            w.insert(name, value.as_dtype(dtype)?);
        }
        Ok(Self {
            w,
            bn_mean,
            bn_var,
            dtype,
        })
    }

    fn weight(&self, name: &str) -> Result<&Array> {
        self.w
            .get(name)
            .with_context(|| format!("missing VAE tensor {name}"))
    }

    fn conv(&self, x: &Array, name: &str, stride: i32, padding: i32) -> Result<Array> {
        let w = self.weight(&format!("{name}.weight"))?;
        let b = self.weight(&format!("{name}.bias"))?;
        Ok(ops::conv2d(x, w, (stride, stride), (padding, padding), (1, 1), 1)?.add(b)?)
    }

    fn norm(&self, x: &Array, name: &str, silu: bool) -> Result<Array> {
        let shape = x.shape().to_vec();
        let (b, h, w, c) = (shape[0], shape[1], shape[2], shape[3]);
        let groups = 32;
        let channel_group = c / groups;
        let y = x
            .as_dtype(Dtype::Float32)?
            .reshape(&[b, h * w, groups, channel_group])?
            .transpose_axes(&[0, 2, 1, 3])?
            .reshape(&[b, groups, -1])?;
        let y = fast::layer_norm(&y, None, None, 1e-6)?;
        let y = y
            .reshape(&[b, groups, h * w, channel_group])?
            .transpose_axes(&[0, 2, 1, 3])?
            .reshape(&[b, h, w, c])?;
        let y = y
            .multiply(
                &self
                    .weight(&format!("{name}.weight"))?
                    .as_dtype(Dtype::Float32)?,
            )?
            .add(
                &self
                    .weight(&format!("{name}.bias"))?
                    .as_dtype(Dtype::Float32)?,
            )?
            .as_dtype(self.dtype)?;
        if silu {
            Ok(nn::silu(&y)?)
        } else {
            Ok(y)
        }
    }

    fn block(&self, x: &Array, name: &str) -> Result<Array> {
        let h = self.conv(
            &self.norm(x, &format!("{name}.norm1"), true)?,
            &format!("{name}.conv1"),
            1,
            1,
        )?;
        let h = self.conv(
            &self.norm(&h, &format!("{name}.norm2"), true)?,
            &format!("{name}.conv2"),
            1,
            1,
        )?;
        let base = if self.w.contains_key(&format!("{name}.nin_shortcut.weight")) {
            self.conv(x, &format!("{name}.nin_shortcut"), 1, 0)?
        } else {
            x.clone()
        };
        Ok(base.add(&h)?)
    }

    fn attention(&self, x: &Array, name: &str) -> Result<Array> {
        let h = self.norm(x, &format!("{name}.norm"), false)?;
        let shape = h.shape().to_vec();
        let channels = shape[3];
        let q = self
            .conv(&h, &format!("{name}.q"), 1, 0)?
            .reshape(&[1, 1, -1, channels])?;
        let k = self
            .conv(&h, &format!("{name}.k"), 1, 0)?
            .reshape(&[1, 1, -1, channels])?;
        let v = self
            .conv(&h, &format!("{name}.v"), 1, 0)?
            .reshape(&[1, 1, -1, channels])?;
        let n = q.shape()[2];
        let mut parts = Vec::new();
        let mut start = 0;
        while start < n {
            let len = (n - start).min(512);
            let indices: Vec<i32> = (start..start + len).collect();
            let idx = Array::from_slice(&indices, &[len]);
            let query = q.take_axis(&idx, 2)?;
            parts.push(fast::scaled_dot_product_attention(
                &query,
                &k,
                &v,
                (channels as f32).sqrt().recip(),
                None::<fast::ScaledDotProductAttentionMask>,
                None::<&Array>,
            )?);
            start += len;
        }
        let h = ops::concatenate(&parts, 2)?.reshape(&shape)?;
        Ok(x.add(&self.conv(&h, &format!("{name}.proj_out"), 1, 0)?)?)
    }

    pub fn encode(&self, image: &Array) -> Result<Array> {
        let shape = image.shape().to_vec();
        let (h, w) = (shape[0], shape[1]);
        let mut x = self.conv(
            &image.reshape(&[1, h, w, 3])?.as_dtype(self.dtype)?,
            "encoder.conv_in",
            1,
            1,
        )?;
        for level in 0..4 {
            for block in 0..2 {
                x = self.block(&x, &format!("encoder.down.{level}.block.{block}"))?;
            }
            if level < 3 {
                x = ops::pad(&x, &[(0, 0), (0, 1), (0, 1), (0, 0)], None, None)?;
                x = self.conv(&x, &format!("encoder.down.{level}.downsample.conv"), 2, 0)?;
            }
        }
        x = self.block(&x, "encoder.mid.block_1")?;
        x = self.attention(&x, "encoder.mid.attn_1")?;
        x = self.block(&x, "encoder.mid.block_2")?;
        let mean = self.conv(
            &self.conv(
                &self.norm(&x, "encoder.norm_out", true)?,
                "encoder.conv_out",
                1,
                1,
            )?,
            "encoder.quant_conv",
            1,
            0,
        )?;
        let mean = mean.split_at_indices(&[32], -1)?.remove(0);
        let h2 = mean.shape()[1] / 2;
        let w2 = mean.shape()[2] / 2;
        let tokens = mean
            .reshape(&[1, h2, 2, w2, 2, 32])?
            .transpose_axes(&[0, 1, 3, 5, 2, 4])?
            .reshape(&[h2 * w2, 128])?;
        let inverse = self.bn_var.add(&Array::from_f32(1e-4))?.rsqrt()?;
        let tokens = tokens.subtract(&self.bn_mean)?.multiply(&inverse)?;
        Ok(tokens.as_dtype(Dtype::Float32)?)
    }

    pub fn decode(&self, tokens: &Array, height: i32, width: i32) -> Result<Array> {
        let h = height / 16;
        let w = width / 16;
        let z = tokens.as_dtype(Dtype::Float32)?.reshape(&[1, h, w, 128])?;
        let scale = self.bn_var.add(&Array::from_f32(1e-4))?.sqrt()?;
        let z = z.multiply(&scale)?.add(&self.bn_mean)?;
        let z = z
            .reshape(&[1, h, w, 32, 2, 2])?
            .transpose_axes(&[0, 1, 4, 2, 5, 3])?
            .reshape(&[1, h * 2, w * 2, 32])?;
        let mut x = self.conv(
            &self.conv(&z.as_dtype(self.dtype)?, "decoder.post_quant_conv", 1, 0)?,
            "decoder.conv_in",
            1,
            1,
        )?;
        x = self.block(&x, "decoder.mid.block_1")?;
        x = self.attention(&x, "decoder.mid.attn_1")?;
        x = self.block(&x, "decoder.mid.block_2")?;
        for level in (0..4).rev() {
            for block in 0..3 {
                x = self.block(&x, &format!("decoder.up.{level}.block.{block}"))?;
            }
            if level > 0 {
                x = ops::repeat_axis::<f16>(&x, 2, 1)?;
                x = ops::repeat_axis::<f16>(&x, 2, 2)?;
                x = self.conv(&x, &format!("decoder.up.{level}.upsample.conv"), 1, 1)?;
            }
        }
        let image = self.conv(
            &self.norm(&x, "decoder.norm_out", true)?,
            "decoder.conv_out",
            1,
            1,
        )?;
        let image = image.split_at_indices(&[1], 0)?.remove(0);
        Ok(image.as_dtype(Dtype::Float32)?)
    }
}
