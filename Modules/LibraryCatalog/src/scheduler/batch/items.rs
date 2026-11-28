//! A workbench item is deliberately absent from lc_task_jobs. Old v9 generic claimants cannot
//! acquire it. Each durable transition is tied to the registered catalog writer and manifest.
use super::{
    directory::{Binding, Final, Root, Stage, Ticket},
    manifest, Catalog, Control, Phase,
};
use crate::Result;
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::Path;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

const TARGET: &str = "wb032.target.v1/";
const ITEM: &str = "wb032.item.v1/";
const DONE: &str = "wb032.done.v1/";
const NAME: &str = "wb032.name.v1/";
const MAX_ATTEMPTS: u32 = 8;

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Operation {
    Items,
    CheckDirectory,
    ClaimItem,
    RenewItem,
    PrepareItem,
    PublishItem,
    AcknowledgeItem,
    SkipItem,
    FailItem,
    FinishBatch,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    action: Operation,
    #[serde(rename = "batchID")]
    batch_id: String,
    ordinal: Option<usize>,
    generation: Option<u64>,
    token: Option<String>,
    item_token: Option<String>,
    lease_ms: Option<u32>,
    directory: Option<String>,
    stage: Option<String>,
    suffix: Option<u32>,
    reason: Option<String>,
    scene_execution: Option<SceneExecution>,
}

#[derive(Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SceneExecution {
    backend: SceneBackend,
    tiles: u64,
    nodes: u64,
    dispatches: u64,
    coverage_cache_hits: u64,
    node_cache_hits: u64,
    peak_bytes: u64,
    budget_bytes: u64,
    cpu_milliseconds: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    fallback_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    photographic_engine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    dag_backend: Option<SceneBackend>,
}

