//! The host keeps its SQLite write transaction across legacy and catalog changes.
use crate::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

mod imports;
mod migration;
mod pair_evidence;
mod relations;
mod replicas;

pub const SCHEMA_SQL: &str = include_str!("authority_schema.sql");

pub fn install(db: &Connection) -> Result<()> {
    require_transaction(db)?;
    if db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='lc_meta')",
        [],
        |r| r.get::<_, bool>(0),
    )? {
        return validate_schema(db);
    }
    db.execute_batch(SCHEMA_SQL)?;
    db.execute(
        "INSERT INTO lc_meta VALUES('libraryID',?1)",
        [uuid::Uuid::new_v4().to_string()],
    )?;
    db.execute("INSERT INTO lc_meta VALUES('operationRevision','0')", [])?;
    migration::migrate(db)?;
    db.execute_batch(&journal_sql())?;
    db.execute(
        "INSERT INTO lc_changes(asset_id,domain) VALUES(NULL,'install')",
        [],
    )?;
    Ok(())
}

fn require_transaction(db: &Connection) -> Result<()> {
    if db.is_autocommit() {
        return Err("catalog operation requires a host transaction".into());
    }
    Ok(())
}

// These sources have a v7 asset identity. Adjacent mutations may emit multiple
// sequence numbers; readers coalesce IDs above their committed watermark.
const JOURNALED: &[(&str, &str, &str)] = &[
    ("assets", "id", "asset"),
    ("project_admissions", "asset_id", "admission"),
    ("asset_tags", "asset_id", "metadata"),
    ("asset_color_labels", "asset_id", "metadata"),
    ("review_records", "asset_id", "metadata"),
    ("quality_evidence", "asset_id", "quality"),
    ("triage_records", "asset_id", "triage"),
    ("membership", "asset_id", "group"),
    ("editing_works", "asset_id", "work"),
    ("lc_scopes", "asset_id", "scope"),
    ("lc_asset_files", "asset_id", "file"),
];

