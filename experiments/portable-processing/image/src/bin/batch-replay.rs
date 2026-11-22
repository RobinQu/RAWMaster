//! Replay the Swift-ingress fixtures in a headless process. One graph, one compiled plan,
//! per-image mask/extent and output identity. Use a new output directory for each experiment.
use rawmaster_image_poc::{render_cpu, Frame, Pixel, Plan};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    io::{Error, ErrorKind},
    path::Path,
};

#[derive(Deserialize)]
struct Record {
    #[serde(rename = "sourceSHA256")]
    source: String,
    #[serde(rename = "graphSHA256")]
    graph: String,
    #[serde(rename = "inputRGBASHA256")]
    input: String,
    #[serde(rename = "inputCoverageSHA256")]
    mask: String,
    #[serde(rename = "cpuRGBA32FLESHA256")]
    expected: String,
    #[serde(rename = "renderExtent")]
    extent: [u32; 2],
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn plane(path: &Path, bytes: usize, expected: &str) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    if fs::metadata(path)?.len() != bytes as u64 {
        return Err(format!("wrong length for {}", path.display()).into());
    }
    let data = fs::read(path)?;
    if hash(&data) != expected {
        return Err(format!("digest mismatch for {}", path.display()).into());
    }
    Ok(data)
}
fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() < 3 {
        return Err("usage: batch-replay GRAPH.json NEW_OUTPUT_DIR RECEIPT_DIR ...".into());
    }
    if cfg!(target_endian = "big") {
        return Err("this experiment emits native little-endian f32".into());
    }
    let recipe = fs::read_to_string(&args[0])?;
    let plan = Plan::parse(&recipe)?;
    let graph = hash(recipe.as_bytes());
    let out = Path::new(&args[1]);
    fs::create_dir(out)?;
    let mut items = Vec::new();
    for (index, dir) in args[2..].iter().enumerate() {
        let dir = Path::new(dir);
        let r: Record = serde_json::from_slice(&fs::read(dir.join("worker.json"))?)?;
        let [w, h] = r.extent;
        let n = w
            .checked_mul(h)
            .filter(|&n| n > 0 && n <= 64_000_000)
            .ok_or("invalid extent")? as usize;
        if graph != r.graph {
            return Err("input bound to a different recipe".into());
        }
        let raw = plane(&dir.join("input.rgba32fle"), n * 16, &r.input)?;
        let pixels: Vec<Pixel> = raw
            .as_chunks::<16>()
            .0
            .iter()
            .copied()
            .map(bytemuck::cast)
            .collect();
        drop(raw);
        let raw = plane(&dir.join("mask.r32fle"), n * 4, &r.mask)?;
        let mask: Vec<f32> = raw
            .as_chunks::<4>()
            .0
            .iter()
            .copied()
            .map(f32::from_le_bytes)
            .collect();
        drop(raw);
        let output = render_cpu(&plan, &Frame::new(w, h, &pixels, &mask)?)?;
        let bytes = bytemuck::cast_slice(&output);
        let actual = hash(bytes);
        if actual != r.expected {
            return Err(Error::new(
                ErrorKind::InvalidData,
                format!("CPU reference mismatch at item {index}: {actual}"),
            )
            .into());
        }
        let filename = format!("item-{index}.rgba32fle");
        let temporary = out.join(format!("item-{index}.part"));
        if let Err(error) =
            fs::write(&temporary, bytes).and_then(|()| fs::rename(&temporary, out.join(&filename)))
        {
            let _ = fs::remove_file(temporary);
            return Err(error.into());
        }
        items.push(json!({"item":index,"sourceSHA256":r.source,"extent":r.extent,"sha256":actual,"bytes":bytes.len(),"output":filename}));
    }
    let summary =
        json!({"backend":"Rust/C++ CPU","compiled_plans":1,"graphSHA256":graph,"items":items});
    println!("{}", serde_json::to_string_pretty(&summary)?);
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