#[derive(Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
enum SceneBackend {
    Rust,
    Wgpu,
    Swift,
    SwiftFallback,
    Mixed,
    Passthrough,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Target {
    manifest_sha256: String,
    binding: Binding,
    extension: String,
    collision: String,
    stems: Vec<String>,
}

pub(super) fn open_directory(path: Option<&str>) -> Result<Option<Root>> {
    path.map(|path| Root::open(Path::new(path))).transpose()
}
pub(super) fn directory_hint(manifest: &Value) -> Result<&Path> {
    manifest["destination"]["pathHint"]
        .as_str()
        .map(Path::new)
        .ok_or_else(|| "missing workbench path hint".into())
}
pub(super) fn encode_target(
    manifest: &Value,
    digest: &str,
    root: &Root,
    verified_extension: Option<&str>,
) -> Result<String> {
    let extension = if manifest["schema"] == 1 {
        manifest::extension(manifest["configuration"]["format"].as_str())
    } else {
        verified_extension
    };
    let target = Target {
        manifest_sha256: digest.into(),
        binding: root.binding.clone(),
        extension: extension.ok_or("unsupported frozen output format")?.into(),
        collision: manifest["collision"]
            .as_str()
            .ok_or("missing collision policy")?
            .into(),
        stems: manifest["items"]
            .as_array()
            .ok_or("missing workbench items")?
            .iter()
            .map(|i| {
                i["stem"]
                    .as_str()
                    .map(str::to_owned)
                    .ok_or("missing literal stem")
            })
            .collect::<std::result::Result<_, _>>()?,
    };
    Ok(serde_json::to_string(&target)?)
}
pub(super) fn store_target(
    db: &Connection,
    row: &Control,
    root: &Root,
    encoded: &str,
) -> Result<()> {
    root.recheck()?;
    insert(db, &super::key(TARGET, &row.batch_id), encoded)
}
fn target(db: &Connection, parent: &Control) -> Result<Option<Target>> {
    let data: Option<String> = db
        .query_row(
            "SELECT value FROM lc_meta WHERE key=?1",
            [super::key(TARGET, &parent.batch_id)],
            |r| r.get(0),
        )
        .optional()?;
    let Some(data) = data else { return Ok(None) };
    let plan: Target = serde_json::from_str(&data)?;
    if plan.manifest_sha256 != parent.manifest_sha256
        || plan.stems.len() != parent.item_count
        || !matches!(plan.extension.as_str(), "jpg" | "tiff" | "png" | "avif")
        || !matches!(plan.collision.as_str(), "skip" | "rename")
        || !plan.stems.iter().all(|s| manifest::literal_stem(s))
    {
        return Err("inconsistent workbench delivery plan".into());
    }
    Ok(Some(plan))
}
pub(super) fn check_duplicate(db: &Connection, row: &Control, root: Option<&Root>) -> Result<()> {
    let saved = target(db, row)?;
    match (saved, root) {
        (None, None) => (),
        (Some(saved), Some(root)) if root.matches(&saved.binding) => root.recheck()?,
        _ => return Err("batch has a different original directory binding".into()),
    }
    Ok(())
}
fn insert(db: &Connection, key: &str, value: &str) -> Result<()> {
    db.execute(
        "INSERT INTO lc_meta(key,value) VALUES(?1,?2)",
        params![key, value],
    )?;
    Ok(())
}
pub(super) fn done(db: &Connection, row: &Control) -> Result<bool> {
    let digest: Option<String> = db
        .query_row(
            "SELECT value FROM lc_meta WHERE key=?1",
            [super::key(DONE, &row.batch_id)],
            |r| r.get(0),
        )
        .optional()?;
    if digest.as_ref().is_some_and(|s| s != &row.manifest_sha256) {
        return Err("invalid workbench completion marker".into());
    }
    Ok(digest.is_some())
}

#[derive(Clone, Copy, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
enum State {
    Pending,
    Running,
    Prepared,
    Delivered,
    Skipped,
    Failed,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Item {
    ordinal: usize,
    manifest_sha256: String,
    state: State,
    generation: u64,
    attempt: u32,
    lease_until: Option<i64>,
    token_digest: Option<String>,
    ticket: Option<Ticket>,
    #[serde(skip_serializing_if = "Option::is_none")]
    scene_execution: Option<SceneExecution>,
    skipped_name: Option<String>,
    reason: Option<String>,
}
impl Item {
    fn load(db: &Connection, row: &Control, n: usize) -> Result<Self> {
        if n == 0 || n > row.item_count {
            return Err("workbench item ordinal out of range".into());
        }
        let raw: Option<String> = db
            .query_row(
                "SELECT value FROM lc_meta WHERE key=?1",
                [item_key(&row.batch_id, n)],
                |r| r.get(0),
            )
            .optional()?;
        let Some(raw) = raw else {
            return Ok(Self {
                ordinal: n,
                manifest_sha256: row.manifest_sha256.clone(),
                state: State::Pending,
                generation: 0,
                attempt: 0,
                lease_until: None,
                token_digest: None,
                ticket: None,
                scene_execution: None,
                skipped_name: None,
                reason: None,
            });
        };
        Self::persisted(&raw, row, n)
    }
    fn persisted(raw: &str, row: &Control, n: usize) -> Result<Self> {
        let item: Self = serde_json::from_str(raw)?;
        if item.ordinal != n
            || item.manifest_sha256 != row.manifest_sha256
            || item.attempt == 0
            || item.attempt > MAX_ATTEMPTS
            || item.generation > row.generation
            || matches!(item.state, State::Prepared | State::Delivered) != item.ticket.is_some()
            || (item.scene_execution.is_some() && item.ticket.is_none())
            || (item.state == State::Skipped) != item.skipped_name.is_some()
            || item.lease_until.is_some() != item.token_digest.is_some()
            || item
                .token_digest
                .as_deref()
                .is_some_and(|s| !manifest::sha256(s))
        {
            return Err("inconsistent persisted workbench item".into());
        }
        Ok(item)
    }
    fn save(&self, db: &Connection, parent: &Control) -> Result<()> {
        db.execute("INSERT INTO lc_meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![item_key(&parent.batch_id,self.ordinal),serde_json::to_string(self)?])?;
        Ok(())
    }
    fn terminal(&self) -> bool {
        matches!(self.state, State::Delivered | State::Skipped)
    }
    fn clear(&mut self) {
        self.lease_until = None;
        self.token_digest = None;
    }
    fn live(&self, parent: &Control, now: i64) -> bool {
        self.generation == parent.generation
            && parent.active(now)
            && self.lease_until.is_some_and(|t| t > now)
    }
    fn owner(&self, parent: &Control, token: Option<&str>, now: i64) -> Result<()> {
        let secret = token.ok_or("missing workbench item token")?;
        if secret.len() != 36
            || !self.live(parent, now)
            || self.token_digest.as_deref() != Some(super::digest(secret.as_bytes()).as_str())
        {
            return Err("expired or replaced workbench item token".into());
        }
        Ok(())
    }
    fn view(&self, parent: &Control, now: i64) -> Value {
        let state = if self.terminal() {
            self.state
        } else if self.ticket.is_some() {
            State::Prepared
        } else if parent.phase == Phase::Cancelled {
            return json!({"ordinal":self.ordinal,"state":"cancelled","attempt":self.attempt,"generation":self.generation});
        } else if self.state == State::Running && !self.live(parent, now) {
            State::Pending
        } else {
            self.state
        };
        let mut reply = json!({"ordinal":self.ordinal,"state":state,"attempt":self.attempt,"generation":self.generation,
            "filename":self.ticket.as_ref().map(|t|&t.filename).or(self.skipped_name.as_ref()),"sha256":self.ticket.as_ref().map(|t|&t.sha256),
            "byteCount":self.ticket.as_ref().map(|t|t.byte_count),"reason":self.reason});
        if let Some(execution) = &self.scene_execution {
            reply["sceneExecution"] = json!(execution);
        }
        reply
    }
}

fn item_key(id: &str, n: usize) -> String {
    format!("{ITEM}{id}/{n:03}")
}
fn normalized_name(name: &str) -> String {
    name.nfc().collect::<String>().to_lowercase()
}

// The enclosing v9 → v10 transaction already validated and upgraded the batch controls.
// Walk physical item rows, including other writers' restored history. Nothing is opened on disk.
pub(super) fn migrate_names(db: &Connection, catalog: &Catalog) -> Result<()> {
    if db.is_autocommit() {
        return Err("name migration requires the catalog upgrade transaction".into());
    }
    let mut items =
        db.prepare("SELECT key FROM lc_meta WHERE key GLOB 'wb032.item.v1/*' ORDER BY key")?;
    let mut rows = items.query([])?;
    let mut cached: Option<(Control, Target)> = None;
    let mut migrated = 0_i64;
    while let Some(row) = rows.next()? {
        let address = row.get_ref(0)?.as_str()?;
        let (id, number) = address
            .strip_prefix(ITEM)
            .and_then(|s| s.split_once('/'))
            .ok_or("invalid old workbench item key")?;
        let ordinal: usize = number.parse()?;
        if manifest::id(id)? != id || item_key(id, ordinal) != address {
            return Err("invalid old workbench item key".into());
        }
        if cached
            .as_ref()
            .is_none_or(|(parent, _)| parent.batch_id != id)
        {
            let parent = super::require(db, id, catalog)?;
            let plan = target(db, &parent)?.ok_or("old workbench item has no directory binding")?;
            let frozen: Value = serde_json::from_str(&super::stored_manifest(db, &parent)?)?;
            let entries = frozen["items"]
                .as_array()
                .ok_or("missing frozen workbench items")?;
            if frozen["batchID"] != parent.batch_id
                || frozen["collision"] != plan.collision
                || entries.len() != plan.stems.len()
                || entries
                    .iter()
                    .zip(&plan.stems)
                    .enumerate()
                    .any(|(i, (entry, stem))| {
                        entry["ordinal"].as_u64() != Some(i as u64 + 1)
                            || entry["stem"].as_str() != Some(stem.as_str())
                    })
            {
                return Err("old workbench target does not match the frozen batch".into());
            }
            cached = Some((parent, plan));
        }
        let (parent, plan) = cached.as_ref().unwrap();
        let item = Item::load(db, parent, ordinal)?;
        if item.state != State::Prepared {
            continue;
        }
        let ticket = item
            .ticket
            .as_ref()
            .ok_or("old prepared workbench item lacks a ticket")?;
        ticket.validate_legacy(&plan.binding, &plan.extension)?;
        plan.check_name(ordinal, &ticket.filename)?;
        let name = normalized_name(&ticket.filename);
        let slot = super::key(
            NAME,
            &plan.binding.legacy_name_digest(&parent.writer_id, &name)?,
        );
        let original: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM lc_meta WHERE key=?1 AND value=?2)",
            params![slot, address],
            |r| r.get(0),
        )?;
        if !original {
            return Err("old workbench ticket lacks its exact original reservation".into());
        }
        db.execute("INSERT INTO lc_workbench_names(item_key,writer_id,directory_scope,normalized_name,volume_uuid)
            VALUES(?1,?2,?3,?4,NULL)",params![address,parent.writer_id,plan.binding.scope()?,name])?;
        migrated += 1;
    }
    // Each proved slot has one distinct owner and each prepared item has exactly one slot.
    // Counting the entire namespace also rejects alternate keys, orphans and delivered owners.
    let old_count: i64 = db.query_row(
        "SELECT count(*) FROM lc_meta WHERE key GLOB 'wb032.name.v1/*'",
        [],
        |r| r.get(0),
    )?;
    if old_count != migrated {
        return Err("unexpected old workbench name reservation".into());
    }
    db.execute("DELETE FROM lc_meta WHERE key GLOB 'wb032.name.v1/*'", [])?;
    Ok(())
}

fn finish_if_terminal(db: &Connection, parent: &mut Control) -> Result<bool> {
    if done(db, parent)? {
        return Ok(true);
    }
    let pattern = format!("{ITEM}{}/*", parent.batch_id);
    // Unclaimed items have no row. A covering key scan avoids reading their neighbors' JSON.
    let count: i64 = db.query_row(
        "SELECT count(*) FROM lc_meta WHERE key GLOB ?1",
        [&pattern],
        |row| row.get(0),
    )?;
    let expected = parent.item_count as i64;
    if count < expected {
        return Ok(false);
    }
    if count > expected {
        return Err("unexpected workbench item keys at completion".into());
    }
    let mut items = db.prepare("SELECT key,value FROM lc_meta WHERE key GLOB ?1 ORDER BY key")?;
    let mut rows = items.query([&pattern])?;
    // Keys are ordered by the three-digit ordinals of the registered batch (at most 200).
    let mut terminal = true;
    for ordinal in 1..=parent.item_count {
        let row = rows.next()?.ok_or("missing workbench item at completion")?;
        if row.get_ref(0)?.as_str()? != item_key(&parent.batch_id, ordinal) {
            return Err("unexpected workbench item key at completion".into());
        }
        terminal &= Item::persisted(row.get_ref(1)?.as_str()?, parent, ordinal)?.terminal();
    }
    if !terminal {
        return Ok(false);
    }
    insert(
        db,
        &super::key(DONE, &parent.batch_id),
        &parent.manifest_sha256,
    )?;
    if parent.phase != Phase::Cancelled {
        parent.phase = Phase::Interrupted;
        parent.token_digest = None;
        parent.lease_until_ms = None;
        super::save(db, parent)?;
    }
    Ok(true)
}

struct Context {
    catalog: Catalog,
    parent: Control,
    target: Target,
    item: Item,
}
impl Context {
    fn load(db: &Connection, id: &str, ordinal: usize) -> Result<Self> {
        let catalog = Catalog::read(db)?;
        let parent = super::require(db, id, &catalog)?;
        parent.local(&catalog)?;
        let target =
            target(db, &parent)?.ok_or("batch has no originally registered workbench directory")?;
        let item = Item::load(db, &parent, ordinal)?;
        let ctx = Self {
            catalog,
            parent,
            target,
            item,
        };
        if let Some(filename) = ctx
            .item
            .ticket
            .as_ref()
            .map(|t| &t.filename)
            .or(ctx.item.skipped_name.as_ref())
        {
            ctx.target.check_name(ctx.item.ordinal, filename)?;
        }
        Ok(ctx)
    }
    fn name_taken(&self, db: &Connection, root: &Root, name: &str) -> Result<bool> {
        let scope = self.target.binding.scope()?;
        Ok(db.query_row(
            "SELECT EXISTS(SELECT 1 FROM lc_workbench_names WHERE writer_id=?1 AND directory_scope=?2
             AND normalized_name=?3 AND (volume_uuid IS NULL OR ?4 IS NULL OR volume_uuid=?4) AND item_key<>?5)",
            params![self.parent.writer_id,scope,normalized_name(name),root.volume_uuid(),item_key(&self.parent.batch_id,self.item.ordinal)],
            |r| r.get(0))?)
    }
    fn reserve(&self, db: &Connection, root: &Root, name: &str) -> Result<()> {
        db.execute("INSERT INTO lc_workbench_names(item_key,writer_id,directory_scope,normalized_name,volume_uuid)
            VALUES(?1,?2,?3,?4,?5)",
            params![item_key(&self.parent.batch_id,self.item.ordinal),self.parent.writer_id,
                self.target.binding.scope()?,normalized_name(name),root.volume_uuid()])?;
        Ok(())
    }
    fn require_reservation(&self, db: &Connection, root: &Root, name: &str) -> Result<()> {
        let owns: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM lc_workbench_names
            WHERE item_key=?1 AND writer_id=?2 AND directory_scope=?3 AND normalized_name=?4
              AND (volume_uuid IS NULL OR volume_uuid=?5))",
            params![
                item_key(&self.parent.batch_id, self.item.ordinal),
                self.parent.writer_id,
                self.target.binding.scope()?,
                normalized_name(name),
                root.volume_uuid()
            ],
            |r| r.get(0),
        )?;
        if !owns {
            return Err("workbench ticket lost its original name reservation".into());
        }
        Ok(())
    }
    fn name(&self, suffix: u32) -> Result<String> {
        self.target.name(self.item.ordinal, suffix)
    }
}
impl Target {
    fn check_name(&self, ordinal: usize, filename: &str) -> Result<()> {
        let base = filename
            .strip_suffix(&format!(".{}", self.extension))
            .ok_or("workbench ticket changed output format")?;
        let stem = &self.stems[ordinal - 1];
        let suffix = if base == stem {
            1
        } else {
            let n = base
                .strip_prefix(stem)
                .and_then(|rest| rest.strip_prefix('-'))
                .ok_or("workbench ticket changed the frozen stem")?
                .parse::<u32>()?;
            if n < 2 {
                return Err("invalid workbench ticket filename suffix".into());
            }
            n
        };
        if self.name(ordinal, suffix)? != filename {
            return Err("invalid frozen workbench ticket filename".into());
        }
        Ok(())
    }
    fn name(&self, ordinal: usize, suffix: u32) -> Result<String> {
        let stem = &self.stems[ordinal - 1];
        let name = match suffix {
            0 => return Err("invalid workbench filename suffix".into()),
            1 => stem.clone(),
            _ if self.collision == "rename" => format!("{stem}-{suffix}"),
            _ => return Err("invalid suffix for skip policy".into()),
        };
        if suffix > 1 {
            let candidate = normalized_name(&name);
            if self.stems.iter().any(|s| normalized_name(s) == candidate) {
                return Err("filename reserved by another frozen item".into());
            }
        }
        let name = format!("{name}.{}", self.extension);
        if name.len() > 255 {
            return Err("workbench filename exceeds filesystem component limit".into());
        }
        Ok(name)
    }
}

