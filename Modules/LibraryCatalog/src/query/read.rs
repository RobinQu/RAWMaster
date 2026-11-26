use super::{
    filter::{self, Matched, Request},
    index::State,
};
use crate::Result;
use rusqlite::{
    params, params_from_iter,
    types::{Value as Bind, ValueRef},
    Connection, OptionalExtension,
};
use serde_json::{json, Map, Value};
use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    sync::{Mutex, OnceLock},
};

fn scalar(value: ValueRef<'_>) -> Result<Value> {
    Ok(match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(v) => json!(v),
        ValueRef::Real(v) => json!(v),
        ValueRef::Text(v) => json!(std::str::from_utf8(v)?),
        ValueRef::Blob(_) => return Err("unexpected binary search key".into()),
    })
}
fn bind_key(column: &str, v: &Value) -> Result<Bind> {
    let numeric = matches!(
        column,
        "x.asset_ord"
            | "x.session_ord"
            | "x.group_order"
            | "x.missing_time"
            | "x.time_asc"
            | "x.time_desc"
            | "x.rating_desc"
    );
    match v {
        Value::String(s) if !numeric => Ok(Bind::Text(s.clone())),
        Value::Number(n) if numeric => n
            .as_i64()
            .map(Bind::Integer)
            .or_else(|| n.as_f64().map(Bind::Real))
            .ok_or_else(|| "invalid numeric cursor key".into()),
        _ => Err("invalid search cursor key".into()),
    }
}
fn order(r: &Request) -> Vec<&'static str> {
    let mut keys = Vec::new();
    match r.sort.as_str() {
        "filename" => keys.push("x.filename COLLATE rm_natural"),
        "capturedAscending" => keys.extend(["x.missing_time", "x.time_asc"]),
        "capturedDescending" => keys.extend(["x.missing_time", "x.time_desc"]),
        "ratingDescending" => keys.push("x.rating_desc"),
        _ => (),
    }
    if r.group.is_some() {
        keys.push("x.group_order");
    }
    if r.order_base == "store" {
        keys.push("x.asset_ord");
    } else {
        keys.extend([
            "x.session_ord",
            "x.session_id",
            "x.relative_path COLLATE rm_natural",
            "x.path_tie",
        ]);
    }
    keys.extend(["x.asset_id", "x.project_id", "x.file_id"]);
    keys
}
fn representative(r: &Request, object: &str) -> String {
    // A (project, file) already has exactly one row in the authority. Across
    // projects or at capture level choose only from fully matching occurrences.
    if r.project.is_some() && r.level == "file" {
        return "1".into();
    }
    format!(
        "NOT EXISTS(SELECT 1 FROM matched other WHERE other.{object}=x.{object}
        AND (other.asset_id,other.project_id,other.file_id)<(x.asset_id,x.project_id,x.file_id))"
    )
}
type CountCache = Mutex<VecDeque<(String, (i64, i64))>>;
static FILTER_COUNTS: OnceLock<CountCache> = OnceLock::new();

