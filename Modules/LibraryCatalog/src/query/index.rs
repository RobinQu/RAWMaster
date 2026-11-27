use super::text;
use crate::Result;
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

pub(super) const APPLICATION: i64 = 0x524d5131;
const FORMAT: i64 = 1;
const CHUNK: i64 = 256;
pub(super) const BASE: &str =
    "session_ord,session_id,relative_path COLLATE rm_natural,path_tie,asset_id,project_id,file_id";

fn id(db: &Connection) -> rusqlite::Result<i64> {
    db.query_row("PRAGMA application_id", [], |r| r.get(0))
}

fn ensure_facet_cache(db: &Connection) -> Result<()> {
    let exists: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='facet_cache')",
        [],
        |r| r.get(0),
    )?;
    if !exists {
        db.execute_batch(
            "CREATE TABLE facet_cache(
                 gen INTEGER NOT NULL, watermark INTEGER NOT NULL,
                 fingerprint TEXT NOT NULL, names TEXT NOT NULL, payload TEXT NOT NULL,
                 PRIMARY KEY(gen,watermark,fingerprint,names)
             ) WITHOUT ROWID",
        )?;
    }
    Ok(())
}

fn cjk_table(db: &Connection) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='search_cjk')",
        [],
        |r| r.get(0),
    )?)
}

fn cjk_marker(db: &Connection) -> Result<bool> {
    let table: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='search_features')",
        [],
        |r| r.get(0),
    )?;
    if !table {
        return Ok(false);
    }
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM search_features WHERE key='cjk_v1' AND value='1')",
        [],
        |r| r.get(0),
    )?)
}

/// Create the CJK unigram table and its document triggers. Returns false when FTS5 is not
/// available; the caller then keeps the `instr` fallback.
fn create_cjk(db: &Connection) -> Result<bool> {
    let triggers = "CREATE TRIGGER IF NOT EXISTS cjk_add AFTER INSERT ON documents BEGIN
             INSERT INTO search_cjk(rowid,name,body)
             VALUES(new.doc,rm_cjk(new.name_key),rm_cjk(new.body)); END;
         CREATE TRIGGER IF NOT EXISTS cjk_remove AFTER DELETE ON documents BEGIN
             DELETE FROM search_cjk WHERE rowid=old.doc; END;";
    // Contentless saves the stored copy of name/body; contentless_delete keeps rowid deletes
    // cheap. Older SQLite builds without the option fall back to a regular FTS5 table.
    let contentless = db.execute_batch(
        "CREATE VIRTUAL TABLE IF NOT EXISTS search_cjk USING fts5(
             name,body,content='',contentless_delete=1,tokenize='unicode61'
         )",
    );
    match contentless {
        Ok(()) => (),
        Err(e)
            if e.to_string().contains("contentless_delete")
                || e.to_string().contains("unrecognized option") =>
        {
            db.execute_batch(
                "CREATE VIRTUAL TABLE IF NOT EXISTS search_cjk USING fts5(
                     name,body,tokenize='unicode61'
                 )",
            )?;
        }
        Err(e)
            if e.to_string().contains("no such module: fts5")
                || e.to_string().contains("tokenizer") =>
        {
            return Ok(false)
        }
        Err(e) => return Err(e.into()),
    }
    db.execute_batch(triggers)?;
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS search_features(
             key TEXT PRIMARY KEY, value TEXT NOT NULL
         ) WITHOUT ROWID",
    )?;
    Ok(true)
}

/// Existing caches gain the CJK table in place. The marker makes the full backfill once-only;
/// a crash before the marker is committed simply repeats it.
fn ensure_cjk(db: &Connection) -> Result<()> {
    if cjk_table(db)? && cjk_marker(db)? {
        return Ok(());
    }
    let tx = Transaction::new_unchecked(db, TransactionBehavior::Immediate)?;
    if !cjk_table(&tx)? || !cjk_marker(&tx)? {
        if !create_cjk(&tx)? {
            tx.commit()?;
            return Ok(());
        }
        if !cjk_table(&tx)? || !cjk_marker(&tx)? {
            tx.execute("DELETE FROM search_cjk", [])?;
            tx.execute(
                "INSERT INTO search_cjk(rowid,name,body)
                 SELECT doc,rm_cjk(name_key),rm_cjk(body) FROM documents",
                [],
            )?;
            tx.execute(
                "INSERT OR REPLACE INTO search_features VALUES('cjk_v1','1')",
                [],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}

fn facets_ready(db: &Connection) -> Result<bool> {
    let table: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='search_features')",
        [],
        |r| r.get(0),
    )?;
    if !table {
        return Ok(false);
    }
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM search_features WHERE key='facets_v1' AND value='1')",
        [],
        |r| r.get(0),
    )?)
}

