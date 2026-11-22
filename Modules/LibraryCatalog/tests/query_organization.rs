use rawmaster_library::organization::{self, apply, read};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
fn fixture() -> Connection {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))
        .unwrap();
    db.execute_batch(include_str!("../src/authority_schema.sql"))
        .unwrap();
    db.execute_batch("PRAGMA foreign_keys=ON;PRAGMA user_version=8; INSERT INTO lc_meta VALUES('libraryID','org-test');
      CREATE TABLE lc_resources(resource_id TEXT PRIMARY KEY);").unwrap();
    db.execute_batch(organization::SCHEMA).unwrap();
    db
}
fn command(db: &Connection, r: Value) -> Value {
    let tx = db.unchecked_transaction().unwrap();
    let v = apply(&tx, &r).unwrap();
    tx.commit().unwrap();
    v
}
fn view(db: &Connection, mut req: Value) -> Value {
    req["view"] = json!("works");
    read(db, &req).unwrap()
}
fn setup(db: &Connection) {
    command(
        db,
        json!({"action":"org.saveVolume","volumeID":"V","name":"旅行硬盘","online":false}),
    );
    for (id, par) in [("parent", None), ("sub", Some("parent"))] {
        command(
            db,
            json!({"action":"org.saveFolder","folderID":id,"volumeID":"V","parentID":par,"name":id}),
        );
    }
    command(
        db,
        json!({"action":"org.saveWork","kind":"offline","workID":"one","folderID":"sub","name":"海边照片","rating":4,
        "metadata":{"filename":"海边001.NEF","camera":"Nikon","iso":1600,"latitude":0.0,"longitude":0.0,"keywords":[{"path":["旅行","海边"]}]},
        "appearance":{"kind":"jpegPreview","resourceID":"preview"},"versionID":"v1"}),
    );
    command(
        db,
        json!({"action":"org.saveWork","kind":"offline","workID":"two","folderID":"sub","name":"城市照片","rating":1,"metadata":{"camera":"Fuji"}}),
    );
    command(
        db,
        json!({"action":"org.saveWork","kind":"virtual","workID":"copy","masterWorkID":"one","name":"黑白副本","rating":5}),
    );
}
#[test]
fn offline_organization_virtual_versions_and_exact_scoped_filters() {
    let db = fixture();
    setup(&db);
    let out = view(
        &db,
        json!({"folderID":"parent","predicate":{"all":[{"field":"iso","op":"gte","value":1000},{"field":"hasGPS","op":"eq","value":true}]},
        "query":{"tags":["旅行/海边"]},"facets":["camera","iso","kind"],"includeOrderedIDs":true}),
    );
    assert_eq!(out["totalWorks"], 2);
    assert_eq!(out["totalFiles"], 0);
    assert_eq!(out["offlineSources"], 1);
    assert_eq!(out["orderedAssetIDs"], json!([]));
    assert_eq!(out["facets"]["iso"][0]["works"], 2);
    assert!(out["items"]
        .as_array()
        .unwrap()
        .iter()
        .all(|v| v["asset"].is_null() && v["originalAvailable"] == false));
    assert_eq!(
        view(&db, json!({"folderID":"parent","includeDescendants":false}))["total"],
        0
    );
    let details = read(&db, &json!({"view":"work","workID":"copy"})).unwrap();
    assert_ne!(details["versionID"], "v1");
    assert_eq!(
        details["versions"][0]["appearance"],
        json!({"kind":"jpegPreview","resourceID":"preview"})
    );
    command(
        &db,
        json!({"action":"org.saveWork","workID":"one","name":"原片改名","rating":2,"appearance":{"kind":"new"},"versionID":"v2"}),
    );
    assert_eq!(
        view(&db, json!({"workID":"copy"}))["items"][0]["metadata"]["rating"],
        5
    );
    assert_eq!(
        read(&db, &json!({"view":"work","workID":"copy"})).unwrap()["versions"],
        details["versions"]
    );
    assert_eq!(
        db.query_row("SELECT count(*) FROM lc_archive_files", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn saved_rules_and_group_memberships_re_evaluate_and_cursors_expire() {
    let db = fixture();
    setup(&db);
    command(
        &db,
        json!({"action":"org.saveCollection","kind":"group","collectionID":"group","name":"旅行"}),
    );
    command(
        &db,
        json!({"action":"org.saveCollection","kind":"smart","collectionID":"bright","parentID":"group","name":"四星",
        "rule":{"folderID":"parent","query":{"minimumRating":4}}}),
    );
    command(
        &db,
        json!({"action":"org.saveCollection","kind":"regular","collectionID":"regular","parentID":"group","name":"手选"}),
    );
    command(
        &db,
        json!({"action":"org.setMembers","collectionID":"regular","workIDs":["two","one"]}),
    );
    assert_eq!(view(&db, json!({"collectionID":"group"}))["total"], 3);
    let first = view(
        &db,
        json!({"collectionID":"bright","pageSize":1,"sort":"ratingDescending"}),
    );
    assert_eq!(first["items"][0]["workID"], "copy");
    assert_eq!(first["total"], 2);
    let next = view(
        &db,
        json!({"collectionID":"bright","sort":"ratingDescending","pageSize":1,"cursor":first["nextCursor"]}),
    );
    assert_eq!(next["items"][0]["workID"], "one");
    assert!(next["nextCursor"].is_null());
    command(
        &db,
        json!({"action":"org.saveWork","workID":"one","rating":1}),
    );
    assert_eq!(
        view(
            &db,
            json!({"collectionID":"bright","sort":"ratingDescending","pageSize":1,"cursor":first["nextCursor"]})
        )["status"],
        "staleCursor"
    );
    assert_eq!(view(&db, json!({"collectionID":"bright"}))["total"], 1);
}
#[test]
fn stack_cover_order_and_manual_collection_members_stay_local_to_scope() {
    let db = fixture();
    setup(&db);
    for id in ["x", "y"] {
        command(
            &db,
            json!({"action":"org.saveCollection","collectionID":id,"kind":"regular","name":id}),
        );
        command(
            &db,
            json!({"action":"org.setMembers","collectionID":id,"workIDs":["two","copy","one"]}),
        );
    }
    command(
        &db,
        json!({"action":"org.saveStack","stackID":"sx","scopeKind":"collection","scopeID":"x","workIDs":["copy","one"],"coverWorkID":"one"}),
    );
    let out = view(
        &db,
        json!({"collectionID":"x","sort":"manual","collapseStacks":true,"includeOrderedIDs":true}),
    );
    assert_eq!(out["total"], 2);
    assert_eq!(out["totalWorks"], 3);
    assert_eq!(out["orderedObjectIDs"], json!(["two", "one"]));
    assert_eq!(
        view(&db, json!({"collectionID":"y","collapseStacks":true}))["total"],
        3
    );
    // A nonmatching cover cannot suppress or become the representative of a matching virtual copy.
    let filtered = view(
        &db,
        json!({"collectionID":"x","collapseStacks":true,"query":{"minimumRating":5}}),
    );
    assert_eq!(filtered["items"][0]["workID"], "copy");
    assert_eq!(filtered["items"][0]["matchedWorkIDs"], json!(["copy"]));
    command(
        &db,
        json!({"action":"org.moveMember","scopeKind":"collection","scopeID":"y","workID":"one","beforeWorkID":"two"}),
    );
    assert_eq!(
        view(
            &db,
            json!({"collectionID":"y","sort":"manual","includeOrderedIDs":true})
        )["orderedObjectIDs"],
        json!(["one", "two", "copy"])
    );
    command(
        &db,
        json!({"action":"org.setMembers","collectionID":"x","workIDs":["one"]}),
    );
    assert_eq!(
        read(
            &db,
            &json!({"view":"stacks","scopeKind":"collection","scopeID":"x"})
        )
        .unwrap()["items"],
        json!([])
    );
}
#[test]
fn staged_import_only_publishes_contiguous_members_and_honors_human_revision() {
    let db = fixture();
    setup(&db);
    command(
        &db,
        json!({"action":"org.saveCollection","collectionID":"x","kind":"regular","name":"R"}),
    );
    let chunk = json!({"action":"org.stageMembers","importID":"run","collectionID":"x","baseRevision":1,"start":1,"workIDs":["two"]});
    assert_eq!(command(&db, chunk.clone())["published"], false);
    assert_eq!(command(&db, chunk)["published"], false);
    assert_eq!(view(&db, json!({"collectionID":"x"}))["total"], 0);
    {
        let tx = db.unchecked_transaction().unwrap();
        assert!(apply(&tx,&json!({"action":"org.stageMembers","importID":"run","collectionID":"x","baseRevision":1,
       "start":2,"workIDs":[],"finish":true,"expectedCount":2})).is_err());
    }
    command(
        &db,
        json!({"action":"org.stageMembers","importID":"run","collectionID":"x","baseRevision":1,"start":0,"workIDs":["copy"],"finish":true,"expectedCount":2}),
    );
    assert_eq!(
        view(
            &db,
            json!({"collectionID":"x","sort":"manual","includeOrderedIDs":true})
        )["orderedObjectIDs"],
        json!(["copy", "two"])
    );
    command(
        &db,
        json!({"action":"org.stageMembers","importID":"later","collectionID":"x","baseRevision":2,"start":0,"workIDs":["one"]}),
    );
    command(
        &db,
        json!({"action":"org.addMembers","collectionID":"x","workIDs":["one"],"baseRevision":2}),
    );
    let tx = db.unchecked_transaction().unwrap();
    assert!(apply(
        &tx,
        &json!({"action":"org.stageMembers","importID":"later","collectionID":"x","baseRevision":2,
        "start":1,"workIDs":[],"finish":true,"expectedCount":1})
    )
    .is_err());
}
#[test]
fn derived_result_is_published_once_and_appears_in_organization_without_original_grant() {
    let db = fixture();
    setup(&db);
    db.execute("INSERT INTO lc_resources VALUES(?)", params!["resource"])
        .unwrap();
    let tx = db.unchecked_transaction().unwrap();
    for _ in 0..2 {
        organization::publish_derived(
            &tx,
            "video",
            "resource",
            "job",
            "derivedVideo",
            "延时",
            Some("sub"),
            "source-project",
        )
        .unwrap();
    }
    tx.commit().unwrap();
    let x = view(&db, json!({"workID":"video"}));
    assert_eq!(x["items"][0]["resourceID"], "resource");
    assert_eq!(x["items"][0]["kind"], "derivedVideo");
    assert_eq!(
        view(&db, json!({"projectID":"source-project","workID":"video"}))["total"],
        1
    );
    assert_eq!(
        view(&db, json!({"projectID":"other","workID":"video"}))["total"],
        0
    );
    assert_eq!(x["items"][0]["originalAvailable"], false);
}

#[test]
fn native_file_folder_relocation_scoped_copy_and_content_specific_inspection() {
    let db = fixture();
    db.execute_batch(include_str!("../src/inspection/schema.sql"))
        .unwrap();
    let hash = "a".repeat(64);
    let current = format!("sha256:{hash}:1");
    let data = json!({"id":"a","sessionID":"s","sourcePath":"x/a.nef","currentPath":"x/a.nef","relativePath":"x/a.nef",
        "projectID":"p","projectName":"P","fileSize":1,"contentHash":hash,"filename":"a.nef","rating":2,"camera":"Old",
        "decision":"keep","availability":"available","importState":"ready","isSequenceMember":false});
    db.execute_batch("INSERT INTO projects VALUES('p','{}'),('q','{}'); INSERT INTO sessions VALUES('s','{}');
      INSERT INTO lc_sessions(session_id,project_id,state,origin) VALUES('s','p','open','native'),('old','p','open','native');
      INSERT INTO lc_captures VALUES('cap'); INSERT INTO lc_files(file_id,capture_id,role) VALUES('f','cap','raw');
      INSERT INTO lc_asset_files VALUES('a','f');").unwrap();
    db.execute(
        "INSERT INTO assets VALUES('a','s','x/a.nef',?,0)",
        [data.to_string()],
    )
    .unwrap();
    for (cid, sha, session) in [(&*current, &*hash, "s"), ("other", &*"b".repeat(64), "old")] {
        db.execute(
            "INSERT OR IGNORE INTO lc_contents VALUES(?,?,1)",
            params![cid, sha],
        )
        .unwrap();
        db.execute("INSERT OR IGNORE INTO lc_occurrences(session_id,occurrence_id,asset_id,file_id,root_id,relative_path,content_id,disposition)
          VALUES(?,'occ','a','f','volume','x/a.nef',?,'admitted')",params![session,cid]).unwrap();
        db.execute("INSERT INTO lc_scopes SELECT ?1,?2,o.occurrence_id,'p','a','f',?3,'admitted','op' FROM lc_occurrences o WHERE session_id=?2 AND asset_id='a'",params![format!("s-{session}"),session,cid]).unwrap();
    }
    db.execute("INSERT INTO lc_scopes SELECT 'scope-q','s',o.occurrence_id,'q','a','f',?,'admitted','op' FROM lc_occurrences o WHERE session_id='s' AND asset_id='a'",[&current]).unwrap();
    db.execute(
        "INSERT INTO lc_inspect_manual VALUES('file:f','rating','5','inspection-action')",
        [],
    )
    .unwrap();
    for (content, lens) in [(&*current, "current lens"), ("other", "old lens")] {
        db.execute("INSERT INTO lc_inspect_files(file_id,content_id,fields_json,af_json,extractor) VALUES('f',?,?,'{}','source')",
            params![content,json!({"iso":800,"lens":lens}).to_string()]).unwrap();
    }
    command(
        &db,
        json!({"action":"org.saveWork","workID":"copy","kind":"virtual","masterWorkID":"file:f","name":"独立","projectID":"p"}),
    );
    assert_eq!(
        view(&db, json!({"workID":"copy","projectID":"q"}))["total"],
        0
    );
    assert_eq!(
        view(
            &db,
            json!({"workID":"copy","projectID":"p","predicate":{"field":"lens","op":"eq","value":"current lens"}})
        )["total"],
        1
    );
    {
        let tx = db.unchecked_transaction().unwrap();
        organization::relocate_managed(&tx, "f", "dest", "/managed", "B/sub/new.nef", "new.nef")
            .unwrap();
        tx.commit().unwrap();
    }
    let copy = view(&db, json!({"workID":"copy"}));
    assert_eq!(copy["items"][0]["metadata"]["rating"], 5);
    assert_eq!(copy["items"][0]["displayName"], "独立");
    assert_eq!(copy["items"][0]["volumeID"], "dest");
    let directory = tempfile::tempdir().unwrap();
    let cat = directory.path().join("cat.sqlite");
    let index = directory.path().join("search.sqlite");
    db.execute("VACUUM INTO ?", [cat.to_str().unwrap()])
        .unwrap();
    let request = json!({"projectID":"p","query":{"minimumRating":4}});
    assert_eq!(
        rawmaster_library::query::page(&cat, &index, &request).unwrap()["total"],
        1
    );
    let host = Connection::open(&cat).unwrap();
    host.execute_batch(
        "BEGIN; UPDATE lc_inspect_manual SET value_json='1' WHERE field='rating';
      INSERT INTO lc_changes(asset_id,domain) VALUES('a','inspection'); COMMIT;",
    )
    .unwrap();
    assert_eq!(
        rawmaster_library::query::page(&cat, &index, &request).unwrap()["total"],
        0
    );
}
