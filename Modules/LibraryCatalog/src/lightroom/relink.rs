use super::*;
use md5::Md5;
use std::fs::File;
use std::io::Read;
#[derive(PartialEq)]
struct Proof {
    sha: String,
    md5: String,
    bytes: i64,
}
fn measure(p: &Path) -> Result<Proof> {
    let before = source::file_stamp(p)?.ok_or("Selected original is unavailable")?;
    let mut f = File::open(p)?;
    let mut sha = Sha256::new();
    let mut md = Md5::new();
    let mut buf = vec![0; 512 * 1024];
    let mut bytes = 0i64;
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        sha.update(&buf[..n]);
        md.update(&buf[..n]);
        bytes = bytes
            .checked_add(n as i64)
            .ok_or("Original file length overflow")?;
    }
    if source::file_stamp(p)?.as_ref() != Some(&before) || bytes as u64 != before.size {
        return Err("Original changed while its contents were being verified".into());
    }
    Ok(Proof {
        sha: hex::encode(sha.finalize()),
        md5: hex::encode(md.finalize()),
        bytes,
    })
}
fn digest<'a>(v: &'a Value, len: usize) -> Option<&'a str> {
    v.as_str()
        .map(str::trim)
        .filter(|s| s.len() == len && s.bytes().all(|b| b.is_ascii_hexdigit()))
}
pub(super) fn apply(catalog: &Path, r: &Value, link: bool) -> Result<Value> {
    let rid = required(r, "runID")?;
    let key = required(r, "sourceKey")?.parse::<i64>()?;
    let selected = Path::new(required(r, "path")?);
    if !selected.is_absolute() {
        return Err("Choose an absolute original-file path".into());
    }
    let mut db = target(catalog, link)?;
    let migration = run(&db, rid)?;
    let snapshot = source::open_readonly(&source::verified_resource(
        catalog,
        &db,
        &migration.snapshot,
    )?)?;
    let work = source::record(&snapshot, "Adobe_images", key)?.ok_or("Unknown Lightroom work")?;
    let master = integer(&work["masterImage"])
        .filter(|v| *v > 0)
        .unwrap_or(key);
    let base = source::record(&snapshot, "Adobe_images", master)?
        .ok_or("Lightroom master is unavailable")?;
    let file = integer(&base["rootFile"]).ok_or("Work has no original file reference")?;
    let index = source::open_readonly(&source::verified_resource(catalog, &db, &migration.order)?)?;
    let work_id = source_identity(&index, &migration.sid, "image", master)?;
    let source_file = source_identity(&index, &migration.sid, "file", file)?;
    let (hint, record): (String, String) = db.query_row(
        "SELECT source_path,checksum_json FROM lc_lr_file_versions WHERE run_id=?1 AND file_id=?2",
        params![migration.rid, source_file],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let checks: Value = serde_json::from_str(&record)?;
    let proof = measure(selected)?;
    let supplied_hash = digest(&checks["original"]["sha256"], 64);
    let supplied_md5 = digest(&checks["md5"], 32);
    let length = integer(&checks["original"]["size"]).filter(|v| *v >= 0);
    let mut evidence = Vec::new();
    let mut mismatch = false;
    if let Some(v) = supplied_hash {
        evidence.push("lightroomSHA256");
        mismatch |= !v.eq_ignore_ascii_case(&proof.sha);
    }
    if let Some(v) = supplied_md5 {
        evidence.push("lightroomMD5");
        mismatch |= !v.eq_ignore_ascii_case(&proof.md5);
    }
    if let Some(v) = length {
        evidence.push("lightroomByteCount");
        mismatch |= v != proof.bytes;
    }
    let binding:Option<(String,String,i64)>=db.query_row("SELECT library_file_id,sha256,byte_count FROM lc_lr_bindings WHERE source_id=?1 AND source_file_id=?2",params![migration.sid,source_file],|row|Ok((row.get(0)?,row.get(1)?,row.get(2)?))).optional()?;
    if let Some((_, sha, n)) = binding.as_ref() {
        evidence.push("priorVerifiedBinding");
        mismatch |= *sha != proof.sha || *n != proof.bytes;
    }
    let mut recognized = supplied_hash.is_some() || supplied_md5.is_some() || binding.is_some();
    if !recognized {
        let p = Path::new(&hint);
        if p.is_absolute() && source::file_stamp(p).ok().flatten().is_some() {
            let same = p.canonicalize()? == selected.canonicalize()?;
            if same || measure(p)? == proof {
                recognized = true;
                evidence.push("recordedOriginalBytes");
            } else {
                mismatch = true;
            }
        }
    }
    let state = if mismatch {
        "differentContent"
    } else if recognized {
        "verified"
    } else {
        "noIndependentSourceProof"
    };
    let mut matches = Vec::new();
    if state == "verified" {
        let mut q=db.prepare("SELECT DISTINCT s.file_id FROM lc_scopes s JOIN lc_contents c ON c.content_id=s.content_id JOIN lc_replicas p ON p.file_id=s.file_id AND p.content_id=c.content_id AND p.state='available' WHERE c.sha256=?1 AND c.byte_count=?2 AND EXISTS(SELECT 1 FROM lc_catalog_files v WHERE v.file_id=s.file_id) ORDER BY s.file_id")?;
        for row in q.query_map(params![proof.sha, proof.bytes], |r| r.get::<_, String>(0))? {
            matches.push(row?);
        }
    }
    let mut response = json!({"state":state,"sha256":proof.sha,"byteCount":proof.bytes,"evidence":evidence,"fileIDs":matches,"masterWorkID":work_id});
    if !link {
        return Ok(response);
    }
    if state != "verified"
        || r["sha256"].as_str() != Some(&proof.sha)
        || integer(&r["byteCount"]) != Some(proof.bytes)
    {
        return Err("Selected bytes do not match the verified Lightroom original".into());
    }
    let library_file = required(r, "fileID")?;
    if !matches.iter().any(|s| s == library_file) {
        return Err("Choose an independently admitted, verified file matching these bytes".into());
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let previous:Option<(String,String,i64)>=tx.query_row("SELECT library_file_id,sha256,byte_count FROM lc_lr_bindings WHERE source_id=?1 AND source_file_id=?2",params![migration.sid,source_file],|row|Ok((row.get(0)?,row.get(1)?,row.get(2)?))).optional()?;
    if previous
        .as_ref()
        .is_some_and(|(f, s, n)| f != library_file || s != &proof.sha || *n != proof.bytes)
    {
        return Err(
            "This Lightroom logical original already has a different verified binding".into(),
        );
    }
    let (kind, current, rev): (String, Option<String>, i64) = tx.query_row(
        "SELECT kind,file_id,revision FROM lc_org_works WHERE work_id=?1",
        [&work_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    if kind == "offline" {
        let reply = crate::organization::apply(
            &tx,
            &json!({"action":"org.linkOriginal","workID":work_id,"fileID":library_file,"sha256":proof.sha,"byteCount":proof.bytes,"baseRevision":rev}),
        )?;
        tx.execute("UPDATE lc_lr_map SET applied_revision=?4 WHERE source_id=?1 AND kind='image' AND target_id=?2 AND applied_revision=?3",params![migration.sid,work_id,rev,reply["revision"].as_i64()])?;
    } else if kind != "original" || current.as_deref() != Some(library_file) {
        return Err("Target work has another original binding".into());
    }
    tx.execute("INSERT INTO lc_lr_bindings(source_id,source_file_id,library_file_id,sha256,byte_count) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(source_id,source_file_id) DO NOTHING",params![migration.sid,source_file,library_file,proof.sha,proof.bytes])?;
    tx.commit()?;
    response["state"] = json!("linked");
    response["fileID"] = json!(library_file);
    Ok(response)
}
