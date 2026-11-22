use super::*;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Component;

pub(super) fn record_verified(
    db: &Connection,
    file: &str,
    content: &str,
    root: &str,
    relative: &str,
    final_path: &Path,
    source: &Path,
    kind: &str,
) -> Result<String> {
    if !matches!(kind, "source" | "managed" | "restored")
        || root.is_empty()
        || relative.is_empty()
        || !final_path.is_absolute()
        || !source.is_absolute()
        || Path::new(relative)
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err("invalid replica kind or location".into());
    }
    let owned:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_occurrences WHERE file_id=?1 AND content_id=?2) OR EXISTS(SELECT 1 FROM lc_scopes WHERE file_id=?1 AND content_id=?2) OR EXISTS(SELECT 1 FROM lc_replicas WHERE file_id=?1 AND content_id=?2)",params![file,content],|r|r.get(0))?;
    if !owned {
        return Err("content version does not belong to this file".into());
    }
    let (expected, length): (String, i64) = db.query_row(
        "SELECT sha256,byte_count FROM lc_contents WHERE content_id=?1",
        [content],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let input = File::open(source)?;
    let before = input.metadata()?;
    if !before.is_file() || before.len() != length as u64 {
        return Err("replica is missing or has the wrong byte length".into());
    }
    let mut reader = BufReader::new(input);
    let mut digest = Sha256::new();
    let mut buffer = vec![0u8; 256 * 1024];
    let mut read = 0u64;
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
        read += count as u64;
    }
    let after = reader.get_ref().metadata()?;
    if read != length as u64
        || before.len() != after.len()
        || before.modified().ok() != after.modified().ok()
        || hex::encode(digest.finalize()) != expected
    {
        return Err("replica changed or failed SHA-256 verification".into());
    }
    let final_text = final_path.to_str().ok_or("replica locator is not UTF-8")?;
    let id = digest_id("replica", &[file, content, root, relative]);
    db.execute("INSERT INTO lc_replicas(replica_id,file_id,content_id,root_id,relative_path,path,kind,state)
        VALUES(?1,?2,?3,?4,?5,?6,?7,'available') ON CONFLICT(replica_id) DO UPDATE SET path=excluded.path,kind=excluded.kind,state='available'
        WHERE lc_replicas.path IS NOT excluded.path OR lc_replicas.kind!=excluded.kind OR lc_replicas.state!='available'",
        params![id,file,content,root,relative,final_text,kind])?;
    Ok(id)
}
pub(super) fn verify(db: &Connection, r: &Value) -> Result<Value> {
    let file = field(r, "fileID")?;
    let content = field(r, "contentID")?;
    let path = Path::new(field(r, "path")?);
    let id = record_verified(
        db,
        file,
        content,
        field(r, "rootID")?,
        field(r, "relativePath")?,
        path,
        path,
        field(r, "kind")?,
    )?;
    Ok(json!({"fileID":file,"contentID":content,"replicaID":id}))
}

pub(super) fn register_root(db: &Connection, r: &Value) -> Result<Value> {
    let root = field(r, "rootID")?;
    let kind = field(r, "kind")?;
    if !matches!(kind, "managed" | "source" | "restored") {
        return Err("unknown root kind".into());
    }
    let volume = r["volumeID"].as_str();
    let relative = r["relativeRoot"].as_str();
    if relative.is_some_and(|path| {
        Path::new(path)
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    }) {
        return Err("invalid volume-relative mount root".into());
    }
    let path = r["path"].as_str();
    if path.is_some_and(|p| !Path::new(p).is_absolute()) {
        return Err("mount root needs a local absolute locator".into());
    }
    let changed=db.execute("INSERT INTO lc_roots(root_id,volume_id,relative_root,local_path,kind) VALUES(?1,?2,?3,?4,?5)
        ON CONFLICT(root_id) DO UPDATE SET volume_id=COALESCE(lc_roots.volume_id,excluded.volume_id),relative_root=COALESCE(excluded.relative_root,lc_roots.relative_root),local_path=excluded.local_path
        WHERE lc_roots.kind=excluded.kind AND (lc_roots.volume_id IS NULL OR excluded.volume_id IS NULL OR lc_roots.volume_id=excluded.volume_id)",
        params![root,volume,relative,path,kind])?;
    if changed != 1 {
        return Err(
            "mount locator cannot silently change the volume or ownership of a root".into(),
        );
    }
    Ok(json!({"rootID":root,"volumeID":volume}))
}

