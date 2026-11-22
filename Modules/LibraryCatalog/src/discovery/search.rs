use super::{cache, field, geometry::Fence, jobs, people, settings, SCENE};
use crate::{query::works::discovery_inputs, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::collections::BTreeSet;
pub fn fences(db: &Connection) -> Result<Value> {
    let mut s = db.prepare(
        "SELECT fence_id,name,geometry,revision FROM lc_discover_fences ORDER BY name,fence_id",
    )?;
    let mut rows = s.query([])?;
    let mut out = Vec::new();
    while let Some(r) = rows.next()? {
        out.push(json!({"fenceID":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"geometry":serde_json::from_str::<Value>(&r.get::<_,String>(2)?)?,"revision":r.get::<_,i64>(3)?}));
    }
    Ok(json!({"items":out}))
}
pub fn save_fence(db: &Connection, b: &Value) -> Result<Value> {
    let g = &b["geometry"];
    Fence::parse(g)?;
    let id = field(b, "fenceID")?;
    let name = field(b, "name")?.trim();
    if name.is_empty() {
        return Err("fence needs a name".into());
    }
    let seen: i64 = db.query_row(
        "SELECT coalesce((SELECT revision FROM lc_discover_fences WHERE fence_id=?),0)",
        [id],
        |r| r.get(0),
    )?;
    if b.get("expectedRevision").is_some() && b["expectedRevision"] != seen {
        return Err("fence changed; refresh".into());
    }
    db.execute("INSERT INTO lc_discover_fences VALUES(?,?,?,?) ON CONFLICT(fence_id) DO UPDATE SET name=excluded.name,geometry=excluded.geometry,revision=excluded.revision",params![id,name,serde_json::to_string(g)?,seen+1])?;
    db.execute(
        "UPDATE lc_discover_state SET revision=revision+1 WHERE id=1",
        [],
    )?;
    Ok(json!({"fenceID":id,"revision":seen+1}))
}
pub fn search(db: &Connection, b: &Value) -> Result<Value> {
    let scope = b.get("scope").cloned().unwrap_or_else(|| json!({}));
    let inputs = discovery_inputs(db, &scope)?;
    let fence = if let Some(v) = b.get("geometry") {
        Some(Fence::parse(v)?)
    } else if b.get("fenceID").is_some() {
        let s: String = db.query_row(
            "SELECT geometry FROM lc_discover_fences WHERE fence_id=?",
            [field(b, "fenceID")?],
            |r| r.get(0),
        )?;
        Some(Fence::parse(&serde_json::from_str(&s)?)?)
    } else {
        None
    };
    let people = if b.get("personID").is_some() {
        Some(people::confirmed(db, field(b, "personID")?)?)
    } else {
        None
    };
    let similar = b
        .get("similarWorkID")
        .map(|_| field(b, "similarWorkID"))
        .transpose()?;
    let semantic = b.get("vector").is_some() || similar.is_some();
    if similar.is_some() && b.get("vector").is_some() {
        return Err("choose a text vector or source work".into());
    }
    let state = settings(db)?;
    let c = if semantic || fence.is_some() {
        cache::open(db, false)?
    } else {
        None
    };
    let candidates = if let Some(f) = &fence {
        cache::shortlist(db, c.as_ref(), f)?
    } else {
        None
    };
    let query = if let Some(v) = b.get("vector") {
        if field(b, "model")? != SCENE {
            return Err("incompatible text/image feature model".into());
        }
        Some(cache::normalized(v, 768)?)
    } else if let Some(id) = similar {
        // A reference image is also required to be in the caller's authorized scope.
        if let Some(i) = inputs.iter().find(|i| i.work_id == id) {
            jobs::scene(db, c.as_ref(), i)?
        } else {
            return Err("reference work outside the selected scope".into());
        }
    } else {
        None
    };
    let min = b
        .get("minimumScore")
        .map(|v| {
            v.as_f64()
                .filter(|n| (-1.0..=1.).contains(n))
                .ok_or("invalid cosine threshold")
        })
        .transpose()?;
    let limit = b
        .get("limit")
        .map(|v| {
            v.as_u64()
                .filter(|n| (1..=1000).contains(n))
                .ok_or("invalid discovery page size")
        })
        .transpose()?
        .unwrap_or(60) as usize;
    let mut hard = 0;
    let mut indexed = 0;
    let mut ranked = Vec::new();
    let mut files = BTreeSet::new();
    let mut captures = BTreeSet::new();
    for input in &inputs {
        if people.as_ref().is_some_and(|p| !p.contains(&input.work_id)) {
            continue;
        }
        if let Some(f) = &fence {
            if candidates
                .as_ref()
                .is_some_and(|s| !s.contains(&input.work_id))
                || !input
                    .latitude
                    .zip(input.longitude)
                    .is_some_and(|(a, b)| f.contains(a, b))
            {
                continue;
            }
        }
        hard += 1;
        enum Rank {
            Include(Option<f64>),
            Skip,
        }
        let score = if semantic {
            if state["scene"] != true {
                Rank::Skip
            } else if let Some(v) = jobs::scene(db, c.as_ref(), input)? {
                indexed += 1;
                if let Some(q) = &query {
                    let s = cache::cosine(q, &v);
                    if min.is_none_or(|n| s >= n) {
                        Rank::Include(Some(s))
                    } else {
                        Rank::Skip
                    }
                } else {
                    Rank::Skip
                }
            } else {
                Rank::Skip
            }
        } else {
            Rank::Include(None)
        };
        let Rank::Include(score) = score else {
            continue;
        };
        if let Some(f) = &input.file_id {
            files.insert(f.clone());
        }
        if let Some(c) = &input.capture_id {
            captures.insert(c.clone());
        }
        ranked.push((score.unwrap_or(0.),input.work_id.clone(),json!({"workID":input.work_id,"fileID":input.file_id,"captureID":input.capture_id,"name":input.name,"kind":input.kind,"score":score,"inputVersion":input.input_version})));
    }
    ranked.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
    let hits = ranked.len();
    let missing = semantic.then_some(hard - indexed);
    let id: String = db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
        r.get(0)
    })?;
    let watermark = cache::tip(db)?;
    let mut descriptor = b.clone();
    let fields = descriptor
        .as_object_mut()
        .ok_or("expected search descriptor")?;
    fields.remove("limit");
    fields.remove("cursor");
    let uris = ranked
        .iter()
        .map(|(score, id, row)| (score.to_bits(), id, &row["inputVersion"]))
        .collect::<Vec<_>>();
    let fingerprint = super::digest(serde_json::to_vec(&(
        &id,
        watermark,
        &state["revision"],
        descriptor,
        hard,
        indexed,
        uris,
    ))?);
    let cursor = b.get("cursor").filter(|c| !c.is_null());
    let stale = cursor.is_some_and(|c| c["fingerprint"] != fingerprint);
    let offset = cursor
        .map(|c| {
            c["offset"]
                .as_u64()
                .and_then(|n| usize::try_from(n).ok())
                .ok_or("invalid discovery cursor")
        })
        .transpose()?
        .unwrap_or(0);
    let next = (!stale && offset.saturating_add(limit) < hits)
        .then(|| json!({"fingerprint":fingerprint,"offset":offset+limit}));
    let items = if stale {
        Vec::new()
    } else {
        ranked
            .into_iter()
            .skip(offset)
            .take(limit)
            .map(|x| x.2)
            .collect()
    };
    Ok(
        json!({"status":if stale{"staleCursor"}else if semantic&&state["scene"]!=true{"indexDisabled"}else if similar.is_some()&&query.is_none(){"referenceUnindexed"}else{"ok"},
       "libraryID":id,"model":semantic.then_some(SCENE),"watermark":watermark,"scopeWorks":inputs.len(),"eligible":hard,"indexed":semantic.then_some(indexed),
       "missing":missing,"partial":missing.is_some_and(|n|n>0),"spatialIndex":if fence.is_none(){None}else{Some(if candidates.is_some(){"rtreeExact"}else{"currentCoordinates"})},
       "count":hits,"fileCount":files.len(),"captureCount":captures.len(),"items":items,"nextCursor":next}),
    )
}
