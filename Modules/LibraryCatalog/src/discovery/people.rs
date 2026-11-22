use super::{cache, digest, field, jobs, settings, Input, FACES, FACE_DIMENSIONS};
use crate::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;
const REVIEW_COSINE: f64 = 0.88;

pub fn rectangle(v: &Value) -> Result<[f64; 4]> {
    let a = v
        .as_array()
        .filter(|x| x.len() == 4)
        .ok_or("expected rectangular face region")?;
    let mut r = [0.; 4];
    for (i, n) in a.iter().enumerate() {
        r[i] = n
            .as_f64()
            .filter(|x| (0.0..=1.).contains(x))
            .ok_or("invalid normalized coordinate")?;
    }
    if r[2] <= 0. || r[3] <= 0. || r[0] + r[2] > 1.000001 || r[1] + r[3] > 1.000001 {
        return Err("invalid normalized face region".into());
    }
    Ok(r)
}
fn iou(a: [f64; 4], b: [f64; 4]) -> f64 {
    let w = (a[0] + a[2]).min(b[0] + b[2]) - a[0].max(b[0]);
    let h = (a[1] + a[3]).min(b[1] + b[3]) - a[1].max(b[1]);
    let u = w.max(0.) * h.max(0.);
    u / (a[2] * a[3] + b[2] * b[3] - u)
}
fn strings(v: &Value) -> Result<Vec<String>> {
    let mut out = BTreeSet::new();
    for v in v
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 5000)
        .ok_or("expected selected faces")?
    {
        out.insert(
            v.as_str()
                .filter(|s| !s.is_empty())
                .ok_or("invalid ID")?
                .to_owned(),
        );
    }
    Ok(out.into_iter().collect())
}
const ANCHOR_PROOF_PREFIX: &str = "discovery.faceAnchorInput.";
const ANCHOR_OVERLAP: f64 = 0.70;

pub(super) struct Face {
    pub(super) id: String,
    pub(super) work: String,
    pub(super) region: [f64; 4],
    pub(super) box_data: Value,
    pub(super) feature: Option<Vec<f32>>,
    pub(super) assigned: Option<String>,
    pub(super) blocked: BTreeSet<String>,
    pub(super) ambiguous: bool,
}

struct Anchor {
    id: String,
    region: [f64; 4],
    person: Option<String>,
    blocked: BTreeSet<String>,
    version: Option<String>,
}

fn proof_key(anchor: &str) -> String {
    format!("{ANCHOR_PROOF_PREFIX}{anchor}")
}

