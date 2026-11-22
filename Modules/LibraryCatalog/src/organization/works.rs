use super::*;
use rusqlite::params;

pub(super) const VOLUME:&str="SELECT json_object('volumeID',volume_id,'name',name,'locator',locator,'online',CASE WHEN online IS NULL THEN NULL ELSE json(CASE WHEN online THEN 'true' ELSE 'false' END) END,'revision',revision) FROM lc_org_volumes WHERE volume_id=?";
pub(super) const FOLDER:&str="SELECT json_object('folderID',folder_id,'volumeID',volume_id,'parentID',parent_id,'name',name,'position',position,'revision',revision) FROM lc_org_folders WHERE folder_id=?";
pub(super) const WORK:&str="SELECT json_object('workID',work_id,'kind',kind,'fileID',file_id,'masterWorkID',master_work_id,'folderID',folder_id,'projectID',project_id,'name',name,'rating',rating,'metadata',json(metadata_json),'versionID',active_version_id,'revision',revision) FROM lc_org_works WHERE work_id=?";

pub(super) fn volume(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "volumeID")?;
    let old = stored(db, VOLUME, id)?;
    let rev = revision(old.as_ref(), r)?;
    let v = amended(
        old.as_ref().unwrap_or(&json!({})),
        r,
        &["name", "locator", "online"],
    );
    let online = match v.get("online") {
        Some(Value::Bool(v)) => Some(*v),
        None | Some(Value::Null) => None,
        _ => return Err("online must be boolean or null".into()),
    };
    db.execute("INSERT INTO lc_org_volumes VALUES(?,?,?,?,?) ON CONFLICT(volume_id) DO UPDATE SET
        name=excluded.name,locator=excluded.locator,online=excluded.online,revision=excluded.revision",
        params![id,string(&v,"name")?,optional(&v,"locator")?,online,rev])?;
    Ok(json!({"volumeID":id,"revision":rev}))
}
pub(super) fn folder(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "folderID")?;
    let old = stored(db, FOLDER, id)?;
    let rev = revision(old.as_ref(), r)?;
    let v = amended(
        old.as_ref().unwrap_or(&json!({})),
        r,
        &["volumeID", "parentID", "name", "position"],
    );
    let volume = string(&v, "volumeID")?;
    require(
        db,
        "SELECT EXISTS(SELECT 1 FROM lc_org_volumes WHERE volume_id=?)",
        volume,
        "unknown volume",
    )?;
    if old.as_ref().is_some_and(|o| o["volumeID"] != volume) {
        return Err("cannot move a folder tree to another volume by renaming it".into());
    }
    let parent = optional(&v, "parentID")?;
    if let Some(parent) = parent {
        let valid:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_org_folders WHERE folder_id=?1 AND volume_id=?2)
            AND NOT EXISTS(WITH RECURSIVE down(id) AS (SELECT ?3 UNION ALL SELECT f.folder_id FROM lc_org_folders f JOIN down ON f.parent_id=down.id)
                SELECT 1 FROM down WHERE id=?1)",params![parent,volume,id],|r|r.get(0))?;
        if !valid {
            return Err("folder parent would form a cycle or belongs to another volume".into());
        }
    }
    db.execute("INSERT INTO lc_org_folders VALUES(?,?,?,?,?,?) ON CONFLICT(folder_id) DO UPDATE SET parent_id=excluded.parent_id,
        name=excluded.name,position=excluded.position,revision=excluded.revision",params![id,volume,parent,string(&v,"name")?,position(&v)?,rev])?;
    Ok(json!({"folderID":id,"revision":rev}))
}
fn appearance(
    db: &Connection,
    r: &Value,
    work: &str,
    current: Option<&str>,
    revision: i64,
) -> Result<Option<String>> {
    let Some(look) = r.get("appearance") else {
        return Ok(current.map(str::to_owned));
    };
    if !look.is_object() {
        return Err("appearance requires a versioned source descriptor".into());
    }
    let version = optional(r, "versionID")?
        .map(str::to_owned)
        .unwrap_or_else(|| format!("org:{}:{revision}", work));
    let previous: Option<(String, String)> = db
        .query_row(
            "SELECT work_id,appearance_json FROM lc_org_versions WHERE version_id=?",
            [&version],
            |q| Ok((q.get(0)?, q.get(1)?)),
        )
        .optional()?;
    let data = serde_json::to_string(look)?;
    if let Some((owner, payload)) = previous {
        if owner != work || serde_json::from_str::<Value>(&payload)? != *look {
            return Err("work version identity already has different content".into());
        }
    } else {
        db.execute(
            "INSERT INTO lc_org_versions VALUES(?,?,?,?,?)",
            params![version, work, current, data, revision],
        )?;
    }
    Ok(Some(version))
}
pub(super) fn save(db: &Connection, r: &Value) -> Result<Value> {
    let id = string(r, "workID")?;
    let old = stored(db, WORK, id)?;
    let rev = revision(old.as_ref(), r)?;
    let v = amended(
        old.as_ref().unwrap_or(&json!({})),
        r,
        &[
            "kind",
            "fileID",
            "masterWorkID",
            "folderID",
            "name",
            "rating",
            "metadata",
            "projectID",
        ],
    );
    let kind = string(&v, "kind")?;
    if let Some(o) = &old {
        for k in ["kind", "fileID", "masterWorkID"] {
            if o[k] != v[k] {
                return Err("work source identity cannot be replaced by a metadata update".into());
            }
        }
    }
    let file = optional(&v, "fileID")?;
    let master = optional(&v, "masterWorkID")?;
    match (kind, file, master) {
        ("offline", None, None) => (),
        ("original", Some(file), None) => require(
            db,
            "SELECT EXISTS(SELECT 1 FROM lc_catalog_files WHERE file_id=?)",
            file,
            "original needs an admitted library file",
        )?,
        ("derivedPhoto" | "derivedVideo", None, None) if old.is_some() => (),
        ("virtual", None, Some(base)) => {
            require(
                db,
                "SELECT EXISTS(SELECT 1 FROM lc_org_works WHERE work_id=? AND kind!='virtual')",
                base,
                "virtual copy needs an existing master",
            )?;
        }
        _ => return Err("invalid original, offline or virtual work identity".into()),
    }
    if let Some(folder) = optional(&v, "folderID")? {
        require(
            db,
            "SELECT EXISTS(SELECT 1 FROM lc_org_folders WHERE folder_id=?)",
            folder,
            "unknown work folder",
        )?;
    }
    let rating = match v.get("rating") {
        Some(Value::Number(n)) => Some(
            n.as_i64()
                .filter(|r| (0..=5).contains(r))
                .ok_or("rating must be 0–5")?,
        ),
        Some(Value::Null) | None => None,
        _ => return Err("invalid work rating".into()),
    };
    let mut metadata = v.get("metadata").cloned().unwrap_or_else(|| json!({}));
    if !metadata.is_object() {
        return Err("work metadata must be an object".into());
    }
    let mut inherited_look = None;
    // A copy starts with a snapshot of the master's descriptive fallback and
    // selected appearance. Future changes to either version stay independent.
    let mut rating = rating;
    if old.is_none() && kind == "virtual" {
        let master = stored(db, WORK, master.unwrap())?.ok_or("master work disappeared")?;
        if r.get("metadata").is_none() {
            metadata = master["metadata"].clone();
        }
        if r.get("rating").is_none() {
            let page = super::work_page(
                db,
                &json!({"workID":master["workID"],"level":"work","pageSize":1}),
            )?;
            rating = Some(page["items"][0]["metadata"]["rating"].as_i64().unwrap_or(0));
        }
        if r.get("appearance").is_none() {
            let active: Option<String> = db
                .query_row(
                    "SELECT appearance_json FROM lc_org_versions WHERE version_id=?",
                    [master["versionID"].as_str()],
                    |s| s.get(0),
                )
                .optional()?;
            if let Some(look) = active {
                inherited_look = Some(json!({"appearance":serde_json::from_str::<Value>(&look)?}));
            }
        }
    }
    let folder = optional(&v, "folderID")?;
    if kind == "virtual" && folder.is_some() {
        return Err("virtual copies inherit their master's folder".into());
    }
    db.execute("INSERT INTO lc_org_works(work_id,kind,file_id,master_work_id,folder_id,name,rating,metadata_json,revision,project_id)
        VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(work_id) DO UPDATE SET folder_id=excluded.folder_id,name=excluded.name,rating=excluded.rating,
        metadata_json=excluded.metadata_json,revision=excluded.revision,project_id=excluded.project_id",params![id,kind,file,master,folder,
        optional(&v,"name")?,rating,metadata.to_string(),rev,optional(&v,"projectID")?])?;
    let current = old.as_ref().and_then(|v| v["versionID"].as_str());
    let version = appearance(db, inherited_look.as_ref().unwrap_or(r), id, current, rev)?;
    db.execute(
        "UPDATE lc_org_works SET active_version_id=? WHERE work_id=?",
        params![version, id],
    )?;
    if old.as_ref().is_some_and(|o| o["folderID"] != v["folderID"]) {
        super::groups::tidy_scope(
            db,
            "folder",
            old.as_ref().and_then(|o| o["folderID"].as_str()),
        )?;
    }
    Ok(json!({"workID":id,"revision":rev,"versionID":version}))
}
pub(super) fn link(db: &Connection, r: &Value) -> Result<Value> {
    let work = string(r, "workID")?;
    let file = string(r, "fileID")?;
    let old = stored(db, WORK, work)?.ok_or("unknown placeholder")?;
    if old["kind"] != "offline" {
        return Err("only an offline placeholder can be linked".into());
    }
    let rev = revision(Some(&old), r)?;
    let bytes = r["byteCount"]
        .as_i64()
        .filter(|n| *n >= 0)
        .ok_or("verified byte count required")?;
    let valid:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_scopes s JOIN lc_contents c USING(content_id)
        JOIN lc_replicas r ON r.file_id=s.file_id AND r.content_id=s.content_id WHERE s.file_id=? AND c.sha256=? AND c.byte_count=? AND r.state='available')",
        params![file,string(r,"sha256")?,bytes],|r|r.get(0))?;
    if !valid {
        return Err("no admitted, verified replica matches the requested content".into());
    }
    db.execute(
        "UPDATE lc_org_works SET kind='original',file_id=?,revision=? WHERE work_id=?",
        params![file, rev, work],
    )?;
    Ok(json!({"workID":work,"fileID":file,"revision":rev}))
}
