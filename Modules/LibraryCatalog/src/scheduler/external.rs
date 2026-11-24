//! A pending local delivery is identified by its canonical path, size, SHA-256 and device/inode.
//! A temporarily unmounted volume has no verifiable destination. If the OS assigns a different device
//! or inode on reattachment, the task stays open for reconciliation even when the bytes match.
//! Once a local delivery has a completed receipt, later verification checks the frozen path and bytes.
//! A restored library keeps historical records and detaches the original workstation's private paths.
use super::check;
use crate::{resources, Result};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde_json::{json, Value};
use std::fs::{self, File, Metadata};
use std::path::{Path, PathBuf};

/// Resolve the directory only: a destination's final component must never be followed.
fn path_in_directory(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        return Err("external publication requires absolute paths".into());
    }
    let parent = path
        .parent()
        .ok_or("missing publication directory")?
        .canonicalize()?;
    Ok(parent.join(path.file_name().ok_or("missing publication filename")?))
}

fn publication(r: &rusqlite::Row<'_>, offset: usize) -> rusqlite::Result<Value> {
    Ok(
        json!({"stage": r.get::<_,String>(offset)?, "destination":r.get::<_,String>(offset+1)?,
                "sha256":r.get::<_,String>(offset+2)?, "byteCount":r.get::<_,i64>(offset+3)?}),
    )
}

pub(super) fn prepared(db: &Connection, key: &str) -> Result<Value> {
    Ok(db.query_row(
        "SELECT prepared_stage,prepared_destination,prepared_sha256,prepared_bytes FROM lc_task_jobs
         WHERE job_key=?1 AND prepared_stage IS NOT NULL", [key],
        |r| publication(r, 0),
    ).optional()?.unwrap_or(Value::Null))
}

// RENAME_EXCL and hard_link preserve the staged inode. A newly written file can have the same SHA
// while belonging to another publisher. A changed volume/file identity must leave recovery pending.
fn file_identity(metadata: &Metadata) -> Option<String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (metadata.ino() != 0).then(|| format!("{:x}:{:x}", metadata.dev(), metadata.ino()))
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
        None
    }
}

fn digest_stable(input: &File, path: &Path, before: &Metadata) -> Result<(String, i64)> {
    let (sha, count) = resources::transfer(input, std::io::sink())?;
    let after = fs::symlink_metadata(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != after.dev() || before.ino() != after.ino() {
            return Err("publication file was replaced during verification".into());
        }
    }
    if !after.is_file()
        || before.len() != after.len()
        || before.modified()? != after.modified()?
        || count <= 0
        || after.len() != u64::try_from(count)?
    {
        return Err("publication file changed during verification or was empty".into());
    }
    Ok((sha, count))
}

