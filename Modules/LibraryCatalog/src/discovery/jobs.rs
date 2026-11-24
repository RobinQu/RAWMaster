use super::{cache, digest, field, settings, Input, FACES, FACE_DIMENSIONS, LEGACY_FACES, SCENE};
use crate::{query::works::discovery_inputs, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use uuid::Uuid;
pub fn model(kind: &str) -> Result<&'static str> {
    match kind {
        "scene" => Ok(SCENE),
        "faces" => Ok(FACES),
        _ => Err("unknown discovery job kind".into()),
    }
}
fn enabled(db: &Connection, kind: &str) -> Result<bool> {
    model(kind)?;
    Ok(settings(db)?[kind] == true)
}
pub fn for_work(db: &Connection, id: &str) -> Result<Option<Input>> {
    let mut item = discovery_inputs(db, &json!({"workID":id}))?.pop();
    if let Some(i) = item.as_mut() {
        i.proxy_sha = proxy(db, i)?;
    }
    Ok(item)
}
fn proxy(db: &Connection, i: &Input) -> Result<Option<String>> {
    let mut q=db.prepare_cached("SELECT DISTINCT proxy_sha FROM lc_discover_outputs WHERE work_id=? AND input_version=? ORDER BY proxy_sha")?;
    let rows = q.query_map(params![i.work_id, i.input_version], |r| {
        r.get::<_, String>(0)
    })?;
    let Some(base) = db.path().and_then(|p| std::path::Path::new(p).parent()) else {
        return Ok(None);
    };
    for key in rows {
        let key = key?;
        if key.len() == 64
            && key
                .bytes()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
            && base
                .join("LibraryIndexes/discovery-proxies")
                .join(&key[0..2])
                .join(format!("{key}.jpg"))
                .is_file()
        {
            return Ok(Some(key));
        }
    }
    Ok(None)
}
fn list(v: &Value) -> Result<Vec<&str>> {
    v.as_array()
        .ok_or("expected an ID list")?
        .iter()
        .map(|v| {
            v.as_str()
                .filter(|s| !s.is_empty())
                .ok_or_else(|| "invalid ID".into())
        })
        .collect()
}
fn output_key(db: &Connection, i: &Input, kind: &str) -> Result<Option<(String, i64)>> {
    Ok(db.query_row("SELECT coalesce(feature_key,''),detections FROM lc_discover_outputs WHERE work_id=? AND kind=? AND input_version=? AND model=?",params![i.work_id,kind,i.input_version,model(kind)?],|r|Ok((r.get(0)?,r.get(1)?))).optional()?)
}
pub fn scene(db: &Connection, c: Option<&Connection>, i: &Input) -> Result<Option<Vec<f32>>> {
    if let Some((k, _)) = output_key(db, i, "scene")? {
        cache::get(c, &k, SCENE, 768)
    } else {
        Ok(None)
    }
}
pub fn covered(db: &Connection, c: Option<&Connection>, i: &Input, kind: &str) -> Result<bool> {
    let Some((key, count)) = output_key(db, i, kind)? else {
        return Ok(false);
    };
    if kind == "scene" {
        return Ok(cache::get(c, &key, SCENE, 768)?.is_some());
    }
    let mut stmt = db.prepare_cached(
        "SELECT feature_key FROM lc_discover_faces WHERE work_id=? AND input_version=? AND model=?",
    )?;
    let keys = stmt.query_map(params![i.work_id, i.input_version, FACES], |r| {
        r.get::<_, String>(0)
    })?;
    let mut seen = 0;
    for k in keys {
        if cache::get(c, &k?, FACES, FACE_DIMENSIONS)?.is_none() {
            return Ok(false);
        }
        seen += 1;
    }
    Ok(seen == count)
}
pub fn enqueue(db: &Connection, b: &Value) -> Result<Value> {
    let kinds = if b.get("kinds").is_some() {
        list(&b["kinds"])?
    } else {
        vec![field(b, "kind")?]
    };
    if kinds.is_empty() {
        return Err("no index kind selected".into());
    }
    for k in &kinds {
        if !enabled(db, k)? {
            return Err(format!("{k} indexing is disabled").into());
        }
    }
    let scope = b.get("scope").cloned().unwrap_or_else(|| json!({}));
    let selected = b
        .get("workIDs")
        .map(|ids| list(ids).map(|v| v.into_iter().map(str::to_owned).collect::<Vec<_>>()))
        .transpose()?;
    let items = crate::query::works::discovery_inputs_selected(db, &scope, selected.as_deref())?;
    let c = cache::open(db, false)?;
    let mut queued = 0;
    let mut already = 0;
    let mut unavailable = 0;
    for i in items {
        for kind in &kinds {
            if covered(db, c.as_ref(), &i, kind)? {
                already += 1;
                continue;
            }
            if i.path.is_none() && proxy(db, &i)?.is_none() {
                unavailable += 1;
                continue;
            }
            let model = model(kind)?;
            let jid = digest(serde_json::to_vec(&(
                &i.work_id,
                kind,
                &i.input_version,
                model,
            ))?);
            queued+=db.execute("INSERT INTO lc_discover_jobs(job_id,work_id,kind,input_version,model,state) VALUES(?,?,?,?,?,'queued')
     ON CONFLICT(work_id,kind,input_version,model) DO UPDATE SET state='queued',lease=NULL,lease_until=NULL,error=NULL WHERE state IN('done','stopped','failed','stale')",
     params![jid,i.work_id,kind,i.input_version,model])?;
        }
    }
    Ok(json!({"queued":queued,"alreadyIndexed":already,"unavailable":unavailable}))
}
pub fn claim(db: &Connection, b: &Value) -> Result<Value> {
    if settings(db)?["paused"] == true {
        return Ok(json!({"job":null}));
    }
    let kind = b.get("kind").map(|_| field(b, "kind")).transpose()?;
    if let Some(k) = kind {
        model(k)?;
    }
    let ttl = b
        .get("leaseSeconds")
        .map(|v| {
            v.as_i64()
                .filter(|d| (5..=3600).contains(d))
                .ok_or("invalid job lease")
        })
        .transpose()?
        .unwrap_or(120);
    loop {
        let row:Option<(String,String,String,String,String)>=db.query_row("SELECT job_id,work_id,kind,input_version,model FROM lc_discover_jobs WHERE
    (state='queued' OR(state='running' AND lease_until<=unixepoch())) AND (?1 IS NULL OR kind=?1) ORDER BY rowid LIMIT 1",[kind],
    |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?;
        let Some((id, work, k, version, m)) = row else {
            return Ok(json!({"job":null}));
        };
        if model(&k)? != m {
            // An older face generation can have an entire library queued.
            db.execute("UPDATE lc_discover_jobs SET state='stale',lease=NULL,lease_until=NULL WHERE kind=? AND model=? AND state IN('queued','running')",
                params![k,m])?;
            continue;
        }
        let input = for_work(db, &work)?;
        let allowed = enabled(db, &k)?;
        if !allowed
            || input.as_ref().is_none_or(|i| {
                i.input_version != version || (i.path.is_none() && i.proxy_sha.is_none())
            })
        {
            db.execute(
                "UPDATE lc_discover_jobs SET state=?,lease=NULL,lease_until=NULL WHERE job_id=?",
                params![if allowed { "stale" } else { "stopped" }, id],
            )?;
            continue;
        }
        let lease = Uuid::new_v4().to_string();
        db.execute("UPDATE lc_discover_jobs SET state='running',lease=?,lease_until=unixepoch()+?,attempts=attempts+1,error=NULL WHERE job_id=?",params![lease,ttl,id])?;
        return Ok(
            json!({"job":{"version":1,"jobID":id,"workID":work,"kind":k,"model":m,"inputVersion":version,"lease":lease,"input":input}}),
        );
    }
}
pub fn stop(db: &Connection, b: &Value) -> Result<Value> {
    let work = b.get("workID").map(|_| field(b, "workID")).transpose()?;
    let id = b.get("jobID").map(|_| field(b, "jobID")).transpose()?;
    let kind = b.get("kind").map(|_| field(b, "kind")).transpose()?;
    if let Some(k) = kind {
        model(k)?;
    }
    if let Some(lease) = b.get("lease").map(|_| field(b, "lease")).transpose()? {
        let job = id.ok_or("leased cancellation requires jobID")?;
        let count = db.execute(
            "UPDATE lc_discover_jobs SET state='stopped',lease=NULL,lease_until=NULL
            WHERE job_id=?1 AND state='running' AND lease=?2 AND lease_until>unixepoch()",
            params![job, lease],
        )?;
        return Ok(json!({"stopped":count}));
    }
    if id.is_none() && work.is_none() && kind.is_none() {
        db.execute(
            "UPDATE lc_discover_state SET paused=1,revision=revision+1 WHERE id=1 AND paused=0",
            [],
        )?;
    }
    let count=db.execute("UPDATE lc_discover_jobs SET state='stopped',lease=NULL,lease_until=NULL WHERE state IN('queued','running') AND (?1 IS NULL OR job_id=?1) AND (?2 IS NULL OR work_id=?2) AND (?3 IS NULL OR kind=?3)",params![id,work,kind])?;
    Ok(json!({"stopped":count}))
}
pub fn finish(db: &Connection, b: &Value, fail: bool) -> Result<Value> {
    let id = field(b, "jobID")?;
    let lease = field(b, "lease")?;
    let row:Option<(String,String,String,String)>=db.query_row("SELECT work_id,kind,input_version,model FROM lc_discover_jobs WHERE job_id=? AND lease=? AND state='running' AND lease_until>unixepoch()",params![id,lease],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    let Some((work, k, version, m)) = row else {
        return Ok(json!({"status":"expired"}));
    };
    if !enabled(db, &k)?
        || for_work(db, &work)?.is_none_or(|i| i.input_version != version)
        || m != model(&k)?
    {
        db.execute(
            "UPDATE lc_discover_jobs SET state='stale',lease=NULL,lease_until=NULL WHERE job_id=?",
            [id],
        )?;
        return Ok(json!({"status":"stale"}));
    }
    if fail {
        let err = field(b, "error")?;
        db.execute("UPDATE lc_discover_jobs SET state='failed',lease=NULL,lease_until=NULL,error=? WHERE job_id=?",params![err,id])?;
        return Ok(json!({"status":"failed"}));
    }
    if field(b, "inputVersion")? != version || field(b, "model")? != m {
        return Err("work version or model mismatch".into());
    }
    let proxy = field(b, "proxySHA256")?;
    if proxy.len() != 64
        || !proxy
            .bytes()
            .all(|x| x.is_ascii_hexdigit() && !x.is_ascii_uppercase())
    {
        return Err("invalid proxy digest".into());
    }
    let key = digest(serde_json::to_vec(&(&work, &version, &m, proxy))?);
    let c = cache::open(db, true)?.ok_or("feature cache unavailable")?;
    let tx = c.unchecked_transaction()?;
    let count = if k == "scene" {
        cache::put(&tx, &key, &m, &cache::normalized(&b["vector"], 768)?)?;
        1
    } else {
        let faces = b["faces"]
            .as_array()
            .filter(|a| a.len() <= 5000)
            .ok_or("invalid face output")?;
        super::people::preserve_work_anchor_proofs(db, &work)?;
        db.execute(
            "DELETE FROM lc_discover_faces WHERE work_id=? AND input_version=? AND model=?",
            params![work, version, m],
        )?;
        for (ix, f) in faces.iter().enumerate() {
            let region = super::people::rectangle(&f["box"])?;
            let pts = f["landmarks"]
                .as_array()
                .filter(|a| a.len() == 5)
                .ok_or("expected five facial landmarks")?;
            if !pts.iter().all(|p| {
                p.as_array().is_some_and(|p| {
                    p.len() == 2
                        && p.iter()
                            .all(|a| a.as_f64().is_some_and(|a| (0.0..=1.).contains(&a)))
                })
            }) {
                return Err("invalid facial landmarks".into());
            }
            let confidence = f["confidence"]
                .as_f64()
                .filter(|n| (0.0..=1.).contains(n))
                .ok_or("invalid face confidence")?;
            let fid = digest(serde_json::to_vec(&(&key, ix))?);
            cache::put(
                &tx,
                &fid,
                &m,
                &cache::normalized(&f["vector"], FACE_DIMENSIONS)?,
            )?;
            db.execute(
                "INSERT INTO lc_discover_faces VALUES(?,?,?,?,?,?,?,?)",
                params![
                    fid,
                    work,
                    version,
                    m,
                    serde_json::to_string(&region)?,
                    serde_json::to_string(pts)?,
                    confidence,
                    fid
                ],
            )?;
        }
        faces.len()
    };
    tx.commit()?;
    db.execute(
        "INSERT OR REPLACE INTO lc_discover_outputs VALUES(?,?,?,?,?,?,?)",
        params![
            work,
            k,
            version,
            m,
            proxy,
            if k == "scene" { Some(&key) } else { None },
            count as i64
        ],
    )?;
    db.execute("UPDATE lc_discover_jobs SET state='done',lease=NULL,lease_until=NULL,error=NULL WHERE job_id=?",[id])?;
    Ok(json!({"status":"done","detections":count}))
}
pub fn state(db: &Connection) -> Result<Value> {
    let mut stmt = db.prepare(
        "SELECT kind,state,count(*) FROM lc_discover_jobs WHERE (kind='scene' AND model=?1) OR (kind='faces' AND model=?2) GROUP BY kind,state ORDER BY kind,state",
    )?;
    let groups=stmt.query_map(params![SCENE,FACES],|r|Ok(json!({"kind":r.get::<_,String>(0)?,"state":r.get::<_,String>(1)?,"count":r.get::<_,i64>(2)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let mut stmt=db.prepare("SELECT work_id,kind,state,error FROM lc_discover_jobs WHERE state='failed' AND ((kind='scene' AND model=?1) OR (kind='faces' AND model=?2)) ORDER BY rowid DESC LIMIT 60")?;
    let failed=stmt.query_map(params![SCENE,FACES],|r|Ok(json!({"workID":r.get::<_,String>(0)?,"kind":r.get::<_,String>(1)?,"state":r.get::<_,String>(2)?,"error":r.get::<_,Option<String>>(3)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({"counts":groups,"failed":failed}))
}

pub fn pending(db: &Connection) -> Result<Value> {
    let config = settings(db)?;
    let tip = cache::tip(db)?;
    if config["paused"] == true {
        return Ok(json!({"queued":false,"kinds":[],"watermark":tip,"paused":true}));
    }
    let mut due = Vec::new();
    for k in ["scene", "faces"] {
        if config[k] != true {
            continue;
        }
        let sync: Option<(i64, String, Option<i64>)> = db
            .query_row(
                "SELECT watermark,model,scan_target FROM lc_discover_schedule WHERE kind=?",
                [k],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if sync.is_none_or(|(w, m, scan)| w != tip || m != model(k).unwrap() || scan.is_some()) {
            due.push(k);
        }
    }
    let ready:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_discover_jobs WHERE state='queued' OR (state='running' AND lease_until<=unixepoch()))",[],|r|r.get(0))?;
    Ok(json!({"kinds":due,"queued":ready,"watermark":tip}))
}
pub fn sync(db: &Connection, body: &Value) -> Result<Value> {
    let only_kind = body.get("kind").map(|_| field(body, "kind")).transpose()?;
    if let Some(kind) = only_kind {
        model(kind)?;
    }
    let pending = pending(db)?;
    let tip = pending["watermark"].as_i64().unwrap();
    let mut queued = 0;
    for k in pending["kinds"].as_array().unwrap() {
        let k = k.as_str().unwrap();
        if only_kind.is_some_and(|kind| kind != k) {
            continue;
        }
        let state:Option<(i64,Option<i64>,Option<String>)>=db.query_row("SELECT watermark,scan_target,after_work FROM lc_discover_schedule WHERE kind=? AND model=?",params![k,model(k)?],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
        let (previous, active, after) = state.unwrap_or((-1, None, None));
        let target = active.unwrap_or(tip);
        let wide=previous<0||db.query_row("SELECT EXISTS(SELECT 1 FROM lc_changes WHERE seq>? AND seq<=? AND asset_id IS NULL)",params![previous,target],|r|r.get::<_,bool>(0))?;
        let last = after.as_deref().unwrap_or("");
        let mut stmt = if wide {
            db.prepare(
                "SELECT work_id FROM lc_org_works WHERE work_id>?1 ORDER BY work_id LIMIT 129",
            )?
        } else {
            db.prepare("SELECT DISTINCT v.work_id FROM lc_changes ch JOIN lc_catalog_files f ON f.asset_id=ch.asset_id JOIN lc_org_visible_sources v ON v.source_file_id=f.file_id WHERE v.work_id>?1 AND ch.seq>?2 AND ch.seq<=?3 ORDER BY v.work_id LIMIT 129")?
        };
        let mut rows = if wide {
            stmt.query([last])?
        } else {
            stmt.query(params![last, previous, target])?
        };
        let mut ids = Vec::<String>::new();
        while let Some(row) = rows.next()? {
            ids.push(row.get(0)?);
        }
        drop(rows);
        drop(stmt);
        let more = ids.len() > 128;
        ids.truncate(128);
        if !ids.is_empty() {
            queued += enqueue(db, &json!({"kind":k,"workIDs":ids}))?["queued"]
                .as_i64()
                .unwrap();
        }
        db.execute("INSERT INTO lc_discover_schedule VALUES(?,?,?,?,?) ON CONFLICT(kind) DO UPDATE SET watermark=excluded.watermark,model=excluded.model,scan_target=excluded.scan_target,after_work=excluded.after_work",
          params![k,if more{previous}else{target},model(k)?,more.then_some(target),if more{ids.last()}else{None}])?;
    }
    Ok(json!({"queued":queued,"watermark":tip}))
}
pub fn clear(db: &Connection, b: &Value) -> Result<Value> {
    let k = field(b, "kind")?;
    let m = model(k)?;
    stop(db, &json!({"kind":k}))?;
    let count = db.execute("DELETE FROM lc_discover_outputs WHERE kind=?", [k])?;
    if k == "faces" {
        super::people::preserve_anchor_proofs(db)?;
        db.execute("DELETE FROM lc_discover_faces", [])?;
    }
    db.execute("DELETE FROM lc_discover_jobs WHERE kind=?", [k])?;
    db.execute("DELETE FROM lc_discover_schedule WHERE kind=?", [k])?;
    if let Some(c) = cache::open(db, false)? {
        drop(c);
        if let Some(c) = cache::open(db, true)? {
            c.execute("DELETE FROM features WHERE model=?", [m])?;
            if k == "faces" {
                c.execute("DELETE FROM features WHERE model=?", [LEGACY_FACES])?;
            }
        }
    }
    Ok(json!({"removed":count}))
}

pub fn resume(db: &Connection) -> Result<Value> {
    db.execute(
        "UPDATE lc_discover_state SET paused=0,revision=revision+1 WHERE id=1 AND paused=1",
        [],
    )?;
    let count=db.execute("UPDATE lc_discover_jobs SET state='queued',error=NULL WHERE state='stopped' AND ((kind='scene' AND (SELECT scene FROM lc_discover_state WHERE id=1)) OR (kind='faces' AND (SELECT faces FROM lc_discover_state WHERE id=1)))",[])?;
    Ok(json!({"queued":count,"paused":false}))
}
