use anyhow::Result;
use std::path::Path;
use tokenizers::{Tokenizer, TruncationParams};

pub struct PromptTokens {
    pub ids: Vec<u32>,
    pub positions: Vec<i32>,
    pub valid: Vec<bool>,
}

pub fn encode(model_root: &Path, prompt: &str) -> Result<PromptTokens> {
    let mut tokenizer = Tokenizer::from_file(model_root.join("assets/tokenizer.json"))
        .map_err(|e| anyhow::anyhow!("tokenizer: {e}"))?;
    tokenizer
        .with_truncation(Some(TruncationParams {
            max_length: 4096,
            ..Default::default()
        }))
        .map_err(|e| anyhow::anyhow!("truncation: {e}"))?;
    let text = format!("<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n");
    let encoding = tokenizer
        .encode(text, true)
        .map_err(|e| anyhow::anyhow!("encode: {e}"))?;
    let mut ids = encoding.get_ids().to_vec();
    let raw_len = ids.len().min(4096);
    let length = (((raw_len + 79) / 80) * 80).min(4096);
    let valid: Vec<bool> = (0..length).map(|i| i < raw_len).collect();
    let positions: Vec<i32> = (0..length)
        .map(|i| if i < raw_len { i as i32 } else { 1 })
        .collect();
    ids.resize(length, 151643);
    Ok(PromptTokens {
        ids,
        positions,
        valid,
    })
}