/// Add the library-scope facet summary. `doc_tags` carries its parent's identity so the tag
/// triggers still work when the parent document is removed by the foreign-key cascade.
fn ensure_facets(db: &Connection) -> Result<()> {
    if facets_ready(db)? {
        return Ok(());
    }
    let tx = Transaction::new_unchecked(db, TransactionBehavior::Immediate)?;
    if facets_ready(&tx)? {
        tx.commit()?;
        return Ok(());
    }
    let mut columns = Vec::new();
    {
        let mut stmt = tx.prepare("PRAGMA table_info(doc_tags)")?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            columns.push(row.get::<_, String>(1)?);
        }
    }
    for (name, kind) in [
        ("gen", "INTEGER"),
        ("file_id", "TEXT"),
        ("capture_id", "TEXT"),
    ] {
        if !columns.iter().any(|column| column == name) {
            tx.execute_batch(&format!("ALTER TABLE doc_tags ADD COLUMN {name} {kind}"))?;
        }
    }
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS search_features(
             key TEXT PRIMARY KEY, value TEXT NOT NULL
         ) WITHOUT ROWID;
         CREATE TABLE IF NOT EXISTS facet_ref(
             gen INTEGER NOT NULL, facet TEXT NOT NULL, value TEXT NOT NULL,
             kind TEXT NOT NULL, id TEXT NOT NULL, n INTEGER NOT NULL, display TEXT,
             PRIMARY KEY(gen,facet,value,kind,id)
         ) WITHOUT ROWID;
         CREATE TABLE IF NOT EXISTS facet_count(
             gen INTEGER NOT NULL, facet TEXT NOT NULL, value TEXT NOT NULL,
             display TEXT, files INTEGER NOT NULL, captures INTEGER NOT NULL,
             PRIMARY KEY(gen,facet,value)
         ) WITHOUT ROWID;",
    )?;
    tx.execute(
        "UPDATE doc_tags SET
             gen=coalesce(gen,(SELECT gen FROM documents WHERE doc=doc_tags.doc)),
             file_id=coalesce(file_id,(SELECT file_id FROM documents WHERE doc=doc_tags.doc)),
             capture_id=coalesce(capture_id,(SELECT capture_id FROM documents WHERE doc=doc_tags.doc))
         WHERE gen IS NULL OR file_id IS NULL OR capture_id IS NULL",
        [],
    )?;
    // Drop the count triggers before the set-based backfill. A cache that lost only the
    // feature marker can still have live triggers; leaving them on would count every backfilled
    // reference and then insert the grouped counts a second time.
    tx.execute_batch(
        "DROP TRIGGER IF EXISTS facet_ref_add;
         DROP TRIGGER IF EXISTS facet_ref_remove;
         DROP TRIGGER IF EXISTS facet_document_add;
         DROP TRIGGER IF EXISTS facet_document_remove;
         DROP TRIGGER IF EXISTS facet_tag_add;
         DROP TRIGGER IF EXISTS facet_tag_remove;
         DELETE FROM facet_ref;
         DELETE FROM facet_count;",
    )?;
    for sql in [
        "INSERT INTO facet_ref(gen,facet,value,kind,id,n,display)
         SELECT gen,'rating',CAST(rating AS TEXT),'file',file_id,count(*),CAST(rating AS TEXT)
         FROM documents GROUP BY gen,rating,file_id",
        "INSERT INTO facet_ref(gen,facet,value,kind,id,n,display)
         SELECT gen,'rating',CAST(rating AS TEXT),'capture',capture_id,count(*),CAST(rating AS TEXT)
         FROM documents GROUP BY gen,rating,capture_id",
        "INSERT INTO facet_ref(gen,facet,value,kind,id,n,display)
         SELECT gen,'camera',coalesce(camera_key,''),'file',file_id,count(*),min(camera)
         FROM documents GROUP BY gen,camera_key,file_id",
        "INSERT INTO facet_ref(gen,facet,value,kind,id,n,display)
         SELECT gen,'camera',coalesce(camera_key,''),'capture',capture_id,count(*),min(camera)
         FROM documents GROUP BY gen,camera_key,capture_id",
        "INSERT INTO facet_ref(gen,facet,value,kind,id,n,display)
         SELECT gen,'tag',key,'file',file_id,count(*),min(display)
         FROM doc_tags WHERE gen IS NOT NULL AND file_id IS NOT NULL AND capture_id IS NOT NULL
         GROUP BY gen,key,file_id",
        "INSERT INTO facet_ref(gen,facet,value,kind,id,n,display)
         SELECT gen,'tag',key,'capture',capture_id,count(*),min(display)
         FROM doc_tags WHERE gen IS NOT NULL AND file_id IS NOT NULL AND capture_id IS NOT NULL
         GROUP BY gen,key,capture_id",
        "INSERT INTO facet_count(gen,facet,value,display,files,captures)
         SELECT gen,facet,value,min(display),sum(kind='file'),sum(kind='capture')
         FROM facet_ref GROUP BY gen,facet,value",
    ] {
        tx.execute(sql, [])?;
    }
    tx.execute_batch(
        "CREATE TRIGGER IF NOT EXISTS facet_ref_add AFTER INSERT ON facet_ref BEGIN
             INSERT INTO facet_count VALUES(new.gen,new.facet,new.value,new.display,
                 new.kind='file',new.kind='capture')
             ON CONFLICT(gen,facet,value) DO UPDATE SET
                 files=files+excluded.files, captures=captures+excluded.captures,
                 display=min(coalesce(display,excluded.display),
                             coalesce(excluded.display,display));
         END;
         CREATE TRIGGER IF NOT EXISTS facet_ref_remove AFTER DELETE ON facet_ref BEGIN
             UPDATE facet_count SET
                 files=files-(old.kind='file'), captures=captures-(old.kind='capture')
             WHERE gen=old.gen AND facet=old.facet AND value=old.value;
             DELETE FROM facet_count
             WHERE gen=old.gen AND facet=old.facet AND value=old.value
               AND files=0 AND captures=0;
         END;
         CREATE TRIGGER IF NOT EXISTS facet_document_add AFTER INSERT ON documents BEGIN
             INSERT INTO facet_ref VALUES(new.gen,'rating',CAST(new.rating AS TEXT),
                 'file',new.file_id,1,CAST(new.rating AS TEXT))
             ON CONFLICT DO UPDATE SET n=n+1;
             INSERT INTO facet_ref VALUES(new.gen,'rating',CAST(new.rating AS TEXT),
                 'capture',new.capture_id,1,CAST(new.rating AS TEXT))
             ON CONFLICT DO UPDATE SET n=n+1;
             INSERT INTO facet_ref VALUES(new.gen,'camera',coalesce(new.camera_key,''),
                 'file',new.file_id,1,new.camera)
             ON CONFLICT DO UPDATE SET n=n+1;
             INSERT INTO facet_ref VALUES(new.gen,'camera',coalesce(new.camera_key,''),
                 'capture',new.capture_id,1,new.camera)
             ON CONFLICT DO UPDATE SET n=n+1;
         END;
         CREATE TRIGGER IF NOT EXISTS facet_document_remove AFTER DELETE ON documents BEGIN
             UPDATE facet_ref SET n=n-1 WHERE gen=old.gen
               AND ((facet='rating' AND value=CAST(old.rating AS TEXT))
                 OR (facet='camera' AND value=coalesce(old.camera_key,'')))
               AND ((kind='file' AND id=old.file_id)
                 OR (kind='capture' AND id=old.capture_id));
             DELETE FROM facet_ref WHERE gen=old.gen AND n=0
               AND ((facet='rating' AND value=CAST(old.rating AS TEXT))
                 OR (facet='camera' AND value=coalesce(old.camera_key,'')))
               AND ((kind='file' AND id=old.file_id)
                 OR (kind='capture' AND id=old.capture_id));
         END;
         CREATE TRIGGER IF NOT EXISTS facet_tag_add AFTER INSERT ON doc_tags
         WHEN new.gen IS NOT NULL AND new.file_id IS NOT NULL AND new.capture_id IS NOT NULL
         BEGIN
             INSERT INTO facet_ref VALUES(new.gen,'tag',new.key,'file',new.file_id,1,new.display)
             ON CONFLICT DO UPDATE SET n=n+1;
             INSERT INTO facet_ref VALUES(new.gen,'tag',new.key,'capture',new.capture_id,1,new.display)
             ON CONFLICT DO UPDATE SET n=n+1;
         END;
         CREATE TRIGGER IF NOT EXISTS facet_tag_remove AFTER DELETE ON doc_tags
         WHEN old.gen IS NOT NULL AND old.file_id IS NOT NULL AND old.capture_id IS NOT NULL
         BEGIN
             UPDATE facet_ref SET n=n-1 WHERE gen=old.gen AND facet='tag' AND value=old.key
               AND ((kind='file' AND id=old.file_id)
                 OR (kind='capture' AND id=old.capture_id));
             DELETE FROM facet_ref WHERE gen=old.gen AND n=0
               AND facet='tag' AND value=old.key
               AND ((kind='file' AND id=old.file_id)
                 OR (kind='capture' AND id=old.capture_id));
         END;",
    )?;
    tx.execute(
        "INSERT OR REPLACE INTO search_features VALUES('facets_v1','1')",
        [],
    )?;
    tx.commit()?;
    Ok(())
}

