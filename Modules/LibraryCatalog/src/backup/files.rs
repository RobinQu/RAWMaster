use super::{Blob, Result};
use sha2::{Digest, Sha256};
use std::ffi::{CString, OsStr};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use tempfile::NamedTempFile;

pub(super) fn hexsum(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

pub(crate) fn part(name: &str) -> Result<()> {
    if name.is_empty()
        || matches!(name, "." | "..")
        || name.contains(['/', '\\', '\0'])
        || name.chars().any(char::is_control)
    {
        return Err("invalid single path component".into());
    }
    Ok(())
}

pub(super) fn relative(value: &str) -> Result<()> {
    for name in value.split('/') {
        part(name)?;
    }
    if value.starts_with('/') || value.as_bytes().get(1) == Some(&b':') {
        return Err("expected a relative path".into());
    }
    Ok(())
}

pub(crate) fn absolute(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::Prefix(_)))
    {
        return Err("expected an absolute path without parent traversal".into());
    }
    #[cfg(target_os = "macos")]
    for alias in ["/tmp", "/var"] {
        if let Ok(rest) = path.strip_prefix(alias) {
            return Ok(Path::new("/private").join(&alias[1..]).join(rest));
        }
    }
    Ok(path.to_owned())
}

fn cstr(s: &OsStr) -> Result<CString> {
    Ok(CString::new(s.as_bytes())?)
}

fn open_at(dir: &File, name: &OsStr, flags: i32) -> io::Result<File> {
    let name =
        CString::new(name.as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            0o600,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

pub(crate) fn directory(path: &Path, create: bool) -> Result<File> {
    let mut current = File::open("/")?;
    for component in absolute(path)?.components() {
        let Component::Normal(name) = component else {
            continue;
        };
        let flags = libc::O_RDONLY | libc::O_DIRECTORY;
        let next = match open_at(&current, name, flags) {
            Ok(next) => next,
            Err(e) if create && e.kind() == io::ErrorKind::NotFound => {
                let name_c = cstr(name)?;
                if unsafe { libc::mkdirat(current.as_raw_fd(), name_c.as_ptr(), 0o700) } != 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::AlreadyExists {
                        return Err(error.into());
                    }
                }
                current.sync_all()?;
                open_at(&current, name, flags)?
            }
            Err(e) => return Err(e.into()),
        };
        current = next;
    }
    Ok(current)
}

pub(crate) fn parent(path: &Path) -> Result<&Path> {
    path.parent()
        .ok_or_else(|| "missing parent directory".into())
}

pub(crate) fn regular(path: &Path) -> Result<File> {
    let dir = directory(parent(path)?, false)?;
    let name = path.file_name().ok_or("missing filename")?;
    let file = open_at(&dir, name, libc::O_RDONLY | libc::O_NONBLOCK)?;
    if !file.metadata()?.is_file() {
        return Err("not a regular file".into());
    }
    Ok(file)
}

pub(crate) fn exists(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(md) if md.file_type().is_symlink() => {
            Err("symbolic links cannot be package entries".into())
        }
        Ok(_) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.into()),
    }
}

pub(super) fn spool(reader: &mut dyn Read, writer: &mut dyn Write) -> Result<Blob> {
    let mut hash = Sha256::new();
    let mut bytes = 0u64;
    let mut buf = vec![0; 256 * 1024];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
        writer.write_all(&buf[..n])?;
        bytes = bytes.checked_add(n as u64).ok_or("file too large")?;
    }
    Ok(Blob {
        sha256: hex::encode(hash.finalize()),
        bytes,
    })
}

pub(crate) fn digest(path: &Path) -> Result<Blob> {
    spool(&mut regular(path)?, &mut io::sink())
}

pub(crate) fn check(path: &Path, expected: &Blob) -> Result<()> {
    let mut f = regular(path)?;
    if f.metadata()?.len() != expected.bytes || spool(&mut f, &mut io::sink())? != *expected {
        return Err("file length or SHA-256 mismatch".into());
    }
    Ok(())
}

pub(super) fn read_bytes(path: &Path) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    regular(path)?.read_to_end(&mut buf)?;
    Ok(buf)
}

pub(super) fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = directory(parent(path)?, true)?;
    let mut t = NamedTempFile::new_in(parent(path)?)?;
    t.write_all(bytes)?;
    t.as_file().sync_all()?;
    t.persist_noclobber(path)?;
    dir.sync_all()?;
    Ok(())
}

