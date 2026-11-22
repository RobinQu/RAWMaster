use super::*;
use std::collections::{BTreeMap, HashSet};
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Entry {
    pub capture_id: String,
    pub file_id: String,
    pub source_position: i64,
    pub render_position: Option<i64>,
    pub asset_id: Option<String>,
    pub content_id: Option<String>,
    pub sha256: Option<String>,
    pub byte_count: Option<i64>,
    pub work_version_id: Option<String>,
    pub role: String,
    pub reason: String,
    pub asset: Value,
    pub alternate_contents: Vec<String>,
}
pub(super) struct Draft {
    pub revision: i64,
    pub project: String,
    pub entries: Vec<Entry>,
    pub missing: Vec<String>,
}
pub(super) fn draft(db: &Connection, r: &Value) -> Result<Draft> {
    let group = required(r, "groupID")?;
    let pending: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_group_dirty WHERE group_id=?)",
        [group],
        |r| r.get(0),
    )?;
    if pending {
        return Err("Group revision is being finalized; reopen the group".into());
    }
    let (rev,project,tombstone):(i64,String,bool)=db.query_row("SELECT revision,project_id,tombstoned FROM lc_group_versions WHERE group_id=? ORDER BY revision DESC LIMIT 1",[group],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
    if tombstone || r["revision"].as_i64().is_some_and(|v| v != rev) {
        return Err("Group was removed or its selected revision changed".into());
    }
    let mut selected = BTreeMap::new();
    if let Some(items) = r.get("selections") {
        for entry in items
            .as_array()
            .ok_or("Selections must be an ordered array")?
        {
            let capture = required(entry, "captureID")?.to_owned();
            if selected.insert(capture, entry).is_some() {
                return Err("Duplicate selection for the same capture".into());
            }
        }
    }
    let mut stmt=db.prepare("SELECT g.capture_id,g.file_id,g.position,g.included,c.included,f.role,c.position FROM lc_group_file_members g JOIN lc_group_members c USING(group_id,revision,capture_id) JOIN lc_files f USING(file_id) WHERE g.group_id=?1 AND g.revision=?2 ORDER BY c.position,g.position")?;
    let mut entries = vec![];
    let mut ranges = Vec::new();
    let mut last = None::<String>;
    for row in stmt.query_map(params![group, rev], |q| {
        Ok((
            q.get::<_, String>(0)?,
            q.get::<_, String>(1)?,
            q.get::<_, i64>(2)?,
            q.get::<_, bool>(3)?,
            q.get::<_, bool>(4)?,
            q.get::<_, String>(5)?,
        ))
    })? {
        let (capture, file, pos, included, cap_included, role) = row?;
        if last.as_deref() != Some(&capture) {
            ranges.push(entries.len());
            last = Some(capture.clone());
        }
        let pref = selected
            .get(&capture)
            .filter(|v| v["fileID"].as_str() == Some(file.as_str()))
            .and_then(|v| v["contentID"].as_str());
        let mut c=db.prepare_cached("SELECT DISTINCT a.asset_id,a.content_id,a.sha256,a.byte_count,CASE WHEN lower(json_extract(s.data,'$.contentHash'))=a.sha256 THEN s.data WHEN lower(json_extract(o.host_snapshot,'$.contentHash'))=a.sha256 THEN o.host_snapshot ELSE s.data END,w.active_version_id,a.scope_id FROM lc_archive_files a JOIN assets s ON s.id=a.asset_id JOIN lc_scopes scope ON scope.scope_id=a.scope_id JOIN lc_occurrences o ON o.session_id=scope.session_id AND o.occurrence_id=scope.occurrence_id LEFT JOIN lc_org_works w ON w.work_id='file:'||a.file_id WHERE a.file_id=?1 AND a.project_id=?2 ORDER BY (a.sha256=json_extract(s.data,'$.contentHash')) DESC,a.asset_id,a.content_id")?;
        let mut possible = Vec::new();
        for v in c.query_map(params![file, project], |q| {
            Ok((
                q.get::<_, String>(0)?,
                q.get::<_, String>(1)?,
                q.get::<_, String>(2)?,
                q.get::<_, i64>(3)?,
                q.get::<_, String>(4)?,
                q.get::<_, Option<String>>(5)?,
                q.get::<_, String>(6)?,
            ))
        })? {
            possible.push(v?);
        }
        let mut versions = Vec::new();
        for v in &possible {
            if !versions.contains(&v.1) {
                versions.push(v.1.clone());
            }
        }
        let chosen = possible.iter().find(|p| pref.is_none_or(|v| v == p.1));
        let mut e = Entry {
            capture_id: capture,
            file_id: file,
            source_position: pos,
            render_position: None,
            asset_id: None,
            content_id: None,
            sha256: None,
            byte_count: None,
            work_version_id: None,
            role,
            reason: if !included || !cap_included {
                "groupExcluded"
            } else {
                "notAdmitted"
            }
            .into(),
            asset: Value::Null,
            alternate_contents: versions,
        };
        if let Some((a, c, h, bytes, data, w, scope)) = chosen {
            let mut asset: Value = serde_json::from_str(data)?;
            asset["contentHash"] = json!(h);
            asset["fileSize"] = json!(bytes);
            asset["admissionScopeID"] = json!(scope);
            asset["renderInput"] = json!("originalContent");
            let optical:Option<String>=db.query_row("SELECT value_json FROM lc_inspect_file_effective WHERE file_id=?1 AND content_id=?2 AND field='shutterSeconds'",params![e.file_id,c],|r|r.get(0)).optional()?;
            if let Some(raw) = optical {
                asset["verifiedExposureSeconds"] = serde_json::from_str(&raw)?;
            }
            e.asset = asset;
            e.asset_id = Some(a.clone());
            e.content_id = Some(c.clone());
            e.sha256 = Some(h.clone());
            e.byte_count = Some(*bytes);
            e.work_version_id = w.clone();
            if included && cap_included {
                e.reason = "candidate".into();
            }
        }
        entries.push(e);
    }
    ranges.push(entries.len());
    let mut position = 0;
    let mut missing = vec![];
    let mut seen = HashSet::new();
    for pair in ranges.windows(2) {
        let group = &mut entries[pair[0]..pair[1]];
        let cap = group[0].capture_id.clone();
        seen.insert(cap.clone());
        let pick = selected.get(&cap);
        if pick.is_some_and(|v| v["exclude"] == true) {
            let reason = pick
                .and_then(|v| v["reason"].as_str())
                .filter(|s| !s.trim().is_empty())
                .ok_or("An explicit omission requires a reason")?;
            for e in group {
                if e.asset.is_null() {
                    e.asset = json!({});
                }
                e.asset["sourceParticipation"] = json!(e.reason);
                e.reason = format!("userExcluded:{reason}");
            }
            continue;
        }
        let wanted = pick.and_then(|p| p["fileID"].as_str());
        let take = if let Some(id) = wanted {
            let reason = pick
                .and_then(|p| p["reason"].as_str())
                .filter(|s| !s.trim().is_empty())
                .ok_or("An explicit representation requires a reason")?;
            let n = group
                .iter()
                .position(|e| e.file_id == id && e.reason == "candidate")
                .ok_or("Selected file is not an eligible member of this capture/group")?;
            Some((n, format!("userSelected:{reason}")))
        } else {
            group
                .iter()
                .position(|e| e.role == "raw" && e.reason == "candidate")
                .or_else(|| group.iter().position(|e| e.reason == "candidate"))
                .map(|n| (n, "selected".into()))
        };
        if let Some((n, reason)) = take {
            for (i, e) in group.iter_mut().enumerate() {
                if i == n {
                    e.reason = reason.clone();
                    e.render_position = Some(position);
                    position += 1;
                } else if e.reason == "candidate" {
                    e.reason = "alternateRepresentation".into();
                }
            }
        } else if group.iter().any(|e| e.reason != "groupExcluded") {
            missing.push(cap);
        }
    }
    if selected.keys().any(|k| !seen.contains(k)) {
        return Err("Selection contains a capture outside the frozen group".into());
    }
    Ok(Draft {
        revision: rev,
        project,
        entries,
        missing,
    })
}
fn stored_recipe(operation: &str, input: &Value) -> Result<Value> {
    let mut recipe = input
        .as_object()
        .ok_or("A versioned recipe is required")?
        .clone();
    if operation != "timelapse" {
        if recipe
            .get("sourceRenderingPolicy")
            .is_some_and(|v| v != "originalLinearRAW")
        {
            return Err("This renderer requires the frozen original linear input policy".into());
        }
        recipe.insert("sourceRenderingPolicy".into(), json!("originalLinearRAW"));
    }
    Ok(Value::Object(recipe))
}
pub(super) fn freeze(db: &mut Connection, r: &Value) -> Result<Value> {
    let group = required(r, "groupID")?;
    let op = required(r, "operation")?;
    if !matches!(op, "timelapse" | "starTrail" | "hdr" | "panorama") {
        return Err("Unknown group processing operation".into());
    }
    let jid = job_id(r)?;
    let recipe = r["recipe"]
        .as_object()
        .ok_or("A versioned recipe is required")?;
    let stored = stored_recipe(op, &r["recipe"])?;
    let request_hash = hex::encode(Sha256::digest(serde_json::to_vec(
        &json!({"groupID":group,"revision":r["revision"],"operation":op,"recipe":recipe,"selections":r["selections"],"parentJobID":r["parentJobID"]}),
    )?));
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let existing: Option<String> = tx
        .query_row(
            "SELECT request_hash FROM lc_proc_jobs WHERE job_id=?",
            [&jid],
            |q| q.get(0),
        )
        .optional()?;
    if let Some(e) = existing {
        if e != request_hash {
            return Err("Job identity already has a different frozen request".into());
        }
        tx.commit()?;
        return status(db, &jid);
    }
    if r["revision"].as_i64().is_none() {
        return Err("Review and select a group revision first".into());
    }
    let draft = draft(&tx, r)?;
    if !draft.missing.is_empty()
        || draft
            .entries
            .iter()
            .filter(|e| e.render_position.is_some())
            .count()
            < 2
    {
        return Err(
            "At least two eligible captures are required; identify each omitted capture explicitly"
                .into(),
        );
    }
    if let Some(parent) = r["parentJobID"].as_str() {
        let related: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM lc_proc_jobs WHERE job_id=?1 AND group_id=?2)",
            params![parent, group],
            |r| r.get(0),
        )?;
        if !related {
            return Err("Rerender requires a predecessor from this group".into());
        }
    }
    tx.execute("INSERT INTO lc_proc_jobs(job_id,group_id,revision,project_id,operation,recipe_json,request_hash,parent_job,state) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'queued')",params![jid,group,draft.revision,draft.project,op,stored.to_string(),request_hash,r["parentJobID"].as_str()])?;
    for e in draft.entries {
        tx.execute(
            "INSERT INTO lc_proc_inputs VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
            params![
                jid,
                e.capture_id,
                e.file_id,
                e.source_position,
                e.render_position,
                e.asset_id,
                e.content_id,
                e.sha256,
                e.byte_count,
                e.work_version_id,
                e.role,
                e.reason,
                e.asset.to_string()
            ],
        )?;
    }
    tx.commit()?;
    status(db, &jid)
}