pub(super) fn initialize(db: &Connection) -> Result<()> {
    let application = id(db)?;
    if application != APPLICATION && application != 0 {
        return Err("not a RAWMaster search index".into());
    }
    if application == 0 {
        let tx = Transaction::new_unchecked(db, TransactionBehavior::Immediate)?;
        if id(&tx)? == 0 {
            let occupied: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%')",
                [],
                |r| r.get(0),
            )?;
            if occupied {
                return Err("search index path already contains another database".into());
            }
            tx.execute_batch(include_str!("schema.sql"))?;
            for (sort, head) in [
                ("original", ""),
                ("filename", "filename COLLATE rm_natural,"),
                ("ascending", "missing_time,time_asc,"),
                ("descending", "missing_time,time_desc,"),
                ("stars", "rating_desc,"),
            ] {
                for (scope, prefix) in [("library", "gen,"), ("project", "gen,project_id,")] {
                    tx.execute_batch(&format!(
                        "CREATE INDEX {scope}_{sort} ON documents({prefix}{head}{BASE})"
                    ))?;
                }
            }
            tx.execute_batch(
                "CREATE INDEX store_order ON documents(gen,asset_ord,asset_id,project_id,file_id)",
            )?;
            match tx.execute_batch("CREATE VIRTUAL TABLE search_fts USING fts5(name,body,tokenize='trigram')") {
                Ok(()) => tx.execute_batch("
                    CREATE TRIGGER fts_add AFTER INSERT ON documents BEGIN
                        INSERT INTO search_fts(rowid,name,body) VALUES(new.doc,new.name_key,new.body); END;
                    CREATE TRIGGER fts_remove AFTER DELETE ON documents BEGIN
                        DELETE FROM search_fts WHERE rowid=old.doc; END;")?,
                Err(e) if e.to_string().contains("no such module: fts5") || e.to_string().contains("tokenizer") => (),
                Err(e) => return Err(e.into()),
            }
            tx.execute_batch(
                "CREATE TABLE provider(id INTEGER PRIMARY KEY CHECK(id=1), name TEXT NOT NULL)",
            )?;
            tx.execute(
                "INSERT INTO provider VALUES(1,?)",
                [text::COLLATION_VERSION],
            )?;
            tx.pragma_update(None, "application_id", APPLICATION)?;
            tx.pragma_update(None, "user_version", FORMAT)?;
        }
        tx.commit()?;
    }
    if id(db)? != APPLICATION {
        return Err("unexpected search index application ID".into());
    }
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version != FORMAT {
        return Err("unsupported search index format; rebuild the search cache".into());
    }
    let provider: String =
        db.query_row("SELECT name FROM provider WHERE id=1", [], |r| r.get(0))?;
    if provider != text::COLLATION_VERSION {
        // Reusing order indexes created with a different comparator makes even
        // key deletion unsafe. Reindex the disposable B-trees before touching them.
        let tx = Transaction::new_unchecked(db, TransactionBehavior::Immediate)?;
        tx.execute_batch(
            "REINDEX rm_natural; UPDATE generations SET state='obsolete' WHERE state!='obsolete'",
        )?;
        tx.execute(
            "UPDATE provider SET name=? WHERE id=1",
            [text::COLLATION_VERSION],
        )?;
        tx.commit()?;
    }
    ensure_cjk(db)?;
    ensure_facet_cache(db)?;
    ensure_facets(db)?;
    let journal: String = db.query_row("PRAGMA journal_mode", [], |r| r.get(0))?;
    if !journal.eq_ignore_ascii_case("wal") {
        let result: String = db.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))?;
        if !result.eq_ignore_ascii_case("wal") {
            return Err("search cache requires WAL support".into());
        }
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct State {
    pub gen: i64,
    pub token: String,
    pub library: String,
    stamp: String,
    pub watermark: i64,
}
pub(super) fn published(db: &Connection) -> rusqlite::Result<Option<State>> {
    db.query_row(
        "SELECT gen,token,library,source_stamp,watermark FROM generations WHERE state='active'",
        [],
        |r| {
            Ok(State {
                gen: r.get(0)?,
                token: r.get(1)?,
                library: r.get(2)?,
                stamp: r.get(3)?,
                watermark: r.get(4)?,
            })
        },
    )
    .optional()
}
struct Head {
    library: String,
    watermark: i64,
    oldest: i64,
}
fn head(db: &Connection) -> Result<Head> {
    Ok(db.query_row(
        "SELECT (SELECT value FROM lc_meta WHERE key='libraryID'),
        coalesce((SELECT seq FROM lc_changes ORDER BY seq DESC LIMIT 1),0),
        coalesce((SELECT seq FROM lc_changes ORDER BY seq LIMIT 1),0)",
        [],
        |r| {
            Ok(Head {
                library: r.get(0)?,
                watermark: r.get(1)?,
                oldest: r.get(2)?,
            })
        },
    )?)
}
pub(super) fn validate_source(db: &Connection) -> Result<()> {
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if !crate::readable_schema(version) {
        return Err(format!("library query requires catalog v8 or v9; opened v{version}").into());
    }
    let library: String =
        db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
            r.get(0)
        })?;
    if library.is_empty() {
        return Err("catalog is missing its library identity".into());
    }
    Ok(())
}
pub(super) fn stamp(path: &Path) -> Result<String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let file = path.metadata()?;
        Ok(format!("{}:{}", file.dev(), file.ino()))
    }
    #[cfg(not(unix))]
    {
        Ok(path.canonicalize()?.to_string_lossy().into_owned())
    }
}
fn valid(s: &State, h: &Head, stamp: &str) -> bool {
    s.library == h.library
        && s.stamp == stamp
        && s.watermark <= h.watermark
        && (h.oldest == 0 || s.watermark >= h.oldest - 1)
}
enum Changes {
    Rows(Vec<String>, i64),
    Global,
}
fn changes(source: &Connection, since: i64, tip: i64) -> Result<Changes> {
    let mut stmt = source.prepare(
        "SELECT seq,asset_id,domain FROM lc_changes WHERE seq>? AND seq<=? ORDER BY seq LIMIT ?",
    )?;
    let mut rows = stmt.query(params![since, tip, CHUNK])?;
    let mut touched = BTreeSet::new();
    let mut end = since;
    while let Some(row) = rows.next()? {
        end = row.get(0)?;
        // Organization and inspector-backed predicates use their own authoritative
        // read snapshot. Their sequence still invalidates a cursor, but metadata
        // for thousands of offline works cannot invalidate the v7 file projection.
        let domain: String = row.get(2)?;
        if domain == "project_review_states" {
            continue;
        }
        match row.get::<_, Option<String>>(1)? {
            Some(asset) => {
                touched.insert(asset);
            }
            None if matches!(domain.as_str(), "organization" | "inspection") => (),
            None => return Ok(Changes::Global),
        }
    }
    if end == since && since < tip {
        return Ok(Changes::Global);
    }
    Ok(Changes::Rows(touched.into_iter().collect(), end))
}
fn start(tx: &Connection, head: &Head, stamp: &str) -> Result<i64> {
    tx.execute(
        "UPDATE generations SET state='obsolete' WHERE state='building'",
        [],
    )?;
    tx.execute(
        "INSERT INTO generations(library,source_stamp,state,watermark) VALUES(?,?,'building',?)",
        params![head.library, stamp, head.watermark],
    )?;
    Ok(tx.last_insert_rowid())
}

