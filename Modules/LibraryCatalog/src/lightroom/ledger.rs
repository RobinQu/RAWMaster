use super::*;
fn fact(
    db: &Connection,
    run: &Run,
    subject: &str,
    key: &str,
    target: Option<&str>,
    f: &Fact,
) -> Result<()> {
    db.execute("INSERT INTO lc_lr_reports(run_id,domain,subject,source_key,field,target_id,status,detail,evidence)
        VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(run_id,domain,subject,source_key,field) DO UPDATE SET
        target_id=excluded.target_id,status=excluded.status,detail=excluded.detail,evidence=excluded.evidence",
        params![run.rid,f.domain,subject,key,f.field,target,f.status,f.detail,f.evidence.to_string()])?;
    Ok(())
}
fn map(
    db: &Connection,
    run: &Run,
    k: &str,
    key: &str,
    target: &str,
    digest: &str,
    rev: Option<i64>,
) -> Result<()> {
    db.execute("INSERT INTO lc_lr_map(source_id,kind,source_key,target_id,source_revision,applied_revision,seen_run) VALUES(?1,?2,?3,?4,?5,?6,?7)
    ON CONFLICT(source_id,kind,source_key) DO UPDATE SET target_id=excluded.target_id,source_revision=excluded.source_revision,applied_revision=excluded.applied_revision,seen_run=excluded.seen_run",params![run.sid,k,key,target,digest,rev,run.rid])?;
    Ok(())
}
fn mapping(
    db: &Connection,
    run: &Run,
    k: &str,
    key: &str,
) -> Result<Option<(String, Option<i64>)>> {
    Ok(db.query_row("SELECT source_revision,applied_revision FROM lc_lr_map WHERE source_id=?1 AND kind=?2 AND source_key=?3",params![run.sid,k,key],|r|Ok((r.get(0)?,r.get(1)?))).optional()?)
}
fn version(db: &Connection, kind: &str, id: &str) -> Result<Option<i64>> {
    let (t, col) = match kind {
        "volume" => ("lc_org_volumes", "volume_id"),
        "folder" => ("lc_org_folders", "folder_id"),
        "image" => ("lc_org_works", "work_id"),
        "collection" => ("lc_org_collections", "collection_id"),
        "AgLibraryFolderStack" | "AgLibraryCollectionStack" => ("lc_org_stacks", "stack_id"),
        _ => return Err("Invalid organization entity".into()),
    };
    Ok(db
        .query_row(
            &format!("SELECT revision FROM {t} WHERE {col}=?1"),
            [id],
            |r| r.get(0),
        )
        .optional()?)
}
fn guard_org(db: &Connection, run: &Run, org: &Org) -> Result<Option<&'static str>> {
    let incoming = hash(&org.command)?;
    let current = version(db, &org.kind, &org.target)?;
    let prior:Option<(String,Option<i64>)>=db.query_row("SELECT source_revision,applied_revision FROM lc_lr_map WHERE source_id=?1 AND kind=?2 AND target_id=?3 ORDER BY seen_run=?4 DESC,source_key=?5 DESC,rowid DESC LIMIT 1",params![run.sid,org.kind,org.target,run.rid,org.key],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    if let Some((seen, applied)) = prior {
        if applied != current {
            db.execute(
                "UPDATE lc_lr_map SET seen_run=?4 WHERE source_id=?1 AND kind=?2 AND source_key=?3",
                params![run.sid, org.kind, org.key, run.rid],
            )?;
            return Ok(Some(
                "Target changed since the previous import; local edit or removal retained",
            ));
        }
        if seen == incoming {
            map(db, run, &org.kind, &org.key, &org.target, &seen, applied)?;
            return Ok(None);
        }
    } else if current.is_some() {
        return Ok(Some("Target identity already belongs to a local object"));
    }
    let mut command = org.command.clone();
    if org.kind == "image" && command["kind"] == "offline" {
        let bound:Option<String>=db.query_row("SELECT b.library_file_id FROM lc_lr_bindings b JOIN lc_org_works w ON w.file_id=b.library_file_id WHERE w.work_id=?1 AND w.kind='original' AND b.source_id=?2 AND b.source_file_id=?3",params![org.target,run.sid,command["metadata"]["sourceFileID"].as_str()],|r|r.get(0)).optional()?;
        if let Some(file) = bound {
            command["kind"] = json!("original");
            command["fileID"] = json!(file);
        }
    }
    if let Some(n) = current {
        command["baseRevision"] = json!(n);
    }
    let out = crate::organization::apply(db, &command)?;
    let applied = out["revision"]
        .as_i64()
        .or(version(db, &org.kind, &org.target)?)
        .ok_or("Organization command did not publish its object")?;
    map(
        db,
        run,
        &org.kind,
        &org.key,
        &org.target,
        &incoming,
        Some(applied),
    )?;
    Ok(None)
}
fn member(db: &Connection, run: &Run, item: &mut Item, m: &Value) -> Result<()> {
    let collection = required(m, "target")?;
    let c = integer(&m["id"])
        .ok_or("Missing membership owner")?
        .to_string();
    let basis = required(m, "basis")?;
    let position = integer(&m["position"]).ok_or("Missing source member position")?;
    let total = integer(&m["total"]).ok_or("Missing expected member count")?;
    if matches!(basis, "unavailableSmartMembers" | "missingMembershipTable") {
        item.report(
            "organization",
            "membership",
            "missing",
            "No stored source snapshot and no equivalent executable rule",
            m.clone(),
        );
        return Ok(());
    }
    let expected = mapping(db, run, "collection", &c)?.and_then(|(_, n)| n);
    let actual = version(db, "collection", collection)?;
    if actual.is_none() || expected != actual {
        item.report(
            "organization",
            "membership",
            "conflict",
            "Target collection or its membership changed locally",
            m.clone(),
        );
        return Ok(());
    }
    if let Some((mark, rev)) = mapping(db, run, "members", &c)? {
        if mark == run.order && rev == actual {
            item.report(
                "organization",
                "membership",
                "mapped",
                "Membership already published at this ordering snapshot",
                m.clone(),
            );
            return Ok(());
        }
    }
    let wid = m["image"].as_str();
    if wid.is_some_and(|id| version(db, "image", id).ok().flatten().is_none()) {
        item.report(
            "organization",
            "membership",
            "missing",
            "Source member work could not be created",
            m.clone(),
        );
        return Ok(());
    }
    let finish = total == 0 || position + 1 == total;
    let reply = crate::organization::apply(
        db,
        &json!({"action":"org.stageMembers","importID":id(&["lrMembers",&run.rid,&run.pass.to_string(),&c]),"collectionID":collection,"baseRevision":expected,"start":position,"workIDs":wid.into_iter().collect::<Vec<_>>(),"finish":finish,"expectedCount":total}),
    )?;
    if finish {
        db.execute("UPDATE lc_lr_reports SET status='mapped',detail='Ordered source membership snapshot published' WHERE run_id=?1 AND domain='organization' AND subject='collectionMember' AND field='membership' AND target_id=?2 AND status='pending'",params![run.rid,collection])?;
        let revision = reply["revision"]
            .as_i64()
            .or(version(db, "collection", collection)?)
            .ok_or("Published collection revision missing")?;
        map(
            db,
            run,
            "members",
            &c,
            collection,
            &run.order,
            Some(revision),
        )?;
        db.execute("UPDATE lc_lr_map SET applied_revision=?4 WHERE source_id=?1 AND kind='collection' AND source_key=?2 AND target_id=?3",params![run.sid,c,collection,revision])?;
    }
    item.report(
        "organization",
        "membership",
        if finish { "mapped" } else { "pending" },
        if basis == "equivalentRule" {
            "Source-equivalent rating rule evaluated against the frozen images"
        } else {
            "Source manual position captured"
        },
        m.clone(),
    );
    Ok(())
}
fn apply_inner(db: &Connection, run: &Run, item: &mut Item, coherent: bool) -> Result<()> {
    if let Some((work, look)) = item.look.as_mut() {
        if !coherent {
            look.revision_bound = false;
            if look.decoded {
                look.state = "decodedRevisionUncertain".into();
            }
        }
        // Reopening without the Lightroom disk must retain the strongest evidence already captured in this run.
        let saved: Option<String> = db
            .query_row(
                "SELECT manifest FROM lc_lr_looks WHERE run_id=?1 AND work_id=?2",
                params![run.rid, work.as_str()],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(saved) = saved {
            let prev: preview::Look = serde_json::from_str(&saved)?;
            if (prev.decoded && !look.decoded) || (prev.revision_bound && !look.revision_bound) {
                *look = prev;
            }
        }
        let org = item
            .org
            .iter_mut()
            .find(|o| o.target == *work)
            .ok_or("Missing appearance owner")?;
        let a = &mut org.command["appearance"];
        a["revisionBound"] = json!(look.revision_bound);
        a["state"] = json!(look.state);
        a["width"] = json!(look.width);
        a["height"] = json!(look.height);
        a["resourceID"] = json!(look.resource.as_ref().map(|r| &r.resource_id));
        let v = hash(a)?;
        org.command["versionID"] = json!(id(&[
            "lightroom",
            &run.sid,
            "version",
            &format!("{}:{v}", item.key)
        ]));
        if let Some(f) = item
            .facts
            .iter_mut()
            .find(|f| f.domain == "appearance" && f.field == "preview")
        {
            f.status = if look.revision_bound {
                "mapped"
            } else if look.decoded {
                "uncertain"
            } else {
                "missing"
            }
            .into();
            f.detail = look.state.clone();
            f.evidence = org.command["appearance"].clone();
        }
    }
    for (_, _, res) in &item.links {
        resources::register(db, res)?;
    }
    let main_target = item
        .org
        .last()
        .map(|o| o.target.clone())
        .or_else(|| {
            item.file
                .as_ref()?
                .get("fileID")?
                .as_str()
                .map(str::to_owned)
        })
        .or_else(|| {
            item.members
                .as_ref()?
                .get("target")?
                .as_str()
                .map(str::to_owned)
        });
    let mut conflicts = Vec::new();
    for org in &item.org {
        if let Some(reason) = guard_org(db, run, org)? {
            conflicts.push((org.target.clone(), reason));
        }
    }
    for (target, reason) in conflicts {
        item.report(
            "organization",
            &format!("localEdit:{target}"),
            "conflict",
            reason,
            json!(target),
        );
    }
    if let Some((work, fields)) = item.metadata.as_ref() {
        if version(db, "image", work)?.is_some() {
            let recent:Option<String>=db.query_row("SELECT fields_json FROM lc_inspect_imports WHERE work_id=?1 AND source_catalog=?2 AND source_object=?3 ORDER BY rowid DESC LIMIT 1",params![work,run.sid,item.key],|r|r.get(0)).optional()?;
            if recent
                .as_deref()
                .map(serde_json::from_str::<Value>)
                .transpose()?
                .as_ref()
                != Some(fields)
            {
                crate::inspection::import_fields(
                    db,
                    work,
                    &run.sid,
                    &item.key,
                    &hash(&json!([run.snapshot, fields]))?,
                    fields,
                )?;
            }
            let mut manual_stmt = db.prepare_cached(
                "SELECT field FROM lc_inspect_manual WHERE work_id=? ORDER BY field",
            )?;
            let overrides = manual_stmt
                .query_map([work], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            for field in overrides {
                item.report(
                    "metadata",
                    &format!("manualOverride:{field}"),
                    "conflict",
                    "The source value is retained under this work's local override",
                    json!(field),
                );
            }
        } else {
            item.report(
                "metadata",
                "localEdit",
                "conflict",
                "Local work was removed; source fields remain in the catalog snapshot",
                Value::Null,
            );
        }
    }
    if let Some(f) = item.file.as_ref() {
        db.execute("INSERT INTO lc_lr_files(source_id,file_id,source_key,folder_id,source_path,file_type,checksum_json) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(source_id,file_id) DO UPDATE SET folder_id=excluded.folder_id,source_path=excluded.source_path,file_type=excluded.file_type,checksum_json=excluded.checksum_json",params![run.sid,required(f,"fileID")?,item.key,required(f,"folderID")?,f["path"].as_str().unwrap_or(""),f["type"].as_str().unwrap_or(""),f["checksums"].to_string()])?;
        db.execute("INSERT INTO lc_lr_file_versions VALUES(?1,?2,?3,?4) ON CONFLICT(run_id,file_id) DO NOTHING",params![run.rid,required(f,"fileID")?,f["path"].as_str().unwrap_or(""),f["checksums"].to_string()])?;
        map(
            db,
            run,
            "file",
            &item.key,
            required(f, "fileID")?,
            &hash(f)?,
            None,
        )?;
    }
    if let Some((work, l)) = item.look.as_ref() {
        if let Some(ref res) = l.resource {
            resources::register(db, res)?;
        }
        db.execute("INSERT INTO lc_lr_looks(run_id,work_id,image_key,cache_uuid,cache_digest,develop_digest,level,width,height,candidate,decoded,revision_bound,resource_id,state,manifest) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15) ON CONFLICT(run_id,work_id) DO UPDATE SET cache_uuid=excluded.cache_uuid,cache_digest=excluded.cache_digest,develop_digest=excluded.develop_digest,level=excluded.level,width=excluded.width,height=excluded.height,candidate=excluded.candidate,decoded=excluded.decoded,revision_bound=excluded.revision_bound,resource_id=excluded.resource_id,state=excluded.state,manifest=excluded.manifest",params![run.rid,work,item.key,l.cache_uuid,l.cache_digest,l.develop_digest,l.level,l.width,l.height,l.candidate,l.decoded,l.revision_bound,l.resource.as_ref().map(|r|&r.resource_id),l.state,serde_json::to_string(l)?])?;
    }
    for (role, locator, res) in &item.links {
        db.execute("INSERT OR IGNORE INTO lc_lr_links(run_id,kind,source_key,role,resource_id,locator) VALUES(?1,?2,?3,?4,?5,?6)",params![run.rid,item.subject,item.key,role,res.resource_id,locator])?;
    }
    if let Some(m) = item.members.take() {
        member(db, run, item, &m)?;
    }
    for f in &item.facts {
        fact(db, run, &item.subject, &item.key, main_target.as_deref(), f)?;
    }
    Ok(())
}
pub(super) fn apply(db: &Connection, run: &Run, item: &mut Item, coherent: bool) -> Result<()> {
    db.execute_batch("SAVEPOINT lr_item")?;
    match apply_inner(db, run, item, coherent) {
        Ok(()) => {
            db.execute_batch("RELEASE lr_item")?;
            Ok(())
        }
        Err(e) => {
            db.execute_batch("ROLLBACK TO lr_item; RELEASE lr_item")?;
            if let Some(sql) = e.downcast_ref::<rusqlite::Error>() {
                if sql.sqlite_error_code() != Some(rusqlite::ErrorCode::ConstraintViolation) {
                    return Err(e);
                }
            }
            let f = Fact {
                domain: "organization".into(),
                field: "object".into(),
                status: "conflict".into(),
                detail: e.to_string(),
                evidence: Value::Null,
            };
            fact(db, run, &item.subject, &item.key, None, &f)
        }
    }
}
pub(super) fn finish(db: &Connection, run: &Run) -> Result<()> {
    db.execute("UPDATE lc_lr_reports SET status='missing',detail='Incomplete collection membership stage; previous target membership retained' WHERE run_id=?1 AND domain='organization' AND status='pending'",[&run.rid])?;
    db.execute("INSERT INTO lc_lr_reports(run_id,domain,subject,source_key,field,target_id,status,detail,evidence)
        SELECT ?2,'organization',kind,source_key,'sourceObject',target_id,'missing','Absent in this source revision; previous target retained','null' FROM lc_lr_map WHERE source_id=?1 AND seen_run!=?2
        ON CONFLICT(run_id,domain,subject,source_key,field) DO UPDATE SET status=excluded.status,detail=excluded.detail",params![run.sid,run.rid])?;
    Ok(())
}
pub(super) fn status(db: &Connection, rid: &str) -> Result<Value> {
    let (source, version, phase, cursor, pass, state): (String, String, i64, i64, i64, String) = db
        .query_row(
            "SELECT source_id,version,phase,cursor,pass,state FROM lc_lr_runs WHERE run_id=?1",
            [rid],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )?;
    let mut counts = json!({"organization":{},"metadata":{},"appearance":{}});
    let mut q = db.prepare(
        "SELECT domain,status,n FROM lc_lr_counts WHERE run_id=?1 AND n>0 ORDER BY domain,status",
    )?;
    for r in q.query_map([rid], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, i64>(2)?,
        ))
    })? {
        let (d, s, n) = r?;
        counts[&d][&s] = json!(n);
    }
    let phase = PHASES
        .get(usize::try_from(phase)?)
        .copied()
        .unwrap_or("complete");
    let effective_state = if state == "complete" && phase != "complete" {
        "running"
    } else {
        &state
    };
    Ok(
        json!({"runID":rid,"sourceID":source,"version":version,"state":effective_state,"phase":phase,"cursor":cursor,"pass":pass,"counts":counts}),
    )
}
pub(super) fn runs(db: &Connection) -> Result<Value> {
    let mut q=db.prepare("SELECT run_id,source_id,source_path,version,state,started_at FROM lc_lr_runs ORDER BY rowid DESC LIMIT 100")?;
    let rows=q.query_map([],|r|Ok(json!({"runID":r.get::<_,String>(0)?,"sourceID":r.get::<_,String>(1)?,"sourcePath":r.get::<_,String>(2)?,"version":r.get::<_,String>(3)?,"state":r.get::<_,String>(4)?,"startedAt":r.get::<_,String>(5)?})))?.collect::<std::result::Result<Vec<_>,_>>()?;
    Ok(json!({"runs":rows}))
}
pub(super) fn report(db: &Connection, r: &Value) -> Result<Value> {
    let rid = required(r, "runID")?;
    let d = required(r, "domain")?;
    if !matches!(d, "organization" | "metadata" | "appearance") {
        return Err("Unknown reconciliation domain".into());
    }
    let cursor = r["cursor"].as_i64().unwrap_or(0);
    let limit = r["limit"].as_i64().unwrap_or(60).clamp(1, 250);
    let status = r["status"].as_str();
    let mut q=db.prepare("SELECT rowid,subject,source_key,field,target_id,status,detail,evidence FROM lc_lr_reports WHERE run_id=?1 AND domain=?2 AND rowid>?3 AND (?4 IS NULL OR status=?4) ORDER BY rowid LIMIT ?5")?;
    let mut rows = Vec::new();
    let mut next = None;
    for row in q.query_map(params![rid,d,cursor,status,limit+1],|r|Ok((r.get::<_,i64>(0)?,json!({"subject":r.get::<_,String>(1)?,"sourceKey":r.get::<_,String>(2)?,"field":r.get::<_,String>(3)?,"targetID":r.get::<_,Option<String>>(4)?,"status":r.get::<_,String>(5)?,"detail":r.get::<_,String>(6)?}),r.get::<_,String>(7)?)))?{
        let(n,mut value,evidence)=row?;if rows.len()==limit as usize{next=rows.last().and_then(|v:&Value|v["cursor"].as_i64());break;}
        value["cursor"]=json!(n);value["evidence"]=serde_json::from_str(&evidence)?;rows.push(value);
    }
    let mut result = status_for_report(db, rid, d)?;
    result["items"] = json!(rows);
    result["nextCursor"] = json!(next);
    Ok(result)
}
fn status_for_report(db: &Connection, rid: &str, d: &str) -> Result<Value> {
    let mut v = status(db, rid)?;
    if d == "appearance" {
        v["previews"]=db.query_row("SELECT count(*),coalesce(sum(candidate),0),coalesce(sum(decoded),0),coalesce(sum(revision_bound),0) FROM lc_lr_looks WHERE run_id=?1",[rid],|r|Ok(json!({"works":r.get::<_,i64>(0)?,"candidate":r.get::<_,i64>(1)?,"decoded":r.get::<_,i64>(2)?,"revisionBound":r.get::<_,i64>(3)?})))?;
    }
    Ok(v)
}
