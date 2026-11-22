use rawmaster_library::{managed_files, transaction, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf};
use tempfile::TempDir;
use uuid::Uuid;

struct Fixture {
    _temp: TempDir,
    db: Connection,
    path: PathBuf,
    card: PathBuf,
    managed: PathBuf,
    target: PathBuf,
}
impl Fixture {
    fn new() -> Result<Self> {
        let temp = tempfile::tempdir()?;
        let base = temp.path().canonicalize()?;
        let card = base.join("card");
        let managed = base.join("managed");
        let target = base.join("target");
        for dir in [&card, &managed, &target] {
            fs::create_dir(dir)?
        }
        let path = base.join("library.sqlite");
        let mut db = Connection::open(&path)?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL")?;
        let tx = db.transaction()?;
        tx.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
        transaction(&tx, &json!({"operation":"install"}))?;
        tx.execute_batch("PRAGMA user_version=8")?;
        tx.execute("INSERT INTO projects VALUES('p','{}')", [])?;
        let s = json!({"id":"s","projectID":"p","sourcePath":card,"destinationPath":managed,"mode":"copy","status":"completed","scanCompleted":true});
        tx.execute("INSERT INTO sessions VALUES('s',?1)", [s.to_string()])?;
        let hash = hex::encode(Sha256::digest(b"image A"));
        let original = card.join("A.ARW");
        let copy = managed.join("A.ARW");
        fs::write(&original, b"image A")?;
        fs::copy(&original, &copy)?;
        fs::write(managed.join("A.xmp"), b"metadata")?;
        let a = json!({"id":"a","sessionID":"s","filename":"A.ARW","relativePath":"A.ARW","currentPath":copy,
            "sourcePath":original,"effectiveManagedPath":copy,"fileSize":7,"contentHash":hash,"availability":"available","importState":"ready"});
        tx.execute(
            "INSERT INTO assets(id,session_id,source_path,data) VALUES('a','s',?1,?2)",
            params![original.to_str(), a.to_string()],
        )?;
        transaction(
            &tx,
            &json!({"operation":"command","request":{"version":1,"commandID":"seal","action":"session.seal","sessionID":"s",
            "items":[{"occurrenceID":"a","disposition":"admitted"}]}}),
        )?;
        tx.commit()?;
        Ok(Self {
            _temp: temp,
            db,
            path,
            card,
            managed,
            target,
        })
    }
    fn body(&self, op: &str) -> Value {
        json!({"op":op,"items":[{"assetID":"a","directory":self.target,"filename":"B.ARW"}]})
    }
    fn preview(&self) -> Result<Value> {
        managed_files::execute(&self.path, &self.body("preview"))
    }
    fn start(&self, preview: &Value, id: &str) -> Result<Value> {
        let mut r = self.body("start");
        r["fingerprint"] = preview["fingerprint"].clone();
        r["planID"] = json!(id);
        managed_files::execute(&self.path, &r)
    }
}
#[test]
fn move_original_and_sidecar_then_reopen_and_replay() -> Result<()> {
    let l = Fixture::new()?;
    let job = Uuid::new_v4().to_string();
    let p = l.preview()?;
    assert_eq!(p["items"].as_array().unwrap().len(), 2);
    let r = l.start(&p, &job)?;
    assert_eq!(r["state"], "done", "{r}");
    assert_eq!(fs::read(l.card.join("A.ARW"))?, b"image A");
    assert!(!l.managed.join("A.ARW").exists());
    assert!(!l.managed.join("A.xmp").exists());
    assert_eq!(fs::read(l.target.join("B.ARW"))?, b"image A");
    assert_eq!(fs::read(l.target.join("B.xmp"))?, b"metadata");
    let db = Connection::open(&l.path)?;
    let path: String = db.query_row(
        "SELECT json_extract(data,'$.currentPath') FROM assets WHERE id='a'",
        [],
        |r| r.get(0),
    )?;
    assert_eq!(PathBuf::from(path), l.target.join("B.ARW"));
    assert_eq!(l.start(&p, &job)?, r);
    Ok(())
}
#[test]
fn stale_preview_collision_and_referenced_source_are_preserved() -> Result<()> {
    let l = Fixture::new()?;
    let preview = l.preview()?;
    fs::write(l.target.join("B.xmp"), b"a different sidecar")?;
    assert!(l.start(&preview, &Uuid::new_v4().to_string()).is_err());
    assert_eq!(fs::read(l.managed.join("A.ARW"))?, b"image A");
    assert_eq!(fs::read(l.target.join("B.xmp"))?, b"a different sidecar");
    fs::remove_file(l.target.join("B.xmp"))?;
    fs::write(l.managed.join("A.xmp"), b"new local metadata")?;
    assert!(l.start(&preview, &Uuid::new_v4().to_string()).is_err());
    l.db.execute(
        "UPDATE assets SET data=json_set(data,'$.effectiveSourcePath',?1) WHERE id='a'",
        [l.managed.join("A.ARW").to_str().unwrap()],
    )?;
    assert!(l.preview().is_err());
    Ok(())
}