pub(super) fn activate(
    db: &Connection,
    scope: &str,
    file: &str,
    content: &str,
    path: &Path,
) -> Result<String> {
    let dest = path.to_str().ok_or("invalid host asset locator")?;
    if !path.is_absolute() {
        return Err("absolute restored path required".into());
    }
    let (source,session,snapshot,hash,length):(String,String,Option<String>,String,i64)=db.query_row(
        "SELECT o.asset_id,o.session_id,o.host_snapshot,c.sha256,c.byte_count FROM lc_scopes s JOIN lc_occurrences o USING(session_id,occurrence_id)
         JOIN lc_contents c ON c.content_id=s.content_id WHERE s.scope_id=?1 AND s.file_id=?2 AND s.content_id=?3 AND
         EXISTS(SELECT 1 FROM lc_replicas r WHERE r.file_id=s.file_id AND r.content_id=s.content_id AND r.state='available' AND r.path=?4)",
        params![scope,file,content,dest],|x|Ok((x.get(0)?,x.get(1)?,x.get(2)?,x.get(3)?,x.get(4)?)))?;
    // Match the frozen digest/length, including rows marked missing or changed.
    // One v7 asset only has one active byte stream. Never redirect an unrelated
    // version's pixel data, metadata or edits onto the newly located original.
    let known:Option<String>=db.query_row("SELECT a.id FROM lc_asset_files f JOIN assets a ON a.id=f.asset_id
        WHERE f.file_id=?1 AND lower(json_extract(a.data,'$.contentHash'))=?2 AND json_extract(a.data,'$.fileSize')=?3
        ORDER BY (a.id=?4) DESC,EXISTS(SELECT 1 FROM lc_recovery_hosts h WHERE h.asset_id=a.id AND h.original_asset_id=?4) DESC,a.id LIMIT 1",
        params![file,hash,length,source],|x|x.get(0)).optional()?;
    let host = if let Some(id) = known {
        id
    } else {
        let id = digest_id("version-asset", &[&source, file, content]);
        let previous: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM assets WHERE id=?1)",
            [&id],
            |x| x.get(0),
        )?;
        if previous {
            return Err(
                "the existing historical version representative contains different bytes".into(),
            );
        }
        let sid = digest_id("version-source", &[&source, file, content]);
        let original: String =
            db.query_row("SELECT data FROM sessions WHERE id=?1", [&session], |x| {
                x.get(0)
            })?;
        let mut host_session: Value = serde_json::from_str(&original)?;
        host_session["id"] = json!(sid);
        host_session["mode"] = json!("reference");
        host_session["status"] = json!("completed");
        host_session["discovered"] = json!(0);
        host_session["completed"] = json!(0);
        host_session["failed"] = json!(0);
        host_session["scanCompleted"] = json!(true);
        if let Some(map) = host_session.as_object_mut() {
            map.remove("destinationPath");
            map.remove("effectiveManagedRoot");
        }
        let mut card: Value = serde_json::from_str(
            snapshot
                .as_deref()
                .ok_or("missing frozen metadata for this restored version")?,
        )?;
        if card["contentHash"]
            .as_str()
            .map(str::to_ascii_lowercase)
            .as_deref()
            != Some(hash.as_str())
            || card["fileSize"].as_i64() != Some(length)
        {
            return Err("frozen host metadata cannot be bound to the restored content".into());
        }
        let original_path = field(&card, "sourcePath")?.to_string();
        card["id"] = json!(id);
        card["sessionID"] = json!(sid);
        card["projectID"] = host_session["projectID"].clone();
        if let Some(name) = host_session.get("projectName") {
            card["projectName"] = name.clone();
        }
        card["effectiveSourcePath"] = json!(dest);
        card["currentPath"] = json!(dest);
        card["availability"] = json!("available");
        card["importState"] = json!("ready");
        if let Some(map) = card.as_object_mut() {
            map.remove("effectiveManagedPath");
            map.remove("error");
        }
        db.execute(
            "INSERT INTO sessions VALUES(?1,?2)",
            params![sid, host_session.to_string()],
        )?;
        db.execute(
            "UPDATE lc_sessions SET origin='version-host' WHERE session_id=?1",
            [&sid],
        )?;
        db.execute(
            "INSERT INTO lc_asset_files VALUES(?1,?2)",
            params![id, file],
        )?;
        db.execute(
            "INSERT INTO lc_recovery_hosts VALUES(?1,?2,?3,?4,?5)",
            params![id, sid, source, file, content],
        )?;
        db.execute(
            "INSERT INTO assets(id,session_id,source_path,data) VALUES(?1,?2,?3,?4)",
            params![id, sid, original_path, card.to_string()],
        )?;
        db.execute(
            "UPDATE lc_sessions SET state='sealed',seal_id=?2 WHERE session_id=?1",
            params![sid, scope],
        )?;
        id
    };
    // The selected original is a verified additional locator. Only an existing
    // managed copy can claim managed ownership. Source path history stays intact.
    let managed:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_replicas WHERE file_id=?1 AND content_id=?2 AND path=?3 AND kind='managed' AND state='available')",params![file,content,dest],|x|x.get(0))?;
    let active=db.execute("UPDATE assets SET revision=revision+1,
        data=json_remove(json_set(CASE WHEN ?5 THEN json_set(data,'$.effectiveManagedPath',?1) ELSE json_remove(data,'$.effectiveManagedPath') END,
            '$.effectiveSourcePath',?1,'$.currentPath',?1,'$.availability','available','$.importState','ready'),'$.error')
        WHERE id=?2 AND lower(json_extract(data,'$.contentHash'))=?3 AND json_extract(data,'$.fileSize')=?4",
        params![dest,host,hash,length,managed])?;
    if active != 1 {
        return Err("restored version changed during activation".into());
    }
    db.execute(
        "UPDATE lc_scopes SET asset_id=?1 WHERE scope_id=?2 AND asset_id<>?1",
        params![host, scope],
    )?;
    Ok(host)
}
