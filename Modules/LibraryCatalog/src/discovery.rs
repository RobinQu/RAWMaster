//! Optional local discovery. Admission and user decisions live in the catalog.
//! ML features are disposable and never make an offline source archive-eligible.
mod cache;
mod geometry;
mod jobs;
mod people;
mod person_retrieval;
mod search;
use crate::Result;
use rusqlite::Connection;
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub const SCHEMA: &str = include_str!("discovery/schema.sql");
pub const SCENE: &str = "siglip2-base-p16-224-75de2d55-f16w-v1";
pub const FACES: &str = "yunet-2023mar-intel-0095-fp32-edge1024-v2";
const LEGACY_FACES: &str = "yunet-2023mar-sface-2021dec-edge1024-v1";
pub const FACE_DIMENSIONS: usize = 256;
pub(crate) fn digest(b: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(b))
}
pub(super) fn field<'a>(v: &'a Value, s: &str) -> Result<&'a str> {
    v[s].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 4096)
        .ok_or_else(|| format!("missing or invalid {s}").into())
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Input {
    pub work_id: String,
    pub name: String,
    pub filename: String,
    pub kind: String,
    pub media_kind: Option<String>,
    pub file_id: Option<String>,
    pub capture_id: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub path: Option<String>,
    pub sha256: Option<String>,
    pub bytes: Option<i64>,
    pub location: String,
    pub input_version: String,
    #[serde(rename = "proxySHA256")]
    pub proxy_sha: Option<String>,
}
impl Input {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        work_id: String,
        name: String,
        kind: String,
        file_id: Option<String>,
        content: Option<String>,
        version: Option<String>,
        resource: Option<String>,
        latitude: Option<f64>,
        longitude: Option<f64>,
        path: Option<String>,
        sha256: Option<String>,
        bytes: Option<i64>,
        location: &str,
        capture_id: Option<String>,
    ) -> Result<Self> {
        let input_version = digest(serde_json::to_vec(&(
            &work_id, &file_id, content, version, resource, &sha256, bytes,
        ))?);
        Ok(Self {
            work_id,
            filename: name.clone(),
            name,
            kind,
            media_kind: None,
            file_id,
            capture_id,
            latitude,
            longitude,
            path,
            sha256,
            bytes,
            location: location.into(),
            input_version,
            proxy_sha: None,
        })
    }
}
pub(crate) fn settings(db: &Connection) -> Result<Value> {
    Ok(db.query_row("SELECT scene,faces,human_revision,revision,paused FROM lc_discover_state WHERE id=1",[],|r|Ok(json!({"scene":r.get::<_,bool>(0)?,"faces":r.get::<_,bool>(1)?,"humanRevision":r.get::<_,i64>(2)?,"paused":r.get::<_,bool>(4)?,"revision":r.get::<_,i64>(3)?,"sceneModel":SCENE,"faceModel":FACES})))?)
}
pub fn apply(db: &Connection, body: &Value) -> Result<Value> {
    match field(body, "action")? {
        "discover.configure" => {
            for k in ["scene", "faces"] {
                if let Some(value) = body.get(k) {
                    let enabled = value.as_bool().ok_or("expected boolean indexing setting")?;
                    db.execute(&format!("UPDATE lc_discover_state SET {k}=?,revision=revision+1 WHERE id=1 AND {k}<>?"),(enabled,enabled))?;
                    if !enabled {
                        db.execute("UPDATE lc_discover_jobs SET state='stopped',lease=NULL,lease_until=NULL WHERE kind=? AND state IN('queued','running')",[k])?;
                    }
                }
            }
            settings(db)
        }
        "discover.enqueue" => jobs::enqueue(db, body),
        "discover.sync" => jobs::sync(db, body),
        "discover.resume" => jobs::resume(db),
        "discover.rescan" => {
            db.execute("DELETE FROM lc_discover_schedule", [])?;
            Ok(json!({"queuedScan":true}))
        }
        "discover.rebuildFeatures" => {
            cache::rebuild(db)?;
            Ok(json!({"queuedScan":true}))
        }
        "discover.clearIndex" => jobs::clear(db, body),
        "discover.claim" => jobs::claim(db, body),
        "discover.finish" => jobs::finish(db, body, false),
        "discover.fail" => jobs::finish(db, body, true),
        "discover.stop" => jobs::stop(db, body),
        "discover.saveFence" => search::save_fence(db, body),
        "discover.rebuildSpatial" => {
            let items = crate::query::works::discovery_inputs(db, &json!({}))?;
            Ok(json!({"indexed":cache::spatial(db,&items)?,"watermark":cache::tip(db)?}))
        }
        op @ ("discover.assign" | "discover.split" | "discover.reject" | "discover.name"
        | "discover.merge" | "discover.undo") => people::human(db, body, op),
        _ => Err("unknown discovery command".into()),
    }
}
pub fn read(db: &Connection, body: &Value) -> Result<Value> {
    match body["op"].as_str().unwrap_or("settings") {
        "settings" => settings(db),
        "identity" => {
            if body["validateSchema"] == true {
                crate::validate_catalog_objects(db)?;
            }
            let schema: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
            let id: String =
                db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
                    r.get(0)
                })?;
            Ok(
                json!({"libraryID":id,"schema":schema,"watermark":cache::tip(db)?,"consent":settings(db)?}),
            )
        }
        "jobs" => jobs::state(db),
        "pending" => jobs::pending(db),
        "preview" => {
            let id = field(body, "workID")?;
            Ok(json!({"input":jobs::for_work(db,id)?}))
        }
        "search" => search::search(db, body),
        "people" => people::names(db),
        "personMatches" => person_retrieval::read(db, body),
        "fences" => search::fences(db),
        op @ ("observations" | "clusters") => {
            let scope = body.get("scope").cloned().unwrap_or_else(|| json!({}));
            let inputs = crate::query::works::discovery_inputs(db, &scope)?;
            let cache = if op == "clusters" {
                cache::open(db, false)?
            } else {
                None
            };
            people::candidates(db, cache.as_ref(), &inputs, op == "clusters")
        }
        _ => Err("unknown discovery read".into()),
    }
}
