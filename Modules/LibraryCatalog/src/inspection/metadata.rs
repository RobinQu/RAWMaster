use super::*;
use sha2::{Digest, Sha256};

pub(super) const EDITABLE: &[&str] = &[
    "title",
    "caption",
    "creator",
    "copyright",
    "keywords",
    "rating",
    "flag",
    "colorLabel",
    "place",
    "latitude",
    "longitude",
];
const OPTICAL: &[&str] = &[
    "capturedAt",
    "capturedLocal",
    "offsetTime",
    "make",
    "camera",
    "lens",
    "iso",
    "width",
    "height",
    "focalLength",
    "aperture",
    "shutterSeconds",
    "exposureCompensation",
    "colorSpace",
    "orientation",
];
fn text(v: &Value) -> bool {
    v.as_str()
        .is_some_and(|s| s.len() <= 65_536 && !s.contains('\0'))
}
pub(super) fn validate(key: &str, v: &Value, embedded: bool) -> bool {
    if v.is_null() {
        return true;
    }
    match key {
        "title" | "caption" | "creator" | "copyright" | "place" | "colorLabelRaw"
        | "capturedLocal" | "offsetTime" => text(v),
        "rating" => v.as_i64().is_some_and(|n| (0..=5).contains(&n)),
        "flag" => matches!(v.as_str(), Some("picked" | "rejected" | "unflagged")),
        "colorLabel" => matches!(
            v.as_str(),
            Some("red" | "yellow" | "green" | "blue" | "purple" | "none")
        ),
        "latitude" => v.as_f64().is_some_and(|n| (-90.0..=90.0).contains(&n)),
        "longitude" => v.as_f64().is_some_and(|n| (-180.0..=180.0).contains(&n)),
        "capturedAt" => v.as_f64().is_some_and(f64::is_finite),
        "keywords" => v.as_array().is_some_and(|a| {
            a.len() <= 4096
                && a.iter().all(|item| {
                    item.as_object()
                        .is_some_and(|o| o.keys().all(|k| k == "id" || k == "path"))
                        && item.get("id").is_none_or(text)
                        && item["path"].as_array().is_some_and(|p| {
                            !p.is_empty()
                                && p.len() <= 64
                                && p.iter().all(|s| text(s) && s.as_str() != Some(""))
                        })
                })
        }),
        "make" | "camera" | "lens" | "colorSpace" if embedded => text(v),
        "width" | "height" | "iso" if embedded => v
            .as_f64()
            .is_some_and(|n| n.fract() == 0.0 && n > 0.0 && n <= i32::MAX as f64),
        "orientation" if embedded => v.as_u64().is_some_and(|n| (1..=8).contains(&n)),
        "aperture" | "shutterSeconds" | "focalLength" if embedded => {
            v.as_f64().is_some_and(|n| n.is_finite() && n > 0.0)
        }
        "exposureCompensation" if embedded => v.as_f64().is_some_and(f64::is_finite),
        _ => false,
    }
}
pub(super) fn import_fields(
    db: &Connection,
    id: &str,
    catalog: &str,
    object: &str,
    revision: &str,
    fields: &Value,
) -> Result<()> {
    if db.is_autocommit()
        || [id, catalog, object, revision]
            .iter()
            .any(|s| s.is_empty() || s.contains('\0'))
    {
        return Err("Missing migration source identity or catalog transaction".into());
    }
    let map = fields
        .as_object()
        .ok_or("Migration metadata must be an object")?;
    if !db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_org_works WHERE work_id=?)",
        [id],
        |r| r.get::<_, bool>(0),
    )? {
        return Err("Unknown migration work".into());
    }
    for (k, v) in map {
        if !(EDITABLE.contains(&k.as_str())
            || OPTICAL.contains(&k.as_str())
            || matches!(
                k.as_str(),
                "colorLabelRaw" | "capturedAt" | "capturedLocal" | "offsetTime"
            ))
            || !validate(k, v, true)
        {
            return Err(format!("Invalid migration metadata field {k}").into());
        }
    }
    let encoded = fields.to_string();
    let added=db.execute("INSERT INTO lc_inspect_imports(work_id,source_catalog,source_object,source_revision,fields_json) VALUES(?,?,?,?,?)
        ON CONFLICT(work_id,source_catalog,source_object,source_revision) DO NOTHING",params![id,catalog,object,revision,encoded])?;
    if added == 0 {
        let existing:String=db.query_row("SELECT fields_json FROM lc_inspect_imports WHERE work_id=? AND source_catalog=? AND source_object=? AND source_revision=?",
            params![id,catalog,object,revision],|r|r.get(0))?;
        if serde_json::from_str::<Value>(&existing)? != *fields {
            return Err("Metadata changed under the same source revision".into());
        }
    } else {
        work_change(db, id)?;
    }
    Ok(())
}
pub(super) struct Work {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub file: Option<String>,
    pub content: Option<String>,
    pub asset: Option<String>,
    pub capture: Option<String>,
    pub path: Option<String>,
    pub availability: String,
    pub fields: Map<String, Value>,
}
pub(super) fn work(db: &Connection, id: &str) -> Result<Work> {
    let (kind,name,file,rating,project,raw):(String,String,Option<String>,Option<i64>,Option<String>,Option<String>)=db.query_row(
        "SELECT w.kind,coalesce(w.name,''),coalesce(w.file_id,m.file_id),w.rating,w.project_id,w.metadata_json FROM lc_org_works w LEFT JOIN lc_org_works m ON m.work_id=w.master_work_id WHERE w.work_id=?",
        [id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)))?;
    let mut w = Work {
        id: id.into(),
        kind,
        name,
        file,
        content: None,
        asset: None,
        capture: None,
        path: None,
        availability: "offline".into(),
        fields: Map::new(),
    };
    let mut defaults = Map::new();
    if let Some(raw) = raw {
        if let Some(o) = serde_json::from_str::<Value>(&raw)?.as_object() {
            for (k, v) in o {
                if validate(k, v, true) && !v.is_null() {
                    defaults.insert(k.clone(), json!({"value":v,"origin":"catalog"}));
                }
            }
        }
    }
    if let Some(file) = w.file.as_deref() {
        let item:Option<(String,String,String,String,Option<String>,String)>=db.query_row("SELECT f.asset_id,f.capture_id,s.content_id,a.data,
            coalesce(json_extract(a.data,'$.effectiveManagedPath'),json_extract(a.data,'$.currentPath')),
            coalesce(json_extract(a.data,'$.availability'),'unknown') FROM lc_catalog_files f JOIN assets a ON a.id=f.asset_id
            JOIN lc_scopes s ON s.asset_id=f.asset_id AND s.file_id=f.file_id AND s.project_id=f.project_id
            LEFT JOIN lc_asset_input a1 ON a1.asset_id=f.asset_id WHERE f.file_id=?1 AND (?2 IS NULL OR f.project_id=?2)
            ORDER BY (s.content_id=a1.content_id) DESC,f.project_id,s.scope_id LIMIT 1",params![file,project],
            |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional()?;
        if let Some((asset, cap, content, data, path, availability)) = item {
            let v: Value = serde_json::from_str(&data)?;
            if w.name.is_empty() {
                w.name = v["filename"].as_str().unwrap_or_default().into();
            }
            for key in ["camera", "width", "height", "capturedAt", "rating"] {
                if !v[key].is_null() {
                    defaults.insert(key.into(), json!({"value":v[key],"origin":"catalog"}));
                }
            }
            defaults.extend(typed_rows(db,"SELECT field,value_json,origin FROM lc_inspect_file_effective WHERE file_id=? AND content_id=?",params![file,content])?);
            w.asset = Some(asset);
            w.capture = Some(cap);
            w.content = Some(content);
            w.path = path;
            w.availability = availability;
        } else if w.kind != "offline" {
            return Err("Work has no admitted original in this scope".into());
        }
    }
    if let Some(n) = rating {
        defaults.insert("rating".into(), json!({"value":n,"origin":"organization"}));
    }
    for (k, v) in typed_rows(
        db,
        "SELECT field,value_json,origin FROM lc_inspect_work_effective WHERE work_id=?",
        [id],
    )? {
        if OPTICAL.contains(&k.as_str())
            && defaults.get(&k).is_some_and(|f| f["origin"] == "embedded")
        {
            continue;
        }
        defaults.insert(k, v);
    }
    let mut st=db.prepare("SELECT field,source_catalog,source_object,source_revision FROM lc_inspect_import_effective WHERE work_id=?")?;
    let mut origins = st.query([id])?;
    while let Some(row) = origins.next()? {
        if let Some(v) = defaults.get_mut(&row.get::<_, String>(0)?) {
            if v["origin"] == "lightroom" {
                v["sourceCatalogID"] = json!(row.get::<_, String>(1)?);
                v["sourceObjectID"] = json!(row.get::<_, String>(2)?);
                v["sourceRevision"] = json!(row.get::<_, String>(3)?);
            }
        }
    }
    w.fields = defaults;
    Ok(w)
}
pub(super) fn selection(db: &Connection, target: &[String]) -> Result<Value> {
    let mut combined = Map::new();
    let mut hash = Sha256::new();
    for id in target {
        let w = work(db, id)?;
        let mut revisions = Vec::new();
        let mut s = db.prepare_cached(
            "SELECT field,command_id FROM lc_inspect_manual WHERE work_id=? ORDER BY field",
        )?;
        for v in s.query_map([id], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })? {
            revisions.push(v?);
        }
        let row = serde_json::to_vec(&(id, &w.content, &w.fields, revisions))?;
        hash.update((row.len() as u64).to_be_bytes());
        hash.update(row);
        for key in EDITABLE {
            let value = w
                .fields
                .get(*key)
                .map(|v| v["value"].clone())
                .unwrap_or(Value::Null);
            let entry = combined
                .entry((*key).to_string())
                .or_insert_with(|| json!({"state":"shared","value":value}));
            if entry["state"] == "shared" && entry["value"] != value {
                *entry = json!({"state":"mixed"});
            }
        }
    }
    Ok(
        json!({"count":target.len(),"workIDs":target,"fields":combined,"token":hex::encode(hash.finalize())}),
    )
}
pub(super) fn edit(db: &Connection, r: &Value) -> Result<Value> {
    let target = ids(&r["workIDs"])?;
    let before = selection(db, &target)?;
    if string(r, "expectedToken")? != before["token"].as_str().unwrap_or_default() {
        return Err("Selected metadata changed; review the current values".into());
    }
    let fields = r["fields"]
        .as_object()
        .filter(|m| !m.is_empty())
        .ok_or("Specify edited fields")?;
    let op = string(r, "commandID")?;
    for (key, value) in fields {
        if !EDITABLE.contains(&key.as_str()) || !validate(key, value, false) {
            return Err(format!("Invalid editable field {key}").into());
        }
    }
    for id in &target {
        for (field, v) in fields {
            let previous:Option<(String,String)>=db.query_row("SELECT value_json,command_id FROM lc_inspect_manual WHERE work_id=? AND field=?",params![id,field],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
            let (old_value, old_op) = previous.unzip();
            db.execute("INSERT INTO lc_inspect_undo(command_id,work_id,field,old_value,old_command) VALUES(?,?,?,?,?)",params![op,id,field,old_value,old_op])?;
            db.execute("INSERT INTO lc_inspect_manual VALUES(?,?,?,?) ON CONFLICT(work_id,field) DO UPDATE SET value_json=excluded.value_json,command_id=excluded.command_id",
                params![id,field,v.to_string(),op])?;
        }
        work_change(db, id)?;
    }
    Ok(json!({"count":target.len(),"fields":fields.keys().collect::<Vec<_>>(),"editCommandID":op}))
}
pub(super) fn undo(db: &Connection, r: &Value) -> Result<Value> {
    let op = string(r, "editCommandID")?;
    let mut s=db.prepare("SELECT u.work_id,u.field,u.old_value,u.old_command,m.command_id,u.undone FROM lc_inspect_undo u
        LEFT JOIN lc_inspect_manual m USING(work_id,field) WHERE u.command_id=? ORDER BY u.work_id,u.field")?;
    let rows = s
        .query_map([op], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, Option<String>>(4)?,
                r.get::<_, bool>(5)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if rows.is_empty() || rows.iter().any(|r| r.4.as_deref() != Some(op) || r.5) {
        return Err("This edit was undone or a later change now owns a field".into());
    }
    let mut changed = BTreeSet::new();
    for (work, field, old, old_op, _, _) in rows {
        if let Some(old) = old {
            db.execute("UPDATE lc_inspect_manual SET value_json=?,command_id=? WHERE work_id=? AND field=?",params![old,old_op,work,field])?;
        } else {
            db.execute(
                "DELETE FROM lc_inspect_manual WHERE work_id=? AND field=?",
                params![work, field],
            )?;
        }
        changed.insert(work);
    }
    db.execute(
        "UPDATE lc_inspect_undo SET undone=1 WHERE command_id=?",
        [op],
    )?;
    for w in &changed {
        work_change(db, w)?;
    }
    Ok(json!({"count":changed.len(),"undid":op}))
}
