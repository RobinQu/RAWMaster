use crate::Result;
use rusqlite::{params, Connection};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Selection {
    #[serde(rename = "libraryID")]
    library_id: String,
    watermark: i64,
    #[serde(rename = "projectID", default)]
    project_id: Option<String>,
    #[serde(rename = "assetIDs")]
    asset_ids: Vec<String>,
}

/// The caller holds a single snapshot for the revision, membership, and subsequent reads or writes.
pub fn resolve(db: &Connection, body: &Value) -> Result<Value> {
    let scope: Selection = serde_json::from_value(body.clone())?;
    let (library, cutoff): (String, i64) = db.query_row(
        "SELECT value,(SELECT COALESCE(MAX(seq),0) FROM lc_changes) FROM lc_meta WHERE key='libraryID'",
        [], |r| Ok((r.get(0)?, r.get(1)?)))?;
    if scope.library_id != library || !(0..=cutoff).contains(&scope.watermark) {
        return Ok(Value::Null);
    }
    if scope.watermark < cutoff {
        // v8–v10 journal a per-file row when the project saves its browsing position.
        // Accept only a complete interval of these rows; a gap or a content edit is stale.
        let browse_rows: i64 = db.query_row(
            "SELECT count(*) FROM lc_changes WHERE seq>?1 AND seq<=?2 AND domain='project_review_states'",
            params![scope.watermark, cutoff], |r| r.get(0),
        )?;
        if browse_rows != cutoff - scope.watermark {
            return Ok(Value::Null);
        }
    }
    let mut seen = BTreeSet::new();
    let mut st = db.prepare_cached(
        "SELECT EXISTS(SELECT 1 FROM lc_scopes s JOIN assets a ON a.id=s.asset_id
        WHERE s.asset_id=?1 AND (?2 IS NULL OR s.project_id=?2)
        )",
    )?;
    for id in &scope.asset_ids {
        if !seen.insert(id) {
            return Err("The frozen selection contains a repeated member".into());
        }
        if st.query_row(params![id, scope.project_id], |r| r.get::<_, bool>(0))? {
            continue;
        }
        let eligible: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM lc_org_works w JOIN editing_works e ON e.id=w.work_id
             JOIN lc_scopes s ON s.asset_id=e.asset_id AND s.project_id=e.project_id
             WHERE w.work_id=?1 AND w.kind='virtual' AND json_extract(e.data,'$.virtualCopyID')=w.work_id
             AND coalesce(json_extract(w.metadata_json,'$.rawmasterCopyRemoved'),0)=0
             AND (?2 IS NULL OR e.project_id=?2))",params![id,scope.project_id], |r| r.get(0))?;
        if !eligible {
            return Err("The frozen selection contains an ineligible member".into());
        }
    }
    Ok(json!({"count": seen.len(), "watermark": cutoff, "libraryID": library}))
}

pub fn check(db: &Connection, body: &Value) -> Result<Value> {
    let result = resolve(db, body)?;
    if result.is_null() {
        return Err("The selected catalog revision has changed".into());
    }
    Ok(result)
}