pub(super) fn synchronize(
    source: &mut Connection,
    cache: &mut Connection,
    stamp: &str,
) -> Result<State> {
    synchronize_inner(source, cache, stamp, false)
}
pub(super) fn force(source: &mut Connection, cache: &mut Connection, stamp: &str) -> Result<State> {
    let tx = cache.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let read = source.transaction()?;
    let h = head(&read)?;
    let building:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM generations WHERE state='building' AND library=?1 AND source_stamp=?2)",
        params![h.library,stamp],|r|r.get(0))?;
    if !building {
        start(&tx, &h, stamp)?;
    }
    drop(read);
    tx.commit()?;
    synchronize_inner(source, cache, stamp, true)
}
fn synchronize_inner(
    source: &mut Connection,
    cache: &mut Connection,
    stamp: &str,
    wait_for_build: bool,
) -> Result<State> {
    loop {
        // The overwhelmingly common read path only looks at two indexed ends of
        // the journal and one state row. Never take the index writer lock here.
        let read = source.transaction()?;
        let current = head(&read)?;
        if let Some(active) = published(cache)? {
            if valid(&active, &current, stamp)
                && active.watermark == current.watermark
                && (!wait_for_build
                    || !cache.query_row(
                        "SELECT EXISTS(SELECT 1 FROM generations WHERE state='building')",
                        [],
                        |r| r.get::<_, bool>(0),
                    )?)
            {
                return Ok(active);
            }
        }
        drop(read);

        // Synchronizers serialize on the derived file, never on the catalog.
        // Start a NEW catalog read snapshot after acquiring the writer lock.
        let tx = cache.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let read = source.transaction()?;
        let h = head(&read)?;
        let active = published(&tx)?;
        let build = tx.query_row("SELECT gen,library,source_stamp,watermark,after_row,scanned FROM generations WHERE state='building'",
            [], |r| Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,
                         r.get::<_,i64>(3)?,r.get::<_,Option<i64>>(4)?,r.get::<_,bool>(5)?))).optional()?;
        if let Some((gen, library, source_stamp, watermark, after, scanned)) = build {
            if library != h.library
                || source_stamp != stamp
                || watermark > h.watermark
                || (h.oldest > 0 && watermark < h.oldest - 1)
            {
                start(&tx, &h, stamp)?;
            } else if !scanned {
                let mut sql = String::from("SELECT rowid,id FROM assets");
                if after.is_some() {
                    sql.push_str(" WHERE rowid>?1");
                }
                sql.push_str(" ORDER BY rowid LIMIT 256");
                let mut stmt = read.prepare(&sql)?;
                let mut rows = stmt.query(rusqlite::params_from_iter(after))?;
                let mut ids = Vec::new();
                let mut last = after;
                while let Some(row) = rows.next()? {
                    last = Some(row.get(0)?);
                    ids.push(row.get(1)?);
                }
                project(&read, &tx, gen, &ids)?;
                tx.execute(
                    "UPDATE generations SET after_row=?,scanned=? WHERE gen=?",
                    params![last, ids.len() < CHUNK as usize, gen],
                )?;
            } else if watermark == h.watermark {
                tx.execute(
                    "UPDATE generations SET state='obsolete' WHERE state='active'",
                    [],
                )?;
                tx.execute("UPDATE generations SET state='active' WHERE gen=?", [gen])?;
            } else {
                match changes(&read, watermark, h.watermark)? {
                    Changes::Rows(ids, end) => {
                        project(&read, &tx, gen, &ids)?;
                        tx.execute(
                            "UPDATE generations SET watermark=? WHERE gen=?",
                            params![end, gen],
                        )?;
                    }
                    Changes::Global => {
                        start(&tx, &h, stamp)?;
                    }
                }
            }
        } else if let Some(active) = active.filter(|s| valid(s, &h, stamp)) {
            if active.watermark == h.watermark {
                return Ok(active);
            }
            match changes(&read, active.watermark, h.watermark)? {
                Changes::Rows(ids, end) => {
                    project(&read, &tx, active.gen, &ids)?;
                    tx.execute(
                        "UPDATE generations SET watermark=? WHERE gen=?",
                        params![end, active.gen],
                    )?;
                }
                Changes::Global => {
                    start(&tx, &h, stamp)?;
                }
            }
        } else {
            start(&tx, &h, stamp)?;
        }
        drop(read);
        collect_chunk(&tx)?;
        tx.commit()?;
    }
}

