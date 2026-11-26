//! A recoverable move publishes every destination before switching the catalog and removing sources.
use crate::{
    backup::{files as io, Blob},
    navigation, Result,
};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Digest;
use std::{
    fs::{self, File, OpenOptions},
    os::unix::{fs::OpenOptionsExt, io::AsRawFd},
    path::{Path, PathBuf},
    time::Duration,
};
use uuid::Uuid;
mod plan;
use plan::Entry;

pub const SCHEMA: &str = include_str!("managed_files/schema.sql");
fn field<'a>(body: &'a Value, key: &str) -> Result<&'a str> {
    body[key]
        .as_str()
        .filter(|s| !s.is_empty() && !s.contains('\0'))
        .ok_or_else(|| format!("缺少字段 {key}").into())
}
fn job_id(body: &Value) -> Result<String> {
    Ok(Uuid::parse_str(field(body, "planID")?)?.to_string())
}

fn writer(catalog: &Path) -> Result<Connection> {
    let db = Connection::open_with_flags(
        catalog,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    db.busy_timeout(Duration::from_secs(5))?;
    db.execute_batch("PRAGMA cache_size=-262144; PRAGMA temp_store=MEMORY;")?;
    db.pragma_update(None, "foreign_keys", true)?;
    crate::validate_catalog_objects(&db)?;
    Ok(db)
}
fn lock(catalog: &Path, id: &str) -> Result<File> {
    let dir = io::parent(catalog)?
        .join("LibraryResources")
        .join(".file-jobs");
    io::directory(&dir, true)?;
    let f = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(dir.join(id))?;
    if !f.metadata()?.is_file()
        || unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0
    {
        return Err("该文件任务正在其他窗口执行".into());
    }
    Ok(f)
}
fn plan_row(db: &Connection, id: &str) -> Result<(String, String, Vec<Entry>)> {
    let (fingerprint, state, encoded): (String, String, String) = db.query_row(
        "SELECT fingerprint,state,entries FROM lc_file_plans WHERE plan_id=?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    Ok((fingerprint, state, serde_json::from_str(&encoded)?))
}
fn sibling(e: &Entry, id: &str, n: usize, staging: bool) -> Result<PathBuf> {
    let p = if staging { &e.destination } else { &e.source };
    Ok(io::parent(p)?.join(format!(
        ".rawmaster-{id}-{n}.{}",
        if staging { "receiving" } else { "relocated" }
    )))
}
fn report(db: &Connection, id: &str) -> Result<Value> {
    let (fingerprint, state, items) = plan_row(db, id)?;
    let mut st =
        db.prepare("SELECT position,state FROM lc_file_steps WHERE plan_id=?1 ORDER BY position")?;
    let mut progress = Vec::new();
    let mut rows = st.query([id])?;
    while let Some(row) = rows.next()? {
        let n = usize::try_from(row.get::<_, i64>(0)?)?;
        let e = items.get(n).ok_or("文件任务清单损坏")?;
        progress.push(json!({"assetID":e.asset,"fileID":e.file,"role":e.role,"from":e.source,"to":e.destination,
            "byteCount":e.digest.bytes,"state":row.get::<_,String>(1)?}));
    }
    Ok(json!({"planID":id,"fingerprint":fingerprint,"state":state,"items":progress}))
}
fn start(db: &mut Connection, binding: &str, id: &str, body: &Value) -> Result<()> {
    let fingerprint = field(body, "fingerprint")?;
    if let Some(stored) = db
        .query_row(
            "SELECT fingerprint FROM lc_file_plans WHERE plan_id=?1",
            [id],
            |r| r.get::<_, String>(0),
        )
        .optional()?
    {
        if stored != fingerprint {
            return Err("该任务 ID 已用于另一份清单".into());
        }
        return Ok(());
    }
    let (entries, current) = plan::materialize(db, body)?;
    if fingerprint != current {
        return Err("文件或目标已变化，请重新核对清单".into());
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute(
        "INSERT INTO lc_file_plans VALUES(?1,?2,?3,?4,'pending')",
        params![id, current, binding, serde_json::to_string(&entries)?],
    )?;
    for (n, e) in entries.iter().enumerate() {
        for p in [&e.source, &e.destination] {
            let occupied = tx.execute(
                "INSERT OR IGNORE INTO lc_file_claims VALUES(?1,?2)",
                params![plan::key(p)?, id],
            )?;
            if occupied != 1 {
                return Err(format!("另一项文件操作占用 {}", p.display()).into());
            }
        }
        tx.execute(
            "INSERT INTO lc_file_steps VALUES(?1,?2,NULL,'pending')",
            params![id, n as i64],
        )?;
    }
    tx.commit()?;
    Ok(())
}
fn publish_one(db: &Connection, id: &str, n: usize, e: &Entry) -> Result<()> {
    let (state, saved): (String, Option<String>) = db.query_row(
        "SELECT state,destination_stamp FROM lc_file_steps WHERE plan_id=?1 AND position=?2",
        params![id, n as i64],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if state == "published" || state == "done" {
        io::check(&e.destination, &e.digest)?;
        return Ok(());
    }
    let temp = sibling(e, id, n, true)?;
    let proof = if let Some(s) = saved {
        serde_json::from_str(&s)?
    } else {
        if plan::stamp(&e.source)? != e.stamp {
            return Err(format!("来源已变化：{}", e.source.display()).into());
        }
        if !io::exists(&temp)? {
            io::verified_copy(&mut io::regular(&e.source)?, &temp, &e.digest)?
        }
        io::check(&temp, &e.digest)?;
        let s = plan::stamp(&temp)?;
        db.execute("UPDATE lc_file_steps SET destination_stamp=?1,state='staged' WHERE plan_id=?2 AND position=?3",
            params![serde_json::to_string(&s)?,id,n as i64])?;
        s
    };
    if !io::exists(&e.destination)? {
        if plan::stamp(&temp)? != proof {
            return Err("暂存文件已变化".into());
        }
        io::publish(&temp, &e.destination)?;
    }
    if plan::stamp(&e.destination)? != proof {
        return Err(format!("同名目标属于其他文件：{}", e.destination.display()).into());
    }
    io::check(&e.destination, &e.digest)?;
    db.execute(
        "UPDATE lc_file_steps SET state='published' WHERE plan_id=?1 AND position=?2",
        params![id, n as i64],
    )?;
    Ok(())
}
fn bind(tx: &Connection, e: &Entry) -> Result<()> {
    let from = e.locator.as_deref().ok_or("原件没有原位置")?;
    let dest = e.destination.to_str().ok_or("目标路径无效")?;
    let name = e
        .destination
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("目标名称无效")?;
    let folder = io::parent(&e.destination)?.to_str().ok_or("目标目录无效")?;
    let still_owned:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM lc_scopes s JOIN lc_asset_input a USING(asset_id) WHERE s.asset_id=?1
        AND s.file_id=?2 AND s.content_id=?3 AND a.content_id=s.content_id AND a.current_path=?4)",params![e.asset,e.file,e.content,from],|r|r.get(0))?;
    let shared:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM lc_asset_input a JOIN lc_asset_files f USING(asset_id)
        WHERE a.source_path=?1 OR a.original_path=?1 OR (a.current_path=?1 AND (f.file_id!=?2 OR a.content_id IS NOT ?3)))",
        params![from,e.file,e.content],|r|r.get(0))?;
    if !still_owned || shared {
        return Err("文件纳入、内容版本或共享关系已变化，请保留来源并重新核对".into());
    }
    let root=tx.query_row("SELECT root_id FROM lc_roots WHERE local_path=?1 AND kind='managed' ORDER BY root_id LIMIT 1",[folder],|r|r.get::<_,String>(0)).optional()?
        .unwrap_or_else(||Uuid::new_v4().to_string());
    tx.execute(
        "INSERT OR IGNORE INTO lc_roots(root_id,local_path,kind) VALUES(?1,?2,'managed')",
        params![root, folder],
    )?;
    let changed=tx.execute("UPDATE assets SET data=json_set(data,'$.filename',?1,'$.effectiveManagedPath',?2,'$.currentPath',?2,'$.availability','available'),revision=revision+1
        WHERE id IN (SELECT a.asset_id FROM lc_asset_input a JOIN lc_asset_files f USING(asset_id) WHERE f.file_id=?3 AND a.content_id=?4 AND a.current_path=?5)",
        params![name,dest,e.file,e.content,from])?;
    if changed == 0 {
        return Err("受管原件已移动".into());
    }
    tx.execute("UPDATE lc_replicas SET state='missing' WHERE file_id=?1 AND content_id=?2 AND path=?3 AND kind!='source'",params![e.file,e.content,from])?;
    // Keep the compatibility replica's physical root consistent with the current managed path.
    tx.execute("UPDATE lc_replicas SET root_id=?1,relative_path=?2 WHERE file_id=?3 AND content_id=?4 AND path=?5 AND kind='managed'",
        params![root,name,e.file,e.content,dest])?;
    let replica = Uuid::new_v5(
        &Uuid::NAMESPACE_OID,
        &serde_json::to_vec(&(&e.file, &e.content, &root, name))?,
    )
    .to_string();
    tx.execute("INSERT INTO lc_replicas(replica_id,file_id,content_id,root_id,relative_path,path,kind,state,source_asset_id) VALUES(?1,?2,?3,?4,?5,?6,'managed','available',?7)
        ON CONFLICT(replica_id) DO UPDATE SET state='available',path=excluded.path",params![replica,e.file,e.content,root,name,dest,e.asset])?;
    crate::organization::relocate_managed(tx, &e.file, &root, folder, name, name)?;
    Ok(())
}
fn cleanup(e: &Entry, id: &str, n: usize) -> Result<()> {
    let parked = sibling(e, id, n, false)?;
    if !io::exists(&parked)? {
        if !io::exists(&e.source)? {
            return Ok(());
        }
        if plan::stamp(&e.source)? != e.stamp {
            return Err(format!("旧位置已有其他文件，保留 {}", e.source.display()).into());
        }
        io::check(&e.source, &e.digest)?;
        io::publish(&e.source, &parked)?;
    }
    if plan::stamp(&parked)? != e.stamp || io::check(&parked, &e.digest).is_err() {
        if !io::exists(&e.source)? {
            io::publish(&parked, &e.source)?
        }
        return Err("旧位置内容已变化，已保留供核对".into());
    }
    fs::remove_file(&parked)?;
    io::directory(io::parent(&parked)?, false)?.sync_all()?;
    Ok(())
}
fn run(catalog: &Path, db: &mut Connection, id: &str) -> Result<()> {
    let (_, mut state, entries) = plan_row(db, id)?;
    if state == "done" {
        return Ok(());
    }
    if state == "cancelled" {
        return Err("文件任务已取消".into());
    }
    if state == "pending" {
        for (n, e) in entries.iter().enumerate() {
            publish_one(db, id, n, e)?
        }
        db.execute(
            "UPDATE lc_file_plans SET state='published' WHERE plan_id=?1",
            [id],
        )?;
        state = "published".into();
    }
    if state == "published" {
        let mut sidecars = vec![];
        for e in &entries {
            io::check(&e.destination, &e.digest)?;
            if e.role == "sidecar" {
                let resource = crate::resources::stage(
                    catalog,
                    &e.destination,
                    &format!("sidecar:{id}:{}", sidecars.len()),
                    "sidecar",
                    Some(e.asset.clone()),
                )?;
                if resource.sha256 != e.digest.sha256 {
                    return Err("旁车文件在登记前已变化".into());
                }
                sidecars.push(resource);
            }
        }
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        for (position, entry) in entries.iter().enumerate() {
            let stamp: String = tx.query_row(
                "SELECT destination_stamp FROM lc_file_steps WHERE plan_id=?1 AND position=?2",
                params![id, position as i64],
                |r| r.get(0),
            )?;
            if plan::stamp(&entry.destination)? != serde_json::from_str(&stamp)? {
                return Err("目标文件在目录登记前已变化".into());
            }
        }
        for e in entries.iter().filter(|e| e.role == "original") {
            bind(&tx, e)?
        }
        for resource in &sidecars {
            crate::resources::register(&tx, resource)?
        }
        tx.execute(
            "UPDATE lc_file_plans SET state='committed' WHERE plan_id=?1",
            [id],
        )?;
        tx.commit()?;
    }
    for (n, e) in entries.iter().enumerate() {
        let done: bool = db.query_row(
            "SELECT state='done' FROM lc_file_steps WHERE plan_id=?1 AND position=?2",
            params![id, n as i64],
            |r| r.get(0),
        )?;
        if done {
            continue;
        }
        io::check(&e.destination, &e.digest)?;
        cleanup(e, id, n)?;
        db.execute(
            "UPDATE lc_file_steps SET state='done' WHERE plan_id=?1 AND position=?2",
            params![id, n as i64],
        )?;
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute("DELETE FROM lc_file_claims WHERE plan_id=?1", [id])?;
    tx.execute(
        "UPDATE lc_file_plans SET state='done' WHERE plan_id=?1",
        [id],
    )?;
    tx.commit()?;
    Ok(())
}
fn cancel(db: &mut Connection, id: &str) -> Result<()> {
    let (_, state, entries) = plan_row(db, id)?;
    if state == "cancelled" {
        return Ok(());
    }
    if state != "pending" && state != "published" {
        return Err("目标位置已登记，可继续清理旧副本".into());
    }
    for (n, e) in entries.iter().enumerate() {
        let saved: Option<String> = db.query_row(
            "SELECT destination_stamp FROM lc_file_steps WHERE plan_id=?1 AND position=?2",
            params![id, n as i64],
            |r| r.get(0),
        )?;
        // Only remove an item whose durable identity still matches our staged file.
        if let Some(proof) = saved {
            let proof = serde_json::from_str(&proof)?;
            for p in [sibling(e, id, n, true)?, e.destination.clone()] {
                if io::exists(&p)? && plan::stamp(&p)? == proof {
                    io::check(&p, &e.digest)?;
                    fs::remove_file(&p)?;
                    io::directory(io::parent(&p)?, false)?.sync_all()?;
                }
            }
        }
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute("DELETE FROM lc_file_claims WHERE plan_id=?1", [id])?;
    tx.execute(
        "UPDATE lc_file_plans SET state='cancelled' WHERE plan_id=?1",
        [id],
    )?;
    tx.commit()?;
    Ok(())
}

/// Copied catalogs preserve the audit trail but cannot resume another instance's file deletions.
pub(crate) fn detach_foreign(db: &Connection, binding: &str) -> Result<()> {
    db.execute("UPDATE lc_file_plans SET state='detached' WHERE local_binding<>?1 AND state IN ('pending','published','committed')", [binding])?;
    db.execute("DELETE FROM lc_file_claims WHERE plan_id IN (SELECT plan_id FROM lc_file_plans WHERE state='detached')",[])?;
    Ok(())
}
fn local_binding(catalog: &Path) -> Result<String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = fs::metadata(catalog)?;
    Ok(format!("{}:{}", metadata.dev(), metadata.ino()))
}

pub fn execute(catalog: &Path, body: &Value) -> Result<Value> {
    match field(body, "op")? {
        "preview" => {
            let db = navigation::open_reader(catalog)?;
            let (entries, fingerprint) = plan::materialize(&db, body)?;
            Ok(json!({"state":"preview","fingerprint":fingerprint,"items":entries}))
        }
        "list" => {
            let db = navigation::open_reader(catalog)?;
            let mut st=db.prepare("SELECT plan_id FROM lc_file_plans WHERE state IN ('pending','published','committed') AND local_binding=?1 ORDER BY rowid")?;
            let ids = st
                .query_map([local_binding(catalog)?], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(json!({"plans":ids.iter().map(|id|report(&db,id)).collect::<Result<Vec<_>>>()?}))
        }
        op @ ("start" | "resume" | "cancel") => {
            let id = job_id(body)?;
            let _lock = lock(catalog, &id)?;
            let mut db = writer(catalog)?;
            let binding = local_binding(catalog)?;
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            detach_foreign(&tx, &binding)?;
            tx.commit()?;
            let foreign:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_file_plans WHERE plan_id=?1 AND local_binding<>?2 AND state<>'done')",params![id,binding],|r|r.get(0))?;
            if foreign {
                return Err("这份清单属于另一份库副本，请在当前位置重新预览".into());
            }
            if op == "start" {
                start(&mut db, &binding, &id, body)?
            }
            if op == "cancel" {
                cancel(&mut db, &id)?
            } else if let Err(error) = run(catalog, &mut db, &id) {
                let mut saved = report(&db, &id)?;
                saved["error"] = json!(error.to_string());
                return Ok(saved);
            }
            report(&db, &id)
        }
        _ => Err("未知文件操作".into()),
    }
}