fn journal_sql() -> String {
    let mut sql = String::new();
    for (event, alias) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
        let mut add = |table: &str, body: String, condition: &str| {
            let when = if event == "UPDATE" && !condition.is_empty() {
                format!(" WHEN {condition}")
            } else {
                String::new()
            };
            sql.push_str(&format!("CREATE TRIGGER lc_j_{table}_{event} AFTER {event} ON {table}{when} BEGIN {body} END;\n"));
        };
        for &(table, key, domain) in JOURNALED {
            let mut body = format!(
                "INSERT INTO lc_changes(asset_id,domain) VALUES({alias}.{key},'{domain}');"
            );
            if table == "membership" {
                body.push_str(&format!(
                    "INSERT INTO lc_group_dirty SELECT {alias}.group_id WHERE NOT EXISTS(SELECT 1 FROM lc_group_dirty WHERE group_id={alias}.group_id);"
                ));
            }
            if table == "triage_records" {
                body.push_str(&format!("UPDATE lc_sessions SET revision=revision+1 WHERE state='open' AND session_id=(SELECT session_id FROM assets WHERE id={alias}.{key});"));
            }
            add(table, body, "");
        }
        for (table,selector) in [
            ("lc_files",format!("SELECT asset_id FROM lc_asset_files WHERE file_id={alias}.file_id")),
            ("lc_replicas",format!("SELECT asset_id FROM lc_asset_files WHERE file_id={alias}.file_id")),
            ("lc_group_versions",format!("SELECT f.asset_id FROM lc_group_file_members m JOIN lc_asset_files f USING(file_id) WHERE m.group_id={alias}.group_id AND m.revision IN ({alias}.revision,(SELECT max(prior.revision) FROM lc_group_versions prior WHERE prior.group_id={alias}.group_id AND prior.revision<{alias}.revision))")),
            ("lc_group_file_members",format!("SELECT asset_id FROM lc_asset_files WHERE file_id={alias}.file_id")),
            ("editing_versions",format!("SELECT asset_id FROM editing_works WHERE id={alias}.work_id")),
            ("editing_exports",format!("SELECT asset_id FROM editing_works WHERE id={alias}.work_id")),
            ("editing_dispositions",format!("SELECT w.asset_id FROM editing_works w JOIN editing_versions v ON v.work_id=w.id WHERE v.id={alias}.version_id")),
            ("archive_publications",format!("SELECT w.asset_id FROM editing_works w JOIN editing_versions v ON v.work_id=w.id WHERE v.id={alias}.version_id")),
            ("projects",format!("SELECT DISTINCT asset_id FROM lc_scopes WHERE project_id={alias}.id")),
            ("project_review_states",format!("SELECT DISTINCT asset_id FROM lc_scopes WHERE project_id={alias}.project_id")),
            ("capture_pairs",format!("SELECT json_extract({alias}.data,'$.rawAssetID') AS asset_id UNION SELECT json_extract({alias}.data,'$.jpegAssetID') AS asset_id")),
            ("groups_data",format!("SELECT asset_id FROM membership WHERE group_id={alias}.id")),
        ] {
            let mut body=format!("INSERT INTO lc_changes(asset_id,domain) SELECT asset_id,'{table}' FROM ({selector}) WHERE asset_id IS NOT NULL;");
            if table=="groups_data"{body.push_str(&format!("INSERT INTO lc_group_dirty SELECT {alias}.id WHERE NOT EXISTS(SELECT 1 FROM lc_group_dirty WHERE group_id={alias}.id);"));}
            add(table,body,"");
        }
        // Import progress alone does not affect a card or inclusion scope.
        // The scope rows and assets themselves cover all membership changes.
        let locs="json_extract(NEW.data,'$.projectID','$.effectiveSourceRoot','$.effectiveManagedRoot') IS NOT json_extract(OLD.data,'$.projectID','$.effectiveSourceRoot','$.effectiveManagedRoot')";
        add("sessions",format!("INSERT INTO lc_changes(asset_id,domain) SELECT id,'session' FROM assets WHERE session_id={alias}.id;"),locs);
    }
    sql
}

pub fn flush_legacy(db: &Connection) -> Result<()> {
    require_transaction(db)?;
    relations::flush(db)
}
type Definition = (String, String, String);
fn definitions(db: &Connection) -> Result<BTreeMap<String, Definition>> {
    let mut statement = db.prepare("SELECT name,type,tbl_name,sql FROM sqlite_master WHERE name GLOB 'lc_*' AND sql IS NOT NULL ORDER BY name")?;
    let entries =
        statement.query_map([], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?, r.get(3)?))))?;
    Ok(entries.collect::<rusqlite::Result<_>>()?)
}

pub(crate) fn reference_database() -> Result<Connection> {
    let reference = Connection::open_in_memory()?;
    reference.execute_batch(migration::LEGACY_REFERENCE)?;
    reference.execute_batch(SCHEMA_SQL)?;
    reference.execute_batch(&journal_sql())?;
    Ok(reference)
}

fn trusted_definitions() -> Result<&'static BTreeMap<String, Definition>> {
    static EXPECTED: OnceLock<std::result::Result<BTreeMap<String, Definition>, String>> =
        OnceLock::new();
    EXPECTED
        .get_or_init(|| {
            reference_database()
                .and_then(|db| definitions(&db))
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|e| e.clone().into())
}
pub fn object_names() -> Result<Vec<String>> {
    Ok(trusted_definitions()?.keys().cloned().collect())
}

