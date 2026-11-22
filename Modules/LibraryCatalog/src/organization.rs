//! Work identity, folder and collection organization. Only the import authority
//! can grant an original a catalog/backup scope. An offline work owns neither.
mod groups;
mod reading;
mod works;

use crate::Result;
use rusqlite::{Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashSet;

pub const SCHEMA: &str = include_str!("organization/schema.sql");

pub fn bootstrap(db: &Connection) -> Result<()> {
    db.execute(
        "INSERT INTO lc_org_native_seed(file_id,root_id,relative_path)
        SELECT s.file_id,o.root_id,o.relative_path FROM lc_scopes s
        JOIN lc_occurrences o USING(session_id,occurrence_id)
        WHERE NOT EXISTS(SELECT 1 FROM lc_org_works w WHERE w.work_id='file:'||s.file_id)
        ORDER BY s.file_id,s.session_id,s.occurrence_id",
        [],
    )?;
    Ok(())
}

pub fn relocate_managed(
    db: &Connection,
    file_id: &str,
    volume_id: &str,
    root_path: &str,
    relative: &str,
    filename: &str,
) -> Result<()> {
    if db.is_autocommit() {
        return Err("managed relocation requires an authority transaction".into());
    }
    let rel = std::path::Path::new(relative);
    if volume_id.is_empty()
        || rel.is_absolute()
        || rel
            .components()
            .any(|p| !matches!(p, std::path::Component::Normal(_)))
        || rel.file_name().and_then(|s| s.to_str()) != Some(filename)
    {
        return Err("invalid managed relative destination".into());
    }
    db.execute(
        "INSERT INTO lc_org_native_seed(file_id,root_id,relative_path) VALUES(?,?,?)",
        rusqlite::params![file_id, volume_id, relative],
    )?;
    db.execute(
        "UPDATE lc_org_volumes SET locator=? WHERE volume_id=?",
        rusqlite::params![root_path, volume_id],
    )?;
    let folder = rel.parent().and_then(|p| p.to_str()).unwrap_or("");
    let target:String=db.query_row("SELECT folder_id FROM lc_org_folders WHERE volume_id=?1 AND folder_id='dir:'||hex(?1)||':'||hex(?2)",
        rusqlite::params![volume_id,folder],|r|r.get(0))?;
    let mut stmt = db.prepare(
        "SELECT DISTINCT folder_id FROM lc_org_works WHERE file_id=? AND folder_id IS NOT NULL",
    )?;
    let prior = stmt
        .query_map([file_id], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    db.execute("UPDATE lc_org_works SET folder_id=?,revision=revision+1 WHERE file_id=? AND folder_id IS NOT ?",rusqlite::params![target,file_id,target])?;
    for old in prior {
        groups::tidy_scope(db, "folder", Some(&old))?;
    }
    db.execute(
        "INSERT INTO lc_changes(asset_id,domain) VALUES(NULL,'organization')",
        [],
    )?;
    Ok(())
}

pub fn publish_derived(
    db: &Connection,
    work_id: &str,
    resource_id: &str,
    job_id: &str,
    kind: &str,
    name: &str,
    folder_id: Option<&str>,
    project_id: &str,
) -> Result<Value> {
    if db.is_autocommit()
        || !matches!(kind, "derivedPhoto" | "derivedVideo")
        || [work_id, resource_id, job_id, name, project_id]
            .iter()
            .any(|s| s.is_empty())
    {
        return Err("invalid derived publication".into());
    }
    let existing:Option<(String,String,String,Option<String>)>=db.query_row("SELECT d.work_id,d.resource_id,w.kind,w.project_id FROM lc_org_derived d JOIN lc_org_works w USING(work_id) WHERE job_id=?",
        [job_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    if let Some((work, resource, k, project)) = existing {
        if work != work_id
            || resource != resource_id
            || k != kind
            || project.as_deref() != Some(project_id)
        {
            return Err("derived job already published different output".into());
        }
    } else {
        require(
            db,
            "SELECT EXISTS(SELECT 1 FROM lc_resources WHERE resource_id=?)",
            resource_id,
            "missing managed result resource",
        )?;
        db.execute(
            "INSERT INTO lc_org_works(work_id,kind,folder_id,name,revision,project_id) VALUES(?,?,?,?,1,?)",
            rusqlite::params![work_id, kind, folder_id, name,project_id],
        )?;
        db.execute(
            "INSERT INTO lc_org_derived VALUES(?,?,?)",
            rusqlite::params![work_id, resource_id, job_id],
        )?;
        db.execute(
            "INSERT INTO lc_changes(asset_id,domain) VALUES(NULL,'organization')",
            [],
        )?;
    }
    Ok(json!({"workID":work_id,"resourceID":resource_id,"jobID":job_id}))
}

fn string<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.trim().is_empty() && !s.contains('\0'))
        .ok_or_else(|| format!("expected nonempty {k}").into())
}
fn optional<'a>(v: &'a Value, k: &str) -> Result<Option<&'a str>> {
    if v[k].is_null() {
        return Ok(None);
    }
    string(v, k).map(Some)
}
fn position(v: &Value) -> Result<i64> {
    v.get("position")
        .map(|n| {
            n.as_i64()
                .filter(|v| *v >= 0)
                .ok_or_else(|| "expected nonnegative position".into())
        })
        .unwrap_or(Ok(0))
}
fn list(v: &Value, k: &str) -> Result<Vec<String>> {
    let xs = v[k]
        .as_array()
        .ok_or_else(|| format!("expected ordered {k}"))?;
    let mut seen = HashSet::new();
    let mut ordered = Vec::with_capacity(xs.len());
    for x in xs {
        let id = x
            .as_str()
            .filter(|s| !s.is_empty() && !s.contains('\0'))
            .ok_or("invalid member ID")?;
        if !seen.insert(id) {
            return Err("duplicate member in explicit order".into());
        }
        ordered.push(id.to_owned());
    }
    Ok(ordered)
}
fn stored(db: &Connection, sql: &str, id: &str) -> Result<Option<Value>> {
    let raw: Option<String> = db.query_row(sql, [id], |r| r.get(0)).optional()?;
    Ok(raw.map(|s| serde_json::from_str(&s)).transpose()?)
}
fn amended(old: &Value, r: &Value, fields: &[&str]) -> Value {
    let mut next = old.clone();
    for k in fields {
        if let Some(v) = r.get(*k) {
            next[*k] = v.clone();
        }
    }
    next
}
fn revision(old: Option<&Value>, r: &Value) -> Result<i64> {
    let rev = old.and_then(|v| v["revision"].as_i64()).unwrap_or(0);
    if let Some(base) = r.get("baseRevision") {
        if base.as_i64() != Some(rev) {
            return Err(
                format!("organization revision changed; expected {base}, current {rev}").into(),
            );
        }
    }
    Ok(rev.checked_add(1).ok_or("organization revision overflow")?)
}
fn require(db: &Connection, sql: &str, id: &str, why: &str) -> Result<()> {
    if !db.query_row(sql, [id], |r| r.get::<_, bool>(0))? {
        return Err(why.to_owned().into());
    }
    Ok(())
}

