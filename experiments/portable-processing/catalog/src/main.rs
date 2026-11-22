//! A headless Rust host. One NDJSON request and one reply per line.
use rmq_probe::{response, Queue, Result};
use std::io::{self, BufRead, Write};
use std::path::Path;

fn main() -> Result<()> {
    let file = std::env::args_os()
        .nth(1)
        .ok_or("usage: rmq-probe DATABASE")?;
    let mut queue = Queue::open(Path::new(&file))?;
    let mut out = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let line = line?;
        let result = serde_json::from_str(&line)
            .map_err(Into::into)
            .and_then(|request| queue.request(request));
        writeln!(out, "{}", response(result))?;
        out.flush()?;
    }
    Ok(())
}
