use rawmaster_library::{lightroom, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

fn target(p: &Path) -> Result<Connection> {
    let db = Connection::open(p)?;
    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE")?;
    db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
    rawmaster_library::transaction(&db, &json!({"operation":"install"}))?;
    db.execute_batch("PRAGMA user_version=8; COMMIT")?;
    Ok(db)
}
fn until_done(p: &Path, rid: &Value, page: i64) -> Result<Value> {
    loop {
        let state = lightroom::execute(p, &json!({"action":"step","runID":rid,"limit":page}))?;
        if state["state"] == "complete" {
            return Ok(state);
        }
    }
}
fn total(db: &Connection, t: &str) -> Result<i64> {
    Ok(db.query_row(&format!("SELECT count(*) FROM {t}"), [], |r| r.get(0))?)
}
fn source(path: &Path, dir: &Path) -> Result<()> {
    let s = Connection::open(path)?;
    s.execute_batch("CREATE TABLE Adobe_variablesTable(id_local INTEGER PRIMARY KEY,name,value);
    INSERT INTO Adobe_variablesTable VALUES(1,'Adobe_DBVersion','1400000'),(2,'Adobe_lrMobileCatalogId','mobile-id');
    CREATE TABLE AgLibraryRootFolder(id_local INTEGER PRIMARY KEY,id_global,absolutePath,name);
    CREATE TABLE AgLibraryFolder(id_local INTEGER PRIMARY KEY,id_global,rootFolder,pathFromRoot);
    INSERT INTO AgLibraryFolder VALUES(4,'folder4',3,'nested/child/');
    CREATE TABLE AgLibraryFile(id_local INTEGER PRIMARY KEY,id_global,folder,baseName,extension,md5,sidecarExtensions);
    INSERT INTO AgLibraryFile VALUES(6,'file6',4,'capture','RAW',NULL,'xmp');
    CREATE TABLE Adobe_images(id_local INTEGER PRIMARY KEY,id_global,rootFile,masterImage,copyName,pick,rating,colorLabels,captureTime,fileWidth,fileHeight);
    INSERT INTO Adobe_images VALUES(10,'master',6,NULL,NULL,-1,4,'Custom',NULL,12,8),(2,'virtual2',6,10,'Day',1,3,'Blue',NULL,12,8),(11,'virtual11',6,10,'Night',0,5,NULL,NULL,12,8);
    CREATE TABLE AgLibraryCollection(id_local INTEGER PRIMARY KEY,creationId,name,parent);
    INSERT INTO AgLibraryCollection VALUES(1,'com.adobe.ag.library.collection','ordered',3),(3,'com.adobe.ag.library.group','top',NULL),(7,'com.adobe.ag.library.collection','second',3),(8,'com.adobe.ag.library.smart_collection','high',NULL);
    CREATE TABLE AgLibraryCollectionImage(id_local INTEGER PRIMARY KEY,collection,image,positionInCollection);
    INSERT INTO AgLibraryCollectionImage VALUES(1,1,10,'b'),(2,1,2,'a'),(3,7,2,'a');
    CREATE TABLE AgLibraryCollectionContent(id_local INTEGER PRIMARY KEY,collection,content,owningModule);
    INSERT INTO AgLibraryCollectionContent VALUES(1,8,'s = { {criteria = \"rating\", operation = \">=\", value = 4,}, combine = \"intersect\", }','ag.library.smart_collection');
    CREATE TABLE AgLibraryFolderStack(id_local INTEGER PRIMARY KEY,collapsed);
    INSERT INTO AgLibraryFolderStack VALUES(2,1);
    CREATE TABLE AgLibraryFolderStackImage(id_local INTEGER PRIMARY KEY,image,stack,position);
    INSERT INTO AgLibraryFolderStackImage VALUES(1,10,2,2),(2,2,2,1);
    CREATE TABLE AgLibraryIPTC(id_local INTEGER PRIMARY KEY,image,caption,copyright);
    INSERT INTO AgLibraryIPTC VALUES(1,2,'day caption',NULL);
    CREATE TABLE AgLibraryKeyword(id_local INTEGER PRIMARY KEY,id_global,parent,name);
    INSERT INTO AgLibraryKeyword VALUES(1,'k1',NULL,'Places'),(2,'k2',1,'Sea');
    CREATE TABLE AgLibraryKeywordImage(id_local INTEGER PRIMARY KEY,image,tag);INSERT INTO AgLibraryKeywordImage VALUES(1,2,2);
    CREATE TABLE Adobe_imageDevelopSettings(id_local INTEGER PRIMARY KEY,image,digest,text);
    INSERT INTO Adobe_imageDevelopSettings VALUES(1,2,'1234567890abcdef1234567890abcdef',X'0100FF'),(2,10,'11111111111111111111111111111111',X'0200FF');
    CREATE TABLE AgHarvestedExifMetadata(id_local INTEGER PRIMARY KEY,image,gpsLatitude,gpsLongitude,hasGPS);
    INSERT INTO AgHarvestedExifMetadata VALUES(1,2,0.0,121.0,1);")?;
    s.execute(
        "INSERT INTO AgLibraryRootFolder VALUES(3,'root3',?,'Archive')",
        [dir.to_str().unwrap()],
    )?;
    let folder = dir.join("nested/child");
    fs::create_dir_all(&folder)?;
    fs::write(folder.join("capture.RAW"), b"original bytes")?;
    fs::write(folder.join("capture.xmp"), b"raw xmp sidecar")?;
    let deps = path.with_extension("lrcat-data");
    fs::create_dir_all(deps.join("level"))?;
    fs::write(deps.join("level/data"), b"\0\xffAdobe dependent bytes")?;
    let preview = path.with_file_name("demo Previews.lrdata");
    let bucket = preview.join("A/ABCD");
    fs::create_dir_all(&bucket)?;
    let p = Connection::open(preview.join("previews.db"))?;
    p.execute_batch("CREATE TABLE ImageCacheEntry(imageId,uuid,digest); CREATE TABLE Pyramid(uuid,digest);
        INSERT INTO ImageCacheEntry VALUES(2,'abcdef0012345678','1234567890abcdef1234567890abcdef'),(10,'abcdef0099999999','abcdbeef12345678');
        INSERT INTO Pyramid SELECT uuid,digest FROM ImageCacheEntry;")?;
    let jpg=fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0008.jpg"))?;
    fs::write(
        bucket.join("abcdef0012345678-1234567890abcdef1234567890abcdef_2"),
        &jpg,
    )?;
    let mut bytes = vec![];
    bytes.extend_from_slice(b"AgHg");
    bytes.extend_from_slice(&32u16.to_be_bytes());
    bytes.extend_from_slice(&[0, 0]);
    bytes.extend_from_slice(&(jpg.len() as u64).to_be_bytes());
    bytes.extend_from_slice(&0u64.to_be_bytes());
    bytes.extend_from_slice(b"level_2\0");
    bytes.extend(jpg);
    fs::write(
        bucket.join("abcdef0099999999-abcdbeef12345678.lrprev"),
        bytes,
    )?;
    Ok(())
}
#[test]
fn resumes_groups_offline_copies_preserves_bytes_and_local_work() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let input = dir.path().join("demo.lrcat");
    let live = dir.path().join("live");
    fs::create_dir(&live)?;
    let path = live.join("library.sqlite");
    source(&input, dir.path())?;
    let input_db = Connection::open(&input)?;
    input_db.execute("INSERT INTO AgLibraryCollection VALUES(99,'com.adobe.ag.layout.book.unsaved','Adobe book',NULL)",[])?;
    input_db.execute(
        "INSERT INTO AgLibraryCollectionImage VALUES(99,99,2,'e')",
        [],
    )?;
    drop(input_db);
    let before = Sha256::digest(fs::read(&input)?);
    let db = target(&path)?;
    let cmd = json!({"action":"start","sourcePath":input,"readSidecars":true});
    let rid = lightroom::execute(&path, &cmd)?["runID"].clone();
    lightroom::execute(&path, &json!({"action":"step","runID":rid,"limit":1}))?;
    let done = until_done(&path, &rid, 1)?;
    assert_eq!(done["state"], "complete");
    assert_eq!(
        total(&db, "lc_org_works")?,
        3,
        "{:?}",
        lightroom::execute(
            &path,
            &json!({"action":"report","runID":rid,"domain":"organization","status":"conflict"})
        )?
    );
    assert_eq!(total(&db, "lc_scopes")?, 0);
    assert_eq!(total(&db, "lc_org_stacks")?, 1);
    assert_eq!(total(&db, "lc_org_collection_members")?, 5);
    let archived:String=db.query_row("SELECT evidence FROM lc_lr_reports WHERE subject='collectionMember' AND source_key='member:99' AND status='archivedOnly'",[],|r|r.get(0))?;
    assert_eq!(
        serde_json::from_str::<Value>(&archived)?["sourcePosition"],
        "e"
    );
    let m: i64 = db.query_row(
        "SELECT count(*) FROM lc_lr_looks WHERE decoded=1 AND revision_bound=0",
        [],
        |r| r.get(0),
    )?;
    assert_eq!(m, 1);
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM lc_lr_looks WHERE revision_bound",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        1
    );
    let look = lightroom::execute(
        &path,
        &json!({"action":"previewPath","runID":rid,"sourceKey":"2"}),
    )?;
    assert!(fs::read(look["path"].as_str().unwrap())?.starts_with(&[0xff, 0xd8]));
    let resources = total(&db, "lc_resources")?;
    let works = total(&db, "lc_org_versions")?;
    let name: String = db.query_row(
        "SELECT work_id FROM lc_org_works WHERE name='Day'",
        [],
        |r| r.get(0),
    )?;
    db.execute_batch("BEGIN IMMEDIATE")?;
    rawmaster_library::organization::apply(
        &db,
        &json!({"action":"org.saveWork","workID":name,"name":"Personal Edit"}),
    )?;
    db.execute_batch("COMMIT")?;
    assert_eq!(lightroom::execute(&path, &cmd)?["runID"], rid);
    fs::rename(
        dir.path().join("demo Previews.lrdata"),
        dir.path().join("offline-preview"),
    )?;
    lightroom::execute(&path, &json!({"action":"retry","runID":rid}))?;
    until_done(&path, &rid, 2)?;
    assert_eq!(total(&db, "lc_resources")?, resources);
    assert_eq!(total(&db, "lc_org_versions")?, works);
    assert_eq!(
        db.query_row(
            "SELECT name FROM lc_org_works WHERE work_id=?",
            [&name],
            |r| r.get::<_, String>(0)
        )?,
        "Personal Edit"
    );
    let original = dir.path().join("nested/child/capture.RAW");
    let c = lightroom::execute(
        &path,
        &json!({"action":"linkCandidates","runID":rid,"sourceKey":"2","path":original}),
    )?;
    assert_eq!(c["state"], "verified");
    assert_eq!(c["fileIDs"], json!([]));
    assert!(lightroom::execute(&path,&json!({"action":"linkOriginal","runID":rid,"sourceKey":"2","path":original,"fileID":"excluded","sha256":c["sha256"],"byteCount":c["byteCount"]})).is_err());
    db.execute_batch("BEGIN IMMEDIATE")?;
    db.execute("INSERT INTO projects VALUES('native-project','{}')", [])?;
    db.execute("INSERT INTO sessions VALUES('native-session',?)",[json!({"id":"native-session","projectID":"native-project","mode":"reference","scanCompleted":true,"status":"completed"}).to_string()])?;
    db.execute("INSERT INTO session_workflows VALUES('native-session',?)",[json!({"sessionID":"native-session","projectID":"native-project","phase":"screening","importActive":false}).to_string()])?;
    let host = json!({"id":"native-file","sessionID":"native-session","projectID":"native-project","sourcePath":original,"currentPath":original,"relativePath":"capture.RAW","filename":"capture.RAW","contentHash":c["sha256"],"fileSize":c["byteCount"],"availability":"available","importState":"ready"});
    db.execute("INSERT INTO assets(id,session_id,source_path,data) VALUES('native-file','native-session',?,?)",params![original.to_str(),host.to_string()])?;
    rawmaster_library::authority::command(
        &db,
        &json!({"action":"session.seal","commandID":"native-intake","version":1,"sessionID":"native-session","items":[{"occurrenceID":"native-file","disposition":"admitted"}]}),
    )?;
    db.execute_batch("COMMIT")?;
    let attachment = json!({"action":"linkOriginal","runID":rid,"sourceKey":"2","path":original,"fileID":"native-file","sha256":c["sha256"],"byteCount":c["byteCount"]});
    assert_eq!(lightroom::execute(&path, &attachment)?["state"], "linked");
    assert_eq!(lightroom::execute(&path, &attachment)?["state"], "linked");
    assert_eq!(total(&db, "lc_scopes")?, 1);
    let pkg = dir.path().canonicalize()?.join("package");
    let restored = dir.path().canonicalize()?.join("restored");
    let b = rawmaster_library::backup::execute(
        &path,
        &json!({"op":"backup","mode":"catalog","destination":pkg,"generation":"lr-proof"}),
    )?;
    assert_eq!(b["state"], "complete");
    rawmaster_library::backup::execute(
        &path,
        &json!({"op":"restore","package":pkg,"destination":restored}),
    )?;
    let recovered = lightroom::execute(
        &restored.join("library.sqlite"),
        &json!({"action":"previewPath","runID":rid,"sourceKey":"2"}),
    )?;
    assert_eq!(
        fs::read(recovered["path"].as_str().unwrap())?,
        fs::read(look["path"].as_str().unwrap())?
    );
    assert_eq!(before, Sha256::digest(fs::read(&input)?));
    Ok(())
}
#[test]
#[ignore = "Requires an explicit source .lrcat and private report directory"]
fn real_catalog_three_domain_reconciliation() -> Result<()> {
    let input = PathBuf::from(std::env::var("RAWMASTER_LR_SOURCE")?);
    let dir = PathBuf::from(std::env::var("RAWMASTER_LR_OUTPUT")?);
    fs::create_dir_all(&dir)?;
    let catalog = dir.join("catalog.sqlite");
    let db = if catalog.exists() {
        Connection::open(&catalog)?
    } else {
        target(&catalog)?
    };
    let started = std::time::Instant::now();
    let pre = lightroom::execute(&catalog, &json!({"action":"preflight","sourcePath":input}))?;
    let prior = if std::env::var_os("RAWMASTER_LR_CONTINUE_FROZEN").is_some() {
        Some(serde_json::from_slice::<Value>(&fs::read(
            dir.join("reconciliation.json"),
        )?)?)
    } else {
        None
    };
    let mut state = if let Some(last) = prior.as_ref() {
        lightroom::execute(&catalog, &json!({"action":"status","runID":last["runID"]}))?
    } else {
        lightroom::execute(
            &catalog,
            &json!({"action":"start","sourcePath":input,"readSidecars":false}),
        )?
    };
    let rid = state["runID"].clone();
    while state["state"] != "complete" {
        state = lightroom::execute(&catalog, &json!({"action":"step","runID":rid,"limit":128}))?;
        fs::write(dir.join("progress.json"), serde_json::to_vec(&state)?)?;
    }
    let mut report = json!({"preflight":pre["counts"],"version":state["version"],"sourceID":state["sourceID"],"runID":rid,"counts":state["counts"],"elapsedSeconds":started.elapsed().as_secs_f64(),"works":total(&db,"lc_org_works")?,"scopes":total(&db,"lc_scopes")?,"resources":total(&db,"lc_resources")?});
    if let Some(previous) = prior {
        report["supplementalAuditSeconds"] = report["elapsedSeconds"].clone();
        report["elapsedSeconds"] = json!(
            previous["elapsedSeconds"].as_f64().unwrap_or(0.0) + started.elapsed().as_secs_f64()
        );
    }
    report["appearance"] = lightroom::execute(
        &catalog,
        &json!({"action":"report","runID":rid,"domain":"appearance","limit":1}),
    )?["previews"]
        .clone();
    let mut q=db.prepare("SELECT domain,subject,status,count(*) FROM lc_lr_reports WHERE run_id=?1 GROUP BY domain,subject,status ORDER BY domain,subject,status")?;
    let rows = q
        .query_map(params![rid.as_str().unwrap()], |r| {
            Ok(json!([
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?
            ]))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    report["bySubject"] = json!(rows);
    fs::write(
        dir.join("reconciliation.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    assert_eq!(report["works"], pre["counts"]["images"]);
    assert_eq!(report["scopes"], 0);
    if std::env::var_os("RAWMASTER_LR_VERIFY_RESTORE").is_some() {
        let restored = roundtrip_virtual_edits(&catalog, &db, &dir, &input, rid.as_str().unwrap())?;
        fs::write(
            dir.join("restore-proof.json"),
            serde_json::to_vec_pretty(&restored)?,
        )?;
    }
    Ok(())
}

#[test]
fn altered_cache_payload_cannot_claim_the_frozen_catalog_revision() -> Result<()> {
    let tmp = tempfile::tempdir()?;
    let input = tmp.path().join("demo.lrcat");
    source(&input, tmp.path())?;
    let catalog = tmp.path().join("library.sqlite");
    let db = target(&catalog)?;
    let start = lightroom::execute(&catalog, &json!({"action":"start","sourcePath":input}))?;
    let path = tmp
        .path()
        .join("demo Previews.lrdata/A/ABCD/abcdef0012345678-1234567890abcdef1234567890abcdef_2");
    let b = fs::read(&path)?;
    let replacement = path.with_extension("replacement");
    fs::write(&replacement, b)?;
    fs::rename(replacement, &path)?;
    until_done(&catalog, &start["runID"], 32)?;
    let observed: (bool, bool) = db.query_row(
        "SELECT decoded,revision_bound FROM lc_lr_looks WHERE image_key='2'",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    assert_eq!(observed, (true, false));
    Ok(())
}

#[test]
fn compressed_original_xmp_maps_localized_title_and_keeps_the_exact_packet() -> Result<()> {
    use std::io::Write;
    let tmp = tempfile::tempdir()?;
    let input = tmp.path().join("demo.lrcat");
    source(&input, tmp.path())?;
    let source = Connection::open(&input)?;
    source.execute_batch("CREATE TABLE Adobe_AdditionalMetadata(id_local INTEGER PRIMARY KEY,image INTEGER,xmp BLOB)")?;
    let xml=br##"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:dc="http://purl.org/dc/elements/1.1/"><rdf:Description><dc:title><rdf:Alt><rdf:li xml:lang="de">Licht</rdf:li><rdf:li xml:lang="x-default">Light study</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF>"##;
    let mut packet = (xml.len() as u32).to_be_bytes().to_vec();
    let mut z = flate2::write::ZlibEncoder::new(vec![], flate2::Compression::default());
    z.write_all(xml)?;
    packet.extend(z.finish()?);
    source.execute(
        "INSERT INTO Adobe_AdditionalMetadata VALUES(1,2,?)",
        [&packet],
    )?;
    drop(source);
    let catalog = tmp.path().join("library.sqlite");
    let db = target(&catalog)?;
    let start = lightroom::execute(&catalog, &json!({"action":"start","sourcePath":input}))?;
    until_done(&catalog, &start["runID"], 24)?;
    let title:String=db.query_row("SELECT json_extract(fields_json,'$.title') FROM lc_inspect_imports WHERE source_object='2'",[],|r|r.get(0))?;
    assert_eq!(title, "Light study");
    let file:String=db.query_row("SELECT p.relative_path FROM lc_lr_links l JOIN lc_resources p USING(resource_id) WHERE l.role='sourceXmp'",[],|r|r.get(0))?;
    assert_eq!(
        fs::read(tmp.path().join("LibraryResources").join(file))?,
        packet
    );
    Ok(())
}

#[test]
fn unreadable_optional_preview_preserves_organization_and_per_work_differences() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let input = temp.path().join("demo.lrcat");
    source(&input, temp.path())?;
    let broken = temp.path().join("demo Previews.lrdata/previews.db");
    fs::write(&broken, b"not a SQLite preview index")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&input, fs::Permissions::from_mode(0o444))?;
        fs::set_permissions(&broken, fs::Permissions::from_mode(0o444))?;
    }
    let path = temp.path().join("library.sqlite");
    let db = target(&path)?;
    let run = lightroom::execute(&path, &json!({"action":"start","sourcePath":input}))?;
    until_done(&path, &run["runID"], 32)?;
    assert_eq!(total(&db, "lc_org_works")?, 3);
    assert_eq!(total(&db, "lc_scopes")?, 0);
    let states: i64 = db.query_row(
        "SELECT COUNT(*) FROM lc_lr_looks WHERE state='unreadablePreviewIndex'",
        [],
        |row| row.get(0),
    )?;
    assert_eq!(states, 3);
    let diagnostics:i64=db.query_row("SELECT COUNT(*) FROM lc_lr_reports WHERE subject='sourceContainer' AND source_key='previews.db' AND status='missing'",[],|row|row.get(0))?;
    assert_eq!(diagnostics, 1);
    Ok(())
}

fn roundtrip_virtual_edits(
    catalog: &Path,
    db: &Connection,
    dir: &Path,
    source_path: &Path,
    rid: &str,
) -> Result<Value> {
    let mut virtuals=db.prepare("SELECT w.work_id,l.image_key,w.active_version_id,l.state,l.resource_id FROM lc_org_works w JOIN lc_lr_looks l USING(work_id) WHERE w.kind='virtual' AND l.run_id=?1 ORDER BY l.decoded DESC,w.work_id")?;
    let rows = virtuals
        .query_map([rid], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, Option<String>>(4)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    assert!(rows.len() >= 2);
    assert!(rows[0].4.is_some());
    db.execute_batch("BEGIN IMMEDIATE")?;
    let edit = rawmaster_library::organization::apply(
        db,
        &json!({"action":"org.saveWork","workID":rows[0].0,"appearance":{"origin":"rawmaster","exposureEV":0.5}}),
    )?;
    db.execute_batch("COMMIT")?;
    let destination = dir.canonicalize()?.join("backup");
    let restored = dir.canonicalize()?.join("restored");
    let package = rawmaster_library::backup::execute(
        catalog,
        &json!({"op":"backup","mode":"catalog","destination":destination,"generation":"virtual-edit"}),
    )?;
    assert_eq!(package["state"], "complete");
    rawmaster_library::backup::execute(
        catalog,
        &json!({"op":"restore","package":destination,"destination":restored}),
    )?;
    let recovered = Connection::open_with_flags(
        restored.join("library.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    let data = restored.join("LibraryResources");
    let frozen:String=recovered.query_row("SELECT r.relative_path FROM lc_lr_runs l JOIN lc_resources r ON r.resource_id=l.snapshot_id WHERE run_id=?1",[rid],|r|r.get(0))?;
    let adobe = Connection::open_with_flags(
        data.join(frozen),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    let mut looks = 0;
    let mut recipes = 0;
    let mut xmps = 0;
    for (index, (work, key, old, historical, resource)) in rows.iter().enumerate() {
        let (active,state,id):(String,String,Option<String>)=recovered.query_row("SELECT w.active_version_id,l.state,l.resource_id FROM lc_org_works w JOIN lc_lr_looks l USING(work_id) WHERE w.work_id=?1 AND l.image_key=?2 AND l.run_id=?3",params![work,key,rid],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
        assert_eq!(state, *historical);
        assert_eq!(&id, resource);
        let version: String = recovered.query_row(
            "SELECT appearance_json FROM lc_org_versions WHERE version_id=?1 AND work_id=?2",
            params![old, work],
            |r| r.get(0),
        )?;
        assert_eq!(
            serde_json::from_str::<Value>(&version)?["sourceImageID"],
            key.parse::<i64>()?
        );
        if index == 0 {
            assert_eq!(edit["versionID"], active);
            assert_ne!(&active, old);
        } else {
            assert_eq!(&active, old);
        }
        if let Some(id) = resource {
            let preview = lightroom::execute(
                &restored.join("library.sqlite"),
                &json!({"action":"previewPath","runID":rid,"sourceKey":key}),
            )?;
            let prior: String = db.query_row(
                "SELECT relative_path FROM lc_resources WHERE resource_id=?1",
                [id],
                |r| r.get(0),
            )?;
            assert_eq!(
                fs::read(preview["path"].as_str().unwrap())?,
                fs::read(
                    catalog
                        .parent()
                        .unwrap()
                        .join("LibraryResources")
                        .join(prior)
                )?
            );
            looks += 1;
        }
        let mut q=recovered.prepare("SELECT l.role,r.relative_path FROM lc_lr_links l JOIN lc_resources r USING(resource_id) WHERE l.run_id=?1 AND l.kind='Adobe_images' AND l.source_key=?2 AND (l.role='sourceXmp' OR l.role LIKE 'develop:%')")?;
        for row in q.query_map(params![rid, key], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })? {
            let (role, path) = row?;
            let source: Vec<u8> = if let Some(record) = role.strip_prefix("develop:") {
                recipes += 1;
                adobe.query_row("SELECT CAST(text AS BLOB) FROM Adobe_imageDevelopSettings WHERE image=?1 AND id_local=?2",params![key.parse::<i64>()?,record.parse::<i64>()?],|r|r.get(0))?
            } else {
                xmps += 1;
                adobe.query_row("SELECT CAST(xmp AS BLOB) FROM Adobe_AdditionalMetadata WHERE image=?1 AND length(xmp)>0 ORDER BY id_local LIMIT 1",[key.parse::<i64>()?],|r|r.get(0))?
            };
            assert_eq!(source, fs::read(data.join(path))?);
        }
    }
    let mut q=recovered.prepare("SELECT l.locator,r.relative_path FROM lc_lr_links l JOIN lc_resources r USING(resource_id) WHERE l.run_id=?1 AND l.role='lrcat-data'")?;
    let mut companions = 0;
    for row in q.query_map([rid], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })? {
        let (locator, path) = row?;
        assert_eq!(
            fs::read(data.join(path))?,
            fs::read(source_path.parent().unwrap().join(locator))?
        );
        companions += 1;
    }
    assert!(recipes > 0 && companions > 0);
    Ok(
        json!({"virtualWorks":rows.len(),"verifiedHistoricalLooks":looks,"exactDevelopRecords":recipes,"exactSourceXmp":xmps,"exactCompanions":companions,"independentNativeEdit":true,"scopeCount":total(&recovered,"lc_scopes")?}),
    )
}

#[test]
fn separate_virtual_edits_restore_both_source_looks_and_proprietary_bytes() -> Result<()> {
    let root = tempfile::tempdir()?;
    let source_path = root.path().join("demo.lrcat");
    source(&source_path, root.path())?;
    let digest = "efefefefefefefefefefefefefefefef";
    let uuid = "abcdef0022222222";
    let preview = root.path().join("demo Previews.lrdata");
    let pv = Connection::open(preview.join("previews.db"))?;
    pv.execute(
        "INSERT INTO ImageCacheEntry VALUES(11,?1,?2)",
        [uuid, digest],
    )?;
    pv.execute("INSERT INTO Pyramid VALUES(?1,?2)", [uuid, digest])?;
    drop(pv);
    let fixture=Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0001.jpg");
    fs::copy(
        fixture,
        preview.join("A/ABCD").join(format!("{uuid}-{digest}_2")),
    )?;
    let adobe = Connection::open(&source_path)?;
    adobe.execute(
        "INSERT INTO Adobe_imageDevelopSettings VALUES(3,11,?1,X'99AAFE00')",
        [digest],
    )?;
    drop(adobe);
    let dir = root.path().join("target");
    fs::create_dir(&dir)?;
    let catalog = dir.join("library.sqlite");
    let db = target(&catalog)?;
    let run = lightroom::execute(
        &catalog,
        &json!({"action":"start","sourcePath":source_path}),
    )?;
    let rid = run["runID"].as_str().unwrap();
    until_done(&catalog, &json!(rid), 24)?;
    let proof = roundtrip_virtual_edits(&catalog, &db, &dir, &source_path, rid)?;
    assert_eq!(proof["verifiedHistoricalLooks"], 2);
    assert_eq!(proof["exactDevelopRecords"], 2);
    assert_eq!(proof["scopeCount"], 0);
    Ok(())
}

#[test]
fn missing_new_preview_still_opens_the_previous_archived_generation() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let input = temp.path().join("demo.lrcat");
    source(&input, temp.path())?;
    let catalog = temp.path().join("library.sqlite");
    let db = target(&catalog)?;
    let request = json!({"action":"start","sourcePath":input});
    let first = lightroom::execute(&catalog, &request)?["runID"].clone();
    until_done(&catalog, &first, 32)?;
    let work: String = db.query_row(
        "SELECT work_id FROM lc_lr_looks WHERE image_key='2' AND run_id=?1",
        [first.as_str()],
        |row| row.get(0),
    )?;
    let master: String = db.query_row(
        "SELECT work_id FROM lc_lr_looks WHERE image_key='10' AND run_id=?1",
        [first.as_str()],
        |r| r.get(0),
    )?;
    let master_media =
        lightroom::execute(&catalog, &json!({"action":"workMedia","workID":master}))?;
    db.execute_batch("BEGIN IMMEDIATE")?;
    rawmaster_library::organization::apply(
        &db,
        &json!({"action":"org.saveWork","kind":"virtual","workID":"pinned-copy","masterWorkID":master,"name":"Pinned look"}),
    )?;
    rawmaster_library::organization::apply(
        &db,
        &json!({"action":"org.saveWork","workID":"pinned-copy","appearance":{"origin":"rawmaster","ev":0.4}}),
    )?;
    let source_id: String = db.query_row(
        "SELECT source_id FROM lc_lr_runs WHERE run_id=?1",
        [first.as_str()],
        |r| r.get(0),
    )?;
    let unrelated = lightroom::execute(&catalog, &json!({"action":"workMedia","workID":work}))?;
    rawmaster_library::organization::apply(
        &db,
        &json!({"action":"org.saveWork","kind":"virtual","workID":"unrelated-copy","masterWorkID":master,"name":"Wrong reference","appearance":{"origin":"lightroom","resourceID":unrelated["resourceID"],"sourceCatalogID":source_id,"sourceImageID":2,"developDigest":unrelated["developDigest"]}}),
    )?;
    db.execute_batch("COMMIT")?;
    let get = json!({"action":"workMedia","workID":work});
    let original = lightroom::execute(&catalog, &get)?;
    assert_eq!(original["historicalGeneration"], "current");
    fs::rename(
        temp.path().join("demo Previews.lrdata"),
        temp.path().join("unmounted-previews"),
    )?;
    let second = lightroom::execute(&catalog, &request)?["runID"].clone();
    assert_ne!(first, second);
    until_done(&catalog, &second, 32)?;
    let result = lightroom::execute(&catalog, &get)?;
    assert_eq!(result["sourceRunID"], first);
    assert_eq!(result["latestRunID"], second);
    assert_eq!(result["historicalGeneration"], "previous");
    assert_eq!(result["latestState"], "noPreviewIndex");
    assert_eq!(result["revisionBound"], true);
    assert_eq!(result["sha256"], original["sha256"]);
    let specific = lightroom::execute(
        &catalog,
        &json!({"action":"workMedia","workID":work,"sourceRunID":second}),
    )?;
    assert!(specific.is_null());
    let cloned = lightroom::execute(
        &catalog,
        &json!({"action":"workMedia","workID":"pinned-copy"}),
    )?;
    assert_eq!(cloned["sourceWorkID"], master);
    assert_eq!(cloned["sourceRunID"], first);
    assert_eq!(cloned["sha256"], master_media["sha256"]);
    assert!(lightroom::execute(
        &catalog,
        &json!({"action":"workMedia","workID":"unrelated-copy"})
    )?
    .is_null());
    Ok(())
}