/// A remake can use the exact historical inputs even if the source group has since changed order.
pub(super) fn remake(db: &mut Connection, r: &Value) -> Result<Value> {
    let jid = job_id(r)?;
    let old = required(r, "parentJobID")?;
    if jid == old {
        return Err("A remake needs a new job ID".into());
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let source = status(&tx, old)?;
    let recipe = r.get("recipe").unwrap_or(&source["recipe"]);
    let stored = stored_recipe(required(&source, "operation")?, recipe)?;
    let mark = hex::encode(Sha256::digest(serde_json::to_vec(&json!([
        "remake", old, recipe
    ]))?));
    let previous: Option<String> = tx
        .query_row(
            "SELECT request_hash FROM lc_proc_jobs WHERE job_id=?",
            [&jid],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(v) = previous {
        if v != mark {
            return Err("Job ID already has another frozen request".into());
        }
    } else {
        tx.execute("INSERT INTO lc_proc_jobs(job_id,group_id,revision,project_id,operation,recipe_json,request_hash,parent_job,state) SELECT ?1,group_id,revision,project_id,operation,?2,?3,job_id,'queued' FROM lc_proc_jobs WHERE job_id=?4",params![jid,stored.to_string(),mark,old])?;
        tx.execute("INSERT INTO lc_proc_inputs SELECT ?1,capture_id,file_id,source_position,render_position,asset_id,content_id,sha256,byte_count,work_version,role,reason,source_json FROM lc_proc_inputs WHERE job_id=?2",params![jid,old])?;
    }
    tx.commit()?;
    status(db, &jid)
}