// Early v8 anchors reused the observation ID. A stable ID alone cannot prove the
// association: rerunning a detector can return another face at the same ordinal.
fn legacy_proof(db: &Connection, id: &str, work: &str, region: [f64; 4]) -> Result<Option<String>> {
    let observed: Option<(String,String,String)> = db.prepare_cached(
        "SELECT input_version, model, region FROM lc_discover_faces WHERE observation_id=? AND work_id=?"
    )?.query_row(params![id,work], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    let Some((version, model, observed)) = observed else {
        return Ok(None);
    };
    let observed: [f64; 4] = serde_json::from_str(&observed)?;
    if iou(region, observed) < ANCHOR_OVERLAP {
        return Ok(None);
    }
    let unique = |sql: &str, params: &[&dyn rusqlite::ToSql], other: [f64; 4]| -> Result<bool> {
        let mut stmt = db.prepare_cached(sql)?;
        let mut rs = stmt.query(params)?;
        let mut count = 0;
        while let Some(row) = rs.next()? {
            let item: [f64; 4] = serde_json::from_str(&row.get::<_, String>(0)?)?;
            if iou(item, other) >= ANCHOR_OVERLAP {
                count += 1;
                if count > 1 {
                    return Ok(false);
                }
            }
        }
        Ok(count == 1)
    };
    let one_observation = unique(
        "SELECT region FROM lc_discover_faces WHERE work_id=? AND input_version=? AND model=?",
        &[&work, &version, &model],
        region,
    )?;
    let one_anchor=unique("SELECT a.region FROM lc_discover_anchors a WHERE a.work_id=? AND (EXISTS (SELECT 1 FROM lc_discover_labels l WHERE l.anchor_id=a.anchor_id) OR EXISTS (SELECT 1 FROM lc_discover_rejections r WHERE r.anchor_id=a.anchor_id))", &[&work], observed)?;
    Ok((one_observation && one_anchor).then_some(version))
}

// Called from cache/observations maintenance in the same authoritative transaction.
// Labels and rejection decisions are never edited by cache rebuild or retargeting.
pub(super) fn preserve_anchor_proofs(db: &Connection) -> Result<()> {
    preserve_proofs(db, None)
}
pub(super) fn preserve_work_anchor_proofs(db: &Connection, work: &str) -> Result<()> {
    preserve_proofs(db, Some(work))
}
fn preserve_proofs(db: &Connection, work: Option<&str>) -> Result<()> {
    let mut sql = "SELECT a.anchor_id,a.work_id,a.region FROM lc_discover_anchors a
        JOIN lc_discover_faces f ON f.observation_id=a.anchor_id AND f.work_id=a.work_id
        WHERE NOT EXISTS(SELECT 1 FROM lc_meta m WHERE m.key=?1||a.anchor_id)"
        .to_owned();
    if work.is_some() {
        sql.push_str(" AND a.work_id=?2")
    }
    let mut q = db.prepare_cached(&sql)?;
    let mut rows = if let Some(work) = work {
        q.query(params![ANCHOR_PROOF_PREFIX, work])?
    } else {
        q.query([ANCHOR_PROOF_PREFIX])?
    };
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        let work: String = row.get(1)?;
        if let Some(version) = legacy_proof(
            db,
            &id,
            &work,
            serde_json::from_str(&row.get::<_, String>(2)?)?,
        )? {
            db.execute(
                "INSERT OR IGNORE INTO lc_meta(key,value) VALUES(?,?)",
                params![proof_key(&id), version],
            )?;
        }
    }
    Ok(())
}

fn labeled(db: &Connection, work: &str) -> Result<Vec<Anchor>> {
    let mut stmt=db.prepare_cached("SELECT a.anchor_id,a.region,l.person_id,m.value,
        (SELECT json_group_array(r.person_id) FROM lc_discover_rejections r WHERE r.anchor_id=a.anchor_id)
        FROM lc_discover_anchors a LEFT JOIN lc_discover_labels l ON l.anchor_id=a.anchor_id
        LEFT JOIN lc_meta m ON m.key=?1||a.anchor_id WHERE a.work_id=?2 AND
        (l.anchor_id IS NOT NULL OR EXISTS(SELECT 1 FROM lc_discover_rejections r WHERE r.anchor_id=a.anchor_id)) ORDER BY a.anchor_id")?;
    let mut rows = stmt.query(params![ANCHOR_PROOF_PREFIX, work])?;
    let mut result = Vec::new();
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        let region = serde_json::from_str(&row.get::<_, String>(1)?)?;
        let version = match row.get::<_, Option<String>>(3)? {
            Some(v) => Some(v),
            None => legacy_proof(db, &id, work, region)?,
        };
        result.push(Anchor {
            id,
            region,
            person: row.get(2)?,
            blocked: serde_json::from_str(&row.get::<_, String>(4)?)?,
            version,
        });
    }
    Ok(result)
}