// The shipped library-033 v8 snapshot stores this exact trigger with a space after WHEN.
// Keep v9 strict. Never normalize arbitrary catalog SQL when deciding whether opening it is safe.
const V8_SYNC_NAME: &str = "lc_sync_asset_update";
const V8_SYNC_DDL: &str = concat!(
    "CREATE TRIGGER lc_sync_asset_update AFTER UPDATE ON assets WHEN \n",
    "  json_extract(OLD.data,'$.fileSize','$.contentHash','$.availability','$.importState','$.effectiveSourcePath','$.currentPath','$.effectiveManagedPath','$.relativePath')\n",
    "  IS NOT json_extract(NEW.data,'$.fileSize','$.contentHash','$.availability','$.importState','$.effectiveSourcePath','$.currentPath','$.effectiveManagedPath','$.relativePath')\n",
    "  BEGIN INSERT INTO lc_touch_asset VALUES(NEW.id); END"
);

pub(crate) fn matches_historical_sync(name: &str, kind: &str, owner: &str, sql: &str) -> bool {
    name == V8_SYNC_NAME && kind == "trigger" && owner == "assets" && sql == V8_SYNC_DDL
}

pub(crate) fn normalize_v8_sync(db: &Connection) -> Result<()> {
    let sql: String = db.query_row(
        "SELECT sql FROM sqlite_schema WHERE name=?1",
        [V8_SYNC_NAME],
        |r| r.get(0),
    )?;
    if sql == V8_SYNC_DDL {
        let ddl = &trusted_definitions()?
            .get(V8_SYNC_NAME)
            .ok_or("missing trusted synchronization trigger")?
            .2;
        db.execute_batch("DROP TRIGGER lc_sync_asset_update")?;
        db.execute_batch(ddl)?;
    }
    Ok(())
}

pub fn validate_schema(db: &Connection) -> Result<()> {
    let actual = definitions(db)?;
    for (name, expected) in trusted_definitions()? {
        if actual.get(name) != Some(expected) {
            if actual
                .get(name)
                .is_some_and(|(kind, owner, sql)| matches_historical_sync(name, kind, owner, sql))
                && db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))? == 8
            {
                continue;
            }
            return Err(format!("unrecognized or missing catalog definition: {name}").into());
        }
    }
    Ok(())
}