fn counts(db: &Connection, state: &State, m: &Matched, fingerprint: &str) -> Result<(i64, i64)> {
    if let Some(scope) = &m.tally_scope {
        return Ok(db
            .query_row(
                "SELECT files,captures FROM scope_counts WHERE gen=? AND scope=?",
                params![state.gen, scope],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .unwrap_or((0, 0)));
    }
    // An expensive exact filtered count is computed once per published query
    // revision. A cursor never supplies counts, and this bounded cache holds no
    // photo records, query text or file paths.
    let key = format!("{}:{}:{}", state.token, state.watermark, fingerprint);
    let cache = FILTER_COUNTS.get_or_init(Mutex::default);
    if let Ok(cache) = cache.lock() {
        if let Some((_, counts)) = cache.iter().find(|(k, _)| k == &key) {
            return Ok(*counts);
        }
    }
    let value = db.query_row(
        &format!(
            "{} SELECT count(DISTINCT file_id),count(DISTINCT capture_id) FROM matched",
            m.cte
        ),
        params_from_iter(&m.binds),
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if let Ok(mut cache) = cache.lock() {
        if cache.len() >= 128 {
            cache.pop_front();
        }
        cache.push_back((key, value));
    }
    Ok(value)
}
fn facets(db: &Connection, m: &Matched, r: &Request) -> Result<Value> {
    let mut result = Map::new();
    for name in &r.facets {
        let (key, display, join) = match name.as_str() {
            "tag" => (
                "t.key",
                "min(t.display)",
                "LEFT JOIN doc_tags t ON t.doc=x.doc",
            ),
            "camera" => ("x.camera_key", "min(x.camera)", ""),
            "rating" => ("x.rating", "x.rating", ""),
            "decision" => ("x.decision", "x.decision", ""),
            "availability" => ("x.availability", "x.availability", ""),
            "colorLabel" => ("x.color_label", "x.color_label", ""),
            "review" => ("x.reviewed", "x.reviewed", ""),
            "format" => ("x.format", "x.format", ""),
            "role" => ("x.role", "x.role", ""),
            "sequenceOnly" => ("x.sequence_only", "x.sequence_only", ""),
            _ => return Err("unsupported search facet".into()),
        };
        let sql = format!(
            "{} SELECT {display},count(DISTINCT x.file_id),count(DISTINCT x.capture_id)
            FROM matched x {join} GROUP BY {key} ORDER BY {key} IS NULL,{key}",
            m.cte
        );
        let mut stmt = db.prepare(&sql)?;
        let mut rows = stmt.query(params_from_iter(&m.binds))?;
        let mut values = Vec::new();
        while let Some(row) = rows.next()? {
            let value = if name == "review" || name == "sequenceOnly" {
                json!(row.get::<_, bool>(0)?)
            } else {
                scalar(row.get_ref(0)?)?
            };
            let files: i64 = row.get(1)?;
            let captures: i64 = row.get(2)?;
            values.push(json!({"value":value,"files":files,"captures":captures,"count":if r.level=="file"{files}else{captures}}));
        }
        result.insert(name.clone(), Value::Array(values));
    }
    Ok(Value::Object(result))
}
fn ordered_ids(
    db: &Connection,
    m: &Matched,
    column: &str,
    guard: &str,
    order: &str,
) -> Result<Vec<String>> {
    let sql = format!(
        "{} SELECT x.{column} FROM matched x WHERE {guard} ORDER BY {order}",
        m.cte
    );
    let mut stmt = db.prepare(&sql)?;
    let mut rows = stmt.query(params_from_iter(&m.binds))?;
    let mut seen = HashSet::new();
    let mut ids = Vec::new();
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        if seen.insert(id.clone()) {
            ids.push(id);
        }
    }
    Ok(ids)
}
struct Card {
    id: String,
    asset: String,
    file: String,
    capture: String,
    project: String,
    record: Value,
}

fn page_members(
    db: &Connection,
    m: &Matched,
    object: &str,
    order: &str,
    cards: &[Card],
) -> Result<BTreeMap<String, Vec<Value>>> {
    let mut members = BTreeMap::<String, Vec<Value>>::new();
    if cards.is_empty() {
        return Ok(members);
    }
    let ids = serde_json::to_string(&cards.iter().map(|c| &c.id).collect::<Vec<_>>())?;
    let mut binds = m.binds.clone();
    binds.push(Bind::Text(ids));
    let sql = format!(
        "{} SELECT x.{object},x.asset_id,x.file_id,x.capture_id,x.project_id FROM matched x
        WHERE x.{object} IN (SELECT value FROM json_each(?{})) ORDER BY {order}",
        m.cte,
        binds.len()
    );
    let mut stmt = db.prepare(&sql)?;
    let mut rows = stmt.query(params_from_iter(&binds))?;
    while let Some(row) = rows.next()? {
        members.entry(row.get(0)?).or_default().push(json!({
            "assetID":row.get::<_,String>(1)?, "fileID":row.get::<_,String>(2)?,
            "captureID":row.get::<_,String>(3)?, "projectID":row.get::<_,String>(4)?
        }));
    }
    Ok(members)
}
fn unique_member_ids(rows: &[Value], field: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    rows.iter()
        .filter_map(|m| m[field].as_str())
        .filter(|v| seen.insert(*v))
        .map(str::to_owned)
        .collect()
}

pub(super) struct FacetWrite {
    pub fingerprint: String,
    pub names: String,
    pub payload: String,
}

pub(super) fn run(
    db: &Connection,
    state: &State,
    r: &Request,
) -> Result<(Value, Option<FacetWrite>)> {
    let hash = r.fingerprint()?;
    let object = if r.level == "file" {
        "file_id"
    } else {
        "capture_id"
    };
    let sort = order(r);
    let cursor = r.cursor.as_ref();
    if let Some(cursor) = cursor {
        if cursor["generation"].as_str() != Some(&state.token)
            || cursor["watermark"].as_i64() != Some(state.watermark)
            || cursor["query"].as_str() != Some(&hash)
        {
            return Ok((
                json!({"status":"staleCursor","generation":state.token,"watermark":state.watermark,"libraryID":state.library}),
                None,
            ));
        }
    }
    let fts: filter::Fts = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='search_fts'),
                EXISTS(SELECT 1 FROM sqlite_schema WHERE name='search_cjk')",
        [],
        |r| {
            Ok(filter::Fts {
                trigram: r.get(0)?,
                cjk: r.get(1)?,
            })
        },
    )?;
    let m = filter::matching(r, state.gen, fts)?;
    let facet_key = if r.facets.is_empty() {
        None
    } else {
        let mut names = r.facets.clone();
        names.sort();
        Some(names.join(","))
    };
    let cached_facets: Option<String> = match &facet_key {
        Some(names) => db
            .query_row(
                "SELECT payload FROM facet_cache
                 WHERE gen=? AND watermark=? AND fingerprint=? AND names=?",
                params![state.gen, state.watermark, hash, names],
                |row| row.get(0),
            )
            .optional()?,
        None => None,
    };
    let (file_count, capture_count) = counts(db, state, &m, &hash)?;
    let ordered = sort.join(",");
    let guard = representative(r, object);
    let mut seek = String::new();
    let mut binds = m.binds.clone();
    if let Some(c) = cursor {
        let values = c["keys"]
            .as_array()
            .filter(|v| v.len() == sort.len())
            .ok_or("invalid search cursor key count")?;
        let mut placeholders = Vec::new();
        for (column, key) in sort.iter().zip(values) {
            binds.push(bind_key(column, key)?);
            placeholders.push(format!("?{}", binds.len()));
        }
        seek = format!(" AND ({ordered})>({})", placeholders.join(","));
    }
    binds.push(Bind::Integer((r.page_size + 1) as i64));
    let sql = format!(
        "{} SELECT x.{object},x.asset_id,x.file_id,x.capture_id,x.project_id,x.record,{ordered}
        FROM matched x WHERE {guard}{seek} ORDER BY {ordered} LIMIT ?{}",
        m.cte,
        binds.len()
    );
    let mut stmt = db.prepare(&sql)?;
    let mut rows = stmt.query(params_from_iter(&binds))?;
    let mut cards = Vec::new();
    let mut last_keys = Vec::new();
    let mut has_more = false;
    while let Some(row) = rows.next()? {
        if cards.len() == r.page_size {
            has_more = true;
            break;
        }
        cards.push(Card {
            id: row.get(0)?,
            asset: row.get(1)?,
            file: row.get(2)?,
            capture: row.get(3)?,
            project: row.get(4)?,
            record: serde_json::from_str(&row.get::<_, String>(5)?)?,
        });
        last_keys = (0..sort.len())
            .map(|i| scalar(row.get_ref(6 + i)?))
            .collect::<Result<_>>()?;
    }
    drop(rows);
    drop(stmt);
    let mut members = page_members(db, &m, object, &ordered, &cards)?;
    let mut items = Vec::with_capacity(cards.len());
    for card in cards {
        let matched = members
            .remove(&card.id)
            .ok_or("projected card lost its matching member")?;
        items.push(json!({"objectID":card.id,"assetID":card.asset,"fileID":card.file,"captureID":card.capture,"projectID":card.project,
            "asset":card.record,"matchedAssetIDs":unique_member_ids(&matched,"assetID"),
            "matchedFileIDs":unique_member_ids(&matched,"fileID"),"matches":matched}));
    }
    let next=has_more.then(||json!({"generation":state.token,"watermark":state.watermark,"query":hash,"keys":last_keys}));
    let mut result = json!({"status":"ok","libraryID":state.library,"generation":state.token,"watermark":state.watermark,
        "totalFiles":file_count,"totalCaptures":capture_count,"total":if r.level=="file"{file_count}else{capture_count},
        "items":items,"nextCursor":next});
    if r.include_ordered_ids {
        result["orderedAssetIDs"] = json!(ordered_ids(db, &m, "asset_id", "1", &ordered)?);
        result["orderedObjectIDs"] = json!(ordered_ids(db, &m, object, &guard, &ordered)?);
    }
    let mut facet_write = None;
    if !r.facets.is_empty() {
        if let Some(payload) = cached_facets {
            result["facets"] = serde_json::from_str(&payload)?;
        } else {
            let value = facets(db, &m, r)?;
            result["facets"] = value;
            if let Some(names) = facet_key {
                facet_write = Some(FacetWrite {
                    fingerprint: hash,
                    names,
                    payload: serde_json::to_string(&result["facets"])?,
                });
            }
        }
    }
    Ok((result, facet_write))
}
