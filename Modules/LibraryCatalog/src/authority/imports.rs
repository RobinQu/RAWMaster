use super::*;
use std::collections::BTreeSet;

pub(super) fn open(db: &Connection, r: &Value) -> Result<Value> {
    let session = field(r, "sessionID")?;
    let project = field(r, "projectID")?;
    let legacy: String = db.query_row(
        "SELECT json_extract(data,'$.projectID') FROM sessions WHERE id=?1",
        [session],
        |row| row.get(0),
    )?;
    if legacy != project {
        return Err("session project is inconsistent".into());
    }
    let changed=db.execute("UPDATE lc_sessions SET origin='native' WHERE session_id=?1 AND project_id=?2 AND state='open' AND origin IN ('host','v7')",params![session,project])?;
    if changed != 1 {
        return Err("session has already been opened or sealed".into());
    }
    Ok(json!({"sessionID":session,"projectID":project,"state":"open"}))
}
fn open_project(db: &Connection, session: &str, r: &Value) -> Result<String> {
    let (project, state, revision): (String, String, i64) = db.query_row(
        "SELECT project_id,state,revision FROM lc_sessions WHERE session_id=?1",
        [session],
        |x| Ok((x.get(0)?, x.get(1)?, x.get(2)?)),
    )?;
    if state != "open" {
        return Err("sealed import requires a new session".into());
    }
    if let Some(base) = r.get("baseRevision") {
        if base.as_i64() != Some(revision) {
            return Err("the import revision has changed".into());
        }
    }
    Ok(project)
}
pub(super) fn put(db: &Connection, r: &Value) -> Result<Value> {
    let session = field(r, "sessionID")?;
    let occurrence = field(r, "occurrenceID")?;
    let asset = field(r, "assetID")?;
    open_project(db, session, r)?;
    let (original,role,content,relative):(String,String,Option<String>,Option<String>)=db.query_row(
        "SELECT f.file_id,a.role,a.content_id,a.relative_path FROM lc_asset_input a JOIN lc_asset_files f USING(asset_id) WHERE a.asset_id=?1",
        [asset],|x|Ok((x.get(0)?,x.get(1)?,x.get(2)?,x.get(3)?)))?;
    let file = match r.get("fileID") {
        Some(_) => field(r, "fileID")?,
        None => &original,
    };
    if file != original {
        let locked:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_occurrences WHERE asset_id=?1 AND (explicit_id=1 OR disposition<>'pending')) OR EXISTS(SELECT 1 FROM lc_scopes WHERE asset_id=?1)",[asset],|x|x.get(0))?;
        if locked {
            return Err("an established file mapping cannot be rebound".into());
        }
        let target: Option<String> = db
            .query_row("SELECT role FROM lc_files WHERE file_id=?1", [file], |x| {
                x.get(0)
            })
            .optional()?;
        if let Some(target_role) = target {
            let known:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_replicas WHERE file_id=?1 AND content_id=?2) OR EXISTS(SELECT 1 FROM lc_scopes WHERE file_id=?1 AND content_id=?2)",params![file,content],|x|x.get(0))?;
            if target_role != role || content.is_none() || !known {
                return Err(
                    "existing logical file needs the same verified content and role".into(),
                );
            }
        } else {
            let cap = format!("capture:{file}");
            db.execute("INSERT INTO lc_captures VALUES(?1)", [&cap])?;
            db.execute(
                "INSERT INTO lc_files(file_id,capture_id,role) VALUES(?1,?2,?3)",
                params![file, cap, role],
            )?;
        }
        db.execute(
            "UPDATE lc_asset_files SET file_id=?1 WHERE asset_id=?2",
            params![file, asset],
        )?;
        db.execute(
            "UPDATE lc_occurrences SET file_id=?1 WHERE asset_id=?2 AND disposition='pending'",
            params![file, asset],
        )?;
        db.execute("INSERT INTO lc_touch_asset VALUES(?1)", [asset])?;
        // Discovery created a provisional single-file capture before this explicit
        // alias was known. Keep it if any immutable group or pairing still uses it.
        db.execute("DELETE FROM lc_files WHERE file_id=?1 AND pair_locked=0 AND NOT EXISTS(SELECT 1 FROM lc_asset_files WHERE file_id=?1) AND NOT EXISTS(SELECT 1 FROM lc_group_file_members WHERE file_id=?1) AND NOT EXISTS(SELECT 1 FROM lc_pair_events WHERE raw_file_id=?1 OR jpeg_file_id=?1) AND NOT EXISTS(SELECT 1 FROM lc_replicas WHERE file_id=?1)",[&original])?;
        let old_capture = format!("capture:{original}");
        db.execute("DELETE FROM lc_captures WHERE capture_id=?1 AND NOT EXISTS(SELECT 1 FROM lc_files WHERE capture_id=?1) AND NOT EXISTS(SELECT 1 FROM lc_group_members WHERE capture_id=?1) AND NOT EXISTS(SELECT 1 FROM lc_capture_aliases WHERE capture_id=?1 OR canonical_id=?1)",[&old_capture])?;
    }
    let previous:Option<(String,bool)>=db.query_row("SELECT occurrence_id,explicit_id FROM lc_occurrences WHERE session_id=?1 AND asset_id=?2",params![session,asset],|x|Ok((x.get(0)?,x.get(1)?))).optional()?;
    if let Some((prior, explicit)) = previous {
        if prior != occurrence && explicit {
            return Err("source occurrence already has a stable ID".into());
        }
        db.execute("UPDATE lc_occurrences SET occurrence_id=?1,explicit_id=1,root_id=COALESCE(?2,root_id),relative_path=COALESCE(?3,relative_path) WHERE session_id=?4 AND asset_id=?5",
            params![occurrence,r["rootID"].as_str(),r["relativePath"].as_str(),session,asset])?;
    } else {
        db.execute("INSERT INTO lc_occurrences(session_id,occurrence_id,asset_id,file_id,root_id,relative_path,content_id,explicit_id) VALUES(?1,?2,?3,?4,?5,?6,?7,1)",
            params![session,occurrence,asset,file,r["rootID"].as_str(),r["relativePath"].as_str().or(relative.as_deref()),content])?;
    }
    db.execute("UPDATE lc_occurrences SET host_snapshot=(SELECT data FROM assets WHERE id=?3) WHERE session_id=?1 AND occurrence_id=?2",params![session,occurrence,asset])?;
    db.execute(
        "UPDATE lc_sessions SET revision=revision+1 WHERE session_id=?1",
        [session],
    )?;
    Ok(json!({"sessionID":session,"occurrenceID":occurrence,"fileID":file,"contentID":content}))
}