pub fn apply(db: &Connection, r: &Value) -> Result<Value> {
    if db.is_autocommit() {
        return Err("organization writes require the caller's authority transaction".into());
    }
    let result = match string(r, "action")? {
        "org.saveVolume" => works::volume(db, r)?,
        "org.saveFolder" => works::folder(db, r)?,
        "org.saveWork" => works::save(db, r)?,
        "org.linkOriginal" => works::link(db, r)?,
        "org.saveCollection" => groups::collection(db, r)?,
        "org.setMembers" => groups::set_members(db, r)?,
        "org.addMembers" => groups::add_members(db, r)?,
        "org.moveMember" => groups::move_member(db, r)?,
        "org.stageMembers" => groups::stage_members(db, r)?,
        "org.setFolderOrder" => groups::folder_order(db, r)?,
        "org.saveStack" => groups::stack(db, r)?,
        "org.removeStack" => groups::remove_stack(db, r)?,
        _ => return Err("unsupported organization command".into()),
    };
    if result.get("published") != Some(&Value::Bool(false)) {
        let mapped = if r["action"] == "org.saveWork" {
            db.execute("INSERT INTO lc_changes(asset_id,domain)
            SELECT af.asset_id,'organization' FROM lc_org_works w JOIN lc_asset_files af ON af.file_id=w.file_id
            WHERE w.work_id=?1 AND w.work_id='file:'||w.file_id",[r["workID"].as_str()])?
        } else {
            0
        };
        if mapped == 0 {
            db.execute(
                "INSERT INTO lc_changes(asset_id,domain) VALUES(NULL,'organization')",
                [],
            )?;
        }
    }
    Ok(result)
}

pub fn read(db: &Connection, r: &Value) -> Result<Value> {
    if db.is_autocommit() {
        let tx = db.unchecked_transaction()?;
        return reading::read(&tx, r);
    }
    reading::read(db, r)
}

pub(crate) fn work_page(db: &Connection, r: &Value) -> Result<Value> {
    if db.is_autocommit() {
        let tx = db.unchecked_transaction()?;
        return crate::query::works::page(&tx, r);
    }
    crate::query::works::page(db, r)
}
