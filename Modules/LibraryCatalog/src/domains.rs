use crate::{authority, inspection, lightroom, managed_files, organization, resources, Result};
use rusqlite::Connection;
use std::{collections::BTreeMap, sync::OnceLock};

/// Domain tables share one catalog version and a single trusted SQLite object registry.
const DOMAINS: &[&str] = &[
    managed_files::SCHEMA,
    crate::processing::SCHEMA,
    organization::SCHEMA,
    crate::discovery::SCHEMA,
    inspection::SCHEMA,
    lightroom::SCHEMA,
];
type Definitions = BTreeMap<String, (String, String, String)>;
fn definitions(db: &Connection) -> Result<Definitions> {
    let mut stmt=db.prepare("SELECT name,type,tbl_name,sql FROM sqlite_schema WHERE name GLOB 'lc_*' AND sql IS NOT NULL")?;
    let rows = stmt.query_map([], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?, r.get(3)?))))?;
    Ok(rows.collect::<rusqlite::Result<Definitions>>()?)
}
fn reference() -> Result<Definitions> {
    let stub = Connection::open_in_memory()?;
    stub.execute_batch(include_str!("authority/legacy_v7_reference.sql"))?;
    stub.execute_batch(authority::SCHEMA_SQL)?;
    resources::install(&stub)?;
    let base = definitions(&stub)?;
    for sql in DOMAINS {
        stub.execute_batch(sql)?
    }
    let mut all = definitions(&stub)?;
    all.retain(|k, _| !base.contains_key(k));
    Ok(all)
}
fn trusted() -> Result<&'static Definitions> {
    static REF: OnceLock<std::result::Result<Definitions, String>> = OnceLock::new();
    REF.get_or_init(|| reference().map_err(|e| e.to_string()))
        .as_ref()
        .map_err(|e| e.clone().into())
}
pub fn names() -> Result<Vec<String>> {
    Ok(trusted()?.keys().cloned().collect())
}
pub fn validate(db: &Connection) -> Result<()> {
    let found = definitions(db)?;
    for (name, definition) in trusted()? {
        if found.get(name) != Some(definition) {
            return Err(format!("Missing or incompatible catalog definition: {name}").into());
        }
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
