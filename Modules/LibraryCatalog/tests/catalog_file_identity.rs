#![cfg(target_os = "linux")]

use rawmaster_library::{request, Result};
use rusqlite::Connection;
use serde_json::json;
use std::{
    fs::{self, File, Permissions},
    os::{
        fd::AsRawFd,
        unix::fs::{symlink, MetadataExt, PermissionsExt},
    },
    path::Path,
    process::Command,
};

#[test]
fn identity_requires_a_readable_regular_file_at_an_absolute_path() -> Result<()> {
    let root = tempfile::tempdir()?;
    let path = root.path().join("catalog");
    let link = root.path().join("link");
    fs::write(&path, b"catalog metadata fixture")?;
    fs::set_permissions(&path, Permissions::from_mode(0o444))?;
    symlink(&path, &link)?;
    let identity = |p: &Path| request(p, &json!({"operation":"workbenchCatalogFile"}));
    let metadata = path.symlink_metadata()?;
    assert_eq!(
        identity(&path)?,
        json!({"device":metadata.dev(),"inode":metadata.ino()})
    );
    let after = path.symlink_metadata()?;
    assert_eq!(
        (metadata.atime(), metadata.atime_nsec()),
        (after.atime(), after.atime_nsec())
    );
    for rejected in [
        &link,
        root.path(),
        Path::new("relative"),
        &root.path().join("missing"),
    ] {
        assert!(identity(rejected).is_err());
    }
    let replacement = root.path().join("replacement");
    fs::copy(&path, &replacement)?;
    let new_identity = identity(&replacement)?;
    assert_ne!(new_identity["inode"], metadata.ino());
    fs::rename(&replacement, &path)?;
    assert_eq!(identity(&path)?, new_identity);
    fs::set_permissions(&path, Permissions::from_mode(0))?;
    if unsafe { libc::geteuid() } != 0 {
        assert!(identity(&path).is_err());
    }
    Ok(())
}

#[test]
fn catalog_identity_preserves_the_process_sqlite_locks() -> Result<()> {
    const OBSERVE: &str = "RAWMASTER_TEST_OBSERVE_CATALOG_LOCK";
    const RESERVED: &str = "RAWMASTER_TEST_CATALOG_RESERVED_LOCK";
    const OBSERVED: &str = "checked the kernel lock owner";
    if let Some(path) = std::env::var_os(OBSERVE) {
        // F_GETLK only reports conflicts with *other* owners. This process never opens SQLite.
        let file = File::open(path)?;
        let reserved = std::env::var(RESERVED)?.parse::<i16>()?;
        for (byte, range, expected) in [
            (0x4000_0002, 510, libc::F_RDLCK as i16),
            (0x4000_0001, 1, reserved),
        ] {
            let mut lock: libc::flock = unsafe { std::mem::zeroed() };
            lock.l_type = libc::F_WRLCK as _;
            lock.l_whence = libc::SEEK_SET as _;
            lock.l_start = byte;
            lock.l_len = range;
            if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETLK, &mut lock) } == -1 {
                return Err(std::io::Error::last_os_error().into());
            }
            assert_eq!(lock.l_type, expected, "kernel lock type at {byte:#x}");
            if expected != libc::F_UNLCK as i16 {
                assert_eq!(lock.l_pid, unsafe { libc::getppid() });
            }
        }
        println!("{OBSERVED}");
        return Ok(());
    }
    let root = tempfile::tempdir()?;
    let path = root.path().join("library.sqlite");
    let db = Connection::open(&path)?;
    db.execute_batch("CREATE TABLE witness(value); INSERT INTO witness VALUES (17)")?;
    let executable = std::env::current_exe()?;
    for journal in ["WAL", "DELETE"] {
        db.pragma_update(None, "journal_mode", journal)?;
        let active: String = db.pragma_query_value(None, "journal_mode", |r| r.get(0))?;
        assert!(active.eq_ignore_ascii_case(journal));
        for begin in ["BEGIN", "BEGIN IMMEDIATE"] {
            db.execute_batch(begin)?;
            assert_eq!(
                db.query_row("SELECT value FROM witness", [], |r| r.get::<_, i64>(0))?,
                17
            );
            let reserved = if journal == "DELETE" && begin == "BEGIN IMMEDIATE" {
                libc::F_WRLCK
            } else {
                libc::F_UNLCK
            };
            let observe = || -> Result<()> {
                let result = Command::new(&executable)
                    .args([
                        "--exact",
                        "catalog_identity_preserves_the_process_sqlite_locks",
                        "--nocapture",
                    ])
                    .env(OBSERVE, &path)
                    .env(RESERVED, reserved.to_string())
                    .output()?;
                assert!(
                    result.status.success()
                        && String::from_utf8_lossy(&result.stdout).contains(OBSERVED),
                    "{journal} {begin}: {}",
                    String::from_utf8_lossy(&result.stderr)
                );
                Ok(())
            };
            observe()?;
            request(&path, &json!({"operation":"workbenchCatalogFile"}))?;
            observe()?;
            db.execute_batch("ROLLBACK")?;
        }
    }
    Ok(())
}
