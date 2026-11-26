//! Local metadata reads. The catalog owns identity and admission. The second
//! SQLite file owns replaceable document projections and short-lived cursors.
mod filter;
mod index;
mod maintenance;
mod read;
mod text;
pub(crate) mod works;

use crate::Result;
use rusqlite::{functions::FunctionFlags, params, Connection, OpenFlags};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
    time::Duration,
};

fn sqlite_paths(main: &Path) -> Vec<PathBuf> {
    ["", "-wal", "-shm", "-journal"]
        .into_iter()
        .map(|suffix| {
            let mut name = main.as_os_str().to_owned();
            name.push(suffix);
            PathBuf::from(name)
        })
        .collect()
}

#[derive(Default)]
struct FileFamily {
    paths: HashSet<PathBuf>,
    #[cfg(unix)]
    inodes: HashSet<(u64, u64)>,
}

fn intended_parent(parent: &Path) -> Result<PathBuf> {
    match parent.canonicalize() {
        Ok(path) => return Ok(path),
        Err(e) if e.kind() == ErrorKind::NotFound => (),
        Err(e) => return Err(e.into()),
    }
    let mut path = PathBuf::new();
    for part in std::path::absolute(parent)?.components() {
        match part {
            std::path::Component::CurDir => (),
            std::path::Component::ParentDir => {
                path.pop();
            }
            _ => {
                path.push(part.as_os_str());
                match path.symlink_metadata() {
                    Ok(m) if m.is_symlink() => path = path.canonicalize()?,
                    Ok(_) => (),
                    Err(e) if e.kind() == ErrorKind::NotFound => (),
                    Err(e) => return Err(e.into()),
                }
            }
        }
    }
    Ok(path)
}

// Include prospective sidecar names even before SQLite creates them. For a
// symlinked main file, inspect both the requested spelling and the resolved
// filename: platform VFS implementations may construct sidecars from either.
fn file_family(main: &Path) -> Result<FileFamily> {
    let parent = main
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let requested =
        intended_parent(parent)?.join(main.file_name().ok_or("SQLite path must name a file")?);
    let mut roots = vec![requested.clone()];
    match requested.canonicalize() {
        Ok(target) if target != requested => roots.push(target),
        Ok(_) => (),
        Err(e) if e.kind() == ErrorKind::NotFound => (),
        Err(e) => return Err(e.into()),
    }
    let mut family = FileFamily::default();
    for root in roots {
        for path in sqlite_paths(&root) {
            if !family.paths.insert(path.clone()) {
                continue;
            }
            let meta = match fs::symlink_metadata(&path) {
                Ok(m) => m,
                Err(e) if e.kind() == ErrorKind::NotFound => continue,
                Err(e) => return Err(e.into()),
            };
            let target_meta = if meta.is_symlink() {
                // Opening a dangling sidecar symlink might create another
                // database's currently absent journal through that link.
                let resolved = path
                    .canonicalize()
                    .map_err(|e| format!("cannot resolve SQLite file or journal link: {e}"))?;
                let target_meta = resolved.metadata()?;
                family.paths.insert(resolved);
                target_meta
            } else {
                meta
            };
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                family.inodes.insert((target_meta.dev(), target_meta.ino()));
            }
            #[cfg(not(unix))]
            let _ = target_meta;
        }
    }
    Ok(family)
}

pub(crate) fn separate_files(catalog: &Path, index: &Path) -> Result<()> {
    let catalog = file_family(catalog)?;
    let index = file_family(index)?;
    let overlap = index.paths.iter().any(|p| {
        catalog
            .paths
            .iter()
            .any(|c| p.starts_with(c) || c.starts_with(p))
    });
    #[cfg(unix)]
    let overlap = overlap || !catalog.inodes.is_disjoint(&index.inodes);
    if overlap {
        return Err("search cache path conflicts with catalog database or journal".into());
    }
    Ok(())
}

fn open_actual(catalog: &Path, index: &Path) -> Result<(Connection, Connection, String)> {
    let source_stamp = index::stamp(catalog)?;
    let source_file = fs::metadata(catalog)?;
    if !source_file.is_file() {
        return Err("catalog path must be a file".into());
    }
    separate_files(catalog, index)?;
    if let Some(parent) = index.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let source = Connection::open_with_flags(
        catalog,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    source.busy_timeout(Duration::from_secs(5))?;
    source.execute_batch("PRAGMA cache_size=-262144; PRAGMA temp_store=MEMORY;")?;
    source.pragma_update(None, "query_only", true)?;
    index::validate_source(&source)?;
    if source_stamp != index::stamp(catalog)? {
        return Err("catalog was replaced during open; reopen it".into());
    }
    // Opening a live WAL reader can materialize an SHM file. Include any new
    // companions in the check immediately before the first writable open.
    separate_files(catalog, index)?;
    let cache = Connection::open(index)?;
    cache.busy_timeout(Duration::from_secs(5))?;
    cache.execute_batch("PRAGMA cache_size=-262144; PRAGMA temp_store=MEMORY;")?;
    cache.create_collation("rm_natural", text::natural)?;
    cache.create_scalar_function(
        "rm_cjk",
        1,
        FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
        |ctx| Ok(text::cjk_index(&ctx.get::<String>(0)?)),
    )?;
    cache.pragma_update(None, "foreign_keys", true)?;
    index::initialize(&cache)?;
    Ok((source, cache, source_stamp))
}
use maintenance::connections;
pub use maintenance::{rebuild, validate};

pub fn refresh(catalog: &Path, index: &Path) -> Result<Value> {
    let (mut source, mut cache, stamp) = connections(catalog, index)?;
    let state = index::synchronize(&mut source, &mut cache, &stamp)?;
    index::collect_obsolete(&mut cache)?;
    Ok(
        json!({"status":"ok","generation":state.token,"watermark":state.watermark,"libraryID":state.library}),
    )
}

pub fn page(catalog: &Path, index: &Path, request: &Value) -> Result<Value> {
    if works::needed(request) {
        let source = Connection::open_with_flags(
            catalog,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        source.busy_timeout(Duration::from_secs(5))?;
        index::validate_source(&source)?;
        return crate::organization::work_page(&source, request);
    }
    let options = filter::Request::parse(request)?;
    let (mut source, mut cache, stamp) = connections(catalog, index)?;
    loop {
        let expected = index::synchronize(&mut source, &mut cache, &stamp)?;
        let snapshot = cache.transaction()?;
        let Some(state) = index::published(&snapshot)? else {
            continue;
        };
        // Another synchronizer can advance the index between our two transactions.
        // A single read snapshot holds counts, cards, facets and action IDs together.
        if state != expected {
            continue;
        }
        let (result, facet_write) = read::run(&snapshot, &state, &options)?;
        drop(snapshot);
        if let Some(write) = facet_write {
            cache.execute(
                "INSERT OR REPLACE INTO facet_cache
                 (gen,watermark,fingerprint,names,payload) VALUES(?,?,?,?,?)",
                params![
                    state.gen,
                    state.watermark,
                    write.fingerprint,
                    write.names,
                    write.payload
                ],
            )?;
            cache.execute(
                "DELETE FROM facet_cache WHERE gen<>? OR (gen=? AND watermark<?)",
                params![state.gen, state.gen, state.watermark],
            )?;
        }
        return Ok(result);
    }
}
