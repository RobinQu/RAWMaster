use crate::{domains, Result};
use rusqlite::{backup::Backup, types::ValueRef, Connection, OpenFlags};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{path::Path, time::Duration};

fn block(hash: &mut Sha256, tag: u8, data: &[u8]) {
    hash.update([tag]);
    hash.update((data.len() as u64).to_be_bytes());
    hash.update(data);
}

/// This digest is over v7 records, not SQLite headers, page layouts or journal mode.
/// rowid is significant because older catalog order and group tie breakers depend on it.
fn signature(db: &Connection) -> Result<String> {
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version != 7 {
        return Err("Expected a validated v7 migration snapshot".into());
    }
    let mut hash = Sha256::new();
    hash.update(b"RAWMaster/v7-records/1");
    let mut schema = db.prepare("SELECT name,sql FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")?;
    let mut tables = schema.query([])?;
    while let Some(table) = tables.next()? {
        let name: String = table.get(0)?;
        let definition: String = table.get(1)?;
        block(&mut hash, 0, name.as_bytes());
        block(&mut hash, 1, definition.as_bytes());
        let quoted = name.replace('"', "\"\"");
        let mut query = db.prepare(&format!("SELECT rowid,* FROM \"{quoted}\" ORDER BY rowid"))?;
        let cols = query.column_count();
        let mut rows = query.query([])?;
        while let Some(row) = rows.next()? {
            hash.update([2]);
            for column in 0..cols {
                match row.get_ref(column)? {
                    ValueRef::Null => block(&mut hash, 3, &[]),
                    ValueRef::Integer(i) => block(&mut hash, 4, &i.to_be_bytes()),
                    ValueRef::Real(f) => block(&mut hash, 5, &f.to_bits().to_be_bytes()),
                    ValueRef::Text(t) => block(&mut hash, 6, t),
                    ValueRef::Blob(b) => block(&mut hash, 7, b),
                }
            }
        }
    }
    Ok(hex::encode(hash.finalize()))
}

pub fn check(db: &Connection, body: &Value) -> Result<Value> {
    if body["v7Signature"].as_str() != Some(&signature(db)?) {
        return Err("The v7 catalog changed after the backup; reopen to retry migration".into());
    }
    Ok(json!({"matched":true}))
}

pub fn preview(backup: &Path) -> Result<Value> {
    let source = Connection::open_with_flags(backup, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    source.busy_timeout(Duration::from_secs(5))?;
    let folder = tempfile::tempdir_in(backup.parent().ok_or("Missing migration backup parent")?)?;
    let mut copy = Connection::open(folder.path().join("rehearsal.sqlite"))?;
    Backup::new(&source, &mut copy)?.run_to_completion(128, Duration::from_millis(1), None)?;
    copy.pragma_update(None, "foreign_keys", true)?;
    let tx = copy.transaction()?;
    let before = signature(&tx)?;
    domains::install(&tx)?;
    crate::validate_catalog_objects(&tx)?;
    let quick: String = tx.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    let broken: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_foreign_key_check)",
        [],
        |row| row.get(0),
    )?;
    if quick != "ok" || broken {
        return Err("Migrated snapshot failed integrity checks".into());
    }
    let scopes: i64 = tx.query_row("SELECT count(*) FROM lc_scopes", [], |r| r.get(0))?;
    let occurrences: i64 = tx.query_row("SELECT count(*) FROM lc_occurrences", [], |r| r.get(0))?;
    let differences: i64 =
        tx.query_row("SELECT count(*) FROM lc_reconciliation", [], |r| r.get(0))?;
    tx.commit()?;
    Ok(
        json!({"v7Signature":before,"occurrences":occurrences,"archiveScopes":scopes,"reconciliation":differences}),
    )
}

pub fn report(catalog: &Path, request: &Value) -> Result<Value> {
    let mut db = crate::navigation::open_reader(catalog)?;
    let tx = db.transaction()?;
    let mut domains = Vec::new();
    let mut st=tx.prepare("SELECT domain,reason,count(*) FROM lc_reconciliation GROUP BY domain,reason ORDER BY domain,reason")?;
    let mut rows = st.query([])?;
    while let Some(r) = rows.next()? {
        domains.push(json!({"domain":r.get::<_,String>(0)?,"reason":r.get::<_,String>(1)?,"count":r.get::<_,i64>(2)?}));
    }
    drop(rows);
    drop(st);
    let mut details = Vec::new();
    let offset = request["afterRow"].as_i64().unwrap_or(0);
    let mut st=tx.prepare("SELECT rowid,domain,entity_id,reason FROM lc_reconciliation WHERE rowid>?1 ORDER BY rowid LIMIT 100")?;
    let mut rows = st.query([offset])?;
    while let Some(r) = rows.next()? {
        details.push(json!({"row":r.get::<_,i64>(0)?,"domain":r.get::<_,String>(1)?,"entityID":r.get::<_,String>(2)?,"reason":r.get::<_,String>(3)?}));
    }
    let (files,captures,sessions,admitted):(i64,i64,i64,i64)=tx.query_row(
        "SELECT (SELECT count(*) FROM lc_files),(SELECT count(DISTINCT capture_id) FROM lc_files),
                (SELECT count(*) FROM lc_sessions WHERE origin<>'version-host'),(SELECT count(*) FROM lc_scopes)",[],|r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
    Ok(
        json!({"files":files,"captures":captures,"sessions":sessions,"archiveScopes":admitted,"domains":domains,"rows":details}),
    )
}
