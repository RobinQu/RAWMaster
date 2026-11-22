use super::text;
use crate::Result;
use rusqlite::types::Value as Bind;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

#[derive(Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct Query {
    filename: String,
    text: String,
    camera: Option<String>,
    captured_from: Option<f64>,
    captured_before: Option<f64>,
    minimum_rating: Option<i64>,
    maximum_rating: Option<i64>,
    tags: Vec<String>,
    tag_match: Option<String>,
    decision: Option<String>,
    availability: Option<String>,
    review: Option<String>,
    color_label: Option<String>,
    format: Option<String>,
    role: Option<String>,
    sequence_only: Option<bool>,
    time_zone_identifier: Option<String>,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Request {
    #[serde(default, rename = "projectID")]
    pub project: Option<String>,
    #[serde(default, rename = "sessionID")]
    pub session: Option<String>,
    #[serde(default, rename = "groupID")]
    pub group: Option<String>,
    #[serde(default, rename = "collectionID")]
    pub collection: Option<String>,
    #[serde(default, rename = "folderID")]
    pub folder: Option<String>,
    #[serde(default, rename = "volumeID")]
    pub volume: Option<String>,
    #[serde(default, rename = "workID")]
    pub work: Option<String>,
    #[serde(default = "yes")]
    pub include_descendants: bool,
    #[serde(default)]
    pub collapse_stacks: bool,
    #[serde(default = "file")]
    pub level: String,
    #[serde(default = "original")]
    pub sort: String,
    #[serde(default = "browser")]
    pub order_base: String,
    #[serde(default)]
    pub query: Query,
    #[serde(default)]
    pub predicate: Option<Value>,
    #[serde(default = "first_page", skip_serializing)]
    pub page_size: usize,
    #[serde(default, skip_serializing)]
    pub cursor: Option<Value>,
    #[serde(default, skip_serializing, rename = "includeOrderedIDs")]
    pub include_ordered_ids: bool,
    #[serde(default, skip_serializing)]
    pub facets: Vec<String>,
}
fn file() -> String {
    "file".into()
}
fn yes() -> bool {
    true
}
pub(super) fn extra(field: &str) -> Option<(&'static str, &'static str)> {
    Some(match field {
        "lens" => ("lens", "text"),
        "iso" => ("iso", "number"),
        "aperture" => ("aperture", "number"),
        "shutterSeconds" => ("shutter_seconds", "number"),
        "focalLength" => ("focal_length", "number"),
        "exposureCompensation" => ("exposure_compensation", "number"),
        "width" => ("width", "number"),
        "height" => ("height", "number"),
        "latitude" => ("latitude", "number"),
        "longitude" => ("longitude", "number"),
        "place" => ("place", "text"),
        "title" => ("title", "text"),
        "caption" => ("caption", "text"),
        "creator" => ("creator", "text"),
        "copyright" => ("copyright", "text"),
        "flag" => ("flag", "text"),
        "colorSpace" => ("color_space", "text"),
        "focusMachine" => ("focus_machine", "text"),
        "focusManual" => ("focus_manual", "text"),
        "focusEffective" => ("focus_effective", "text"),
        "edited" => ("edited", "bool"),
        "exported" => ("exported", "bool"),
        "kind" => ("kind", "text"),
        "hasGPS" => ("has_gps", "bool"),
        "name" => ("name_key", "text"),
        _ => return None,
    })
}
fn original() -> String {
    "original".into()
}
fn browser() -> String {
    "browser".into()
}
fn first_page() -> usize {
    60
}
const FACETS: &[&str] = &[
    "camera",
    "rating",
    "decision",
    "availability",
    "colorLabel",
    "review",
    "format",
    "role",
    "tag",
    "sequenceOnly",
];
impl Request {
    pub fn parse(v: &Value) -> Result<Self> {
        let r: Self = serde_json::from_value(v.clone())?;
        let q = &r.query;
        if !matches!(r.level.as_str(), "file" | "capture" | "work")
            || !matches!(r.order_base.as_str(), "browser" | "store")
            || !matches!(
                r.sort.as_str(),
                "original"
                    | "manual"
                    | "filename"
                    | "capturedAscending"
                    | "capturedDescending"
                    | "ratingDescending"
            )
        {
            return Err("unknown catalog query level or sort".into());
        }
        if !(1..=500).contains(&r.page_size)
            || r.facets
                .iter()
                .any(|s| !FACETS.contains(&s.as_str()) && extra(s).is_none())
            || r.facets.len() > 40
        {
            return Err("invalid page size or facet".into());
        }
        if q.filename.chars().count() > 1024
            || q.text.chars().count() > 1024
            || q.tags.len() > 100
            || q.tags.iter().any(|s| s.chars().count() > 128)
            || q.minimum_rating.is_some_and(|r| !(0..=5).contains(&r))
            || q.maximum_rating.is_some_and(|r| !(0..=5).contains(&r))
            || matches!((q.minimum_rating,q.maximum_rating),(Some(a),Some(b)) if a>b)
            || matches!((q.captured_from,q.captured_before),(Some(a),Some(b)) if a>=b)
        {
            return Err("invalid search criteria".into());
        }
        if !matches!(q.tag_match.as_deref(), None | Some("any" | "all"))
            || !matches!(
                q.review.as_deref(),
                None | Some("all" | "reviewed" | "unreviewed")
            )
        {
            return Err("invalid tag/review mode".into());
        }
        if q.time_zone_identifier.as_deref() == Some("") {
            return Err("empty query time zone".into());
        }
        Ok(r)
    }
    pub fn fingerprint(&self) -> Result<String> {
        Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(self)?)))
    }
}