pub(super) fn collect_obsolete(db: &mut Connection) -> Result<()> {
    loop {
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if !collect_chunk(&tx)? {
            return Ok(());
        }
        tx.commit()?;
    }
}

// Keep discarded builds bounded even if the application only calls page().
// WAL readers retain their previous published snapshot across these deletes.
fn collect_chunk(tx: &Connection) -> Result<bool> {
    let gen: Option<i64> = tx
        .query_row(
            "SELECT gen FROM generations WHERE state='obsolete' LIMIT 1",
            [],
            |r| r.get(0),
        )
        .optional()?;
    let Some(gen) = gen else {
        return Ok(false);
    };
    let n = tx.execute(
        "DELETE FROM documents WHERE doc IN (SELECT doc FROM documents WHERE gen=? LIMIT ?)",
        params![gen, CHUNK],
    )?;
    if n == 0 {
        tx.execute("DELETE FROM scope_counts WHERE gen=?", [gen])?;
        tx.execute("DELETE FROM generations WHERE gen=?", [gen])?;
    }
    Ok(true)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Asset {
    filename: String,
    relative_path: String,
    captured_at: Option<f64>,
    camera: Option<String>,
    rating: i64,
    decision: String,
    availability: String,
}
struct Member {
    group_id: String,
    position: i64,
    included: bool,
}
fn project(source: &Connection, index: &Connection, gen: i64, assets: &[String]) -> Result<()> {
    if assets.is_empty() {
        return Ok(());
    }
    let ids = serde_json::to_string(assets)?;
    // A scope can pick a *different* legacy representative for the same file on
    // deletion, or acquire a smaller representative from another occurrence.
    // Replace both the previous and current logical file, across its projects.
    let mut files = BTreeSet::<String>::new();
    let mut old=index.prepare_cached("SELECT DISTINCT file_id FROM documents WHERE gen=? AND asset_id IN (SELECT value FROM json_each(?))")?;
    files.extend(
        old.query_map(params![gen, ids], |r| r.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?,
    );
    let mut current = source.prepare_cached(
        "SELECT file_id FROM lc_asset_files WHERE asset_id IN (SELECT value FROM json_each(?1))
        UNION SELECT file_id FROM lc_scopes WHERE asset_id IN (SELECT value FROM json_each(?1))",
    )?;
    files.extend(
        current
            .query_map([&ids], |r| r.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?,
    );
    if files.is_empty() {
        return Ok(());
    }
    let files = serde_json::to_string(&files)?;
    index.execute(
        "DELETE FROM documents WHERE gen=? AND file_id IN (SELECT value FROM json_each(?))",
        params![gen, files],
    )?;
    let mut member_stmt = source.prepare(include_str!("members.sql"))?;
    let mut rows = member_stmt.query([&files])?;
    let mut members: BTreeMap<(String, String), Vec<Member>> = BTreeMap::new();
    while let Some(r) = rows.next()? {
        members
            .entry((r.get(0)?, r.get(1)?))
            .or_default()
            .push(Member {
                group_id: r.get(2)?,
                position: r.get(3)?,
                included: r.get(4)?,
            });
    }
    // Only authoritative catalog occurrences can enter the index. Looking up the
    // v7 sessions/assets supplies display metadata without opening original files.
    let mut stmt=source.prepare("SELECT f.asset_id,f.file_id,f.capture_id,f.project_id,a.session_id,a.rowid,s.rowid,a.data,
        t.data, json_extract(c.data,'$.label'),coalesce(json_extract(r.data,'$.reviewed'),0),
        (SELECT min(sc.kind='sequenceOnly') FROM lc_scopes sc WHERE sc.file_id=f.file_id AND sc.project_id=f.project_id),
        json_extract(pr.data,'$.name'),file.role
        FROM lc_catalog_files f JOIN assets a ON a.id=f.asset_id JOIN lc_files file ON file.file_id=f.file_id LEFT JOIN sessions s ON s.id=a.session_id
        LEFT JOIN asset_tags t ON t.asset_id=a.id LEFT JOIN asset_color_labels c ON c.asset_id=a.id
        LEFT JOIN review_records r ON r.asset_id=a.id LEFT JOIN projects pr ON pr.id=f.project_id
        WHERE f.file_id IN (SELECT value FROM json_each(?))")?;
    let mut rows = stmt.query([files])?;
    let mut insert=index.prepare_cached("INSERT INTO documents(gen,asset_id,file_id,capture_id,project_id,session_id,
        session_ord,asset_ord,filename,name_key,relative_path,path_tie,camera,camera_key,captured,missing_time,time_asc,time_desc,
        rating,rating_desc,decision,availability,color_label,reviewed,format,sequence_only,body,record,role)
        VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29)")?;
    let mut insert_tag = index.prepare_cached(
        "INSERT OR IGNORE INTO doc_tags(doc,key,display,gen,file_id,capture_id)
         VALUES(?,?,?,?,?,?)",
    )?;
    let mut insert_member =
        index.prepare_cached("INSERT INTO doc_groups(doc,group_id,position) VALUES(?,?,?)")?;
    let with_inspection: bool = source.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='lc_inspect_work_effective') AND
        EXISTS(SELECT 1 FROM sqlite_schema WHERE name='lc_org_works')",
        [],
        |r| r.get(0),
    )?;
    let mut overlays = if with_inspection {
        Some(source.prepare_cached("SELECT w.metadata_json,w.rating,
        (SELECT json_group_object(field,json(value_json)) FROM lc_inspect_work_effective i WHERE i.work_id=w.work_id),
        (SELECT json_group_object(field,json(value_json)) FROM lc_inspect_file_effective i WHERE i.file_id=w.file_id AND i.content_id=coalesce(
            (SELECT s.content_id FROM lc_scopes s JOIN lc_asset_input ai ON ai.asset_id=s.asset_id AND ai.content_id=s.content_id WHERE s.file_id=?1 AND s.asset_id=?2 AND s.project_id=?3 ORDER BY s.rowid DESC LIMIT 1),
            (SELECT s.content_id FROM lc_scopes s WHERE s.file_id=?1 AND s.asset_id=?2 AND s.project_id=?3 ORDER BY s.rowid DESC LIMIT 1)))
        FROM lc_org_works w WHERE w.work_id='file:'||?1")?)
    } else {
        None
    };
    while let Some(row) = rows.next()? {
        let aid: String = row.get(0)?;
        let project: String = row.get(3)?;
        let mut record: Value = serde_json::from_str(&row.get::<_, String>(7)?)?;
        let mut tags: Vec<String> = row
            .get::<_, Option<String>>(8)?
            .map(|s| serde_json::from_str(&s))
            .transpose()?
            .unwrap_or_default();
        let file: String = row.get(1)?;
        let mut label = row.get::<_, Option<String>>(9)?;
        if let Some(overlays) = overlays.as_mut() {
            if let Some((org, rating, work, embedded)) = overlays
                .query_row(params![file, aid, project], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, Option<i64>>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                    ))
                })
                .optional()?
            {
                let origin: Value = serde_json::from_str(&org)?;
                let embedded: Value = serde_json::from_str(&embedded)?;
                let work: Value = serde_json::from_str(&work)?;
                for k in [
                    "rating",
                    "camera",
                    "capturedAt",
                    "title",
                    "caption",
                    "creator",
                    "copyright",
                    "place",
                    "lens",
                    "colorLabel",
                    "keywords",
                ] {
                    let mut val = work
                        .get(k)
                        .or_else(|| embedded.get(k))
                        .or_else(|| origin.get(k))
                        .cloned();
                    if matches!(k, "camera" | "capturedAt" | "lens") {
                        if let Some(v) = embedded.get(k).filter(|v| !v.is_null()) {
                            val = Some(v.clone());
                        }
                    }
                    if k == "rating" && work.get(k).is_none() && rating.is_some() {
                        val = Some(json!(rating));
                    }
                    if let Some(v) = val {
                        match k {
                            "rating" => record[k] = json!(v.as_i64().unwrap_or(0)),
                            "colorLabel" => {
                                label = v.as_str().filter(|s| *s != "none").map(str::to_owned)
                            }
                            "keywords" => tags = super::works::tag_list(&v),
                            _ => record[k] = v,
                        }
                    }
                }
            }
        }
        let asset: Asset = serde_json::from_value(record.clone())?;
        let joined = members
            .get(&(file.clone(), project.clone()))
            .map(Vec::as_slice)
            .unwrap_or_default();
        record["projectID"] = json!(project);
        if let Some(name) = row.get::<_, Option<String>>(12)? {
            record["projectName"] = json!(name);
        }
        record["groupID"] = json!(joined.first().map(|m| &m.group_id));
        record["sequenceIndex"] = json!(joined.first().map(|m| m.position));
        record["isSequenceMember"] = json!(joined.iter().any(|m| m.included));
        let camera = asset
            .camera
            .as_deref()
            .map(|v| v.trim_matches(|c: char| c.is_whitespace() || c.is_control()));
        let name_key = text::searchable(&asset.filename);
        let mut fields = vec![name_key.clone()];
        for tag in &tags {
            fields.push(text::searchable(tag));
        }
        for key in [
            "title",
            "description",
            "caption",
            "creator",
            "copyright",
            "place",
            "lens",
            "camera",
        ] {
            if let Some(value) = record.get(key).and_then(Value::as_str) {
                fields.push(text::searchable(value));
            }
        }
        let format = Path::new(&asset.filename)
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let captured = asset.captured_at;
        let t = captured.unwrap_or(0.);
        let capture: String = row.get(2)?;
        insert.execute(params![
            gen,
            aid,
            file,
            capture,
            project,
            row.get::<_, String>(4)?,
            row.get::<_, Option<i64>>(6)?.unwrap_or(i64::MAX),
            row.get::<_, i64>(5)?,
            asset.filename,
            name_key,
            asset.relative_path,
            text::path_tiebreak(&asset.relative_path),
            camera,
            camera.map(text::searchable),
            captured,
            captured.is_none(),
            t,
            -t,
            asset.rating,
            -asset.rating,
            asset.decision,
            asset.availability,
            label,
            row.get::<_, bool>(10)?,
            format,
            row.get::<_, bool>(11)?,
            fields.join("\u{1f}"),
            serde_json::to_string(&record)?,
            row.get::<_, String>(13)?
        ])?;
        let doc = index.last_insert_rowid();
        for tag in &tags {
            insert_tag.execute(params![doc, text::tag_key(tag), tag, gen, file, capture])?;
        }
        for member in joined {
            insert_member.execute(params![doc, member.group_id, member.position])?;
        }
    }
    Ok(())
}
