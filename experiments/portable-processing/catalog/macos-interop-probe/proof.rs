use crate::Result;
use rusqlite::{ffi, Connection};
use serde_json::{json, Value};
use std::{
    env,
    ffi::{CStr, CString},
    os::fd::RawFd,
};

#[repr(C)]
#[derive(Default)]
struct FileInfo {
    device: u64,
    inode: u64,
    birth_seconds: u64,
    birth_nanos: u64,
    size: u64,
    mode: u32,
    access: u32,
    volume: [u8; 16],
}
impl FileInfo {
    fn local(&self) -> [u64; 4] {
        [
            self.device,
            self.inode,
            self.birth_seconds,
            self.birth_nanos,
        ]
    }
}
extern "C" {
    fn rm_mac_fd(fd: RawFd, info: *mut FileInfo) -> i32;
    fn rm_mac_named(dir: RawFd, name: *const std::ffi::c_char, info: *mut FileInfo) -> i32;
    fn rm_mac_mapping(db: *mut ffi::sqlite3, shm: *const FileInfo, out: *mut u64) -> i32;
    fn rm_mac_sqlite_image() -> *const std::ffi::c_char;
    fn rm_install_mapping_vfs() -> i32;
}
pub fn image() -> String {
    unsafe { CStr::from_ptr(rm_mac_sqlite_image()) }
        .to_string_lossy()
        .into_owned()
}
pub fn install() -> Result<()> {
    if unsafe { rm_install_mapping_vfs() } != ffi::SQLITE_OK {
        return Err("private natural-mapping VFS missing".into());
    }
    Ok(())
}
fn from_fd(fd: i32) -> Result<FileInfo> {
    let mut value = FileInfo::default();
    if unsafe { rm_mac_fd(fd, &mut value) } != 1
        || value.volume == [0; 16]
        || value.volume == [255; 16]
    {
        return Err("expected a live local APFS descriptor".into());
    }
    Ok(value)
}
fn at(fd: i32, name: &str) -> Result<FileInfo> {
    let mut value = FileInfo::default();
    let name = CString::new(name)?;
    if unsafe { rm_mac_named(fd, name.as_ptr(), &mut value) } != 1 {
        return Err("missing authorized directory entry".into());
    }
    Ok(value)
}
fn barrier(phase: &str, event: u8) -> Result<()> {
    if env::var("RM_MAC_PAUSE_PHASE").as_deref() != Ok(phase) {
        return Ok(());
    }
    let b: RawFd = env::var("RM_MAC_BARRIER")?.parse()?;
    // This is exclusively the control socket; it does not refer to a database file.
    let mut ack = [0u8; 1];
    if unsafe { libc::write(b, (&event as *const u8).cast(), 1) } != 1
        || unsafe { libc::read(b, ack.as_mut_ptr().cast(), 1) } != 1
    {
        return Err("private checkpoint disconnected".into());
    }
    if ack != [b'g'] {
        return Err("private checkpoint interrupted".into());
    }
    Ok(())
}
pub fn report(db: &Connection, phase: &str, wanted: i32) -> Result<Value> {
    let state = unsafe { ffi::sqlite3_txn_state(db.handle(), c"main".as_ptr()) };
    let mode: String = db.pragma_query_value(None, "journal_mode", |r| r.get(0))?;
    let encoded: String = db.query_row("SELECT sqlite_filestat('main')", [], |r| r.get(0))?;
    let stat: Value = serde_json::from_str(&encoded)?;
    let number = |field: &str| {
        stat.pointer(field)
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("missing FILESTAT {field}"))
    };
    let raw = [
        number("/db/h")? as i32,
        number("/journal/h")? as i32,
        number("/db/shm/h")? as i32,
    ];
    let shared = number("/db/shm/sharedMask")?;
    let exclusive = number("/db/shm/exclMask")?;
    let grants: Vec<i32> = env::var("RM_MAC_GRANTS")?
        .split(',')
        .map(str::parse)
        .collect::<std::result::Result<_, _>>()?;
    if grants.len() != 4 {
        return Err("require original directory and three APFS objects".into());
    }
    barrier(phase, b'p')?;
    let dir = from_fd(grants[0])?;
    let visible = at(libc::AT_FDCWD, &env::var("RM_MAC_DIRECTORY")?)?;
    let mut allowed = state == wanted
        && !db.is_autocommit()
        && mode == "wal"
        && dir.local() == visible.local()
        && (dir.mode & libc::S_IFMT as u32) == libc::S_IFDIR as u32
        && stat.pointer("/db/vfs") == Some(&json!("unix"))
        && stat.pointer("/journal/vfs") == Some(&json!("unix"))
        && shared & 0xf8 != 0
        && (wanted != 2 || exclusive & 1 != 0);
    let mut rows = vec![];
    let mut mapping = [0u64; 7];
    for (i, name) in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"]
        .into_iter()
        .enumerate()
    {
        let actual = from_fd(raw[i])?;
        let expected = from_fd(grants[i + 1])?;
        let current = at(grants[0], name)?;
        let full = actual.local() == expected.local()
            && actual.local() == current.local()
            && actual.volume == expected.volume
            && actual.volume == dir.volume
            && [actual.mode, expected.mode, current.mode]
                .into_iter()
                .all(|m| m & libc::S_IFMT as u32 == libc::S_IFREG as u32)
            && (wanted != 2 || actual.access == libc::O_RDWR as u32);
        allowed &= full;
        if i == 2 {
            allowed &= unsafe { rm_mac_mapping(db.handle(), &actual, mapping.as_mut_ptr()) } == 1;
        }
        rows.push(json!({"actual":actual.local(),"authorized":expected.local(),"directoryEntry":current.local(),"bytes":actual.size,
            "actualAccess":actual.access,"volumeUUID":uuid::Uuid::from_bytes(actual.volume).to_string(),"matches":full}));
    }
    Ok(
        json!({"phase":phase,"txnState":state,"allowed":allowed,"rows":rows,"sharedMask":shared,"exclusiveMask":exclusive,"mapping":mapping,"sqliteImage":image()}),
    )
}
pub fn check(db: &Connection, phase: &str, wanted: i32) -> Result<()> {
    let proof = report(db, phase, wanted)?;
    eprintln!("{proof}");
    barrier(phase, b'q')?;
    if proof["allowed"] == true {
        Ok(())
    } else {
        Err("unproven APFS attachment".into())
    }
}