pub(crate) fn verified_copy(
    reader: &mut dyn Read,
    destination: &Path,
    expected: &Blob,
) -> Result<()> {
    let dir = directory(parent(destination)?, true)?;
    let mut t = NamedTempFile::new_in(parent(destination)?)?;
    if spool(reader, &mut t)? != *expected {
        return Err("source length or SHA-256 mismatch".into());
    }
    t.as_file().sync_all()?;
    t.persist_noclobber(destination)?;
    dir.sync_all()?;
    Ok(())
}

// Call only for entries in our locked 0700 stage, never on the live library or published package.
pub(super) fn keep_verified(path: &Path, spec: &Blob) -> Result<bool> {
    if !exists(path)? {
        return Ok(false);
    }
    let file = regular(path)?;
    if file.metadata()?.len() == spec.bytes && check(path, spec).is_ok() {
        return Ok(true);
    }
    fs::remove_file(path)?;
    directory(parent(path)?, false)?.sync_all()?;
    Ok(false)
}

pub(super) fn link_or_copy(source: &Path, target: &Path, spec: &Blob) -> Result<()> {
    if keep_verified(target, spec)? {
        return Ok(());
    }
    let dir = directory(parent(target)?, true)?;
    let mut file = regular(source)?;
    if file.metadata()?.len() != spec.bytes || spool(&mut file, &mut io::sink())? != *spec {
        return Err("source object failed verification".into());
    }
    if fs::hard_link(source, target).is_err() {
        file.seek(SeekFrom::Start(0))?;
        verified_copy(&mut file, target, spec)?;
    }
    check(target, spec)?;
    dir.sync_all()?;
    Ok(())
}

pub(super) fn private_stage(destination: &Path, action: &str) -> Result<(PathBuf, File)> {
    let owner = directory(parent(destination)?, false)?;
    let name = destination.file_name().ok_or("missing destination name")?;
    let label = format!(
        ".rawmaster-{action}-{}.partial",
        &hexsum(name.as_bytes())[..24]
    );
    let name_c = CString::new(label.as_str())?;
    if unsafe { libc::mkdirat(owner.as_raw_fd(), name_c.as_ptr(), 0o700) } != 0 {
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::AlreadyExists {
            return Err(e.into());
        }
    } else {
        owner.sync_all()?;
    }
    let stage = parent(destination)?.join(label);
    let lock = directory(&stage, false)?;
    let md = lock.metadata()?;
    if md.uid() != unsafe { libc::geteuid() } || md.mode() & 0o077 != 0 {
        return Err("stage must be private to its owner".into());
    }
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("another package operation owns the stage".into());
    }
    Ok((stage, lock))
}

// tempfile::NamedTempFile uses .tmp + six random ASCII characters. A killed writer can
// leave its private temporary file or SQLite journal. Never clean user source directories.
pub(super) fn discard_abandoned_temps(stage: &Path) -> Result<()> {
    let mut queue = vec![stage.to_path_buf()];
    while let Some(dir) = queue.pop() {
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                return Err("symbolic link inside private stage".into());
            }
            if kind.is_dir() {
                queue.push(entry.path());
                continue;
            }
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            let name = name
                .strip_suffix("-journal")
                .or_else(|| name.strip_suffix("-wal"))
                .or_else(|| name.strip_suffix("-shm"))
                .unwrap_or(name);
            if kind.is_file()
                && name
                    .strip_prefix(".tmp")
                    .is_some_and(|s| s.len() == 6 && s.bytes().all(|b| b.is_ascii_alphanumeric()))
            {
                fs::remove_file(entry.path())?;
                directory(&dir, false)?.sync_all()?;
            }
        }
    }
    Ok(())
}

pub(crate) fn publish(source: &Path, destination: &Path) -> Result<()> {
    let from = directory(parent(source)?, false)?;
    let to = directory(parent(destination)?, false)?;
    let a = cstr(source.file_name().ok_or("missing source name")?)?;
    let b = cstr(destination.file_name().ok_or("missing destination name")?)?;
    #[cfg(target_vendor = "apple")]
    let rc = unsafe {
        libc::renameatx_np(
            from.as_raw_fd(),
            a.as_ptr(),
            to.as_raw_fd(),
            b.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    #[cfg(target_os = "linux")]
    let rc = unsafe {
        libc::renameat2(
            from.as_raw_fd(),
            a.as_ptr(),
            to.as_raw_fd(),
            b.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
    let rc = {
        return Err("exclusive directory publication is unsupported on this platform".into());
    };
    if rc != 0 {
        return Err(io::Error::last_os_error().into());
    }
    to.sync_all()?;
    Ok(())
}
