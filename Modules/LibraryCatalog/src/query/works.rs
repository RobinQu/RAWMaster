use super::{
    filter::{self, Request},
    text,
};
use crate::Result;
use rusqlite::{
    functions::FunctionFlags,
    params_from_iter,
    types::{Value as Bind, ValueRef},
    Connection,
};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};

fn predicate_extra(v: &Value) -> bool {
    match v {
        Value::Object(o) => {
            o.get("field")
                .and_then(Value::as_str)
                .and_then(filter::extra)
                .is_some()
                || o.values().any(predicate_extra)
        }
        Value::Array(a) => a.iter().any(predicate_extra),
        _ => false,
    }
}
pub(super) fn needed(v: &Value) -> bool {
    v["level"] == "work"
        || v["sort"] == "manual"
        || v["collapseStacks"] == true
        || ["folderID", "volumeID", "collectionID", "workID"]
            .iter()
            .any(|k| !v[*k].is_null())
        || predicate_extra(&v["predicate"])
        || v["facets"].as_array().is_some_and(|a| {
            a.iter()
                .any(|v| v.as_str().and_then(filter::extra).is_some())
        })
}
pub(crate) fn validate_rule(v: &Value) -> Result<()> {
    if !v.is_object()
        || v.as_object().unwrap().keys().any(|k| {
            !matches!(
                k.as_str(),
                "query"
                    | "predicate"
                    | "projectID"
                    | "sessionID"
                    | "groupID"
                    | "volumeID"
                    | "folderID"
                    | "includeDescendants"
                    | "workID"
            )
        })
    {
        return Err("invalid smart collection rule or recursive collection dependency".into());
    }
    filter::matching(&Request::parse(v)?, 0, filter::Fts::default())?;
    Ok(())
}
fn register(db: &Connection) -> Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC;
    db.create_collation("rm_natural", text::natural)?;
    db.create_scalar_function("rm_org_fold", 1, flags, |c| {
        Ok(c.get::<Option<String>>(0)?.map(|s| text::searchable(&s)))
    })?;
    db.create_scalar_function("rm_org_tag", 1, flags, |c| {
        Ok(text::tag_key(&c.get::<String>(0)?))
    })?;
    db.create_scalar_function("rm_org_format", 1, flags, |c| {
        Ok(std::path::Path::new(&c.get::<String>(0)?)
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .to_ascii_lowercase())
    })?;
    db.create_scalar_function("rm_org_number", 1, flags, |c| {
        Ok(match c.get_raw(0) {
            ValueRef::Integer(i) => Some(i as f64),
            ValueRef::Real(n) => Some(n),
            _ => None,
        })
    })?;
    db.create_scalar_function("rm_org_meta", 6, flags, |ctx| {
        let mut result = Map::new();
        let mut observations = Map::new();
        for i in 0..6 {
            if i == 4 {
                if let Some(n) = ctx.get::<Option<i64>>(i)? {
                    result.insert("rating".into(), json!(n));
                }
                continue;
            }
            if let Some(s) = ctx.get::<Option<String>>(i)? {
                let v: Map<String, Value> = serde_json::from_str(&s)
                    .map_err(|e| rusqlite::Error::UserFunctionError(Box::new(e)))?;
                if i == 3 {
                    for key in [
                        "camera",
                        "lens",
                        "iso",
                        "aperture",
                        "shutterSeconds",
                        "focalLength",
                        "exposureCompensation",
                        "capturedAt",
                        "offsetTime",
                        "width",
                        "height",
                        "colorSpace",
                        "focusMachine",
                        "focusManual",
                        "focusEffective",
                    ] {
                        if let Some(v) = v.get(key).filter(|v| !v.is_null()) {
                            observations.insert(key.to_owned(), v.clone());
                        }
                    }
                }
                result.extend(v);
            }
        }
        result.extend(observations);
        Ok(Value::Object(result).to_string())
    })?;
    db.create_scalar_function("rm_org_tags", 2, flags, |ctx| {
        let metadata: Value = serde_json::from_str(&ctx.get::<String>(0)?)
            .map_err(|e| rusqlite::Error::UserFunctionError(Box::new(e)))?;
        let fallback: Value = serde_json::from_str(&ctx.get::<String>(1)?)
            .map_err(|e| rusqlite::Error::UserFunctionError(Box::new(e)))?;
        Ok(json!(tag_list(metadata.get("keywords").unwrap_or(&fallback))).to_string())
    })?;
    Ok(())
}
pub(super) fn tag_list(value: &Value) -> Vec<String> {
    let mut result = BTreeSet::new();
    if let Some(list) = value.as_array() {
        for item in list {
            if let Some(label) = item.as_str() {
                result.insert(label.to_owned());
            }
            if let Some(path) = item.get("path").and_then(Value::as_array) {
                let path = path.iter().filter_map(Value::as_str).collect::<Vec<_>>();
                result.extend(path.iter().map(|v| v.to_string()));
                if !path.is_empty() {
                    result.insert(path.join("/"));
                }
            }
        }
    }
    result.into_iter().collect()
}
struct Bindings(Vec<Bind>);
impl Bindings {
    fn add(&mut self, v: impl Into<Bind>) -> String {
        self.0.push(v.into());
        format!("?{}", self.0.len())
    }
    fn merge(&mut self, sql: &str, values: Vec<Bind>) -> String {
        let off = self.0.len();
        self.0.extend(values);
        let mut out = String::new();
        let mut chars = sql.chars().peekable();
        while let Some(c) = chars.next() {
            out.push(c);
            if c == '?' {
                let mut n = String::new();
                while chars.peek().is_some_and(|c| c.is_ascii_digit()) {
                    n.push(chars.next().unwrap());
                }
                if !n.is_empty() {
                    out.push_str(&(n.parse::<usize>().unwrap() + off).to_string());
                }
            }
        }
        out
    }
}
fn scope(r: &Request, b: &mut Bindings, folder: &str, volume: &str, work: &str) -> Vec<String> {
    let mut terms = Vec::new();
    if let Some(v) = &r.volume {
        terms.push(format!("{volume}={}", b.add(v.clone())));
    }
    if let Some(w) = &r.work {
        terms.push(format!("{work}={}", b.add(w.clone())));
    }
    if let Some(f) = &r.folder {
        let p = b.add(f.clone());
        terms.push(if r.include_descendants{format!("{folder} IN (WITH RECURSIVE tree(id) AS (SELECT {p} UNION ALL SELECT c.folder_id FROM lc_org_folders c JOIN tree t ON c.parent_id=t.id) SELECT id FROM tree)")}
            else{format!("{folder}={p}")});
    }
    terms
}
fn descriptor(r: &Request, b: &mut Bindings) -> Result<String> {
    let m = filter::matching(r, 0, filter::Fts::default())?;
    let mut sql = b.merge(&m.select, m.binds);
    for t in scope(r, b, "d.source_folder_id", "d.volume_id", "d.work_id") {
        sql.push_str(" AND ");
        sql.push_str(&t);
    }
    Ok(sql)
}
fn collection(db: &Connection, id: &str, b: &mut Bindings) -> Result<String> {
    let mut stmt=db.prepare("WITH RECURSIVE tree(id) AS (SELECT collection_id FROM lc_org_collections WHERE collection_id=? UNION ALL
        SELECT c.collection_id FROM lc_org_collections c JOIN tree ON c.parent_id=tree.id)
        SELECT kind,collection_id,rule_json FROM lc_org_collections WHERE collection_id IN tree ORDER BY collection_id")?;
    let rows = stmt.query_map([id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Option<String>>(2)?,
        ))
    })?;
    let mut regular = Vec::new();
    let mut choices = Vec::new();
    for row in rows {
        let (kind, child, rule) = row?;
        match kind.as_str() {
            "regular" => regular.push(child),
            "smart" => {
                let rule: Value = serde_json::from_str(&rule.ok_or("missing saved rule")?)?;
                validate_rule(&rule)?;
                let q = descriptor(&Request::parse(&rule)?, b)?;
                choices.push(format!("x.doc IN (SELECT doc FROM ({q}))"));
            }
            _ => (),
        }
    }
    if !regular.is_empty() {
        let ids = b.add(serde_json::to_string(&regular)?);
        choices.push(format!("x.work_id IN (SELECT work_id FROM lc_org_collection_members WHERE collection_id IN (SELECT value FROM json_each({ids})))"));
    }
    Ok(if choices.is_empty() {
        "0".into()
    } else {
        format!("({})", choices.join(" OR "))
    })
}
fn sql_value(v: ValueRef<'_>) -> Result<Value> {
    Ok(match v {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(n) => json!(n),
        ValueRef::Real(n) => json!(n),
        ValueRef::Text(s) => json!(std::str::from_utf8(s)?),
        _ => return Err("binary organization result".into()),
    })
}
fn query_json(v: &Value) -> Result<Bind> {
    Ok(match v {
        Value::Number(n) => n
            .as_i64()
            .map(Bind::Integer)
            .or_else(|| n.as_f64().map(Bind::Real))
            .ok_or("invalid page number")?,
        Value::String(s) => Bind::Text(s.clone()),
        _ => return Err("invalid work cursor key".into()),
    })
}

