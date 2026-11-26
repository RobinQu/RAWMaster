use anyhow::{bail, Result};
use std::path::Path;

pub enum Npy {
    F32(Vec<f32>, Vec<i32>),
    I64(Vec<i64>, Vec<i32>),
    Bool(Vec<bool>, Vec<i32>),
}

impl Npy {
    pub fn f32(&self) -> Result<(&[f32], &[i32])> {
        match self {
            Npy::F32(v, s) => Ok((v, s)),
            _ => bail!("expected f32 npy"),
        }
    }
    pub fn i64(&self) -> Result<(&[i64], &[i32])> {
        match self {
            Npy::I64(v, s) => Ok((v, s)),
            _ => bail!("expected i64 npy"),
        }
    }
    pub fn bool(&self) -> Result<(&[bool], &[i32])> {
        match self {
            Npy::Bool(v, s) => Ok((v, s)),
            _ => bail!("expected bool npy"),
        }
    }
}

pub fn load(path: &Path) -> Result<Npy> {
    let bytes = std::fs::read(path)?;
    if bytes.len() < 12 || &bytes[..6] != b"\x93NUMPY" {
        bail!("not a npy file: {}", path.display());
    }
    let major = bytes[6];
    let (header_start, header_len) = if major == 1 {
        (10usize, u16::from_le_bytes([bytes[8], bytes[9]]) as usize)
    } else {
        (
            12usize,
            u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]) as usize,
        )
    };
    let header = std::str::from_utf8(&bytes[header_start..header_start + header_len])?;
    let descr = header
        .split("'descr':")
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("npy descr missing"))?
        .split(',')
        .next()
        .unwrap()
        .trim()
        .trim_matches('\'')
        .trim();
    let shape_start = header
        .find("'shape':")
        .ok_or_else(|| anyhow::anyhow!("npy shape missing"))?
        + 8;
    let shape_end = header[shape_start..]
        .find(')')
        .ok_or_else(|| anyhow::anyhow!("npy shape end missing"))?
        + shape_start;
    let shape: Vec<i32> = header[shape_start..shape_end]
        .trim_matches(|c| c == '(' || c == ')' || c == ' ')
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().parse::<i32>())
        .collect::<std::result::Result<_, _>>()?;
    let data = &bytes[header_start + header_len..];
    match descr {
        "<f4" => {
            let mut values = Vec::with_capacity(data.len() / 4);
            for chunk in data.chunks_exact(4) {
                values.push(f32::from_le_bytes(chunk.try_into().unwrap()));
            }
            Ok(Npy::F32(values, shape))
        }
        "<i8" => {
            let mut values = Vec::with_capacity(data.len() / 8);
            for chunk in data.chunks_exact(8) {
                values.push(i64::from_le_bytes(chunk.try_into().unwrap()));
            }
            Ok(Npy::I64(values, shape))
        }
        "|b1" => Ok(Npy::Bool(
            data.iter().map(|&value| value != 0).collect(),
            shape,
        )),
        other => bail!("unsupported npy dtype {other}"),
    }
}

pub fn save_f32(path: &Path, values: &[f32], shape: &[i32]) -> Result<()> {
    let shape_str = shape
        .iter()
        .map(|v| v.to_string())
        .collect::<Vec<_>>()
        .join(", ");
    let mut header =
        format!("{{'descr': '<f4', 'fortran_order': False, 'shape': ({shape_str},), }}");
    let preamble = 10usize;
    let total = preamble + header.len() + 1;
    let padding = (64 - total % 64) % 64;
    header.push_str(&" ".repeat(padding));
    header.push('\n');
    let mut out = Vec::with_capacity(preamble + header.len() + values.len() * 4);
    out.extend_from_slice(b"\x93NUMPY");
    out.push(1);
    out.push(0);
    out.extend_from_slice(&(header.len() as u16).to_le_bytes());
    out.extend_from_slice(header.as_bytes());
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
    std::fs::write(path, out)?;
    Ok(())
}
