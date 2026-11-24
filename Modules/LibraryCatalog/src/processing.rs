//! Frozen group recipes and independently recoverable rendering attempts.
use crate::{organization, resources, Result};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
mod inputs;
mod media;
mod render;
pub const SCHEMA: &str = include_str!("processing/schema.sql");
fn required<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| format!("Missing {k}").into())
}
fn job_id(r: &Value) -> Result<String> {
    Ok(Uuid::parse_str(required(r, "jobID")?)?
        .hyphenated()
        .to_string())
}
fn time() -> Result<i64> {
    Ok(i64::try_from(
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
    )?)
}
fn db(p: &Path, write: bool) -> Result<Connection> {
    if !fs::symlink_metadata(p)?.is_file() {
        return Err("Expected a regular catalog".into());
    }
    let c = Connection::open_with_flags(
        p.canonicalize()?,
        (if write {
            OpenFlags::SQLITE_OPEN_READ_WRITE
        } else {
            OpenFlags::SQLITE_OPEN_READ_ONLY
        }) | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    c.busy_timeout(Duration::from_secs(5))?;
    c.execute_batch("PRAGMA trusted_schema=OFF;PRAGMA foreign_keys=ON;")?;
    Ok(c)
}
fn attempt_dir(catalog: &Path, jid: &str, token: &str) -> Result<PathBuf> {
    let job = Uuid::parse_str(jid)?.hyphenated().to_string();
    let token = Uuid::parse_str(token)?.hyphenated().to_string();
    let base = catalog
        .canonicalize()?
        .parent()
        .ok_or("Missing library folder")?
        .to_path_buf();
    let mut current = base;
    for c in [".GroupJobs", &job, &token] {
        current.push(c);
        if current.exists() && !fs::symlink_metadata(&current)?.is_dir() {
            return Err("Invalid private rendering folder".into());
        }
    }
    Ok(current)
}
fn status(db: &Connection, jid: &str) -> Result<Value> {
    let mut v=db.query_row("SELECT group_id,revision,project_id,operation,recipe_json,parent_job,state,attempt,token,lease_until,receipt_json,resource_id,work_id,error FROM lc_proc_jobs WHERE job_id=?",[jid],|r|Ok(json!({"jobID":jid,"groupID":r.get::<_,String>(0)?,"revision":r.get::<_,i64>(1)?,"projectID":r.get::<_,String>(2)?,"operation":r.get::<_,String>(3)?,"recipe":r.get::<_,String>(4)?,"parentJobID":r.get::<_,Option<String>>(5)?,"state":r.get::<_,String>(6)?,"attempt":r.get::<_,i64>(7)?,"token":r.get::<_,Option<String>>(8)?,"leaseUntil":r.get::<_,Option<i64>>(9)?,"receipt":r.get::<_,Option<String>>(10)?,"resourceID":r.get::<_,Option<String>>(11)?,"workID":r.get::<_,Option<String>>(12)?,"error":r.get::<_,Option<String>>(13)?})))?;
    v["recipe"] = serde_json::from_str(required(&v, "recipe")?)?;
    if let Some(s) = v["receipt"].as_str() {
        v["receipt"] = serde_json::from_str(s)?;
    }
    Ok(v)
}
fn sources(db: &Connection, jid: &str) -> Result<Vec<Value>> {
    let mut q=db.prepare("SELECT capture_id,file_id,source_position,render_position,asset_id,content_id,sha256,byte_count,work_version,role,reason,source_json FROM lc_proc_inputs WHERE job_id=? ORDER BY source_position")?;
    let rows=q.query_map([jid],|r|Ok(json!({"captureID":r.get::<_,String>(0)?,"fileID":r.get::<_,String>(1)?,"position":r.get::<_,i64>(2)?,"renderPosition":r.get::<_,Option<i64>>(3)?,"assetID":r.get::<_,Option<String>>(4)?,"contentID":r.get::<_,Option<String>>(5)?,"sha256":r.get::<_,Option<String>>(6)?,"byteCount":r.get::<_,Option<i64>>(7)?,"workVersionID":r.get::<_,Option<String>>(8)?,"role":r.get::<_,String>(9)?,"reason":r.get::<_,String>(10)?,"asset":r.get::<_,String>(11)?})))?;
    let mut out = Vec::new();
    for v in rows {
        let mut v = v?;
        v["asset"] = serde_json::from_str(required(&v, "asset")?)?;
        v["exposureSeconds"] = v["asset"]["verifiedExposureSeconds"].clone();
        out.push(v);
    }
    Ok(out)
}
fn publish(db: &mut Connection, r: &Value) -> Result<Value> {
    let jid = job_id(r)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let job = status(&tx, &jid)?;
    if job["state"] == "published" {
        tx.commit()?;
        return status(db, &jid);
    }
    if job["state"] != "staged" {
        return Err("Output has not passed its format and integrity checks".into());
    }
    let kind = required(&job["receipt"], "mediaKind")?;
    let res = required(&job, "resourceID")?;
    let wid = Uuid::new_v5(
        &Uuid::NAMESPACE_URL,
        format!("rawmaster/group-output/{jid}").as_bytes(),
    )
    .to_string();
    let folder:Option<String>=tx.query_row("SELECT w.folder_id FROM lc_proc_inputs i JOIN lc_org_works w ON w.work_id='file:'||i.file_id WHERE i.job_id=? AND i.render_position IS NOT NULL AND w.folder_id IS NOT NULL ORDER BY i.render_position LIMIT 1",[&jid],|v|v.get(0)).optional()?;
    let name = r["name"]
        .as_str()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or(required(&job, "operation")?);
    organization::publish_derived(
        &tx,
        &wid,
        res,
        &jid,
        kind,
        name,
        folder.as_deref(),
        required(&job, "projectID")?,
    )?;
    tx.execute(
        "UPDATE lc_proc_jobs SET state='published',work_id=?2,lease_until=NULL WHERE job_id=?1",
        params![jid, wid],
    )?;
    tx.execute(
        "UPDATE lc_proc_attempts SET state='published' WHERE job_id=?1 AND attempt=?2",
        params![jid, job["attempt"].as_i64()],
    )?;
    tx.commit()?;
    status(db, &jid)
}
pub fn execute(catalog: &Path, r: &Value) -> Result<Value> {
    let action = required(r, "action")?;
    let mut c = db(
        catalog,
        !matches!(
            action,
            "draft" | "status" | "trace" | "list" | "inspectOutput"
        ),
    )?;
    match action {
        "draft" => {
            let tx = c.transaction()?;
            let d = inputs::draft(&tx, r)?;
            Ok(
                json!({"groupID":r["groupID"],"revision":d.revision,"projectID":d.project,"entries":d.entries,"missing":d.missing}),
            )
        }
        "freeze" => inputs::freeze(&mut c, r),
        "remake" => inputs::remake(&mut c, r),
        "claim" => render::claim(catalog, &mut c, r),
        "checkpoint" => render::checkpoint(catalog, &mut c, r),
        "publish" => {
            let result = publish(&mut c, r)?;
            // A superseded worker may have stopped between copying input frames and registering its failure.
            let jid = job_id(r)?;
            let mut q = c.prepare("SELECT token FROM lc_proc_attempts WHERE job_id=?1")?;
            for token in q.query_map([&jid], |row| row.get::<_, String>(0))? {
                render::clean_attempt(&attempt_dir(catalog, &jid, &token?)?);
            }
            Ok(result)
        }
        "status" | "trace" => {
            let jid = if let Some(work) = r["workID"].as_str() {
                c.query_row(
                    "SELECT job_id FROM lc_proc_jobs WHERE work_id=?",
                    [work],
                    |v| v.get::<_, String>(0),
                )?
            } else {
                job_id(r)?
            };
            let tx = c.transaction()?;
            let mut v = status(&tx, &jid)?;
            v["inputs"] = json!(sources(&tx, &jid)?);
            Ok(v)
        }
        "list" => {
            let mut q=c.prepare("SELECT j.job_id FROM lc_proc_jobs j WHERE (?1 IS NULL OR j.group_id=?1) AND (?2 IS NULL OR EXISTS(SELECT 1 FROM lc_proc_inputs i WHERE i.job_id=j.job_id AND i.file_id=?2)) AND (?3 IS NULL OR EXISTS(SELECT 1 FROM lc_proc_inputs i WHERE i.job_id=j.job_id AND i.capture_id=?3)) ORDER BY j.rowid DESC LIMIT 200")?;
            let ids = q
                .query_map(
                    params![
                        r["groupID"].as_str(),
                        r["fileID"].as_str(),
                        r["captureID"].as_str()
                    ],
                    |v| v.get::<_, String>(0),
                )?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(json!({"jobs":ids.iter().map(|j|status(&c,j)).collect::<Result<Vec<_>>>()?}))
        }
        "renew" => {
            let jid = job_id(r)?;
            let token = required(r, "token")?;
            if c.execute("UPDATE lc_proc_jobs SET lease_until=?3 WHERE job_id=?1 AND token=?2 AND state IN ('preparing','rendering') AND lease_until>unixepoch()",params![jid,token,time()?+300])?!=1{return Err("Rendering attempt is no longer active".into());}
            Ok(json!({"renewed":true}))
        }
        "cancel" | "fail" => {
            let result = render::stop(&mut c, r, action == "cancel")?;
            if let Some(token) = result["token"].as_str() {
                render::clean_attempt(&attempt_dir(catalog, &job_id(r)?, token)?);
            }
            Ok(result)
        }
        "inspectOutput" => {
            let jid = job_id(r)?;
            let job = status(&c, &jid)?;
            let (sha, length): (String, i64) = c.query_row(
                "SELECT sha256,byte_count FROM lc_resources WHERE resource_id=?",
                [required(&job, "resourceID")?],
                |v| Ok((v.get(0)?, v.get(1)?)),
            )?;
            let path = catalog
                .parent()
                .ok_or("Missing library folder")?
                .join("LibraryResources")
                .join(resources::object_path(&sha)?);
            if render::digest(&path, std::io::sink())? != (sha, length) {
                return Err(
                    "The managed master no longer matches its published digest and length".into(),
                );
            }
            Ok(json!({"path":path,"receipt":job["receipt"],"workID":job["workID"]}))
        }
        _ => Err("Unknown group processing action".into()),
    }
}