fn projected(db: &Connection, r: &Request, b: &mut Bindings) -> Result<String> {
    projected_selection(db, r, b, None)
}
fn projected_selection(
    db: &Connection,
    r: &Request,
    b: &mut Bindings,
    selection: Option<&[String]>,
) -> Result<String> {
    let mut anchor = scope(r, b, "v.source_folder_id", "fo.volume_id", "w.work_id");
    if let Some(ids) = selection {
        let param = b.add(serde_json::to_string(ids)?);
        anchor.push(format!(
            "w.work_id IN(SELECT value FROM json_each({param}))"
        ));
    }
    if r.level != "work" {
        anchor.push("f.file_id IS NOT NULL".into());
    }
    if let Some(p) = &r.project {
        anchor.push(format!(
            "coalesce(f.project_id,v.work_project_id,'')={}",
            b.add(p.clone())
        ));
    }
    let mut keep = "1".to_owned();
    if let Some(id) = &r.collection {
        let regular:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_org_collections WHERE collection_id=? AND kind='regular')",[id],|r|r.get(0))?;
        if regular {
            let p = b.add(id.clone());
            anchor.push(format!("w.work_id IN (SELECT work_id FROM lc_org_collection_members WHERE collection_id={p})"));
        } else {
            keep = collection(db, id, b)?;
        }
    }
    let inspect:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='lc_inspect_file_effective') AND EXISTS(SELECT 1 FROM sqlite_schema WHERE name='lc_inspect_work_effective')",[],|r|r.get(0))?;
    let file = if inspect {
        "(SELECT json_group_object(field,json(value_json)) FROM lc_inspect_file_effective f WHERE f.file_id=o.source_file_id AND f.content_id=o.content_id)"
    } else {
        "'{}'"
    };
    let work = if inspect {
        "(SELECT json_group_object(field,json(value_json)) FROM lc_inspect_work_effective w WHERE w.work_id=o.work_id)"
    } else {
        "'{}'"
    };
    let base = include_str!("work_source.sql")
        .replace(
            "__ANCHOR__",
            &if anchor.is_empty() {
                "1".into()
            } else {
                anchor.join(" AND ")
            },
        )
        .replace("__FILE_EFFECTIVE__", file)
        .replace("__WORK_EFFECTIVE__", work);
    let select = descriptor(r, b)?;
    let object = match r.level.as_str() {
        "work" => "x.work_id",
        "file" => "x.source_file_id",
        _ => "x.capture_id",
    };
    let (scope_kind, selected) = if let Some(c) = &r.collection {
        ("collection", Some(c))
    } else {
        ("folder", r.folder.as_ref())
    };
    let (manual, join) = if let Some(id) = selected {
        let p = b.add(id.clone());
        let manual = if scope_kind == "collection" {
            format!("(SELECT position FROM lc_org_collection_members cm WHERE cm.collection_id={p} AND cm.work_id=x.work_id)")
        } else {
            format!("(SELECT position FROM lc_org_folder_order fo WHERE fo.folder_id={p} AND fo.work_id=x.work_id)")
        };
        (manual,format!("LEFT JOIN lc_org_stack_members sm ON sm.work_id=x.work_id AND sm.scope_kind='{scope_kind}' AND sm.scope_id={p} LEFT JOIN lc_org_stacks st ON st.stack_id=sm.stack_id"))
    } else {
        (
            "NULL".into(),
            "LEFT JOIN lc_org_stack_members sm ON 0 LEFT JOIN lc_org_stacks st ON 0".into(),
        )
    };
    let display = if r.collapse_stacks && r.level == "work" {
        format!("CASE WHEN st.collapsed THEN json_array('stack',st.stack_id) ELSE json_array('object',{object}) END")
    } else {
        format!("json_array('object',{object})")
    };
    Ok(format!("{base}, matched AS NOT MATERIALIZED ({select}), hits AS MATERIALIZED (
        SELECT x.*,{object} AS object_id,{display} AS display_id,sm.stack_id,st.cover_work_id,st.collapsed,sm.position AS stack_pos,
        coalesce({manual},9223372036854775807) AS manual_pos FROM matched x {join} WHERE {keep}),
        candidates AS (SELECT h.*,row_number() OVER(PARTITION BY display_id ORDER BY CASE WHEN cover_work_id=work_id THEN 0 ELSE 1 END,
            coalesce(stack_pos,9223372036854775807),work_id,coalesce(asset_id,''),project_id) AS representative FROM hits h)"))
}

