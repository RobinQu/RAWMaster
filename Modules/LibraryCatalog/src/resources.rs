use crate::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use tempfile::NamedTempFile;

const SQL: &str = "CREATE TABLE lc_resources(resource_id TEXT PRIMARY KEY NOT NULL,kind TEXT NOT NULL,relative_path TEXT NOT NULL,sha256 TEXT NOT NULL,byte_count INTEGER NOT NULL CHECK(byte_count>=0),source_asset_id TEXT)";
pub const TABLE: &str = "lc_resources";

pub fn install(db: &Connection) -> Result<()> {
    db.execute_batch(SQL)?;
    Ok(())
}

pub fn validate(db: &Connection) -> Result<()> {
    let actual: Option<String> = db
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE type='table' AND name='lc_resources'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if actual.as_deref() != Some(SQL) {
        return Err("Invalid resource schema".into());
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Resource {
    pub resource_id: String,
    pub kind: String,
    pub relative_path: String,
    pub sha256: String,
    pub byte_count: i64,
    pub source_asset_id: Option<String>,
}

pub fn object_path(digest: &str) -> Result<PathBuf> {
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err("Invalid SHA-256 resource identity".into());
    }
    Ok(Path::new("objects").join(&digest[..2]).join(digest))
}

fn directory(path: &Path) -> Result<()> {
    match fs::create_dir(path) {
        Ok(()) => File::open(path.parent().ok_or("Missing directory parent")?)?.sync_all()?,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(e) => return Err(e.into()),
    }
    if !fs::symlink_metadata(path)?.is_dir() {
        return Err("Expected a real storage directory".into());
    }
    Ok(())
}

fn open_regular(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() {
        return Err("Expected a regular resource file".into());
    }
    Ok(file)
}

fn transfer(mut source: File, mut destination: impl Write) -> Result<(String, i64)> {
    let mut hash = Sha256::new();
    let mut buffer = vec![0; 256 * 1024];
    let mut total = 0_i64;
    loop {
        let n = source.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
        destination.write_all(&buffer[..n])?;
        total = total
            .checked_add(n as i64)
            .ok_or("Resource size overflow")?;
    }
    Ok((hex::encode(hash.finalize()), total))
}

/// Stage bytes before opening a write transaction. Unregistered objects are never enumerated by backup.
pub fn stage(
    catalog: &Path,
    input: &Path,
    id: &str,
    kind: &str,
    source_asset_id: Option<String>,
) -> Result<Resource> {
    if id.is_empty()
        || !matches!(
            kind,
            "historicalLook"
                | "adobePayload"
                | "sidecar"
                | "derivedPhoto"
                | "derivedVideo"
                | "recipeResource"
        )
    {
        return Err("Unknown resource kind or empty identity".into());
    }
    let base = catalog
        .parent()
        .ok_or("Missing library root")?
        .join("LibraryResources");
    directory(&base)?;
    let objects = base.join("objects");
    directory(&objects)?;
    let mut temp = NamedTempFile::new_in(&objects)?;
    let (sha256, byte_count) = transfer(open_regular(input)?, temp.as_file_mut())?;
    temp.as_file().sync_all()?;
    let relative = object_path(&sha256)?;
    let target = base.join(&relative);
    let parent = target.parent().ok_or("Missing object root")?;
    directory(parent)?;
    match temp.persist_noclobber(&target) {
        Ok(_) => File::open(parent)?.sync_all()?,
        Err(e) if e.error.kind() == std::io::ErrorKind::AlreadyExists => {
            let (found, size) = transfer(open_regular(&target)?, std::io::sink())?;
            if found != sha256 || size != byte_count {
                return Err("Stored resource failed verification".into());
            }
        }
        Err(e) => return Err(e.error.into()),
    }
    Ok(Resource {
        resource_id: id.into(),
        kind: kind.into(),
        relative_path: relative.to_string_lossy().into_owned(),
        sha256,
        byte_count,
        source_asset_id,
    })
}

/// Call in the same transaction as the owner record. Replaying the same published object is harmless.
pub fn register(db: &Connection, resource: &Resource) -> Result<()> {
    let expected = object_path(&resource.sha256)?;
    if resource.byte_count < 0
        || expected != Path::new(&resource.relative_path)
        || resource.resource_id.is_empty()
        || !matches!(
            resource.kind.as_str(),
            "historicalLook"
                | "adobePayload"
                | "sidecar"
                | "derivedPhoto"
                | "derivedVideo"
                | "recipeResource"
        )
    {
        return Err("Invalid library resource".into());
    }
    let added = db.execute(
        "INSERT INTO lc_resources(resource_id,kind,relative_path,sha256,byte_count,source_asset_id)
         VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(resource_id) DO NOTHING",
        params![
            resource.resource_id,
            resource.kind,
            resource.relative_path,
            resource.sha256,
            resource.byte_count,
            resource.source_asset_id
        ],
    )?;
    if added == 0 {
        let matches: bool = db.query_row(
            "SELECT kind=?2 AND relative_path=?3 AND sha256=?4 AND byte_count=?5 AND source_asset_id IS ?6
             FROM lc_resources WHERE resource_id=?1", params![resource.resource_id, resource.kind, resource.relative_path,
             resource.sha256, resource.byte_count, resource.source_asset_id], |r| r.get(0))?;
        if !matches {
            return Err("Resource identity already has different bytes or provenance".into());
        }
    }
    Ok(())
}
