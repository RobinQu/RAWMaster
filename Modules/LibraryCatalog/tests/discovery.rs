use rawmaster_library::{discovery, organization, resources};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;
struct Library {
    _root: TempDir,
    db: Connection,
}
impl Library {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let db = Connection::open(root.path().join("catalog.sqlite")).unwrap();
        db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))
            .unwrap();
        db.execute_batch(include_str!("../src/authority_schema.sql"))
            .unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON;PRAGMA user_version=8; INSERT INTO lc_meta VALUES('libraryID','discovery-test');INSERT INTO lc_meta VALUES('operationRevision','0');").unwrap();
        resources::install(&db).unwrap();
        db.execute_batch(organization::SCHEMA).unwrap();
        db.execute_batch(discovery::SCHEMA).unwrap();
        Self { _root: root, db }
    }
    fn work(&self, id: &str, lat: Option<f64>, lon: Option<f64>, rating: i64) {
        self.db
            .execute(
                "INSERT OR IGNORE INTO lc_resources VALUES(?,'historicalAppearance',?,?,5,NULL)",
                params![id, id, "a".repeat(64)],
            )
            .unwrap();
        let tx = self.db.unchecked_transaction().unwrap();
        organization::apply(&tx,&json!({"action":"org.saveWork","kind":"offline","workID":id,"name":id,
   "rating":rating,"metadata":{"latitude":lat,"longitude":lon},"versionID":format!("v-{id}"),"appearance":{"kind":"jpeg","resourceID":id}})).unwrap();
        tx.commit().unwrap();
    }
    fn cmd(&self, mut v: Value) -> Value {
        let tx = self.db.unchecked_transaction().unwrap();
        v["commandID"] = v
            .get("commandID")
            .cloned()
            .unwrap_or_else(|| json!(uuid::Uuid::new_v4().to_string()));
        let out = discovery::apply(&tx, &v).unwrap();
        tx.commit().unwrap();
        out
    }
    fn get(&self, v: Value) -> Value {
        discovery::read(&self.db, &v).unwrap()
    }
    fn finish(&self, k: &str, work: &str, vector: Value) -> Value {
        self.cmd(json!({"action":"discover.enqueue","kind":k,"scope":{"workID":work}}));
        let j = self.cmd(json!({"action":"discover.claim","kind":k}))["job"].clone();
        assert_eq!(j["workID"], work);
        let mut b = json!({"action":"discover.finish","jobID":j["jobID"],"lease":j["lease"],"model":j["model"],"inputVersion":j["inputVersion"],"proxySHA256":"b".repeat(64)});
        if k == "scene" {
            b["vector"] = vector;
        } else {
            b["faces"] = json!([{"box":[0.2,0.2,0.5,0.5],"landmarks":[[0.3,0.3],[0.6,0.3],[0.5,0.5],[0.4,0.6],[0.6,0.6]],"confidence":0.99,"vector":vector}]);
        }
        self.cmd(b)
    }
}
fn vecn(n: usize, at: usize) -> Value {
    let mut v = vec![0.; n];
    v[at] = 1.;
    json!(v)
}
fn ids(o: &Value) -> Vec<&str> {
    o["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["workID"].as_str().unwrap())
        .collect()
}
#[test]
fn spherical_fences_rtree_boundary_dateline_poles_and_coordinate_change() {
    let l = Library::new();
    for (id, a, b) in [
        ("east", Some(10.), Some(179.9)),
        ("west", Some(10.), Some(-179.9)),
        ("edge", Some(9.), Some(179.)),
        ("away", Some(10.), Some(0.)),
        ("none", None, None),
        ("polar", Some(90.), Some(111.)),
    ] {
        l.work(id, a, b, 4);
    }
    let polygon = json!({"kind":"polygon","vertices":[[9,179],[9,-179],[11,-179],[11,179]]});
    let scope = |g: &Value| json!({"op":"search","geometry":g});
    let a = l.get(scope(&polygon));
    assert_eq!(ids(&a), vec!["east", "edge", "west"]);
    assert_eq!(a["spatialIndex"], "currentCoordinates");
    l.cmd(json!({"action":"discover.saveFence","fenceID":"wet","name":"湿地","geometry":polygon}));
    assert_eq!(
        l.cmd(json!({"action":"discover.rebuildSpatial"}))["indexed"],
        5
    );
    let b = l.get(json!({"op":"search","fenceID":"wet"}));
    assert_eq!(ids(&b), ids(&a));
    assert_eq!(b["spatialIndex"], "rtreeExact");
    for g in [
        json!({"kind":"circle","latitude":89.0,"longitude":-70.0,"radiusMeters":150000.0}),
        json!({"kind":"polygon","vertices":[[85,0],[85,120],[85,-120]]}),
    ] {
        assert_eq!(ids(&l.get(scope(&g))), vec!["polar"]);
    }
    let concave = json!({"kind":"polygon","vertices":[[0,0],[0,4],[4,4],[1,2],[4,0]]});
    l.work("inside", Some(0.5), Some(2.), 4);
    l.work("cutout", Some(3.9), Some(2.), 4);
    assert_eq!(ids(&l.get(scope(&concave))), vec!["inside"]);
    l.cmd(json!({"action":"discover.rebuildSpatial"}));
    l.work("moving", Some(10.), Some(179.7), 4);
    assert_eq!(
        ids(&l.get(scope(&polygon))),
        vec!["east", "edge", "moving", "west"]
    );
    let tx = l.db.unchecked_transaction().unwrap();
    organization::apply(&tx,&json!({"action":"org.saveWork","workID":"moving","metadata":{"latitude":null,"longitude":null}})).unwrap();
    tx.commit().unwrap();
    assert_eq!(ids(&l.get(scope(&polygon))), vec!["east", "edge", "west"]);
}
#[test]
fn semantic_hard_scope_partial_coverage_stale_jobs_cache_loss_and_human_labels() {
    let l = Library::new();
    for (id, a, r) in [
        ("scene-1", 0., 5),
        ("scene-2", 0., 2),
        ("scene-3", 0., 5),
        ("scene-4", 4., 5),
    ] {
        l.work(id, Some(a), Some(0.), r);
    }
    assert!(discovery::apply(&l.db, &json!({"action":"discover.enqueue","kind":"faces"})).is_err());
    l.cmd(json!({"action":"discover.configure","scene":true,"faces":true}));
    for work in ["scene-1", "scene-2", "scene-4"] {
        assert_eq!(l.finish("scene", work, vecn(768, 0))["status"], "done");
    }
    for work in ["scene-1", "scene-2", "scene-3"] {
        assert_eq!(
            l.finish(
                "faces",
                work,
                vecn(
                    rawmaster_library::discovery::FACE_DIMENSIONS,
                    if work == "scene-3" { 1 } else { 0 }
                )
            )["status"],
            "done"
        );
    }
    let clusters = l.get(json!({"op":"clusters"}));
    assert_eq!(clusters["items"].as_array().unwrap().len(), 2);
    let obs = l.get(json!({"op":"observations"}));
    let aid = |w: &str| {
        obs["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["workID"] == w)
            .unwrap()["observationID"]
            .clone()
    };
    let first=l.cmd(json!({"action":"discover.assign","personID":"friend","name":"朋友","observationIDs":[aid("scene-1"),aid("scene-2"),aid("scene-3")]}));
    let split=l.cmd(json!({"action":"discover.split","personID":"guest","name":"访客","observationIDs":[aid("scene-2")],"expectedRevision":first["humanRevision"]}));
    assert_eq!(
        ids(&l.get(json!({"op":"search","personID":"friend"}))),
        vec!["scene-1", "scene-3"]
    );
    let merge=l.cmd(json!({"action":"discover.merge","personID":"friend","fromPersonID":"guest","expectedRevision":split["humanRevision"]}));
    l.cmd(json!({"action":"discover.undo","editCommandID":merge["editCommandID"]}));
    assert_eq!(
        ids(&l.get(json!({"op":"search","personID":"guest"}))),
        vec!["scene-2"]
    );
    let search = json!({"op":"search","scope":{"query":{"minimumRating":4}},"geometry":{"kind":"circle","latitude":0,"longitude":0,"radiusMeters":50},
  "personID":"friend","vector":vecn(768,0),"model":discovery::SCENE,"minimumScore":0.5});
    let h = l.get(search.clone());
    assert_eq!(ids(&h), vec!["scene-1"]);
    assert_eq!(h["eligible"], 2);
    assert_eq!(h["missing"], 1);
    l.cmd(json!({"action":"discover.enqueue","kind":"scene","scope":{"workID":"scene-3"}}));
    let job = l.cmd(json!({"action":"discover.claim","kind":"scene"}))["job"].clone();
    l.cmd(json!({"action":"discover.stop","jobID":job["jobID"]}));
    assert_eq!(
        l.cmd(json!({"action":"discover.finish","jobID":job["jobID"],"lease":job["lease"]}))
            ["status"],
        "expired"
    );
    l.cmd(json!({"action":"discover.configure","faces":false}));
    assert_eq!(l.get(json!({"op":"observations"}))["items"], json!([]));
    assert_eq!(ids(&l.get(search.clone())), vec!["scene-1"]);
    l.cmd(json!({"action":"discover.clearIndex","kind":"faces"}));
    assert_eq!(
        ids(&l.get(json!({"op":"search","personID":"friend"}))),
        vec!["scene-1", "scene-3"]
    );
    let dir = l._root.path().join("LibraryIndexes");
    let cache = std::fs::read_dir(dir)
        .unwrap()
        .find_map(|e| {
            let p = e.ok()?.path();
            p.extension().filter(|x| *x == "sqlite").map(|_| p.clone())
        })
        .unwrap();
    std::fs::remove_file(cache).unwrap();
    assert_eq!(l.get(search)["missing"], 2);
    assert_eq!(
        l.cmd(json!({"action":"discover.enqueue","kind":"scene","scope":{"workID":"scene-1"}}))
            ["queued"],
        1
    );
    assert_eq!(
        l.db.query_row("SELECT count(*) FROM lc_archive_files", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn worker_receipts_omit_vectors_and_enforce_replay_and_input_versions() {
    let l = Library::new();
    l.work("v", Some(1.), Some(2.), 1);
    l.cmd(json!({"action":"discover.configure","scene":true}));
    let f = l.cmd(json!({"action":"discover.sync"}));
    assert_eq!(f["queued"], 1);
    assert_eq!(l.get(json!({"op":"pending"}))["kinds"], json!([]));
    let job = l.cmd(json!({"action":"discover.claim"}))["job"].clone();
    let cmd = json!({"action":"discover.finish","version":1,"commandID":"completion","jobID":job["jobID"],"lease":job["lease"],"inputVersion":job["inputVersion"],"model":discovery::SCENE,"proxySHA256":"b".repeat(64),"vector":vecn(768,0)});
    let tx = l.db.unchecked_transaction().unwrap();
    let done = rawmaster_library::authority::command(&tx, &cmd).unwrap();
    assert_eq!(done["status"], "done");
    assert_eq!(
        done,
        rawmaster_library::authority::command(&tx, &cmd).unwrap()
    );
    let mut changed = cmd;
    changed["vector"] = vecn(768, 1);
    assert!(rawmaster_library::authority::command(&tx, &changed).is_err());
    tx.commit().unwrap();
    let stored: String =
        l.db.query_row(
            "SELECT request FROM lc_receipts WHERE command_id='completion'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(stored.starts_with("sha256:"));
    assert!(!stored.contains("vector"));
    l.cmd(json!({"action":"discover.clearIndex","kind":"scene"}));
    l.cmd(json!({"action":"discover.enqueue","kind":"scene"}));
    let j = l.cmd(json!({"action":"discover.claim"}))["job"].clone();
    let tx = l.db.unchecked_transaction().unwrap();
    organization::apply(&tx,&json!({"action":"org.saveWork","workID":"v","versionID":"new","appearance":{"kind":"look"}})).unwrap();
    tx.commit().unwrap();
    assert_eq!(
        l.cmd(json!({"action":"discover.finish","jobID":j["jobID"],"lease":j["lease"]}))["status"],
        "stale"
    );
}

#[test]
fn pagination_invalidates_changed_candidates_and_scheduler_yields_on_large_admissions() {
    let l = Library::new();
    for i in 0..132 {
        l.work(&format!("capture-{i:03}"), Some(12.), Some(34.), 4);
    }
    let first = l.get(json!({"op":"search","limit":60}));
    let second = l.get(json!({"op":"search","limit":60,"cursor":first["nextCursor"]}));
    assert_eq!(ids(&first).len(), 60);
    assert_eq!(ids(&second).first(), Some(&"capture-060"));
    l.work("new", None, None, 0);
    assert_eq!(
        l.get(json!({"op":"search","limit":60,"cursor":first["nextCursor"]}))["status"],
        "staleCursor"
    );
    l.cmd(json!({"action":"discover.configure","scene":true}));
    assert_eq!(l.cmd(json!({"action":"discover.sync"}))["queued"], 128);
    assert_eq!(l.get(json!({"op":"pending"}))["kinds"], json!(["scene"]));
    assert_eq!(l.cmd(json!({"action":"discover.sync"}))["queued"], 5);
    assert_eq!(l.get(json!({"op":"pending"}))["kinds"], json!([]));
    l.cmd(json!({"action":"discover.stop"}));
    assert_eq!(l.get(json!({"op":"pending"}))["paused"], true);
    l.work("added-while-paused", None, None, 2);
    assert_eq!(
        l.cmd(json!({"action":"discover.claim"}))["job"],
        Value::Null
    );
    assert_eq!(l.cmd(json!({"action":"discover.resume"}))["queued"], 133);
    let n1 = l.cmd(json!({"action":"discover.sync"}))["queued"]
        .as_i64()
        .unwrap();
    let n2 = l.cmd(json!({"action":"discover.sync"}))["queued"]
        .as_i64()
        .unwrap();
    assert_eq!(n1 + n2, 1);
}

#[test]
fn replacing_a_damaged_feature_generation_leaves_foreign_bytes_and_authority_untouched() {
    let library = Library::new();
    library.work("portrait", None, None, 4);
    library.cmd(json!({"action":"discover.configure","scene":true}));
    library.finish("scene", "portrait", vecn(768, 0));
    let search = json!({"op":"search","vector":vecn(768,0),"model":discovery::SCENE});
    assert_eq!(library.get(search.clone())["indexed"], 1);
    let dir = library._root.path().join("LibraryIndexes");
    let target = std::fs::read_dir(&dir)
        .unwrap()
        .map(|r| r.unwrap().path())
        .find(|p| p.extension().is_some_and(|e| e == "sqlite"))
        .unwrap();
    let unrelated = b"unrelated local data";
    std::fs::write(&target, unrelated).unwrap();
    assert!(discovery::read(&library.db, &search).is_err());
    library.cmd(json!({"action":"discover.rebuildFeatures"}));
    assert_eq!(library.get(search.clone())["missing"], 1);
    library.finish("scene", "portrait", vecn(768, 0));
    assert_eq!(library.get(search)["indexed"], 1);
    assert_eq!(std::fs::read(target).unwrap(), unrelated);
    assert_eq!(
        library.get(json!({"op":"search","scope":{"query":{"minimumRating":4}}}))["count"],
        1
    );
}

#[test]
fn retired_face_generation_cannot_complete_or_inflate_current_progress() {
    let l = Library::new();
    l.work("v", None, None, 4);
    l.cmd(json!({"action":"discover.configure","faces":true}));
    l.cmd(json!({"action":"discover.enqueue","kind":"faces"}));
    let mut active = l.cmd(json!({"action":"discover.claim","kind":"faces"}))["job"].clone();
    let retired = "yunet-2023mar-sface-2021dec-edge1024-v1";
    l.db.execute(
        "UPDATE lc_discover_jobs SET job_id='retired-face-job',model=?1 WHERE job_id=?2",
        params![retired, active["jobID"].as_str().unwrap()],
    )
    .unwrap();
    active["jobID"] = json!("retired-face-job");
    assert_eq!(l.get(json!({"op":"jobs"}))["counts"], json!([]));
    let stale = l.cmd(json!({"action":"discover.finish","jobID":active["jobID"],"lease":active["lease"],
         "model":retired,"inputVersion":active["inputVersion"],"proxySHA256":"c".repeat(64),"faces":[]}));
    assert_eq!(stale["status"], "stale");
    l.db.execute(
        "UPDATE lc_discover_jobs SET state='queued' WHERE job_id=?1",
        [active["jobID"].as_str().unwrap()],
    )
    .unwrap();
    assert!(l.cmd(json!({"action":"discover.claim","kind":"faces"}))["job"].is_null());
    assert_eq!(
        l.cmd(json!({"action":"discover.sync","kind":"faces"}))["queued"],
        1
    );
    let fresh = l.cmd(json!({"action":"discover.claim","kind":"faces"}))["job"].clone();
    assert_eq!(fresh["model"], discovery::FACES);
    assert_ne!(fresh["jobID"], active["jobID"]);
    assert_eq!(
        l.get(json!({"op":"jobs"}))["counts"],
        json!([{"kind":"faces","state":"running","count":1}])
    );
}