/// Freeze the final, encoded bytes before the host's atomic no-replace operation. Holding a catalog
/// writer lock while hashing an export would block unrelated views. Recheck ownership after hashing.
pub(super) fn prepare(
    db: &mut Connection,
    key: &str,
    token: &str,
    stage: &Path,
    destination: &Path,
) -> Result<Value> {
    check(db, key, token)?;
    require_local(db, key)?;
    let stage = path_in_directory(stage)?;
    let destination = path_in_directory(destination)?;
    let frozen: Option<String> = db.query_row(
        "SELECT json_extract(payload,'$.destination') FROM lc_task_jobs WHERE job_key=?1",
        [key],
        |r| r.get(0),
    )?;
    if let Some(frozen) = frozen {
        if path_in_directory(Path::new(&frozen))? != destination {
            return Err("external destination differs from the frozen task descriptor".into());
        }
    }
    let root = destination.parent().ok_or("missing output folder")?;
    if stage == destination || !stage.starts_with(root) {
        return Err("stage must be a distinct file under the destination directory".into());
    }
    let existing = prepared(db, key)?;
    if !existing.is_null()
        && (existing["stage"].as_str() != stage.to_str()
            || existing["destination"].as_str() != destination.to_str())
    {
        return Err("external publication paths have already been frozen".into());
    }
    let input = resources::open_regular(&stage)?;
    let metadata = input.metadata()?;
    let binding = file_identity(&metadata);
    let (sha, count) = digest_stable(&input, &stage, &metadata)?;
    input.sync_all()?;
    let stage_parent = stage.parent().ok_or("missing stage directory")?;
    File::open(stage_parent)?.sync_all()?;
    if stage_parent != root {
        File::open(root)?.sync_all()?;
    }
    let row = json!({"stage":stage.to_str().ok_or("non-UTF-8 stage")?, "destination":destination.to_str().ok_or("non-UTF-8 destination")?,
                    "sha256":sha,"byteCount":count});
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    check(&tx, key, token)?;
    let saved = prepared(&tx, key)?;
    if !saved.is_null() {
        let prior: Option<String> = tx.query_row(
            "SELECT prepared_file_identity FROM lc_task_jobs WHERE job_key=?1",
            [key],
            |r| r.get(0),
        )?;
        if saved != row || prior != binding {
            return Err(
                "prepared external publication has different bytes, identity or paths".into(),
            );
        }
    } else {
        match fs::symlink_metadata(&destination) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
            Ok(_) => return Ok(json!({"status":"destinationExists"})),
        }
        tx.execute("UPDATE lc_task_jobs SET prepared_stage=?2,prepared_destination=?3,prepared_sha256=?4,prepared_bytes=?5,prepared_file_identity=?6 WHERE job_key=?1",
            params![key,stage.to_str(),destination.to_str(),sha,count,binding])?;
    }
    tx.commit()?;
    Ok(row)
}

pub(super) fn pending(
    db: &Connection,
    lane: &str,
    prefix: &str,
    after: Option<&str>,
    limit: u32,
) -> Result<Value> {
    if !super::LANES.contains(&lane) || !(1..=256).contains(&limit) {
        return Err("invalid lane or preparation page size".into());
    }
    let mut query = db.prepare(
        "SELECT job_key,payload,prepared_stage,prepared_destination,prepared_sha256,prepared_bytes
                FROM lc_task_jobs WHERE lane=?1 AND substr(job_key,1,length(?2))=?2 AND job_key>?3
                AND prepared_stage IS NOT NULL AND prepared_detached=0 AND state!='done' ORDER BY job_key LIMIT ?4",
    )?;
    let rows = query.query_map(params![lane, prefix, after.unwrap_or(""), limit], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            publication(r, 2)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (key, encoded, publication) = row?;
        let payload: Value = serde_json::from_str(&encoded)?;
        out.push(json!({"key":key,"payload":payload,"publication":publication}));
    }
    Ok(Value::Array(out))
}

struct Verification {
    ticket: Value,
    binding: Option<String>,
    historical: bool,
    owner: Option<String>,
    result: Option<String>,
}

impl Verification {
    fn load(db: &Connection, key: &str) -> Result<Option<Self>> {
        let row = db.query_row("SELECT prepared_stage,prepared_destination,prepared_sha256,prepared_bytes,prepared_detached,
            prepared_file_identity,state='done' AND final_verified=1,token,result
            FROM lc_task_jobs WHERE job_key=?1 AND prepared_stage IS NOT NULL", [key], |r| {
            Ok((Self { ticket: publication(r, 0)?, binding: r.get(5)?, historical: r.get(6)?,
                       owner: r.get(7)?, result: r.get(8)? }, r.get::<_,bool>(4)?))
        }).optional()?;
        match row {
            Some((_, true)) => Err("the external delivery is detached from this task".into()),
            Some((record, false)) => Ok(Some(record)),
            None => Ok(None),
        }
    }

    fn acknowledged_by(&self, token: &str) -> bool {
        self.historical
            && self.owner.as_deref() == Some(token)
            && self.result.as_deref() == self.ticket["sha256"].as_str()
    }

    /// Missing is distinct from an existing mismatched destination. The latter must never authorize replay.
    fn verify_file(&self, destination: bool) -> Result<bool> {
        let field = if destination { "destination" } else { "stage" };
        let path = Path::new(
            self.ticket[field]
                .as_str()
                .ok_or("missing prepared external publication")?,
        );
        let file = match resources::open_regular(path) {
            Ok(file) => file,
            Err(e)
                if e.downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
            {
                return Ok(false)
            }
            Err(e) => return Err(e),
        };
        let count = self.ticket["byteCount"]
            .as_i64()
            .ok_or("missing prepared byte count")?;
        let metadata = file.metadata()?;
        if !destination || !self.historical {
            if destination && self.binding.is_none() {
                return Err(
                    "the filesystem does not provide a stable identity for this pending delivery"
                        .into(),
                );
            }
            if self.binding != file_identity(&metadata) {
                return Err(
                    "external output does not have the prepared volume and file identity".into(),
                );
            }
        }
        if metadata.len() != u64::try_from(count)? {
            return Err("external output has a different size".into());
        }
        let (sha, actual) = digest_stable(&file, path, &metadata)?;
        if actual != count || self.ticket["sha256"] != sha {
            return Err("external output has a different SHA-256".into());
        }
        file.sync_all()?;
        File::open(path.parent().ok_or("missing publication directory")?)?.sync_all()?;
        Ok(true)
    }
}

