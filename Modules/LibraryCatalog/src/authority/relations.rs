use super::*;
use std::collections::{BTreeMap, BTreeSet};

fn auto_match(e: &Value) -> bool {
    let raw = &e["raw"];
    let jpg = &e["jpeg"];
    let same = |key: &str| {
        raw[key]
            .as_str()
            .filter(|v| !v.is_empty())
            .is_some_and(|v| jpg[key].as_str() == Some(v))
    };
    let disagrees = |key: &str| {
        raw[key]
            .as_str()
            .zip(jpg[key].as_str())
            .is_some_and(|(a, b)| a != b)
    };
    same("cameraSerial")
        && same("captureTime")
        && !disagrees("subsecond")
        && !disagrees("frameNumber")
        && (same("subsecond") || same("frameNumber"))
}
pub(super) fn pair(db: &Connection, r: &Value) -> Result<Value> {
    apply_pair(db, r, false)
}
fn bound_pair(db: &Connection, raw: &str, jpeg: &str, e: &Value) -> Result<bool> {
    if !auto_match(e) {
        return Ok(false);
    }
    for (file, member) in [(raw, &e["raw"]), (jpeg, &e["jpeg"])] {
        let Some(content) = member["contentID"].as_str() else {
            return Ok(false);
        };
        let valid:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_asset_files f JOIN lc_asset_input a USING(asset_id) WHERE f.file_id=?1 AND a.content_id=?2)",params![file,content],|x|x.get(0))?;
        if !valid {
            return Ok(false);
        }
    }
    Ok(true)
}
fn apply_pair(db: &Connection, r: &Value, local_corroborated: bool) -> Result<Value> {
    let raw = field(r, "rawFileID")?;
    let jpeg = field(r, "jpegFileID")?;
    let op = field(r, "commandID")?;
    let action = field(r, "action")?;
    let manual = r["manual"].as_bool().ok_or("pair requires manual flag")?;
    if raw == jpeg {
        return Err("pair requires two distinct files".into());
    }
    let info = |id: &str| -> rusqlite::Result<(String, String, bool)> {
        db.query_row(
            "SELECT capture_id,role,pair_locked FROM lc_files WHERE file_id=?1",
            [id],
            |x| Ok((x.get(0)?, x.get(1)?, x.get(2)?)),
        )
    };
    let (rc, rr, rl) = info(raw)?;
    let (jc, jr, jl) = info(jpeg)?;
    if rr != "raw" || jr != "jpeg" {
        return Err("pair requires a RAW and a camera JPEG".into());
    }
    let evidence = &r["evidence"];
    let mut status = "paired";
    if action == "capture.split" {
        if !manual || rc != jc {
            return Err("split requires a currently paired capture and user confirmation".into());
        }
        let single = format!("capture:{jpeg}");
        db.execute("INSERT OR IGNORE INTO lc_captures VALUES(?1)", [&single])?;
        db.execute(
            "UPDATE lc_files SET capture_id=?1,pair_locked=1 WHERE file_id=?2",
            params![single, jpeg],
        )?;
        db.execute("UPDATE lc_files SET pair_locked=1 WHERE file_id=?1", [raw])?;
        db.execute(
            "DELETE FROM lc_capture_aliases WHERE capture_id=?1",
            [single],
        )?;
        status = "split";
    } else if !manual && (rl || jl || !local_corroborated && !bound_pair(db, raw, jpeg, evidence)?)
    {
        status = "review";
    } else if rc != jc {
        let occupied:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_files WHERE (capture_id=?1 AND file_id<>?2) OR (capture_id=?3 AND file_id<>?4))",params![rc,raw,jc,jpeg],|x|x.get(0))?;
        if occupied && manual {
            return Err("split the existing pair before assigning another counterpart".into());
        }
        if occupied {
            status = "review";
        } else {
            db.execute(
                "UPDATE lc_files SET capture_id=?1,pair_locked=?2 WHERE file_id=?3",
                params![rc, manual, jpeg],
            )?;
            db.execute(
                "UPDATE lc_files SET pair_locked=?1 WHERE file_id=?2",
                params![manual, raw],
            )?;
            db.execute("INSERT INTO lc_capture_aliases VALUES(?1,?2,?3) ON CONFLICT(capture_id) DO UPDATE SET canonical_id=excluded.canonical_id,operation_id=excluded.operation_id",params![jc,rc,op])?;
        }
    } else if manual {
        db.execute(
            "UPDATE lc_files SET pair_locked=1 WHERE file_id IN (?1,?2)",
            params![raw, jpeg],
        )?;
    }
    db.execute(
        "INSERT INTO lc_pair_events VALUES(?1,?2,?3,?4,?5,?6)",
        params![op, raw, jpeg, status, manual, canonical(evidence)?],
    )?;
    if status != "review" {
        let mut st=db.prepare("SELECT DISTINCT v.group_id FROM lc_group_file_members m JOIN lc_group_versions v USING(group_id,revision)
            WHERE m.file_id IN (?1,?2) AND v.tombstoned=0 AND v.revision=(SELECT max(revision) FROM lc_group_versions WHERE group_id=v.group_id)")?;
        let groups = st
            .query_map(params![raw, jpeg], |x| x.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?;
        for g in groups {
            let current = latest(db, &g)?.ok_or("missing group")?;
            let files = version_files(db, &g, current.revision)?;
            write(
                db,
                &g,
                current.revision + 1,
                &current.project,
                &current.kind,
                current.locked,
                &json!({"pairOperation":op}),
                &files,
                false,
            )?;
        }
    }
    Ok(json!({"status":status,"rawFileID":raw,"jpegFileID":jpeg,"captureID":rc}))
}

struct Group {
    revision: i64,
    project: String,
    kind: String,
    locked: bool,
    tombstoned: bool,
}
fn latest(db: &Connection, id: &str) -> Result<Option<Group>> {
    Ok(db.query_row("SELECT revision,project_id,kind,locked,tombstoned FROM lc_group_versions WHERE group_id=?1 ORDER BY revision DESC LIMIT 1",[id],|x|Ok(Group{revision:x.get(0)?,project:x.get(1)?,kind:x.get(2)?,locked:x.get(3)?,tombstoned:x.get(4)?})).optional()?)
}
fn version_files(db: &Connection, id: &str, revision: i64) -> Result<Vec<(String, bool)>> {
    let mut st=db.prepare("SELECT file_id,included FROM lc_group_file_members WHERE group_id=?1 AND revision=?2 ORDER BY position")?;
    let rows = st.query_map(params![id, revision], |x| Ok((x.get(0)?, x.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}
pub(super) fn write(
    db: &Connection,
    id: &str,
    revision: i64,
    project: &str,
    kind: &str,
    locked: bool,
    evidence: &Value,
    files: &[(String, bool)],
    tombstone: bool,
) -> Result<()> {
    let mut captures: BTreeMap<String, (i64, bool)> = BTreeMap::new();
    let mut rows = Vec::new();
    let mut seen = BTreeSet::new();
    for (position, (file, included)) in files.iter().enumerate() {
        if !seen.insert(file) {
            return Err("duplicate logical file in group revision".into());
        }
        let cap: String = db.query_row(
            "SELECT capture_id FROM lc_files WHERE file_id=?1",
            [file],
            |x| x.get(0),
        )?;
        let next = captures.len() as i64;
        let item = captures.entry(cap.clone()).or_insert((next, false));
        item.1 |= *included;
        rows.push((file, cap, position as i64, *included));
    }
    db.execute(
        "INSERT INTO lc_group_versions VALUES(?1,?2,?3,?4,?5,?6,?7)",
        params![
            id,
            revision,
            project,
            kind,
            locked,
            canonical(evidence)?,
            tombstone
        ],
    )?;
    for (cap, (position, included)) in captures {
        db.execute(
            "INSERT INTO lc_group_members VALUES(?1,?2,?3,?4,?5)",
            params![id, revision, cap, position, included],
        )?;
    }
    for (file, cap, position, included) in rows {
        db.execute(
            "INSERT INTO lc_group_file_members VALUES(?1,?2,?3,?4,?5,?6)",
            params![id, revision, file, cap, position, included],
        )?;
    }
    Ok(())
}
pub(super) fn revise(db: &Connection, r: &Value) -> Result<Value> {
    let id = field(r, "groupID")?;
    let base = number(r, "baseRevision")?;
    let current = latest(db, id)?;
    if current.as_ref().map(|x| x.revision).unwrap_or(0) != base {
        return Err("group revision changed".into());
    }
    if current.as_ref().is_some_and(|g| g.locked) && r["automatic"] == true {
        return Err("automatic grouping cannot replace a locked revision".into());
    }
    let project = field(r, "projectID")?;
    if current.as_ref().is_some_and(|g| g.project != project) {
        return Err("group belongs to a different project".into());
    }
    let mut files = Vec::new();
    for m in array(r, "members")? {
        let file = field(m, "fileID")?;
        let local: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM lc_occurrences o JOIN lc_sessions s USING(session_id) WHERE o.file_id=?1 AND s.project_id=?2) OR EXISTS(SELECT 1 FROM lc_scopes WHERE file_id=?1 AND project_id=?2)",params![file,project],|row|row.get(0))?;
        if !local {
            return Err("group member is outside the project and its import history".into());
        }
        files.push((
            file.to_string(),
            m["included"]
                .as_bool()
                .ok_or("member participation is required")?,
        ));
    }
    let next = base.checked_add(1).ok_or("revision overflow")?;
    write(
        db,
        id,
        next,
        project,
        field(r, "kind")?,
        r["locked"].as_bool().ok_or("group lock is required")?,
        &r["evidence"],
        &files,
        false,
    )?;
    Ok(json!({"groupID":id,"revision":next,"fileCount":files.len()}))
}
pub(super) fn sync_group(db: &Connection, id: &str) -> Result<Value> {
    let current = latest(db, id)?;
    let legacy: Option<(String, String)> = db
        .query_row(
            "SELECT project_id,data FROM groups_data WHERE id=?1",
            [id],
            |x| Ok((x.get(0)?, x.get(1)?)),
        )
        .optional()?;
    if let Some((project, data)) = legacy {
        let info: Value = serde_json::from_str(&data)?;
        let kind = field(&info, "kind")?;
        let locked = info["locked"].as_bool().unwrap_or(true);
        let mut st=db.prepare("SELECT f.file_id,m.included FROM membership m JOIN lc_asset_files f USING(asset_id) WHERE m.group_id=?1 ORDER BY m.position,m.rowid")?;
        let files = st
            .query_map([id], |x| Ok((x.get(0)?, x.get(1)?)))?
            .collect::<rusqlite::Result<Vec<(String, bool)>>>()?;
        let legacy_revision = info["groupRevision"].as_i64().unwrap_or(0).max(0);
        let revision = current
            .as_ref()
            .map(|g| g.revision + 1)
            .unwrap_or(legacy_revision)
            .max(legacy_revision);
        let unchanged = if let Some(c) = &current {
            !c.tombstoned
                && c.project == project
                && c.kind == kind
                && c.locked == locked
                && version_files(db, id, c.revision)? == files
        } else {
            false
        };
        if !unchanged {
            write(
                db,
                id,
                revision,
                &project,
                kind,
                locked,
                &json!({"source":"v7","sourceRevision":legacy_revision}),
                &files,
                false,
            )?;
        }
    } else if let Some(c) = current {
        if !c.tombstoned {
            write(
                db,
                id,
                c.revision + 1,
                &c.project,
                &c.kind,
                c.locked,
                &json!({"source":"v7","deleted":true}),
                &[],
                true,
            )?;
        }
    }
    Ok(json!({"groupID":id,"revision":latest(db,id)?.map(|g|g.revision)}))
}

/// Import snapshots containing old member-level participation, including groups
/// since removed. The original envelope remains available for exact recovery.
pub(super) fn import_history(db: &Connection) -> Result<()> {
    let mut st = db.prepare("SELECT id,data FROM group_commands ORDER BY rowid")?;
    let mut rows = st.query([])?;
    while let Some(row) = rows.next()? {
        let command: String = row.get(0)?;
        let doc: Value = serde_json::from_str(&row.get::<_, String>(1)?)?;
        let record = &doc["record"];
        if record["payloadVersion"].as_u64() != Some(1) {
            migration::report(
                db,
                "group-command",
                &command,
                "unsupported historical group payload retained",
            )?;
            continue;
        }
        for side in ["before", "after"] {
            for g in array(record, side)? {
                let id = field(g, "id")?;
                let project = field(g, "projectID")?;
                let kind = field(g, "kind")?;
                let revision = g["groupRevision"].as_i64().unwrap_or(0).max(0);
                let participants = g["includedAssetIDs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .collect::<BTreeSet<_>>();
                let mut files = Vec::new();
                let mut complete = true;
                for asset in array(g, "assetIDs")? {
                    let asset = asset.as_str().ok_or("invalid historical group member")?;
                    let file: Option<String> = db
                        .query_row(
                            "SELECT file_id FROM lc_asset_files WHERE asset_id=?1",
                            [asset],
                            |r| r.get(0),
                        )
                        .optional()?;
                    if let Some(file) = file {
                        files.push((file, participants.contains(asset)));
                    } else {
                        complete = false;
                    }
                }
                if !complete {
                    migration::report(
                        db,
                        "group-command",
                        &command,
                        "historical group has an unresolved original member",
                    )?;
                    continue;
                }
                let exists:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_group_versions WHERE group_id=?1 AND revision=?2)",params![id,revision],|r|r.get(0))?;
                if exists {
                    if version_files(db, id, revision)? != files {
                        migration::report(
                            db,
                            "group-command",
                            &command,
                            "competing snapshots of the same source revision retained",
                        )?;
                    }
                } else {
                    write(
                        db,
                        id,
                        revision,
                        project,
                        kind,
                        g["locked"].as_bool().unwrap_or(true),
                        &json!({"source":"v7-group-command","operation":command}),
                        &files,
                        false,
                    )?;
                }
            }
        }
    }
    let mut st=db.prepare("SELECT DISTINCT group_id FROM lc_group_versions WHERE NOT EXISTS(SELECT 1 FROM groups_data WHERE id=group_id)")?;
    let removed = st
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    for id in removed {
        sync_group(db, &id)?;
    }
    Ok(())
}

/// Called by the host immediately before committing a transaction that touched
/// compatible v7 group or pair tables. Reads only queued, affected relations.
pub(super) fn flush(db: &Connection) -> Result<()> {
    let mut st =
        db.prepare("SELECT sequence,pair_id,data,removed FROM lc_pair_dirty ORDER BY sequence")?;
    let entries = st
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, bool>(3)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut sources = BTreeMap::<String, pair_evidence::SessionFacts>::new();
    for (seq, id, data, removed) in entries {
        let p: Value = serde_json::from_str(&data)?;
        let raw = field(&p, "rawAssetID")?;
        let jpeg = field(&p, "jpegAssetID")?;
        let mut st=db.prepare("SELECT f.file_id,f.capture_id FROM lc_asset_files m JOIN lc_files f USING(file_id) WHERE asset_id=?1")?;
        let lookup = |key: &str| {
            st.query_row([key], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .optional()
        };
        let mut lookup = lookup;
        let a = lookup(raw)?;
        let b = lookup(jpeg)?;
        if let (Some((raw, rc)), Some((jpeg, jc))) = (a, b) {
            if (removed && rc == jc) || (!removed && rc != jc) {
                let action = if removed {
                    "capture.split"
                } else {
                    "capture.pair"
                };
                let op = format!("compat:pair:{seq}:{id}");
                let manual = removed || p["isManual"].as_bool().unwrap_or(false);
                let (mut evidence, allow_local) = if manual {
                    (json!({"source":"v7-explicit-action"}), false)
                } else {
                    let session = field(&p, "sessionID")?;
                    if !sources.contains_key(session) {
                        sources.insert(
                            session.to_owned(),
                            pair_evidence::SessionFacts::load(db, session)?,
                        );
                    }
                    sources[session].assess(field(&p, "rawAssetID")?, field(&p, "jpegAssetID")?, &p)
                };
                evidence["pairID"] = json!(id);
                apply_pair(
                    db,
                    &json!({"action":action,"commandID":op,"rawFileID":raw,"jpegFileID":jpeg,"manual":manual,"evidence":evidence}),
                    allow_local,
                )?;
            }
        } else {
            migration::report(
                db,
                "pair",
                &id,
                "a compatibility edit referenced an unknown file",
            )?;
        }
        db.execute("DELETE FROM lc_pair_dirty WHERE sequence=?1", [seq])?;
    }
    let mut st = db.prepare("SELECT group_id FROM lc_group_dirty ORDER BY group_id")?;
    let groups = st
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    for id in groups {
        sync_group(db, &id)?;
        db.execute("DELETE FROM lc_group_dirty WHERE group_id=?1", [id])?;
    }
    Ok(())
}

pub(super) fn direct_pairs(db: &Connection, session: &str, command: &str) -> Result<()> {
    flush(db)?;
    let facts = pair_evidence::SessionFacts::load(db, session)?;
    let mut existing=db.prepare("SELECT json_extract(data,'$.rawAssetID'),json_extract(data,'$.jpegAssetID') FROM capture_pairs WHERE json_extract(data,'$.sessionID')=?1")?;
    let records = existing
        .query_map([session], |x| {
            Ok((x.get::<_, String>(0)?, x.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<BTreeSet<_>>>()?;
    for (raw, jpg) in facts.unique_candidates() {
        if records.contains(&(raw.to_string(), jpg.to_string())) {
            continue;
        }
        let dismissed_key = if raw < jpg {
            format!("{raw}:{jpg}")
        } else {
            format!("{jpg}:{raw}")
        };
        let dismissed: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pair_dismissals WHERE id=?1)",
            [dismissed_key],
            |x| x.get(0),
        )?;
        if dismissed {
            continue;
        }
        let id = digest_id("direct-pair", &[session, raw, jpg]);
        let body = json!({"id":id,"sessionID":session,"rawAssetID":raw,"jpegAssetID":jpg,"isManual":false});
        let (evidence, qualified) = facts.assess(raw, jpg, &body);
        let lookup = |asset: &str| {
            db.query_row("SELECT f.file_id,f.capture_id FROM lc_asset_files a JOIN lc_files f USING(file_id) WHERE a.asset_id=?1",[asset],|x|Ok((x.get::<_,String>(0)?,x.get::<_,String>(1)?)))
        };
        let (rf, rc) = lookup(raw)?;
        let (jf, jc) = lookup(jpg)?;
        if rc == jc {
            continue;
        }
        let event = digest_id("direct-pair-event", &[command, &id]);
        let result = apply_pair(
            db,
            &json!({"commandID":event,"action":"capture.pair","rawFileID":rf,"jpegFileID":jf,"manual":false,"evidence":evidence}),
            qualified,
        )?;
        if result["status"] == "paired" {
            db.execute(
                "INSERT INTO capture_pairs VALUES(?1,?2)",
                params![id, body.to_string()],
            )?;
        }
    }
    flush(db)?;
    Ok(())
}