pub(super) fn grant(
    db: &Connection,
    session: &str,
    occurrence: &str,
    kind: &str,
    op: &str,
) -> Result<String> {
    let scope = digest_id("scope", &[session, occurrence]);
    let changed=db.execute("INSERT INTO lc_scopes(scope_id,session_id,occurrence_id,project_id,asset_id,file_id,content_id,kind,operation_id)
        SELECT ?1,o.session_id,o.occurrence_id,s.project_id,o.asset_id,o.file_id,o.content_id,?4,?5 FROM lc_occurrences o JOIN lc_sessions s USING(session_id)
        WHERE o.session_id=?2 AND o.occurrence_id=?3 AND o.content_id IS NOT NULL",params![scope,session,occurrence,kind,op])?;
    if changed != 1 {
        return Err("scope requires one verified occurrence".into());
    }
    Ok(scope)
}

pub(super) fn seal(db: &Connection, r: &Value) -> Result<Value> {
    let session = field(r, "sessionID")?;
    let project = open_project(db, session, r)?;
    let op = field(r, "commandID")?;
    let ready:bool=db.query_row("SELECT COALESCE(json_extract(s.data,'$.scanCompleted')=1 AND json_extract(s.data,'$.status') IN ('completed','partial') AND COALESCE(json_extract(w.data,'$.importActive'),0)=0,0)
        FROM sessions s LEFT JOIN session_workflows w ON w.id=s.id WHERE s.id=?1",[session],|row|row.get(0))?;
    if !ready {
        return Err("the source scan must finish before sealing".into());
    }
    let mut st = db.prepare("SELECT occurrence_id FROM lc_occurrences WHERE session_id=?1")?;
    let expected: BTreeSet<String> = st
        .query_map([session], |x| x.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    let mut actual = BTreeSet::new();
    let mut counts = BTreeMap::from([
        ("admitted", 0usize),
        ("sequenceOnly", 0),
        ("excluded", 0),
        ("failed", 0),
    ]);
    for item in array(r, "items")? {
        let occ = field(item, "occurrenceID")?;
        let disposition = field(item, "disposition")?;
        if !expected.contains(occ) || !actual.insert(occ.to_string()) {
            return Err("unknown or repeated occurrence in seal".into());
        }
        let count = counts
            .get_mut(disposition)
            .ok_or("invalid final disposition")?;
        *count += 1;
        let (content,available,triage):(Option<String>,Option<String>,Option<String>)=db.query_row(
            "SELECT o.content_id,a.availability,CASE WHEN a.session_id=o.session_id THEN json_extract(t.data,'$.disposition') END
             FROM lc_occurrences o JOIN lc_asset_input a ON a.asset_id=o.asset_id LEFT JOIN triage_records t ON t.asset_id=o.asset_id
             WHERE o.session_id=?1 AND o.occurrence_id=?2",params![session,occ],|x| Ok((x.get(0)?,x.get(1)?,x.get(2)?)))?;
        if let Some(ex) = item.get("contentID") {
            if ex.as_str() != content.as_deref() {
                return Err("occurrence content changed after preview".into());
            }
        }
        if disposition == "excluded" && content.is_none() {
            return Err("unverified source must be sealed as a failed occurrence".into());
        }
        if disposition == "failed" && content.is_some() && available.as_deref() == Some("available")
        {
            return Err("verified available original requires an explicit disposition".into());
        }
        if matches!(disposition, "admitted" | "sequenceOnly") {
            if content.is_none() || available.as_deref() != Some("available") {
                return Err("admission requires a verified available original".into());
            }
            if triage.as_deref() == Some("excluded") {
                return Err("an excluded import member cannot be admitted by its group".into());
            }
            grant(db, session, occ, disposition, op)?;
        }
        db.execute(
            "UPDATE lc_occurrences SET disposition=?3,host_snapshot=(SELECT data FROM assets WHERE id=lc_occurrences.asset_id) WHERE session_id=?1 AND occurrence_id=?2",
            params![session, occ, disposition],
        )?;
    }
    if actual != expected {
        return Err("seal must cover every discovered occurrence".into());
    }
    db.execute(
        "UPDATE lc_sessions SET state='sealed',revision=revision+1,seal_id=?1 WHERE session_id=?2",
        params![op, session],
    )?;
    Ok(
        json!({"sessionID":session,"projectID":project,"state":"sealed","counts":counts,"total":actual.len()}),
    )
}

pub(super) fn restore(db: &Connection, r: &Value) -> Result<Value> {
    let session = field(r, "sessionID")?;
    let occ = field(r, "occurrenceID")?;
    let op = field(r, "commandID")?;
    let (file,content,state,disposition):(String,Option<String>,String,String)=db.query_row(
        "SELECT o.file_id,o.content_id,s.state,o.disposition FROM lc_occurrences o JOIN lc_sessions s USING(session_id) WHERE o.session_id=?1 AND o.occurrence_id=?2",
        params![session,occ],|x|Ok((x.get(0)?,x.get(1)?,x.get(2)?,x.get(3)?)))?;
    if state != "sealed" || !matches!(disposition.as_str(), "excluded" | "reconcile") {
        return Err("only a verified excluded occurrence can be restored".into());
    }
    let expected = content.ok_or("occurrence never verified; start a new import session")?;
    let sha = checked_hash(field(r, "sha256")?)?;
    let size = number(r, "byteCount")?;
    if expected != format!("sha256:{sha}:{size}") {
        return Err("restored bytes differ from the sealed content version".into());
    }
    let path = Path::new(field(r, "path")?);
    let filename = path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("invalid original filename")?;
    replicas::record_verified(
        db,
        &file,
        &expected,
        r["rootID"].as_str().unwrap_or("explicit-recovery"),
        r["relativePath"].as_str().unwrap_or(filename),
        path,
        path,
        "restored",
    )?;
    let scope = grant(db, session, occ, "restored", op)?;
    let resolved_asset = activate_restored_scope(db, &scope, &file, &expected, path)?;
    Ok(
        json!({"sessionID":session,"occurrenceID":occ,"scopeID":scope,"fileID":file,"contentID":expected,"assetID":resolved_asset}),
    )
}

pub(super) fn finish_direct(db: &Connection, r: &Value) -> Result<Value> {
    let session = field(r, "sessionID")?;
    let project = open_project(db, session, r)?;
    let direct:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM sessions s WHERE s.id=?1 AND json_extract(s.data,'$.status')='completed' AND json_extract(s.data,'$.scanCompleted')=1
        AND NOT EXISTS(SELECT 1 FROM session_workflows w WHERE w.id=s.id))",[session],|x|x.get(0))?;
    if !direct {
        return Err(
            "direct completion requires a finished import without a screening workflow".into(),
        );
    }
    let mut st=db.prepare("SELECT o.occurrence_id,o.content_id,a.availability,a.session_id,p.data FROM lc_occurrences o JOIN lc_asset_input a USING(asset_id)
        LEFT JOIN project_admissions p ON p.asset_id=o.asset_id WHERE o.session_id=?1 ORDER BY o.occurrence_id")?;
    let mut rows = st.query([session])?;
    let mut items = Vec::new();
    while let Some(row) = rows.next()? {
        let occurrence: String = row.get(0)?;
        let content: Option<String> = row.get(1)?;
        let available: Option<String> = row.get(2)?;
        let source: String = row.get(3)?;
        let formal: Option<String> = row.get(4)?;
        let formal = formal
            .map(|s| serde_json::from_str::<Value>(&s))
            .transpose()?;
        if content.is_none()
            || available.as_deref() != Some("available")
            || source != session
            || !formal.as_ref().is_some_and(|f| {
                f["projectID"].as_str() == Some(project.as_str())
                    && f["sequenceOnly"].as_bool() != Some(true)
            })
        {
            return Err(
                "direct import has an unresolved source; resume or review its items before sealing"
                    .into(),
            );
        }
        items.push(json!({"occurrenceID":occurrence,"contentID":content,"disposition":"admitted"}));
    }
    relations::direct_pairs(db, session, field(r, "commandID")?)?;
    let mut sealed = r.clone();
    sealed["items"] = json!(items);
    seal(db, &sealed)
}
