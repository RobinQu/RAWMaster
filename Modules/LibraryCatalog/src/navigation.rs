use crate::Result;
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

pub(crate) fn open_reader(catalog: &Path) -> Result<Connection> {
    let db = Connection::open_with_flags(
        catalog,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.busy_timeout(Duration::from_secs(3))?;
    db.pragma_update(None, "query_only", true)?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version != crate::CATALOG_SCHEMA_VERSION {
        return Err(format!("Unsupported library version {version}").into());
    }
    Ok(db)
}

pub fn overview(catalog: &Path) -> Result<Value> {
    let mut db = open_reader(catalog)?;
    let tx = db.transaction()?;
    let mut projects = Vec::new();
    {
        let mut stmt = tx.prepare(
            "WITH counted AS (
            SELECT s.project_id, count(DISTINCT s.file_id) AS files, count(DISTINCT f.capture_id) AS captures, count(DISTINCT CASE WHEN json_extract(a.data,'$.decision')='keep' THEN s.file_id END) AS kept FROM lc_scopes s JOIN lc_files f ON f.file_id=s.file_id
            JOIN assets a ON a.id=s.asset_id GROUP BY s.project_id
        ) SELECT p.data,COALESCE(c.files,0),COALESCE(c.captures,0),COALESCE(c.kept,0) FROM projects p LEFT JOIN counted c ON c.project_id=p.id
        WHERE c.files>0 OR NOT EXISTS (SELECT 1 FROM session_workflows w
          WHERE json_extract(w.data,'$.projectID')=p.id AND json_extract(w.data,'$.isNewProject')=1)
        ORDER BY p.rowid",
        )?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let project: Value = serde_json::from_str(&row.get::<_, String>(0)?)?;
            projects.push(json!({"project": project, "files": row.get::<_,i64>(1)?,"captures":row.get::<_,i64>(2)?,"kept":row.get::<_,i64>(3)?}));
        }
    }
    let (files, kept): (i64, i64) = tx.query_row(
        "SELECT count(DISTINCT s.file_id),count(DISTINCT CASE WHEN json_extract(a.data,'$.decision')='keep' THEN s.file_id END) FROM lc_scopes s JOIN assets a ON a.id=s.asset_id",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let captures: i64 = tx.query_row("SELECT count(DISTINCT f.capture_id) FROM lc_scopes s JOIN lc_files f ON f.file_id=s.file_id JOIN assets a ON a.id=s.asset_id",[],|r|r.get(0))?;
    let sessions: i64 = tx.query_row("SELECT count(*) FROM sessions s WHERE NOT EXISTS(SELECT 1 FROM lc_sessions x WHERE x.session_id=s.id AND x.origin='version-host')", [], |r| r.get(0))?;
    let groups: i64 = tx.query_row("SELECT count(*) FROM lc_group_versions v
        WHERE v.tombstoned=0 AND v.revision=(SELECT MAX(revision) FROM lc_group_versions WHERE group_id=v.group_id)
        AND EXISTS(SELECT 1 FROM lc_group_file_members m JOIN lc_scopes s ON s.file_id=m.file_id AND s.project_id=v.project_id
        JOIN assets a ON a.id=s.asset_id WHERE m.group_id=v.group_id AND m.revision=v.revision)",[],|r|r.get(0))?;
    Ok(
        json!({"projects":projects,"files":files,"captures":captures,"sessions":sessions,"groups":groups,"kept":kept}),
    )
}
