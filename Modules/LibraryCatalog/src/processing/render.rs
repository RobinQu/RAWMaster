use super::*;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
fn regular(p: &Path) -> Result<File> {
    let mut open = OpenOptions::new();
    open.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        open.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let f = open.open(p)?;
    if !f.metadata()?.is_file() {
        return Err("Expected a regular input file".into());
    }
    Ok(f)
}
pub(super) fn digest(p: &Path, mut sink: impl Write) -> Result<(String, i64)> {
    let mut f = regular(p)?;
    let mut sha = Sha256::new();
    let mut len = 0i64;
    let mut buf = vec![0; 512 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        sha.update(&buf[..n]);
        sink.write_all(&buf[..n])?;
        len = len.checked_add(n as i64).ok_or("Render input too large")?;
    }
    Ok((hex::encode(sha.finalize()), len))
}
fn name(entry: &Value, index: i64) -> PathBuf {
    let ext = entry["asset"]["filename"]
        .as_str()
        .and_then(|s| Path::new(s).extension()?.to_str())
        .filter(|s| s.len() <= 12 && !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric()))
        .unwrap_or("raw");
    PathBuf::from(format!("frame-{index:08}.{ext}"))
}
fn output(dir: &Path, op: &str) -> PathBuf {
    dir.join(if op == "timelapse" {
        "output.mp4"
    } else {
        "output.tif"
    })
}
fn capture_inputs(
    db: &Connection,
    dir: &Path,
    job: &Value,
    jid: &str,
    token: &str,
) -> Result<Vec<Value>> {
    let mut input = sources(db, jid)?;
    input.retain(|v| v["renderPosition"].is_i64());
    input.sort_by_key(|v| v["renderPosition"].as_i64());
    for entry in &mut input {
        let file = required(entry, "fileID")?;
        let content = required(entry, "contentID")?;
        let expected = (
            required(entry, "sha256")?.to_owned(),
            entry["byteCount"].as_i64().ok_or("Missing frame length")?,
        );
        let dest = dir.join(name(entry, entry["renderPosition"].as_i64().unwrap()));
        let mut q=db.prepare_cached("SELECT DISTINCT path FROM lc_archive_files WHERE file_id=?1 AND content_id=?2 AND project_id=?3 AND path IS NOT NULL ORDER BY path")?;
        let paths = q
            .query_map(params![file, content, required(job, "projectID")?], |r| {
                r.get::<_, String>(0)
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut ok = false;
        for path in paths {
            let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
            match digest(Path::new(&path), tmp.as_file_mut()) {
                Ok(v) if v == expected => {
                    tmp.as_file().sync_data()?;
                    tmp.persist_noclobber(&dest)?;
                    ok = true;
                    break;
                }
                _ => continue,
            }
        }
        if !ok {
            return Err(
                format!("No available replica matches frozen file {file} ({content})").into(),
            );
        }
        let mut perms = fs::metadata(&dest)?.permissions();
        perms.set_readonly(true);
        fs::set_permissions(&dest, perms)?;
        entry["path"] = json!(dest);
        entry["exposureSeconds"] = entry["asset"]["verifiedExposureSeconds"].clone();
        if entry["exposureSeconds"].is_null() {
            entry["exposureSeconds"] =
                entry["asset"]["sequenceFrameEvidence"]["exposureSeconds"].clone();
        }
        if db.execute("UPDATE lc_proc_jobs SET lease_until=?3 WHERE job_id=?1 AND token=?2 AND state='preparing' AND lease_until>unixepoch()",params![jid,token,time()?+300])?!=1{return Err("Rendering attempt was superseded".into());}
    }
    Ok(input)
}
pub(super) fn claim(catalog: &Path, db: &mut Connection, r: &Value) -> Result<Value> {
    let jid = job_id(r)?;
    let mut j = status(db, &jid)?;
    if matches!(j["state"].as_str(), Some("published" | "staged")) {
        return Ok(j);
    }
    if let Some(old) = j["token"].as_str() {
        let old_dir = attempt_dir(catalog, &jid, old)?;
        if j["state"] == "rendering" && old_dir.join("receipt.json").is_file() {
            // A fresh claim can reconcile a committed on-disk receipt left by a dead worker.
            // The old worker's own checkpoint call always requires a live lease.
            let recovered = checkpoint_output(catalog, db, &json!({"jobID":jid,"token":old}), true);
            if recovered.is_ok() || j["leaseUntil"].as_i64().unwrap_or(0) > time()? {
                return recovered;
            }
            // An invalid abandoned marker must not strand a replayable local job.
        }
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    j = status(&tx, &jid)?;
    if matches!(j["state"].as_str(), Some("preparing" | "rendering"))
        && j["leaseUntil"]
            .as_i64()
            .is_some_and(|v| time().is_ok_and(|n| v > n))
    {
        return Err("This job has an active rendering attempt".into());
    }
    if matches!(j["state"].as_str(), Some("published" | "staged")) {
        tx.commit()?;
        return Ok(j);
    }
    tx.execute("UPDATE lc_proc_attempts SET state='interrupted',diagnostic='Lease expired before publication' WHERE job_id=?1 AND state IN('preparing','rendering')",[&jid])?;
    let token = Uuid::new_v4().to_string();
    let attempt = j["attempt"].as_i64().ok_or("Unknown attempt")? + 1;
    tx.execute("UPDATE lc_proc_jobs SET state='preparing',token=?2,attempt=?3,lease_until=?4,error=NULL WHERE job_id=?1",params![jid,token,attempt,time()?+300])?;
    tx.execute(
        "INSERT INTO lc_proc_attempts(job_id,attempt,token,state) VALUES(?1,?2,?3,'preparing')",
        params![jid, attempt, token],
    )?;
    tx.commit()?;
    let dir = attempt_dir(catalog, &jid, &token)?;
    let prepared = (|| -> Result<Vec<Value>> {
        fs::create_dir_all(&dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
        }
        capture_inputs(db, &dir, &j, &jid, &token)
    })();
    let frames = match prepared {
        Ok(v) => v,
        Err(e) => {
            stop(
                db,
                &json!({"jobID":jid,"token":token,"detail":e.to_string()}),
                false,
            )?;
            clean_attempt(&dir);
            return Err(e);
        }
    };
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if tx.execute("UPDATE lc_proc_jobs SET state='rendering',lease_until=?3 WHERE job_id=?1 AND token=?2 AND state='preparing' AND lease_until>unixepoch()",params![jid,token,time()?+300])?!=1{return Err("Rendering attempt was cancelled".into());}
    tx.execute(
        "UPDATE lc_proc_attempts SET state='rendering' WHERE job_id=?1 AND attempt=?2",
        params![jid, attempt],
    )?;
    tx.commit()?;
    let mut result = status(db, &jid)?;
    result["frames"] = json!(frames);
    result["outputPath"] = json!(output(&dir, required(&j, "operation")?));
    result["receiptPath"] = json!(dir.join("receipt.json"));
    Ok(result)
}
pub(super) fn checkpoint(catalog: &Path, db: &mut Connection, r: &Value) -> Result<Value> {
    checkpoint_output(catalog, db, r, false)
}

fn checkpoint_output(
    catalog: &Path,
    db: &mut Connection,
    r: &Value,
    recover_marker: bool,
) -> Result<Value> {
    let jid = job_id(r)?;
    let token = required(r, "token")?;
    let job = status(db, &jid)?;
    if job["token"] != token {
        return Err("Rendering attempt has been replaced".into());
    }
    if matches!(job["state"].as_str(), Some("staged" | "published")) {
        if r.get("receipt")
            .is_some_and(|supplied| supplied != &job["receipt"])
        {
            return Err("Job already published a different receipt".into());
        }
        return Ok(job);
    }
    if job["state"] != "rendering"
        || (!recover_marker && job["leaseUntil"].as_i64().unwrap_or(0) <= time()?)
    {
        return Err("Attempt no longer accepts an output".into());
    }
    let dir = attempt_dir(catalog, &jid, token)?;
    let path = output(&dir, required(&job, "operation")?);
    let marker = dir.join("receipt.json");
    let receipt: Value = if let Some(v) = r.get("receipt") {
        v.clone()
    } else {
        let f = regular(&marker)?;
        if f.metadata()?.len() > 8 * 1024 * 1024 {
            return Err("Oversized render receipt".into());
        }
        serde_json::from_reader(f)?
    };
    let kind = if job["operation"] == "timelapse" {
        "derivedVideo"
    } else {
        "derivedPhoto"
    };
    if receipt["mediaKind"] != kind
        || receipt["engineVersion"]
            .as_str()
            .is_none_or(|v| v.trim().is_empty())
        || !receipt["facts"].is_object()
    {
        return Err("Missing render engine or media provenance".into());
    }
    if kind == "derivedPhoto"
        && job["recipe"]["sourceRenderingPolicy"]
            .as_str()
            .is_some_and(|policy| receipt["facts"]["sourceRenderingPolicy"] != policy)
    {
        return Err("Render receipt does not match the frozen original rendering policy".into());
    }
    let mut used = 0;
    let declared = receipt["facts"]["inputs"]
        .as_array()
        .ok_or("Rendering receipt has no ordered input digests")?;
    for i in sources(db, &jid)? {
        if let Some(pos) = i["renderPosition"].as_i64() {
            let report = declared
                .get(usize::try_from(pos)?)
                .ok_or("Missing input in rendering receipt")?;
            if ["fileID", "contentID", "sha256"]
                .iter()
                .any(|k| report[*k] != i[*k])
            {
                return Err("Renderer used a different input or order".into());
            }
            if kind == "derivedPhoto"
                && i["workVersionID"].is_string()
                && report["workVersionID"] != i["workVersionID"]
            {
                return Err("Render receipt has another input work version".into());
            }
            used += 1;
            let (h, n) = digest(&dir.join(name(&i, pos)), std::io::sink())?;
            if i["sha256"] != h || i["byteCount"] != n {
                return Err("A frozen rendering input changed during processing".into());
            }
        }
    }
    if declared.len() != used {
        return Err("Rendering receipt includes an extra frame".into());
    }
    let resource = resources::stage(catalog, &path, &format!("group-output:{jid}"), kind, None)?;
    let managed = catalog
        .parent()
        .ok_or("Missing catalog directory")?
        .join("LibraryResources")
        .join(&resource.relative_path);
    media::verify(&managed, &receipt)?;
    if receipt["facts"]["outputSHA256"]
        .as_str()
        .is_some_and(|s| s != resource.sha256)
        || receipt["facts"]["outputByteCount"]
            .as_i64()
            .is_some_and(|n| n != resource.byte_count)
    {
        return Err("Worker output digest does not match the managed master".into());
    }
    if marker.exists() {
        let existing: Value = serde_json::from_reader(regular(&marker)?)?;
        if existing != receipt {
            return Err("Another receipt already exists for this attempt".into());
        }
    } else {
        let mut tmp = tempfile::NamedTempFile::new_in(&dir)?;
        serde_json::to_writer(tmp.as_file_mut(), &receipt)?;
        tmp.as_file().sync_all()?;
        tmp.persist_noclobber(&marker)?;
        File::open(&dir)?.sync_all()?;
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let latest = status(&tx, &jid)?;
    if latest["token"] != token {
        return Err("Attempt changed before storing output".into());
    }
    if latest["state"] == "rendering" {
        // Check the deadline again after reading the full media and waiting for the write lock.
        if !recover_marker && latest["leaseUntil"].as_i64().unwrap_or(0) <= time()? {
            return Err("Rendering lease expired before publication".into());
        }
        resources::register(&tx, &resource)?;
        tx.execute("UPDATE lc_proc_jobs SET state='staged',receipt_json=?2,resource_id=?3,lease_until=NULL WHERE job_id=?1",params![jid,receipt.to_string(),resource.resource_id])?;
        tx.execute(
            "UPDATE lc_proc_attempts SET state='staged' WHERE job_id=?1 AND token=?2",
            params![jid, token],
        )?;
    } else if !matches!(latest["state"].as_str(), Some("staged" | "published"))
        || latest["receipt"] != receipt
    {
        return Err("Output stage changed before registration".into());
    }
    tx.commit()?;
    status(db, &jid)
}
pub(super) fn stop(db: &mut Connection, r: &Value, cancel: bool) -> Result<Value> {
    let jid = job_id(r)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let job = status(&tx, &jid)?;
    let state = if cancel { "cancelled" } else { "failed" };
    if job["token"].as_str() != r["token"].as_str() {
        return Err("Attempt token changed".into());
    }
    if matches!(job["state"].as_str(), Some("rendering" | "preparing"))
        && job["leaseUntil"].as_i64().unwrap_or(0) <= time()?
    {
        return Err("Rendering lease expired".into());
    }
    if job["state"] == state {
        tx.commit()?;
        return Ok(job);
    }
    if matches!(job["state"].as_str(), Some("published" | "staged")) {
        return Err("Verified output is already staged or published".into());
    }
    let detail = r["detail"].as_str().unwrap_or(if cancel {
        "Cancelled by user"
    } else {
        "Rendering failed"
    });
    tx.execute(
        "UPDATE lc_proc_jobs SET state=?2,error=?3,lease_until=NULL WHERE job_id=?1",
        params![jid, state, detail],
    )?;
    tx.execute(
        "UPDATE lc_proc_attempts SET state=?3,diagnostic=?4 WHERE job_id=?1 AND token=?2",
        params![jid, r["token"].as_str(), state, detail],
    )?;
    tx.commit()?;
    status(db, &jid)
}
pub(super) fn clean_attempt(dir: &Path) {
    if fs::symlink_metadata(dir).is_ok_and(|m| m.is_dir()) {
        let _ = fs::remove_dir_all(dir);
    }
}
