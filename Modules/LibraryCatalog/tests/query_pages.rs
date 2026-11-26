use rawmaster_library::query::{page, refresh};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::PathBuf;
use tempfile::{tempdir, TempDir};

struct Library {
    _temporary: TempDir,
    catalog: PathBuf,
    search: PathBuf,
    db: Connection,
}
impl Library {
    fn new() -> Self {
        let temporary = tempdir().unwrap();
        let catalog = temporary.path().join("catalog.sqlite");
        let search = temporary.path().join("indexes/search.sqlite");
        let db = Connection::open(&catalog).unwrap();
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA user_version=8;
            CREATE TABLE lc_meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO lc_meta VALUES('libraryID','test-library');
            CREATE TABLE lc_changes(seq INTEGER PRIMARY KEY AUTOINCREMENT,asset_id TEXT,domain TEXT);
            CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions VALUES ('s');
            CREATE TABLE projects(id TEXT PRIMARY KEY,data TEXT); INSERT INTO projects VALUES ('p','{\"name\":\"P\"}'),('q','{\"name\":\"Q\"}');
            CREATE TABLE assets(id TEXT PRIMARY KEY,session_id TEXT,data TEXT);
            CREATE TABLE asset_tags(asset_id TEXT PRIMARY KEY,data TEXT);
            CREATE TABLE asset_color_labels(asset_id TEXT PRIMARY KEY,data TEXT);
            CREATE TABLE review_records(asset_id TEXT PRIMARY KEY,data TEXT);
            CREATE TABLE membership(group_id TEXT,asset_id TEXT,position INTEGER,included INTEGER);
            CREATE TABLE groups_data(id TEXT PRIMARY KEY,project_id TEXT); INSERT INTO groups_data VALUES('group','p');
            CREATE TABLE lc_group_versions(group_id TEXT,revision INTEGER,project_id TEXT,tombstoned INTEGER);
            CREATE TABLE lc_group_file_members(file_id TEXT,group_id TEXT,revision INTEGER,position INTEGER,included INTEGER);
            CREATE TABLE lc_group_dirty(group_id TEXT PRIMARY KEY);
            CREATE TABLE lc_files(file_id TEXT PRIMARY KEY,capture_id TEXT,role TEXT);
            CREATE TABLE lc_asset_files(asset_id TEXT PRIMARY KEY,file_id TEXT);
            CREATE TABLE lc_scopes(project_id TEXT,asset_id TEXT,file_id TEXT,kind TEXT);
            CREATE VIEW lc_catalog_files(file_id,asset_id,capture_id,project_id) AS
                SELECT s.file_id,min(s.asset_id),f.capture_id,s.project_id FROM lc_scopes s
                JOIN assets a ON a.id=s.asset_id JOIN lc_files f ON f.file_id=s.file_id GROUP BY s.project_id,s.file_id;").unwrap();
        Self {
            _temporary: temporary,
            catalog,
            search,
            db,
        }
    }
    fn asset(
        &self,
        id: &str,
        file: &str,
        capture: &str,
        name: &str,
        date: Option<f64>,
        rating: i64,
    ) {
        let data = json!({"id":id,"sessionID":"s","projectID":"p","projectName":"P","sourcePath":name,"currentPath":name,
            "relativePath":name,"filename":name,"fileSize":1,"capturedAt":date,"camera":" Ｃafé ","rating":rating,
            "decision":"undecided","availability":"available","importState":"ready","isSequenceMember":false});
        self.db
            .execute(
                "INSERT OR IGNORE INTO lc_files VALUES(?,?,?)",
                params![
                    file,
                    capture,
                    if name.ends_with(".RAW") {
                        "raw"
                    } else {
                        "jpeg"
                    }
                ],
            )
            .unwrap();
        self.db
            .execute("INSERT INTO lc_asset_files VALUES(?,?)", params![id, file])
            .unwrap();
        self.db
            .execute(
                "INSERT INTO assets VALUES(?,'s',?)",
                params![id, data.to_string()],
            )
            .unwrap();
    }
    fn admit(&self, id: &str, file: &str, project: &str) {
        self.db
            .execute(
                "INSERT INTO lc_scopes VALUES(?,?,?,'admitted')",
                params![project, id, file],
            )
            .unwrap();
    }
    fn change(&self, id: Option<&str>) {
        self.db
            .execute(
                "INSERT INTO lc_changes(asset_id,domain) VALUES(?,'scope')",
                [id],
            )
            .unwrap();
    }
    fn page(&self, req: Value) -> Value {
        page(&self.catalog, &self.search, &req).unwrap()
    }
    fn basic() -> Self {
        let library = Self::new();
        for (id, file, cap, name, date, rating) in [
            ("b", "raw", "pair", "照片10.RAW", Some(10.), 5),
            ("a", "jpg", "pair", "照片2.JPG", Some(10.), 2),
            ("c", "solo", "snap", "度假1.JPG", None, 5),
            ("h", "hidden", "excluded", "照片1.RAW", Some(20.), 5),
        ] {
            library.asset(id, file, cap, name, date, rating);
            if id != "h" {
                library.admit(id, file, "p");
            }
        }
        library
            .db
            .execute_batch(
                "INSERT INTO asset_tags VALUES ('b','[\"旅行\",\"山\"]'),('a','[\"旅行\"]');
            INSERT INTO asset_color_labels VALUES ('b','{\"label\":\"red\"}');
            INSERT INTO review_records VALUES ('b','{\"reviewed\":true}');
            INSERT INTO membership VALUES ('group','b',0,1),('group','a',1,0);",
            )
            .unwrap();
        library
    }
}
fn ids(items: &Value) -> Vec<String> {
    items
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["assetID"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn same_file_filters_capture_provenance_and_exact_facets() {
    let l = Library::basic();
    let q = json!({"projectID":"p","level":"capture","query":{"camera":"cafe","filename":"照","tags":["山","旅行"],
        "tagMatch":"all","review":"reviewed","colorLabel":"red"},"facets":["tag","review","colorLabel"],"includeOrderedIDs":true});
    let result = l.page(q);
    assert_eq!(result["totalFiles"], 1);
    assert_eq!(result["totalCaptures"], 1);
    assert_eq!(result["orderedAssetIDs"], json!(["b"]));
    assert_eq!(result["orderedObjectIDs"], json!(["pair"]));
    assert_eq!(result["items"][0]["matchedFileIDs"], json!(["raw"]));
    assert_eq!(
        result["items"][0]["matches"][0],
        json!({"assetID":"b","captureID":"pair","fileID":"raw","projectID":"p"})
    );
    assert_eq!(
        result["facets"]["review"],
        json!([{"value":true,"files":1,"captures":1,"count":1}])
    );
    // The highly rated RAW does not make the other member a highly rated JPEG.
    let different_members = l.page(
        json!({"level":"capture","query":{"filename":"照片"},"predicate":{"all":[
        {"field":"format","op":"eq","value":"jpg"},{"field":"rating","op":"gte","value":4}]}}),
    );
    assert_eq!(different_members["total"], 0);
    // The sole solo JPEG has no capture time. Its zero rating/time sentinel
    // cannot match a real interval by accident.
    assert_eq!(
        l.page(json!({"predicate":{"field":"capturedAt","op":"missing"}}))["total"],
        1
    );
    assert_eq!(
        l.page(json!({"query":{"capturedFrom":0,"capturedBefore":10}}))["total"],
        0
    );
    assert_eq!(
        l.page(json!({"query":{"capturedFrom":10,"capturedBefore":11}}))["total"],
        2
    );
}

#[test]
fn keyset_pages_keep_legacy_numeric_order_ties_nulls_and_group_positions() {
    let l = Library::basic();
    for sort in [
        "original",
        "filename",
        "capturedAscending",
        "capturedDescending",
        "ratingDescending",
    ] {
        let all = l.page(json!({"projectID":"p","sort":sort,"includeOrderedIDs":true}));
        let expected = ids(&all["items"]);
        assert_eq!(all["orderedAssetIDs"], json!(expected));
        let mut req = json!({"projectID":"p","sort":sort,"pageSize":1});
        let mut actual = Vec::new();
        loop {
            let result = l.page(req.clone());
            assert_eq!(result["status"], "ok");
            actual.extend(ids(&result["items"]));
            req["cursor"] = result["nextCursor"].clone();
            if req["cursor"].is_null() {
                break;
            }
            assert!(actual.len() <= 3);
        }
        assert_eq!(actual, expected);
        if sort.starts_with("captured") {
            assert_eq!(actual, ["a", "b", "c"]);
        }
        if sort == "filename" {
            assert!(
                actual.iter().position(|id| id == "a") < actual.iter().position(|id| id == "b")
            );
        }
    }
    assert_eq!(
        ids(&l.page(json!({"groupID":"group"}))["items"]),
        ["b", "a"]
    );
    assert_eq!(
        ids(&l.page(json!({"orderBase":"store"}))["items"]),
        ["b", "a", "c"]
    );
    assert!(page(
        &l.catalog,
        &l.search,
        &json!({"query":{"unknownFeature":true}})
    )
    .is_err());
}

#[test]
fn repeated_logical_file_changes_representative_and_exclusion_expires_cursor() {
    let l = Library::basic();
    l.asset("z", "jpg", "pair", "另一次导入.JPG", Some(10.), 0);
    l.admit("z", "jpg", "p");
    l.admit("a", "jpg", "q");
    let first = l.page(json!({"pageSize":1,"includeOrderedIDs":true}));
    assert_eq!(first["totalFiles"], 3);
    assert_eq!(first["totalCaptures"], 2);
    assert_eq!(first["orderedAssetIDs"].as_array().unwrap().len(), 3);
    let cursor = first["nextCursor"].clone();
    let generation = first["generation"].clone();
    assert_eq!(
        l.page(json!({"projectID":"q","cursor":cursor}))["status"],
        "staleCursor"
    );
    l.db.execute_batch(
        "BEGIN; DELETE FROM lc_scopes WHERE asset_id='a';
        INSERT INTO lc_changes(asset_id,domain) VALUES('a','scope'); COMMIT;",
    )
    .unwrap();
    let refreshed = l.page(json!({"projectID":"p","includeOrderedIDs":true}));
    assert_eq!(refreshed["generation"], generation);
    assert_eq!(refreshed["totalFiles"], 3);
    let action = refreshed["orderedAssetIDs"].as_array().unwrap();
    assert!(action.contains(&json!("z")));
    assert!(!action.contains(&json!("a")));
    assert_eq!(
        l.page(json!({"pageSize":1,"cursor":cursor}))["status"],
        "staleCursor"
    );
    assert_eq!(l.page(json!({"projectID":"q"}))["total"], 0);
    // A global event forces a new published generation even if counts coincide.
    l.change(None);
    let rebuilt = refresh(&l.catalog, &l.search).unwrap();
    assert_ne!(rebuilt["generation"], generation);
    assert_eq!(l.page(json!({}))["total"], 3);
}

#[test]
fn opened_catalog_and_foreign_database_cannot_be_repurposed_as_search_cache() {
    let l = Library::basic();
    assert!(page(&l.catalog, &l.catalog, &json!({})).is_err());
    assert!(page(
        &l.catalog,
        &l._temporary.path().join("catalog.sqlite-wal"),
        &json!({})
    )
    .is_err());
    let other = l._temporary.path().join("other.sqlite");
    Connection::open(&other)
        .unwrap()
        .execute("CREATE TABLE personal(value TEXT)", [])
        .unwrap();
    assert!(page(&l.catalog, &other, &json!({})).is_err());
    let objects: i64 = Connection::open(other)
        .unwrap()
        .query_row(
            "SELECT count(*) FROM sqlite_schema WHERE type='table'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(objects, 1);
}

#[cfg(unix)]
#[test]
fn every_cache_file_is_checked_against_every_catalog_file_by_inode_before_open() {
    use std::fs;
    fn companion(main: &std::path::Path, suffix: &str) -> PathBuf {
        let mut name = main.as_os_str().to_owned();
        name.push(suffix);
        PathBuf::from(name)
    }
    let l = Library::basic();
    let dir = l._temporary.path();
    let rollback = companion(&l.catalog, "-journal");
    // This isolated WAL fixture keeps the WAL and SHM present. A fourth
    // ordinary inode allows checking the rollback-journal name in the same matrix.
    fs::write(&rollback, b"rollback-journal sentinel").unwrap();
    let suffixes = ["", "-wal", "-shm", "-journal"];
    for (i, source_suffix) in suffixes.iter().enumerate() {
        let source = companion(&l.catalog, source_suffix);
        let expected = fs::read(&source).unwrap();
        for (j, index_suffix) in suffixes.iter().enumerate() {
            let cache = dir.join(format!("cache-{i}-{j}.sqlite"));
            let alias = companion(&cache, index_suffix);
            fs::hard_link(&source, &alias).unwrap();
            let error = page(&l.catalog, &cache, &json!({})).unwrap_err();
            assert!(
                error.to_string().contains("conflicts with catalog"),
                "{source_suffix:?} -> {index_suffix:?}: {error}"
            );
            if !index_suffix.is_empty() {
                assert!(!cache.exists());
            }
            assert_eq!(fs::read(&source).unwrap(), expected);
            fs::remove_file(alias).unwrap();
        }
    }
    fs::remove_file(&rollback).unwrap();
    // A prospective output directory must not occupy the catalog's journal.
    assert!(page(&l.catalog, &rollback.join("search.sqlite"), &json!({})).is_err());
    assert!(!rollback.exists());
}

#[test]
fn new_group_versions_keep_project_scope_and_tombstones() {
    let l = Library::basic();
    l.admit("b", "raw", "q");
    l.db.execute_batch("INSERT INTO lc_group_versions VALUES('group',1,'p',0),('group',2,'p',0);
        INSERT INTO lc_group_file_members VALUES('raw','group',1,0,1),('jpg','group',1,1,0),('jpg','group',2,0,1);
        INSERT INTO lc_changes(asset_id,domain) VALUES(NULL,'group');").unwrap();
    assert_eq!(ids(&l.page(json!({"groupID":"group"}))["items"]), ["a"]);
    assert_eq!(
        l.page(json!({"groupID":"group","projectID":"q"}))["total"],
        0
    );
    l.db.execute_batch("INSERT INTO lc_group_dirty VALUES('group'); INSERT INTO lc_changes(asset_id,domain) VALUES(NULL,'group');").unwrap();
    assert_eq!(
        ids(&l.page(json!({"groupID":"group"}))["items"]),
        ["b", "a"]
    );
    l.db.execute_batch(
        "DELETE FROM lc_group_dirty; INSERT INTO lc_group_versions VALUES('group',3,'p',1);
        INSERT INTO lc_changes(asset_id,domain) VALUES(NULL,'group');",
    )
    .unwrap();
    assert_eq!(l.page(json!({"groupID":"group"}))["total"], 0);
}

#[test]
fn unfinished_generation_resumes_after_reopen_and_uncommitted_sources_stay_invisible() {
    let l = Library::basic();
    let before = l.page(json!({}));
    l.db.execute_batch(
        "BEGIN; DELETE FROM lc_scopes WHERE asset_id='b';
        INSERT INTO lc_changes(asset_id,domain) VALUES('b','scope');",
    )
    .unwrap();
    assert_eq!(l.page(json!({}))["totalFiles"], 3);
    l.db.execute_batch("ROLLBACK").unwrap();
    // Recreate the persisted initial checkpoint of a rebuild whose worker exited.
    l.change(None);
    let cache = Connection::open(&l.search).unwrap();
    cache
        .execute(
            "INSERT INTO generations(library,source_stamp,state,watermark)
        SELECT library,source_stamp,'building',1 FROM generations WHERE state='active'",
            [],
        )
        .unwrap();
    drop(cache);
    let after = l.page(json!({}));
    assert_ne!(after["generation"], before["generation"]);
    assert_eq!(after["watermark"], 1);
    assert_eq!(after["totalFiles"], 3);
}

#[test]
fn explicit_rebuild_preserves_existing_read_snapshot_and_foreign_databases() {
    use rawmaster_library::query::{rebuild, validate};
    let l = Library::basic();
    let before = l.page(json!({"pageSize":1}));
    let held = Connection::open(&l.search).unwrap();
    held.execute_batch("BEGIN").unwrap();
    let token: String = held
        .query_row(
            "SELECT token FROM generations WHERE state='active'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let next = rebuild(&l.catalog, &l.search).unwrap();
    assert_ne!(next["generation"], before["generation"]);
    assert_eq!(
        held.query_row(
            "SELECT token FROM generations WHERE state='active'",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        token
    );
    held.execute_batch("ROLLBACK").unwrap();
    drop(held);
    assert_eq!(
        l.page(json!({"cursor":before["nextCursor"]}))["status"],
        "staleCursor"
    );
    assert_eq!(
        validate(&l.catalog, &l.search).unwrap()["generation"],
        next["generation"]
    );
    // Preserve an explicitly owned, incompatible cache at its original pathname.
    {
        let old = Connection::open(&l.search).unwrap();
        old.pragma_update(None, "user_version", 999).unwrap();
    }
    let recovered = rebuild(&l.catalog, &l.search).unwrap();
    assert_eq!(recovered["recovered"], true);
    assert_eq!(l.page(json!({}))["totalFiles"], 3);
    assert_eq!(
        Connection::open(&l.search)
            .unwrap()
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        999
    );
    let other = l._temporary.path().join("foreign.sqlite");
    let db = Connection::open(&other).unwrap();
    db.execute("CREATE TABLE personal(value TEXT)", []).unwrap();
    db.execute("INSERT INTO personal VALUES('keep')", [])
        .unwrap();
    drop(db);
    assert!(rebuild(&l.catalog, &other).is_err());
    assert_eq!(
        Connection::open(other)
            .unwrap()
            .query_row("SELECT value FROM personal", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "keep"
    );
}

#[test]
fn unreadable_owned_cache_recovers_without_erasing_diagnostic_bytes() {
    use rawmaster_library::query::rebuild;
    let l = Library::basic();
    l.page(json!({}));
    let original = b"damaged owned cache; preserve for inspection";
    std::fs::write(&l.search, original).unwrap();
    let result = rebuild(&l.catalog, &l.search).unwrap();
    assert_eq!(result["recovered"], true);
    assert_eq!(std::fs::read(&l.search).unwrap(), original);
    assert_eq!(l.page(json!({}))["totalCaptures"], 2);
}

#[test]
fn east_asian_short_queries_use_the_unigram_index() {
    let library = Library::new();
    for (id, name) in [
        ("fuji", "富士山樱花.RAW"),
        ("gap", "富士Nikon山.RAW"),
        ("seoul", "서울한강.JPG"),
        ("kana", "ふじさん.JPG"),
    ] {
        library.asset(id, id, id, name, Some(1.), 0);
        library.admit(id, id, "p");
    }
    let query = |needle: &str| {
        ids(&library.page(json!({
            "projectID":"p",
            "query":{"filename":needle},
            "includeOrderedIDs":true
        }))["items"])
    };
    assert_eq!(query("富").len(), 2);
    assert_eq!(query("富士").len(), 2);
    // A Latin word between the two ideographs must not produce a false phrase match.
    assert_eq!(query("士山"), vec!["fuji"]);
    assert_eq!(query("富士山"), vec!["fuji"]);
    assert_eq!(query("한강"), vec!["seoul"]);
    assert_eq!(query("ふじ"), vec!["kana"]);
    let body = |needle: &str| {
        ids(&library.page(json!({
            "projectID":"p",
            "query":{"text":needle},
            "includeOrderedIDs":true
        }))["items"])
    };
    assert_eq!(body("富士").len(), 2);
    assert_eq!(body("한강"), vec!["seoul"]);

    let cache = Connection::open(&library.search).unwrap();
    let has_fts: bool = cache
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='search_fts')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let has_cjk: bool = cache
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='search_cjk')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    if has_fts {
        assert!(has_cjk, "CJK index is missing while FTS5 is available");
    }
    if has_cjk {
        let count: i64 = cache
            .query_row("SELECT count(*) FROM search_cjk", [], |r| r.get(0))
            .unwrap();
        assert!(count >= 4, "CJK index has {count} rows");
    }
}

#[test]
fn repeated_facet_pages_reuse_the_watermark_cache() {
    let library = Library::basic();
    let request = json!({
        "projectID":"p",
        "facets":["rating","camera"],
        "includeOrderedIDs":true
    });
    let first = library.page(request.clone());
    let cache = Connection::open(&library.search).unwrap();
    cache
        .create_collation("rm_natural", |a, b| a.cmp(b))
        .unwrap();
    let rows: i64 = cache
        .query_row("SELECT count(*) FROM facet_cache", [], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 1);

    // Overwrite the cached payload with a sentinel. If the second page consults the cache for
    // this generation and watermark it must return the sentinel, not the recomputed histogram.
    cache
        .execute(
            "UPDATE facet_cache SET payload=?",
            [r#"{"rating":[{"value":"cached","files":1,"captures":1,"count":1}]}"#],
        )
        .unwrap();
    let second = library.page(request);
    assert_eq!(second["facets"]["rating"][0]["value"], "cached");
    assert_ne!(first["facets"]["rating"][0]["value"], "cached");
}

#[test]
fn cjk_index_is_backfilled_when_an_existing_cache_is_opened() {
    let library = Library::new();
    library.asset("cjk", "cjk", "cjk", "富士山樱花.RAW", Some(1.), 0);
    library.admit("cjk", "cjk", "p");
    assert_eq!(
        ids(&library.page(json!({"projectID":"p","query":{"filename":"富士"}}))["items"]),
        vec!["cjk"]
    );

    {
        let cache = Connection::open(&library.search).unwrap();
        cache
            .create_collation("rm_natural", |a, b| a.cmp(b))
            .unwrap();
        cache
            .execute_batch(
                "DROP TRIGGER IF EXISTS cjk_add;
                 DROP TRIGGER IF EXISTS cjk_remove;
                 DROP TABLE IF EXISTS search_cjk;
                 DROP TABLE IF EXISTS search_features;",
            )
            .unwrap();
    }

    assert_eq!(
        ids(&library.page(json!({"projectID":"p","query":{"filename":"士山"}}))["items"]),
        vec!["cjk"]
    );
    let cache = Connection::open(&library.search).unwrap();
    cache
        .create_collation("rm_natural", |a, b| a.cmp(b))
        .unwrap();
    let has_cjk: bool = cache
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='search_cjk')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(has_cjk);
}
