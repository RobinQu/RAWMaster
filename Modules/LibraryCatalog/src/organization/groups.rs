use super::*;
use rusqlite::params;
use sha2::{Digest, Sha256};

pub(super) const COLLECTION:&str="SELECT json_object('collectionID',collection_id,'kind',kind,'parentID',parent_id,'name',name,
 'position',position,'rule',json(rule_json),'revision',revision) FROM lc_org_collections WHERE collection_id=?";
pub(super) const STACK:&str="SELECT json_object('stackID',stack_id,'scopeKind',scope_kind,'scopeID',scope_id,'coverWorkID',cover_work_id,
 'collapsed',json(CASE WHEN collapsed THEN 'true' ELSE 'false' END),'revision',revision) FROM lc_org_stacks WHERE stack_id=?";

pub(super) fn collection(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "collectionID")?;
    let old = stored(db, COLLECTION, id)?;
    let rev = revision(old.as_ref(), r)?;
    let v = amended(
        old.as_ref().unwrap_or(&json!({})),
        r,
        &["kind", "parentID", "name", "position", "rule"],
    );
    let kind = string(&v, "kind")?;
    if !matches!(kind, "regular" | "smart" | "group")
        || old.as_ref().is_some_and(|o| o["kind"] != kind)
    {
        return Err("invalid or incompatible collection kind".into());
    }
    let rule = if kind == "smart" {
        crate::query::works::validate_rule(&v["rule"])?;
        Some(v["rule"].to_string())
    } else if v["rule"].is_null() {
        None
    } else {
        return Err("only smart collections store rules".into());
    };
    if let Some(parent) = optional(&v, "parentID")? {
        let ok:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_org_collections WHERE collection_id=?1 AND kind='group')
            AND NOT EXISTS(WITH RECURSIVE down(id) AS (SELECT ?2 UNION ALL SELECT c.collection_id FROM lc_org_collections c JOIN down ON c.parent_id=down.id)
            SELECT 1 FROM down WHERE id=?1)",params![parent,id],|r|r.get(0))?;
        if !ok {
            return Err("collection parent is missing, not a group, or would form a cycle".into());
        }
    }
    db.execute("INSERT INTO lc_org_collections VALUES(?,?,?,?,?,?,?) ON CONFLICT(collection_id) DO UPDATE SET
        parent_id=excluded.parent_id,name=excluded.name,rule_json=excluded.rule_json,position=excluded.position,revision=excluded.revision",
        params![id,optional(&v,"parentID")?,kind,string(&v,"name")?,rule,position(&v)?,rev])?;
    Ok(json!({"collectionID":id,"revision":rev}))
}
fn visible(db: &Connection, ids: &[String]) -> Result<()> {
    let missing:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM json_each(?) i WHERE NOT EXISTS(SELECT 1 FROM lc_org_visible_sources v WHERE v.work_id=i.value))",
        [serde_json::to_string(ids)?],|r|r.get(0))?;
    if missing {
        return Err("an organization member is unavailable or outside the library".into());
    }
    Ok(())
}
pub(super) fn set_members(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "collectionID")?;
    let old = stored(db, COLLECTION, id)?.ok_or("unknown collection")?;
    if old["kind"] != "regular" {
        return Err("manual membership requires a regular collection".into());
    }
    let rev = revision(Some(&old), r)?;
    let ids = list(r, "workIDs")?;
    visible(db, &ids)?;
    db.execute(
        "DELETE FROM lc_org_collection_members WHERE collection_id=?",
        [id],
    )?;
    db.execute("INSERT INTO lc_org_collection_members SELECT ?1,value,CAST(key AS INTEGER) FROM json_each(?2)",params![id,serde_json::to_string(&ids)?])?;
    db.execute(
        "UPDATE lc_org_collections SET revision=? WHERE collection_id=?",
        params![rev, id],
    )?;
    tidy_scope(db, "collection", Some(id))?;
    Ok(json!({"collectionID":id,"revision":rev,"count":ids.len()}))
}

