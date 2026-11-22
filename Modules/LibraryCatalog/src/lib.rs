//! Local RAWMaster catalog. SQLite is the single transaction authority.
pub mod authority;
pub mod backup;
pub mod discovery;
mod domains;
mod ffi;
pub mod inspection;
pub mod lightroom;
pub mod managed_files;
mod migration;
mod navigation;
pub mod organization;
pub mod processing;
pub mod query;
pub mod resources;
mod selection;
pub const CATALOG_SCHEMA_VERSION: i64 = 8;
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

use rusqlite::Connection;
use serde_json::{json, Value};
use std::path::Path;

pub fn request(catalog: &Path, envelope: &Value) -> Result<Value> {
    let body = envelope.get("request").unwrap_or(&Value::Null);
    match envelope["operation"].as_str() {
        Some("page" | "refresh" | "indexValidate" | "indexRebuild") => {
            let index = Path::new(envelope["indexPath"].as_str().ok_or("Missing indexPath")?);
            if index == catalog || !index.is_absolute() || !catalog.is_absolute() {
                return Err("Catalog and index require distinct absolute paths".into());
            }
            match envelope["operation"].as_str() {
                Some("page") => query::page(catalog, index, body),
                Some("indexValidate") => query::validate(catalog, index),
                Some("indexRebuild") => query::rebuild(catalog, index),
                _ => query::refresh(catalog, index),
            }
        }
        Some("migrationReport") => migration::report(catalog, body),
        Some("migrationPreview") => migration::preview(catalog),
        Some("organization" | "inspection" | "discovery") => {
            let mut db = navigation::open_reader(catalog)?;
            let tx = db.transaction()?;
            if envelope["operation"] == "organization" {
                organization::read(&tx, body)
            } else if envelope["operation"] == "discovery" {
                discovery::read(&tx, body)
            } else {
                inspection::read(&tx, body)
            }
        }
        Some("groupProcessing") => processing::execute(catalog, body),
        Some("lightroom") => lightroom::execute(catalog, body),
        Some("managedFiles") => managed_files::execute(catalog, body),
        Some("overview") => navigation::overview(catalog),
        Some("package") => backup::execute(catalog, body),
        _ => Err("Unsupported catalog operation".into()),
    }
}

/// All library-owned SQL objects are identified from the packaged schema.
pub fn schema_objects() -> Result<Vec<String>> {
    let mut names = authority::object_names()?;
    names.push(resources::TABLE.into());
    names.extend(domains::names()?);
    names.sort();
    Ok(names)
}

pub fn validate_catalog_objects(db: &Connection) -> Result<Vec<String>> {
    authority::validate_schema(db)?;
    resources::validate(db)?;
    domains::validate(db)?;
    let allowed = schema_objects()?;
    let mut statement = db.prepare("SELECT name FROM sqlite_schema WHERE name GLOB 'lc_*'")?;
    for row in statement.query_map([], |row| row.get::<_, String>(0))? {
        let name = row?;
        if allowed.binary_search(&name).is_err() {
            return Err(format!("Unknown catalog schema object: {name}").into());
        }
    }
    Ok(allowed)
}

pub fn transaction(db: &Connection, envelope: &Value) -> Result<Value> {
    let op = envelope["operation"].as_str().ok_or("Missing operation")?;
    if op == "validate" {
        let names = validate_catalog_objects(db)?;
        return Ok(json!({"valid": true, "objects": names}));
    }
    if db.is_autocommit() {
        return Err("A host write transaction is required".into());
    }
    match op {
        "install" => {
            domains::install(db)?;
            Ok(json!({"installed": true}))
        }
        "flushLegacy" => {
            authority::flush_legacy(db)?;
            Ok(json!({"flushed": true}))
        }
        "migrationCheck" => migration::check(db, &envelope["request"]),
        "validateSelection" => selection::check(db, &envelope["request"]),
        "command" => authority::command(db, &envelope["request"]),
        _ => Err("Unsupported catalog transaction".into()),
    }
}