pub(super) struct Matched {
    pub cte: String,
    pub select: String,
    pub binds: Vec<Bind>,
    pub tally_scope: Option<String>,
}
struct Where {
    values: Vec<Bind>,
    terms: Vec<String>,
    fts: bool,
}
impl Where {
    fn bind(&mut self, v: impl Into<Bind>) -> String {
        self.values.push(v.into());
        format!("?{}", self.values.len())
    }
    fn compare(&mut self, col: &str, op: &str, value: impl Into<Bind>) -> String {
        let p = self.bind(value);
        format!("d.{col} {op} {p}")
    }
    fn add(&mut self, col: &str, op: &str, value: impl Into<Bind>) {
        let term = self.compare(col, op, value);
        self.terms.push(term);
    }
    fn substring(&mut self, col: &str, needle: &str) -> String {
        let needle = text::searchable(needle);
        let exact = self.bind(needle.clone());
        let exact = format!("instr(d.{col},{exact})>0");
        if !self.fts || needle.contains('\0') || needle.chars().count() < 3 {
            return exact;
        }
        let fts_column = if col == "name_key" { "name" } else { "body" };
        let literal = needle.replace('"', "\"\"");
        let token = self.bind(format!("{fts_column} : \"{literal}\""));
        format!(
            "(d.doc IN (SELECT rowid FROM search_fts WHERE search_fts MATCH {token}) AND {exact})"
        )
    }
    fn tag(&mut self, value: &str) -> String {
        let key = self.bind(text::tag_key(value.trim()));
        format!("EXISTS(SELECT 1 FROM doc_tags t WHERE t.doc=d.doc AND t.key={key})")
    }
    fn predicate(&mut self, v: &Value, depth: usize, nodes: &mut usize) -> Result<String> {
        *nodes += 1;
        if depth > 10 || *nodes > 160 {
            return Err("search predicate is too large".into());
        }
        let object = v.as_object().ok_or("expected a predicate object")?;
        for (key, join) in [("all", " AND "), ("any", " OR ")] {
            if let Some(children) = object.get(key) {
                let values = children
                    .as_array()
                    .ok_or("predicate children must be an array")?;
                if object.len() != 1 || values.is_empty() {
                    return Err("expected a nonempty predicate group".into());
                }
                let terms = values
                    .iter()
                    .map(|p| self.predicate(p, depth + 1, nodes))
                    .collect::<Result<Vec<_>>>()?;
                return Ok(format!("({})", terms.join(join)));
            }
        }
        if let Some(child) = object.get("not") {
            if object.len() != 1 {
                return Err("unexpected negated predicate fields".into());
            }
            return Ok(format!(
                "NOT coalesce(({}),0)",
                self.predicate(child, depth + 1, nodes)?
            ));
        }
        let field = v["field"].as_str().ok_or("expected predicate field")?;
        let op = v["op"].as_str().ok_or("expected predicate operator")?;
        if object
            .keys()
            .any(|s| !matches!(s.as_str(), "field" | "op" | "value"))
        {
            return Err("unknown predicate property".into());
        }
        let col = match field {
            "filename" => "name_key",
            "text" => "body",
            "camera" => "camera_key",
            "capturedAt" => "captured",
            "rating" => "rating",
            "decision" => "decision",
            "availability" => "availability",
            "reviewed" => "reviewed",
            "colorLabel" => "color_label",
            "format" => "format",
            "role" => "role",
            "sequenceOnly" => "sequence_only",
            "tag" => "tag",
            _ => {
                extra(field)
                    .ok_or_else(|| format!("unsupported search field {field}"))?
                    .0
            }
        };
        if matches!(op, "missing" | "present") {
            if object.contains_key("value") {
                return Err("unexpected value for presence predicate".into());
            }
            let has = if col == "tag" {
                "EXISTS(SELECT 1 FROM doc_tags t WHERE t.doc=d.doc)".to_owned()
            } else {
                format!("d.{col} IS NOT NULL")
            };
            return Ok(if op == "missing" {
                format!("NOT ({has})")
            } else {
                has
            });
        }
        let value = object.get("value").ok_or("missing predicate value")?;
        if col == "tag" && matches!(op, "eq" | "ne") {
            let tag = self.tag(value.as_str().ok_or("expected tag text")?);
            return Ok(if op == "ne" {
                format!("NOT ({tag})")
            } else {
                tag
            });
        }
        if op == "contains" && extra(field).is_some_and(|(_, k)| k == "text") && col != "name_key" {
            let p = self.bind(text::searchable(
                value.as_str().ok_or("expected predicate text")?,
            ));
            return Ok(format!("instr(rm_org_fold(d.{col}),{p})>0"));
        }
        if op == "contains" && matches!(col, "name_key" | "body") {
            return Ok(self.substring(col, value.as_str().ok_or("expected substring")?));
        }
        let sql_op = match op {
            "eq" => "=",
            "ne" => "!=",
            "gt" | "gte" | "lt" | "lte"
                if matches!(col, "rating" | "captured")
                    || extra(field).is_some_and(|(_, k)| k == "number") =>
            {
                match op {
                    "gt" => ">",
                    "gte" => ">=",
                    "lt" => "<",
                    _ => "<=",
                }
            }
            _ => return Err("unsupported comparison".into()),
        };
        let value = match col {
            "rating" => Bind::Integer(
                value
                    .as_i64()
                    .filter(|n| (0..=5).contains(n))
                    .ok_or("expected rating from 0 to 5")?,
            ),
            "captured" => Bind::Real(
                value
                    .as_f64()
                    .ok_or("expected a Foundation reference date in seconds")?,
            ),
            "reviewed" | "sequence_only" => {
                Bind::Integer(value.as_bool().ok_or("expected Boolean")? as i64)
            }
            "tag" => return Err("unsupported tag predicate".into()),
            _ if extra(field).is_some_and(|(_, k)| k == "number") => {
                Bind::Real(value.as_f64().ok_or("expected numeric predicate")?)
            }
            _ if extra(field).is_some_and(|(_, k)| k == "bool") => {
                Bind::Integer(value.as_bool().ok_or("expected boolean predicate")? as i64)
            }
            _ => {
                let s = value.as_str().ok_or("expected predicate text")?;
                Bind::Text(match col {
                    "name_key" | "body" | "camera_key" => text::searchable(s),
                    "format" => s.to_ascii_lowercase(),
                    _ => s.to_owned(),
                })
            }
        };
        Ok(self.compare(col, sql_op, value))
    }
}

