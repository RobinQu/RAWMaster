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

/// Called inside the very same write transaction as the host bulk mutation.
pub fn check(db: &Connection, body: &Value) -> Result<Value> {
    let scope: Selection = serde_json::from_value(body.clone())?;
    let (library, cutoff): (String, i64) = db.query_row(
        "SELECT value,(SELECT COALESCE(MAX(seq),0) FROM lc_changes) FROM lc_meta WHERE key='libraryID'",
        [], |r| Ok((r.get(0)?, r.get(1)?)))?;
    if scope.library_id != library || scope.watermark != cutoff {
        return Err("The selected catalog revision has changed".into());
    }
    let mut seen = BTreeSet::new();
    let mut st = db.prepare_cached(
        "SELECT EXISTS(SELECT 1 FROM lc_scopes s JOIN assets a ON a.id=s.asset_id
        WHERE s.asset_id=?1 AND (?2 IS NULL OR s.project_id=?2))",
    )?;
    for id in &scope.asset_ids {
        if !seen.insert(id)
            || !st.query_row(params![id, scope.project_id], |r| r.get::<_, bool>(0))?
        {
            return Err("The frozen selection contains a repeated or ineligible member".into());
        }
    }
    Ok(json!({"count": seen.len(), "watermark": cutoff, "libraryID": library}))
}
