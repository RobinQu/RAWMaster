use serde::Deserialize;
use serde_json::Value;

fn default_memory() -> u32 {
    64
}
fn default_attempts() -> u8 {
    3
}
fn default_safe() -> bool {
    false
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
    WorkbenchBatch {
        command: super::batch::Command,
    },
    Capabilities,
    Configure {
        cpu: u32,
        gpu: u32,
        io: u32,
        #[serde(rename = "memoryMiB")]
        memory_mib: u32,
    },
    Check {
        key: String,
        token: String,
    },
    PrepareExternal {
        key: String,
        token: String,
        stage: String,
        destination: String,
    },
    PreparedExternalTasks {
        lane: String,
        key_prefix: String,
        after: Option<String>,
        limit: u32,
    },
    VerifyPrepared {
        key: String,
        destination: bool,
    },
    VerifyExternalDelivery {
        key: String,
    },
    FinishExternalDelivery {
        key: String,
        token: String,
    },
    PreparedExternal {
        key: String,
    },
    Attempts {
        key: String,
    },
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
        claim_lease_ms: Option<u32>,
    },
    Claim {
        key: Option<String>,
        resource: Option<String>,
        #[serde(default = "default_lease")]
        lease_ms: u32,
        #[serde(default)]
        include_status: bool,
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
        token: Option<String>,
    },
    CancelIfQueued {
        key: String,
        submission_token: String,
        #[serde(default)]
        attempt: u32,
    },
    AckCancel {
        key: String,
        token: String,
    },
    AbandonUnstarted {
        key: String,
        token: String,
    },
    Reconcile {
        key: String,
        result: Option<String>,
        safe_to_resubmit: bool,
    },
    Wake {
        key: String,
    },
    Fail {
        key: String,
        token: String,
        class: Failure,
        error: String,
        #[serde(default)]
        own_retry: bool,
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
    DestinationOccupied,
    Uncertain,
    Offline,
}
