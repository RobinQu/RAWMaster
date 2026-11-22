use rawmaster_library::authority;
use rawmaster_library::Result;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

fn source() -> Result<Connection> {
    let db = Connection::open_in_memory()?;
    db.execute_batch("PRAGMA foreign_keys=ON; BEGIN IMMEDIATE")?;
    db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
    db.execute("INSERT INTO projects VALUES('p1','{}'),('p2','{}')", [])?;
    Ok(db)
}
fn session(db: &Connection, id: &str, project: &str, phase: &str) -> Result<()> {
    let data = json!({"id":id,"projectID":project,"mode":"reference","sourcePath":"/source","status":"completed","scanCompleted":true});
    db.execute(
        "INSERT INTO sessions VALUES(?1,?2)",
        params![id, data.to_string()],
    )?;
    db.execute(
        "INSERT INTO session_workflows VALUES(?1,?2)",
        params![
            id,
            json!({"sessionID":id,"phase":phase,"projectID":project,"importActive":false})
                .to_string()
        ],
    )?;
    Ok(())
}
fn sha(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn asset(
    db: &Connection,
    s: &str,
    p: &str,
    id: &str,
    name: &str,
    bytes: Option<&[u8]>,
) -> Result<()> {
    let path = format!("/{s}/{name}");
    let data = json!({"id":id,"sessionID":s,"projectID":p,"filename":name,"sourcePath":path,"currentPath":path,"relativePath":name,
        "contentHash":bytes.map(sha),"fileSize":bytes.map_or(0,|b|b.len()),"availability":"available","importState":if bytes.is_some(){"ready"}else{"failed"}});
    db.execute(
        "INSERT INTO assets(id,session_id,source_path,data) VALUES(?1,?2,?3,?4)",
        params![id, s, path, data.to_string()],
    )?;
    Ok(())
}
fn triage(db: &Connection, id: &str, status: &str) -> Result<()> {
    db.execute(
        "INSERT INTO triage_records VALUES(?1,?2)",
        params![id, json!({"assetID":id,"disposition":status}).to_string()],
    )?;
    Ok(())
}
fn admission(db: &Connection, id: &str, sequence: bool) -> Result<()> {
    db.execute(
        "INSERT INTO project_admissions VALUES(?1,?2)",
        params![
            id,
            json!({"assetID":id,"projectID":"p1","sequenceOnly":sequence}).to_string()
        ],
    )?;
    Ok(())
}
fn cmd(db: &Connection, op: &str, action: &str, mut data: Value) -> Result<Value> {
    data["commandID"] = json!(op);
    data["version"] = json!(1);
    data["action"] = json!(action);
    authority::command(db, &data)
}
fn list(db: &Connection, sql: &str) -> Result<Vec<String>> {
    let mut st = db.prepare(sql)?;
    let rows = st.query_map([], |r| r.get(0))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}
fn item(id: &str, disposition: &str) -> Value {
    json!({"occurrenceID":id,"disposition":disposition})
}

#[test]
fn seal_exclusions_are_file_specific_and_restoration_is_explicit() -> Result<()> {
    let db = source()?;
    authority::install(&db)?;
    session(&db, "s", "p1", "screening")?;
    for (id, name, bytes) in [
        ("a", "A.RAW", Some(&b"A"[..])),
        ("j", "A.JPG", Some(&b"J"[..])),
        ("b", "B.RAW", Some(&b"B"[..])),
        ("c", "C.RAW", Some(&b"C"[..])),
        ("d", "D.RAW", None),
    ] {
        asset(&db, "s", "p1", id, name, bytes)?;
    }
    triage(&db, "a", "excluded")?;
    triage(&db, "c", "excluded")?;
    cmd(
        &db,
        "pair",
        "capture.pair",
        json!({"rawFileID":"a","jpegFileID":"j","manual":true}),
    )?;
    let bad = json!({"sessionID":"s","items":[item("j","admitted"),item("a","sequenceOnly"),item("b","sequenceOnly"),item("c","excluded"),item("d","failed")]});
    assert!(cmd(&db, "bad", "session.seal", bad).is_err());
    assert!(list(&db, "SELECT file_id FROM lc_catalog_files")?.is_empty());
    let req = json!({"sessionID":"s","items":[item("a","excluded"),item("b","sequenceOnly"),item("c","excluded"),item("d","failed"),item("j","admitted")]});
    let receipt = cmd(&db, "close", "session.seal", req.clone())?;
    assert_eq!(
        receipt["counts"],
        json!({"admitted":1,"sequenceOnly":1,"excluded":2,"failed":1})
    );
    assert_eq!(receipt, cmd(&db, "close", "session.seal", req.clone())?);
    assert!(cmd(
        &db,
        "close",
        "session.seal",
        json!({"sessionID":"s","items":[]})
    )
    .is_err());
    assert!(cmd(&db, "different", "session.seal", req).is_err());
    assert!(cmd(
        &db,
        "again",
        "session.open",
        json!({"sessionID":"s","projectID":"p1"})
    )
    .is_err());
    assert_eq!(
        list(
            &db,
            "SELECT DISTINCT file_id FROM lc_archive_files ORDER BY 1"
        )?,
        ["b", "j"]
    );
    db.execute("UPDATE assets SET data=json_set(data,'$.availability','missing','$.effectiveManagedPath','/offline/old/A.RAW') WHERE id='a'",[])?;
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("A.RAW");
    std::fs::write(&path, b"wrong")?;
    let restore =
        json!({"sessionID":"s","occurrenceID":"a","sha256":sha(b"A"),"byteCount":1,"path":path});
    assert!(cmd(&db, "restore", "admission.restore", restore.clone()).is_err());
    std::fs::write(&path, b"A")?;
    let before = cmd(&db, "restore", "admission.restore", restore.clone())?;
    let (source,json_source,effective_source,opened,available):(String,String,String,String,String)=db.query_row("SELECT source_path,json_extract(data,'$.sourcePath'),json_extract(data,'$.effectiveSourcePath'),COALESCE(json_extract(data,'$.effectiveManagedPath'),json_extract(data,'$.currentPath')),json_extract(data,'$.availability') FROM assets WHERE id='a'",[],|x|Ok((x.get(0)?,x.get(1)?,x.get(2)?,x.get(3)?,x.get(4)?)))?;
    assert_eq!(source, "/s/A.RAW");
    assert_eq!(json_source, source);
    assert_eq!(effective_source, path.to_str().unwrap());
    assert_eq!(available, "available");
    assert_eq!(std::fs::read(opened)?, b"A");
    assert_eq!(before, cmd(&db, "restore", "admission.restore", restore)?);
    assert_eq!(
        list(
            &db,
            "SELECT DISTINCT file_id FROM lc_archive_files ORDER BY 1"
        )?,
        ["a", "b", "j"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT disposition FROM lc_occurrences WHERE occurrence_id='a'"
        )?,
        ["excluded"]
    );
    Ok(())
}

#[test]
fn v7_automatic_necessary_frames_and_implicitly_restored_pairs_stay_out() -> Result<()> {
    let db = source()?;
    session(&db, "history", "p1", "closed")?;
    for (id, name) in [
        ("raw", "A.RAW"),
        ("jpg", "A.JPG"),
        ("old", "old.RAW"),
        ("given", "given.RAW"),
    ] {
        asset(&db, "history", "p1", id, name, Some(id.as_bytes()))?;
        admission(&db, id, id == "raw")?;
    }
    for id in ["raw", "old", "given"] {
        triage(&db, id, "excluded")?;
    }
    db.execute(
        "INSERT INTO capture_pairs VALUES('pair',?1)",
        [
            json!({"sessionID":"history","rawAssetID":"raw","jpegAssetID":"jpg","isManual":true})
                .to_string(),
        ],
    )?;
    db.execute("INSERT INTO workflow_completions VALUES('close',?1)",[json!({"sessionID":"history","projectID":"p1","admittedAssetIDs":["raw","jpg"],"excludedAssetIDs":["old","given"],"sequenceOnlyAssetIDs":["raw"]}).to_string()])?;
    db.execute("INSERT INTO operations VALUES('restore','d','history',0,1,1,'restoreTriageAssets','[\"raw\",\"given\"]',1)",[])?;
    let group = json!({"id":"g","projectID":"p1","kind":"burst","locked":true,"groupRevision":8});
    db.execute(
        "INSERT INTO groups_data VALUES('g','p1',?1)",
        [group.to_string()],
    )?;
    db.execute(
        "INSERT INTO membership VALUES('g','raw',0,0),('g','jpg',1,1)",
        [],
    )?;
    authority::install(&db)?;
    assert_eq!(
        list(
            &db,
            "SELECT DISTINCT file_id FROM lc_archive_files ORDER BY 1"
        )?,
        ["given", "jpg"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT occurrence_id FROM lc_occurrences WHERE disposition='excluded' ORDER BY 1"
        )?,
        ["given", "old", "raw"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT capture_id FROM lc_group_members WHERE group_id='g' AND revision=8"
        )?,
        ["capture:raw"]
    );
    assert_eq!(list(&db,"SELECT file_id FROM lc_group_file_members WHERE group_id='g' AND revision=8 AND included=0")?,["raw"]);
    assert!(authority::validate_schema(&db).is_ok());
    db.execute_batch(
        "DROP VIEW lc_catalog_files; CREATE VIEW lc_catalog_files AS SELECT id FROM assets",
    )?;
    assert!(authority::validate_schema(&db).is_err());
    Ok(())
}

#[test]
fn repeated_content_keeps_occurrences_projects_and_archive_paths_distinct() -> Result<()> {
    let db = source()?;
    authority::install(&db)?;
    for (s, p, id, decision) in [
        ("s1", "p1", "first", "admitted"),
        ("s2", "p2", "second", "admitted"),
        ("s3", "p2", "excluded", "excluded"),
    ] {
        session(&db, s, p, "screening")?;
        asset(&db, s, p, id, "a.RAW", Some(b"same"))?;
        cmd(
            &db,
            &format!("put-{id}"),
            "occurrence.put",
            json!({"sessionID":s,"occurrenceID":"source-1","assetID":id,"fileID":"first"}),
        )?;
        cmd(
            &db,
            &format!("seal-{id}"),
            "session.seal",
            json!({"sessionID":s,"items":[item("source-1",decision)]}),
        )?;
    }
    assert_eq!(
        list(
            &db,
            "SELECT file_id||':'||project_id FROM lc_catalog_files ORDER BY project_id"
        )?,
        ["first:p1", "first:p2"]
    );
    assert_eq!(
        list(&db, "SELECT DISTINCT path FROM lc_archive_files ORDER BY 1")?,
        ["/s1/a.RAW", "/s2/a.RAW"]
    );
    assert_eq!(
        list(&db, "SELECT DISTINCT file_id FROM lc_occurrences")?,
        ["first"]
    );
    assert_eq!(
        list(&db, "SELECT DISTINCT content_id FROM lc_archive_files")?.len(),
        1
    );
    Ok(())
}

#[test]
fn unverified_and_unfinished_legacy_history_do_not_create_archive_entitlements() -> Result<()> {
    let db = source()?;
    session(&db, "legacy", "p1", "legacyHistory")?;
    asset(&db, "legacy", "p1", "complete", "A.RAW", Some(b"accepted"))?;
    asset(&db, "legacy", "p1", "unverified", "B.RAW", None)?;
    admission(&db, "complete", false)?;
    admission(&db, "unverified", false)?;
    session(&db, "unfinished", "p1", "legacyHistory")?;
    db.execute("UPDATE sessions SET data=json_set(data,'$.status','partial','$.scanCompleted',0) WHERE id='unfinished'",[])?;
    asset(&db, "unfinished", "p1", "open-source", "X.RAW", Some(b"X"))?;
    admission(&db, "open-source", false)?;
    authority::install(&db)?;
    assert_eq!(
        list(&db, "SELECT DISTINCT file_id FROM lc_archive_files")?,
        ["complete"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT session_id FROM lc_sessions WHERE state='sealed' ORDER BY 1"
        )?,
        ["legacy", "unfinished"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT occurrence_id FROM lc_occurrences WHERE disposition='failed'"
        )?,
        ["unverified"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT occurrence_id FROM lc_occurrences WHERE disposition='reconcile'"
        )?,
        ["open-source"]
    );
    Ok(())
}

#[test]
fn file_and_group_journal_changes_are_scoped_and_previous_revisions_are_frozen() -> Result<()> {
    let db = source()?;
    authority::install(&db)?;
    session(&db, "s", "p1", "screening")?;
    asset(&db, "s", "p1", "raw", "A.RAW", Some(b"R"))?;
    asset(&db, "s", "p1", "jpg", "A.JPG", Some(b"J"))?;
    let members = json!([{"fileID":"raw","included":false},{"fileID":"jpg","included":true}]);
    cmd(
        &db,
        "g1",
        "group.revise",
        json!({"groupID":"G","projectID":"p1","kind":"burst","locked":true,"baseRevision":0,"members":members}),
    )?;
    let ambiguous = cmd(
        &db,
        "candidate",
        "capture.pair",
        json!({"rawFileID":"raw","jpegFileID":"jpg","manual":false,"evidence":{"raw":{"cameraSerial":"1","frameNumber":"3","captureTime":"T"},"jpeg":{"cameraSerial":"2","frameNumber":"3","captureTime":"T"}}}),
    )?;
    assert_eq!(ambiguous["status"], "review");
    cmd(
        &db,
        "pair",
        "capture.pair",
        json!({"rawFileID":"raw","jpegFileID":"jpg","manual":true}),
    )?;
    assert_eq!(list(&db,"SELECT capture_id FROM lc_group_members WHERE group_id='G' AND revision=1 ORDER BY position")?,["capture:raw","capture:jpg"]);
    assert_eq!(
        list(
            &db,
            "SELECT capture_id FROM lc_group_members WHERE group_id='G' AND revision=2"
        )?,
        ["capture:raw"]
    );
    assert_eq!(list(&db,"SELECT file_id FROM lc_group_file_members WHERE group_id='G' AND revision=2 AND included=0")?,["raw"]);
    cmd(
        &db,
        "split",
        "capture.split",
        json!({"rawFileID":"raw","jpegFileID":"jpg","manual":true}),
    )?;
    assert_eq!(list(&db,"SELECT capture_id FROM lc_group_members WHERE group_id='G' AND revision=3 ORDER BY position")?,["capture:raw","capture:jpg"]);
    assert!(cmd(&db,"stale","group.revise",json!({"groupID":"G","projectID":"p1","kind":"burst","locked":false,"baseRevision":1,"members":[]})).is_err());
    assert!(list(
        &db,
        "SELECT domain FROM lc_changes WHERE asset_id IS NULL AND domain <> 'install'"
    )?
    .is_empty());
    let total: i64 = db.query_row(
        "SELECT count(*) FROM lc_changes WHERE asset_id='raw'",
        [],
        |r| r.get(0),
    )?;
    assert!(total > 0);
    Ok(())
}

#[test]
fn compatible_scans_recover_corroboration_and_direct_import_closes_once() -> Result<()> {
    let db = source()?;
    authority::install(&db)?;
    session(&db, "normal", "p1", "screening")?;
    for (id, name) in [
        ("n1", "A.RAW"),
        ("n2", "A.JPG"),
        ("amb1", "B.RAW"),
        ("amb2", "B.JPG"),
        ("amb3", "B.DNG"),
    ] {
        asset(&db, "normal", "p1", id, name, Some(id.as_bytes()))?;
    }
    db.execute("UPDATE assets SET data=json_set(data,'$.capturedAt',12.5,'$.camera','Model A','$.width',800,'$.height',600) WHERE session_id='normal'",[])?;
    for (id, raw, jpg) in [("same", "n1", "n2"), ("ambiguous", "amb1", "amb2")] {
        let pair = json!({"id":id,"rawAssetID":raw,"jpegAssetID":jpg,"sessionID":"normal","isManual":false});
        db.execute(
            "INSERT INTO capture_pairs VALUES(?1,?2)",
            params![id, pair.to_string()],
        )?;
    }
    authority::flush_legacy(&db)?;
    assert_eq!(
        list(
            &db,
            "SELECT action FROM lc_pair_events WHERE raw_file_id='n1'"
        )?,
        ["paired"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT action FROM lc_pair_events WHERE raw_file_id='amb1'"
        )?,
        ["review"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT json_extract(evidence,'$.source') FROM lc_pair_events WHERE raw_file_id='n1'"
        )?,
        ["v7-source-corroboration-v1"]
    );
    assert!(cmd(
        &db,
        "early",
        "session.finishDirect",
        json!({"sessionID":"normal"})
    )
    .is_err());
    let data = json!({"id":"direct","projectID":"p1","mode":"reference","sourcePath":"/sources","status":"completed","scanCompleted":true});
    db.execute(
        "INSERT INTO sessions VALUES('direct',?1)",
        [data.to_string()],
    )?;
    for (id, name) in [("d1", "C.RAW"), ("d2", "C.JPG")] {
        asset(&db, "direct", "p1", id, name, Some(id.as_bytes()))?;
        admission(&db, id, false)?;
    }
    db.execute("UPDATE assets SET data=json_set(data,'$.capturedAt',24.25,'$.camera','Model B','$.width',800,'$.height',600) WHERE session_id='direct'",[])?;
    assert!(list(
        &db,
        "SELECT file_id FROM lc_catalog_files WHERE file_id IN ('d1','d2')"
    )?
    .is_empty());
    let request = json!({"sessionID":"direct"});
    let result = cmd(
        &db,
        "direct-close/direct",
        "session.finishDirect",
        request.clone(),
    )?;
    assert_eq!(result["counts"]["admitted"], 2);
    assert_eq!(
        result,
        cmd(&db, "direct-close/direct", "session.finishDirect", request)?
    );
    assert_eq!(
        list(
            &db,
            "SELECT DISTINCT capture_id FROM lc_catalog_files WHERE file_id IN ('d1','d2')"
        )?,
        ["capture:d1"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT DISTINCT file_id FROM lc_archive_files ORDER BY file_id"
        )?,
        ["d1", "d2"]
    );
    Ok(())
}

#[test]
fn restoring_an_old_version_leaves_the_newer_host_and_sealed_history_intact() -> Result<()> {
    let db = source()?;
    authority::install(&db)?;
    session(&db, "old", "p1", "screening")?;
    asset(&db, "old", "p1", "photo", "IMG.RAW", Some(b"earlier"))?;
    triage(&db, "photo", "excluded")?;
    cmd(
        &db,
        "seal-old",
        "session.seal",
        json!({"sessionID":"old","items":[item("photo","excluded")]}),
    )?;
    let dir = tempfile::tempdir()?;
    let later = dir.path().join("later.raw");
    let first = dir.path().join("earlier.raw");
    std::fs::write(&later, b"later")?;
    std::fs::write(&first, b"earlier")?;
    db.execute("UPDATE assets SET data=json_set(data,'$.contentHash',?1,'$.fileSize',5,'$.effectiveSourcePath',?2,'$.currentPath',?2) WHERE id='photo'",params![sha(b"later"),later.to_str()])?;
    session(&db, "new", "p2", "screening")?;
    cmd(
        &db,
        "record-new",
        "occurrence.put",
        json!({"sessionID":"new","assetID":"photo","occurrenceID":"found"}),
    )?;
    cmd(
        &db,
        "close-new",
        "session.seal",
        json!({"sessionID":"new","items":[item("found","admitted")]}),
    )?;
    let got = cmd(
        &db,
        "recover",
        "admission.restore",
        json!({"sessionID":"old","occurrenceID":"photo","sha256":sha(b"earlier"),"byteCount":7,"path":first}),
    )?;
    let representative = got["assetID"].as_str().unwrap();
    assert_ne!(representative, "photo");
    let read = |id: &str| -> Result<Vec<u8>> {
        let path:String=db.query_row("SELECT COALESCE(json_extract(data,'$.effectiveManagedPath'),json_extract(data,'$.currentPath')) FROM assets WHERE id=?1",[id],|r|r.get(0))?;
        Ok(std::fs::read(path)?)
    };
    assert_eq!(read("photo")?, b"later");
    assert_eq!(read(representative)?, b"earlier");
    assert_eq!(
        list(&db, "SELECT occurrence_id FROM lc_occurrences ORDER BY 1")?,
        ["found", "photo"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT asset_id FROM lc_occurrences WHERE session_id='old'"
        )?,
        ["photo"]
    );
    assert_eq!(
        list(&db, "SELECT asset_id FROM lc_scopes WHERE project_id='p1'")?,
        [representative]
    );
    assert_eq!(
        list(&db, "SELECT asset_id FROM lc_scopes WHERE project_id='p2'")?,
        ["photo"]
    );
    assert_eq!(
        list(
            &db,
            "SELECT session_id FROM lc_sessions WHERE origin<>'version-host' ORDER BY 1"
        )?,
        ["new", "old"]
    );
    Ok(())
}
