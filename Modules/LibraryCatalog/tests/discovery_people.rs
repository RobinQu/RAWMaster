use rawmaster_library::{discovery, organization, resources};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

struct Library {
    _dir: TempDir,
    db: Connection,
}
impl Library {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let db = Connection::open(dir.path().join("library.sqlite")).unwrap();
        db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))
            .unwrap();
        db.execute_batch(include_str!("../src/authority_schema.sql"))
            .unwrap();
        db.execute_batch("PRAGMA user_version=8;PRAGMA foreign_keys=ON;INSERT INTO lc_meta VALUES('libraryID','people-v8');").unwrap();
        resources::install(&db).unwrap();
        db.execute_batch(organization::SCHEMA).unwrap();
        db.execute_batch(discovery::SCHEMA).unwrap();
        let l = Self { _dir: dir, db };
        l.cmd(json!({"action":"discover.configure","faces":true}));
        l
    }
    fn cmd(&self, mut v: Value) -> Value {
        v["commandID"] = json!(uuid::Uuid::new_v4().to_string());
        let tx = self.db.unchecked_transaction().unwrap();
        let result = discovery::apply(&tx, &v).unwrap();
        tx.commit().unwrap();
        result
    }
    fn read(&self, v: Value) -> Value {
        discovery::read(&self.db, &v).unwrap()
    }
    fn work(&self, id: &str, source: &str, rating: i64) {
        let sha = format!("{:x}", Sha256::digest(source.as_bytes()));
        self.db
            .execute(
                "INSERT INTO lc_resources VALUES(?1,'historicalAppearance',?1,?2,5,NULL)",
                params![id, sha],
            )
            .unwrap();
        let tx = self.db.unchecked_transaction().unwrap();
        organization::apply(&tx,&json!({"action":"org.saveWork","kind":"offline","workID":id,"name":id,
            "rating":rating,"versionID":format!("v-{id}"),"appearance":{"kind":"jpeg","resourceID":id}})).unwrap();
        tx.commit().unwrap();
    }
    fn index(&self, work: &str, rows: &[(f64, f64, [f64; 4])]) -> Vec<String> {
        let detections:Vec<Value>=rows.iter().map(|(x,y,r)|{
            let mut v=vec![0.;discovery::FACE_DIMENSIONS];
            v[0]=*x;v[1]=*y;
            json!({"vector":v,"confidence":0.99,"box":r,"landmarks":[[0.2,0.2],[0.3,0.2],[0.25,0.25],[0.2,0.3],[0.3,0.3]]})
        }).collect();
        self.index_vectors(work, detections)
    }
    fn index_vectors(&self, work: &str, detections: Vec<Value>) -> Vec<String> {
        self.cmd(json!({"action":"discover.enqueue","kind":"faces","workIDs":[work]}));
        let job = self.cmd(json!({"action":"discover.claim","kind":"faces"}))["job"].clone();
        assert_eq!(job["workID"], work);
        self.cmd(json!({"action":"discover.finish","jobID":job["jobID"],"lease":job["lease"],"model":job["model"],"inputVersion":job["inputVersion"],"proxySHA256":"c".repeat(64),"faces":detections}));
        let mut values = self.read(json!({"op":"observations","scope":{"workID":work}}))["items"]
            .as_array()
            .unwrap()
            .to_vec();
        values.sort_by(|a, b| {
            a["box"][0]
                .as_f64()
                .unwrap()
                .total_cmp(&b["box"][0].as_f64().unwrap())
        });
        values
            .into_iter()
            .map(|v| v["observationID"].as_str().unwrap().to_owned())
            .collect()
    }
    fn person(&self, id: &str, obs: &str) {
        self.cmd(
            json!({"action":"discover.assign","personID":id,"name":id,"observationIDs":[obs]}),
        );
    }
}
const LEFT: [f64; 4] = [0.10, 0.10, 0.25, 0.25];
const RIGHT: [f64; 4] = [0.59, 0.15, 0.25, 0.25];

