use rawmaster_library::{authority, processing, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};
use uuid::Uuid;
fn cmd(db: &Connection, id: &str, action: &str, mut v: Value) -> Result<Value> {
    v["commandID"] = json!(id);
    v["version"] = json!(1);
    v["action"] = json!(action);
    authority::command(db, &v)
}
fn library(folder: &Path) -> Result<(PathBuf, Connection)> {
    let path = folder.join("catalog.sqlite");
    let db = Connection::open(&path)?;
    db.execute_batch("PRAGMA foreign_keys=ON;BEGIN IMMEDIATE")?;
    db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
    db.execute("INSERT INTO projects VALUES('p','{}')", [])?;
    rawmaster_library::transaction(&db, &json!({"operation":"install"}))?;
    db.execute("INSERT INTO sessions VALUES('s',?1)",[json!({"id":"s","projectID":"p","mode":"reference","status":"completed","scanCompleted":true}).to_string()])?;
    db.execute(
        "INSERT INTO session_workflows VALUES('s',?1)",
        [
            json!({"phase":"screening","sessionID":"s","projectID":"p","importActive":false})
                .to_string(),
        ],
    )?;
    for (asset, name, data) in [
        ("a", "A.RAW", b"A".as_slice()),
        ("aj", "A.JPG", b"J"),
        ("b", "B.RAW", b"B"),
        ("deny", "D.RAW", b"X"),
    ] {
        let src = folder.join(name);
        fs::write(&src, data)?;
        let sha = hex::encode(Sha256::digest(data));
        let v = json!({"id":asset,"sessionID":"s","projectID":"p","sourcePath":src,"currentPath":src,"relativePath":name,"filename":name,"importState":"ready","availability":"available","contentHash":sha,"fileSize":data.len()});
        db.execute(
            "INSERT INTO assets(id,session_id,source_path,data) VALUES(?1,'s',?2,?3)",
            params![asset, src.to_str(), v.to_string()],
        )?;
    }
    cmd(
        &db,
        "pair",
        "capture.pair",
        json!({"rawFileID":"a","jpegFileID":"aj","manual":true}),
    )?;
    cmd(
        &db,
        "seal",
        "session.seal",
        json!({"sessionID":"s","items":[{"occurrenceID":"a","disposition":"admitted"},{"occurrenceID":"aj","disposition":"admitted"},{"occurrenceID":"b","disposition":"sequenceOnly"},{"occurrenceID":"deny","disposition":"excluded"}]}),
    )?;
    cmd(
        &db,
        "group",
        "group.revise",
        json!({"groupID":"G","projectID":"p","kind":"timelapse","locked":true,"baseRevision":0,"members":[{"fileID":"aj","included":true},{"fileID":"a","included":true},{"fileID":"deny","included":false},{"fileID":"b","included":true}]}),
    )?;
    db.execute_batch("PRAGMA user_version=8; COMMIT")?;
    Ok((path, db))
}
fn atom(tag: &[u8; 4], bytes: Vec<u8>) -> Vec<u8> {
    let mut out = ((bytes.len() + 8) as u32).to_be_bytes().to_vec();
    out.extend(tag);
    out.extend(bytes);
    out
}
fn test_movie() -> Vec<u8> {
    let mut desc = vec![0; 28];
    desc[24..28].copy_from_slice(&[0, 16, 0, 12]);
    let stsd = atom(
        b"stsd",
        [vec![0, 0, 0, 0, 0, 0, 0, 1], atom(b"avc1", desc)].concat(),
    );
    let stsz = atom(
        b"stsz",
        [0u32.to_be_bytes(), 1u32.to_be_bytes(), 2u32.to_be_bytes()].concat(),
    );
    let stco = atom(
        b"stco",
        [0u32.to_be_bytes(), 1u32.to_be_bytes(), 20u32.to_be_bytes()].concat(),
    );
    let stsc = atom(
        b"stsc",
        [
            0u32.to_be_bytes(),
            1u32.to_be_bytes(),
            1u32.to_be_bytes(),
            2u32.to_be_bytes(),
            1u32.to_be_bytes(),
        ]
        .concat(),
    );
    let md = atom(
        b"mdia",
        [
            atom(b"hdlr", [vec![0; 8], b"vide".to_vec()].concat()),
            atom(b"minf", atom(b"stbl", [stsd, stsz, stsc, stco].concat())),
        ]
        .concat(),
    );
    [
        atom(b"ftyp", b"isom".to_vec()),
        atom(b"mdat", vec![1, 2]),
        atom(b"moov", atom(b"trak", md)),
    ]
    .concat()
}
fn frozen(p: &Path, j: &str) -> Result<Value> {
    processing::execute(
        p,
        &json!({"action":"freeze","jobID":j,"groupID":"G","revision":1,"operation":"timelapse","recipe":{"frameRate":10}}),
    )
}
#[test]
fn frozen_order_alternate_content_recovery_and_reverse_links() -> Result<()> {
    let t = tempfile::tempdir()?;
    let (path, db) = library(t.path())?;
    let jid = Uuid::new_v4().to_string();
    let packs = tempfile::tempdir()?;
    let folder = packs.path().canonicalize()?;
    let prior = folder.join("before");
    let next = folder.join("after");
    let restored = folder.join("restored");
    let package = rawmaster_library::backup::execute(
        &path,
        &json!({"op":"backup","mode":"full","destination":prior,"generation":"before-job"}),
    )?;
    assert_eq!(package["state"], "complete");
    let first = frozen(&path, &jid)?;
    assert_eq!(first["state"], "queued");
    assert_eq!(first, frozen(&path, &jid)?);
    let conflict = json!({"action":"freeze","jobID":jid,"groupID":"G","revision":1,"operation":"hdr","recipe":{}});
    assert!(processing::execute(&path, &conflict).is_err());
    let orphan = processing::execute(&path, &json!({"action":"claim","jobID":jid}))?;
    let orphan_dir = Path::new(orphan["outputPath"].as_str().unwrap())
        .parent()
        .unwrap();
    db.execute(
        "UPDATE lc_proc_jobs SET lease_until=0 WHERE job_id=?1",
        [&jid],
    )?;
    let ready = processing::execute(&path, &json!({"action":"claim","jobID":jid}))?;
    assert_ne!(orphan["token"], ready["token"]);
    let frames = ready["frames"].as_array().unwrap();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["fileID"], "a");
    assert_eq!(frames[1]["fileID"], "b");
    assert!(processing::execute(&path, &json!({"action":"claim","jobID":jid})).is_err());
    let src = PathBuf::from(frames[0]["path"].as_str().unwrap());
    assert_eq!(fs::read(&src)?, b"A");
    fs::write(t.path().join("A.RAW"), b"original changed after freeze")?;
    assert_eq!(fs::read(&src)?, b"A");
    db.execute_batch("BEGIN")?;
    cmd(
        &db,
        "group2",
        "group.revise",
        json!({"groupID":"G","projectID":"p","kind":"timelapse","locked":true,"baseRevision":1,"members":[{"fileID":"b","included":true},{"fileID":"a","included":true}]}),
    )?;
    db.execute_batch("COMMIT")?;
    let movie = test_movie();
    fs::write(ready["outputPath"].as_str().unwrap(), &movie)?;
    let used = frames
        .iter()
        .map(|f| json!({"fileID":f["fileID"],"contentID":f["contentID"],"sha256":f["sha256"]}))
        .collect::<Vec<_>>();
    let receipt = json!({"mediaKind":"derivedVideo","format":"mp4","width":16,"height":12,"frameCount":2,"engineVersion":"fixture-1","facts":{"readback":"fixture structure","inputs":used}});
    fs::write(
        ready["receiptPath"].as_str().unwrap(),
        serde_json::to_vec(&receipt)?,
    )?;
    let staged = processing::execute(&path, &json!({"action":"claim","jobID":jid}))?;
    assert_eq!(staged["state"], "staged");
    let published = processing::execute(&path, &json!({"action":"publish","jobID":jid}))?;
    assert_eq!(published["state"], "published");
    assert!(!orphan_dir.exists());
    db.execute_batch("BEGIN IMMEDIATE")?;
    rawmaster_library::organization::apply(
        &db,
        &json!({"action":"org.saveWork","kind":"virtual","masterWorkID":published["workID"],"workID":"derived-video-copy","name":"Derived movie copy"}),
    )?;
    db.execute_batch("COMMIT")?;
    let virtual_media = rawmaster_library::lightroom::execute(
        &path,
        &json!({"action":"workMedia","workID":"derived-video-copy"}),
    )?;
    assert_eq!(virtual_media["kind"], "derivedVideo");
    assert_eq!(virtual_media["sourceWorkID"], published["workID"]);
    assert_eq!(virtual_media["resourceID"], published["resourceID"]);
    for (project, expected) in [("p", true), ("another-project", false)] {
        let page = rawmaster_library::query::page(
            &path,
            &t.path().join("project-search.sqlite"),
            &json!({"level":"work","projectID":project,"pageSize":32}),
        )?;
        assert_eq!(
            page["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|w| w["workID"] == published["workID"]),
            expected,
            "{page}"
        );
    }
    assert_eq!(
        published,
        processing::execute(&path, &json!({"action":"publish","jobID":jid}))?
    );
    let trace = processing::execute(
        &path,
        &json!({"action":"trace","workID":published["workID"]}),
    )?;
    assert_eq!(trace["revision"], 1);
    assert_eq!(trace["inputs"].as_array().unwrap().len(), 4);
    assert_eq!(
        processing::execute(&path, &json!({"action":"list","fileID":"b"}))?["jobs"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let final_path = processing::execute(&path, &json!({"action":"inspectOutput","jobID":jid}))?;
    assert_eq!(fs::read(final_path["path"].as_str().unwrap())?, movie);
    assert_eq!(
        db.query_row("SELECT count(*) FROM lc_org_derived", [], |r| r
            .get::<_, i64>(0))?,
        1
    );
    let redo = Uuid::new_v4().to_string();
    let remade = processing::execute(
        &path,
        &json!({"action":"remake","jobID":redo,"parentJobID":jid}),
    )?;
    assert_eq!(remade["revision"], 1);
    let increment = rawmaster_library::backup::execute(
        &path,
        &json!({"op":"backup","mode":"full","destination":next,"previousPackage":prior,"generation":"after-job"}),
    )?;
    assert_eq!(increment["state"], "complete");
    assert!(increment["reusedObjects"].as_u64().unwrap_or(0) > 0);
    assert!(increment["copiedObjects"].as_u64().unwrap_or(0) > 0);
    rawmaster_library::backup::execute(
        &path,
        &json!({"op":"restore","package":next,"destination":restored}),
    )?;
    let recovered = processing::execute(
        &restored.join("library.sqlite"),
        &json!({"action":"inspectOutput","jobID":jid}),
    )?;
    assert_eq!(fs::read(recovered["path"].as_str().unwrap())?, movie);
    let origins = processing::execute(
        &restored.join("library.sqlite"),
        &json!({"action":"trace","workID":published["workID"]}),
    )?;
    assert_eq!(origins["inputs"], trace["inputs"]);
    // A same-length post-restore corruption must be detected when the user opens the managed output.
    let mut altered = movie;
    altered[0] ^= 1;
    fs::write(recovered["path"].as_str().unwrap(), altered)?;
    assert!(processing::execute(
        &restored.join("library.sqlite"),
        &json!({"action":"inspectOutput","jobID":jid})
    )
    .is_err());
    Ok(())
}
#[test]
fn unavailable_raw_does_not_switch_to_jpeg_or_accept_a_stale_attempt() -> Result<()> {
    let t = tempfile::tempdir()?;
    let (path, _db) = library(t.path())?;
    let j = Uuid::new_v4().to_string();
    frozen(&path, &j)?;
    fs::remove_file(t.path().join("A.RAW"))?;
    assert!(processing::execute(&path, &json!({"action":"claim","jobID":j})).is_err());
    let failed = processing::execute(&path, &json!({"action":"status","jobID":j}))?;
    assert_eq!(failed["state"], "failed");
    fs::write(t.path().join("A.RAW"), b"A")?;
    let active = processing::execute(&path, &json!({"action":"claim","jobID":j}))?;
    assert!(processing::execute(
        &path,
        &json!({"action":"cancel","jobID":j,"token":failed["token"]})
    )
    .is_err());
    assert_eq!(
        processing::execute(
            &path,
            &json!({"action":"cancel","jobID":j,"token":active["token"]})
        )?["state"],
        "cancelled"
    );
    Ok(())
}
#[test]
#[ignore = "Run with an explicit verified image group, native renderer, and private output directory"]
fn real_group_renders_and_publishes_one_independent_master() -> Result<()> {
    let input: Value = serde_json::from_slice(&fs::read(std::env::var("RAWMASTER_GROUP_INPUT")?)?)?;
    let output = PathBuf::from(std::env::var("RAWMASTER_GROUP_OUTPUT")?);
    fs::create_dir_all(&output)?;
    let path = output.join("catalog.sqlite");
    let db = Connection::open(&path)?;
    db.execute_batch("PRAGMA foreign_keys=ON;BEGIN IMMEDIATE")?;
    db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
    db.execute("INSERT INTO projects VALUES('p','{}')", [])?;
    rawmaster_library::transaction(&db, &json!({"operation":"install"}))?;
    db.execute("INSERT INTO sessions VALUES('s',?1)",[json!({"id":"s","projectID":"p","mode":"reference","status":"completed","scanCompleted":true}).to_string()])?;
    db.execute(
        "INSERT INTO session_workflows VALUES('s',?1)",
        [
            json!({"phase":"screening","sessionID":"s","projectID":"p","importActive":false})
                .to_string(),
        ],
    )?;
    let mut members = Vec::new();
    let mut intake = Vec::new();
    for frame in input["frames"]
        .as_array()
        .ok_or("Missing real input frames")?
    {
        let asset = frame["fileID"]
            .as_str()
            .ok_or("Missing fixture file identity")?;
        let p = Path::new(frame["path"].as_str().ok_or("Missing real original")?);
        let name = p
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("Missing original filename")?;
        let v = json!({"id":asset,"sessionID":"s","projectID":"p","sourcePath":p,"currentPath":p,"relativePath":name,"filename":name,"importState":"ready","availability":"available","contentHash":frame["sha256"],"fileSize":frame["byteCount"]});
        db.execute(
            "INSERT INTO assets(id,session_id,source_path,data) VALUES(?1,'s',?2,?3)",
            params![asset, p.to_str(), v.to_string()],
        )?;
        intake.push(json!({"occurrenceID":asset,"disposition":"admitted"}));
        members.push(json!({"fileID":asset,"included":true}));
    }
    cmd(
        &db,
        "seal",
        "session.seal",
        json!({"sessionID":"s","items":intake}),
    )?;
    cmd(
        &db,
        "group",
        "group.revise",
        json!({"groupID":"G","projectID":"p","kind":"manual","locked":true,"baseRevision":0,"members":members}),
    )?;
    db.execute_batch("COMMIT")?;
    let jid = Uuid::new_v4().to_string();
    processing::execute(
        &path,
        &json!({"action":"freeze","jobID":jid,"groupID":"G","revision":1,"operation":input["operation"],"recipe":input["recipe"]}),
    )?;
    let ready = processing::execute(&path, &json!({"action":"claim","jobID":jid}))?;
    let rendered = Path::new(ready["outputPath"].as_str().unwrap());
    let marker = Path::new(ready["receiptPath"].as_str().unwrap());
    let file_url = format!(
        "file://{}",
        rendered
            .to_str()
            .unwrap()
            .replace('%', "%25")
            .replace(' ', "%20")
    );
    let request = json!({"jobID":jid,"groupID":"G","revision":1,"operation":input["operation"],"recipe":ready["recipe"],"frames":ready["frames"],"outputURL":file_url});
    let request_file = output.join("request.json");
    fs::write(&request_file, serde_json::to_vec(&request)?)?;
    let native = std::process::Command::new(std::env::var("RAWMASTER_GROUP_HELPER")?)
        .arg(&request_file)
        .arg(marker)
        .output()?;
    if !native.status.success() {
        return Err(format!(
            "Renderer failed: {}",
            String::from_utf8_lossy(&native.stderr)
        )
        .into());
    }
    let receipt: Value = serde_json::from_slice(&fs::read(marker)?)?;
    let staged = processing::execute(&path, &json!({"action":"claim","jobID":jid}))?;
    assert_eq!(staged["state"], "staged");
    let stored = processing::execute(&path, &json!({"action":"publish","jobID":jid}))?;
    let trace = processing::execute(&path, &json!({"action":"trace","workID":stored["workID"]}))?;
    let summary = json!({"jobID":jid,"workID":stored["workID"],"resourceID":stored["resourceID"],"engine":receipt["engineVersion"],"operation":input["operation"],"width":receipt["width"],"height":receipt["height"],"format":receipt["format"],"inputCount":trace["inputs"].as_array().unwrap().len(),"outputSHA256":receipt["facts"]["outputSHA256"],"sourceRenderingPolicy":receipt["facts"]["sourceRenderingPolicy"],"projectID":trace["projectID"],"publishedWorks":db.query_row("SELECT count(*) FROM lc_org_derived",[],|r|r.get::<_,i64>(0))?});
    fs::write(
        output.join("result.json"),
        serde_json::to_vec_pretty(&summary)?,
    )?;
    assert_eq!(summary["publishedWorks"], 1);
    Ok(())
}
