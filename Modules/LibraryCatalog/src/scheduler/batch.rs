//! Frozen workbench submissions. A catalog writer identity survives reopens, but it does
//! not authorize access to an external directory. The execution host resolves that grant.
mod directory;
mod items;
mod manifest;
mod objects;
use crate::Result;
use manifest::Frozen;
pub use objects::Role;
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::path::Path;
use uuid::Uuid;

const CONTROL: &str = "wb032.control.v1/";
const MANIFEST: &str = "wb032.manifest.v1/";
const CONTROL_SCHEMA: u8 = 2;
pub(crate) const SCHEMA_V10: &str = include_str!("batch/schema_v10.sql");

pub(crate) fn catalog_file_identity(path: &Path) -> Result<Value> {
    directory::catalog_file_identity(path)
}

/// `File::sync_all` is `fcntl(F_FULLFSYNC)` on Apple targets, the expensive call behind the
/// export per-item fixed cost. `RAWMASTER_SYNC_TIMING=1` prints one line per call so a batch can
/// be counted exactly without a profiler.
pub(crate) fn durable_sync(file: &std::fs::File, label: &str) -> Result<()> {
    static TIMING: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    let timing =
        *TIMING.get_or_init(|| std::env::var("RAWMASTER_SYNC_TIMING").as_deref() == Ok("1"));
    let started = timing.then(std::time::Instant::now);
    file.sync_all()?;
    if let Some(started) = started {
        eprintln!(
            "SYNC {label} {:.3}",
            started.elapsed().as_secs_f64() * 1000.0
        );
    }
    Ok(())
}

fn lease_duration() -> u32 {
    90_000
}
fn page_size() -> u32 {
    32
}

#[derive(Deserialize)]
#[serde(untagged)]
pub enum Command {
    Batch(BatchCommand),
    Item(items::Request),
}

#[derive(Deserialize)]
#[serde(
    tag = "action",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum BatchCommand {
    StageResource {
        path: String,
        sha256: String,
        byte_count: i64,
    },
    LoadResource {
        #[serde(rename = "batchID")]
        batch_id: String,
        role: Role,
        ordinal: Option<usize>,
    },
    Register {
        manifest: Value,
        directory: Option<String>,
        #[serde(default = "lease_duration")]
        lease_ms: u32,
    },
    List {
        after: Option<String>,
        #[serde(default = "page_size")]
        limit: u32,
    },
    Load {
        #[serde(rename = "batchID")]
        batch_id: String,
    },
    Begin {
        #[serde(rename = "batchID")]
        batch_id: String,
        expected_generation: u64,
        #[serde(default = "lease_duration")]
        lease_ms: u32,
    },
    Check {
        #[serde(rename = "batchID")]
        batch_id: String,
        generation: u64,
        token: String,
    },
    Renew {
        #[serde(rename = "batchID")]
        batch_id: String,
        generation: u64,
        token: String,
        #[serde(default = "lease_duration")]
        lease_ms: u32,
    },
    Stop {
        #[serde(rename = "batchID")]
        batch_id: String,
        expected_generation: u64,
        reason: StopReason,
        token: Option<String>,
    },
}

#[derive(Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum StopReason {
    Interrupted,
    Cancelled,
}

