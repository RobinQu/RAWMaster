//! Durable catalog intents and fenced worker leases. Pixel work is owned by the execution host.
pub mod batch;
mod external;
mod request;
use crate::{resources, Result};
pub use request::{Failure, Request};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub const SCHEMA: &str = include_str!("scheduler/schema.sql");
const LANES: [&str; 5] = ["editing", "export", "editing", "library", "editing"];
const MAX_MEMORY_MIB: u32 = 32768;

pub struct Queue {
    db: Connection,
    path: PathBuf,
}

fn now_ms() -> Result<i64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)?
        .as_millis()
        .try_into()?)
}

fn deadline(now: i64, lease: u32) -> Result<i64> {
    if !(5..=120_000).contains(&lease) {
        return Err("leaseMs must be in 5...120000".into());
    }
    Ok(now + i64::from(lease))
}

impl Queue {
    pub fn open(path: &Path) -> Result<Self> {
        let path = path.canonicalize()?;
        let db = Connection::open_with_flags(
            &path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch(
            "PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; \
             PRAGMA cache_size=-262144; PRAGMA temp_store=MEMORY;",
        )?;
        crate::require_scheduler_schema(&db)?;
        Ok(Self { db, path })
    }

    pub fn request(&mut self, request: Request) -> Result<Value> {
        use Request::*;
        match request {
            WorkbenchBatch { command } => return batch::execute(&mut self.db, &self.path, command),
            Capabilities => {
                return capabilities(&self.db);
            }
            Attempts { key } => {
                let mut stmt=self.db.prepare("SELECT a.attempt,a.state,a.started_at,a.finished_at,a.error FROM lc_task_attempts a
                    JOIN lc_task_jobs j ON j.id=a.job_id WHERE j.job_key=? ORDER BY a.attempt")?;
                let rows=stmt.query_map([key], |r| Ok(json!({"attempt":r.get::<_,i64>(0)?,"state":r.get::<_,String>(1)?,
                    "startedAt":r.get::<_,i64>(2)?,"finishedAt":r.get::<_,Option<i64>>(3)?,"error":r.get::<_,Option<String>>(4)?})))?;
                return Ok(Value::Array(rows.collect::<rusqlite::Result<_>>()?));
            }
            Check { key, token } => return check(&self.db, &key, &token),
            PrepareExternal {
                key,
                token,
                stage,
                destination,
            } => {
                return external::prepare(
                    &mut self.db,
                    &key,
                    &token,
                    Path::new(&stage),
                    Path::new(&destination),
                );
            }
            PreparedExternal { key } => return external::prepared(&self.db, &key),
            PreparedExternalTasks {
                lane,
                key_prefix,
                after,
                limit,
            } => {
                return external::pending(&self.db, &lane, &key_prefix, after.as_deref(), limit);
            }
            VerifyPrepared { key, destination } => {
                return external::verify(&self.db, &key, destination, false)
            }
            VerifyExternalDelivery { key } => return external::verify(&self.db, &key, true, true),
            FinishExternalDelivery { key, token } => {
                return external::finish(&mut self.db, &key, &token)
            }
            Status { key } => return status(&self.db, &key),
            Statuses { keys } => {
                if keys.len() > 256 {
                    return Err("status page exceeds 256 keys".into());
                }
                let keys: Vec<_> = keys.iter().map(String::as_str).collect();
                return Ok(Value::Array(statuses(&self.db, &keys)?));
            }
            Complete {
                key,
                token,
                result,
                file,
            } => return self.complete(&key, &token, &result, file.as_deref().map(Path::new)),
            _ => (),
        }
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let now = now_ms()?;
        let output = match request {
            Configure {
                cpu,
                gpu,
                io,
                memory_mib,
            } => {
                tx.execute("UPDATE lc_task_scheduler SET cpu_slots=?1,gpu_slots=?2,io_slots=?3,memory_mib=?4 WHERE id=1",
                    params![cpu,gpu,io,memory_mib])?;
                capabilities(&tx)?
            }
            Reconcile {
                key,
                result,
                safe_to_resubmit,
            } => {
                if result.as_ref().is_some_and(|v| v.is_empty())
                    || (result.is_some() == safe_to_resubmit)
                {
                    return Err("reconcile requires either the verified receipt or confirmation that no effect occurred".into());
                }
                expire(&tx, now)?;
                if result.is_some() {
                    external::require_final_receipt(&tx, &key)?;
                } else {
                    external::require_local(&tx, &key)?;
                }
                let next = if result.is_some() { "done" } else { "queued" };
                let recorded = status(&tx, &key)?;
                if recorded["state"] == "done"
                    && result
                        .as_deref()
                        .is_some_and(|receipt| recorded["result"] == receipt)
                {
                    tx.commit()?;
                    return Ok(recorded);
                }
                changed(tx.execute("UPDATE lc_task_jobs SET state=CASE WHEN ?2='queued' AND attempt>=max_attempts THEN 'failed' ELSE ?2 END,
                    result=?3,token=NULL,lease_until=NULL,available_at=0 WHERE job_key=?1 AND state='reconcile'",params![key,next,result])?)?;
                status(&tx, &key)?
            }
            Submit {
                key,
                lane,
                resource,
                payload,
                memory_mib,
                max_attempts,
                replay_safe,
                claim_lease_ms,
            } => {
                let until = claim_lease_ms.map(|ms| deadline(now, ms)).transpose()?;
                if key.trim().is_empty()
                    || !LANES.contains(&lane.as_str())
                    || !["cpu", "gpu", "io"].contains(&resource.as_str())
                    || !(1..=MAX_MEMORY_MIB).contains(&memory_mib)
                    || !(1..=8).contains(&max_attempts)
                {
                    return Err("invalid job, lane, resource, memoryMiB or maxAttempts".into());
                }
                if let Some(expected) = payload.get("libraryID") {
                    let id: String =
                        tx.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
                            r.get(0)
                        })?;
                    if expected.as_str() != Some(id.as_str()) {
                        return Err("job descriptor belongs to another catalog".into());
                    }
                }
                let encoded = payload.to_string();
                let args = params![
                    key,
                    lane,
                    resource,
                    encoded,
                    memory_mib,
                    max_attempts,
                    replay_safe
                ];
                let added = tx.execute("INSERT INTO lc_task_jobs(job_key,lane,resource,payload,memory_mib,max_attempts,replay_safe)
                    VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(job_key) DO NOTHING", args)?;
                if added == 0 {
                    let matches: bool = tx.query_row("SELECT lane=?2 AND resource=?3 AND payload=?4 AND
                        memory_mib=?5 AND max_attempts=?6 AND replay_safe=?7 FROM lc_task_jobs WHERE job_key=?1",
                        args, |r| r.get(0))?;
                    if !matches {
                        return Err("idempotency key has a different descriptor".into());
                    }
                }
                if let Some(until) = until {
                    let mut row =
                        claim_or_status(&tx, now, until, Some(&key), Some(&resource), true)?;
                    row["inserted"] = Value::Bool(added == 1);
                    if added == 1 && row["state"] == "queued" {
                        // Only this caller created the still-unclaimed intent. Readers and duplicate
                        // submitters must never be able to withdraw it while its creator is waiting.
                        let proof = Uuid::new_v4().to_string();
                        tx.execute(
                            "UPDATE lc_task_jobs SET submission_token=?2 WHERE job_key=?1",
                            params![key, proof],
                        )?;
                        row["submissionToken"] = proof.into();
                    }
                    row
                } else {
                    status(&tx, &key)?
                }
            }
            Claim {
                key,
                resource,
                lease_ms,
                include_status,
            } => {
                if resource
                    .as_deref()
                    .is_some_and(|v| !["cpu", "gpu", "io"].contains(&v))
                {
                    return Err("invalid claimant resource".into());
                }
                claim_or_status(
                    &tx,
                    now,
                    deadline(now, lease_ms)?,
                    key.as_deref(),
                    resource.as_deref(),
                    include_status,
                )?
            }
            CancelIfQueued {
                key,
                submission_token,
                attempt,
            } => {
                tx.execute("UPDATE lc_task_jobs SET state='cancelled',submission_token=NULL,claim_interest_until=0
                   WHERE job_key=?1 AND submission_token=?2 AND state='queued' AND attempt=?3", params![key,submission_token,attempt])?;
                status(&tx, &key)?
            }
            Cancel { key, token } => {
                if let Some(token) = token {
                    check(&tx, &key, &token)?;
                }
                tx.execute("UPDATE lc_task_jobs SET state=CASE WHEN state='running' THEN 'cancelling' ELSE 'cancelled' END
                    WHERE job_key=? AND state IN ('queued','waiting','running')", [&key])?;
                status(&tx, &key)?
            }
            Wake { key } => {
                changed(tx.execute("UPDATE lc_task_jobs SET state=CASE WHEN attempt>=max_attempts THEN 'failed' ELSE 'queued' END,available_at=0
                    WHERE job_key=? AND state='waiting'", [&key])?)?;
                status(&tx, &key)?
            }
            AbandonUnstarted { key, token } => {
                // The owner was cancelled between preclaim and entry into its worker. No external operation
                // began for this generation. A pre-existing preparation still requires reconciliation.
                changed(tx.execute("UPDATE lc_task_jobs SET state=CASE WHEN prepared_stage IS NULL THEN 'cancelled' ELSE 'reconcile' END,
                    token=NULL,lease_until=NULL WHERE job_key=?1 AND token=?2 AND state IN ('running','cancelling') AND lease_until>?3",
                    params![key,token,now])?)?;
                status(&tx, &key)?
            }
            AckCancel { key, token } => {
                changed(tx.execute(
                    "UPDATE lc_task_jobs SET state=CASE WHEN prepared_stage IS NULL THEN 'cancelled' ELSE 'reconcile' END,lease_until=NULL,token=NULL
                    WHERE job_key=?1 AND token=?2 AND state='cancelling' AND lease_until>?3",
                    params![key, token, now],
                )?)?;
                status(&tx, &key)?
            }
            Heartbeat {
                key,
                token,
                lease_ms,
            } => {
                let until = deadline(now, lease_ms)?;
                changed(tx.execute(
                    "UPDATE lc_task_jobs SET lease_until=?4 WHERE job_key=?1 AND token=?2
                    AND state='running' AND lease_until>?3",
                    params![key, token, now, until],
                )?)?;
                status(&tx, &key)?
            }
            Fail {
                key,
                token,
                class,
                error,
                own_retry,
            } => {
                let uncertain = matches!(class, Failure::Uncertain);
                let occupied = matches!(class, Failure::DestinationOccupied);
                let (safe, attempt, limit, prepared): (bool, u32, u32, bool) = tx.query_row(
                    "SELECT replay_safe,attempt,max_attempts,prepared_stage IS NOT NULL FROM lc_task_jobs WHERE job_key=?1 AND token=?2
                     AND (state='running' OR (state='cancelling' AND ?4)) AND lease_until>?3", params![key, token, now, uncertain || occupied],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
                let state = match class {
                    Failure::DestinationOccupied => "failed",
                    _ if prepared => "reconcile",
                    Failure::Permanent => "failed",
                    Failure::Uncertain => "reconcile",
                    // Offline means the executor confirmed no external side effect.
                    Failure::Offline => "waiting",
                    Failure::Transient if !safe => "reconcile",
                    Failure::Transient if attempt >= limit => "failed",
                    Failure::Transient => "queued",
                };
                let retry_at = now + (250_i64 << (attempt - 1).min(7));
                let retry_token =
                    (own_retry && state == "queued").then(|| Uuid::new_v4().to_string());
                tx.execute("UPDATE lc_task_jobs SET state=?2,available_at=?3,last_error=?4,token=NULL,lease_until=NULL,
                    prepared_detached=CASE WHEN ?5 AND prepared_stage IS NOT NULL THEN 1 ELSE prepared_detached END,submission_token=?6
                    WHERE job_key=?1", params![key, state, retry_at, error, occupied, retry_token])?;
                let mut row = status(&tx, &key)?;
                if let Some(token) = retry_token {
                    row["submissionToken"] = token.into();
                }
                row
            }
            WorkbenchBatch { .. }
            | Capabilities
            | PreparedExternalTasks { .. }
            | VerifyPrepared { .. }
            | VerifyExternalDelivery { .. }
            | FinishExternalDelivery { .. }
            | PreparedExternal { .. }
            | PrepareExternal { .. }
            | Check { .. }
            | Attempts { .. }
            | Status { .. }
            | Statuses { .. }
            | Complete { .. } => {
                unreachable!()
            }
        };
        tx.commit()?;
        Ok(output)
    }

    fn complete(
        &mut self,
        key: &str,
        token: &str,
        result: &str,
        file: Option<&Path>,
    ) -> Result<Value> {
        if result.is_empty() {
            return Err("missing result".into());
        }
        // A lost acknowledgement can be replayed after removal of the worker's temporary file.
        if receipt(&self.db, key, token, result, file.is_some())? {
            return status(&self.db, key);
        }
        if !owns_job(&self.db, key, token, now_ms()?)? {
            return Err("stale or cancelled lease".into());
        }
        let resource = file
            .map(|p| {
                resources::stage(
                    &self.path,
                    p,
                    &format!("scheduler:{}", hex::encode(Sha256::digest(key.as_bytes()))),
                    "recipeResource",
                    None,
                )
            })
            .transpose()?;
        if resource.as_ref().is_some_and(|r| r.sha256 != result) {
            return Err("artifact SHA-256 mismatch".into());
        }
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if !receipt(&tx, key, token, result, file.is_some())? {
            external::require_final_receipt(&tx, key)?;
            changed(tx.execute(
                "UPDATE lc_task_jobs SET state='done',result=?4,lease_until=NULL
                WHERE job_key=?1 AND token=?2 AND state='running' AND lease_until>?3",
                params![key, token, now_ms()?, result],
            )?)?;
            if let Some(r) = &resource {
                resources::register(&tx, r)?;
                tx.execute(
                    "UPDATE lc_task_jobs SET resource_id=?2 WHERE job_key=?1",
                    params![key, r.resource_id],
                )?;
            }
        }
        let value = status(&tx, key)?;
        tx.commit()?;
        Ok(value)
    }
}

fn receipt(db: &Connection, key: &str, token: &str, result: &str, has_file: bool) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_task_jobs WHERE job_key=?1 AND token=?2 AND result=?3
        AND (resource_id IS NOT NULL)=?4 AND state='done')",
        params![key, token, result, has_file],
        |r| r.get(0),
    )?)
}

fn owns_job(db: &Connection, key: &str, token: &str, now: i64) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_task_jobs WHERE job_key=?1 AND token=?2 AND state='running'
        AND lease_until>?3)",
        params![key, token, now],
        |r| r.get(0),
    )?)
}

pub(crate) fn check(db: &Connection, key: &str, token: &str) -> Result<Value> {
    if !owns_job(db, key, token, now_ms()?)? {
        return Err("Task lease expired, cancelled or replaced".into());
    }
    Ok(Value::Bool(true))
}

/// Called inside the host write transaction *after* the domain's publication changes.
/// An error must roll back both domain changes and the scheduler receipt together.
pub(crate) fn finish_receipt(
    db: &Connection,
    key: &str,
    token: &str,
    result: &str,
) -> Result<Value> {
    if result.is_empty() {
        return Err("missing authoritative receipt".into());
    }
    external::require_final_receipt(db, key)?;
    changed(db.execute("UPDATE lc_task_jobs SET state='done',result=?4,lease_until=NULL WHERE job_key=?1 AND token=?2
                AND state='running' AND lease_until>?3",params![key,token,now_ms()?,result])?)?;
    Ok(Value::Bool(true))
}

pub(crate) fn for_receipt(db: &Connection, key: &str) -> Result<Value> {
    Ok(statuses(db, &[key])?.pop().unwrap_or(Value::Null))
}

/// The host has verified an existing domain receipt against the frozen descriptor under this write lock.
/// Invalidate outstanding tokens including live ones: their result has already been published by the domain.
pub(crate) fn complete_verified(db: &Connection, key: &str, result: &str) -> Result<Value> {
    if result.is_empty() {
        return Err("missing verified domain receipt".into());
    }
    external::require_final_receipt(db, key)?;
    let row = status(db, key)?;
    if row["state"] == "done" {
        if row["result"] != result {
            return Err("verified domain receipt conflicts with the existing result".into());
        }
    } else {
        changed(db.execute("UPDATE lc_task_jobs SET state='done',result=?2,lease_until=NULL,token=NULL,last_error=NULL
                          WHERE job_key=?1",params![key,result])?)?;
    }
    Ok(Value::Bool(true))
}

fn changed(count: usize) -> Result<()> {
    if count != 1 {
        return Err("ineligible state or stale lease".into());
    }
    Ok(())
}

fn status(db: &Connection, key: &str) -> Result<Value> {
    statuses(db, &[key])?
        .pop()
        .filter(|row| !row.is_null())
        .ok_or_else(|| "unknown job".into())
}

fn statuses(db: &Connection, keys: &[&str]) -> Result<Vec<Value>> {
    let mut q = db.prepare_cached("SELECT CASE WHEN j.id IS NULL THEN 'null' ELSE json_object(
        'key',j.job_key,'lane',j.lane,'resource',j.resource,'payload',json(j.payload),
        'memoryMiB',j.memory_mib,'state',j.state,'attempt',j.attempt,'lastError',j.last_error,
        'result',j.result,'resourceID',j.resource_id,'availableAtMs',j.available_at,'leaseUntilMs',j.lease_until,
        'fitsConfiguredBudget',json(CASE WHEN j.memory_mib<=s.memory_mib AND (j.resource!='gpu' OR s.gpu_slots>0) THEN 'true' ELSE 'false' END))
        END FROM json_each(?1) AS requested LEFT JOIN lc_task_jobs j ON j.job_key=requested.value
        CROSS JOIN lc_task_scheduler s WHERE s.id=1 ORDER BY requested.key")?;
    let rows = q.query_map([serde_json::to_string(keys)?], |r| r.get::<_, String>(0))?;
    rows.map(|s| Ok(serde_json::from_str(&s?)?)).collect()
}

fn capabilities(db: &Connection) -> Result<Value> {
    Ok(db.query_row("SELECT cpu_slots,gpu_slots,io_slots,memory_mib FROM lc_task_scheduler WHERE id=1",[],|r|
        Ok(json!({"queueSchema":1,"catalogSchema":crate::CATALOG_SCHEMA_VERSION,"lanes":LANES,"cpu":r.get::<_,u32>(0)?,
            "gpu":r.get::<_,u32>(1)?,"io":r.get::<_,u32>(2)?,"memoryMiB":r.get::<_,u32>(3)?})))?)
}

pub fn execute(catalog: &Path, request: &Value) -> Result<Value> {
    let request = serde_json::from_value(request.clone())?;
    Queue::open(catalog)?.request(request)
}

/// A package restore creates an independent writer. Its live workers and private stages were never packaged.
pub(crate) fn detach_restored_workers(db: &Connection) -> Result<()> {
    let version = db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))?;
    if version < 9 {
        return Ok(());
    }
    db.execute_batch("UPDATE lc_task_jobs SET claim_interest_until=0,submission_token=NULL WHERE claim_interest_until!=0 OR submission_token IS NOT NULL;
        UPDATE lc_task_jobs SET state=CASE WHEN prepared_stage IS NOT NULL OR replay_safe=0 THEN 'reconcile'
            WHEN state='cancelling' THEN 'cancelled' WHEN attempt>=max_attempts THEN 'failed' ELSE 'queued' END,
            token=NULL,lease_until=NULL,last_error='original worker belongs to a different library'
            WHERE state IN ('running','cancelling');
        UPDATE lc_task_jobs SET prepared_detached=1,state=CASE WHEN state='done' THEN state ELSE 'reconcile' END
            WHERE prepared_stage IS NOT NULL;
        UPDATE lc_task_jobs SET state='reconcile',last_error='external destination belongs to the original library'
            WHERE prepared_stage IS NULL AND state IN ('queued','waiting') AND json_type(payload,'$.destination')='text';
        UPDATE lc_proc_attempts SET state='interrupted',diagnostic='Original rendering worker was not included in the package'
            WHERE state IN ('preparing','rendering');
        UPDATE lc_proc_jobs SET state='queued',lease_until=NULL,token=NULL WHERE state IN ('preparing','rendering');
        UPDATE lc_discover_jobs SET state='queued',lease=NULL,lease_until=NULL WHERE state='running'")?;
    Ok(())
}

fn expire(tx: &Transaction<'_>, now: i64) -> Result<()> {
    tx.execute("UPDATE lc_task_jobs SET state=CASE WHEN replay_safe=0 OR prepared_stage IS NOT NULL THEN 'reconcile'
        WHEN state='cancelling' THEN 'cancelled' WHEN attempt>=max_attempts THEN 'failed' ELSE 'queued' END,
        token=NULL,lease_until=NULL,last_error='lease expired' WHERE state IN ('running','cancelling') AND lease_until<=?",
        [now])?;
    Ok(())
}

fn claim_or_status(
    tx: &Transaction<'_>,
    now: i64,
    until: i64,
    key: Option<&str>,
    resource: Option<&str>,
    include_status: bool,
) -> Result<Value> {
    if include_status && key.is_none() {
        return Err("a targeted claim is required to return job status".into());
    }
    let granted = claim(tx, now, until, key, resource)?;
    if granted.is_null() && include_status {
        return status(tx, key.ok_or("missing status key")?);
    }
    Ok(granted)
}

fn claim(
    tx: &Transaction<'_>,
    now: i64,
    until: i64,
    key: Option<&str>,
    resource: Option<&str>,
) -> Result<Value> {
    expire(tx, now)?;
    // Swift callers own closures for specific jobs. Rotate among live, polling claimants so a race of
    // targeted claims still observes lane weights. A stopped caller cannot hold up a claimable job forever.
    let target_resource = if let Some(key) = key {
        let target: Option<String> = tx
            .query_row(
                "SELECT resource FROM lc_task_jobs WHERE job_key=?1
            AND state='queued' AND available_at<=?2",
                params![key, now],
                |r| r.get(0),
            )
            .optional()?;
        let Some(target) = target else {
            return Ok(Value::Null);
        };
        if resource.is_some_and(|r| r != target) {
            return Ok(Value::Null);
        }
        tx.execute("UPDATE lc_task_jobs SET claim_interest_until=?2 WHERE job_key=?1 AND claim_interest_until<?3",
            params![key,now+1000,now+500])?;
        Some(target)
    } else {
        None
    };
    let resource = target_resource.as_deref().or(resource);
    let start: u8 = tx.query_row(
        "SELECT next_slot FROM lc_task_scheduler WHERE id=1",
        [],
        |r| r.get(0),
    )?;
    let mut candidates = tx.prepare_cached("WITH used AS (
        SELECT COALESCE(SUM(memory_mib),0) AS memory, COUNT(*) FILTER(WHERE resource='cpu') AS cpu,
               COUNT(*) FILTER(WHERE resource='gpu') AS gpu, COUNT(*) FILTER(WHERE resource='io') AS io
        FROM lc_task_jobs WHERE state IN ('running','cancelling'))
        SELECT job_key FROM lc_task_jobs,used,lc_task_scheduler s WHERE lc_task_jobs.state='queued' AND lc_task_jobs.lane=?1 AND lc_task_jobs.available_at<=?2 AND s.id=1 AND (?3=0 OR lc_task_jobs.claim_interest_until>?2) AND (?4 IS NULL OR lc_task_jobs.resource=?4)
            AND lc_task_jobs.memory_mib+used.memory<=s.memory_mib
            AND (resource='cpu' AND used.cpu<s.cpu_slots OR resource='gpu' AND used.gpu<s.gpu_slots OR resource='io' AND used.io<s.io_slots)
        ORDER BY lc_task_jobs.id LIMIT 1")?;
    for offset in 0..LANES.len() {
        let slot = (usize::from(start) + offset) % LANES.len();
        let candidate: Option<String> = candidates
            .query_row(params![LANES[slot], now, key.is_some(), resource], |r| {
                r.get(0)
            })
            .optional()?;
        if let Some(candidate) = candidate {
            if key.is_some_and(|requested| requested != candidate) {
                return Ok(Value::Null);
            }
            let key = candidate;
            let token = Uuid::new_v4().to_string();
            tx.execute("UPDATE lc_task_jobs SET state='running',attempt=attempt+1,token=?2,lease_until=?3,last_error=NULL,claim_interest_until=0,submission_token=NULL WHERE job_key=?1",
                params![key, token, until])?;
            tx.execute(
                "UPDATE lc_task_scheduler SET next_slot=? WHERE id=1",
                [((slot + 1) % LANES.len()) as u8],
            )?;
            let mut result = status(tx, &key)?;
            result["token"] = token.into();
            return Ok(result);
        }
    }
    Ok(Value::Null)
}