pub(super) fn matching(r: &Request, gen: i64, fts: bool) -> Result<Matched> {
    let mut w = Where {
        values: Vec::new(),
        terms: Vec::new(),
        fts,
    };
    w.add("gen", "=", gen);
    if let Some(p) = &r.project {
        w.add("project_id", "=", p.clone());
    }
    let fixed = w.terms.len();
    if let Some(s) = &r.session {
        w.add("session_id", "=", s.clone());
    }
    let (extra_col, group_join) = if let Some(group) = &r.group {
        let id = w.bind(group.clone());
        (
            ",g.position AS group_order",
            format!("JOIN doc_groups g ON g.doc=d.doc AND g.group_id={id}"),
        )
    } else {
        ("", String::new())
    };
    let q = &r.query;
    for (col, value) in [("name_key", &q.filename), ("body", &q.text)] {
        if !value.trim().is_empty() {
            let term = w.substring(col, value.trim());
            w.terms.push(term);
        }
    }
    if let Some(c) = q
        .camera
        .as_deref()
        .map(|s| s.trim_matches(|c: char| c.is_whitespace() || c.is_control()))
        .filter(|s| !s.is_empty())
    {
        w.add("camera_key", "=", text::searchable(c));
    }
    if let Some(low) = q.minimum_rating {
        w.add("rating", ">=", low);
    }
    if let Some(high) = q.maximum_rating {
        w.add("rating", "<=", high);
    }
    if let Some(start) = q.captured_from {
        w.add("captured", ">=", start);
    }
    if let Some(end) = q.captured_before {
        w.add("captured", "<", end);
    }
    for (col, v) in [
        ("decision", &q.decision),
        ("availability", &q.availability),
        ("color_label", &q.color_label),
    ] {
        if let Some(v) = v {
            w.add(col, "=", v.clone());
        }
    }
    if let Some(f) = &q.format {
        w.add(
            "format",
            "=",
            f.trim_start_matches('.').to_ascii_lowercase(),
        );
    }
    if let Some(role) = &q.role {
        w.add("role", "=", role.to_ascii_lowercase());
    }
    if let Some(s) = q.sequence_only {
        w.add("sequence_only", "=", s as i64);
    }
    if let Some(review @ ("reviewed" | "unreviewed")) = q.review.as_deref() {
        w.add("reviewed", "=", (review == "reviewed") as i64);
    }
    let tags = q
        .tags
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(text::tag_key)
        .collect::<BTreeSet<_>>();
    if !tags.is_empty() {
        let join = if q.tag_match.as_deref() == Some("any") {
            " OR "
        } else {
            " AND "
        };
        let terms = tags.iter().map(|v| w.tag(v)).collect::<Vec<_>>();
        w.terms.push(format!("({})", terms.join(join)));
    }
    if let Some(p) = &r.predicate {
        let t = w.predicate(p, 0, &mut 0)?;
        w.terms.push(t);
    }
    let tally_scope = (w.terms.len() == fixed && r.group.is_none()).then(|| {
        r.project
            .as_ref()
            .map_or_else(|| "L".into(), |p| format!("P{p}"))
    });
    let select = format!(
        "SELECT d.*{extra_col} FROM documents d {group_join} WHERE {}",
        w.terms.join(" AND ")
    );
    Ok(Matched {
        cte: format!("WITH matched AS NOT MATERIALIZED ({select})"),
        select,
        binds: w.values,
        tally_scope,
    })
}
