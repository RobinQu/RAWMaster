use anyhow::{Context, Result};
use mlx_rs::{
    ops::{dequantize, quantized_matmul, DequantizeOptions, QuantizedMatmulOptions},
    Array, Dtype,
};
use safetensors::SafeTensors;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub struct Weights {
    pub w: HashMap<String, Array>,
    pub bits: i32,
    pub group_size: i32,
}

fn is_scaled(name: &str) -> bool {
    !name.starts_with("time_in.")
        && !name.starts_with("ref_time_in.")
        && !name.starts_with("early_stream_modulations.")
        && !name.starts_with("single_stream_modulations.")
        && !name.starts_with("final_layer.")
}

impl Weights {
    fn load_file_into(path: &Path, w: &mut HashMap<String, Array>) -> Result<()> {
        let bytes = std::fs::read(path)?;
        let tensors = SafeTensors::deserialize(&bytes)?;
        for (name, view) in tensors.tensors() {
            let array = Array::try_from(view)?;
            w.insert(name.to_string(), array);
        }
        Ok(())
    }

    pub fn from_file(path: &Path) -> Result<Self> {
        let mut w = HashMap::new();
        Self::load_file_into(path, &mut w)?;
        Ok(Self {
            w,
            bits: 8,
            group_size: 64,
        })
    }

    pub fn load_with(dirs: &[PathBuf], fp16_weights: bool) -> Result<Self> {
        let mut w = HashMap::new();
        for dir in dirs {
            let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
                .with_context(|| format!("read {}", dir.display()))?
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.extension().map(|e| e == "safetensors").unwrap_or(false))
                .collect();
            files.sort();
            for file in files {
                let mut loaded = HashMap::new();
                Self::load_file_into(&file, &mut loaded)?;
                if fp16_weights {
                    let names: Vec<String> = loaded
                        .keys()
                        .filter(|name| {
                            name.ends_with(".weight")
                                && loaded.contains_key(&name.replace(".weight", ".scales"))
                        })
                        .cloned()
                        .collect();
                    for name in names {
                        let scales = loaded
                            .get(&name.replace(".weight", ".scales"))
                            .context("quantized scales")?
                            .clone();
                        let biases = loaded
                            .get(&name.replace(".weight", ".biases"))
                            .context("quantized biases")?
                            .clone();
                        let weight = loaded.get(&name).context("quantized weight")?;
                        let dense = dequantize(
                            weight,
                            &scales,
                            Some(&biases),
                            DequantizeOptions {
                                group_size: Some(64),
                                bits: Some(8),
                                ..Default::default()
                            },
                        )?;
                        dense.eval()?;
                        loaded.insert(name.clone(), dense);
                        loaded.remove(&name.replace(".weight", ".scales"));
                        loaded.remove(&name.replace(".weight", ".biases"));
                    }
                }
                w.extend(loaded);
            }
        }
        Ok(Self {
            w,
            bits: 8,
            group_size: 64,
        })
    }

    /// Gather the requested vocab rows and dequantize them.
    pub fn embedding(&self, ids: &[i32]) -> Result<Array> {
        let indices = Array::from_slice(ids, &[ids.len() as i32]);
        let w = self.get("embed_tokens.weight")?.take_axis(&indices, 0)?;
        let scales = self.get("embed_tokens.scales")?.take_axis(&indices, 0)?;
        let biases = self.get("embed_tokens.biases")?.take_axis(&indices, 0)?;
        let dense = dequantize(
            &w,
            &scales,
            Some(&biases),
            DequantizeOptions {
                group_size: Some(self.group_size),
                bits: Some(self.bits),
                ..Default::default()
            },
        )?;
        Ok(dense.as_dtype(Dtype::Float32)?)
    }

    pub fn get(&self, name: &str) -> Result<&Array> {
        self.w
            .get(name)
            .with_context(|| format!("missing tensor {name}"))
    }

    /// Mirrors flux_klein_mlx.engine.Weights.linear:
    /// `scaled_input` says the activation is already divided by 256,
    /// `scaled_output` says the caller wants the scaled (not multiplied) result.
    pub fn linear(
        &self,
        name: &str,
        x: &Array,
        scaled_input: bool,
        scaled_output: bool,
    ) -> Result<Array> {
        let w = self.get(&format!("{name}.weight"))?;
        let scaled = is_scaled(name);
        let mut xin = x.clone();
        if scaled && !scaled_input {
            xin = xin
                .as_dtype(Dtype::Float32)?
                .divide(&Array::from_f32(256.0))?
                .as_dtype(Dtype::Float16)?;
        }
        let y = if let Some(scales) = self.w.get(&format!("{name}.scales")) {
            let biases = self.w.get(&format!("{name}.biases"));
            quantized_matmul(
                &xin,
                w,
                scales,
                biases,
                QuantizedMatmulOptions {
                    group_size: Some(self.group_size),
                    bits: Some(self.bits),
                    transpose: true,
                    ..Default::default()
                },
            )?
        } else {
            let wd = w.as_dtype(xin.dtype())?;
            xin.matmul(&wd.transpose_axes(&[1, 0])?)?
        };
        if scaled && !scaled_output {
            Ok(y.as_dtype(Dtype::Float32)?
                .multiply(&Array::from_f32(256.0))?)
        } else {
            Ok(y)
        }
    }


}