pub(super) fn add_members(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "collectionID")?;
    let old = stored(db, COLLECTION, id)?.ok_or("unknown collection")?;
    if old["kind"] != "regular" {
        return Err("manual additions require a regular collection".into());
    }
    let rev = revision(Some(&old), r)?;
    let ids = list(r, "workIDs")?;
    visible(db, &ids)?;
    let added=db.execute("WITH new_ids AS (SELECT value AS work_id,CAST(key AS INTEGER) AS ord FROM json_each(?2) i
        WHERE NOT EXISTS(SELECT 1 FROM lc_org_collection_members m WHERE m.collection_id=?1 AND m.work_id=i.value))
        INSERT INTO lc_org_collection_members SELECT ?1,work_id,
          (SELECT coalesce(max(position),-1) FROM lc_org_collection_members WHERE collection_id=?1)+row_number() OVER(ORDER BY ord) FROM new_ids",
        params![id,serde_json::to_string(&ids)?])?;
    if added > 0 {
        db.execute(
            "UPDATE lc_org_collections SET revision=? WHERE collection_id=?",
            params![rev, id],
        )?;
    }
    Ok(json!({"collectionID":id,"revision":if added>0{rev}else{rev-1},"countAdded":added}))
}
pub(super) fn move_member(db: &Connection, r: &Value) -> Result<Value> {
    let kind = string(r, "scopeKind")?;
    let id = string(r, "scopeID")?;
    let work = string(r, "workID")?;
    let before = optional(r, "beforeWorkID")?;
    let sql=match kind{
        "collection"=>"SELECT work_id FROM lc_org_collection_members WHERE collection_id=? ORDER BY position",
        "folder"=>"SELECT v.work_id FROM lc_org_visible_sources v LEFT JOIN lc_org_folder_order o ON o.folder_id=v.source_folder_id AND o.work_id=v.work_id
            WHERE v.source_folder_id=? ORDER BY o.position IS NULL,o.position,v.work_id",
        _=>return Err("manual order requires a folder or regular collection".into()),
    };
    let mut stmt = db.prepare(sql)?;
    let mut ids = stmt
        .query_map([id], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let from = ids
        .iter()
        .position(|x| x == work)
        .ok_or("moving member is outside the scope")?;
    if before == Some(work) {
        return Err("choose a different anchor for the move".into());
    }
    let value = ids.remove(from);
    let to = before
        .map(|b| {
            ids.iter()
                .position(|v| v == b)
                .ok_or("order anchor left the scope")
        })
        .transpose()?
        .unwrap_or(ids.len());
    ids.insert(to, value);
    let mut request = json!({"workIDs":ids});
    if let Some(v) = r.get("baseRevision") {
        request["baseRevision"] = v.clone();
    }
    if kind == "collection" {
        request["collectionID"] = json!(id);
        set_members(db, &request)
    } else {
        request["folderID"] = json!(id);
        folder_order(db, &request)
    }
}
pub(super) fn stage_members(db: &Connection, r: &Value) -> Result<Value> {
    let batch = string(r, "importID")?;
    let id = string(r, "collectionID")?;
    let old = stored(db, COLLECTION, id)?.ok_or("unknown collection")?;
    if old["kind"] == "group" {
        return Err("collection groups cannot store a membership snapshot".into());
    }
    let base = r["baseRevision"]
        .as_i64()
        .filter(|v| *v >= 0)
        .ok_or("member import requires a base revision")?;
    let start = r["start"]
        .as_i64()
        .filter(|v| *v >= 0)
        .ok_or("invalid starting position")?;
    let ids = list(r, "workIDs")?;
    let count = i64::try_from(ids.len())?;
    start.checked_add(count).ok_or("import position overflow")?;
    let body = serde_json::to_string(&ids)?;
    let digest = format!("{:x}", Sha256::digest(body.as_bytes()));
    let finish = r["finish"].as_bool().unwrap_or(false);
    db.execute("INSERT OR IGNORE INTO lc_org_member_imports(import_id,collection_id,base_revision) VALUES(?,?,?)",params![batch,id,base])?;
    let (owner,version,published,expected):(String,i64,Option<i64>,Option<i64>)=db.query_row(
        "SELECT collection_id,base_revision,published_revision,expected_count FROM lc_org_member_imports WHERE import_id=?",[batch],
        |row|Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?)))?;
    if owner != id || base != version {
        return Err(
            "import identity already belongs to another collection or base revision".into(),
        );
    }
    let prev: Option<String> = db
        .query_row(
            "SELECT digest FROM lc_org_member_parts WHERE import_id=? AND start=?",
            params![batch, start],
            |r| r.get(0),
        )
        .optional()?;
    if !ids.is_empty() && prev.as_ref().is_some_and(|d| d != &digest) {
        return Err("member import chunk conflicts with its earlier payload".into());
    }
    if let Some(rev) = published {
        if (!ids.is_empty() && prev.is_none())
            || (finish && expected != r["expectedCount"].as_i64())
        {
            return Err("member import already finished with different coverage".into());
        }
        return Ok(json!({"collectionID":id,"revision":rev,"published":true,"count":expected}));
    }
    let next = revision(Some(&old), r)?;
    if prev.is_none() && !ids.is_empty() {
        visible(db, &ids)?;
        db.execute("INSERT INTO lc_org_member_stage SELECT ?1,?2+CAST(key AS INTEGER),value FROM json_each(?3)",params![batch,start,body])?;
        db.execute(
            "INSERT INTO lc_org_member_parts VALUES(?,?,?,?)",
            params![batch, start, count, digest],
        )?;
    }
    if !finish {
        return Ok(json!({"collectionID":id,"revision":base,"published":false}));
    }
    let wanted = r["expectedCount"]
        .as_i64()
        .filter(|n| *n >= 0)
        .ok_or("finishing a member import requires its expected size")?;
    let (n, last): (i64, i64) = db.query_row(
        "SELECT count(*),coalesce(max(position),-1) FROM lc_org_member_stage WHERE import_id=?",
        [batch],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if n != wanted || last != wanted - 1 {
        return Err("member import is incomplete".into());
    }
    let ineligible:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_org_member_stage s WHERE s.import_id=? AND NOT EXISTS(SELECT 1 FROM lc_org_visible_sources v WHERE v.work_id=s.work_id))",[batch],|r|r.get(0))?;
    if ineligible {
        return Err("a staged member left the library before publication".into());
    }
    db.execute(
        "DELETE FROM lc_org_collection_members WHERE collection_id=?",
        [id],
    )?;
    db.execute("INSERT INTO lc_org_collection_members SELECT ?1,work_id,position FROM lc_org_member_stage WHERE import_id=?2",params![id,batch])?;
    db.execute("DELETE FROM lc_org_member_stage WHERE import_id=?", [batch])?;
    db.execute(
        "UPDATE lc_org_member_imports SET published_revision=?,expected_count=? WHERE import_id=?",
        params![next, wanted, batch],
    )?;
    db.execute(
        "UPDATE lc_org_collections SET revision=? WHERE collection_id=?",
        params![next, id],
    )?;
    tidy_scope(db, "collection", Some(id))?;
    Ok(json!({"collectionID":id,"revision":next,"published":true,"count":wanted}))
}
pub(super) fn folder_order(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "folderID")?;
    let old = stored(db, works::FOLDER, id)?.ok_or("unknown folder")?;
    let rev = revision(Some(&old), r)?;
    let ids = list(r, "workIDs")?;
    scoped(db, "folder", id, &ids)?;
    db.execute("DELETE FROM lc_org_folder_order WHERE folder_id=?", [id])?;
    db.execute(
        "INSERT INTO lc_org_folder_order SELECT ?1,value,CAST(key AS INTEGER) FROM json_each(?2)",
        params![id, serde_json::to_string(&ids)?],
    )?;
    db.execute(
        "UPDATE lc_org_folders SET revision=? WHERE folder_id=?",
        params![rev, id],
    )?;
    Ok(json!({"folderID":id,"revision":rev}))
}
fn membership(kind: &str) -> Result<&'static str> {
    match kind{
        "folder"=>Ok("SELECT work_id FROM lc_org_visible_sources WHERE source_folder_id=?1"),
        "collection"=>Ok("SELECT m.work_id FROM lc_org_collection_members m JOIN lc_org_visible_sources v ON v.work_id=m.work_id WHERE m.collection_id=?1"),
        _=>Err("unknown organization scope".into()),
    }
}
fn scoped(db: &Connection, kind: &str, id: &str, works: &[String]) -> Result<()> {
    let contains = membership(kind)?;
    let sql =
        format!("SELECT EXISTS(SELECT 1 FROM json_each(?2) i WHERE i.value NOT IN ({contains}))");
    if db.query_row(&sql, params![id, serde_json::to_string(works)?], |r| {
        r.get::<_, bool>(0)
    })? {
        return Err("a work is outside the requested scope".into());
    }
    Ok(())
}
pub(super) fn stack(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "stackID")?;
    let old = stored(db, STACK, id)?;
    let rev = revision(old.as_ref(), r)?;
    let v = amended(
        old.as_ref().unwrap_or(&json!({})),
        r,
        &["scopeKind", "scopeID", "coverWorkID", "collapsed"],
    );
    let kind = string(&v, "scopeKind")?;
    let scope = string(&v, "scopeID")?;
    if old
        .as_ref()
        .is_some_and(|o| o["scopeKind"] != kind || o["scopeID"] != scope)
    {
        return Err("a stack is bound to one scope".into());
    }
    let ids = if r.get("workIDs").is_some() {
        list(r, "workIDs")?
    } else {
        let mut stmt = db.prepare(
            "SELECT work_id FROM lc_org_stack_members WHERE stack_id=? ORDER BY position",
        )?;
        let rows = stmt.query_map([id], |r| r.get(0))?;
        rows.collect::<rusqlite::Result<Vec<String>>>()?
    };
    let cover = string(&v, "coverWorkID")?;
    if ids.len() < 2 || !ids.iter().any(|w| w == cover) {
        return Err("stack needs at least two members and a member cover".into());
    }
    scoped(db, kind, scope, &ids)?;
    let collapsed = v
        .get("collapsed")
        .map(|v| v.as_bool().ok_or("collapsed must be boolean"))
        .transpose()?
        .unwrap_or(true);
    db.execute("INSERT INTO lc_org_stacks VALUES(?,?,?,?,?,?) ON CONFLICT(stack_id) DO UPDATE SET cover_work_id=excluded.cover_work_id,
        collapsed=excluded.collapsed,revision=excluded.revision",params![id,kind,scope,cover,collapsed,rev])?;
    db.execute("DELETE FROM lc_org_stack_members WHERE stack_id=?", [id])?;
    db.execute("INSERT INTO lc_org_stack_members SELECT ?1,?2,?3,value,CAST(key AS INTEGER) FROM json_each(?4)",params![id,kind,scope,serde_json::to_string(&ids)?])?;
    Ok(json!({"stackID":id,"revision":rev}))
}
pub(super) fn remove_stack(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "stackID")?;
    let current = stored(db, STACK, id)?.ok_or("unknown stack")?;
    let revision = revision(Some(&current), r)?;
    db.execute("DELETE FROM lc_org_stacks WHERE stack_id=?", [id])?;
    Ok(json!({"stackID":id,"removed":true,"revision":revision}))
}
pub(super) fn tidy_scope(db: &Connection, kind: &str, scope: Option<&str>) -> Result<()> {
    let Some(scope) = scope else {
        return Ok(());
    };
    let member = membership(kind)?;
    let mut stmt=db.prepare(&format!("SELECT DISTINCT stack_id FROM lc_org_stack_members WHERE scope_id=?1 AND scope_kind=?2 AND work_id NOT IN ({member})"))?;
    let stale = stmt
        .query_map(params![scope, kind], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for stack in stale {
        db.execute(
            &format!(
                "DELETE FROM lc_org_stack_members WHERE stack_id=?2 AND work_id NOT IN ({member})"
            ),
            params![scope, stack],
        )?;
        let count: i64 = db.query_row(
            "SELECT count(*) FROM lc_org_stack_members WHERE stack_id=?",
            [&stack],
            |r| r.get(0),
        )?;
        if count < 2 {
            db.execute("DELETE FROM lc_org_stacks WHERE stack_id=?", [stack])?;
        } else {
            db.execute("UPDATE lc_org_stacks SET revision=revision+1,cover_work_id=CASE WHEN EXISTS(SELECT 1 FROM lc_org_stack_members m WHERE m.stack_id=?1 AND m.work_id=cover_work_id)
                THEN cover_work_id ELSE (SELECT work_id FROM lc_org_stack_members WHERE stack_id=?1 ORDER BY position LIMIT 1) END WHERE stack_id=?1",[stack])?;
        }
    }
    Ok(())
}
