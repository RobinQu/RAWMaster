use super::*;
use crate::authority;
use inventory::has;
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use std::collections::BTreeMap;

pub(super) fn guard_destination(catalog: &Path, destination: &Path) -> Result<()> {
    let db = open(catalog, false)?;
    let mut protected = Vec::new();
    if has(&db, "sessions")? {
        let mut q = db.prepare("SELECT data FROM sessions")?;
        for row in q.query_map([], |r| r.get::<_, String>(0))? {
            let s: Value = serde_json::from_str(&row?)?;
            for k in [
                "sourcePath",
                "effectiveSourceRoot",
                "destinationPath",
                "effectiveManagedRoot",
            ] {
                if let Some(v) = s[k].as_str().filter(|s| !s.is_empty()) {
                    protected.push(PathBuf::from(v));
                }
            }
        }
    }
    if has(&db, "metadata")? {
        if let Some(path) = db
            .query_row(
                "SELECT value FROM metadata WHERE key='editingArchiveRoot'",
                [],
                |r| r.get::<_, String>(0),
            )
            .optional()?
        {
            protected.push(path.into());
        }
    }
    protected.push(parent(catalog)?.join("LibraryResources"));
    for p in protected {
        if p.is_absolute() {
            distinct_dirs(&absolute(&p)?, destination)?;
        }
    }
    Ok(())
}

fn check_reopened_catalog(path: &Path, dest: &Path, m: &Manifest) -> Result<()> {
    let reopened = open(path, false)?;
    integrity(&reopened)?;
    crate::validate_catalog_objects(&reopened)?;
    let mut lookup = reopened.prepare(
        "SELECT DISTINCT a.current_path FROM lc_archive_files f JOIN lc_asset_input a ON a.asset_id=f.asset_id
        WHERE f.scope_id=?1 AND f.file_id=?3 AND f.content_id=?4 AND f.path=?2 AND a.current_path=a.source_path
        AND a.content_id=f.content_id AND a.availability='available' AND EXISTS(SELECT 1 FROM lc_archive_files resolver
          WHERE resolver.scope_id=f.scope_id AND resolver.path=a.current_path)",
    )?;
    for o in &m.originals {
        if m.mode == Mode::Full {
            let final_path = dest.join(o.restored_path());
            let resolved: String = lookup.query_row(
                params![
                    o.scope_id,
                    final_path.to_str().ok_or("non-UTF8 restored path")?,
                    o.file_id,
                    o.content_id
                ],
                |r| r.get(0),
            )?;
            let rel = Path::new(&resolved)
                .strip_prefix(dest)
                .map_err(|_| "restored catalog resolves outside its library")?;
            files::relative(rel.to_str().ok_or("non-UTF8 resolved original")?)?;
            check(&parent(path)?.join(rel), &o.object)?;
        }
    }
    Ok(())
}