#[test]
fn scope_filters_candidates_and_ranked_people_are_separate_from_human_results() {
    let l = Library::new();
    for (work, source, rating) in [
        ("a-ref", "A-original", 1),
        ("a-duplicate", "A-original", 5),
        ("b-ref", "B-original", 1),
        ("a-good", "1", 5),
        ("almost-tied", "2", 5),
        ("b-good", "3", 5),
        ("a-low-rating", "4", 1),
        ("current-unindexed", "5", 5),
        ("zero-faces", "6", 5),
        ("second-a", "7", 5),
    ] {
        l.work(work, source, rating);
    }
    let a = l.index("a-ref", &[(1., 0., LEFT)]);
    l.person("alice", &a[0]);
    let b = l.index("b-ref", &[(0., 1., LEFT)]);
    l.person("beth", &b[0]);
    l.index("a-duplicate", &[(1., 0., LEFT)]);
    l.index("a-good", &[(1., 0., LEFT)]);
    l.index("second-a", &[(0.99, 0.03, LEFT)]);
    l.index("almost-tied", &[(1., 1., LEFT)]);
    l.index("b-good", &[(0., 1., LEFT)]);
    l.index("a-low-rating", &[(1., 0., LEFT)]);
    l.index("zero-faces", &[]);
    let req = json!({"op":"personMatches","personID":"alice","scope":{"query":{"minimumRating":5}},"limit":1});
    let first = l.read(req.clone());
    assert_eq!(first["status"], "ok");
    assert_eq!(first["eligibleWorks"], 7);
    assert_eq!(first["indexedWorks"], 6);
    assert_eq!(first["referenceCount"], 1);
    assert_eq!(first["count"], 2);
    let hit = &first["items"][0];
    assert_eq!(hit["workID"], "a-good");
    assert!(hit["personID"].is_null());
    assert!(hit["margin"].as_f64().unwrap() > 0.9);
    let confirmed = l.read(json!({"op":"search","personID":"alice"}));
    assert_eq!(confirmed["count"], 1);
    let mut next = req.clone();
    next["cursor"] = first["nextCursor"].clone();
    assert_eq!(l.read(next.clone())["items"][0]["workID"], "second-a");
    l.cmd(json!({"action":"discover.reject","personID":"alice","observationIDs":[hit["observationID"]],"expectedRevision":first["humanRevision"]}));
    assert_eq!(l.read(next)["status"], "staleCursor");
    assert_eq!(l.read(req.clone())["count"], 1);
    let tx = l.db.unchecked_transaction().unwrap();
    assert!(discovery::apply(&tx,&json!({"action":"discover.assign","personID":"alice","observationIDs":[hit["observationID"]],"expectedRevision":first["humanRevision"]})).is_err());
    drop(tx);
    l.cmd(json!({"action":"discover.configure","faces":false}));
    assert_eq!(l.read(req)["status"], "indexDisabled");
}
#[test]
fn bounded_diverse_templates_collapse_identical_sources_and_separate_people_in_one_photo() {
    let l = Library::new();
    for i in 0..12 {
        let work = format!("ref-{i:02}");
        let source = if i < 4 {
            "same-capture".to_owned()
        } else {
            work.clone()
        };
        l.work(&work, &source, 1);
        let (x, y) = if i >= 9 { (0., 1.) } else { (1., 0.) };
        let f = l.index(&work, &[(x, y, LEFT)]);
        l.person("a", &f[0]);
    }
    l.work("new", "c", 5);
    l.index("new", &[(0., 1., LEFT), (-1., 0., RIGHT)]);
    let r = l.read(json!({"op":"personMatches","personID":"a","scope":{"workID":"new"}}));
    assert_eq!(r["referenceCount"], 8);
    assert_eq!(r["count"], 1);
    assert!(r["items"][0]["margin"].is_null());
    assert_eq!(r["items"][0]["box"], json!(LEFT));
    l.work("duplicate", "same-capture", 5);
    l.index("duplicate", &[(1., 0., LEFT)]);
    assert_eq!(
        l.read(json!({"op":"personMatches","personID":"a","scope":{"workID":"duplicate"}}))
            ["count"],
        0
    );
}
#[test]
fn input_bound_anchors_survive_rebuild_without_attaching_different_content_or_recycled_ordinals() {
    let l = Library::new();
    l.work("first", "one", 5);
    l.work("candidate", "two", 5);
    let first = l.index("first", &[(1., 0., LEFT), (-1., 0., RIGHT)]);
    l.index("candidate", &[(1., 0., LEFT)]);
    l.person("p", &first[0]);
    let req = json!({"op":"personMatches","personID":"p"});
    assert_eq!(l.read(req.clone())["referenceCount"], 1);
    l.cmd(json!({"action":"discover.clearIndex","kind":"faces"}));
    let no = l.read(req.clone());
    assert_eq!(no["status"], "referenceUnindexed");
    assert_eq!(no["confirmedWorkCount"], 1);
    // Reversed detector order over exactly the same unchanged image.
    let fresh = l.index("first", &[(-1., 0., RIGHT), (1., 0., LEFT)]);
    assert_ne!(first[0], fresh[0]);
    let f = l.read(json!({"op":"observations","scope":{"workID":"first"}}));
    let named: Vec<_> = f["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|v| v["personID"] == "p")
        .collect();
    assert_eq!(named.len(), 1);
    assert_eq!(named[0]["box"], json!(LEFT));
    l.index("candidate", &[(1., 0., LEFT)]);
    assert_eq!(l.read(req.clone())["count"], 1);
    l.db.execute(
        "UPDATE lc_resources SET sha256=? WHERE resource_id='first'",
        ["f".repeat(64)],
    )
    .unwrap();
    l.index("first", &[(1., 0., LEFT)]);
    let altered = l.read(req);
    assert_eq!(altered["status"], "referenceUnindexed");
    assert_eq!(altered["confirmedWorkCount"], 1);
    assert_eq!(altered["unindexedReferenceWorks"], 1);
    assert_eq!(l.read(json!({"op":"search","personID":"p"}))["count"], 1);
}
#[test]
fn old_v8_anchor_requires_matching_historical_evidence_and_cache_loss_keeps_observations_visible() {
    let l = Library::new();
    l.work("old", "old", 4);
    let obs = l.index("old", &[(1., 0., LEFT), (0., 1., RIGHT)]);
    l.db.execute(
        "INSERT INTO lc_discover_people VALUES('legacy','legacy')",
        [],
    )
    .unwrap();
    let version: String =
        l.db.query_row(
            "SELECT input_version FROM lc_discover_faces WHERE observation_id=?",
            [&obs[0]],
            |r| r.get(0),
        )
        .unwrap();
    let old = "retired-detector-ordinal";
    // Historical detector and present detector both show the left face in this exact source version.
    l.db.execute(
        "INSERT INTO lc_discover_faces VALUES(?1,'old',?2,'retired',?3,'[]',1,'old-key')",
        params![old, version, serde_json::to_string(&LEFT).unwrap()],
    )
    .unwrap();
    l.db.execute(
        "INSERT INTO lc_discover_anchors VALUES(?1,'old',?2)",
        params![old, serde_json::to_string(&LEFT).unwrap()],
    )
    .unwrap();
    l.db.execute(
        "INSERT INTO lc_discover_labels VALUES(?1,'old',?2,'legacy')",
        params![old, serde_json::to_string(&LEFT).unwrap()],
    )
    .unwrap();
    let req = json!({"op":"personMatches","personID":"legacy"});
    assert_eq!(l.read(req.clone())["referenceCount"], 1);
    l.cmd(json!({"action":"discover.clearIndex","kind":"faces"}));
    assert_eq!(l.read(req.clone())["confirmedWorkCount"], 1);
    l.index("old", &[(1., 0., LEFT), (0., 1., RIGHT)]);
    assert_eq!(l.read(req.clone())["referenceCount"], 1);
    // Two overlapping new detections cannot borrow one label by ID or geometry.
    l.cmd(json!({"action":"discover.clearIndex","kind":"faces"}));
    l.index("old", &[(1., 0., LEFT), (0., 1., [0.11, 0.10, 0.25, 0.25])]);
    assert_eq!(l.read(req)["referenceCount"], 0);
    let cache = std::fs::read_dir(l._dir.path().join("LibraryIndexes"))
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .find(|p| p.extension().is_some_and(|e| e == "sqlite"))
        .unwrap();
    std::fs::remove_file(cache).unwrap();
    let clusters = l.read(json!({"op":"clusters"}));
    assert_eq!(clusters["observations"], 2);
    assert_eq!(clusters["items"].as_array().unwrap().len(), 2);
}

#[test]
fn a_single_unrepresentative_reference_cannot_overrule_a_better_supported_competitor() {
    let l = Library::new();
    for (id, who, x, y) in [
        ("a-one", "a", 1., 0.),
        ("a-two", "a", 0., 1.),
        ("b-one", "b", 0.8, 0.6),
        ("b-two", "b", 0.81, 0.59),
    ] {
        l.work(id, id, 1);
        let face = l.index(id, &[(x, y, LEFT)]);
        l.person(who, &face[0]);
    }
    l.work("probe", "probe", 5);
    l.index("probe", &[(1., 0., LEFT)]);
    let read = |person: &str| {
        l.read(json!({"op":"personMatches","personID":person,"scope":{"workID":"probe"}}))
    };
    assert_eq!(read("a")["count"], 0);
    let best = read("b");
    assert_eq!(best["count"], 1);
    assert!((0.79..0.82).contains(&best["items"][0]["score"].as_f64().unwrap()));
    assert!(best["items"][0]["margin"].as_f64().unwrap() > 0.29);
}

#[test]
fn sparse_single_identity_gallery_requires_a_tighter_match_and_partial_cache_preserves_labels() {
    let l = Library::new();
    l.work("only", "sample-a", 4);
    let a = l.index("only", &[(1., 0., LEFT)]);
    l.person("a", &a[0]);
    l.work("between-thresholds", "sample-query", 4);
    let x = 0.64_f64;
    l.index("between-thresholds", &[(x, (1. - x * x).sqrt(), LEFT)]);
    let req = json!({"op":"personMatches","personID":"a","scope":{"workID":"between-thresholds"}});
    assert_eq!(l.read(req.clone())["count"], 0);
    l.work("rival", "sample-b", 1);
    let b = l.index("rival", &[(-1., 0., LEFT)]);
    l.person("b", &b[0]);
    let with_rival = l.read(req.clone());
    assert_eq!(with_rival["count"], 1);
    assert!(with_rival["items"][0]["margin"].as_f64().unwrap() > 1.);
    let cache = std::fs::read_dir(l._dir.path().join("LibraryIndexes"))
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .find(|p| p.extension().is_some_and(|e| e == "sqlite"))
        .unwrap();
    let c = Connection::open(cache).unwrap();
    c.execute("DELETE FROM features WHERE key=?", params![a[0]])
        .unwrap();
    let missing = l.read(req);
    assert_eq!(missing["status"], "referenceUnindexed");
    assert_eq!(missing["confirmedWorkCount"], 1);
    assert_eq!(missing["unindexedReferenceWorks"], 1);
    assert_eq!(l.read(json!({"op":"search","personID":"a"}))["count"], 1);
}

#[test]
fn folder_collection_keywords_and_project_membership_match_the_ordinary_grid() {
    let l = Library::new();
    let org = |v: Value| {
        let tx = l.db.unchecked_transaction().unwrap();
        organization::apply(&tx, &v).unwrap();
        tx.commit().unwrap();
    };
    org(json!({"action":"org.saveVolume","volumeID":"v","name":"V","online":false}));
    org(json!({"action":"org.saveFolder","folderID":"parent","volumeID":"v","name":"父目录"}));
    org(
        json!({"action":"org.saveFolder","folderID":"child","volumeID":"v","parentID":"parent","name":"子目录"}),
    );
    for id in ["reference", "visible", "other"] {
        l.work(id, id, 4);
    }
    l.db.execute("UPDATE lc_org_works SET project_id='p1',folder_id='child',metadata_json=? WHERE work_id='visible'",
        [json!({"keywords":[{"path":["动物","驯鹿"]}]}).to_string()]).unwrap();
    l.db.execute(
        "UPDATE lc_org_works SET project_id='p2' WHERE work_id='other'",
        [],
    )
    .unwrap();
    org(
        json!({"action":"org.saveCollection","collectionID":"one","kind":"regular","name":"普通集合"}),
    );
    org(json!({"action":"org.setMembers","collectionID":"one","workIDs":["visible"]}));
    let reference = l.index("reference", &[(1., 0., LEFT)]);
    l.person("p", &reference[0]);
    l.index("visible", &[(1., 0., LEFT)]);
    l.index("other", &[(1., 0., LEFT)]);
    for (scope, expected) in [
        (json!({"projectID":"p1"}), vec!["visible"]),
        (json!({"projectID":"p2","query":{}}), vec!["other"]),
        (json!({"projectID":"missing"}), vec![]),
        (json!({"projectID":""}), vec![]),
        (
            json!({"folderID":"parent","includeDescendants":true}),
            vec!["visible"],
        ),
        (
            json!({"folderID":"parent","includeDescendants":false}),
            vec![],
        ),
        (json!({"collectionID":"one"}), vec!["visible"]),
        (json!({"query":{"text":"驯鹿"}}), vec!["visible"]),
        (json!({"projectID":"p2","query":{"text":"驯鹿"}}), vec![]),
    ] {
        let ordinary = l.read(json!({"op":"search","scope":scope}));
        let suggestions = l.read(json!({"op":"personMatches","personID":"p","scope":scope}));
        assert_eq!(
            ordinary["scopeWorks"], suggestions["eligibleWorks"],
            "{scope}"
        );
        let ids: Vec<_> = suggestions["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["workID"].as_str().unwrap())
            .collect();
        assert_eq!(ids, expected, "{scope}");
    }
}

#[path = "discovery/private_gallery.rs"]
mod private_gallery;
