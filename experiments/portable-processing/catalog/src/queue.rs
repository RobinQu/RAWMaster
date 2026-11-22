use crate::{Failure, Request, Result};
use rawmaster_library::resources;
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const APP_ID: i32 = 0x524D5131; // RMQ1
const LANES: [&str; 5] = ["editing", "export", "editing", "library", "editing"];
const MEMORY_MIB: u32 = 512;

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
        let mut db = Connection::open(path)?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;")?;
        let app_id =
            |db: &Connection| db.query_row("PRAGMA application_id", [], |r| r.get::<_, i32>(0));
        if app_id(&db)? != APP_ID {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if app_id(&tx)? != APP_ID {
                let occupied: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM sqlite_schema) OR
                     (SELECT application_id FROM pragma_application_id)<>0 OR
                     (SELECT user_version FROM pragma_user_version)<>0",
                    [],
                    |r| r.get(0),
                )?;
                if occupied {
                    return Err("expected an empty experiment database".into());
                }
                resources::install(&tx)?;
                tx.execute_batch(include_str!("schema.sql"))?;
                tx.pragma_update(None, "application_id", APP_ID)?;
                tx.pragma_update(None, "user_version", 1)?;
            }
            tx.commit()?;
        }
        let version: i32 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version != 1 {
            return Err("unsupported experiment schema".into());
        }
        let mode: String = db.query_row("PRAGMA journal_mode", [], |r| r.get(0))?;
        if mode != "wal" {
            let mode: String = db.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))?;
            if mode != "wal" {
                return Err("WAL is required for this experiment".into());
            }
        }
        Ok(Self {
            db,
            path: path.canonicalize()?,
        })
    }

    pub fn request(&mut self, request: Request) -> Result<Value> {
        use Request::*;
        match request {
            Capabilities => {
                let sqlite: String = self
                    .db
                    .query_row("SELECT sqlite_version()", [], |r| r.get(0))?;
                let journal: String = self.db.query_row("PRAGMA journal_mode", [], |r| r.get(0))?;
                let sync: u8 = self.db.query_row("PRAGMA synchronous", [], |r| r.get(0))?;
                return Ok(
                    json!({"queueSchema": 1, "catalogSchema": rawmaster_library::CATALOG_SCHEMA_VERSION,
                                 "sqlite": sqlite, "journal": journal, "synchronous": sync,
                                 "lanes": LANES, "cpu": 2, "gpu": 1, "io": 1, "memoryMiB": MEMORY_MIB}),
                );
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
            Submit {
                key,
                lane,
                resource,
                payload,
                memory_mib,
                max_attempts,
                replay_safe,
            } => {
                if key.trim().is_empty()
                    || !LANES.contains(&lane.as_str())
                    || !["cpu", "gpu", "io"].contains(&resource.as_str())
                    || !(1..=MEMORY_MIB).contains(&memory_mib)
                    || !(1..=8).contains(&max_attempts)
                {
                    return Err("invalid job, lane, resource, memoryMiB or maxAttempts".into());
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
                let added = tx.execute("INSERT INTO jobs(job_key,lane,resource,payload,memory_mib,max_attempts,replay_safe)
                    VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(job_key) DO NOTHING", args)?;
                if added == 0 {
                    let matches: bool = tx.query_row("SELECT lane=?2 AND resource=?3 AND payload=?4 AND
                        memory_mib=?5 AND max_attempts=?6 AND replay_safe=?7 FROM jobs WHERE job_key=?1",
                        args, |r| r.get(0))?;
                    if !matches {
                        return Err("idempotency key has a different descriptor".into());
                    }
                }
                status(&tx, &key)?
            }
            Claim { lease_ms } => claim(&tx, now, deadline(now, lease_ms)?)?,
            Cancel { key } => {
                tx.execute("UPDATE jobs SET state=CASE WHEN state='running' THEN 'cancelling' ELSE 'cancelled' END
                    WHERE job_key=? AND state IN ('queued','waiting','running')", [&key])?;
                status(&tx, &key)?
            }
            Wake { key } => {
                changed(tx.execute("UPDATE jobs SET state=CASE WHEN attempt>=max_attempts THEN 'failed' ELSE 'queued' END,available_at=0
                    WHERE job_key=? AND state='waiting'", [&key])?)?;
                status(&tx, &key)?
            }
            AckCancel { key, token } => {
                changed(tx.execute(
                    "UPDATE jobs SET state='cancelled',lease_until=NULL,token=NULL
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
                    "UPDATE jobs SET lease_until=?4 WHERE job_key=?1 AND token=?2
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
            } => {
                let (safe, attempt, limit): (bool, u32, u32) = tx.query_row(
                    "SELECT replay_safe,attempt,max_attempts FROM jobs WHERE job_key=?1 AND token=?2
                     AND state='running' AND lease_until>?3", params![key, token, now],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
                let state = match class {
                    Failure::Permanent => "failed",
                    Failure::Uncertain => "reconcile",
                    // Offline means the executor confirmed no external side effect.
                    Failure::Offline => "waiting",
                    Failure::Transient if !safe => "reconcile",
                    Failure::Transient if attempt >= limit => "failed",
                    Failure::Transient => "queued",
                };
                let retry_at = now + (250_i64 << (attempt - 1).min(7));
                tx.execute("UPDATE jobs SET state=?2,available_at=?3,last_error=?4,token=NULL,lease_until=NULL
                    WHERE job_key=?1", params![key, state, retry_at, error])?;
                status(&tx, &key)?
            }
            Capabilities | Status { .. } | Statuses { .. } | Complete { .. } => unreachable!(),
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
            .map(|p| resources::stage(&self.path, p, &format!("job:{key}"), "derivedPhoto", None))
            .transpose()?;
        if resource.as_ref().is_some_and(|r| r.sha256 != result) {
            return Err("artifact SHA-256 mismatch".into());
        }
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if !receipt(&tx, key, token, result, file.is_some())? {
            changed(tx.execute(
                "UPDATE jobs SET state='done',result=?4,lease_until=NULL
                WHERE job_key=?1 AND token=?2 AND state='running' AND lease_until>?3",
                params![key, token, now_ms()?, result],
            )?)?;
            if let Some(r) = &resource {
                resources::register(&tx, r)?;
                tx.execute(
                    "UPDATE jobs SET resource_id=?2 WHERE job_key=?1",
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
        "SELECT EXISTS(SELECT 1 FROM jobs WHERE job_key=?1 AND token=?2 AND result=?3
        AND (resource_id IS NOT NULL)=?4 AND state='done')",
        params![key, token, result, has_file],
        |r| r.get(0),
    )?)
}

fn owns_job(db: &Connection, key: &str, token: &str, now: i64) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM jobs WHERE job_key=?1 AND token=?2 AND state='running'
        AND lease_until>?3)",
        params![key, token, now],
        |r| r.get(0),
    )?)
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
        'result',j.result,'resourceID',j.resource_id,'availableAtMs',j.available_at,'leaseUntilMs',j.lease_until)
        END FROM json_each(?1) AS requested LEFT JOIN jobs j ON j.job_key=requested.value ORDER BY requested.key")?;
    let rows = q.query_map([serde_json::to_string(keys)?], |r| r.get::<_, String>(0))?;
    rows.map(|s| Ok(serde_json::from_str(&s?)?)).collect()
}

fn claim(tx: &Transaction<'_>, now: i64, until: i64) -> Result<Value> {
    tx.execute("UPDATE jobs SET state=CASE WHEN replay_safe=0 THEN 'reconcile'
        WHEN state='cancelling' THEN 'cancelled' WHEN attempt>=max_attempts THEN 'failed' ELSE 'queued' END,
        token=NULL,lease_until=NULL,last_error='lease expired' WHERE state IN ('running','cancelling') AND lease_until<=?",
        [now])?;
    let start: u8 = tx.query_row("SELECT next_slot FROM scheduler WHERE id=1", [], |r| {
        r.get(0)
    })?;
    let mut candidates = tx.prepare_cached("WITH used AS (
        SELECT COALESCE(SUM(memory_mib),0) AS memory, COUNT(*) FILTER(WHERE resource='cpu') AS cpu,
               COUNT(*) FILTER(WHERE resource='gpu') AS gpu, COUNT(*) FILTER(WHERE resource='io') AS io
        FROM jobs WHERE state IN ('running','cancelling'))
        SELECT job_key FROM jobs,used WHERE state='queued' AND lane=?1 AND available_at<=?2
            AND memory_mib+used.memory<=?3
            AND (resource='cpu' AND used.cpu<2 OR resource='gpu' AND used.gpu<1 OR resource='io' AND used.io<1)
        ORDER BY id LIMIT 1")?;
    for offset in 0..LANES.len() {
        let slot = (usize::from(start) + offset) % LANES.len();
        let key: Option<String> = candidates
            .query_row(params![LANES[slot], now, MEMORY_MIB], |r| r.get(0))
            .optional()?;
        if let Some(key) = key {
            let token = Uuid::new_v4().to_string();
            tx.execute("UPDATE jobs SET state='running',attempt=attempt+1,token=?2,lease_until=?3 WHERE job_key=?1",
                params![key, token, until])?;
            tx.execute(
                "UPDATE scheduler SET next_slot=? WHERE id=1",
                [((slot + 1) % LANES.len()) as u8],
            )?;
            let mut result = status(tx, &key)?;
            result["token"] = token.into();
            return Ok(result);
        }
    }
    Ok(Value::Null)
}