#[derive(Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
enum Phase {
    Running,
    Interrupted,
    Cancelled,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Control {
    schema: u8,
    #[serde(rename = "batchID")]
    batch_id: String,
    #[serde(rename = "libraryID")]
    library_id: String,
    #[serde(rename = "originWriterID")]
    writer_id: String,
    #[serde(rename = "manifestSHA256")]
    manifest_sha256: String,
    item_count: usize,
    created_at_ms: i64,
    phase: Phase,
    generation: u64,
    lease_until_ms: Option<i64>,
    token_digest: Option<String>,
}

pub(super) fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

#[derive(PartialEq)]
struct Catalog {
    library: String,
    writer: String,
    historical_libraries: BTreeSet<String>,
}

impl Catalog {
    fn read(db: &Connection) -> Result<Self> {
        let identity = db.query_row("SELECT l.value,w.value FROM lc_meta l JOIN metadata w
            ON w.key='deviceID' WHERE l.key='libraryID' AND length(l.value)>0 AND length(w.value)>0", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        }).optional()?;
        let (library, writer) = identity.ok_or("missing catalog library or writer identity")?;
        let mut statement = db.prepare("SELECT substr(key,length('localPackage.historyLibrary.v1/')+1)
            FROM lc_meta WHERE key GLOB 'localPackage.historyLibrary.v1/*' AND value='1'")?;
        let historical_libraries = statement.query_map([], |row| row.get(0))?.collect::<std::result::Result<_, _>>()?;
        Ok(Self { library, writer, historical_libraries })
    }
}

impl Control {
    fn decode(id: &str, value: &str, catalog: &Catalog) -> Result<Self> {
        Self::decode_schema(id, value, catalog, CONTROL_SCHEMA)
    }

    fn decode_schema(id: &str, value: &str, catalog: &Catalog, schema: u8) -> Result<Self> {
        let row: Self = serde_json::from_str(value)?;
        let lease_valid = match row.phase {
            Phase::Running => {
                row.lease_until_ms.is_some_and(|deadline| deadline > 0)
                    && row.token_digest.as_deref().is_some_and(manifest::sha256)
            }
            _ => row.lease_until_ms.is_none() && row.token_digest.is_none(),
        };
        if row.schema != schema
            || row.batch_id != id
            || (row.library_id != catalog.library
                && (row.writer_id == catalog.writer || !catalog.historical_libraries.contains(&row.library_id)))
            || row.writer_id.is_empty()
            || row.generation == 0
            || row.created_at_ms < 0
            || !(1..=manifest::MAX_ITEMS).contains(&row.item_count)
            || !manifest::sha256(&row.manifest_sha256)
            || !lease_valid
        {
            return Err("inconsistent workbench batch control".into());
        }
        Ok(row)
    }
    fn local(&self, catalog: &Catalog) -> Result<()> {
        if !self.is_local(catalog) {
            return Err("workbench batch belongs to a historical catalog writer".into());
        }
        Ok(())
    }
    fn is_local(&self, catalog: &Catalog) -> bool {
        self.library_id == catalog.library && self.writer_id == catalog.writer
    }
    fn active(&self, now: i64) -> bool {
        self.phase == Phase::Running && self.lease_until_ms.is_some_and(|until| until > now)
    }
    fn owner(&self, catalog: &Catalog, generation: u64, token: &str, now: i64) -> Result<()> {
        self.local(catalog)?;
        if self.generation != generation
            || !self.active(now)
            || token.len() != 36
            || self.token_digest.as_deref() != Some(digest(token.as_bytes()).as_str())
        {
            return Err("stale workbench batch lease".into());
        }
        Ok(())
    }
    fn summary(&self, catalog: &Catalog, now: i64) -> Value {
        let phase = if !self.is_local(catalog) {
            "historical"
        } else if self.active(now) {
            "running"
        } else if self.phase == Phase::Cancelled {
            "cancelled"
        } else {
            "interrupted"
        };
        json!({"batchID":self.batch_id,"phase":phase,"generation":self.generation,"itemCount":self.item_count,
            "manifestSHA256":self.manifest_sha256,"createdAtMs":self.created_at_ms,
            "leaseUntilMs":if phase == "running" { self.lease_until_ms } else { None }})
    }
    fn grant(&mut self, now: i64, lease_ms: u32) -> Result<String> {
        let until = super::deadline(now, lease_ms)?;
        self.generation = self
            .generation
            .checked_add(1)
            .ok_or("workbench batch generation exhausted")?;
        let token = Uuid::new_v4().to_string();
        self.phase = Phase::Running;
        self.token_digest = Some(digest(token.as_bytes()));
        self.lease_until_ms = Some(until);
        Ok(token)
    }
}

/// The caller owns the format upgrade's write transaction and has installed the v10 schema.
pub(crate) fn migrate_v9(db: &Connection) -> Result<()> {
    let has_batches: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_meta WHERE key GLOB 'wb032.*')",
        [],
        |row| row.get(0),
    )?;
    if !has_batches {
        return Ok(());
    }
    let catalog = Catalog::read(db)?;
    {
        let mut query = db.prepare("SELECT key,value FROM lc_meta WHERE key GLOB 'wb032.control.v1/*'")?;
        let mut rows = query.query([])?;
        while let Some(row) = rows.next()? {
            let address = row.get_ref(0)?.as_str()?;
            let id = address.strip_prefix(CONTROL).ok_or("invalid workbench control key")?;
            if manifest::id(id)? != id {
                return Err("invalid workbench control identifier".into());
            }
            Control::decode_schema(id, row.get_ref(1)?.as_str()?, &catalog, 1)?;
        }
    }
    db.execute(
        "UPDATE lc_meta SET value=CASE WHEN json_extract(value,'$.phase')='running' THEN
             json_set(value,'$.schema',?1,'$.phase','interrupted','$.leaseUntilMs',NULL,'$.tokenDigest',NULL)
             ELSE json_set(value,'$.schema',?1) END WHERE key GLOB 'wb032.control.v1/*'",
        [CONTROL_SCHEMA],
    )?;
    items::migrate_names(db, &catalog)
}

fn key(prefix: &str, id: &str) -> String {
    format!("{prefix}{id}")
}

fn control(db: &Connection, id: &str, catalog: &Catalog) -> Result<Option<Control>> {
    let (raw, paired): (Option<String>, bool) = db.query_row(
        "SELECT (SELECT value FROM lc_meta WHERE key=?1), EXISTS(SELECT 1 FROM lc_meta WHERE key=?2)",
        params![key(CONTROL,id),key(MANIFEST,id)], |r| Ok((r.get(0)?,r.get(1)?)))?;
    match (raw, paired) {
        (Some(raw), true) => Ok(Some(Control::decode(id, &raw, catalog)?)),
        (None, false) => Ok(None),
        _ => Err("incomplete workbench batch registration".into()),
    }
}

fn require(db: &Connection, id: &str, catalog: &Catalog) -> Result<Control> {
    control(db, id, catalog)?.ok_or_else(|| "unknown workbench batch".into())
}

fn stored_manifest(db: &Connection, row: &Control) -> Result<String> {
    let stored: String = db.query_row(
        "SELECT value FROM lc_meta WHERE key=?1 AND length(CAST(value AS BLOB))<=?2",
        params![key(MANIFEST, &row.batch_id), manifest::MAX_BYTES as i64],
        |r| r.get(0),
    )?;
    if digest(stored.as_bytes()) != row.manifest_sha256 {
        return Err("workbench batch manifest digest mismatch".into());
    }
    Ok(stored)
}

fn save(db: &Connection, row: &Control) -> Result<()> {
    super::changed(db.execute(
        "UPDATE lc_meta SET value=?2 WHERE key=?1",
        params![key(CONTROL, &row.batch_id), serde_json::to_string(row)?],
    )?)?;
    Ok(())
}

fn displayed(db: &Connection, row: &Control, catalog: &Catalog, now: i64) -> Result<Value> {
    let mut summary = row.summary(catalog, now);
    if row.is_local(catalog) && row.phase != Phase::Cancelled && items::done(db, row)? {
        summary["phase"] = "done".into();
    }
    Ok(summary)
}

fn duplicate(
    db: &Connection,
    frozen: &Frozen,
    catalog: &Catalog,
    directory: Option<&directory::Root>,
) -> Result<Option<Value>> {
    let Some(row) = control(db, &frozen.id, catalog)? else {
        return Ok(None);
    };
    if row.manifest_sha256 != frozen.digest || stored_manifest(db, &row)? != frozen.json {
        return Err("batch UUID already has a different immutable manifest".into());
    }
    items::check_duplicate(db, &row, directory)?;
    Ok(Some(
        json!({"batch":displayed(db,&row,catalog,super::now_ms()?)?}),
    ))
}

fn register(
    db: &mut Connection,
    path: &Path,
    mut manifest: Value,
    lease_ms: u32,
    directory: Option<&str>,
) -> Result<Value> {
    let frozen = Frozen::new(&mut manifest, directory.is_some())?;
    // Check the existing catalog writer before opening any external target named by a restored record.
    if directory.is_some() {
        let catalog = Catalog::read(db)?;
        if let Some(row) = control(db, &frozen.id, &catalog)? {
            row.local(&catalog)?;
        }
    }
    let directory = items::open_directory(directory)?;
    super::deadline(super::now_ms()?, lease_ms)?;
    let (origin, verified) = if frozen.objects.is_some() || directory.is_some() {
        let read = db.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let origin = Catalog::read(&read)?;
        if origin.library != frozen.library_id {
            return Err("workbench submission belongs to another library".into());
        }
        if let Some(reply) = duplicate(&read, &frozen, &origin, directory.as_ref())? {
            return Ok(reply);
        }
        read.commit()?;
        let verified = match &frozen.objects {
            Some(set) => set.verify(path)?,
            None => Vec::new(),
        };
        (Some(origin), verified)
    } else {
        (None, Vec::new())
    };
    let encoded_target = directory
        .as_ref()
        .map(|root| -> Result<_> {
            let hint = items::directory_hint(&manifest)?.to_path_buf();
            let encoded = items::encode_target(
                &manifest,
                &frozen.digest,
                root,
                verified.iter().find_map(|object| object.extension),
            )?;
            Ok((encoded, hint))
        })
        .transpose()?;
    drop(manifest);
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let catalog = Catalog::read(&tx)?;
    if frozen.library_id != catalog.library
        || origin.as_ref().is_some_and(|initial| initial != &catalog)
    {
        return Err("workbench submission belongs to another library".into());
    }
    if let Some(reply) = duplicate(&tx, &frozen, &catalog, directory.as_ref())? {
        return Ok(reply);
    }
    for object in &verified {
        object.register(&tx)?;
    }
    let now = super::now_ms()?;
    let mut row = Control {
        schema: CONTROL_SCHEMA,
        batch_id: frozen.id,
        library_id: frozen.library_id,
        writer_id: catalog.writer.clone(),
        manifest_sha256: frozen.digest,
        item_count: frozen.count,
        created_at_ms: now,
        phase: Phase::Interrupted,
        generation: 0,
        lease_until_ms: None,
        token_digest: None,
    };
    let token = row.grant(now, lease_ms)?;
    if let (Some(root), Some((encoded, hint))) = (&directory, encoded_target.as_ref()) {
        // The first grant and its frozen hint may have entered through different aliases.
        root.verify_hint(hint)?;
        items::store_target(&tx, &row, root, encoded)?;
    }
    tx.execute(
        "INSERT INTO lc_meta(key,value) VALUES(?1,?2),(?3,?4)",
        params![
            key(MANIFEST, &row.batch_id),
            frozen.json,
            key(CONTROL, &row.batch_id),
            serde_json::to_string(&row)?
        ],
    )?;
    tx.commit()?;
    Ok(json!({"batch":row.summary(&catalog,super::now_ms()?),"token":token}))
}

fn list(
    db: &Connection,
    catalog: &Catalog,
    after: Option<String>,
    limit: u32,
    now: i64,
) -> Result<Value> {
    if !(1..=64).contains(&limit) {
        return Err("workbench batch page size must be 1 to 64".into());
    }
    let cursor = after
        .as_deref()
        .map(manifest::id)
        .transpose()?
        .unwrap_or_default();
    // The prefix and the cursor constrain the primary key without scanning manifest values.
    let mut query = db.prepare("SELECT c.key,c.value,EXISTS(SELECT 1 FROM lc_meta m WHERE m.key=?3||substr(c.key,length(?4)+1))
        FROM lc_meta c WHERE c.key>?1 AND c.key GLOB ?5 ORDER BY c.key LIMIT ?2")?;
    let mut rows = query.query(params![
        key(CONTROL, &cursor),
        limit + 1,
        MANIFEST,
        CONTROL,
        format!("{CONTROL}*")
    ])?;
    let mut entries = Vec::new();
    let mut last = None;
    while let Some(row) = rows.next()? {
        if entries.len() == limit as usize {
            return Ok(json!({"batches":entries,"nextAfter":last}));
        }
        let address = row.get_ref(0)?.as_str()?;
        let id = address
            .strip_prefix(CONTROL)
            .ok_or("invalid workbench control key")?;
        if !row.get::<_, bool>(2)? || manifest::id(id)? != id {
            return Err("incomplete workbench batch registration".into());
        }
        let header = Control::decode(id, row.get_ref(1)?.as_str()?, catalog)?;
        last = Some(id.to_owned());
        entries.push(displayed(db, &header, catalog, now)?);
    }
    Ok(json!({"batches":entries,"nextAfter":null}))
}

/// A publication host can call this check inside its existing SQLite write transaction.
/// Filesystem access also requires proof from the originating machine's directory grant.
pub fn check(db: &Connection, batch_id: &str, generation: u64, token: &str) -> Result<()> {
    // A deferred read snapshot can outlive a newer cancellation on another connection.
    // The borrowed SQLite handle is valid here and the file name is a static C string.
    let state = unsafe { rusqlite::ffi::sqlite3_txn_state(db.handle(), c"main".as_ptr()) };
    if state != rusqlite::ffi::SQLITE_TXN_WRITE {
        return Err("a host write transaction is required for a workbench batch fence".into());
    }
    let catalog = Catalog::read(db)?;
    require(db, &manifest::id(batch_id)?, &catalog)?.owner(
        &catalog,
        generation,
        token,
        super::now_ms()?,
    )
}

fn resumable(row: &Control, catalog: &Catalog, generation: u64) -> Result<()> {
    row.local(catalog)?;
    if row.generation != generation || row.phase == Phase::Cancelled || row.active(super::now_ms()?)
    {
        return Err("workbench batch cannot resume this generation".into());
    }
    Ok(())
}

fn begin(
    db: &mut Connection,
    path: &Path,
    id: &str,
    generation: u64,
    lease_ms: u32,
) -> Result<Value> {
    let id = manifest::id(id)?;
    super::deadline(super::now_ms()?, lease_ms)?;
    let read = db.transaction_with_behavior(TransactionBehavior::Deferred)?;
    let origin = Catalog::read(&read)?;
    let previous = require(&read, &id, &origin)?;
    if items::done(&read, &previous)? {
        return Err("workbench batch is already complete".into());
    }
    resumable(&previous, &origin, generation)?;
    let stored = stored_manifest(&read, &previous)?;
    read.commit()?;
    let raw: Value = serde_json::from_str(&stored)?;
    let verified = match raw["schema"].as_u64() {
        Some(1) => Vec::new(),
        Some(2) => objects::Set::new(&raw["configuration"], &raw["items"])?.verify(path)?,
        _ => return Err("unsupported frozen workbench schema".into()),
    };
    let write = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let catalog = Catalog::read(&write)?;
    let mut row = require(&write, &id, &catalog)?;
    if items::done(&write, &row)? {
        return Err("workbench batch is already complete".into());
    }
    resumable(&row, &catalog, generation)?;
    if origin != catalog
        || previous.manifest_sha256 != row.manifest_sha256
        || !write.query_row(
            "SELECT EXISTS(SELECT 1 FROM lc_meta WHERE key=?1 AND value=?2)",
            params![key(MANIFEST, &id), stored],
            |r| r.get::<_, bool>(0),
        )?
    {
        return Err("workbench batch changed during resource verification".into());
    }
    for object in &verified {
        object.check(&write)?;
    }
    let token = row.grant(super::now_ms()?, lease_ms)?;
    save(&write, &row)?;
    write.commit()?;
    Ok(json!({"batch":row.summary(&catalog,super::now_ms()?),"token":token}))
}

fn load_resource(
    db: &mut Connection,
    path: &Path,
    id: &str,
    role: Role,
    ordinal: Option<usize>,
) -> Result<Value> {
    let id = manifest::id(id)?;
    let read = db.transaction_with_behavior(TransactionBehavior::Deferred)?;
    let catalog = Catalog::read(&read)?;
    let row = require(&read, &id, &catalog)?;
    row.local(&catalog)?;
    let raw: Value = serde_json::from_str(&stored_manifest(&read, &row)?)?;
    if raw["schema"] != 2 {
        return Err("workbench batch has no external input objects".into());
    }
    let set = objects::Set::new(&raw["configuration"], &raw["items"])?;
    read.commit()?;
    let body = set.load(db, path, role, ordinal)?;
    if Catalog::read(db)? != catalog {
        return Err("catalog writer changed while loading the workbench resource".into());
    }
    Ok(json!({"body":body}))
}

pub(super) fn execute(db: &mut Connection, path: &Path, command: Command) -> Result<Value> {
    let command = match command {
        Command::Item(item) => return item.execute(db),
        Command::Batch(batch) => batch,
    };
    use BatchCommand::*;
    match command {
        StageResource {
            path: input,
            sha256,
            byte_count,
        } => {
            Catalog::read(db)?;
            return objects::stage(path, Path::new(&input), sha256, byte_count);
        }
        LoadResource {
            batch_id,
            role,
            ordinal,
        } => return load_resource(db, path, &batch_id, role, ordinal),
        Begin {
            batch_id,
            expected_generation,
            lease_ms,
        } => return begin(db, path, &batch_id, expected_generation, lease_ms),
        Register {
            manifest,
            lease_ms,
            directory,
        } => return register(db, path, manifest, lease_ms, directory.as_deref()),
        _ => (),
    }
    let behavior = match command {
        List { .. } | Load { .. } | Check { .. } => TransactionBehavior::Deferred,
        _ => TransactionBehavior::Immediate,
    };
    let tx = db.transaction_with_behavior(behavior)?;
    let catalog = Catalog::read(&tx)?;
    let now = super::now_ms()?;
    if let List { after, limit } = command {
        return list(&tx, &catalog, after, limit, now);
    }
    let id = match &command {
        Load { batch_id }
        | Check { batch_id, .. }
        | Renew { batch_id, .. }
        | Stop { batch_id, .. } => manifest::id(batch_id)?,
        Register { .. }
        | List { .. }
        | Begin { .. }
        | StageResource { .. }
        | LoadResource { .. } => unreachable!(),
    };
    if let Load { .. } = command {
        let Some(row) = control(&tx, &id, &catalog)? else {
            return Ok(Value::Null);
        };
        let stored = stored_manifest(&tx, &row)?;
        let manifest = if row.is_local(&catalog) {
            serde_json::from_str(&stored)?
        } else {
            Value::Null
        };
        return Ok(json!({"batch":displayed(&tx,&row,&catalog,now)?,"manifest":manifest}));
    }
    let mut row = require(&tx, &id, &catalog)?;
    row.local(&catalog)?;
    if items::done(&tx, &row)? {
        return Err("workbench batch is already complete".into());
    }
    match command {
        Check {
            generation, token, ..
        } => {
            let checked_at = super::now_ms()?;
            row.owner(&catalog, generation, &token, checked_at)?;
            return Ok(json!({"batch":row.summary(&catalog,checked_at)}));
        }
        Renew {
            generation,
            token,
            lease_ms,
            ..
        } => {
            let renewed_at = super::now_ms()?;
            row.owner(&catalog, generation, &token, renewed_at)?;
            row.lease_until_ms = Some(super::deadline(renewed_at, lease_ms)?);
        }
        Stop {
            expected_generation,
            reason,
            token,
            ..
        } => {
            if row.generation != expected_generation {
                return Err("stale workbench batch generation".into());
            }
            match reason {
                StopReason::Interrupted => {
                    row.owner(
                        &catalog,
                        expected_generation,
                        token.as_deref().ok_or("missing workbench batch token")?,
                        super::now_ms()?,
                    )?;
                    row.phase = Phase::Interrupted;
                }
                StopReason::Cancelled => {
                    if token.is_some() {
                        return Err("cancelling a batch is an explicit catalog action".into());
                    }
                    if row.phase == Phase::Cancelled {
                        return Ok(json!({"batch":row.summary(&catalog,now)}));
                    }
                    row.phase = Phase::Cancelled;
                }
            }
            row.token_digest = None;
            row.lease_until_ms = None;
        }
        _ => unreachable!(),
    }
    save(&tx, &row)?;
    tx.commit()?;
    Ok(json!({"batch":row.summary(&catalog,super::now_ms()?)}))
}
