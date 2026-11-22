//! Experiment on the existing Rust catalog's SQLite and content-addressed storage.
//! Use a new temporary database. No Swift, Apple frameworks or image engine are required.
mod ffi;
mod queue;

pub use queue::Queue;
pub use rawmaster_library::Result;

use serde::Deserialize;
use serde_json::Value;

fn default_memory() -> u32 {
    64
}
fn default_attempts() -> u8 {
    3
}
fn default_safe() -> bool {
    true
}
fn default_lease() -> u32 {
    30_000
}

#[derive(Deserialize)]
#[serde(
    tag = "op",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Request {
    Capabilities,
    Submit {
        key: String,
        lane: String,
        resource: String,
        payload: Value,
        #[serde(default = "default_memory", rename = "memoryMiB")]
        memory_mib: u32,
        #[serde(default = "default_attempts")]
        max_attempts: u8,
        #[serde(default = "default_safe")]
        replay_safe: bool,
    },
    Claim {
        #[serde(default = "default_lease")]
        lease_ms: u32,
    },
    Status {
        key: String,
    },
    Statuses {
        keys: Vec<String>,
    },
    Heartbeat {
        key: String,
        token: String,
        #[serde(default = "default_lease")]
        lease_ms: u32,
    },
    Cancel {
        key: String,
    },
    AckCancel {
        key: String,
        token: String,
    },
    Wake {
        key: String,
    },
    Fail {
        key: String,
        token: String,
        class: Failure,
        error: String,
    },
    Complete {
        key: String,
        token: String,
        result: String,
        file: Option<String>,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Failure {
    Transient,
    Permanent,
    Uncertain,
    Offline,
}

pub fn response(result: Result<Value>) -> Value {
    match result {
        Ok(value) => serde_json::json!({"ok": true, "value": value}),
        Err(error) => serde_json::json!({"ok": false, "error": error.to_string()}),
    }
}