fn set_editing_root(db: &Connection, dest: &Path) -> Result<()> {
    if has(db, "metadata")? {
        let new_path = dest.join("EditingArchive");
        db.execute(
            "UPDATE metadata SET value=? WHERE key='editingArchiveRoot'",
            [new_path.to_str().ok_or("invalid editing archive path")?],
        )?;
    }
    Ok(())
}
fn restore_result(m: &Manifest, dest: &Path) -> Value {
    let files = m
        .originals
        .iter()
        .map(|o| &o.file_id)
        .collect::<BTreeSet<_>>()
        .len();
    json!({"state":"complete","libraryPath":dest.join(DB),"libraryRoot":dest,"mode":m.mode,"generation":m.generation,
        "restoredFiles":if m.mode==Mode::Full {files}else{0},"restoredResources":m.resources.len(),"deferred":m.deferred})
}
fn attach(
    db: &Connection,
    scope: &Original,
    root_id: &str,
    relative: &str,
    final_path: &Path,
    actual: &Path,
) -> Result<()> {
    check(actual, &scope.object)?;
    authority::restore_replica(
        db,
        &scope.file_id,
        &scope.content_id,
        root_id,
        relative,
        final_path,
        actual,
    )?;
    authority::activate_restored_scope(
        db,
        &scope.scope_id,
        &scope.file_id,
        &scope.content_id,
        final_path,
    )?;
    Ok(())
}
fn mapped_originals(m: &Manifest) -> BTreeMap<PathBuf, &Original> {
    let mut paths = BTreeMap::new();
    if m.mode == Mode::Full {
        for original in &m.originals {
            paths.insert(original.restored_path(), original);
        }
    }
    paths
}
fn check_materialized(m: &Manifest, root: &Path) -> Result<()> {
    for (path, o) in mapped_originals(m) {
        check(&root.join(path), &o.object)?;
    }
    for r in &m.resources {
        check(&root.join(&r.target), &r.object)?;
    }
    Ok(())
}
pub(super) fn restore(request: &Value) -> Result<Value> {
    let src = path_request(request, "package")?;
    let dest = path_request(request, "destination")?;
    distinct_dirs(&src, &dest)?;
    let (m, inv, h) = package_header(&src, request["expectedManifestSHA256"].as_str())?;
    guard_destination(&src.join(DB), &dest)?;
    validate_objects(&src, &inv, m.mode)?;
    let record =
        json!({"format":1,"manifestSHA256":h,"generation":m.generation,"libraryRoot":dest});
    if exists(&dest)? {
        directory(&dest, false)?;
        if !exists(&dest.join("restoration.json"))?
            || read_json::<Value>(&dest.join("restoration.json"))? != record
        {
            return Err("restore destination already exists; choose an unused directory".into());
        }
        integrity(&open(&dest.join(DB), false)?)?;
        check_materialized(&m, &dest)?;
        let mut result = restore_result(&m, &dest);
        result["alreadyRestored"] = json!(true);
        return Ok(result);
    }
    let (stage, _lock) = private_stage(&dest, "restore")?;
    files::discard_abandoned_temps(&stage)?;
    let marker = stage.join("restoration.json");
    if exists(&marker)? {
        if read_json::<Value>(&marker)? != record {
            return Err("restore stage belongs to another package".into());
        }
    } else {
        if fs::read_dir(&stage)?.next().is_some() {
            return Err("unrecognized existing restoration stage".into());
        }
        write_json(&marker, &record)?;
    }
    for obj in inv.required(m.mode) {
        let out = stage.join(obj.path());
        if !keep_verified(&out, &obj)? {
            verified_copy(&mut regular(&src.join(obj.path()))?, &out, &obj)?;
        }
    }
    let originals = mapped_originals(&m);
    for (rel, original) in &originals {
        files::link_or_copy(
            &stage.join(original.object.path()),
            &stage.join(rel),
            &original.object,
        )?;
    }
    for r in &m.resources {
        files::link_or_copy(
            &stage.join(r.object.path()),
            &stage.join(&r.target),
            &r.object,
        )?;
    }
    if inv
        .resources
        .iter()
        .any(|r| r.target.starts_with("EditingArchive/"))
        || has(&open(&src.join(DB), false)?, "metadata")?
    {
        for sub in [
            "artifacts",
            "receipts",
            ".staging",
            ".received",
            "received-receipts",
            ".inputs",
        ] {
            directory(&stage.join("EditingArchive").join(sub), true)?;
        }
    }
    // Rebuild the small mutable copy from the sealed DB on each attempt. Never hard-link
    // a future SQLite writer to its backup. Only already verified media are reused.
    let dest_db = stage.join(DB);
    for suffix in ["", "-journal", "-wal", "-shm"] {
        let f = stage.join(format!("{DB}{suffix}"));
        if exists(&f)? {
            regular(&f)?;
            fs::remove_file(f)?;
        }
    }
    verified_copy(&mut regular(&src.join(DB))?, &dest_db, &m.catalog)?;
    {
        let mut db = open(&dest_db, true)?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let root_id = format!("restored:{}", hexsum(dest.as_os_str().as_encoded_bytes()));
        if m.mode == Mode::Full {
            for (rel, o) in &originals {
                authority::restore_replica(
                    &tx,
                    &o.file_id,
                    &o.content_id,
                    &root_id,
                    rel.to_str().ok_or("non-UTF8 package path")?,
                    &dest.join(rel),
                    &stage.join(rel),
                )?;
            }
            for o in &m.originals {
                authority::activate_restored_scope(
                    &tx,
                    &o.scope_id,
                    &o.file_id,
                    &o.content_id,
                    &dest.join(o.restored_path()),
                )?;
            }
            // The destination is a new local library. Old machine locations remain available
            // for explicit reconnection, but they have not been verified on this machine.
            tx.execute("UPDATE lc_replicas SET state='unknown' WHERE state='available' AND root_id<>?1
                AND EXISTS(SELECT 1 FROM lc_scopes s WHERE s.file_id=lc_replicas.file_id AND s.content_id=lc_replicas.content_id)",[&root_id])?;
        }
        set_editing_root(&tx, &dest)?;
        super::detach_restored_writer(&tx)?;
        tx.commit()?;
        db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")?;
    }
    check_reopened_catalog(&dest_db, &dest, &m)?;
    check_materialized(&m, &stage)?;
    regular(&dest_db)?.sync_all()?;
    directory(&stage, false)?.sync_all()?;
    // Catch changed package seals during the copy and never overwrite an existing live library.
    package_header(&src, Some(&h))?;
    publish(&stage, &dest)?;
    Ok(restore_result(&m, &dest))
}

fn old_locations(db: &Connection, original: &Original, old: &Path) -> Result<BTreeSet<PathBuf>> {
    let mut possible = BTreeSet::new();
    let mut q = db.prepare(
        "SELECT path FROM lc_replicas WHERE file_id=? AND content_id=? AND path IS NOT NULL",
    )?;
    let mut vals = q.query(params![original.file_id, original.content_id])?;
    while let Some(r) = vals.next()? {
        let Ok(path) = absolute(Path::new(&r.get::<_, String>(0)?)) else {
            continue;
        };
        if let Ok(rel) = path.strip_prefix(old) {
            if let Some(s) = rel.to_str() {
                files::relative(s)?;
                possible.insert(rel.to_owned());
            }
        }
    }
    let data: String = db.query_row(
        "SELECT data FROM assets WHERE id=?",
        [&original.asset_id],
        |r| r.get(0),
    )?;
    let v: Value = serde_json::from_str(&data)?;
    for key in [
        "sourcePath",
        "effectiveSourcePath",
        "currentPath",
        "effectiveManagedPath",
    ] {
        if let Some(s) = v[key].as_str() {
            let Ok(p) = absolute(Path::new(s)) else {
                continue;
            };
            if let Ok(rel) = p.strip_prefix(old) {
                if let Some(s) = rel.to_str() {
                    files::relative(s)?;
                    possible.insert(rel.to_owned());
                }
            }
        }
    }
    Ok(possible)
}

pub(super) fn relink(catalog: &Path, request: &Value) -> Result<Value> {
    let old = path_request(request, "fromRoot")?;
    let new = path_request(request, "toRoot")?;
    directory(&new, false)?;
    let temp = tempfile::tempdir()?;
    snapshot(catalog, temp.path())?;
    let frozen = open(&temp.path().join(DB), false)?;
    let inv = Inventory::from_snapshot(&frozen, catalog, Mode::Catalog)?;
    let mut candidates = BTreeMap::new();
    for o in &inv.originals {
        let paths = old_locations(&frozen, o, &old)?;
        if !paths.is_empty() {
            candidates.insert(o.scope_id.clone(), (o.clone(), paths));
        }
    }
    drop(frozen);
    let mut db = open(catalog, true)?;
    let root_id = format!("relocated:{}", hexsum(new.as_os_str().as_encoded_bytes()));
    let mut missing = Vec::new();
    let mut linked = BTreeSet::new();
    for (_, (o, paths)) in candidates {
        let mut located = None;
        for rel in paths {
            let path = new.join(&rel);
            if check(&path, &o.object).is_ok() {
                located = Some((rel, path));
                break;
            }
        }
        if let Some((rel, path)) = located {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            attach(
                &tx,
                &o,
                &root_id,
                rel.to_str().ok_or("invalid relative path")?,
                &path,
                &path,
            )?;
            tx.commit()?;
            linked.insert(o.file_id);
        } else {
            missing.push(json!({"fileID":o.file_id,"assetID":o.asset_id,"relativePath":o.relative_path,"reason":"missingOrChanged"}));
        }
    }
    // A restored library is itself movable. Rebase its managed editing root only when the
    // catalog has physically moved under the new root and all frozen attachment paths verify.
    if catalog.starts_with(&new) && has(&db, "metadata")? {
        let current: Option<String> = db
            .query_row(
                "SELECT value FROM metadata WHERE key='editingArchiveRoot'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        if current
            .as_deref()
            .is_some_and(|p| Path::new(p).starts_with(&old))
        {
            for resource in &inv.resources {
                check(&parent(catalog)?.join(&resource.target), &resource.object)?;
            }
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            set_editing_root(&tx, parent(catalog)?)?;
            tx.commit()?;
        }
    }
    Ok(
        json!({"state":if missing.is_empty(){"complete"}else{"incomplete"},"linkedFiles":linked.len(),"missing":missing,"canResume":!missing.is_empty()}),
    )
}
