//! Scratch worker only. Inherited O_PATH handles are generated-fixture grants.
use crate::Result;
use rusqlite::{ffi, Connection};
use serde_json::{json, Value};
use std::{
    env,
    ffi::{CStr, CString},
    io,
    mem::MaybeUninit,
};

fn fstat(fd: i32) -> Result<libc::stat> {
    let mut s = MaybeUninit::uninit();
    if fd < 0 || unsafe { libc::fstat(fd, s.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(unsafe { s.assume_init() })
}
fn named(dir: i32, name: &CStr) -> Result<libc::stat> {
    let mut s = MaybeUninit::uninit();
    if unsafe {
        libc::fstatat(
            dir,
            name.as_ptr(),
            s.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(io::Error::last_os_error().into());
    }
    Ok(unsafe { s.assume_init() })
}
fn ident(s: &libc::stat) -> [u64; 2] {
    [s.st_dev as u64, s.st_ino as u64]
}
fn mappings(s: &libc::stat) -> Result<usize> {
    let major = libc::major(s.st_dev);
    let minor = libc::minor(s.st_dev);
    let src = std::fs::read_to_string("/proc/self/maps")?;
    Ok(src
        .lines()
        .filter(|line| {
            let mut fields = line.split_whitespace();
            let range = fields.next().unwrap_or("");
            let perm = fields.next().unwrap_or("");
            let offset = fields.next().unwrap_or("");
            let device = fields.next().unwrap_or("");
            let inode = fields.next().unwrap_or("");
            let extent = range.split_once('-').and_then(|(a, b)| {
                Some(
                    usize::from_str_radix(b, 16)
                        .ok()?
                        .checked_sub(usize::from_str_radix(a, 16).ok()?)?,
                )
            });
            let dev = device.split_once(':').and_then(|(a, b)| {
                Some((
                    u32::from_str_radix(a, 16).ok()?,
                    u32::from_str_radix(b, 16).ok()?,
                ))
            });
            extent.is_some_and(|n| n >= 32768)
                && perm.starts_with('r')
                && perm.ends_with('s')
                && u64::from_str_radix(offset, 16) == Ok(0)
                && dev == Some((major, minor))
                && inode.parse::<u64>() == Ok(s.st_ino as u64)
        })
        .count())
}
pub(super) fn check(db: &Connection, phase: &str, wanted: i32) -> Result<()> {
    let spec = env::var_os("RM_PRIVATE_FIXTURE_GRANTS").ok_or("missing private fixture grants")?;
    let grants = spec
        .to_str()
        .ok_or("invalid grants")?
        .split(',')
        .map(str::parse::<i32>)
        .collect::<std::result::Result<Vec<_>, _>>()?;
    if grants.len() != 4 {
        return Err("expected directory, main, WAL, SHM fixture grants".into());
    }
    let state = unsafe { ffi::sqlite3_txn_state(db.handle(), c"main".as_ptr()) };
    let mode: String = db.pragma_query_value(Some("main"), "journal_mode", |r| r.get(0))?;
    let report: String = db.query_row("SELECT sqlite_filestat('main')", [], |r| r.get(0))?;
    let diagnostics: Value = serde_json::from_str(&report)?;
    let n = |key: &str| -> Result<i64> {
        diagnostics
            .pointer(key)
            .and_then(|v| v.as_i64())
            .ok_or_else(|| format!("absent FILESTAT {key}").into())
    };
    let raw = [n("/db/h")?, n("/journal/h")?, n("/db/shm/h")?];
    let shared = n("/db/shm/sharedMask")?;
    let exclusive = n("/db/shm/exclMask")?;
    let mut attached = vec![];
    let mut trusted = vec![];
    let mut names = vec![];
    let mut sizes = vec![];
    let mut shm_maps = 0;
    let substitute = env::var("RM_PRIVATE_WRONG_GRANT").ok();
    for (i, (fd, role)) in raw.iter().zip(["main", "wal", "shm"]).enumerate() {
        let live = fstat(i32::try_from(*fd)?)?;
        let mut expected_fd = grants[i + 1];
        if let Some(choice) = substitute.as_deref() {
            let mut s = choice.split(':');
            let at = s.next().unwrap_or("");
            let which = s.next().unwrap_or("");
            let other = s.next().unwrap_or("");
            if at == phase && which == role {
                expected_fd = other.parse()?;
            }
        }
        let expected = fstat(expected_fd)?;
        let name = CString::new(match role {
            "main" => "library.sqlite",
            "wal" => "library.sqlite-wal",
            _ => "library.sqlite-shm",
        })?;
        let current = named(grants[0], &name)?;
        if [live.st_mode, expected.st_mode, current.st_mode]
            .into_iter()
            .any(|m| m & libc::S_IFMT != libc::S_IFREG)
        {
            return Err("nonregular attachment".into());
        }
        attached.push(ident(&live));
        trusted.push(ident(&expected));
        names.push(ident(&current));
        sizes.push(live.st_size);
        if role == "shm" {
            shm_maps = mappings(&live)?;
        }
    }
    let allowed = state == wanted
        && !db.is_autocommit()
        && mode == "wal"
        && diagnostics.pointer("/db/vfs") == Some(&json!("unix"))
        && diagnostics.pointer("/journal/vfs") == Some(&json!("unix"))
        && shared & 0xf8 != 0
        && (wanted != 2 || exclusive & 1 != 0)
        && shm_maps == 1
        && attached == trusted
        && attached == names;
    eprintln!(
        "{}",
        json!({"phase":phase,"state":state,"walBytes":sizes[1],"attached":attached,"grants":trusted,"names":names,"shmMappings":shm_maps,"readMask":shared,"exclusiveMask":exclusive,"allowed":allowed})
    );
    if allowed {
        Ok(())
    } else {
        Err("fixture active attachment proof failed".into())
    }
}
