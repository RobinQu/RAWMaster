//! Opt in with the private existing RAW sample directory and a real camera JPEG.
use rawmaster_library::{request, transaction, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::time::Instant;

fn digest(path: &Path) -> Result<String> {
    let mut hash = Sha256::new();
    let mut source = File::open(path)?;
    let mut buf = vec![0; 1 << 18];
    loop {
        let n = source.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(hex::encode(hash.finalize()))
}
fn command(db: &Connection, action: &str, id: &str, mut data: Value) -> Result<Value> {
    data["version"] = json!(1);
    data["action"] = json!(action);
    data["commandID"] = json!(id);
    transaction(db, &json!({"operation":"command","request":data}))
}
fn package(catalog: &Path, body: Value) -> Result<Value> {
    request(catalog, &json!({"operation":"package","request":body}))
}
fn objects(dir: &Path) -> Result<BTreeSet<String>> {
    let mut result = BTreeSet::new();
    for prefix in fs::read_dir(dir.join("objects"))? {
        for entry in fs::read_dir(prefix?.path())? {
            let file = entry?.path();
            let hash = digest(&file)?;
            assert_eq!(file.file_name().unwrap().to_str(), Some(hash.as_str()));
            assert!(result.insert(hash));
        }
    }
    Ok(result)
}

fn scenario(raws: &[PathBuf], jpeg: &Path, reverse: bool) -> Result<Value> {
    let temp = tempfile::tempdir()?;
    let base = temp.path().canonicalize()?;
    let source = base.join("card");
    let live = base.join("live");
    fs::create_dir(&source)?;
    fs::create_dir(&live)?;
    let catalog = live.join("library.sqlite");
    let mut db = Connection::open(&catalog)?;
    db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL")?;
    let tx = db.transaction()?;
    tx.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
    transaction(&tx, &json!({"operation":"install"}))?;
    tx.execute_batch("PRAGMA user_version=8")?;
    tx.execute(
        "INSERT INTO projects VALUES('p',?1)",
        [json!({"id":"p","name":"实拍回归"}).to_string()],
    )?;
    tx.execute(
        "INSERT INTO sessions VALUES('s',?1)",
        [json!({"id":"s","projectID":"p","mode":"reference",
        "sourcePath":source,"status":"completed","scanCompleted":true})
        .to_string()],
    )?;
    tx.execute(
        "INSERT INTO session_workflows VALUES('s',?1)",
        [
            json!({"sessionID":"s","projectID":"p","phase":"screening","importActive":false})
                .to_string(),
        ],
    )?;
    command(
        &tx,
        "session.open",
        "open",
        json!({"sessionID":"s","projectID":"p"}),
    )?;
    let mut hashes = Vec::new();
    let mut items = Vec::new();
    let dispositions = if reverse {
        ["admitted", "excluded", "sequenceOnly", "excluded", "failed"]
    } else {
        ["excluded", "admitted", "sequenceOnly", "excluded", "failed"]
    };
    let files = [
        ("ar", "A.ARW", &raws[0]),
        ("aj", "A.JPG", &jpeg.to_owned()),
        ("b", "B.ARW", &raws[1]),
        ("c", "C.ARW", &raws[2]),
        ("d", "D.ARW", &raws[3]),
    ];
    for ((id, name, from), &disposition) in files.iter().zip(&dispositions) {
        let path = source.join(name);
        fs::copy(from, &path)?;
        let sha = digest(&path)?;
        let verified = disposition != "failed";
        let bytes = fs::metadata(&path)?.len();
        let a = json!({"id":id,"sessionID":"s","projectID":"p","filename":name,"sourcePath":path,
            "currentPath":path,"relativePath":name,"contentHash":verified.then_some(&sha),"fileSize":bytes,
            "availability":"available","importState":if verified{"ready"}else{"failed"}});
        tx.execute(
            "INSERT INTO assets(id,session_id,source_path,data) VALUES(?1,'s',?2,?3)",
            params![id, path.to_str(), a.to_string()],
        )?;
        if disposition == "excluded" {
            tx.execute(
                "INSERT INTO triage_records VALUES(?1,?2)",
                params![
                    id,
                    json!({"assetID":id,"disposition":"excluded"}).to_string()
                ],
            )?;
        }
        items.push(json!({"occurrenceID":id,"disposition":disposition}));
        hashes.push(sha);
    }
    assert_eq!(hashes.iter().collect::<BTreeSet<_>>().len(), 5);
    command(
        &tx,
        "capture.pair",
        "pair",
        json!({"manual":true,"rawFileID":"ar","jpegFileID":"aj"}),
    )?;
    let group = json!({"id":"sequence","projectID":"p","kind":"timelapse","assetIDs":["ar","aj","b","c"],
        "includedAssetIDs":["ar","aj","b","c"],"groupRevision":1,"locked":true});
    tx.execute(
        "INSERT INTO groups_data VALUES('sequence','p',?1)",
        [group.to_string()],
    )?;
    for (position, id) in ["ar", "aj", "b", "c"].iter().enumerate() {
        tx.execute(
            "INSERT INTO membership VALUES('sequence',?1,?2,1)",
            params![id, position as i64],
        )?;
    }
    transaction(&tx, &json!({"operation":"flushLegacy"}))?;
    let seal = json!({"sessionID":"s","items":items});
    let receipt = command(&tx, "session.seal", "once", seal.clone())?;
    tx.commit()?;
    drop(db);
    let mut reopened = Connection::open(&catalog)?;
    let replay = reopened.transaction()?;
    assert_eq!(command(&replay, "session.seal", "once", seal)?, receipt);
    replay.commit()?;
    let first = base.join("first");
    let start = Instant::now();
    let backed = package(
        &catalog,
        json!({"op":"backup","mode":"full","destination":first}),
    )?;
    assert_eq!(backed["state"], "complete");
    let selected = if reverse { 0 } else { 1 };
    let expected: BTreeSet<String> = [hashes[selected].clone(), hashes[2].clone()].into();
    assert_eq!(objects(&first)?, expected);
    let backup_ms = start.elapsed().as_secs_f64() * 1000.;
    let unmounted = base.join("offline-card");
    fs::rename(&source, &unmounted)?;
    let restored = base.join("restored");
    let restore = package(
        &catalog,
        json!({"op":"restore","package":first,"destination":restored}),
    )?;
    assert_eq!(restore["restoredFiles"], 2);
    let independent = Connection::open(restored.join("library.sqlite"))?;
    transaction(&independent, &json!({"operation":"validate"}))?;
    let mut st = independent.prepare("SELECT DISTINCT file_id FROM lc_archive_files ORDER BY 1")?;
    let ids: Vec<String> = st
        .query_map([], |row| row.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    assert_eq!(
        ids,
        if reverse {
            vec!["ar", "b"]
        } else {
            vec!["aj", "b"]
        }
    );
    let excluded = if reverse { 1 } else { 0 };
    let (id, name, _) = files[excluded];
    let path = unmounted.join(name);
    let tx = reopened.transaction()?;
    command(
        &tx,
        "admission.restore",
        "restore-one",
        json!({"sessionID":"s","occurrenceID":id,"path":path,
        "sha256":hashes[excluded],"byteCount":fs::metadata(&path)?.len()}),
    )?;
    tx.commit()?;
    let second = base.join("second");
    let incremental = package(
        &catalog,
        json!({"op":"backup","mode":"full","destination":second,"previousPackage":first}),
    )?;
    assert_eq!(incremental["state"], "complete");
    let mut later = expected;
    later.insert(hashes[excluded].clone());
    assert_eq!(objects(&second)?, later);
    Ok(
        json!({"swappedPair":reverse,"sealCounts":receipt["counts"],"sourceFiles":files.len(),"archivedFiles":ids,
        "distinctObjects":2,"restoredFiles":restore["restoredFiles"],"objectsAfterExplicitRestore":3,"backupAndReadbackMs":backup_ms}),
    )
}

#[test]
#[ignore = "requires existing real RAWs and an actual JPEG"]
fn complete_packages_exclude_originals_through_pair_group_restart_and_restore() -> Result<()> {
    let folder = PathBuf::from(std::env::var("RAWMASTER_CATALOG_SAMPLE_DIR")?);
    let jpeg = PathBuf::from(std::env::var("RAWMASTER_CATALOG_SAMPLE_JPEG")?);
    let mut raws: Vec<_> = fs::read_dir(folder)?
        .map(|row| row.map(|v| v.path()))
        .collect::<io::Result<Vec<_>>>()?
        .into_iter()
        .filter(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("arw")))
        .collect();
    raws.sort();
    if raws.len() < 4 {
        return Err("at least four distinct Sony RAW samples are required".into());
    }
    let rows = [
        scenario(&raws, &jpeg, false)?,
        scenario(&raws, &jpeg, true)?,
    ];
    if let Ok(path) = std::env::var("RAWMASTER_CATALOG_ARCHIVE_REPORT") {
        let out = File::create_new(path)?;
        serde_json::to_writer_pretty(out, &rows)?;
    }
    Ok(())
}
