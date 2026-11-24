use rawmaster_library::{authority, backup, resources, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};
use tempfile::TempDir;

fn hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn object(root: &Path, bytes: &[u8]) -> PathBuf {
    let h = hash(bytes);
    root.join("objects").join(&h[..2]).join(h)
}
struct Library {
    _temp: TempDir,
    root: PathBuf,
    db_path: PathBuf,
    source: PathBuf,
    db: Connection,
}
impl Library {
    fn new() -> Result<Self> {
        let temp = tempfile::tempdir()?;
        let root = temp.path().canonicalize()?;
        let library = root.join("live");
        fs::create_dir(&library)?;
        let source = root.join("volume");
        fs::create_dir(&source)?;
        let db_path = library.join("library.sqlite");
        let db = Connection::open(&db_path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE")?;
        db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
        rawmaster_library::transaction(&db, &json!({"operation":"install"}))?;
        db.execute("INSERT INTO projects VALUES('p','{}'),('another','{}')", [])?;
        db.execute(
            "INSERT INTO metadata VALUES('deviceID','original-device')",
            [],
        )?;
        db.execute("INSERT INTO sessions VALUES('s',?)",[json!({"id":"s","projectID":"p","mode":"reference","sourcePath":source,"scanCompleted":true,"status":"completed"}).to_string()])?;
        db.execute(
            "INSERT INTO session_workflows VALUES('s',?)",
            [
                json!({"phase":"screening","projectID":"p","sessionID":"s","importActive":false})
                    .to_string(),
            ],
        )?;
        let this = Self {
            _temp: temp,
            root,
            db_path,
            source,
            db,
        };
        let mut items = Vec::new();
        for (id, name, bytes, disposition) in [
            ("araw", "A.RAW", b"excluded-raw".as_slice(), "excluded"),
            ("ajpg", "A.JPG", b"admitted-jpeg", "admitted"),
            ("b", "B.RAW", b"sequence-only", "sequenceOnly"),
            ("c", "C.RAW", b"excluded-required", "excluded"),
            ("d", "D.RAW", b"unverified", "failed"),
        ] {
            let path = this.source.join(name);
            fs::write(&path, bytes)?;
            let sha = hash(bytes);
            let data = json!({"id":id,"sessionID":"s","projectID":"p","filename":name,"relativePath":name,"sourcePath":path,"currentPath":path,
                "fileSize":bytes.len(),"contentHash":(disposition!="failed").then_some(sha),"availability":"available","importState":if disposition=="failed" {"failed"}else{"ready"}});
            this.db.execute(
                "INSERT INTO assets(id,session_id,source_path,data) VALUES(?1,'s',?2,?3)",
                params![id, path.to_str(), data.to_string()],
            )?;
            items.push(json!({"occurrenceID":id,"disposition":disposition}));
        }
        authority::command(
            &this.db,
            &json!({"version":1,"commandID":"c1","action":"session.seal","sessionID":"s","items":items}),
        )?;
        this.db.execute_batch("PRAGMA user_version=8; COMMIT")?;
        Ok(this)
    }
    fn run(&self, request: Value) -> Result<Value> {
        backup::execute(&self.db_path, &request)
    }
    fn backup(&self, mode: &str, package: &Path) -> Result<Value> {
        self.run(json!({"op":"backup","destination":package,"mode":mode,"generation":"g1"}))
    }
    fn restore(&self, package: &Path, destination: &Path) -> Result<Value> {
        self.run(json!({"op":"restore","package":package,"destination":destination}))
    }
    fn resource(&self, id: &str, kind: &str, owner: Option<&str>, bytes: &[u8]) -> Result<String> {
        let r = self.root.join(format!("input-{id}"));
        fs::write(&r, bytes)?;
        let resource = resources::stage(&self.db_path, &r, id, kind, owner.map(String::from))?;
        resources::register(&self.db, &resource)?;
        Ok(resource.relative_path)
    }
    fn editing(&self) -> Result<()> {
        let a = self.root.join("editing");
        fs::create_dir_all(a.join("artifacts/w/v"))?;
        let rel = "artifacts/w/v/receipt.png";
        let bytes = b"published-pixels";
        fs::write(a.join(rel), bytes)?;
        self.db.execute(
            "INSERT INTO metadata VALUES('editingArchiveRoot',?)",
            [a.to_str()],
        )?;
        self.db.execute_batch(
            "CREATE TABLE IF NOT EXISTS processing_jobs(id TEXT PRIMARY KEY,data TEXT)",
        )?;
        let source = json!({"assetID":"ajpg","contentSHA256":hash(b"admitted-jpeg")});
        let art = json!({"relativePath":rel,"sha256":hash(bytes),"byteCount":bytes.len(),"encoding":"public.png",
            "pixelWidth":2,"pixelHeight":2,"nativePixelWidth":2,"nativePixelHeight":2,"bitDepth":8});
        let v = json!({"id":"v","workID":"w","kind":"external","source":source,"artifact":art});
        self.db.execute(
            "INSERT INTO editing_versions(id,work_id,data) VALUES('v','w',?)",
            [v.to_string()],
        )?;
        self.db.execute(
            "INSERT INTO archive_publications VALUES('receipt','v',?)",
            [json!({"id":"receipt","version":v}).to_string()],
        )?;
        let cache = json!({"relativePath":".inputs/frozen/source.raw","sha256":hash(b"excluded-raw"),"byteCount":12,"encoding":"raw"});
        let job =
            json!({"id":"job","request":{"source":source,"inputArtifact":cache},"attempts":[]});
        self.db.execute(
            "INSERT INTO processing_jobs VALUES('job',?)",
            [job.to_string()],
        )?;
        Ok(())
    }
}

#[test]
fn only_admitted_originals_are_recovered_with_working_paths_and_editing_resources() -> Result<()> {
    let l = Library::new()?;
    let dest = l.root.join("generation");
    let restored = l.root.join("restored");
    l.editing()?;
    let look = l.resource("look", "historicalLook", Some("ajpg"), b"rendered-look")?;
    l.resource("sidecar", "sidecar", Some("c"), b"excluded-sidecar")?;
    l.resource("spoof", "derivedPhoto", Some("ajpg"), b"excluded-raw")?;
    l.db.execute("INSERT INTO lc_scopes SELECT 'second-project',session_id,occurrence_id,'another',asset_id,file_id,content_id,kind,operation_id FROM lc_scopes WHERE asset_id='b'",[])?;
    let plan = l.run(json!({"op":"plan","mode":"full"}))?;
    assert_eq!(plan["eligibleFiles"], 2);
    assert_eq!(plan["eligibleReferences"], 3);
    assert_eq!(plan["roots"][0]["files"], 2);
    assert_eq!(plan["roots"][0]["pathHint"], json!(l.source));
    assert_eq!(
        plan["distinctOriginalBytes"],
        (b"admitted-jpeg".len() + b"sequence-only".len()) as i64
    );
    let b = l.backup("full", &dest)?;
    assert_eq!(b["state"], "complete");
    assert_eq!(b["originalReferences"], 3);
    for unused in [
        b"excluded-raw".as_slice(),
        b"excluded-required",
        b"unverified",
        b"excluded-sidecar",
    ] {
        assert!(!object(&dest, unused).exists());
    }
    assert!(object(&dest, b"sequence-only").is_file());
    assert!(object(&dest, b"admitted-jpeg").is_file());
    fs::rename(&l.source, l.root.join("unmounted"))?;
    let r = l.restore(&dest, &restored)?;
    assert_eq!(r["restoredFiles"], 2);
    let db = Connection::open(restored.join("library.sqlite"))?;
    let restored_device: String =
        db.query_row("SELECT value FROM metadata WHERE key='deviceID'", [], |r| {
            r.get(0)
        })?;
    assert_ne!(restored_device, "original-device");
    for (id, name, bytes) in [
        ("b", "B.RAW", b"sequence-only".as_slice()),
        ("ajpg", "A.JPG", b"admitted-jpeg"),
    ] {
        let current: String = db.query_row(
            "SELECT coalesce(json_extract(data,'$.effectiveManagedPath'),json_extract(data,'$.currentPath')) FROM assets WHERE id=?",
            [id],
            |r| r.get(0),
        )?;
        let p = Path::new(&current);
        assert!(p.starts_with(&restored));
        assert_eq!(p.file_name().unwrap(), name);
        assert_eq!(fs::read(p)?, bytes);
        let n: i64 = db.query_row(
            "SELECT count(*) FROM lc_replicas WHERE file_id=? AND kind='restored' AND path=?",
            params![id, current],
            |r| r.get(0),
        )?;
        assert_eq!(n, 1);
        let unresolved: i64 = db.query_row(
            "SELECT count(*) FROM lc_archive_files WHERE file_id=?1 AND (path IS NULL OR path<>?2)",
            params![id, current],
            |r| r.get(0),
        )?;
        assert_eq!(unresolved, 0);
    }
    assert_eq!(
        fs::read(restored.join("LibraryResources").join(look))?,
        b"rendered-look"
    );
    let receipt: Value = serde_json::from_slice(&fs::read(
        restored.join("EditingArchive/receipts/receipt.json"),
    )?)?;
    assert_eq!(receipt["version"]["id"], "v");
    assert_eq!(
        fs::read(restored.join("EditingArchive/artifacts/w/v/receipt.png"))?,
        b"published-pixels"
    );
    assert!(!restored
        .join("EditingArchive/.inputs/frozen/source.raw")
        .exists());
    assert_eq!(l.restore(&dest, &restored)?["alreadyRestored"], true);
    Ok(())
}

#[test]
fn directory_only_relinks_a_moved_tree_and_checks_the_entire_file() -> Result<()> {
    let l = Library::new()?;
    let pkg = l.root.join("catalog-only");
    let restored = l.root.join("portable");
    l.resource("look", "historicalLook", Some("ajpg"), b"historic")?;
    l.backup("catalog", &pkg)?;
    assert!(!object(&pkg, b"admitted-jpeg").exists());
    assert!(object(&pkg, b"historic").exists());
    let moved = l.root.join("new-volume");
    fs::rename(&l.source, &moved)?;
    assert_eq!(l.restore(&pkg, &restored)?["restoredFiles"], 0);
    fs::write(moved.join("B.RAW"), b"SEQUENCE-ONLY")?;
    let request = json!({"op":"relink","fromRoot":l.source,"toRoot":moved});
    let partial = backup::execute(&restored.join("library.sqlite"), &request)?;
    assert_eq!(partial["linkedFiles"], 1);
    assert_eq!(partial["missing"].as_array().unwrap().len(), 1);
    fs::write(moved.join("B.RAW"), b"sequence-only")?;
    let again = backup::execute(&restored.join("library.sqlite"), &request)?;
    assert_eq!(again["state"], "complete");
    assert_eq!(again["linkedFiles"], 2);
    Ok(())
}

#[test]
fn failed_copy_resumes_the_frozen_generation_and_corrupt_backup_can_be_repaired() -> Result<()> {
    let l = Library::new()?;
    let pkg = l.root.join("g");
    let fixed = l.root.join("repaired");
    fs::remove_file(l.source.join("B.RAW"))?;
    let partial = l.backup("full", &pkg)?;
    assert_eq!(partial["state"], "incomplete");
    assert!(!pkg.exists());
    l.db.execute("DELETE FROM lc_scopes WHERE asset_id='b'", [])?;
    fs::write(l.source.join("B.RAW"), b"sequence-only")?;
    let full = l.backup("full", &pkg)?;
    assert_eq!(full["originalReferences"], 2);
    assert_eq!(full["reusedObjects"], 1);
    fs::write(object(&pkg, b"admitted-jpeg"), b"corrupt")?;
    let no = l.root.join("no-restore");
    assert!(l.restore(&pkg, &no).is_err());
    assert!(!no.exists());
    let repair =
        l.run(json!({"op":"backup","mode":"full","destination":fixed,"repairFrom":pkg}))?;
    assert_eq!(repair["state"], "complete");
    assert_eq!(repair["originalReferences"], 2);
    assert_eq!(l.restore(&fixed, &no)?["restoredFiles"], 2);
    Ok(())
}

#[test]
fn forged_references_names_extra_entries_and_symbolic_links_are_rejected() -> Result<()> {
    let l = Library::new()?;
    let pkg = l.root.join("g");
    l.backup("full", &pkg)?;
    let out = l.root.join("restored");
    let manifest = pkg.join("manifest.json");
    let seal = pkg.join("manifest.sha256");
    let original = fs::read(&manifest)?;
    let mut v: Value = serde_json::from_slice(&original)?;
    v["originals"][0]["filename"] = json!("../outside.RAW");
    let tampered = serde_json::to_vec(&v)?;
    fs::write(&manifest, &tampered)?;
    fs::write(&seal, hash(&tampered))?;
    assert!(l.restore(&pkg, &out).is_err());
    assert!(!out.exists());
    fs::write(&manifest, &original)?;
    fs::write(&seal, hash(&original))?;
    fs::write(pkg.join("unexpected.RAW"), b"must never restore")?;
    assert!(l.restore(&pkg, &out).is_err());
    fs::remove_file(pkg.join("unexpected.RAW"))?;
    let raw = object(&pkg, b"sequence-only");
    fs::remove_file(&raw)?;
    std::os::unix::fs::symlink(l.source.join("B.RAW"), &raw)?;
    assert!(l.restore(&pkg, &out).is_err());
    assert!(!out.exists());
    let unsafe_dir = l.source.join("bad-backup");
    assert!(l.backup("catalog", &unsafe_dir).is_err());
    assert!(!unsafe_dir.exists());
    Ok(())
}

#[test]
fn job_input_cannot_wrap_unverified_source_bytes_as_a_png_render() -> Result<()> {
    let l = Library::new()?;
    l.editing()?;
    let rel = ".inputs/frozen/supposed-render.png";
    let path = l.root.join("editing").join(rel);
    fs::create_dir_all(path.parent().unwrap())?;
    let bytes = b"contents of an unverified RAW that is mislabeled as a rendered provider input";
    fs::write(path, bytes)?;
    let job = json!({"id":"forged","request":{"source":{"assetID":"ajpg","contentSHA256":hash(b"admitted-jpeg")},
        "inputArtifact":{"relativePath":rel,"sha256":hash(bytes),"byteCount":bytes.len(),"encoding":"public.png",
            "bitDepth":8,"pixelWidth":1,"pixelHeight":1},"configuration":{"inputPolicy":"bounded-png8-srgb-1mp-v1"}},"attempts":[]});
    l.db.execute(
        "INSERT INTO processing_jobs VALUES('forged',?)",
        [job.to_string()],
    )?;
    let out = l.root.join("bad-input");
    let partial = l.backup("full", &out)?;
    assert_eq!(partial["state"], "incomplete");
    assert!(!out.exists());
    Ok(())
}

#[test]
fn two_admitted_versions_of_one_file_reopen_as_their_own_verified_bytes() -> Result<()> {
    let l = Library::new()?;
    let input = l.source.join("B.RAW");
    let saved = l.root.join("other-disk/B.RAW");
    fs::create_dir(saved.parent().unwrap())?;
    fs::rename(&input, &saved)?;
    let before = b"sequence-only";
    let after = b"new fully verified bytes at the same source filename";
    fs::write(&input, after)?;
    let old_id = format!("sha256:{}:{}", hash(before), before.len());
    l.db.execute_batch("BEGIN IMMEDIATE")?;
    authority::command(
        &l.db,
        &json!({"version":1,"commandID":"other-replica","action":"replica.verify",
        "fileID":"b","contentID":old_id,"rootID":"other","relativePath":"B.RAW","kind":"source","path":saved}),
    )?;
    l.db.execute(
        "UPDATE assets SET data=json_set(data,'$.contentHash',?1,'$.fileSize',?2) WHERE id='b'",
        params![hash(after), after.len() as i64],
    )?;
    l.db.execute("INSERT INTO sessions VALUES('s2',?)",[json!({"id":"s2","projectID":"p","mode":"reference","sourcePath":l.source,"scanCompleted":true,"status":"completed"}).to_string()])?;
    authority::command(
        &l.db,
        &json!({"version":1,"commandID":"repeat","action":"occurrence.put","sessionID":"s2","occurrenceID":"repeat-B","assetID":"b","fileID":"b","relativePath":"B.RAW"}),
    )?;
    authority::command(
        &l.db,
        &json!({"version":1,"commandID":"s2-seal","action":"session.seal","sessionID":"s2",
        "items":[{"occurrenceID":"repeat-B","disposition":"admitted"}]}),
    )?;
    l.db.execute_batch("COMMIT")?;
    let package = l.root.join("history");
    let built = l.backup("full", &package)?;
    assert_eq!(built["state"], "complete");
    assert_eq!(built["coveredScopes"], 3);
    fs::rename(&l.source, l.root.join("source-offline"))?;
    fs::remove_file(&saved)?;
    let restored = l.root.join("separate");
    l.restore(&package, &restored)?;
    let opened = Connection::open(restored.join("library.sqlite"))?;
    let mut q=opened.prepare("SELECT DISTINCT c.sha256,a.current_path FROM lc_archive_files f JOIN lc_asset_input a USING(asset_id)
        JOIN lc_contents c ON c.content_id=f.content_id WHERE f.file_id='b' AND a.content_id=f.content_id")?;
    let rows = q
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    assert_eq!(rows.len(), 2);
    for (digest, path) in rows {
        assert!(Path::new(&path).starts_with(&restored));
        assert_eq!(hash(&fs::read(path)?), digest);
    }
    Ok(())
}

#[test]
fn coverage_distinguishes_eligible_from_verified_and_unplugged_generations() -> Result<()> {
    let l = Library::new()?;
    let full = l.root.join("full");
    let directory = l.root.join("catalog-only");
    let backup = l.backup("full", &full)?;
    let catalog = l.backup("catalog", &directory)?;
    let id = format!(
        "sha256:{}:{}",
        hash(b"admitted-jpeg"),
        b"admitted-jpeg".len()
    );
    let ask = |package: &Path, pin: &Value, file: &str, content: &str| {
        l.run(json!({"op":"coverage","package":package,"expectedManifestSHA256":pin,"fileID":file,"contentID":content}))
    };
    assert_eq!(
        ask(&full, &backup["manifestSHA256"], "ajpg", &id)?["state"],
        "verified"
    );
    assert_eq!(
        ask(&full, &backup["manifestSHA256"], "araw", &id)?["state"],
        "notIncluded"
    );
    assert_eq!(
        ask(&directory, &catalog["manifestSHA256"], "ajpg", &id)?["state"],
        "catalogOnly"
    );
    fs::write(object(&full, b"admitted-jpeg"), b"damaged")?;
    assert_eq!(
        ask(&full, &backup["manifestSHA256"], "ajpg", &id)?["state"],
        "unverified"
    );
    fs::rename(&full, l.root.join("off-volume"))?;
    assert_eq!(
        ask(&full, &backup["manifestSHA256"], "ajpg", &id)?["state"],
        "offline"
    );
    Ok(())
}

#[test]
fn v9_restore_invalidates_active_workers_and_does_not_read_source_workstation_export_paths(
) -> Result<()> {
    let mut l = Library::new()?;
    let tx =
        l.db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    rawmaster_library::transaction(&tx, &json!({"operation":"upgradeScheduler"}))?;
    tx.commit()?;
    let schedule = |path: &Path, body: Value| {
        rawmaster_library::request(path, &json!({"operation":"scheduler","request":body}))
    };
    for key in ["export-1", "export-2"] {
        schedule(
            &l.db_path,
            json!({"op":"submit","key":key,"lane":"export","resource":"io","payload":{},"replaySafe":true}),
        )?;
    }
    let running = schedule(&l.db_path, json!({"op":"claim","key":"export-1"}))?;
    let stage = l.root.join("staged.jpg");
    fs::write(&stage, b"staged source-only bytes")?;
    let final_path = l.root.join("source-output.jpg");
    schedule(
        &l.db_path,
        json!({"op":"prepareExternal","key":"export-1","token":running["token"],"stage":stage,"destination":final_path}),
    )?;
    let safe = schedule(&l.db_path, json!({"op":"claim","key":"export-2"}))?;
    schedule(
        &l.db_path,
        json!({"op":"submit","key":"export-unprepared","lane":"export","resource":"io",
        "payload":{"destination":l.root.join("future-external.jpg")},"replaySafe":true}),
    )?;
    assert_eq!(
        schedule(&l.db_path, json!({"op":"check","key":"export-1","token":running["token"]}))?,
        true
    );
    // The generic queue schema is identical in v9. Seal it in that exact format so the
    // restore must revoke its old leases before a v10 host ever opens the restored copy.
    l.db.execute_batch("BEGIN IMMEDIATE;
        DROP TRIGGER lc_workbench_writer_insert;
        DROP TRIGGER lc_workbench_writer_update;
        DROP TABLE lc_workbench_names;
        PRAGMA user_version=9;
        COMMIT;")?;
    let pkg = l.root.join("catalog-package");
    let copy = l.root.join("restored-library");
    assert_eq!(l.backup("catalog", &pkg)?["state"], "complete");
    let restored = l.restore(&pkg, &copy)?;
    let copied = Path::new(restored["libraryPath"].as_str().unwrap());
    let mut copy_db = Connection::open(copied)?;
    assert_eq!(copy_db.pragma_query_value(None,"user_version",|row| row.get::<_, i64>(0))?, 9);
    assert_eq!(
        copy_db.query_row("SELECT state,prepared_detached,token FROM lc_task_jobs WHERE job_key='export-1'", [],
            |row| Ok((row.get::<_,String>(0)?,row.get::<_,i64>(1)?,row.get::<_,Option<String>>(2)?)))?,
        ("reconcile".into(), 1, None)
    );
    let tx = copy_db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    rawmaster_library::transaction(&tx, &json!({"operation":"upgradeScheduler"}))?;
    tx.commit()?;
    assert_eq!(
        schedule(copied, json!({"op":"status","key":"export-unprepared"}))?["state"],
        "reconcile"
    );
    assert!(schedule(copied, json!({"op":"claim","key":"export-unprepared"}))?.is_null());
    assert_eq!(
        l.db.query_row("SELECT state FROM lc_task_jobs WHERE job_key='export-unprepared'",[],|row| row.get::<_,String>(0))?,
        "queued"
    );
    assert_eq!(
        schedule(copied, json!({"op":"status","key":"export-2"}))?["state"],
        "queued"
    );
    assert!(schedule(
        copied,
        json!({"op":"check","key":"export-2","token":safe["token"]})
    )
    .is_err());
    assert_eq!(
        schedule(copied, json!({"op":"status","key":"export-1"}))?["state"],
        "reconcile"
    );
    assert_eq!(
        schedule(
            copied,
            json!({"op":"preparedExternalTasks","lane":"export","keyPrefix":"export-","limit":64})
        )?,
        json!([])
    );
    assert!(schedule(
        copied,
        json!({"op":"verifyPrepared","key":"export-1","destination":false})
    )
    .is_err());
    assert!(
        schedule(copied, json!({"op":"preparedExternal","key":"export-1"}))?["sha256"].is_string()
    );
    assert_eq!(
        l.db.query_row("SELECT token FROM lc_task_jobs WHERE job_key='export-1'",[],|row| row.get::<_,String>(0))?,
        running["token"].as_str().unwrap()
    );
    assert!(stage.is_file() && !final_path.exists());
    Ok(())
}