/// Enumerate only the structurally eligible work rows. The scene, face and
/// spatial readers use this same predicate before examining derived indexes.
pub(crate) fn discovery_inputs(
    db: &Connection,
    descriptor: &Value,
) -> Result<Vec<crate::discovery::Input>> {
    discovery_inputs_selected(db, descriptor, None)
}
fn discovery_request(descriptor: &Value) -> Result<Request> {
    let mut req = descriptor.clone();
    let fields = req
        .as_object_mut()
        .ok_or("expected a structured discovery scope")?;
    fields.insert("level".into(), json!("work"));
    fields.remove("cursor");
    Request::parse(&req)
}

pub(crate) fn discovery_inputs_selected(
    db: &Connection,
    descriptor: &Value,
    selection: Option<&[String]>,
) -> Result<Vec<crate::discovery::Input>> {
    let r = discovery_request(descriptor)?;
    register(db)?;
    let mut binds = Bindings(Vec::new());
    let cte = projected_selection(db, &r, &mut binds, selection)?;
    let mut stmt=db.prepare(&format!("{cte} SELECT h.work_id,h.display_name,h.kind,h.source_file_id,h.content_id,h.active_version_id,
        CASE WHEN h.active_version_id IS NULL THEN h.resource_id ELSE (SELECT json_extract(v.appearance_json,'$.resourceID') FROM lc_org_versions v WHERE v.version_id=h.active_version_id) END,
        h.latitude,h.longitude,h.project_id,h.capture_id,
        (SELECT a.path FROM lc_archive_files a WHERE a.file_id=h.source_file_id AND a.project_id=h.project_id AND a.content_id=h.content_id AND a.path IS NOT NULL ORDER BY a.path LIMIT 1),h.filename
        FROM hits h ORDER BY h.work_id,h.project_id"))?;
    let mut rs = stmt.query(params_from_iter(&binds.0))?;
    let mut result = BTreeMap::new();
    let mut resource = db.prepare_cached(
        "SELECT relative_path,sha256,byte_count,kind FROM lc_resources WHERE resource_id=?",
    )?;
    let mut content =
        db.prepare_cached("SELECT sha256,byte_count FROM lc_contents WHERE content_id=?")?;
    use rusqlite::OptionalExtension;
    while let Some(row) = rs.next()? {
        let work: String = row.get(0)?;
        let file: Option<String> = row.get(3)?;
        let cid: Option<String> = row.get(4)?;
        let version: Option<String> = row.get(5)?;
        let rid: Option<String> = row.get(6)?;
        let source: Option<String> = row.get(11)?;
        let managed = rid
            .as_deref()
            .map(|id| {
                resource
                    .query_row([id], |s| {
                        Ok((
                            s.get::<_, String>(0)?,
                            s.get::<_, String>(1)?,
                            s.get::<_, i64>(2)?,
                            s.get::<_, String>(3)?,
                        ))
                    })
                    .optional()
            })
            .transpose()?
            .flatten();
        let original = cid
            .as_deref()
            .map(|id| {
                content
                    .query_row([id], |s| Ok((s.get::<_, String>(0)?, s.get::<_, i64>(1)?)))
                    .optional()
            })
            .transpose()?
            .flatten();
        let media_kind = managed.as_ref().map(|row| row.3.clone());
        let (path, digest, bytes, location) = if let Some((path, sha, n, _)) = managed {
            (Some(path), Some(sha), Some(n), "resource")
        } else if version.is_none() {
            let (sha, n) = original.unzip();
            (source, sha, n, "original")
        } else {
            (None, None, None, "unavailable")
        };
        let mut item = crate::discovery::Input::new(
            work.clone(),
            row.get(1)?,
            row.get(2)?,
            file,
            cid,
            version,
            rid,
            row.get(7)?,
            row.get(8)?,
            path,
            digest,
            bytes,
            location,
            row.get(10)?,
        )?;
        item.filename = row.get(12)?;
        item.media_kind = media_kind;
        let existing = result.entry(work).or_insert_with(|| item.clone());
        if existing.path.is_none() && item.path.is_some() {
            *existing = item;
        }
    }
    Ok(result.into_values().collect())
}
fn order(r: &Request) -> Vec<&'static str> {
    let mut keys = Vec::new();
    match r.sort.as_str() {
        "manual" => keys.push("manual_pos"),
        "filename" => keys.push("filename COLLATE rm_natural"),
        "ratingDescending" => keys.push("(-rating)"),
        "capturedAscending" => keys.extend(["(captured IS NULL)", "coalesce(captured,0.0)"]),
        "capturedDescending" => keys.extend(["(captured IS NULL)", "(-coalesce(captured,0.0))"]),
        _ => (),
    }
    if r.group.is_some() {
        keys.push("group_order");
    }
    if r.order_base == "store" {
        keys.push("coalesce(asset_ord,9223372036854775807)");
    } else {
        keys.extend([
            "coalesce(session_ord,9223372036854775807)",
            "coalesce(session_id,'')",
            "relative_path COLLATE rm_natural",
            "relative_path",
        ]);
    }
    keys.extend([
        "work_id",
        "coalesce(asset_id,'')",
        "project_id",
        "display_id",
    ]);
    keys
}
fn unique(rows: &[Value], key: &str) -> Vec<String> {
    let mut seen = BTreeSet::new();
    rows.iter()
        .filter_map(|m| m[key].as_str())
        .filter(|s| seen.insert(*s))
        .map(str::to_owned)
        .collect()
}
fn bucket(
    db: &Connection,
    cte: &str,
    bindings: &[Bind],
    field: &str,
    level: &str,
) -> Result<Value> {
    let (column, join) = match field {
        "tag" => ("t.display", "LEFT JOIN doc_tags t ON t.doc=h.doc"),
        "camera" => ("h.camera", ""),
        "rating" => ("h.rating", ""),
        "decision" => ("h.decision", ""),
        "availability" => ("h.availability", ""),
        "colorLabel" => ("h.color_label", ""),
        "role" => ("h.role", ""),
        "format" => ("h.format", ""),
        "review" => ("h.reviewed", ""),
        "sequenceOnly" => ("h.sequence_only", ""),
        _ => (filter::extra(field).ok_or("unsupported facet")?.0, ""),
    };
    let sql=format!("{cte} SELECT {column},count(DISTINCT h.source_file_id),count(DISTINCT h.capture_id),count(DISTINCT h.work_id)
        FROM hits h {join} GROUP BY {column} ORDER BY {column} IS NULL,{column}");
    let mut stmt = db.prepare(&sql)?;
    let mut rows = stmt.query(params_from_iter(bindings))?;
    let mut out = Vec::new();
    while let Some(row) = rows.next()? {
        let mut value = sql_value(row.get_ref(0)?)?;
        if matches!(
            field,
            "hasGPS" | "edited" | "exported" | "review" | "sequenceOnly"
        ) {
            if let Some(n) = value.as_i64() {
                value = json!(n != 0);
            }
        }
        let (files, captures, works): (i64, i64, i64) = (row.get(1)?, row.get(2)?, row.get(3)?);
        out.push(json!({"value":value,"files":files,"captures":captures,"works":works,"count":match level{"file"=>files,"capture"=>captures,_=>works}}));
    }
    Ok(json!(out))
}

pub(crate) fn page(db: &Connection, raw: &Value) -> Result<Value> {
    let r = Request::parse(raw)?;
    register(db)?;
    let (library,tip):(String,i64)=db.query_row("SELECT (SELECT value FROM lc_meta WHERE key='libraryID'),coalesce((SELECT max(seq) FROM lc_changes),0)",[],|r|Ok((r.get(0)?,r.get(1)?)))?;
    let gen = format!("work-v1:{library}");
    let fingerprint = r.fingerprint()?;
    if let Some(c) = &r.cursor {
        if c["generation"] != gen || c["watermark"] != tip || c["query"] != fingerprint {
            return Ok(
                json!({"status":"staleCursor","libraryID":library,"generation":gen,"watermark":tip}),
            );
        }
    }
    let mut b = Bindings(Vec::new());
    let cte = projected(db, &r, &mut b)?;
    let counts:(i64,i64,i64,i64,i64)=db.query_row(&format!("{cte} SELECT count(DISTINCT source_file_id),count(DISTINCT capture_id),count(DISTINCT work_id),
        count(DISTINCT display_id),count(DISTINCT CASE WHEN source_file_id IS NULL AND resource_id IS NULL THEN base_work_id END) FROM hits"),
        params_from_iter(&b.0),|x|Ok((x.get(0)?,x.get(1)?,x.get(2)?,x.get(3)?,x.get(4)?)))?;
    let keys = order(&r);
    let sort = keys.join(",");
    let mut page_b = Bindings(b.0.clone());
    let seek = if let Some(c) = &r.cursor {
        let v = c["keys"]
            .as_array()
            .filter(|a| a.len() == keys.len())
            .ok_or("invalid work cursor")?;
        let marks = v
            .iter()
            .map(|v| Ok(page_b.add(query_json(v)?)))
            .collect::<Result<Vec<_>>>()?;
        format!(" AND ({sort})>({})", marks.join(","))
    } else {
        String::new()
    };
    let limit = page_b.add((r.page_size + 1) as i64);
    let mut stmt=db.prepare(&format!("{cte} SELECT display_id,object_id,work_id,kind,base_work_id,source_file_id,capture_id,asset_id,project_id,
        display_name,filename,active_version_id,source_folder_id,volume_id,meta,record,stack_id,cover_work_id,collapsed,resource_id,job_id,content_id,
        EXISTS(SELECT 1 FROM lc_archive_files a WHERE a.file_id=candidates.source_file_id AND a.project_id=candidates.project_id AND a.path IS NOT NULL),{sort}
        FROM candidates WHERE representative=1{seek} ORDER BY {sort} LIMIT {limit}"))?;
    let mut rows = stmt.query(params_from_iter(&page_b.0))?;
    let mut items = Vec::new();
    let mut display_ids = Vec::new();
    let mut last = Vec::new();
    let mut more = false;
    while let Some(x) = rows.next()? {
        if items.len() == r.page_size {
            more = true;
            break;
        }
        let display: String = x.get(0)?;
        display_ids.push(display.clone());
        let aid: Option<String> = x.get(7)?;
        let project: String = x.get(8)?;
        let meta: Value = serde_json::from_str(&x.get::<_, String>(14)?)?;
        let asset = if aid.is_some() {
            let mut a: Value = serde_json::from_str(&x.get::<_, String>(15)?)?;
            a["projectID"] = json!(project);
            if let Some(rating) = meta.get("rating").and_then(Value::as_i64) {
                a["rating"] = json!(rating);
            }
            a
        } else {
            Value::Null
        };
        let look: Option<String> = x.get(11)?;
        let res: Option<String> = x.get(19)?;
        items.push(json!({"objectID":x.get::<_,String>(1)?,"workID":x.get::<_,String>(2)?,"kind":x.get::<_,String>(3)?,
            "masterWorkID":x.get::<_,String>(4)?,"fileID":x.get::<_,Option<String>>(5)?,"captureID":x.get::<_,Option<String>>(6)?,
            "assetID":aid,"projectID":project,"displayName":x.get::<_,String>(9)?,"filename":x.get::<_,String>(10)?,"versionID":look,
            "folderID":x.get::<_,Option<String>>(12)?,"volumeID":x.get::<_,Option<String>>(13)?,"metadata":meta,"asset":asset,
            "stackID":x.get::<_,Option<String>>(16)?,"coverWorkID":x.get::<_,Option<String>>(17)?,"collapsed":x.get::<_,Option<bool>>(18)?,
            "resourceID":res,"jobID":x.get::<_,Option<String>>(20)?,"contentID":x.get::<_,Option<String>>(21)?,"originalAvailable":x.get::<_,bool>(22)?}));
        last = (0..keys.len())
            .map(|n| sql_value(x.get_ref(23 + n)?))
            .collect::<Result<_>>()?;
    }
    drop(rows);
    drop(stmt);
    let mut map = BTreeMap::<String, Vec<Value>>::new();
    if !display_ids.is_empty() {
        let mut mb = Bindings(b.0.clone());
        let selected = mb.add(serde_json::to_string(&display_ids)?);
        let mut stmt=db.prepare(&format!("{cte} SELECT display_id,work_id,asset_id,source_file_id,capture_id,project_id FROM hits WHERE display_id IN (SELECT value FROM json_each({selected})) ORDER BY {sort}"))?;
        let mut rs = stmt.query(params_from_iter(&mb.0))?;
        while let Some(row) = rs.next()? {
            map.entry(row.get(0)?).or_default().push(json!({"workID":row.get::<_,String>(1)?,"assetID":row.get::<_,Option<String>>(2)?,
            "fileID":row.get::<_,Option<String>>(3)?,"captureID":row.get::<_,Option<String>>(4)?,"projectID":row.get::<_,String>(5)?}));
        }
    }
    for (item, key) in items.iter_mut().zip(display_ids) {
        let values = map.remove(&key).unwrap_or_default();
        item["matchedWorkIDs"] = json!(unique(&values, "workID"));
        item["matchedAssetIDs"] = json!(unique(&values, "assetID"));
        item["matchedFileIDs"] = json!(unique(&values, "fileID"));
        item["matches"] = json!(values
            .into_iter()
            .filter(|m| !m["assetID"].is_null())
            .collect::<Vec<_>>());
    }
    let mut result = json!({"status":"ok","libraryID":library,"generation":gen,"watermark":tip,"totalFiles":counts.0,"totalCaptures":counts.1,
        "totalWorks":counts.2,"total":counts.3,"offlineSources":counts.4,"items":items,"nextCursor":more.then(||json!({"generation":gen,"watermark":tip,"query":fingerprint,"keys":last}))});
    if r.include_ordered_ids {
        let mut ids = Vec::new();
        let mut seen = BTreeSet::new();
        let mut s = db.prepare(&format!(
            "{cte} SELECT asset_id FROM hits WHERE asset_id IS NOT NULL ORDER BY {sort}"
        ))?;
        for a in s.query_map(params_from_iter(&b.0), |r| r.get::<_, String>(0))? {
            let a = a?;
            if seen.insert(a.clone()) {
                ids.push(a);
            }
        }
        result["orderedAssetIDs"] = json!(ids);
        let mut s = db.prepare(&format!(
            "{cte} SELECT object_id FROM candidates WHERE representative=1 ORDER BY {sort}"
        ))?;
        let vals = s
            .query_map(params_from_iter(&b.0), |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        result["orderedObjectIDs"] = json!(vals);
    }
    if !r.facets.is_empty() {
        let mut facets = Map::new();
        for f in &r.facets {
            facets.insert(f.clone(), bucket(db, &cte, &b.0, f, &r.level)?);
        }
        result["facets"] = Value::Object(facets);
    }
    Ok(result)
}

/// Lightroom compares the migrated snapshot against the exact collection grid predicate.
pub(crate) fn collection_work_ids(db: &Connection, id: &str) -> Result<Vec<String>> {
    discovery_work_ids(db, &json!({"collectionID":id}))
}

/// Membership uses the same work projection as the grid. The common empty/project
/// scope needs only admission and organization identities, never asset JSON or media paths.
pub(crate) fn discovery_work_ids(db: &Connection, descriptor: &Value) -> Result<Vec<String>> {
    let r = discovery_request(descriptor)?;
    let simple = descriptor.as_object().is_some_and(|m| {
        m.iter().all(|(key, value)| match key.as_str() {
            "level" | "projectID" => true,
            "query" => value.as_object().is_some_and(|q| q.is_empty()),
            _ => false,
        })
    });
    if simple {
        let mut stmt=db.prepare_cached("SELECT v.work_id FROM lc_org_visible_sources v WHERE
            (v.source_file_id IS NULL AND (?1 IS NULL OR coalesce(v.work_project_id,'')=?1)) OR
            (v.source_file_id IS NOT NULL AND EXISTS(SELECT 1 FROM lc_catalog_files f WHERE f.file_id=v.source_file_id
                AND (v.work_project_id IS NULL OR v.work_project_id=f.project_id) AND (?1 IS NULL OR f.project_id=?1)))
            ORDER BY v.work_id")?;
        let rows = stmt.query_map([r.project.as_deref()], |row| row.get(0))?;
        return Ok(rows.collect::<rusqlite::Result<_>>()?);
    }
    register(db)?;
    let mut bindings = Bindings(Vec::new());
    let cte = projected(db, &r, &mut bindings)?;
    let mut stmt = db.prepare(&format!(
        "{cte} SELECT DISTINCT work_id FROM hits ORDER BY work_id"
    ))?;
    let rows = stmt.query_map(params_from_iter(&bindings.0), |r| r.get::<_, String>(0))?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}
