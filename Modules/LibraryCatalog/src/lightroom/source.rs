use super::*;
use rusqlite::{backup::Backup, types::ValueRef};
use serde::{Deserialize, Serialize};
use std::fs::Metadata;
use std::time::{Duration, UNIX_EPOCH};
use tempfile::TempDir;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Stamp {
    pub size: u64,
    pub time: u128,
    pub change: i64,
    pub nanos: i64,
    pub inode: u64,
    pub device: u64,
}
fn stamp(m: Metadata) -> Result<Stamp> {
    let time = m.modified()?.duration_since(UNIX_EPOCH)?.as_nanos();
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(Stamp {
            size: m.len(),
            time,
            change: m.ctime(),
            nanos: m.ctime_nsec(),
            inode: m.ino(),
            device: m.dev(),
        })
    }
    #[cfg(not(unix))]
    {
        Ok(Stamp {
            size: m.len(),
            time,
            change: 0,
            nanos: 0,
            inode: 0,
            device: 0,
        })
    }
}
pub(super) fn file_stamp(p: &Path) -> Result<Option<Stamp>> {
    match fs::symlink_metadata(p) {
        Ok(m) if m.is_file() => Ok(Some(stamp(m)?)),
        Ok(_) => Err(format!("Expected a regular source file: {}", p.display()).into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}
fn sibling(p: &Path, suffix: &str) -> PathBuf {
    let mut path = p.as_os_str().to_owned();
    path.push(suffix);
    path.into()
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct DbStamp {
    main: Option<Stamp>,
    wal: Option<Stamp>,
    journal: Option<Stamp>,
}
pub(super) fn db_stamp(p: &Path) -> Result<DbStamp> {
    Ok(DbStamp {
        main: file_stamp(p)?,
        wal: file_stamp(&sibling(p, "-wal"))?,
        journal: file_stamp(&sibling(p, "-journal"))?,
    })
}
pub(super) fn cache_dir(p: &Path) -> PathBuf {
    let mut name = p.file_stem().unwrap_or_default().to_owned();
    name.push(" Previews.lrdata");
    p.with_file_name(name)
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct Signatures {
    pub catalog: DbStamp,
    pub preview: Option<DbStamp>,
}
pub(super) fn signatures(p: &Path) -> Result<Signatures> {
    let preview = cache_dir(p).join("previews.db");
    Ok(Signatures {
        catalog: db_stamp(p)?,
        preview: if fs::symlink_metadata(&preview).is_ok() {
            Some(db_stamp(&preview)?)
        } else {
            None
        },
    })
}
pub(super) struct Snapshot {
    _temp: TempDir,
    pub path: PathBuf,
    pub db: Connection,
}
pub(super) fn open_readonly(p: &Path) -> Result<Connection> {
    let db = Connection::open_with_flags(
        p,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.execute_batch("PRAGMA trusted_schema=OFF;PRAGMA query_only=ON;")?;
    Ok(db)
}
fn private_copy(source: &Path, dest: &Path) -> Result<()> {
    fs::copy(source, dest)?;
    // std::fs::copy preserves file permissions. SQLite recovers journals on our private
    // files, including when a backup or read-only disk supplied a 0444 catalog.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dest, fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(not(unix))]
    {
        let mut p = fs::metadata(dest)?.permissions();
        p.set_readonly(false);
        fs::set_permissions(dest, p)?;
    }
    Ok(())
}
pub(super) fn snapshot(p: &Path, expected: &DbStamp) -> Result<Snapshot> {
    if expected.main.is_none() {
        return Err("Source database is missing".into());
    }
    let temp = tempfile::tempdir()?;
    let raw = temp.path().join("input.sqlite");
    private_copy(p, &raw)?;
    if expected.wal.is_some() {
        private_copy(&sibling(p, "-wal"), &sibling(&raw, "-wal"))?;
    }
    if expected.journal.as_ref().is_some_and(|s| s.size > 0) {
        use std::io::{Read, Seek, SeekFrom};
        let journal = sibling(p, "-journal");
        let dest = sibling(&raw, "-journal");
        private_copy(&journal, &dest)?;
        let mut f = std::fs::File::open(&dest)?;
        let n = f.metadata()?.len();
        if n >= 16 {
            f.seek(SeekFrom::End(-16))?;
            let mut tail = [0u8; 16];
            f.read_exact(&mut tail)?;
            // A super-journal names databases outside our private copy. Recover an ordinary
            // single-database journal privately, and require a closed copy for the former.
            let magic = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7];
            let size = u32::from_be_bytes(tail[..4].try_into()?) as u64;
            if tail[8..] == magic && size > 0 && size <= n - 16 {
                return Err(
                    "Close the Lightroom multi-database transaction before migration".into(),
                );
            }
        }
    }
    if &db_stamp(p)? != expected {
        return Err("The source changed during capture; retry after Lightroom closes".into());
    }
    // SQLite can rebuild SHM and replay WAL in our private copy. No SQLite handle opens the user's file.
    let copy = Connection::open_with_flags(&raw, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    copy.execute_batch("PRAGMA trusted_schema=OFF;PRAGMA query_only=ON;")?;
    let path = temp.path().join("snapshot.sqlite");
    let mut output = Connection::open(&path)?;
    Backup::new(&copy, &mut output)?.run_to_completion(256, Duration::from_millis(1), None)?;
    output.execute_batch("PRAGMA journal_mode=DELETE;")?;
    drop(output);
    drop(copy);
    let db = open_readonly(&path)?;
    let healthy: String = db.query_row("PRAGMA quick_check(1)", [], |r| r.get(0))?;
    if healthy != "ok" {
        return Err("Source snapshot failed SQLite quick_check".into());
    }
    Ok(Snapshot {
        _temp: temp,
        path,
        db,
    })
}
pub(super) fn exists(db: &Connection, t: &str) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1)",
        [t],
        |r| r.get(0),
    )?)
}
fn ident(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}
pub(super) fn columns(db: &Connection, t: &str) -> Result<Vec<String>> {
    if !ident(t) {
        return Err("Unknown source table".into());
    }
    let mut q = db.prepare(&format!("PRAGMA table_info({t})"))?;
    let v = q
        .query_map([], |r| r.get(1))?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}
pub(super) fn value(r: &rusqlite::Row<'_>, i: usize) -> rusqlite::Result<Value> {
    let v = match r.get_ref(i)? {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(v) => json!(v),
        ValueRef::Real(v) => json!(v),
        ValueRef::Text(v) => json!(String::from_utf8_lossy(v)),
        ValueRef::Blob(v) => json!({"bytes":v.len(),"sha256":hex::encode(Sha256::digest(v))}),
    };
    Ok(v)
}
pub(super) fn record(db: &Connection, t: &str, id: i64) -> Result<Option<Value>> {
    if !ident(t) {
        return Err("Unknown source table".into());
    }
    let mut q = db.prepare_cached(&format!("SELECT * FROM {t} WHERE id_local=?1"))?;
    let names = q
        .column_names()
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();
    Ok(q.query_row([id], |r| {
        let mut data = serde_json::Map::new();
        for (i, name) in names.iter().enumerate() {
            data.insert(name.clone(), value(r, i)?);
        }
        Ok(Value::Object(data))
    })
    .optional()?)
}
pub(super) fn related(db: &Connection, t: &str, field: &str, id: i64) -> Result<Option<Value>> {
    if !exists(db, t)? {
        return Ok(None);
    }
    if !ident(t) || !ident(field) {
        return Err("Unknown source relation".into());
    }
    let key: Option<i64> = db
        .query_row(
            &format!("SELECT id_local FROM {t} WHERE {field}=?1 ORDER BY id_local LIMIT 1"),
            [id],
            |r| r.get(0),
        )
        .optional()?;
    match key {
        Some(k) => record(db, t, k),
        None => Ok(None),
    }
}
pub(super) fn count(db: &Connection, t: &str) -> Result<Option<i64>> {
    if !exists(db, t)? {
        return Ok(None);
    }
    if !ident(t) {
        return Err("Unknown source table".into());
    }
    Ok(Some(db.query_row(
        &format!("SELECT count(*) FROM {t}"),
        [],
        |r| r.get(0),
    )?))
}
pub(super) fn version(db: &Connection) -> Result<String> {
    for (t, fields) in [
        ("Adobe_images", &["id_local", "rootFile", "masterImage"][..]),
        (
            "AgLibraryFile",
            &["id_local", "baseName", "extension", "folder"],
        ),
        (
            "AgLibraryFolder",
            &["id_local", "rootFolder", "pathFromRoot"],
        ),
        ("AgLibraryRootFolder", &["id_local", "absolutePath"]),
        ("Adobe_variablesTable", &["name", "value"]),
    ] {
        let cols = columns(db, t)?;
        if fields.iter().any(|f| !cols.iter().any(|c| c == f)) {
            return Err(format!("Unsupported Lightroom layout in {t}").into());
        }
    }
    let ver: String = db.query_row(
        "SELECT CAST(value AS TEXT) FROM Adobe_variablesTable WHERE name='Adobe_DBVersion' LIMIT 1",
        [],
        |r| r.get(0),
    )?;
    if !matches!(ver.as_str(), "1200001" | "1300000" | "1400000" | "1504001") {
        return Err(format!("Unverified Lightroom catalog version {ver}").into());
    }
    Ok(ver)
}
pub(super) fn anchor(db: &Connection) -> Result<Value> {
    let key:Option<String>=db.query_row("SELECT CAST(value AS TEXT) FROM Adobe_variablesTable WHERE name='Adobe_lrMobileCatalogId' AND length(value)>0 LIMIT 1",[],|r|r.get(0)).optional()?;
    let mut anchors = Vec::new();
    for t in ["AgLibraryRootFolder", "AgLibraryFile", "Adobe_images"] {
        if !columns(db, t)?.iter().any(|c| c == "id_global") {
            continue;
        }
        let mut s=db.prepare(&format!("SELECT id_local,CAST(id_global AS TEXT) FROM {t} WHERE length(id_global)>0 ORDER BY id_local LIMIT 8"))?;
        for row in s.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
            let (local, global) = row?;
            anchors.push(json!([t, local, global]));
        }
    }
    Ok(json!({"mobile":key,"samples":anchors}))
}
pub(super) fn compatible(a: &Value, b: &Value) -> bool {
    if a["mobile"].is_string() && b["mobile"].is_string() && a["mobile"] != b["mobile"] {
        return false;
    }
    let samples = a["samples"].as_array().into_iter().flatten();
    samples.clone().any(|s| {
        b["samples"]
            .as_array()
            .is_some_and(|v| v.iter().any(|t| t[0] == s[0] && t[2] == s[2]))
    }) || (a["samples"] == json!([])
        && b["samples"] == json!([])
        && a["mobile"].is_string()
        && a["mobile"] == b["mobile"])
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Dependency {
    pub name: String,
    pub stamp: Option<Stamp>,
    pub state: String,
}
pub(super) fn dependencies(source: &Path) -> Result<Vec<Dependency>> {
    let root = source.with_extension("lrcat-data");
    let mut out = Vec::new();
    fn visit(base: &Path, p: &Path, out: &mut Vec<Dependency>) -> Result<()> {
        let name = p
            .strip_prefix(base)?
            .to_str()
            .ok_or("Non-UTF8 companion path")?
            .to_owned();
        let m = fs::symlink_metadata(p)?;
        if m.is_file() {
            out.push(Dependency {
                name,
                stamp: Some(stamp(m)?),
                state: "present".into(),
            });
        } else if m.is_dir() {
            let mut entries =
                match fs::read_dir(p).and_then(|it| it.collect::<std::io::Result<Vec<_>>>()) {
                    Ok(files) => files,
                    Err(_) => {
                        out.push(Dependency {
                            name,
                            stamp: None,
                            state: "unreadableDirectory".into(),
                        });
                        return Ok(());
                    }
                };
            entries.sort_by_key(|e| e.file_name());
            if entries.is_empty() {
                out.push(Dependency {
                    name,
                    stamp: None,
                    state: "emptyDirectory".into(),
                });
            }
            for child in entries {
                visit(base, &child.path(), out)?;
            }
        } else {
            out.push(Dependency {
                name,
                stamp: None,
                state: "unsupportedType".into(),
            });
        }
        Ok(())
    }
    if let Err(e) = fs::symlink_metadata(&root) {
        out.push(Dependency {
            name: root
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned(),
            stamp: None,
            state: if e.kind() == std::io::ErrorKind::NotFound {
                "missing"
            } else {
                "unreadable"
            }
            .into(),
        });
    } else {
        visit(
            source.parent().ok_or("Missing catalog parent")?,
            &root,
            &mut out,
        )?;
    }
    Ok(out)
}
pub(super) fn verified_resource(catalog: &Path, db: &Connection, id: &str) -> Result<PathBuf> {
    let (path, hash, n): (String, String, i64) = db.query_row(
        "SELECT relative_path,sha256,byte_count FROM lc_resources WHERE resource_id=?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    if Path::new(&path) != resources::object_path(&hash)? {
        return Err("Invalid snapshot resource location".into());
    }
    let p = catalog
        .parent()
        .ok_or("Missing catalog root")?
        .join("LibraryResources")
        .join(path);
    use std::{
        collections::BTreeMap,
        io::Read,
        sync::{Mutex, OnceLock},
    };
    static CHECKED: OnceLock<Mutex<BTreeMap<(PathBuf, String), Stamp>>> = OnceLock::new();
    let sig = file_stamp(&p)?.ok_or("Snapshot resource no longer exists")?;
    if sig.size != u64::try_from(n)? {
        return Err("Snapshot resource length changed".into());
    }
    let key = (p.clone(), hash.clone());
    let cache = CHECKED.get_or_init(Mutex::default);
    if cache
        .lock()
        .map_err(|_| "Resource validation unavailable")?
        .get(&key)
        != Some(&sig)
    {
        let mut f = std::fs::File::open(&p)?;
        let mut digest = Sha256::new();
        let mut buf = vec![0; 512 * 1024];
        loop {
            let n = f.read(&mut buf)?;
            if n == 0 {
                break;
            }
            digest.update(&buf[..n]);
        }
        if hex::encode(digest.finalize()) != hash || file_stamp(&p)?.as_ref() != Some(&sig) {
            return Err("Archived resource checksum changed".into());
        }
        let mut guard = cache
            .lock()
            .map_err(|_| "Resource validation unavailable")?;
        if guard.len() > 4096 {
            guard.clear();
        }
        guard.insert(key, sig);
    }
    Ok(p)
}
pub(super) fn content(catalog: &Path, path: &Path, kind: &str) -> Result<Resource> {
    let mut r = resources::stage(catalog, path, "pending", kind, None)?;
    r.resource_id = format!("lr:{kind}:{}", r.sha256);
    Ok(r)
}
pub(super) fn bytes(catalog: &Path, data: &[u8], kind: &str) -> Result<Resource> {
    use std::io::Write;
    let mut tmp = tempfile::NamedTempFile::new()?;
    tmp.write_all(data)?;
    tmp.flush()?;
    content(catalog, tmp.path(), kind)
}
