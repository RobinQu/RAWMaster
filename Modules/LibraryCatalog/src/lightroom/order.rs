use super::*;
pub(super) fn rule(sql: &Connection, collection: i64) -> Result<Option<(String, Option<Value>)>> {
    if !source::exists(sql, "AgLibraryCollectionContent")? {
        return Ok(None);
    }
    let raw:Option<String>=sql.query_row("SELECT CAST(content AS TEXT) FROM AgLibraryCollectionContent WHERE collection=?1 AND owningModule='ag.library.smart_collection' ORDER BY id_local LIMIT 1",[collection],|r|r.get(0)).optional()?;
    Ok(raw.map(|s| {
        let predicate = rating_rule(&s);
        (s, predicate)
    }))
}
// Match the complete structure represented by our one equivalent rule. Reject extra clauses,
// units, nested booleans and unrecognized Adobe syntax instead of silently weakening the filter.
fn rating_rule(s: &str) -> Option<Value> {
    let tight = s.chars().filter(|c| !c.is_whitespace()).collect::<String>();
    for operation in [
        ("==", "eq"),
        (">=", "gte"),
        ("<=", "lte"),
        (">", "gt"),
        ("<", "lt"),
    ] {
        for r in 0..=5 {
            for combine in ["intersect", "union"] {
                let expected=format!("s={{{{criteria=\"rating\",operation=\"{}\",value={r},}},combine=\"{combine}\",}}",operation.0);
                if tight == expected
                    || tight
                        == expected
                            .trim_end_matches('}')
                            .trim_end_matches(',')
                            .to_owned()
                            + "}"
                {
                    return Some(json!({"field":"rating","op":operation.1,"value":r}));
                }
            }
        }
    }
    None
}
pub(super) fn manifest(
    catalog: &Path,
    source_db: &source::Snapshot,
    preview: Option<&Connection>,
    cache: &Path,
) -> Result<Resource> {
    let t = tempfile::tempdir()?;
    let p = t.path().join("order.sqlite");
    let mut out = Connection::open(&p)?;
    out.execute_batch("PRAGMA trusted_schema=OFF; CREATE TABLE members(seq INTEGER PRIMARY KEY,collection INTEGER NOT NULL, image INTEGER, position INTEGER NOT NULL,total INTEGER NOT NULL,basis TEXT NOT NULL,source_member INTEGER);")?;
    out.execute(
        "ATTACH ?1 AS src",
        [source_db.path.to_str().ok_or("Non-UTF8 source snapshot")?],
    )?;
    let tx = out.transaction()?;
    let db = &source_db.db;
    tx.execute_batch("CREATE TABLE identity(kind TEXT NOT NULL,local_id INTEGER NOT NULL,guid TEXT NOT NULL,PRIMARY KEY(kind,local_id)) WITHOUT ROWID;")?;
    for (kind, table) in [
        ("image", "Adobe_images"),
        ("file", "AgLibraryFile"),
        ("volume", "AgLibraryRootFolder"),
        ("folder", "AgLibraryFolder"),
        ("keyword", "AgLibraryKeyword"),
        ("AgLibraryFolderStack", "AgLibraryFolderStack"),
        ("AgLibraryCollectionStack", "AgLibraryCollectionStack"),
    ] {
        if source::columns(db, table)?.iter().any(|c| c == "id_global") {
            tx.execute(&format!("INSERT INTO identity SELECT ?1,id_local,CAST(id_global AS TEXT) FROM src.{table} WHERE typeof(id_global)='text' AND length(id_global)>0"),[kind])?;
        }
    }
    if source::exists(db, "AgLibraryCollection")? {
        let has_members = source::exists(db, "AgLibraryCollectionImage")?;
        let mut q =
            db.prepare("SELECT id_local,creationId FROM AgLibraryCollection ORDER BY id_local")?;
        for v in q.query_map([], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?))
        })? {
            let (id, kind) = v?;
            let kind = kind.as_deref().unwrap_or("");
            if !matches!(
                kind,
                "com.adobe.ag.library.collection" | "com.adobe.ag.library.smart_collection"
            ) {
                continue;
            }
            let count: i64 = if has_members {
                db.query_row(
                    "SELECT COUNT(*) FROM AgLibraryCollectionImage WHERE collection=?1",
                    [id],
                    |r| r.get(0),
                )?
            } else {
                0
            };
            if count > 0 {
                tx.execute("INSERT INTO members(collection,image,position,total,basis,source_member) SELECT collection,image,row_number() OVER(ORDER BY positionInCollection COLLATE BINARY,id_local)-1,?2,'sourceMembers',id_local FROM src.AgLibraryCollectionImage WHERE collection=?1 ORDER BY positionInCollection COLLATE BINARY,id_local",params![id,count])?;
            } else if kind.ends_with("smart_collection") {
                let predicate = rule(db, id)?.and_then(|(_, p)| p);
                if let Some(pred) = predicate {
                    let cmp = match pred["op"].as_str() {
                        Some("eq") => "=",
                        Some("gte") => ">=",
                        Some("lte") => "<=",
                        Some("gt") => ">",
                        Some("lt") => "<",
                        _ => return Err("Unknown rating rule".into()),
                    };
                    let n=tx.execute(&format!("INSERT INTO members(collection,image,position,total,basis) SELECT ?1,id_local,row_number() OVER(ORDER BY id_local)-1,count(*) OVER(),'equivalentRule' FROM src.Adobe_images WHERE coalesce(rating,0) {cmp} ?2 ORDER BY id_local"),params![id,pred["value"].as_i64()])?;
                    if n == 0 {
                        tx.execute("INSERT INTO members(collection,position,total,basis) VALUES(?1,0,0,'equivalentRule')",[id])?;
                    }
                } else {
                    tx.execute("INSERT INTO members(collection,position,total,basis) VALUES(?1,0,0,'unavailableSmartMembers')",[id])?;
                }
            } else {
                tx.execute(
                    "INSERT INTO members(collection,position,total,basis) VALUES(?1,0,0,?2)",
                    params![
                        id,
                        if has_members {
                            "sourceMembers"
                        } else {
                            "missingMembershipTable"
                        }
                    ],
                )?;
            }
        }
    }
    preview::inventory(&tx, preview, cache)?;
    tx.execute_batch("CREATE INDEX member_collection ON members(collection,image)")?;
    tx.commit()?;
    out.execute_batch("DETACH src;")?;
    drop(out);
    source::content(catalog, &p, "adobePayload")
}