pub(super) fn verify(
    db: &Connection,
    key: &str,
    destination: bool,
    return_ticket: bool,
) -> Result<Value> {
    let Some(record) = Verification::load(db, key)? else {
        if return_ticket {
            return Ok(Value::Null);
        }
        return Err("missing prepared external publication".into());
    };
    if !record.verify_file(destination)? {
        return Ok(if return_ticket {
            Value::Null
        } else {
            Value::Bool(false)
        });
    }
    if destination {
        let verified = db.execute("UPDATE lc_task_jobs SET final_verified=1 WHERE job_key=?1 AND prepared_detached=0 AND final_verified=0
            AND prepared_sha256=?2 AND prepared_bytes=?3 AND prepared_file_identity IS ?4",
            params![key, record.ticket["sha256"].as_str(), record.ticket["byteCount"].as_i64(), record.binding])?;
        if verified == 0 {
            require_local(db, key)?;
        }
    }
    Ok(if return_ticket {
        record.ticket
    } else {
        Value::Bool(true)
    })
}

/// The batch export's result is exactly the durable file SHA. Hash and fsync before the write lock,
/// then acknowledge this live generation and the verified file in one commit.
pub(super) fn finish(db: &mut Connection, key: &str, token: &str) -> Result<Value> {
    let record = Verification::load(db, key)?.ok_or("missing prepared external publication")?;
    if record.acknowledged_by(token) {
        return Ok(record.ticket);
    }
    check(db, key, token)?;
    if !record.verify_file(true)? {
        return Err("missing prepared destination".into());
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let changed=tx.execute("UPDATE lc_task_jobs SET final_verified=1,state='done',result=prepared_sha256,lease_until=NULL,last_error=NULL
        WHERE job_key=?1 AND token=?2 AND state='running' AND lease_until>?3 AND prepared_detached=0
        AND prepared_sha256=?4 AND prepared_bytes=?5 AND prepared_file_identity IS ?6",
        params![key,token,super::now_ms()?,record.ticket["sha256"].as_str(),record.ticket["byteCount"].as_i64(),record.binding])?;
    if changed == 0 && !Verification::load(&tx, key)?.is_some_and(|r| r.acknowledged_by(token)) {
        return Err("stale lease or external publication changed before acknowledgement".into());
    }
    tx.commit()?;
    Ok(record.ticket)
}

pub(super) fn require_local(db: &Connection, key: &str) -> Result<()> {
    let remote: bool = db.query_row(
        "SELECT prepared_detached FROM lc_task_jobs WHERE job_key=?1",
        [key],
        |r| r.get(0),
    )?;
    if remote {
        return Err("the external delivery is detached from this task".into());
    }
    Ok(())
}

pub(super) fn require_final_receipt(db: &Connection, key: &str) -> Result<()> {
    let pending: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_task_jobs
        WHERE job_key=?1 AND prepared_stage IS NOT NULL AND (final_verified=0 OR (prepared_detached=1 AND state!='done')))",
        [key],
        |r| r.get(0),
    )?;
    if pending {
        return Err("external delivery requires verified final bytes".into());
    }
    Ok(())
}
