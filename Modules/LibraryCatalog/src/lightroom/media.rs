use super::*;

struct Historical {
    id: String,
    sha: String,
    run: String,
    image: String,
    develop: Option<String>,
    bound: bool,
}
impl Historical {
    fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            sha: row.get(1)?,
            run: row.get(2)?,
            image: row.get(3)?,
            develop: row.get(4)?,
            bound: row.get(5)?,
        })
    }
}

pub(super) fn work(catalog: &Path, r: &Value) -> Result<Value> {
    let db = target(catalog, false)?;
    let work = required(r, "workID")?;
    let (base,version):(String,Option<String>)=db.query_row(
        "SELECT visible.base_work_id,w.active_version_id FROM lc_org_visible_sources visible JOIN lc_org_works w USING(work_id)
         WHERE w.work_id=?1",[work],|row|Ok((row.get(0)?,row.get(1)?))).optional()?.ok_or("Work is outside this library")?;
    let asked = r["sourceRunID"].as_str();
    let owner = if db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_lr_looks WHERE work_id=?1)",
        [work],
        |r| r.get::<_, bool>(0),
    )? {
        work
    } else {
        &base
    };
    let latest: Option<(String, String)> = db
        .query_row(
            "SELECT l.run_id,l.state FROM lc_lr_looks l JOIN lc_lr_runs s USING(run_id)
         WHERE l.work_id=?1 ORDER BY s.rowid DESC LIMIT 1",
            [owner],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((latest_run, latest_state)) = latest {
        // A user copy inherits an exact descriptor at creation. Follow that work's own
        // version chain and verify both the source photograph and resource, keeping later
        // edits or snapshots of the master from substituting another appearance.
        let pinned:Option<Historical>=db.query_row(
            "WITH RECURSIVE lineage(id,parent,source,depth) AS (
                 SELECT version_id,parent_version_id,appearance_json,0 FROM lc_org_versions WHERE work_id=?1 AND version_id=?2
                 UNION ALL SELECT v.version_id,v.parent_version_id,v.appearance_json,depth+1 FROM lc_org_versions v JOIN lineage x
                 ON v.version_id=x.parent AND v.work_id=?1)
             SELECT r.resource_id,r.sha256,l.run_id,l.image_key,l.develop_digest,
                    l.revision_bound AND CASE WHEN json_extract(x.source,'$.origin')='lightroom'
                      THEN coalesce(json_extract(x.source,'$.revisionBound'),0)
                      ELSE coalesce(json_extract(x.source,'$.source.revisionBound'),0) END
             FROM lineage x JOIN lc_lr_looks l ON l.work_id=?3 AND l.decoded=1
             JOIN lc_resources r ON r.resource_id=l.resource_id AND r.kind='historicalLook'
             JOIN lc_lr_runs s ON s.run_id=l.run_id
             WHERE (?4 IS NULL OR l.run_id=?4) AND (
               (json_extract(x.source,'$.origin')='lightroom' AND l.resource_id=json_extract(x.source,'$.resourceID')
                AND l.image_key=CAST(json_extract(x.source,'$.sourceImageID') AS TEXT)
                AND l.develop_digest IS json_extract(x.source,'$.developDigest')
                AND s.source_id=json_extract(x.source,'$.sourceCatalogID'))
               OR (json_extract(x.source,'$.origin')='rawmasterLocalDevelop' AND json_extract(x.source,'$.schemaVersion')=1
                AND json_extract(x.source,'$.source.kind')='historicalLook'
                AND l.work_id=json_extract(x.source,'$.source.sourceWorkID')
                AND l.resource_id=json_extract(x.source,'$.source.resourceID')
                AND l.run_id=json_extract(x.source,'$.source.sourceRunID')
                AND r.sha256=json_extract(x.source,'$.source.sha256')))
             ORDER BY x.depth,s.rowid DESC LIMIT 1",
            params![work,version,owner,asked],Historical::row).optional()?;
        let selected = if pinned.is_none() && owner == work {
            // A new run with no preview may still have an older available photo. An explicit
            // generation only returns bytes proven for that generation.
            db.query_row(
                "SELECT r.resource_id,r.sha256,l.run_id,l.image_key,l.develop_digest,l.revision_bound
                 FROM lc_lr_looks l JOIN lc_lr_runs s USING(run_id) JOIN lc_resources r ON r.resource_id=l.resource_id
                 WHERE l.work_id=?1 AND l.decoded=1 AND (?2 IS NULL OR l.run_id=?2) ORDER BY s.rowid DESC LIMIT 1",
                params![work,asked],Historical::row).optional()?
        } else {
            pinned
        };
        if let Some(h) = selected {
            let path = source::verified_resource(catalog, &db, &h.id)?;
            return Ok(
                json!({"path":path,"resourceID":h.id,"sha256":h.sha,"kind":"historical","version":format!("{}/{}",h.run,h.image),
               "workVersionID":version,"sourceWorkID":owner,"developDigest":h.develop,"revisionBound":h.bound,
               "sourceRunID":h.run,"latestRunID":latest_run,"latestState":latest_state,"historicalGeneration":if h.run==latest_run{"current"}else{"previous"}}),
            );
        }
    }
    if asked.is_some() {
        return Ok(Value::Null);
    }
    let derived:Option<(String,String,String,String)>=db.query_row(
        "SELECT r.resource_id,r.sha256,w.kind,d.job_id FROM lc_org_derived d JOIN lc_org_works w USING(work_id)
         JOIN lc_resources r USING(resource_id) WHERE d.work_id=?1",[&base],
        |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    if let Some((id, sha, kind, job)) = derived {
        let path = source::verified_resource(catalog, &db, &id)?;
        return Ok(
            json!({"path":path,"resourceID":id,"sha256":sha,"kind":kind,"version":job,"sourceWorkID":base,"workVersionID":version,"revisionBound":true}),
        );
    }
    Ok(Value::Null)
}