pub(super) fn scan(
    db: &Connection,
    cache: Option<&Connection>,
    inputs: &[Input],
    embeddings: bool,
) -> Result<Vec<Face>> {
    if settings(db)?["faces"] != true {
        return Ok(Vec::new());
    }
    let mut stmt=db.prepare_cached("SELECT observation_id,region,landmarks,confidence,feature_key FROM lc_discover_faces WHERE work_id=? AND input_version=? AND model=? ORDER BY observation_id")?;
    let mut faces = Vec::new();
    for input in inputs {
        let mut rows = stmt.query(params![input.work_id, input.input_version, FACES])?;
        let mut current = Vec::new();
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            let region: [f64; 4] = serde_json::from_str(&row.get::<_, String>(1)?)?;
            let pts: Value = serde_json::from_str(&row.get::<_, String>(2)?)?;
            let feature = if embeddings {
                cache::get(cache, &row.get::<_, String>(4)?, FACES, FACE_DIMENSIONS)?
            } else {
                None
            };
            let box_data = json!({"observationID":id,"workID":input.work_id,"name":input.name,"box":region,"landmarks":pts,"confidence":row.get::<_,f64>(3)?,"inputVersion":input.input_version});
            current.push(Face {
                id,
                work: input.work_id.clone(),
                region,
                box_data,
                feature,
                assigned: None,
                blocked: BTreeSet::new(),
                ambiguous: false,
            });
        }
        if current.is_empty() {
            continue;
        }
        let anchors = labeled(db, &input.work_id)?;
        let overlaps: Vec<Vec<usize>> = current
            .iter()
            .map(|face| {
                anchors
                    .iter()
                    .enumerate()
                    .filter_map(|(i, anchor)| {
                        (anchor.version.as_deref() == Some(input.input_version.as_str())
                            && iou(face.region, anchor.region) >= ANCHOR_OVERLAP)
                            .then_some(i)
                    })
                    .collect()
            })
            .collect();
        for (idx, face) in current.iter_mut().enumerate() {
            let matches = &overlaps[idx];
            if let [index] = matches.as_slice() {
                let anchor = &anchors[*index];
                if anchor.version.as_deref() == Some(&input.input_version)
                    && overlaps
                        .iter()
                        .filter(|others| others.contains(index))
                        .count()
                        == 1
                {
                    face.assigned = anchor.person.clone();
                    face.blocked = anchor.blocked.clone();
                    face.box_data["anchorID"] = json!(anchor.id);
                } else {
                    face.ambiguous = true
                }
            } else if !matches.is_empty() {
                face.ambiguous = true
            }
            face.box_data["personID"] = json!(face.assigned);
        }
        faces.extend(current);
    }
    faces.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(faces)
}
pub fn confirmed(db: &Connection, id: &str) -> Result<BTreeSet<String>> {
    let mut s = db.prepare("SELECT DISTINCT work_id FROM lc_discover_labels WHERE person_id=?")?;
    let rows = s.query_map([id], |r| r.get(0))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}
