use super::{index, open_actual, separate_files};
use crate::Result;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs::{self, File},
    io::{ErrorKind, Read, Write},
    path::{Path, PathBuf},
};
use tempfile::NamedTempFile;
use uuid::Uuid;

#[derive(Serialize, Deserialize, Eq, PartialEq)]
struct Owner {
    format: u8,
    library: String,
    inode: String,
    active: Option<String>,
}
fn suffix(base: &Path, extra: &str) -> PathBuf {
    let mut s = base.as_os_str().to_owned();
    s.push(extra);
    PathBuf::from(s)
}
fn owner_file(base: &Path) -> PathBuf {
    suffix(base, ".rawmaster-search-owner.json")
}
fn actual(base: &Path, active: Option<&str>) -> PathBuf {
    active
        .map(|id| suffix(base, &format!(".recovered-{id}")))
        .unwrap_or_else(|| base.to_owned())
}
fn owner(base: &Path) -> Result<Option<Owner>> {
    let file = owner_file(base);
    match fs::symlink_metadata(&file) {
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
        Ok(m) if !m.is_file() || m.len() > 4096 => {
            return Err("unexpected search ownership marker".into())
        }
        _ => (),
    }
    let parsed: Owner = serde_json::from_slice(&fs::read(file)?)?;
    if let Some(id) = &parsed.active {
        if Uuid::parse_str(id)?.to_string() != *id {
            return Err("invalid search recovery generation".into());
        }
    }
    if parsed.format != 1 {
        return Err("unsupported search ownership marker".into());
    }
    Ok(Some(parsed))
}
fn publish(base: &Path, value: &Owner, previous: Option<&Owner>) -> Result<()> {
    if owner(base)?.as_ref() != previous {
        return Err("search ownership changed; reopen the cache".into());
    }
    let parent = base
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let mut tmp = NamedTempFile::new_in(parent)?;
    tmp.write_all(&serde_json::to_vec(value)?)?;
    tmp.as_file().sync_all()?;
    if previous.is_some() {
        tmp.persist(owner_file(base))?;
    } else if let Err(err) = tmp.persist_noclobber(owner_file(base)) {
        if err.error.kind() != ErrorKind::AlreadyExists || owner(base)?.as_ref() != Some(value) {
            return Err(err.into());
        }
    }
    File::open(parent)?.sync_all()?;
    Ok(())
}
fn library(db: &Connection) -> Result<String> {
    Ok(
        db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
            r.get(0)
        })?,
    )
}
pub(super) fn connections(catalog: &Path, base: &Path) -> Result<(Connection, Connection, String)> {
    separate_files(catalog, base)?;
    let prior = owner(base)?;
    let active = prior.as_ref().and_then(|v| v.active.clone());
    if let Some(o) = &prior {
        let check = Connection::open_with_flags(catalog, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        if o.library != library(&check)? {
            return Err("search cache belongs to another library".into());
        }
    }
    let path = actual(base, active.as_deref());
    let (source, cache, stamp) = open_actual(catalog, &path)?;
    let lib = library(&source)?;
    if prior.as_ref().is_some_and(|o|o.library!=lib) || cache.query_row(
        "SELECT EXISTS(SELECT 1 FROM generations WHERE state IN ('building','active') AND library!=?1)",[&lib],|r|r.get::<_,bool>(0))?{
        return Err("search cache belongs to another library".into());
    }
    let expected = Owner {
        format: 1,
        library: lib,
        inode: index::stamp(&path)?,
        active,
    };
    if prior.as_ref() != Some(&expected) {
        publish(base, &expected, prior.as_ref())?;
    }
    Ok((source, cache, stamp))
}
fn healthy(cache: &Connection) -> Result<()> {
    let check: String = cache.query_row("PRAGMA quick_check(1)", [], |r| r.get(0))?;
    if check != "ok" {
        return Err(format!("corrupt search cache: {check}").into());
    }
    Ok(())
}
pub fn validate(catalog: &Path, index: &Path) -> Result<Value> {
    if !index.exists() && owner(index)?.is_none() {
        return Err("search cache is missing".into());
    }
    let (source, cache, _) = connections(catalog, index)?;
    healthy(&cache)?;
    let active = index::published(&cache)?.ok_or("search cache has no published generation")?;
    Ok(
        json!({"status":"ok","libraryID":library(&source)?,"generation":active.token,"watermark":active.watermark}),
    )
}
fn recoverable(err: &(dyn std::error::Error + Send + Sync + 'static)) -> bool {
    if let Some(r) = err.downcast_ref::<rusqlite::Error>() {
        if matches!(
            r.sqlite_error_code(),
            Some(rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase)
        ) {
            return true;
        }
    }
    let m = err.to_string();
    m.starts_with("unsupported search index format")
        || m.starts_with("corrupt search cache:")
        || m.contains("no such table: provider")
        || m.contains("no such table: generations")
}
pub fn rebuild(catalog: &Path, base: &Path) -> Result<Value> {
    let normal = (|| -> Result<Value> {
        let (mut source, mut cache, stamp) = connections(catalog, base)?;
        healthy(&cache)?;
        let s = index::force(&mut source, &mut cache, &stamp)?;
        index::collect_obsolete(&mut cache)?;
        Ok(
            json!({"status":"ok","libraryID":s.library,"generation":s.token,"watermark":s.watermark,"recovered":false}),
        )
    })();
    match normal {
        Ok(v) => return Ok(v),
        Err(e) if !recoverable(e.as_ref()) => return Err(e),
        Err(_) => (),
    }
    let old = owner(base)?.ok_or("cannot establish ownership of the damaged search database")?;
    let previous = actual(base, old.active.as_deref());
    separate_files(catalog, &previous)?;
    let source = Connection::open_with_flags(catalog, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    index::validate_source(&source)?;
    if old.library != library(&source)? || old.inode != index::stamp(&previous)? {
        return Err("damaged file does not match the cache owned by this library".into());
    }
    let mut header = [0; 72];
    let file = File::open(&previous)?;
    let mut bytes = Vec::new();
    file.take(72).read_to_end(&mut bytes)?;
    if bytes.len() == 72 {
        header.copy_from_slice(&bytes);
        if &header[..16] == b"SQLite format 3\0"
            && u32::from_be_bytes(header[68..72].try_into()?) as i64 != index::APPLICATION
        {
            return Err("this SQLite database is not a RAWMaster search cache".into());
        }
    }
    let token = Uuid::new_v4().to_string();
    let new_path = actual(base, Some(&token));
    let (mut source, mut cache, stamp) = open_actual(catalog, &new_path)?;
    let state = index::synchronize(&mut source, &mut cache, &stamp)?;
    healthy(&cache)?;
    // Switch a small ownership pointer only after the new database is readable.
    // Existing readers and any diagnostic data keep their original file names.
    publish(
        base,
        &Owner {
            format: 1,
            library: old.library.clone(),
            inode: index::stamp(&new_path)?,
            active: Some(token),
        },
        Some(&old),
    )?;
    Ok(
        json!({"status":"ok","libraryID":state.library,"generation":state.token,"watermark":state.watermark,"recovered":true}),
    )
}
