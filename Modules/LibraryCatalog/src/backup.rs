//! Package operations run off the UI thread. A destination is one immutable generation.
//! The writer must commit its intake/resource ledger and reconcile pending editing receipts
//! before calling backup. Only the snapshot's lc_archive_files confers original eligibility.
//! lc_resources contains already frozen, hash-verified publications rooted at LibraryResources/.
//! Cached RAWs, preview caches, export destinations and staging directories are not inputs.
pub(crate) mod files;
mod inventory;
mod restore;

use crate::Result;
use files::{
    absolute, check, digest, directory, exists, hexsum, keep_verified, parent, part, private_stage,
    publish, read_bytes, regular, verified_copy, write_new,
};
use inventory::{text, Inventory, Original, Resource, Source};
use rusqlite::{backup::Backup, Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tempfile::NamedTempFile;
use uuid::Uuid;

/// A restored copy retains history and starts with its own writer identity and leases.
pub(crate) fn detach_restored_writer(db: &Connection) -> Result<String> {
    if db.is_autocommit() {
        return Err("restore requires a catalog write transaction".into());
    }
    crate::managed_files::detach_foreign(db, "restored-package")?;
    crate::scheduler::detach_restored_workers(db)?;
    let writer = Uuid::new_v4().to_string();
    db.execute("INSERT INTO metadata(key,value) VALUES('deviceID',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [&writer])?;
    Ok(writer)
}

/// A package fork retains frozen batch fingerprints as read-only history. Lease grants
/// must match the new library and writer identities.
pub(crate) fn detach_local_copy(db: &Connection, body: &Value) -> Result<Value> {
    let new = Uuid::parse_str(text(body, "libraryID")?)?.to_string();
    let old = library_id(db)?;
    if old == new {
        return Err("copy requires an independent library identity".into());
    }
    let writer = detach_restored_writer(db)?;
    db.execute(
        "INSERT OR IGNORE INTO lc_meta(key,value) VALUES('localPackage.historyLibrary.v1/'||?1,'1')",
        [&old],
    )?;
    db.execute("UPDATE lc_meta SET value=?1 WHERE key='libraryID'", [&new])?;
    db.execute_batch("UPDATE lc_task_jobs SET state='cancelled',claim_interest_until=0,submission_token=NULL,
        token=NULL,lease_until=NULL,last_error='task belongs to the original library'
        WHERE state IN ('queued','running','cancelling','waiting','reconcile');
        UPDATE lc_proc_jobs SET state='cancelled',lease_until=NULL,token=NULL,error='task belongs to the original library'
        WHERE state IN ('queued','preparing','rendering','staged');")?;
    Ok(json!({"libraryID":new,"writerID":writer}))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Mode {
    Catalog,
    Full,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Blob {
    pub(crate) sha256: String,
    pub(crate) bytes: u64,
}
impl Blob {
    pub(crate) fn new(s: String, bytes: i64) -> Result<Self> {
        if bytes < 0
            || s.len() != 64
            || !s
                .bytes()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        {
            return Err("invalid SHA-256 or object length".into());
        }
        Ok(Self {
            sha256: s,
            bytes: bytes as u64,
        })
    }
    fn path(&self) -> PathBuf {
        Path::new("objects")
            .join(&self.sha256[..2])
            .join(&self.sha256)
    }
}
#[derive(Serialize, Deserialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest {
    format: u32,
    #[serde(rename = "libraryID")]
    library_id: String,
    generation: String,
    mode: Mode,
    catalog: Blob,
    originals: Vec<Original>,
    source_roots: Vec<inventory::RootSummary>,
    resources: Vec<Resource>,
    deferred: Vec<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Generation {
    format: u32,
    #[serde(rename = "libraryID")]
    library_id: String,
    generation: String,
    mode: Mode,
    origin: String,
}
const FORMAT: u32 = 1;
const DB: &str = "library.sqlite";

fn library_id(db: &Connection) -> Result<String> {
    let id: String = db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
        r.get(0)
    })?;
    if id.is_empty() {
        return Err("catalog does not have an identity".into());
    }
    Ok(id)
}

fn open(path: &Path, write: bool) -> Result<Connection> {
    // SQLite NOFOLLOW also checks Darwin's system /var and /tmp aliases.
    let path = absolute(path)?;
    regular(&path)?;
    let flags = if write {
        OpenFlags::SQLITE_OPEN_READ_WRITE
    } else {
        OpenFlags::SQLITE_OPEN_READ_ONLY
    };
    let db = Connection::open_with_flags(path, flags | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
    db.busy_timeout(Duration::from_secs(5))?;
    db.execute_batch("PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON;")?;
    Ok(db)
}
fn integrity(db: &Connection) -> Result<()> {
    let mut q = db.prepare("PRAGMA quick_check")?;
    let mut rows = q.query([])?;
    if rows
        .next()?
        .ok_or("missing integrity result")?
        .get::<_, String>(0)?
        != "ok"
        || rows.next()?.is_some()
    {
        return Err("catalog integrity check failed".into());
    }
    if db.prepare("PRAGMA foreign_key_check")?.exists([])? {
        return Err("catalog foreign-key check failed".into());
    }
    Ok(())
}
fn snapshot(source: &Path, stage: &Path) -> Result<Blob> {
    let db = open(source, false)?;
    db.execute_batch("BEGIN DEFERRED;")?;
    db.query_row("SELECT COUNT(*) FROM sqlite_schema", [], |r| {
        r.get::<_, i64>(0)
    })?;
    let target = NamedTempFile::new_in(stage)?;
    {
        let mut dest = open(target.path(), true)?;
        Backup::new(&db, &mut dest)?.run_to_completion(256, Duration::from_millis(2), None)?;
        dest.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
        let mode: String = dest.query_row("PRAGMA journal_mode=DELETE", [], |r| r.get(0))?;
        if !mode.eq_ignore_ascii_case("delete") {
            return Err("Could not seal the backup journal".into());
        }
        dest.execute_batch("PRAGMA synchronous=FULL;")?;
        integrity(&dest)?;
    }
    // SQLite can retain a zero-WAL shared-memory file when an online backup copied a
    // WAL source onto a new handle. These names belong exclusively to our closed temp DB.
    let temp = target
        .path()
        .to_str()
        .ok_or("Invalid snapshot staging path")?;
    for suffix in ["-wal", "-shm", "-journal"] {
        let sidecar = PathBuf::from(format!("{temp}{suffix}"));
        if exists(&sidecar)? {
            regular(&sidecar)?;
            fs::remove_file(sidecar)?;
        }
    }
    target.as_file().sync_all()?;
    let hash = digest(target.path())?;
    target.persist_noclobber(stage.join(DB))?;
    directory(stage, false)?.sync_all()?;
    Ok(hash)
}
fn path_request(request: &Value, key: &str) -> Result<PathBuf> {
    absolute(Path::new(text(request, key)?))
}
fn read_json<T: for<'a> Deserialize<'a>>(p: &Path) -> Result<T> {
    Ok(serde_json::from_slice(&read_bytes(p)?)?)
}
fn write_json<T: Serialize>(path: &Path, v: &T) -> Result<()> {
    write_new(path, &serde_json::to_vec(v)?)
}

fn describe(inv: &Inventory, generation: &str, mode: Mode, catalog: Blob) -> Manifest {
    Manifest {
        format: FORMAT,
        library_id: inv.library_id.clone(),
        generation: generation.into(),
        mode,
        catalog,
        originals: inv.originals.iter().cloned().collect(),
        source_roots: inv.roots.clone(),
        resources: inv.resources.iter().cloned().collect(),
        deferred: inv.deferred.iter().cloned().collect(),
    }
}
fn distinct_dirs(a: &Path, b: &Path) -> Result<()> {
    if a.starts_with(b) || b.starts_with(a) {
        return Err("package and working locations must be independent".into());
    }
    Ok(())
}
fn package_header(root: &Path, expected: Option<&str>) -> Result<(Manifest, Inventory, String)> {
    directory(root, false)?;
    for suffix in ["-wal", "-shm", "-journal"] {
        if exists(&root.join(format!("{DB}{suffix}")))? {
            return Err("sealed catalog has an unexpected SQLite sidecar".into());
        }
    }
    let data = read_bytes(&root.join("manifest.json"))?;
    let fingerprint = hexsum(&data);
    if read_bytes(&root.join("manifest.sha256"))? != fingerprint.as_bytes()
        || expected.is_some_and(|v| v != fingerprint)
    {
        return Err("package manifest checksum mismatch".into());
    }
    let m: Manifest = serde_json::from_slice(&data)?;
    let g: Generation = read_json(&root.join("generation.json"))?;
    if m.format != FORMAT
        || g.format != FORMAT
        || m.generation != g.generation
        || m.library_id != g.library_id
        || m.mode != g.mode
        || read_json::<Blob>(&root.join("snapshot.json"))? != m.catalog
    {
        return Err("inconsistent package generation".into());
    }
    part(&m.generation)?;
    Blob::new(m.catalog.sha256.clone(), i64::try_from(m.catalog.bytes)?)?;
    let db_path = root.join(DB);
    check(&db_path, &m.catalog)?;
    let db = open(&db_path, false)?;
    integrity(&db)?;
    let inv = Inventory::from_snapshot(&db, &db_path, m.mode)?;
    if describe(&inv, &g.generation, g.mode, m.catalog.clone()) != m {
        return Err("manifest differs from its catalog references".into());
    }
    Ok((m, inv, fingerprint))
}
fn package_entries(root: &Path, required: &BTreeSet<Blob>) -> Result<()> {
    let mut expected: BTreeSet<PathBuf> = [
        "generation.json",
        "snapshot.json",
        DB,
        "manifest.json",
        "manifest.sha256",
    ]
    .iter()
    .map(PathBuf::from)
    .collect();
    let mut dirs = BTreeSet::new();
    dirs.insert(PathBuf::from("objects"));
    for obj in required {
        let name = obj.path();
        dirs.insert(parent(&name)?.to_owned());
        expected.insert(name);
    }
    let mut stack = vec![PathBuf::new()];
    while let Some(rel) = stack.pop() {
        for entry in fs::read_dir(root.join(&rel))? {
            let entry = entry?;
            let key = rel.join(entry.file_name());
            let kind = entry.file_type()?;
            if kind.is_dir() && dirs.contains(&key) {
                stack.push(key);
            } else if !(kind.is_file() && expected.remove(&key)) {
                return Err(format!("unlisted or unsafe package entry {}", key.display()).into());
            }
        }
    }
    if !expected.is_empty() {
        return Err("package has missing objects".into());
    }
    Ok(())
}
fn validate_objects(root: &Path, inv: &Inventory, mode: Mode) -> Result<()> {
    let needed = inv.required(mode);
    package_entries(root, &needed)?;
    for obj in &needed {
        check(&root.join(obj.path()), obj)?;
        inv.check_input(obj, &root.join(obj.path()))?;
    }
    Ok(())
}
fn generation_result(m: &Manifest, hash: &str, root: &Path, copied: usize, reused: usize) -> Value {
    json!({"state":"complete","libraryID":m.library_id,"generation":m.generation,"mode":m.mode,"package":root,"manifestSHA256":hash,
        "catalogSHA256":m.catalog.sha256,"originalReferences":m.originals.len(),"resourceReferences":m.resources.len(),
        "deferred":m.deferred,"coveredOriginalFiles":if m.mode==Mode::Full{m.originals.iter().map(|r|&r.file_id).collect::<BTreeSet<_>>().len()}else{0},
        "coveredRoots":if m.mode==Mode::Full{m.source_roots.as_slice()}else{&[]},
        "coveredScopes":if m.mode==Mode::Full{m.originals.iter().map(|r|&r.scope_id).collect::<BTreeSet<_>>().len()}else{0},
        "copiedObjects":copied,"reusedObjects":reused})
}
fn assign_generation(
    stage: &Path,
    source: &Path,
    request: &Value,
    mode: Mode,
    library: &str,
) -> Result<Generation> {
    let marker = stage.join("generation.json");
    let origin = hexsum(source.as_os_str().as_encoded_bytes());
    let specified = request
        .get("generation")
        .map(|v| v.as_str().ok_or("invalid generation"))
        .transpose()?;
    if let Some(id) = specified {
        part(id)?;
    }
    if exists(&marker)? {
        let g: Generation = read_json(&marker)?;
        if g.format != FORMAT
            || g.origin != origin
            || g.library_id != library
            || g.mode != mode
            || specified.is_some_and(|id| id != g.generation)
        {
            return Err("a different generation already occupies the private stage".into());
        }
        return Ok(g);
    }
    if fs::read_dir(stage)?.next().is_some() {
        return Err("unrecognized existing package stage".into());
    }
    let g = Generation {
        format: FORMAT,
        library_id: library.to_owned(),
        generation: specified
            .map(str::to_string)
            .unwrap_or_else(|| Uuid::new_v4().to_string()),
        origin,
        mode,
    };
    write_json(&marker, &g)?;
    Ok(g)
}
fn copy_objects(
    stage: &Path,
    inv: &Inventory,
    mode: Mode,
    previous: &[PathBuf],
) -> Result<(usize, usize, Vec<Value>)> {
    let mut copied = 0;
    let mut reused = 0;
    let mut missing = Vec::new();
    for obj in inv.required(mode) {
        let target = stage.join(obj.path());
        if keep_verified(&target, &obj)? {
            reused += 1;
            continue;
        }
        let mut done = false;
        for root in previous {
            let source = root.join(obj.path());
            if files::link_or_copy(&source, &target, &obj).is_ok() {
                done = true;
                reused += 1;
                break;
            }
        }
        if done {
            continue;
        }
        for candidate in inv.copies.get(&obj).into_iter().flatten() {
            let result = match candidate {
                Source::Bytes(b) => verified_copy(&mut Cursor::new(b), &target, &obj),
                Source::File(path) => inv
                    .check_input(&obj, path)
                    .and_then(|()| regular(path))
                    .and_then(|mut f| verified_copy(&mut f, &target, &obj)),
            };
            if result.is_ok() {
                done = true;
                copied += 1;
                break;
            }
        }
        if !done {
            let file_ids: BTreeSet<_> = inv
                .originals
                .iter()
                .filter(|r| r.object == obj)
                .map(|r| &r.file_id)
                .collect();
            let resource_ids: BTreeSet<_> = inv
                .resources
                .iter()
                .filter(|r| r.object == obj)
                .map(|r| &r.id)
                .collect();
            missing.push(json!({"sha256":obj.sha256,"byteCount":obj.bytes,"files":file_ids,"resources":resource_ids,
                "reason":"noReadableVerifiedCopy"}));
        }
    }
    Ok((copied, reused, missing))
}
// A moved original may have gained a verified replica since this frozen generation.
// New scopes never add coverage to the manifest.
fn supplement_locations(inv: &mut Inventory, catalog: &Path) -> Result<()> {
    let mut db = open(catalog, false)?;
    let tx = db.transaction()?;
    let library: String =
        tx.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
            r.get(0)
        })?;
    if library != inv.library_id {
        return Err("originals belong to another library".into());
    }
    let admitted: std::collections::BTreeMap<_, _> = inv
        .originals
        .iter()
        .map(|o| {
            (
                (
                    o.scope_id.as_str(),
                    o.file_id.as_str(),
                    o.content_id.as_str(),
                ),
                &o.object,
            )
        })
        .collect();
    let mut stmt = tx.prepare(
        "SELECT scope_id,file_id,content_id,path FROM lc_archive_files WHERE path IS NOT NULL",
    )?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let (scope, file, content, path): (String, String, String, String) =
            (row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?);
        if let Some(object) = admitted.get(&(scope.as_str(), file.as_str(), content.as_str())) {
            let path = PathBuf::from(path);
            let sources = inv.copies.entry((*object).clone()).or_default();
            if !sources
                .iter()
                .any(|s| matches!(s,Source::File(p) if *p==path))
            {
                sources.push(Source::File(path));
            }
        }
    }
    Ok(())
}

fn backup(catalog: &Path, request: &Value) -> Result<Value> {
    let dest = path_request(request, "destination")?;
    distinct_dirs(catalog, &dest)?;
    let mode: Mode =
        serde_json::from_value(request.get("mode").cloned().unwrap_or(json!("catalog")))?;
    let repair = request
        .get("repairFrom")
        .map(|_| path_request(request, "repairFrom"))
        .transpose()?;
    let source_key = repair.as_deref().unwrap_or(catalog);
    let source_database = repair
        .as_ref()
        .map(|dir| dir.join(DB))
        .unwrap_or_else(|| catalog.to_owned());
    let library = library_id(&open(&source_database, false)?)?;
    if let Some(old) = repair.as_deref() {
        restore::guard_destination(&old.join(DB), &dest)?;
    } else {
        restore::guard_destination(catalog, &dest)?;
    }
    let mut reuse = Vec::new();
    for key in ["repairFrom", "previousPackage"] {
        if request.get(key).is_some() {
            let source = path_request(request, key)?;
            distinct_dirs(&source, &dest)?;
            if package_header(&source, None)?.0.library_id != library {
                return Err("referenced package belongs to a different library".into());
            }
            reuse.push(source);
        }
    }
    if exists(&dest)? {
        let (m, inv, h) = package_header(&dest, request["expectedManifestSHA256"].as_str())?;
        let g: Generation = read_json(&dest.join("generation.json"))?;
        if g.origin != hexsum(source_key.as_os_str().as_encoded_bytes())
            || m.library_id != library
            || m.mode != mode
            || request["generation"]
                .as_str()
                .is_some_and(|id| id != m.generation)
        {
            return Err("destination holds a different generation".into());
        }
        validate_objects(&dest, &inv, m.mode)?;
        return Ok(generation_result(
            &m,
            &h,
            &dest,
            0,
            inv.required(m.mode).len(),
        ));
    }
    let (stage, _lock) = private_stage(&dest, "backup")?;
    files::discard_abandoned_temps(&stage)?;
    let generation = assign_generation(&stage, source_key, request, mode, &library)?;
    let db_path = stage.join(DB);
    let stamp = stage.join("snapshot.json");
    if !exists(&db_path)? {
        let obj = if let Some(ref old) = repair {
            let (m, _, _) = package_header(old, request["expectedManifestSHA256"].as_str())?;
            if m.mode != mode {
                return Err("repair must retain the sealed coverage mode".into());
            }
            verified_copy(&mut regular(&old.join(DB))?, &db_path, &m.catalog)?;
            m.catalog
        } else {
            snapshot(catalog, &stage)?
        };
        write_json(&stamp, &obj)?;
    } else if !exists(&stamp)? {
        // Publication of the SQLite file is atomic. Recheck an interruption between the two seals.
        integrity(&open(&db_path, false)?)?;
        write_json(&stamp, &digest(&db_path)?)?;
    }
    let obj: Blob = read_json(&stamp)?;
    check(&db_path, &obj)?;
    let db = open(&db_path, false)?;
    integrity(&db)?;
    let mut inv = Inventory::from_snapshot(&db, catalog, mode)?;
    if inv.library_id != generation.library_id {
        return Err("catalog identity changed during backup".into());
    }
    drop(db);
    restore::guard_destination(&db_path, &dest)?;
    if mode == Mode::Full {
        supplement_locations(&mut inv, catalog)?;
    }
    let (copied, reused, missing) = copy_objects(&stage, &inv, mode, &reuse)?;
    if !missing.is_empty() {
        return Ok(
            json!({"state":"incomplete","generation":generation.generation,"mode":mode,"copiedObjects":copied,
            "reusedObjects":reused,"missing":missing,"package":dest,"canResume":true}),
        );
    }
    let m = describe(&inv, &generation.generation, mode, obj);
    let data = serde_json::to_vec(&m)?;
    let h = hexsum(&data);
    for (name, bytes) in [
        ("manifest.json", data.as_slice()),
        ("manifest.sha256", h.as_bytes()),
    ] {
        let target = stage.join(name);
        if exists(&target)? {
            if read_bytes(&target)? != bytes {
                return Err("stage seal mismatch".into());
            }
        } else {
            write_new(&target, bytes)?;
        }
    }
    let (_, rechecked, _) = package_header(&stage, Some(&h))?;
    validate_objects(&stage, &rechecked, mode)?;
    publish(&stage, &dest)?;
    Ok(generation_result(&m, &h, &dest, copied, reused))
}
fn plan(catalog: &Path, request: &Value) -> Result<Value> {
    let mode: Mode =
        serde_json::from_value(request.get("mode").cloned().unwrap_or(json!("catalog")))?;
    let tmp = tempfile::tempdir()?;
    let bytes = snapshot(catalog, tmp.path())?;
    let db = open(&tmp.path().join(DB), false)?;
    let inv = Inventory::from_snapshot(&db, catalog, mode)?;
    let originals: BTreeSet<_> = inv.originals.iter().map(|r| &r.object).collect();
    let resources: BTreeSet<_> = inv.resources.iter().map(|r| &r.object).collect();
    let required = inv.required(mode);
    let mut missing = Vec::new();
    for obj in &required {
        let reachable = inv.copies.get(obj).into_iter().flatten().any(|s| match s {
            Source::Bytes(b) => b.len() as u64 == obj.bytes,
            Source::File(p) => regular(p)
                .and_then(|f| Ok(f.metadata()?.len()))
                .is_ok_and(|n| n == obj.bytes),
        });
        if !reachable {
            missing.push(json!({"sha256":obj.sha256,"byteCount":obj.bytes,"files":inv.originals.iter().filter(|r|r.object==*obj).map(|r|&r.file_id).collect::<BTreeSet<_>>(),
                "resources":inv.resources.iter().filter(|r|r.object==*obj).map(|r|&r.id).collect::<Vec<_>>(),"reason":"notPresentAtRecordedSize"}));
        }
    }
    let mut external_missing = BTreeSet::new();
    for original in &inv.originals {
        let available = inv.locations.get(original).into_iter().flatten().any(|p| {
            regular(p)
                .and_then(|file| Ok(file.metadata()?.len()))
                .is_ok_and(|bytes| bytes == original.object.bytes)
        });
        if !available {
            external_missing.insert(&original.file_id);
        }
    }
    Ok(
        json!({"state":"planned","mode":mode,"eligibleFiles":inv.originals.iter().map(|r|&r.file_id).collect::<BTreeSet<_>>().len(),
        "eligibleReferences":inv.originals.len(),"distinctOriginalBytes":originals.iter().map(|o|o.bytes).sum::<u64>(),
        "resourceBytes":resources.iter().map(|o|o.bytes).sum::<u64>(),"resourceReferences":inv.resources.len(),"catalogBytes":bytes.bytes,
        "estimatedPackageBytes":bytes.bytes+required.iter().map(|o|o.bytes).sum::<u64>(),"roots":inv.roots,"missing":missing,"externalMissingFiles":external_missing,"deferred":inv.deferred,
        "verification":"availabilityAndSize"}),
    )
}
// A pinned manifest is the receipt for this particular generation. Inspecting one original only
// verifies its own object. Unplugging the backup volume cannot turn cached coverage into success.
fn coverage(catalog: &Path, r: &Value) -> Result<Value> {
    let dir = path_request(r, "package")?;
    let expected = text(r, "expectedManifestSHA256")?;
    let file = text(r, "fileID")?;
    let content = text(r, "contentID")?;
    if expected.len() != 64
        || !expected
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
    {
        return Err("A pinned manifest SHA-256 is required".into());
    }
    if fs::metadata(&dir).is_err() {
        return Ok(json!({"state":"offline","covered":null}));
    }
    let library = library_id(&open(catalog, false)?)?;
    let inspect = (|| -> Result<Value> {
        directory(&dir, false)?;
        let bytes = read_bytes(&dir.join("manifest.json"))?;
        if hexsum(&bytes) != expected
            || read_bytes(&dir.join("manifest.sha256"))? != expected.as_bytes()
        {
            return Err("Backup seal changed".into());
        }
        let m: Manifest = serde_json::from_slice(&bytes)?;
        if m.format != FORMAT || m.library_id != library {
            return Err("Unknown generation or different library".into());
        }
        if m.mode == Mode::Catalog {
            return Ok(json!({"state":"catalogOnly","covered":false,"generation":m.generation}));
        }
        let item = m
            .originals
            .iter()
            .find(|o| o.file_id == file && o.content_id == content);
        if let Some(o) = item {
            Blob::new(o.object.sha256.clone(), i64::try_from(o.object.bytes)?)?;
            check(&dir.join(o.object.path()), &o.object)?;
        }
        Ok(
            json!({"state":if item.is_some(){"verified"}else{"notIncluded"},"covered":item.is_some(),"generation":m.generation}),
        )
    })();
    Ok(inspect
        .unwrap_or_else(|e| json!({"state":"unverified","covered":null,"reason":e.to_string()})))
}
pub fn execute(catalog: &Path, request: &Value) -> Result<Value> {
    let catalog = absolute(catalog)?;
    match text(request, "op")? {
        "plan" => plan(&catalog, request),
        "coverage" => coverage(&catalog, request),
        "backup" => backup(&catalog, request),
        "restore" => restore::restore(request),
        "relink" => restore::relink(&catalog, request),
        _ => Err("unknown package operation".into()),
    }
}