impl Request {
    fn parent(&self, context: &Context, now: i64) -> Result<()> {
        context.parent.owner(
            &context.catalog,
            self.generation.ok_or("missing workbench generation")?,
            self.token.as_deref().ok_or("missing workbench token")?,
            now,
        )
    }
    fn owners(&self, context: &Context, now: i64) -> Result<()> {
        self.parent(context, now)?;
        context
            .item
            .owner(&context.parent, self.item_token.as_deref(), now)
    }
    fn root(&self, context: &Context) -> Result<Root> {
        Root::authorize(
            Path::new(
                self.directory
                    .as_deref()
                    .ok_or("missing authorized workbench directory")?,
            ),
            &context.target.binding,
        )
    }
    fn list(&self, db: &mut Connection, id: &str) -> Result<Value> {
        let tx = db.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let catalog = Catalog::read(&tx)?;
        let row = super::require(&tx, id, &catalog)?;
        let historical = !row.is_local(&catalog);
        let available = !historical && target(&tx, &row)?.is_some();
        let now = super::super::now_ms()?;
        let entries = if available {
            (1..=row.item_count)
                .map(|n| Ok(Item::load(&tx, &row, n)?.view(&row, now)))
                .collect::<Result<Vec<_>>>()?
        } else if historical {
            let entries = (1..=row.item_count)
                .map(|n| Item::load(&tx, &row, n))
                .collect::<Result<Vec<_>>>()?;
            entries.into_iter().filter(Item::terminal).map(|item| item.view(&row, now)).collect()
        } else {
            vec![]
        };
        let complete = done(&tx, &row)?;
        Ok(json!({"available":available,"complete":complete,"items":entries}))
    }
    fn claim_item(&self, db: &mut Connection, id: &str, ordinal: usize) -> Result<Value> {
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut ctx = Context::load(&tx, id, ordinal)?;
        let now = super::super::now_ms()?;
        self.parent(&ctx, now)?;
        let until =
            super::super::deadline(now, self.lease_ms.unwrap_or_else(super::lease_duration))?;
        let mut reply = json!({});
        if !ctx.item.terminal() && !ctx.item.live(&ctx.parent, now) {
            if ctx.item.generation != ctx.parent.generation {
                ctx.item.attempt = 0;
            } else if ctx.item.reason.is_some() || ctx.item.attempt >= MAX_ATTEMPTS {
                return Err("explicit new workbench generation required to retry".into());
            }
            let token = Uuid::new_v4().to_string();
            ctx.item.generation = ctx.parent.generation;
            ctx.item.attempt += 1;
            ctx.item.state = if ctx.item.ticket.is_some() {
                State::Prepared
            } else {
                State::Running
            };
            ctx.item.token_digest = Some(super::digest(token.as_bytes()));
            ctx.item.lease_until = Some(until);
            ctx.item.reason = None;
            ctx.item.save(&tx, &ctx.parent)?;
            reply["itemToken"] = token.into();
        }
        reply["item"] = ctx.item.view(&ctx.parent, now);
        tx.commit()?;
        Ok(reply)
    }
    pub(super) fn execute(self, db: &mut Connection) -> Result<Value> {
        use Operation::*;
        let id = manifest::id(&self.batch_id)?;
        if matches!(self.action, Items) {
            return self.list(db, &id);
        }
        let ordinal = if matches!(self.action, FinishBatch | CheckDirectory) {
            1
        } else {
            self.ordinal.ok_or("missing workbench ordinal")?
        };
        if matches!(self.action, ClaimItem) {
            // Claim has no filesystem work between authorization and the write.
            return self.claim_item(db, &id, ordinal);
        }
        let read = db.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let snapshot = Context::load(&read, &id, ordinal)?;
        if matches!(self.action, CheckDirectory) {
            self.root(&snapshot)?.recheck()?;
            return Ok(json!({"valid":true}));
        }
        let now = super::super::now_ms()?;
        if !matches!(self.action, AcknowledgeItem)
            && !(matches!(self.action, FinishBatch) && done(&read, &snapshot.parent)?)
        {
            if matches!(self.action, FinishBatch) {
                self.parent(&snapshot, now)?;
            } else {
                self.owners(&snapshot, now)?;
            }
        }
        read.commit()?;
        // All content hashing and file synchronization for preparation and ACK precede BEGIN IMMEDIATE.
        let root = if matches!(
            self.action,
            PrepareItem | PublishItem | AcknowledgeItem | SkipItem
        ) {
            Some(self.root(&snapshot)?)
        } else {
            None
        };
        let verified = if matches!(self.action, AcknowledgeItem | PublishItem) {
            snapshot
                .item
                .ticket
                .as_ref()
                .map(|t| t.verify_final(root.as_ref().unwrap()))
                .transpose()?
        } else {
            None
        };
        let stage = match self.action {
            PrepareItem => Some(Stage::read(
                root.as_ref().unwrap(),
                self.stage.as_deref().ok_or("missing workbench stage")?,
                snapshot.name(self.suffix.ok_or("missing workbench filename suffix")?)?,
                &snapshot.target.extension,
                snapshot.item.ticket.is_none(),
                true,
            )?),
            PublishItem if matches!(verified, Some(Final::Missing)) => Stage::from_ticket(
                root.as_ref().unwrap(),
                snapshot
                    .item
                    .ticket
                    .as_ref()
                    .ok_or("item has no prepared ticket")?,
                &snapshot.target.extension,
            )?,
            _ => None,
        };
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut ctx = Context::load(&tx, &id, ordinal)?;
        let now = super::super::now_ms()?;
        if ctx.catalog != snapshot.catalog
            || ctx.target.binding != snapshot.target.binding
            || ctx.parent.manifest_sha256 != snapshot.parent.manifest_sha256
        {
            return Err("workbench binding changed".into());
        }
        if let Some(root) = &root {
            root.recheck()?;
        }
        let mut reply = json!({});
        match self.action {
            RenewItem => {
                self.owners(&ctx, now)?;
                ctx.item.lease_until = Some(super::super::deadline(
                    now,
                    self.lease_ms.unwrap_or_else(super::lease_duration),
                )?);
                ctx.item.save(&tx, &ctx.parent)?;
            }
            PrepareItem => {
                self.owners(&ctx, now)?;
                let root = root.as_ref().unwrap();
                let stage = stage.as_ref().unwrap();
                stage.check(root)?;
                if let Some(ticket) = &ctx.item.ticket {
                    ctx.require_reservation(&tx, root, &ticket.filename)?;
                    if ticket != &stage.ticket || ctx.item.scene_execution != self.scene_execution {
                        return Err("a prepared workbench item cannot be retargeted".into());
                    }
                } else if root.occupied(&stage.ticket.filename)?
                    || ctx.name_taken(&tx, root, &stage.ticket.filename)?
                {
                    reply["status"] = "destinationExists".into();
                } else {
                    self.owners(&ctx, super::super::now_ms()?)?;
                    ctx.reserve(&tx, root, &stage.ticket.filename)?;
                    ctx.item.ticket = Some(stage.ticket.clone());
                    ctx.item.scene_execution = self.scene_execution.clone();
                    ctx.item.state = State::Prepared;
                    ctx.item.save(&tx, &ctx.parent)?;
                }
            }
            PublishItem => {
                self.owners(&ctx, now)?;
                let root = root.as_ref().unwrap();
                let ticket = ctx
                    .item
                    .ticket
                    .as_ref()
                    .ok_or("missing prepared workbench ticket")?;
                ctx.require_reservation(&tx, root, &ticket.filename)?;
                if Some(ticket) != snapshot.item.ticket.as_ref() {
                    return Err("workbench ticket changed".into());
                }
                reply["status"] = match verified {
                    Some(Final::Verified(file)) => {
                        ticket.check_final(root, &file)?;
                        "published"
                    }
                    Some(Final::Conflict) => "conflict",
                    Some(Final::Missing) => match stage.as_ref() {
                        Some(stage)
                            if stage
                                .publish(root, || self.owners(&ctx, super::super::now_ms()?))? =>
                        {
                            "published"
                        }
                        Some(_) => "conflict",
                        None => "missingStage",
                    },
                    None => return Err("missing prepared workbench ticket".into()),
                }
                .into();
            }
            AcknowledgeItem => {
                let root = root.as_ref().unwrap();
                if ctx.item.ticket != snapshot.item.ticket {
                    return Err("workbench ticket changed during acknowledgement".into());
                }
                reply["status"] = match verified {
                    Some(Final::Verified(file)) => {
                        ctx.item.ticket.as_ref().unwrap().check_final(root, &file)?;
                        if ctx.item.state != State::Delivered {
                            ctx.require_reservation(
                                &tx,
                                root,
                                &ctx.item.ticket.as_ref().unwrap().filename,
                            )?;
                            tx.execute(
                                "DELETE FROM lc_workbench_names WHERE item_key=?1",
                                [item_key(&ctx.parent.batch_id, ctx.item.ordinal)],
                            )?;
                            ctx.item.state = State::Delivered;
                            ctx.item.reason = None;
                            ctx.item.clear();
                            ctx.item.save(&tx, &ctx.parent)?;
                        }
                        finish_if_terminal(&tx, &mut ctx.parent)?;
                        "delivered"
                    }
                    Some(Final::Conflict) => "conflict",
                    _ => "missing",
                }
                .into();
            }
            SkipItem => {
                self.owners(&ctx, now)?;
                let name = ctx.name(self.suffix.ok_or("missing skip filename suffix")?)?;
                if ctx.target.collision != "skip"
                    || ctx.item.ticket.is_some()
                    || !(root.as_ref().unwrap().occupied(&name)?
                        || ctx.name_taken(&tx, root.as_ref().unwrap(), &name)?)
                {
                    return Err("only an occupied, unprepared name can be skipped".into());
                }
                self.owners(&ctx, super::super::now_ms()?)?;
                ctx.item.state = State::Skipped;
                ctx.item.skipped_name = Some(name);
                ctx.item.reason = Some("destinationExists".into());
                ctx.item.clear();
                ctx.item.save(&tx, &ctx.parent)?;
                finish_if_terminal(&tx, &mut ctx.parent)?;
            }
            FailItem => {
                self.owners(&ctx, now)?;
                let reason = self
                    .reason
                    .as_deref()
                    .filter(|v| {
                        !v.trim().is_empty() && v.len() <= 512 && !v.chars().any(char::is_control)
                    })
                    .ok_or("invalid workbench item diagnostic")?;
                ctx.item.reason = Some(reason.into());
                ctx.item.clear();
                ctx.item.state = if ctx.item.ticket.is_some() {
                    State::Prepared
                } else {
                    State::Failed
                };
                ctx.item.save(&tx, &ctx.parent)?;
            }
            FinishBatch => {
                if !done(&tx, &ctx.parent)? {
                    self.parent(&ctx, now)?;
                    if !finish_if_terminal(&tx, &mut ctx.parent)? {
                        return Err("workbench batch has unfinished items".into());
                    }
                }
                reply["complete"] = true.into();
            }
            Items | CheckDirectory | ClaimItem => unreachable!(),
        }
        reply["item"] = ctx.item.view(&ctx.parent, now);
        tx.commit()?;
        if matches!(self.action, PublishItem) && reply["status"] == "published" {
            if let (Some(stage), Some(root)) = (stage.as_ref(), root.as_ref()) {
                stage.sync_publication(root)?;
            }
        }
        if matches!(self.action, AcknowledgeItem) && reply["status"] == "delivered" {
            if let (Some(ticket), Some(root)) = (ctx.item.ticket.as_ref(), root.as_ref()) {
                let _ = ticket.cleanup(root);
            }
        }
        Ok(reply)
    }
}
