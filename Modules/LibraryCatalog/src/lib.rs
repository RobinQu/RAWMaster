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
pub mod scheduler;
mod selection;
pub const CATALOG_SCHEMA_VERSION: i64 = 10;

pub fn readable_schema(version: i64) -> bool {
    (8..=CATALOG_SCHEMA_VERSION).contains(&version)
}
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
        Some("scheduler") => scheduler::execute(catalog, body),
        Some("workbenchCatalogFile") => scheduler::batch::catalog_file_identity(catalog),
        Some("groupProcessing") => processing::execute(catalog, body),
        Some("lightroom") => lightroom::execute(catalog, body),
        Some("managedFiles") => managed_files::execute(catalog, body),
        Some("resolveSelection") => {
            let mut db = navigation::open_reader(catalog)?;
            let snapshot = db.transaction()?;
            selection::resolve(&snapshot, body)
        }
        Some("overview") => navigation::overview(catalog),
        Some("package") => backup::execute(catalog, body),
        _ => Err("Unsupported catalog operation".into()),
    }
}

/// All library-owned SQL objects are identified from the packaged schema.
pub fn schema_objects() -> Result<Vec<String>> {
    domains::names(CATALOG_SCHEMA_VERSION)
}

pub fn validate_catalog_objects(db: &Connection) -> Result<Vec<String>> {
    domains::names(validated_schema_version(db, false)?)
}

fn validated_schema_version(db: &Connection, current_only: bool) -> Result<i64> {
    // Observe user_version and its registered definitions in the same SQLite snapshot.
    // Migrations and backup verification may already own a transaction on this handle.
    let snapshot = db
        .is_autocommit()
        .then(|| rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Deferred))
        .transpose()?;
    let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    if current_only && version != CATALOG_SCHEMA_VERSION {
        return Err("scheduler requires an upgraded library".into());
    }
    domains::validate(db, version)?;
    if let Some(snapshot) = snapshot {
        snapshot.commit()?;
    }
    Ok(version)
}

fn require_scheduler_schema(db: &Connection) -> Result<()> {
    validated_schema_version(db, true)?;
    Ok(())
}

/// Only install on the exact previous trusted catalog. The owning host backs up before migration.
fn upgrade_scheduler(db: &Connection) -> Result<()> {
    let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    if version == CATALOG_SCHEMA_VERSION {
        return require_scheduler_schema(db);
    }
    if !matches!(version, 8 | 9) {
        return Err("scheduler migration requires a version 8 or 9 library".into());
    }
    domains::validate(db, version)?;
    db.execute_batch("SAVEPOINT lc_scheduler_migration")?;
    let upgraded = (|| -> Result<()> {
        if version == 8 {
            authority::normalize_v8_sync(db)?;
            db.execute_batch(scheduler::SCHEMA)?;
        }
        db.execute_batch(scheduler::batch::SCHEMA_V10)?;
        if version == 9 {
            scheduler::batch::migrate_v9(db)?;
        }
        db.pragma_update(None, "user_version", CATALOG_SCHEMA_VERSION)?;
        require_scheduler_schema(db)
    })();
    if upgraded.is_err() {
        db.execute_batch("ROLLBACK TO lc_scheduler_migration")?;
    }
    db.execute_batch("RELEASE lc_scheduler_migration")?;
    upgraded
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
        "upgradeScheduler" => {
            upgrade_scheduler(db)?;
            Ok(json!({"schema":CATALOG_SCHEMA_VERSION}))
        }
        "detachRestoredWriter" => Ok(json!({"writerID":backup::detach_restored_writer(db)?})),
        "detachLocalCopy" => backup::detach_local_copy(db, &envelope["request"]),
        "taskForReceipt" | "completeVerifiedTask" => {
            let body = &envelope["request"];
            let key = body["key"].as_str().ok_or("missing task key")?;
            if op == "taskForReceipt" {
                scheduler::for_receipt(db, key)
            } else {
                scheduler::complete_verified(
                    db,
                    key,
                    body["receipt"].as_str().ok_or("missing verified receipt")?,
                )
            }
        }
        "checkTaskLease" | "finishTaskReceipt" => {
            let r = &envelope["request"];
            let key = r["key"].as_str().ok_or("missing task key")?;
            let token = r["token"].as_str().ok_or("missing lease token")?;
            if op == "checkTaskLease" {
                scheduler::check(db, key, token)
            } else {
                scheduler::finish_receipt(
                    db,
                    key,
                    token,
                    r["receipt"]
                        .as_str()
                        .ok_or("missing authoritative receipt")?,
                )
            }
        }
        "flushLegacy" => {
            authority::flush_legacy(db)?;
            Ok(json!({"flushed": true}))
        }
        "migrationCheck" => migration::check(db, &envelope["request"]),
        "validateSelection" => selection::check(db, &envelope["request"]),
        "resolveSelection" => selection::resolve(db, &envelope["request"]),
        "command" => authority::command(db, &envelope["request"]),
        _ => Err("Unsupported catalog transaction".into()),
    }
}