pub fn candidates(
    db: &Connection,
    c: Option<&Connection>,
    inputs: &[Input],
    cluster: bool,
) -> Result<Value> {
    let rows = scan(db, c, inputs, cluster)?;
    if !cluster {
        return Ok(json!({"items":rows.into_iter().map(|x|x.box_data).collect::<Vec<_>>()}));
    }
    // Greedy complete-link admission. Every pair in the suggested group clears the
    // threshold. A face rejected for the named person cannot re-enter that group.
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for (idx, face) in rows.iter().enumerate() {
        let Some(v) = &face.feature else {
            groups.push(vec![idx]);
            continue;
        };
        if face.ambiguous {
            groups.push(vec![idx]);
            continue;
        }
        let mut best = None;
        for (g, inds) in groups.iter().enumerate() {
            let mut score = 1.0_f64;
            for j in inds {
                let b = &rows[*j];
                if b.feature.is_none()
                    || b.ambiguous
                    || b.work == face.work
                    || matches!((&face.assigned,&b.assigned),(Some(a),Some(b)) if a!=b)
                    || face
                        .assigned
                        .as_ref()
                        .is_some_and(|p| b.blocked.contains(p))
                    || b.assigned
                        .as_ref()
                        .is_some_and(|p| face.blocked.contains(p))
                {
                    score = -1.;
                    break;
                }
                score = score.min(cache::cosine(v, b.feature.as_ref().unwrap()));
                if score < REVIEW_COSINE {
                    break;
                }
            }
            if score >= REVIEW_COSINE && best.is_none_or(|(_, s)| score > s) {
                best = Some((g, score));
            }
        }
        if let Some((g, _)) = best {
            groups[g].push(idx);
        } else {
            groups.push(vec![idx]);
        }
    }
    let data:Vec<_>=groups.iter().map(|ix|json!({"observations":ix.iter().map(|i|&rows[*i].box_data).collect::<Vec<_>>(),"suggestedPersonID":ix.iter().find_map(|i|rows[*i].assigned.as_deref()),"confirmed":false})).collect();
    Ok(
        json!({"items":data,"observations":rows.len(),"model":FACES,"minimumPairCosine":REVIEW_COSINE}),
    )
}
fn actual_anchor(db: &Connection, id: &str) -> Result<(String, String, String, String)> {
    let observed:Option<(String,String,String,String)>=db.query_row(
        "SELECT work_id,input_version,model,region FROM lc_discover_faces WHERE observation_id=?", [id],
        |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    if let Some((work, version, model, region)) = observed {
        if settings(db)?["faces"] != true || model != FACES {
            return Err("stale or disabled face observation".into());
        }
        let input = jobs::for_work(db, &work)?
            .filter(|i| i.input_version == version)
            .ok_or("stale face observation")?;
        let faces = scan(db, None, &[input], false)?;
        let face = faces
            .iter()
            .find(|f| f.id == id)
            .ok_or("face outside this version")?;
        let anchor = if let Some(a) = face.box_data["anchorID"].as_str() {
            a.to_owned()
        } else {
            // A person may explicitly identify this region even when older observations overlap.
            // Use region and source revision so a recycled detection ordinal cannot overwrite an old label.
            digest(serde_json::to_vec(&(
                "face-anchor-v2",
                &work,
                &version,
                &region,
                id,
            ))?)
        };
        return Ok((anchor, work, region, version));
    }
    let (work,region,version):(String,String,String)=db.query_row(
        "SELECT a.work_id,a.region,m.value FROM lc_discover_anchors a JOIN lc_meta m ON m.key=?1||a.anchor_id WHERE a.anchor_id=?2",
        params![ANCHOR_PROOF_PREFIX,id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
    if jobs::for_work(db, &work)?.is_none_or(|i| i.input_version != version) {
        return Err("stale face anchor".into());
    }
    Ok((id.to_owned(), work, region, version))
}
fn snapshot(db: &Connection, persons: &[String], anchors: &[String]) -> Result<Value> {
    let p = serde_json::to_string(persons)?;
    let a = serde_json::to_string(anchors)?;
    let mut out = json!({"scopePeople":persons,"scopeAnchors":anchors});
    for(k,sql)in[("people","SELECT json_array(person_id,name) FROM lc_discover_people WHERE person_id IN(SELECT value FROM json_each(?1))"),
 ("labels","SELECT json_array(anchor_id,work_id,region,person_id) FROM lc_discover_labels WHERE person_id IN(SELECT value FROM json_each(?1)) OR anchor_id IN(SELECT value FROM json_each(?2))"),
 ("rejects","SELECT json_array(anchor_id,person_id) FROM lc_discover_rejections WHERE person_id IN(SELECT value FROM json_each(?1)) OR anchor_id IN(SELECT value FROM json_each(?2))")]{
 let mut s=db.prepare(sql)?;let mut rows=if k=="people"{s.query([&p])?}else{s.query(params![p,a])?};let mut bucket=Vec::new();while let Some(r)=rows.next()?{bucket.push(serde_json::from_str::<Value>(&r.get::<_,String>(0)?)?);}out[k]=json!(bucket);}
    Ok(out)
}
fn restore(db: &Connection, s: &Value) -> Result<()> {
    let p = serde_json::to_string(&s["scopePeople"])?;
    let a = serde_json::to_string(&s["scopeAnchors"])?;
    for tab in ["lc_discover_rejections", "lc_discover_labels"] {
        db.execute(&format!("DELETE FROM {tab} WHERE person_id IN(SELECT value FROM json_each(?1)) OR anchor_id IN(SELECT value FROM json_each(?2))"),params![p,a])?;
    }
    db.execute(
        "DELETE FROM lc_discover_people WHERE person_id IN(SELECT value FROM json_each(?))",
        [p],
    )?;
    for (k, tab, n) in [
        ("people", "lc_discover_people", 2),
        ("labels", "lc_discover_labels", 4),
        ("rejects", "lc_discover_rejections", 2),
    ] {
        for row in s[k].as_array().ok_or("invalid undo entry")? {
            let values = row
                .as_array()
                .filter(|a| a.len() == n)
                .ok_or("invalid undo row")?
                .iter()
                .map(|a| a.as_str().ok_or("invalid undo value"))
                .collect::<std::result::Result<Vec<_>, _>>()?;
            db.execute(
                &format!("INSERT INTO {tab} VALUES({})", vec!["?"; n].join(",")),
                rusqlite::params_from_iter(values),
            )?;
        }
    }
    Ok(())
}
pub fn human(db: &Connection, b: &Value, op: &str) -> Result<Value> {
    let revision = settings(db)?["humanRevision"]
        .as_i64()
        .ok_or("invalid human revision")?;
    if b.get("expectedRevision").is_some() && b["expectedRevision"] != revision {
        return Err("face edits changed; refresh".into());
    }
    if op == "discover.undo" {
        let cmd = field(b, "editCommandID")?;
        let old:String=db.query_row("SELECT before_json FROM lc_discover_undo WHERE command_id=?1 AND undone=0 AND after_revision=(SELECT max(after_revision) FROM lc_discover_undo WHERE undone=0)",[cmd],|r|r.get(0))?;
        restore(db, &serde_json::from_str(&old)?)?;
        db.execute(
            "UPDATE lc_discover_undo SET undone=1 WHERE command_id=?",
            [cmd],
        )?;
        db.execute("UPDATE lc_discover_state SET human_revision=human_revision+1,revision=revision+1 WHERE id=1",[])?;
        return Ok(json!({"undone":cmd,"humanRevision":revision+1}));
    }
    let id = b["personID"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    let mut people = vec![id.clone()];
    let mut targets = BTreeMap::new();
    if matches!(op, "discover.assign" | "discover.split" | "discover.reject") {
        for obs in strings(&b["observationIDs"])? {
            let (a, w, r, version) = actual_anchor(db, &obs)?;
            targets.insert(a, (w, r, version));
        }
    }
    let source = if op == "discover.merge" {
        let src = field(b, "fromPersonID")?.to_owned();
        if src == id {
            return Err("merge needs two different people".into());
        }
        people.push(src.clone());
        Some(src)
    } else {
        None
    };
    for (a, (w, r, version)) in &targets {
        db.execute(
            "INSERT OR IGNORE INTO lc_meta(key,value) VALUES(?,?)",
            params![proof_key(a), version],
        )?;
        db.execute(
            "INSERT OR IGNORE INTO lc_discover_anchors VALUES(?,?,?)",
            params![a, w, r],
        )?;
    }
    let anchors: Vec<_> = targets.keys().cloned().collect();
    let before = snapshot(db, &people, &anchors)?;
    let exists = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_discover_people WHERE person_id=?)",
        [&id],
        |r| r.get::<_, bool>(0),
    )?;
    if op == "discover.split" && exists {
        return Err("split must create a separate person".into());
    }
    if matches!(op, "discover.name" | "discover.assign" | "discover.split") {
        if !exists || op == "discover.name" {
            let name = field(b, "name")?.trim();
            if name.is_empty() || name.chars().count() > 240 {
                return Err("invalid person name".into());
            }
            db.execute("INSERT INTO lc_discover_people VALUES(?,?) ON CONFLICT(person_id) DO UPDATE SET name=excluded.name",params![id,name])?;
        }
    } else if !exists {
        return Err("unknown person".into());
    }
    match op {
        "discover.assign" | "discover.split" => {
            for (anchor, (w, r, _)) in targets {
                db.execute(
                    "DELETE FROM lc_discover_rejections WHERE anchor_id=? AND person_id=?",
                    params![anchor, id],
                )?;
                db.execute("INSERT INTO lc_discover_labels VALUES(?,?,?,?) ON CONFLICT(anchor_id) DO UPDATE SET person_id=excluded.person_id",params![anchor,w,r,id])?;
            }
        }
        "discover.reject" => {
            for (a, _) in targets {
                db.execute(
                    "DELETE FROM lc_discover_labels WHERE anchor_id=? AND person_id=?",
                    params![a, id],
                )?;
                db.execute(
                    "INSERT OR IGNORE INTO lc_discover_rejections VALUES(?,?)",
                    params![a, id],
                )?;
            }
        }
        "discover.merge" => {
            let src = source.unwrap();
            let found: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM lc_discover_people WHERE person_id=?)",
                [&src],
                |r| r.get(0),
            )?;
            if !found {
                return Err("unknown source person".into());
            }
            db.execute(
                "UPDATE lc_discover_labels SET person_id=? WHERE person_id=?",
                params![id, src],
            )?;
            db.execute("INSERT OR IGNORE INTO lc_discover_rejections SELECT anchor_id,? FROM lc_discover_rejections WHERE person_id=?",params![id,src])?;
            db.execute("DELETE FROM lc_discover_rejections WHERE person_id=? OR (person_id=? AND EXISTS(SELECT 1 FROM lc_discover_labels l WHERE l.anchor_id=lc_discover_rejections.anchor_id AND l.person_id=?))",params![src,id,id])?;
            db.execute("DELETE FROM lc_discover_people WHERE person_id=?", [src])?;
        }
        "discover.name" => (),
        _ => return Err("unknown human face edit".into()),
    }
    let cmd = field(b, "commandID")?;
    db.execute(
        "INSERT INTO lc_discover_undo(command_id,before_json,after_revision) VALUES(?,?,?)",
        params![cmd, serde_json::to_string(&before)?, revision + 1],
    )?;
    db.execute("UPDATE lc_discover_state SET human_revision=human_revision+1,revision=revision+1 WHERE id=1",[])?;
    Ok(json!({"personID":id,"editCommandID":cmd,"humanRevision":revision+1}))
}
pub fn names(db: &Connection) -> Result<Value> {
    let mut s=db.prepare("SELECT p.person_id,p.name,count(DISTINCT CASE WHEN v.work_id IS NOT NULL THEN l.work_id END) FROM lc_discover_people p LEFT JOIN lc_discover_labels l USING(person_id) LEFT JOIN lc_org_visible_sources v ON v.work_id=l.work_id GROUP BY p.person_id ORDER BY p.name,p.person_id")?;
    let undo:Option<String>=db.query_row("SELECT command_id FROM lc_discover_undo WHERE undone=0 ORDER BY after_revision DESC LIMIT 1",[],|r|r.get(0)).optional()?;
    let rows=s.query_map([],|r|Ok(json!({"personID":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"works":r.get::<_,i64>(2)?})))?;
    Ok(
        json!({"items":rows.collect::<rusqlite::Result<Vec<_>>>()?,"humanRevision":settings(db)?["humanRevision"],"undoCommandID":undo}),
    )
}
