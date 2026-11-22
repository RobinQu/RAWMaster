use rawmaster_library::{inspection, transaction, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

fn install() -> Result<Connection> {
    let db = Connection::open_in_memory()?;
    db.execute_batch("PRAGMA foreign_keys=ON;BEGIN IMMEDIATE")?;
    db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
    transaction(&db, &json!({"operation":"install"}))?;
    db.execute("INSERT INTO projects VALUES('p','{}')", [])?;
    db.execute("INSERT INTO sessions VALUES('s',?)",[json!({"id":"s","projectID":"p","mode":"reference","sourcePath":"/offline-card","scanCompleted":true,"status":"completed"}).to_string()])?;
    db.execute(
        "INSERT INTO session_workflows VALUES('s',?)",
        [
            json!({"sessionID":"s","projectID":"p","phase":"screening","importActive":false})
                .to_string(),
        ],
    )?;
    Ok(db)
}
fn cmd(db: &Connection, id: &str, action: &str, mut r: Value) -> Result<Value> {
    r["version"] = json!(1);
    r["action"] = json!(action);
    r["commandID"] = json!(id);
    transaction(db, &json!({"operation":"command","request":r}))
}
fn file(db: &Connection, id: &str) -> Result<String> {
    let hash = hex::encode(Sha256::digest(id.as_bytes()));
    let path = format!("/offline-card/{id}.ARW");
    let data = json!({"id":id,"sessionID":"s","projectID":"p","filename":format!("{id}.ARW"),"relativePath":format!("{id}.ARW"),
        "sourcePath":path,"currentPath":path,"contentHash":hash,"fileSize":id.len(),"availability":"available","importState":"ready","rating":1});
    db.execute(
        "INSERT INTO assets(id,session_id,source_path,data) VALUES(?1,'s',?2,?3)",
        params![id, path, data.to_string()],
    )?;
    Ok(format!("sha256:{hash}:{}", id.len()))
}
fn sel(db: &Connection, works: &[&str]) -> Result<Value> {
    inspection::read(db, &json!({"op":"selection","workIDs":works}))
}
fn offline(db: &Connection, id: &str) -> Result<()> {
    db.execute("INSERT INTO lc_org_works(work_id,kind,name,revision,project_id) VALUES(?1,'offline',?1,1,'p')",[id])?;
    Ok(())
}
#[test]
fn import_provenance_manual_clear_conflict_and_field_undo_are_independent_per_work() -> Result<()> {
    let db = install()?;
    offline(&db, "one")?;
    offline(&db, "two")?;
    inspection::import_fields(
        &db,
        "one",
        "L",
        "A",
        "r1",
        &json!({"title":"A","camera":"Sony","colorLabelRaw":"客户自定义","keywords":[{"id":"9","path":["旅行","福建"]}]}),
    )?;
    inspection::import_fields(
        &db,
        "two",
        "L",
        "B",
        "r1",
        &json!({"title":"B","copyright":"版权"}),
    )?;
    let preview = sel(&db, &["two", "one"])?;
    assert_eq!(preview["count"], 2);
    assert_eq!(preview["fields"]["title"]["state"], "mixed");
    let put = json!({"workIDs":["one","two"],"expectedToken":preview["token"],"fields":{"title":"我选的标题","caption":null}});
    let receipt = cmd(&db, "edit", "inspect.edit", put.clone())?;
    assert_eq!(cmd(&db, "edit", "inspect.edit", put)?, receipt);
    inspection::import_fields(
        &db,
        "one",
        "L",
        "A",
        "r2",
        &json!({"title":"新目录名","caption":"来源说明"}),
    )?;
    assert_eq!(
        inspection::work_fields(&db, "one")?["title"]["value"],
        "我选的标题"
    );
    assert_eq!(
        inspection::work_fields(&db, "one")?["caption"],
        json!({"value":null,"origin":"manual"})
    );
    let p = sel(&db, &["one"])?;
    cmd(
        &db,
        "another",
        "inspect.edit",
        json!({"workIDs":["one"],"expectedToken":p["token"],"fields":{"title":"后来的修改"}}),
    )?;
    assert!(cmd(
        &db,
        "should-conflict",
        "inspect.undo",
        json!({"editCommandID":"edit"})
    )
    .is_err());
    assert_eq!(
        inspection::work_fields(&db, "two")?["title"]["value"],
        "我选的标题"
    );
    cmd(
        &db,
        "undo-2",
        "inspect.undo",
        json!({"editCommandID":"another"}),
    )?;
    cmd(
        &db,
        "undo-1",
        "inspect.undo",
        json!({"editCommandID":"edit"}),
    )?;
    assert_eq!(
        inspection::work_fields(&db, "one")?["title"]["value"],
        "新目录名"
    );
    assert_eq!(
        inspection::work_fields(&db, "one")?["caption"]["value"],
        "来源说明"
    );
    assert_eq!(inspection::work_fields(&db, "two")?["title"]["value"], "B");
    // A replay of an already observed older revision cannot make that revision current again.
    inspection::import_fields(
        &db,
        "one",
        "L",
        "A",
        "r1",
        &json!({"title":"A","camera":"Sony","colorLabelRaw":"客户自定义","keywords":[{"id":"9","path":["旅行","福建"]}]}),
    )?;
    assert_eq!(
        inspection::work_fields(&db, "one")?["title"]["value"],
        "新目录名"
    );
    Ok(())
}
#[test]
fn cached_optics_histogram_and_af_keep_source_versions_offline() -> Result<()> {
    let db = install()?;
    let c = file(&db, "a")?;
    cmd(
        &db,
        "seal",
        "session.seal",
        json!({"sessionID":"s","items":[{"occurrenceID":"a","disposition":"admitted"}]}),
    )?;
    let af = json!({"state":"available","tag":"Sony:FocusLocation","model":"ILCE-1M2","coordinateSpace":"unorientedTopLeft","orientation":6,"tuple":[6000,4000,1500,1000]});
    cmd(
        &db,
        "meta",
        "inspect.capture",
        json!({"fileID":"a","contentID":c,"extractor":"ImageIO+ExifTool-Sony-v1","fields":{"camera":"camera embedded","iso":640,"orientation":6},"af":af}),
    )?;
    inspection::import_fields(
        &db,
        "file:a",
        "L",
        "A",
        "rev",
        &json!({"camera":"LR fallback","caption":"legacy appearance"}),
    )?;
    cmd(
        &db,
        "no-helper",
        "inspect.capture",
        json!({"fileID":"a","contentID":c,"extractor":"ImageIO-v1","fields":{},"af":{"state":"unavailable","reason":"readerUnavailable"}}),
    )?;
    let mut bins = vec![0u32; 256];
    bins[22] = 1;
    let sample = json!({"sampleID":"render/ver1","kind":"render","versionID":"ver1","sourceSHA256":"3".repeat(64),
        "encoding":"sRGB8","sampleWidth":1,"sampleHeight":1,"sampledPixels":1,"red":bins,"green":bins,"blue":bins});
    cmd(
        &db,
        "hist",
        "inspect.histogram",
        json!({"fileID":"a","contentID":c,"sample":sample}),
    )?;
    let mut corrupt = sample.clone();
    corrupt["blue"] = json!([1]);
    assert!(cmd(
        &db,
        "bad-hist",
        "inspect.histogram",
        json!({"fileID":"a","contentID":c,"sample":corrupt})
    )
    .is_err());
    db.execute(
        "UPDATE assets SET data=json_set(data,'$.availability','missing') WHERE id='a'",
        [],
    )?;
    let read = inspection::read(&db, &json!({"op":"work","workID":"file:a"}))?;
    assert_eq!(read["availability"], "missing");
    assert_eq!(read["fields"]["camera"]["value"], "camera embedded");
    assert_eq!(read["fields"]["caption"]["origin"], "lightroom");
    assert_eq!(read["file"]["af"], af);
    assert_eq!(read["file"]["samples"][0]["versionID"], "ver1");
    Ok(())
}
#[test]
fn uncertain_low_texture_motion_and_human_focus_never_change_admission() -> Result<()> {
    let db = install()?;
    let ids = ["a", "b", "c", "d", "e", "f", "g", "h"];
    let mut frames = Vec::new();
    let mut items = Vec::new();
    db.execute(
        "INSERT INTO groups_data VALUES('g','p',?)",
        [
            json!({"id":"g","projectID":"p","assetIDs":ids,"kind":"burst","origin":"manual"})
                .to_string(),
        ],
    )?;
    for (i, id) in ids.iter().enumerate() {
        let c = file(&db, id)?;
        db.execute(
            "INSERT INTO membership VALUES('g',?,?,1)",
            params![id, i as i64],
        )?;
        let mut frame = json!({"fileID":id,"contentID":c,"inputKind":"nativeRAW","pixelScale":1,"regionBasis":"manualEye","comparisonKey":"same eye 6000x4000",
            "region":{"x":0.1,"y":0.15,"width":0.02,"height":0.03},"measurements":{"pixels":9216,"luma":0.55,
            "contrast":0.2,"gradient":0.08,"laplacian":if i==0 {0.001}else{0.08},"anisotropy":0.2,"clippedFraction":0.02}});
        if *id == "e" {
            frame["measurements"]["contrast"] = json!(0.01);
        }
        if *id == "f" {
            frame["measurements"]["anisotropy"] = json!(0.98);
        }
        if *id == "h" {
            frame["measurements"]["luma"] = json!(0.075);
            frame["measurements"]["contrast"] = json!(0.030);
        }
        if *id == "g" {
            frame["unavailable"] = json!("noAFOrSubject");
        }
        frames.push(frame);
        items
            .push(json!({"occurrenceID":id,"disposition":if *id=="g"{"excluded"}else{"admitted"}}));
    }
    let payload = json!({"groupID":"g","sessionID":"s","frames":frames});
    let analysis = cmd(&db, "analysis", "inspect.analyzeBurst", payload.clone())?;
    assert_eq!(analysis["frames"]["a"]["machine"], "suspectedBlur");
    assert_eq!(analysis["frames"]["b"]["machine"], "clear");
    assert_eq!(analysis["frames"]["e"]["reason"], "lowTexture");
    assert_eq!(
        analysis["frames"]["f"]["reason"],
        "directionalEdgesOrMotion"
    );
    assert_eq!(analysis["frames"]["g"]["machine"], "unknown");
    assert_eq!(analysis["frames"]["h"]["reason"], "lowSignalShadow");
    cmd(
        &db,
        "human",
        "inspect.focusManual",
        json!({"fileID":"a","contentID":frames[0]["contentID"],"sessionID":"s","value":"clear"}),
    )?;
    cmd(&db, "again", "inspect.analyzeBurst", payload)?;
    cmd(
        &db,
        "seal",
        "session.seal",
        json!({"sessionID":"s","items":items}),
    )?;
    let result = inspection::read(&db, &json!({"op":"work","workID":"file:a"}))?;
    assert_eq!(result["fields"]["focusEffective"]["value"], "clear");
    assert_eq!(result["fields"]["focusMachine"]["value"], "suspectedBlur");
    assert_eq!(result["file"]["archiveEligible"], true);
    assert!(inspection::read(
        &db,
        &json!({"op":"file","fileID":"g","contentID":frames[6]["contentID"]})
    )
    .is_err());
    Ok(())
}
