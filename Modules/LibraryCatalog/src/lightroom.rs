//! One-way Lightroom Classic catalog migration. Source SQLite, WAL and cache payloads are opened
//! only for reading. Each frozen run has independent organization, metadata and appearance ledgers.
use crate::{
    resources::{self, Resource},
    Result,
};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};
use uuid::Uuid;
mod ledger;
mod media;
mod metadata;
mod objects;
mod order;
mod preview;
mod relink;
mod source;
pub const SCHEMA: &str = include_str!("lightroom/schema.sql");
const PHASES: &[&str] = &[
    "volumes",
    "folders",
    "files",
    "masters",
    "copies",
    "collections",
    "members",
    "folderStacks",
    "collectionStacks",
    "dependencies",
    "smartAudit",
    "moduleMembers",
];
fn id(parts: &[&str]) -> String {
    Uuid::new_v5(
        &Uuid::NAMESPACE_URL,
        &serde_json::to_vec(parts).expect("string tuple"),
    )
    .to_string()
}
fn hash(v: &Value) -> Result<String> {
    Ok(hex::encode(Sha256::digest(serde_json::to_vec(v)?)))
}
fn integer(v: &Value) -> Option<i64> {
    v.as_i64()
        .or_else(|| {
            v.as_f64()
                .filter(|n| n.is_finite() && n.fract() == 0.0)
                .map(|n| n as i64)
        })
        .or_else(|| v.as_str()?.parse().ok())
}
fn numeric(v: &Value) -> Option<f64> {
    v.as_f64()
        .or_else(|| v.as_str()?.parse::<f64>().ok())
        .filter(|n| n.is_finite())
}
fn required<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("Missing {k}").into())
}
fn target(path: &Path, write: bool) -> Result<Connection> {
    let flags = if write {
        OpenFlags::SQLITE_OPEN_READ_WRITE
    } else {
        OpenFlags::SQLITE_OPEN_READ_ONLY
    };
    if !fs::symlink_metadata(path)?.is_file() {
        return Err("Expected a regular target catalog".into());
    }
    let c = Connection::open_with_flags(
        path.canonicalize()?,
        flags | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    c.busy_timeout(Duration::from_secs(5))?;
    c.execute_batch("PRAGMA trusted_schema=OFF;PRAGMA foreign_keys=ON;")?;
    Ok(c)
}
fn capture_request(catalog: &Path, r: &Value) -> Result<PathBuf> {
    let p = Path::new(required(r, "sourcePath")?);
    if !p.is_absolute()
        || !p
            .extension()
            .is_some_and(|e| e.eq_ignore_ascii_case("lrcat"))
        || !fs::symlink_metadata(p)?.is_file()
    {
        return Err("Choose a regular Lightroom .lrcat file".into());
    }
    let p = p.canonicalize()?;
    if catalog.canonicalize()? == p {
        return Err("Source and target catalog must differ".into());
    }
    Ok(p)
}
struct Context<'a> {
    catalog: &'a Path,
    source_path: PathBuf,
    source_id: String,
    source: Connection,
    preview: Option<Connection>,
    order: Connection,
    preview_layout: bool,
    preview_expected: bool,
    coherent: bool,
    sidecars: bool,
}
impl Context<'_> {
    fn named(&self, k: &str, v: &str) -> String {
        id(&["lightroom", &self.source_id, k, v])
    }
    fn id(&self, k: &str, v: i64) -> Result<String> {
        source_identity(&self.order, &self.source_id, k, v)
    }
}
fn source_identity(index: &Connection, sid: &str, kind: &str, local: i64) -> Result<String> {
    let global: Option<String> = index
        .prepare_cached("SELECT guid FROM identity WHERE kind=?1 AND local_id=?2")?
        .query_row(params![kind, local], |r| r.get(0))
        .optional()?;
    Ok(match global {
        Some(g) => id(&["lightroom", sid, kind, "global", &g]),
        None => id(&["lightroom", sid, kind, &local.to_string()]),
    })
}
struct Org {
    kind: String,
    key: String,
    target: String,
    command: Value,
}
struct Fact {
    domain: String,
    field: String,
    status: String,
    detail: String,
    evidence: Value,
}
struct Item {
    subject: String,
    key: String,
    org: Vec<Org>,
    facts: Vec<Fact>,
    links: Vec<(String, String, Resource)>,
    metadata: Option<(String, Value)>,
    look: Option<(String, preview::Look)>,
    file: Option<Value>,
    members: Option<Value>,
}
impl Item {
    fn new(subject: &str, key: &str) -> Self {
        Self {
            subject: subject.into(),
            key: key.into(),
            org: vec![],
            facts: vec![],
            links: vec![],
            metadata: None,
            look: None,
            file: None,
            members: None,
        }
    }
    fn org(&mut self, k: &str, key: &str, target: &str, c: Value) {
        self.org.push(Org {
            kind: k.into(),
            key: key.into(),
            target: target.into(),
            command: c,
        });
    }
    fn report(&mut self, d: &str, f: &str, s: &str, m: &str, e: Value) {
        self.facts.push(Fact {
            domain: d.into(),
            field: f.into(),
            status: s.into(),
            detail: m.into(),
            evidence: e,
        });
    }
    fn link(&mut self, role: &str, path: &str, r: Resource) {
        self.links.push((role.into(), path.into(), r));
    }
}
#[derive(Debug)]
struct Run {
    rid: String,
    sid: String,
    snapshot: String,
    preview: Option<String>,
    order: String,
    source_path: PathBuf,
    signature: source::Signatures,
    deps: Vec<source::Dependency>,
    sidecars: bool,
    phase: usize,
    cursor: i64,
    pass: i64,
    state: String,
}
fn run(db: &Connection, rid: &str) -> Result<Run> {
    let row=db.query_row("SELECT run_id,source_id,snapshot_id,preview_id,order_id,source_path,signatures,dependencies,sidecars,phase,cursor,pass,state FROM lc_lr_runs WHERE run_id=?1",[rid],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,Option<String>>(3)?,r.get::<_,String>(4)?,r.get::<_,String>(5)?,r.get::<_,String>(6)?,r.get::<_,String>(7)?,r.get::<_,bool>(8)?,r.get::<_,i64>(9)?,r.get::<_,i64>(10)?,r.get::<_,i64>(11)?,r.get::<_,String>(12)?)))?;
    Ok(Run {
        rid: row.0,
        sid: row.1,
        snapshot: row.2,
        preview: row.3,
        order: row.4,
        source_path: row.5.into(),
        signature: serde_json::from_str(&row.6)?,
        deps: serde_json::from_str(&row.7)?,
        sidecars: row.8,
        phase: usize::try_from(row.9)?,
        cursor: row.10,
        pass: row.11,
        state: row.12,
    })
}
fn counts(db: &Connection) -> Result<Value> {
    let mut out = json!({});
    for (k, t) in [
        ("volumes", "AgLibraryRootFolder"),
        ("folders", "AgLibraryFolder"),
        ("files", "AgLibraryFile"),
        ("images", "Adobe_images"),
        ("collections", "AgLibraryCollection"),
        ("members", "AgLibraryCollectionImage"),
        ("folderStackMembers", "AgLibraryFolderStackImage"),
        ("collectionStackMembers", "AgLibraryCollectionStackImage"),
        ("keywordLinks", "AgLibraryKeywordImage"),
        ("developRows", "Adobe_imageDevelopSettings"),
    ] {
        out[k] = json!(source::count(db, t)?);
    }
    out["virtualCopies"] = json!(db.query_row(
        "SELECT count(*) FROM Adobe_images WHERE masterImage IS NOT NULL AND masterImage!=0",
        [],
        |r| r.get::<_, i64>(0)
    )?);
    Ok(out)
}
fn start(catalog: &Path, r: &Value, preflight: bool) -> Result<Value> {
    let source_path = capture_request(catalog, r)?;
    let path = source_path.to_str().ok_or("Invalid catalog path")?;
    let signature = source::signatures(&source_path)?;
    let frozen = source::snapshot(&source_path, &signature.catalog)?;
    let version = source::version(&frozen.db)?;
    let anchor = source::anchor(&frozen.db)?;
    let deps = source::dependencies(&source_path)?;
    let sidecars = r["readSidecars"].as_bool().unwrap_or(false);
    let mut db = target(catalog, !preflight)?;
    let prior: Option<(String, String)> = db
        .query_row(
            "SELECT source_id,anchor FROM lc_lr_sources WHERE locator=?1",
            [path],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let explicit = r["sourceID"].as_str().filter(|s| !s.is_empty());
    let sid = explicit
        .map(str::to_owned)
        .or_else(|| prior.as_ref().map(|p| p.0.clone()))
        .unwrap_or_else(|| id(&["lightroomSource", path]));
    if prior.as_ref().is_some_and(|p| p.0 != sid) {
        return Err("Source locator is already bound to another Lightroom catalog".into());
    }
    let present: Option<(String, String)> = db
        .query_row(
            "SELECT locator,anchor FROM lc_lr_sources WHERE source_id=?1",
            [&sid],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((ref old_path, ref evidence)) = present {
        let old: Value = serde_json::from_str(evidence)?;
        if old != anchor && !source::compatible(&old, &anchor) {
            return Err("Lightroom source identity no longer matches the recorded catalog".into());
        }
        if old_path != path
            && (r["confirmRelocation"] != true || !source::compatible(&old, &anchor))
        {
            return Err(
                "Catalog relocation requires confirmation and matching source-object identities"
                    .into(),
            );
        }
    }
    if preflight {
        return Ok(
            json!({"state":"preflight","sourceID":sid,"version":version,"counts":counts(&frozen.db)?,"previewIndex":signature.preview.is_some(),"dependencyEntries":deps.len(),"knownSource":present.is_some(),"sourcePath":path}),
        );
    }
    let (preview, preview_problem) = match signature.preview.as_ref() {
        Some(s) => {
            match source::snapshot(&source::cache_dir(&source_path).join("previews.db"), s) {
                Ok(snapshot) => (Some(snapshot), None),
                Err(e) => (None, Some(e.to_string())),
            }
        }
        None => (None, None),
    };
    if source::signatures(&source_path)? != signature || source::dependencies(&source_path)? != deps
    {
        return Err("Catalog/companion set changed during capture".into());
    }
    let original = source::content(catalog, &frozen.path, "adobePayload")?;
    let cached = preview
        .as_ref()
        .map(|p| source::content(catalog, &p.path, "adobePayload"))
        .transpose()?;
    let order = order::manifest(
        catalog,
        &frozen,
        preview.as_ref().map(|v| &v.db),
        &source::cache_dir(&source_path),
    )?;
    if source::signatures(&source_path)? != signature {
        return Err("Source or cache index changed during object inventory".into());
    }
    let generation = hash(&json!([
        original.sha256,
        order.sha256,
        cached.as_ref().map(|r| &r.sha256),
        signature,
        deps,
        sidecars
    ]))?;
    let rid = id(&["lightroomRun", &sid, &generation]);
    if db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_lr_runs WHERE run_id=?1)",
        [&rid],
        |r| r.get::<_, bool>(0),
    )? {
        return ledger::status(&db, &rid);
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute("INSERT INTO lc_lr_sources(source_id,locator,anchor) VALUES(?1,?2,?3) ON CONFLICT(source_id) DO UPDATE SET locator=excluded.locator,anchor=excluded.anchor",params![sid,path,anchor.to_string()])?;
    resources::register(&tx, &original)?;
    resources::register(&tx, &order)?;
    if let Some(res) = cached.as_ref() {
        resources::register(&tx, res)?;
    }
    tx.execute("INSERT INTO lc_lr_runs(run_id,source_id,snapshot_id,preview_id,order_id,generation,source_path,version,signatures,dependencies,sidecars) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) ON CONFLICT(run_id) DO NOTHING",params![rid,sid,original.resource_id,cached.as_ref().map(|r|&r.resource_id),order.resource_id,generation,path,version,serde_json::to_string(&signature)?,serde_json::to_string(&deps)?,sidecars])?;
    if let Some(error) = preview_problem {
        tx.execute("INSERT OR REPLACE INTO lc_lr_reports(run_id,domain,subject,source_key,field,status,detail,evidence) VALUES(?1,'appearance','sourceContainer','previews.db','snapshot','missing',?2,'null')",params![rid,error])?;
    }
    tx.commit()?;
    ledger::status(&db, &rid)
}
fn context<'a>(catalog: &'a Path, db: &Connection, run: &Run) -> Result<Context<'a>> {
    let source = source::open_readonly(&source::verified_resource(catalog, db, &run.snapshot)?)?;
    let preview = run
        .preview
        .as_ref()
        .map(|id| {
            source::verified_resource(catalog, db, id).and_then(|p| source::open_readonly(&p))
        })
        .transpose()?;
    let preview_layout = match &preview {
        Some(p) => preview::supported(p)?,
        None => false,
    };
    Ok(Context {
        catalog,
        source_path: run.source_path.clone(),
        source_id: run.sid.clone(),
        source,
        preview,
        order: source::open_readonly(&source::verified_resource(catalog, db, &run.order)?)?,
        preview_layout,
        preview_expected: run.signature.preview.is_some(),
        coherent: source::signatures(&run.source_path).is_ok_and(|s| s == run.signature),
        sidecars: run.sidecars,
    })
}
fn companion(ctx: &Context<'_>, d: &source::Dependency) -> Result<Item> {
    let mut item = Item::new("dependency", &d.name);
    if d.state != "present" {
        item.report(
            "appearance",
            "bytes",
            if d.state == "emptyDirectory" {
                "mapped"
            } else {
                "missing"
            },
            &d.state,
            Value::Null,
        );
        return Ok(item);
    }
    let p = ctx
        .source_path
        .parent()
        .ok_or("No catalog parent")?
        .join(&d.name);
    if source::file_stamp(&p).ok().flatten() != d.stamp {
        item.report(
            "appearance",
            "bytes",
            "uncertain",
            "Source companion is unavailable or changed since the frozen inventory",
            Value::Null,
        );
        return Ok(item);
    }
    let resource = source::content(ctx.catalog, &p, "adobePayload")?;
    if source::file_stamp(&p).ok().flatten() != d.stamp {
        item.report(
            "appearance",
            "bytes",
            "uncertain",
            "Companion changed during capture",
            Value::Null,
        );
        return Ok(item);
    }
    item.report(
        "appearance",
        "bytes",
        "archivedOnly",
        "Companion retained at its source-relative location",
        json!({"sha256":resource.sha256,"bytes":resource.byte_count}),
    );
    item.link("lrcat-data", &d.name, resource);
    Ok(item)
}
/// Each worker has its own immutable SQLite handles. Prepare expensive JPEG/opaque resources
/// before the small target write transaction, and preserve source order at the checkpoint.
fn image_batch(ctx: &Context<'_>, keys: &[i64]) -> Result<Vec<Item>> {
    if keys.len() < 32 {
        return keys
            .iter()
            .map(|k| objects::prepare(ctx, "Adobe_images", *k))
            .collect();
    }
    let input = PathBuf::from(ctx.source.path().ok_or("Missing frozen catalog locator")?);
    let order = PathBuf::from(
        ctx.order
            .path()
            .ok_or("Missing ordering snapshot locator")?,
    );
    let preview = ctx
        .preview
        .as_ref()
        .and_then(Connection::path)
        .map(PathBuf::from);
    let catalog = ctx.catalog;
    let source_path = &ctx.source_path;
    let sid = &ctx.source_id;
    let preview_layout = ctx.preview_layout;
    let preview_expected = ctx.preview_expected;
    let coherent = ctx.coherent;
    let sidecars = ctx.sidecars;
    let width = std::thread::available_parallelism()
        .map(|p| p.get())
        .unwrap_or(1)
        .clamp(1, 4);
    std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for chunk in keys.chunks(keys.len().div_ceil(width)) {
            let input = &input;
            let order = &order;
            let preview = &preview;
            handles.push(scope.spawn(move || -> Result<Vec<Item>> {
                let local = Context {
                    catalog,
                    source_path: source_path.clone(),
                    source_id: sid.clone(),
                    source: source::open_readonly(input)?,
                    order: source::open_readonly(order)?,
                    preview: preview
                        .as_ref()
                        .map(|p| source::open_readonly(p))
                        .transpose()?,
                    preview_layout,
                    preview_expected,
                    coherent,
                    sidecars,
                };
                chunk
                    .iter()
                    .map(|k| objects::prepare(&local, "Adobe_images", *k))
                    .collect()
            }));
        }
        let mut out = Vec::new();
        for h in handles {
            out.extend(
                h.join()
                    .map_err(|_| "Lightroom image worker interrupted")??,
            );
        }
        Ok(out)
    })
}
fn batch(ctx: &Context<'_>, run: &Run, limit: i64) -> Result<(Vec<Item>, i64)> {
    let mut rows = Vec::new();
    let mut cursor = run.cursor;
    match PHASES[run.phase] {
        "dependencies" => {
            for (idx, d) in run
                .deps
                .iter()
                .enumerate()
                .skip((run.cursor + 1) as usize)
                .take(limit as usize)
            {
                rows.push(companion(ctx, d)?);
                cursor = idx as i64;
            }
        }
        "moduleMembers" => {
            if !source::exists(&ctx.source, "AgLibraryCollectionImage")? {
                return Ok((rows, cursor));
            }
            // Book/layout and slideshow objects have their own ordered image references.
            // Retain each source position and reason even when there is no native collection.
            let mut query=ctx.source.prepare(
                "SELECT m.id_local,m.collection,m.image,m.positionInCollection,c.creationId
                 FROM AgLibraryCollectionImage m LEFT JOIN AgLibraryCollection c ON c.id_local=m.collection
                 WHERE m.id_local>?1 AND (c.creationId IS NULL OR c.creationId NOT IN
                 ('com.adobe.ag.library.collection','com.adobe.ag.library.smart_collection')) ORDER BY m.id_local LIMIT ?2")?;
            let mut found = query.query(params![run.cursor, limit])?;
            while let Some(row) = found.next()? {
                let key: i64 = row.get(0)?;
                let owner: Option<i64> = row.get(1)?;
                let image: Option<i64> = row.get(2)?;
                let module: Option<String> = row.get(4)?;
                let mut item = Item::new("collectionMember", &format!("member:{key}"));
                item.report("organization","membership",if module.is_some(){"archivedOnly"}else{"missing"},
                    if module.is_some(){"Source Adobe module membership and ordering are preserved in the archived catalog"}else{"Source collection membership has no identifiable owner"},
                    json!({"sourceMember":key,"sourceCollectionID":owner,"sourceImageID":image,"sourcePosition":source::value(row,3)?,
                      "workID":image.map(|i|ctx.id("image",i)).transpose()?,"module":module}));
                rows.push(item);
                cursor = key;
            }
        }
        "smartAudit" => {
            if !source::exists(&ctx.source, "AgLibraryCollection")? {
                return Ok((rows, cursor));
            }
            let mut q=ctx.source.prepare("SELECT id_local FROM AgLibraryCollection WHERE creationId='com.adobe.ag.library.smart_collection' AND id_local>?1 ORDER BY id_local LIMIT ?2")?;
            let mut target = target(ctx.catalog, false)?;
            let tx = target.transaction()?;
            let watermark: i64 =
                tx.query_row("SELECT coalesce(max(seq),0) FROM lc_changes", [], |r| {
                    r.get(0)
                })?;
            for item in q.query_map(params![run.cursor, limit], |r| r.get::<_, i64>(0))? {
                let key = item?;
                cursor = key;
                let mut item = Item::new("AgLibraryCollection", &key.to_string());
                let cid = ctx.id("collection", key)?;
                let rule = order::rule(&ctx.source, key)?.and_then(|(_, rule)| rule);
                if rule.is_some() {
                    let actual_kind: Option<String> = tx
                        .query_row(
                            "SELECT kind FROM lc_org_collections WHERE collection_id=?1",
                            [&cid],
                            |r| r.get(0),
                        )
                        .optional()?;
                    if actual_kind.as_deref() == Some("smart") {
                        let mut s = ctx.order.prepare_cached(
                            "SELECT image FROM members WHERE collection=? AND image IS NOT NULL",
                        )?;
                        let mut expected = std::collections::BTreeSet::new();
                        for row in s.query_map([key], |r| r.get::<_, i64>(0))? {
                            expected.insert(ctx.id("image", row?)?);
                        }
                        let actual = crate::query::works::collection_work_ids(&tx, &cid)?
                            .into_iter()
                            .collect::<std::collections::BTreeSet<_>>();
                        item.report("organization","reevaluatedRule",if expected==actual{"mapped"}else{"uncertain"},"Native smart collection reevaluated against current visible works",json!({"sourceCount":expected.len(),"targetCount":actual.len(),"sourceOnly":expected.difference(&actual).count(),"targetOnly":actual.difference(&expected).count(),"watermark":watermark,"rule":rule}));
                        for (side, only) in [
                            ("sourceOnly", expected.difference(&actual)),
                            ("targetOnly", actual.difference(&expected)),
                        ] {
                            for work in only {
                                item.report("organization",&format!("ruleDifference:{side}:{work}"),"uncertain","Work differs between frozen source and current native rule result",json!({"side":side,"workID":work,"watermark":watermark}));
                            }
                        }
                    } else {
                        item.report(
                            "organization",
                            "reevaluatedRule",
                            "conflict",
                            "Native collection unavailable or locally changed",
                            Value::Null,
                        );
                    }
                }
                rows.push(item);
            }
        }
        "members" => {
            let mut q=ctx.order.prepare("SELECT seq,collection,image,position,total,basis,source_member FROM members WHERE seq>?1 ORDER BY seq LIMIT ?2")?;
            for v in q.query_map(params![run.cursor, limit], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, Option<i64>>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, Option<i64>>(6)?,
                ))
            })? {
                let (n, c, image, pos, total, basis, member) = v?;
                let mut item = Item::new(
                    "collectionMember",
                    &member
                        .map(|m| format!("member:{m}"))
                        .unwrap_or_else(|| format!("collection:{c}:{pos}")),
                );
                item.members = Some(
                    json!({"id":c,"target":ctx.id("collection",c)?,"image":image.map(|i|ctx.id("image",i)).transpose()?,"position":pos,"total":total,"basis":basis,"sourceMember":member}),
                );
                rows.push(item);
                cursor = n;
            }
        }
        phase => {
            let (table, condition) = match phase {
                "volumes" => ("AgLibraryRootFolder", "1"),
                "folders" => ("AgLibraryFolder", "1"),
                "files" => ("AgLibraryFile", "1"),
                "masters" => ("Adobe_images", "coalesce(masterImage,0)=0"),
                "copies" => ("Adobe_images", "coalesce(masterImage,0)!=0"),
                "collections" => ("AgLibraryCollection", "1"),
                "folderStacks" => ("AgLibraryFolderStack", "1"),
                "collectionStacks" => ("AgLibraryCollectionStack", "1"),
                _ => return Err("Unknown migration phase".into()),
            };
            if !source::exists(&ctx.source, table)? {
                return Ok((rows, cursor));
            }
            let mut q=ctx.source.prepare(&format!("SELECT id_local FROM {table} WHERE id_local>?1 AND {condition} ORDER BY id_local LIMIT ?2"))?;
            let keys = q
                .query_map(params![run.cursor, limit], |r| r.get::<_, i64>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            if let Some(last) = keys.last() {
                cursor = *last;
            }
            if table == "Adobe_images" {
                rows = image_batch(ctx, &keys)?;
            } else {
                for key in keys {
                    rows.push(objects::prepare(ctx, table, key)?);
                }
            }
        }
    }
    Ok((rows, cursor))
}
fn step(catalog: &Path, r: &Value) -> Result<Value> {
    let rid = required(r, "runID")?;
    let mut db = target(catalog, true)?;
    let state = run(&db, rid)?;
    if state.state == "complete" && state.phase >= PHASES.len() {
        return ledger::status(&db, rid);
    }
    let limit = r["limit"].as_i64().unwrap_or(24).clamp(1, 128);
    let ctx = context(catalog, &db, &state)?;
    let (items, cursor) = batch(&ctx, &state, limit)?;
    let coherent =
        ctx.coherent && source::signatures(&state.source_path).is_ok_and(|v| v == state.signature);
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let latest = run(&tx, rid)?;
    if (latest.phase, latest.cursor, latest.pass) != (state.phase, state.cursor, state.pass) {
        tx.rollback()?;
        return ledger::status(&db, rid);
    }
    // A new snapshot supersedes an older unfinished run. It cannot be overwritten by stale continuation.
    if tx.query_row("SELECT EXISTS(SELECT 1 FROM lc_lr_runs n,lc_lr_runs old WHERE old.run_id=?1 AND n.source_id=old.source_id AND n.rowid>old.rowid)",[rid],|r|r.get::<_,bool>(0))?{return Err("A newer snapshot exists; resume the latest generation".into());}
    let empty = items.is_empty();
    for mut item in items {
        ledger::apply(&tx, &state, &mut item, coherent)?;
    }
    let next = if empty { state.phase + 1 } else { state.phase };
    if next == PHASES.len() {
        ledger::finish(&tx, &state)?;
    }
    tx.execute(
        "UPDATE lc_lr_runs SET phase=?2,cursor=?3,state=?4 WHERE run_id=?1",
        params![
            rid,
            i64::try_from(next)?,
            if empty { -1 } else { cursor },
            if next == PHASES.len() {
                "complete"
            } else {
                "running"
            }
        ],
    )?;
    tx.commit()?;
    ledger::status(&db, rid)
}
pub fn execute(catalog: &Path, r: &Value) -> Result<Value> {
    match required(r, "action")? {
        "preflight" => start(catalog, r, true),
        "start" => start(catalog, r, false),
        "step" => step(catalog, r),
        "status" => ledger::status(&target(catalog, false)?, required(r, "runID")?),
        "linkCandidates" => relink::apply(catalog, r, false),
        "linkOriginal" => relink::apply(catalog, r, true),
        "workMedia" => media::work(catalog, r),
        "previewPath" => {
            let db = target(catalog, false)?;
            let resource:String=db.query_row("SELECT resource_id FROM lc_lr_looks WHERE run_id=?1 AND image_key=?2 AND decoded=1",params![required(r,"runID")?,required(r,"sourceKey")?],|row|row.get(0))?;
            let p = source::verified_resource(catalog, &db, &resource)?;
            Ok(json!({"path":p}))
        }
        "runs" => ledger::runs(&target(catalog, false)?),
        "report" => ledger::report(&target(catalog, false)?, r),
        "retry" => {
            let mut db = target(catalog, true)?;
            let rid = required(r, "runID")?;
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if tx.query_row("SELECT EXISTS(SELECT 1 FROM lc_lr_runs n,lc_lr_runs old WHERE old.run_id=?1 AND n.source_id=old.source_id AND n.rowid>old.rowid)",[rid],|r|r.get::<_,bool>(0))?{return Err("A newer generation supersedes this import".into());}
            tx.execute("UPDATE lc_lr_runs SET pass=pass+1,phase=0,cursor=-1,state='running' WHERE run_id=?1 AND state='complete'",[rid])?;
            tx.commit()?;
            ledger::status(&db, rid)
        }
        _ => Err("Unknown Lightroom operation".into()),
    }
}
