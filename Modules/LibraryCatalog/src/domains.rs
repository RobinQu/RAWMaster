use crate::{authority, inspection, lightroom, managed_files, organization, resources, Result};
use rusqlite::{types::ValueRef, Connection};
use std::sync::OnceLock;

/// Domain tables share one catalog version and a single trusted SQLite object registry.
const DOMAINS: &[&str] = &[
    managed_files::SCHEMA,
    crate::processing::SCHEMA,
    organization::SCHEMA,
    crate::discovery::SCHEMA,
    inspection::SCHEMA,
    lightroom::SCHEMA,
];
struct Definition {
    name: String,
    kind: String,
    owner: String,
    sql: String,
}

fn reference(version: i64) -> Result<Vec<Definition>> {
    let db = authority::reference_database()?;
    resources::install(&db)?;
    for sql in DOMAINS {
        db.execute_batch(sql)?;
    }
    if version >= 9 {
        db.execute_batch(crate::scheduler::SCHEMA)?;
    }
    if version >= 10 {
        db.execute_batch(crate::scheduler::batch::SCHEMA_V10)?;
    }
    let mut stmt = db.prepare(
        "SELECT name,type,tbl_name,sql FROM main.sqlite_schema WHERE name GLOB 'lc_*' ORDER BY name",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(Definition {
            name: row.get(0)?,
            kind: row.get(1)?,
            owner: row.get(2)?,
            sql: row.get(3)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn trusted(version: i64) -> Result<&'static [Definition]> {
    type Reference = OnceLock<std::result::Result<Vec<Definition>, String>>;
    static V8: Reference = OnceLock::new();
    static V9: Reference = OnceLock::new();
    static V10: Reference = OnceLock::new();
    let reference_cell = match version {
        8 => &V8,
        9 => &V9,
        10 => &V10,
        _ => return Err("unsupported catalog definition version".into()),
    };
    reference_cell
        .get_or_init(|| reference(version).map_err(|e| e.to_string()))
        .as_ref()
        .map(Vec::as_slice)
        .map_err(|e| e.clone().into())
}
pub fn names(version: i64) -> Result<Vec<String>> {
    Ok(trusted(version)?
        .iter()
        .map(|def| def.name.clone())
        .collect())
}

/// Only packaged expectations are cached. Inspect every registered or executable object in
/// the live main database once, including unregistered indexes owned by catalog tables.
pub fn validate(db: &Connection, version: i64) -> Result<()> {
    let expected = trusted(version)?;
    let mut seen = vec![false; expected.len()];
    let mut stmt = db.prepare(
        "SELECT name,type,tbl_name,sql FROM main.sqlite_schema WHERE name GLOB 'lc_*'
         OR (name NOT GLOB 'sqlite_*' AND (type IN ('view','trigger') OR tbl_name GLOB 'lc_*'))",
    )?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name = row.get_ref(0)?.as_str()?;
        let index = expected
            .binary_search_by(|def| def.name.as_str().cmp(name))
            .map_err(|_| format!("Unknown catalog schema object: {name}"))?;
        let def = &expected[index];
        let kind = row.get_ref(1)?.as_str()?;
        let owner = row.get_ref(2)?.as_str()?;
        let sql = row.get_ref(3)?;
        if seen[index]
            || kind != def.kind
            || owner != def.owner
            || (sql != ValueRef::Text(def.sql.as_bytes())
                && !(version == 8
                    && authority::matches_historical_sync(name, kind, owner, sql.as_str()?)))
        {
            return Err(format!("Incompatible catalog definition: {name}").into());
        }
        seen[index] = true;
    }
    if let Some(missing) = seen.iter().position(|present| !present) {
        return Err(format!("Missing catalog definition: {}", expected[missing].name).into());
    }
    Ok(())
}
pub fn install(db: &Connection) -> Result<()> {
    authority::install(db)?;
    resources::install(db)?;
    for sql in DOMAINS {
        db.execute_batch(sql)?
    }
    organization::bootstrap(db)?;
    Ok(())
}