fn field<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.is_empty() && !s.contains('\0'))
        .ok_or_else(|| format!("missing or invalid {k}").into())
}
fn number(v: &Value, k: &str) -> Result<i64> {
    v[k].as_i64()
        .filter(|n| *n >= 0)
        .ok_or_else(|| format!("invalid {k}").into())
}
fn array<'a>(v: &'a Value, k: &str) -> Result<&'a [Value]> {
    v[k].as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| format!("invalid {k}").into())
}
fn digest_id(domain: &str, parts: &[&str]) -> String {
    let mut h = Sha256::new();
    for part in std::iter::once(&domain).chain(parts.iter()) {
        h.update((part.len() as u64).to_be_bytes());
        h.update(part.as_bytes());
    }
    format!("{domain}:{}", hex::encode(h.finalize()))
}
fn checked_hash(v: &str) -> Result<String> {
    if v.len() != 64 || !v.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("invalid SHA-256 digest".into());
    }
    Ok(v.to_ascii_lowercase())
}
fn canonical(v: &Value) -> Result<String> {
    fn sort(v: &Value) -> Value {
        match v {
            Value::Object(map) => {
                let ordered: BTreeMap<_, _> =
                    map.iter().map(|(k, x)| (k.clone(), sort(x))).collect();
                Value::Object(ordered.into_iter().collect())
            }
            Value::Array(xs) => Value::Array(xs.iter().map(sort).collect()),
            x => x.clone(),
        }
    }
    Ok(serde_json::to_string(&sort(v))?)
}
pub fn command(db: &Connection, request: &Value) -> Result<Value> {
    require_transaction(db)?;
    if request["version"].as_u64() != Some(1) {
        return Err("unsupported catalog command version".into());
    }
    let library: String =
        db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |x| {
            x.get(0)
        })?;
    if let Some(requested) = request.get("libraryID") {
        if requested.as_str() != Some(library.as_str()) {
            return Err("command belongs to another library".into());
        }
    }
    let operation = field(request, "commandID")?;
    let payload = canonical(request)?;
    let digest = hex::encode(Sha256::digest(payload.as_bytes()));
    // Replay validation needs identity of the exact descriptor. Derived face
    // and scene vectors belong to the disposable feature index, even in backups.
    let payload = if request["action"] == "discover.finish" {
        format!("sha256:{digest}")
    } else {
        payload
    };
    if let Some((original, result)) = db
        .query_row(
            "SELECT request,result FROM lc_receipts WHERE command_id=?1",
            [operation],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()?
    {
        if original != payload {
            return Err("command ID was already used for a different request".into());
        }
        return Ok(serde_json::from_str(&result)?);
    }
    db.execute_batch("SAVEPOINT lc_command_atomic")?;
    let attempt = (|| -> Result<Value> {
        let mut result = match field(request, "action")? {
            "session.open" => imports::open(db, request)?,
            "occurrence.put" => imports::put(db, request)?,
            "session.seal" => imports::seal(db, request)?,
            "session.finishDirect" => imports::finish_direct(db, request)?,
            "admission.restore" => imports::restore(db, request)?,
            "capture.pair" | "capture.split" => relations::pair(db, request)?,
            "group.revise" => relations::revise(db, request)?,
            "group.syncLegacy" => relations::sync_group(db, field(request, "groupID")?)?,
            "replica.verify" => replicas::verify(db, request)?,
            "root.register" => replicas::register_root(db, request)?,
            action if action.starts_with("org.") => crate::organization::apply(db, request)?,
            action if action.starts_with("discover.") => crate::discovery::apply(db, request)?,
            action if action.starts_with("inspect.") => crate::inspection::apply(db, request)?,
            _ => return Err("unknown catalog command action".into()),
        };
        let revision: i64 = db.query_row(
            "SELECT CAST(value AS INTEGER) FROM lc_meta WHERE key='operationRevision'",
            [],
            |x| x.get(0),
        )?;
        let next = revision
            .checked_add(1)
            .ok_or("catalog operation revision overflow")?;
        db.execute(
            "UPDATE lc_meta SET value=?1 WHERE key='operationRevision'",
            [next.to_string()],
        )?;
        result["libraryID"] = json!(library);
        result["action"] = request["action"].clone();
        result["baseCatalogRevision"] = json!(revision);
        result["resultCatalogRevision"] = json!(next);
        let device: Option<String> = db
            .query_row("SELECT value FROM metadata WHERE key='deviceID'", [], |x| {
                x.get(0)
            })
            .optional()?;
        result["deviceID"] = json!(request["deviceID"].as_str().or(device.as_deref()));
        result["commandID"] = json!(operation);
        result["version"] = json!(1);
        db.execute(
            "INSERT INTO lc_receipts VALUES(?1,?2,?3,?4)",
            params![operation, digest, payload, canonical(&result)?],
        )?;
        Ok(result)
    })();
    match attempt {
        Ok(result) => {
            db.execute_batch("RELEASE lc_command_atomic")?;
            Ok(result)
        }
        Err(error) => {
            db.execute_batch("ROLLBACK TO lc_command_atomic; RELEASE lc_command_atomic")?;
            Err(error)
        }
    }
}

pub(crate) fn restore_replica(
    db: &Connection,
    file_id: &str,
    content_id: &str,
    root_id: &str,
    relative_path: &str,
    final_path: &Path,
    verified_staged_path: &Path,
) -> Result<()> {
    require_transaction(db)?;
    replicas::record_verified(
        db,
        file_id,
        content_id,
        root_id,
        relative_path,
        final_path,
        verified_staged_path,
        "restored",
    )?;
    Ok(())
}

pub(crate) fn activate_restored_scope(
    db: &Connection,
    scope_id: &str,
    file_id: &str,
    content_id: &str,
    final_path: &Path,
) -> Result<String> {
    require_transaction(db)?;
    replicas::activate(db, scope_id, file_id, content_id, final_path)
}
