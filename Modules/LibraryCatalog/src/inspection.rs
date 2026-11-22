//! Embedded observations belong to a physical file version. Editable IPTC and migration
//! records belong to a work. This module never creates an admission or changes a triage vote.
mod evidence;
mod metadata;
use crate::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
pub const SCHEMA: &str = include_str!("inspection/schema.sql");

fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|v| !v.is_empty() && v.len() <= 16_384 && !v.contains('\0'))
        .ok_or_else(|| format!("Missing or invalid {key}").into())
}
fn ids(v: &Value) -> Result<Vec<String>> {
    let list = v.as_array().ok_or("Expected a selection of works")?;
    if list.is_empty() || list.len() > 10_000 {
        return Err("Select 1 to 10000 works".into());
    }
    let mut unique = BTreeSet::new();
    for id in list {
        let s = id
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("Invalid work identity")?;
        if !unique.insert(s.to_owned()) {
            return Err("Duplicate work in selection".into());
        }
    }
    Ok(unique.into_iter().collect())
}
fn typed_rows(
    db: &Connection,
    sql: &str,
    bindings: impl rusqlite::Params,
) -> Result<Map<String, Value>> {
    let mut map = Map::new();
    let mut s = db.prepare(sql)?;
    let mut rows = s.query(bindings)?;
    while let Some(r) = rows.next()? {
        let field: String = r.get(0)?;
        let value: String = r.get(1)?;
        let origin: String = r.get(2)?;
        map.insert(
            field,
            json!({"value":serde_json::from_str::<Value>(&value)?,"origin":origin}),
        );
    }
    Ok(map)
}
fn file_change(db: &Connection, file: &str) -> Result<()> {
    db.execute("INSERT INTO lc_changes(asset_id,domain) SELECT asset_id,'inspection' FROM lc_asset_files WHERE file_id=?1",[file])?;
    Ok(())
}
fn work_change(db: &Connection, work: &str) -> Result<()> {
    let n=db.execute("INSERT INTO lc_changes(asset_id,domain) SELECT DISTINCT a.asset_id,'inspection'
        FROM lc_org_works w LEFT JOIN lc_org_works m ON m.work_id=w.master_work_id JOIN lc_asset_files a ON a.file_id=coalesce(w.file_id,m.file_id)
        WHERE w.work_id=?1",[work])?;
    if n == 0 {
        db.execute(
            "INSERT INTO lc_changes(asset_id,domain) VALUES(NULL,'inspection')",
            [],
        )?;
    }
    Ok(())
}
fn file_scope(db: &Connection, file: &str, content: &str, session: Option<&str>) -> Result<()> {
    let ok:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_scopes WHERE file_id=?1 AND content_id=?2)
        OR EXISTS(SELECT 1 FROM lc_occurrences o JOIN lc_sessions s USING(session_id) WHERE o.file_id=?1 AND o.content_id=?2
          AND s.session_id=?3 AND s.state='open')",params![file,content,session],|r|r.get(0))?;
    if !ok {
        return Err("File version is unavailable in the selected library or open intake".into());
    }
    Ok(())
}
fn file_details(db: &Connection, file: &str, content: &str) -> Result<Value> {
    let fields=typed_rows(db,"SELECT field,value_json,origin FROM lc_inspect_file_effective WHERE file_id=? AND content_id=?",params![file,content])?;
    let af: Option<String> = db
        .query_row(
            "SELECT af_json FROM lc_inspect_files WHERE file_id=? AND content_id=?",
            params![file, content],
            |r| r.get(0),
        )
        .optional()?;
    let extractor: Option<String> = db
        .query_row(
            "SELECT extractor FROM lc_inspect_files WHERE file_id=? AND content_id=?",
            params![file, content],
            |r| r.get(0),
        )
        .optional()?;
    let manual_command: Option<String> = db
        .query_row(
            "SELECT manual_command FROM lc_inspect_focus WHERE file_id=? AND content_id=?",
            params![file, content],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let focus: Option<String> = db
        .query_row(
            "SELECT evidence FROM lc_inspect_focus WHERE file_id=? AND content_id=?",
            params![file, content],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let mut samples = Vec::new();
    let mut st = db.prepare(
        "SELECT data FROM lc_inspect_samples WHERE file_id=? AND content_id=? ORDER BY sample_id",
    )?;
    for row in st.query_map(params![file, content], |r| r.get::<_, String>(0))? {
        samples.push(serde_json::from_str::<Value>(&row?)?);
    }
    let mut replicas = Vec::new();
    let mut st=db.prepare("SELECT DISTINCT root_id,relative_path,path,kind,state FROM lc_replicas WHERE file_id=? AND content_id=?
        ORDER BY kind,root_id,relative_path")?;
    let mut rows = st.query(params![file, content])?;
    while let Some(r) = rows.next()? {
        replicas.push(json!({"rootID":r.get::<_,String>(0)?,"relativePath":r.get::<_,String>(1)?,
        "path":r.get::<_,Option<String>>(2)?,"kind":r.get::<_,String>(3)?,"state":r.get::<_,String>(4)?}));
    }
    Ok(json!({"fileID":file,"contentID":content,"fields":fields,
        "extractor":extractor,"manualFocusCommand":manual_command,"af":af.map(|s|serde_json::from_str::<Value>(&s)).transpose()?,"focusEvidence":focus.map(|s|serde_json::from_str::<Value>(&s)).transpose()?,
        "samples":samples,"replicas":replicas,"archiveEligible":db.query_row("SELECT EXISTS(SELECT 1 FROM lc_scopes WHERE file_id=? AND content_id=?)",params![file,content],|r|r.get::<_,bool>(0))?}))
}
pub fn import_fields(
    db: &Connection,
    work_id: &str,
    source_catalog_id: &str,
    source_object_id: &str,
    source_revision: &str,
    fields: &Value,
) -> Result<()> {
    metadata::import_fields(
        db,
        work_id,
        source_catalog_id,
        source_object_id,
        source_revision,
        fields,
    )
}
pub fn work_fields(db: &Connection, work_id: &str) -> Result<Value> {
    Ok(json!(metadata::work(db, work_id)?.fields))
}
pub fn apply(db: &Connection, request: &Value) -> Result<Value> {
    if db.is_autocommit() {
        return Err("Inspection writes require the catalog transaction".into());
    }
    match string(request, "action")? {
        "inspect.edit" => metadata::edit(db, request),
        "inspect.undo" => metadata::undo(db, request),
        "inspect.capture" => evidence::capture(db, request),
        "inspect.histogram" => evidence::histogram(db, request),
        "inspect.analyzeBurst" => evidence::burst(db, request),
        "inspect.focusManual" => evidence::manual(db, request),
        _ => Err("Unknown inspection command".into()),
    }
}
pub fn read(db: &Connection, request: &Value) -> Result<Value> {
    match string(request, "op")? {
        "selection" => metadata::selection(db, &ids(&request["workIDs"])?),
        "work" => {
            let work = metadata::work(db, string(request, "workID")?)?;
            let source = match (&work.file, &work.content) {
                (Some(f), Some(c)) => file_details(db, f, c)?,
                _ => Value::Null,
            };
            Ok(
                json!({"workID":work.id,"fileID":work.file,"contentID":work.content,"fields":work.fields,"file":source,"kind":work.kind,
                "assetID":work.asset,"captureID":work.capture,"filename":work.name,"availability":work.availability,"resolvedPath":work.path}),
            )
        }
        "file" => {
            let f = string(request, "fileID")?;
            let c = string(request, "contentID")?;
            file_scope(db, f, c, request["sessionID"].as_str())?;
            file_details(db, f, c)
        }
        _ => Err("Unknown inspection read".into()),
    }
}
