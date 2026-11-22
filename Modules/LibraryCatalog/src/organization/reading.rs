use super::*;
use rusqlite::params;

fn nodes(db: &Connection, sql: &str) -> Result<Vec<Value>> {
    let mut stmt = db.prepare(sql)?;
    let mut rows = stmt.query([])?;
    let mut out = Vec::new();
    while let Some(row) = rows.next()? {
        out.push(serde_json::from_str(&row.get::<_, String>(0)?)?);
    }
    Ok(out)
}
pub(super) fn read(db: &Connection, r: &Value) -> Result<Value> {
    match r["view"].as_str().unwrap_or("navigation") {
        "navigation" => Ok(json!({
            "volumes":nodes(db,"SELECT json_object('id',volume_id,'kind','volume','name',name,'locator',locator,'online',online,'revision',revision) FROM lc_org_volumes ORDER BY name,volume_id")?,
            "folders":nodes(db,"SELECT json_object('id',folder_id,'kind','folder','volumeID',volume_id,'parentID',parent_id,'name',name,'revision',revision)
              FROM lc_org_folders ORDER BY volume_id,parent_id,position,name,folder_id")?,
            "collections":nodes(db,"SELECT json_object('id',collection_id,'kind',kind,'parentID',parent_id,'name',name,'rule',json(rule_json),'revision',revision)
              FROM lc_org_collections ORDER BY parent_id,position,name,collection_id")?
        })),
        "works" => {
            let mut req = r.clone();
            req.as_object_mut()
                .ok_or("expected organization request")?
                .remove("view");
            if req.get("level").is_none() {
                req["level"] = json!("work");
            }
            super::work_page(db, &req)
        }
        "work" => {
            let id = string(r, "workID")?;
            require(
                db,
                "SELECT EXISTS(SELECT 1 FROM lc_org_visible_sources WHERE work_id=?)",
                id,
                "work is outside the library",
            )?;
            let mut item = stored(db, works::WORK, id)?.ok_or("unknown work")?;
            let mut stmt=db.prepare("SELECT version_id,parent_version_id,appearance_json,position FROM lc_org_versions WHERE work_id=? ORDER BY position DESC")?;
            let mut rows = stmt.query([id])?;
            let mut versions = Vec::new();
            while let Some(row) = rows.next()? {
                versions.push(json!({"versionID":row.get::<_,String>(0)?,"parentVersionID":row.get::<_,Option<String>>(1)?,
                "appearance":serde_json::from_str::<Value>(&row.get::<_,String>(2)?)?,"position":row.get::<_,i64>(3)?}));
            }
            item["versions"] = json!(versions);
            Ok(item)
        }
        "stacks" => {
            let kind = string(r, "scopeKind")?;
            let id = string(r, "scopeID")?;
            let mut stmt=db.prepare("SELECT s.stack_id,s.cover_work_id,s.collapsed,s.revision,m.work_id,m.position FROM lc_org_stacks s
                JOIN lc_org_stack_members m ON m.stack_id=s.stack_id JOIN lc_org_visible_sources v ON v.work_id=m.work_id
                WHERE s.scope_kind=? AND s.scope_id=? ORDER BY s.stack_id,m.position")?;
            let mut rows = stmt.query(params![kind, id])?;
            let mut items: Vec<Value> = Vec::new();
            while let Some(row) = rows.next()? {
                let sid: String = row.get(0)?;
                if items.last().is_none_or(|v| v["stackID"] != sid) {
                    items.push(json!({"stackID":sid,"coverWorkID":row.get::<_,String>(1)?,
                    "collapsed":row.get::<_,bool>(2)?,"revision":row.get::<_,i64>(3)?,"workIDs":[]}));
                }
                items.last_mut().unwrap()["workIDs"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!(row.get::<_, String>(4)?));
            }
            Ok(json!({"items":items}))
        }
        "collection" => stored(db, groups::COLLECTION, string(r, "collectionID")?)?
            .ok_or_else(|| "unknown collection".into()),
        "folder" => stored(db, works::FOLDER, string(r, "folderID")?)?
            .ok_or_else(|| "unknown folder".into()),
        "volume" => stored(db, works::VOLUME, string(r, "volumeID")?)?
            .ok_or_else(|| "unknown volume".into()),
        _ => Err("unknown organization view".into()),
    }
}
