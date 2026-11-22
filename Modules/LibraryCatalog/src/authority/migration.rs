use super::*;
use std::collections::{BTreeMap, BTreeSet};

pub(super) const LEGACY_REFERENCE: &str = include_str!("legacy_v7_reference.sql");

pub(super) fn report(db: &Connection, domain: &str, id: &str, reason: &str) -> Result<()> {
    db.execute(
        "INSERT OR IGNORE INTO lc_reconciliation VALUES(?1,?2,?3)",
        params![domain, id, reason],
    )?;
    Ok(())
}
fn strings(v: &Value, k: &str) -> Result<BTreeSet<String>> {
    array(v, k)?
        .iter()
        .map(|x| {
            x.as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| "invalid legacy member ID".into())
        })
        .collect()
}
#[derive(PartialEq, Eq)]
struct Completion {
    project: String,
    admitted: BTreeSet<String>,
    excluded: BTreeSet<String>,
    sequence: BTreeSet<String>,
}
struct History {
    completed: BTreeMap<String, (String, Completion)>,
    ambiguous: BTreeSet<String>,
    restored: BTreeMap<(String, String), String>,
}
fn history(db: &Connection) -> Result<History> {
    let mut h = History {
        completed: BTreeMap::new(),
        ambiguous: BTreeSet::new(),
        restored: BTreeMap::new(),
    };
    let mut st=db.prepare("SELECT id,data FROM workflow_completions UNION ALL SELECT id,payload FROM operations WHERE action='completeTriage' AND payload_version=1")?;
    let mut rows = st.query([])?;
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        let v: Value = serde_json::from_str(&row.get::<_, String>(1)?)?;
        let session = field(&v, "sessionID")?.to_string();
        let item = Completion {
            project: field(&v, "projectID")?.into(),
            admitted: strings(&v, "admittedAssetIDs")?,
            excluded: strings(&v, "excludedAssetIDs")?,
            sequence: strings(&v, "sequenceOnlyAssetIDs")?,
        };
        if !item.admitted.is_disjoint(&item.excluded)
            || !item.sequence.is_subset(&item.admitted)
            || h.completed.get(&session).is_some_and(|(_, c)| *c != item)
        {
            h.ambiguous.insert(session.clone());
            report(db, "session", &session, "conflicting completion evidence")?;
        }
        h.completed.entry(session).or_insert((id, item));
    }
    let mut st=db.prepare("SELECT id,entity_id,payload FROM operations WHERE action='restoreTriageAssets' AND payload_version=1 ORDER BY rowid")?;
    let mut rows = st.query([])?;
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        let session: String = row.get(1)?;
        let v: Value = serde_json::from_str(&row.get::<_, String>(2)?)?;
        if let Some(items) = v.as_array() {
            for item in items {
                if let Some(asset) = item.as_str() {
                    h.restored
                        .insert((session.clone(), asset.to_string()), id.clone());
                }
            }
        } else {
            report(
                db,
                "operation",
                &id,
                "unrecognized recovery payload retained in operations",
            )?;
        }
    }
    Ok(h)
}
fn import_pairs(db: &Connection) -> Result<BTreeSet<String>> {
    let mut paired = BTreeSet::new();
    let mut conflicts=db.prepare("SELECT asset FROM (SELECT json_extract(data,'$.rawAssetID') AS asset FROM capture_pairs UNION ALL SELECT json_extract(data,'$.jpegAssetID') FROM capture_pairs) GROUP BY asset HAVING count(*)>1")?;
    let repeated = conflicts
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<BTreeSet<String>>>()?;
    let mut st = db.prepare("SELECT id,data FROM capture_pairs ORDER BY rowid")?;
    let mut rows = st.query([])?;
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        let pair: Value = serde_json::from_str(&row.get::<_, String>(1)?)?;
        let raw = field(&pair, "rawAssetID")?;
        let jpeg = field(&pair, "jpegAssetID")?;
        let pair_key = if raw < jpeg {
            format!("{raw}:{jpeg}")
        } else {
            format!("{jpeg}:{raw}")
        };
        let candidates:Option<(String,String,String,String,String,String)>=db.query_row("SELECT x.file_id,y.file_id,x.role,y.role,x.capture_id,y.capture_id FROM lc_files x,lc_files y WHERE x.file_id=?1 AND y.file_id=?2",params![raw,jpeg],|x|Ok((x.get(0)?,x.get(1)?,x.get(2)?,x.get(3)?,x.get(4)?,x.get(5)?))).optional()?;
        let duplicate = repeated.contains(raw) || repeated.contains(jpeg);
        paired.insert(raw.to_string());
        paired.insert(jpeg.to_string());
        let dismissed: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pair_dismissals WHERE id=?1)",
            [pair_key],
            |x| x.get(0),
        )?;
        let Some((_, _, rr, jr, cap, old)) = candidates else {
            report(db, "pair", &id, "pair member is missing")?;
            continue;
        };
        if rr != "raw" || jr != "jpeg" || duplicate || dismissed {
            report(
                db,
                "pair",
                &id,
                "conflicting roles, membership or dismissal",
            )?;
            continue;
        }
        let manual = pair["isManual"].as_bool().unwrap_or(false);
        db.execute(
            "UPDATE lc_files SET capture_id=?1,pair_locked=?2 WHERE file_id IN (?3,?4)",
            params![cap, manual, raw, jpeg],
        )?;
        db.execute(
            "INSERT INTO lc_capture_aliases VALUES(?1,?2,?3)",
            params![old, cap, id],
        )?;
        db.execute(
            "INSERT INTO lc_pair_events VALUES(?1,?2,?3,'v7-paired',?4,?5)",
            params![format!("v7:{id}"), raw, jpeg, manual, canonical(&pair)?],
        )?;
    }
    let mut st = db.prepare("SELECT id FROM pair_dismissals")?;
    let mut rows = st.query([])?;
    while let Some(row) = rows.next()? {
        let key: String = row.get(0)?;
        // v7 concatenated sorted IDs with a colon; recognize only an unambiguous
        // pair of catalog files, keeping the opaque original record in all cases.
        if let Some((a, b)) = key
            .split_once(':')
            .filter(|(a, b)| !a.is_empty() && !b.contains(':'))
        {
            db.execute(
                "UPDATE lc_files SET pair_locked=1 WHERE file_id IN (?1,?2)",
                params![a, b],
            )?;
            paired.insert(a.to_string());
            paired.insert(b.to_string());
        }
    }
    Ok(paired)
}
fn map_occurrences(db: &Connection, h: &History, paired: &BTreeSet<String>) -> Result<()> {
    let mut st=db.prepare("SELECT s.id,l.project_id,json_extract(w.data,'$.phase'),json_extract(s.data,'$.status'),json_extract(s.data,'$.scanCompleted')
        FROM sessions s JOIN lc_sessions l ON l.session_id=s.id LEFT JOIN session_workflows w ON w.id=s.id ORDER BY s.rowid")?;
    let mut sessions = st.query([])?;
    while let Some(row) = sessions.next()? {
        let session: String = row.get(0)?;
        let project: String = row.get(1)?;
        let phase: Option<String> = row.get(2)?;
        let status: Option<String> = row.get(3)?;
        let scanned: Option<bool> = row.get(4)?;
        let legacy = phase.as_deref() == Some("legacyHistory") || phase.is_none();
        let completed_legacy = legacy
            && status.as_deref() == Some("completed")
            && scanned.unwrap_or(phase.as_deref() == Some("legacyHistory"));
        let terminal =
            matches!(phase.as_deref(), Some("closed" | "legacyHistory")) || completed_legacy;
        if !terminal {
            continue;
        }
        let completed = h.completed.get(&session);
        let snapshot = completed.and_then(|(_, x)| (x.project == project).then_some(x));
        let ambiguous = h.ambiguous.contains(&session) || completed.is_some() && snapshot.is_none();
        let mut files=db.prepare("SELECT o.occurrence_id,o.asset_id,o.content_id,i.import_state,json_extract(t.data,'$.disposition'),p.data
          FROM lc_occurrences o JOIN lc_asset_input i ON i.asset_id=o.asset_id LEFT JOIN triage_records t ON t.asset_id=o.asset_id
          LEFT JOIN project_admissions p ON p.asset_id=o.asset_id WHERE o.session_id=?1")?;
        let mut rows = files.query([&session])?;
        while let Some(f) = rows.next()? {
            let occ: String = f.get(0)?;
            let asset: String = f.get(1)?;
            let content: Option<String> = f.get(2)?;
            let state: Option<String> = f.get(3)?;
            let decision: Option<String> = f.get(4)?;
            let admission: Option<String> = f.get(5)?;
            let admission = admission
                .map(|s| serde_json::from_str::<Value>(&s))
                .transpose()?;
            let formal = admission.as_ref().is_some_and(|v| {
                v["projectID"].as_str() == Some(project.as_str())
                    && v["assetID"].as_str() == Some(asset.as_str())
            });
            let required = admission
                .as_ref()
                .is_some_and(|v| v["sequenceOnly"].as_bool() == Some(true))
                || snapshot.is_some_and(|v| v.sequence.contains(&asset));
            let excluded = required
                || decision.as_deref() == Some("excluded")
                || snapshot.is_some_and(|v| v.excluded.contains(&asset));
            let supported = completed_legacy
                || snapshot.is_some_and(|v| v.admitted.contains(&asset))
                || snapshot.is_none() && decision.as_deref() == Some("passed");
            let valid = content.is_some() && state.as_deref() == Some("ready");
            let disposition = if !valid {
                "failed"
            } else if excluded {
                "excluded"
            } else if formal && supported && !ambiguous {
                "admitted"
            } else {
                "reconcile"
            };
            db.execute(
                "UPDATE lc_occurrences SET disposition=?1 WHERE session_id=?2 AND occurrence_id=?3",
                params![disposition, session, occ],
            )?;
            if disposition == "admitted" {
                let operation = completed
                    .map(|(id, _)| id.as_str())
                    .unwrap_or("v7-formal-admission");
                imports::grant(db, &session, &occ, "admitted", operation)?;
            } else if let Some(op) = h.restored.get(&(session.clone(), asset.clone())) {
                // v7 expanded a request to both pair members before logging only
                // the resulting IDs. That payload cannot attest explicit restoration
                // of a particular paired file.
                if valid && formal && !ambiguous && !paired.contains(&asset) {
                    imports::grant(db, &session, &occ, "restored", op)?;
                } else {
                    report(
                        db,
                        "recovery",
                        &asset,
                        "legacy recovery could not establish individual verified consent",
                    )?;
                }
            } else if disposition == "reconcile" || required || formal && !valid {
                report(
                    db,
                    "admission",
                    &asset,
                    if required {
                        "excluded sequence-protected legacy member"
                    } else {
                        "incomplete or unverified admission evidence"
                    },
                )?;
            }
        }
        let receipt = completed.map(|(id, _)| id.as_str()).unwrap_or("v7-history");
        db.execute(
            "UPDATE lc_sessions SET state='sealed',seal_id=?1 WHERE session_id=?2",
            params![receipt, session],
        )?;
    }
    Ok(())
}
pub(super) fn migrate(db: &Connection) -> Result<()> {
    db.execute("INSERT INTO lc_sessions(session_id,project_id,state,origin) SELECT id,json_extract(data,'$.projectID'),'open','v7' FROM sessions",[])?;
    db.execute("INSERT INTO lc_roots SELECT 'source:'||id,NULL,NULL,COALESCE(json_extract(data,'$.effectiveSourceRoot'),json_extract(data,'$.sourcePath')),'source' FROM sessions",[])?;
    db.execute("INSERT INTO lc_roots SELECT 'managed:'||id,NULL,NULL,COALESCE(json_extract(data,'$.effectiveManagedRoot'),json_extract(data,'$.destinationPath')),'managed' FROM sessions WHERE json_extract(data,'$.mode')='copy'",[])?;
    db.execute(
        "INSERT INTO lc_touch_asset SELECT id FROM assets ORDER BY rowid",
        [],
    )?;
    let sources: i64 = db.query_row("SELECT count(*) FROM assets", [], |r| r.get(0))?;
    let mapped: i64 = db.query_row("SELECT count(*) FROM lc_asset_files", [], |r| r.get(0))?;
    if sources != mapped {
        return Err("v7 file references an unknown import session".into());
    }
    let h = history(db)?;
    let paired = import_pairs(db)?;
    map_occurrences(db, &h, &paired)?;
    // Group command envelopes and operations remain intact in the v7 tables.
    // Preserve old participants in each available payload in addition to the
    // current Swift membership relation before later revisions can change it.
    relations::import_history(db)?;
    let mut groups = db.prepare("SELECT id FROM groups_data ORDER BY rowid")?;
    let ids = groups
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    for id in ids {
        relations::sync_group(db, &id)?;
    }
    Ok(())
}
