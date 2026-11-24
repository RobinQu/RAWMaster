use rawmaster_library::{mac_probe, Result};
use rusqlite::{ffi, Connection, OpenFlags};
use serde_json::{json, Value};
use std::{
    env,
    ffi::CStr,
    io::{self, BufRead, Read, Write},
    time::Duration,
};
#[repr(C)]
struct Owned {
    data: *mut u8,
    length: usize,
}
extern "C" {
    fn rm_library_request_v1(
        path: *const u8,
        n: usize,
        req: *const u8,
        len: usize,
        out: *mut Owned,
    ) -> i32;
    fn rm_library_sqlite_identity_v1() -> unsafe extern "C" fn() -> i32;
    fn rm_library_release_v1(out: *mut Owned);
}
fn say(v: Value) -> Result<()> {
    println!("{v}");
    io::stdout().flush()?;
    Ok(())
}
fn marker(db: &Connection) -> rusqlite::Result<i64> {
    db.query_row("SELECT coalesce((SELECT CAST(value AS INTEGER) FROM lc_meta WHERE key='fixture.interop.marker'),0)",[],|r|r.get(0))
}
fn main() -> Result<()> {
    assert!(std::ptr::fn_addr_eq(
        unsafe { rm_library_sqlite_identity_v1() },
        ffi::sqlite3_libversion_number as unsafe extern "C" fn() -> i32
    ));
    let source = unsafe { CStr::from_ptr(ffi::sqlite3_sourceid()) }.to_string_lossy();
    let args: Vec<_> = env::args().collect();
    let op = args.get(1).ok_or("missing mode")?;
    let info = json!({"sqliteVersion":unsafe{ffi::sqlite3_libversion_number()},"sourceID":source,"image":mac_probe::image(),"pid":std::process::id(),"sameSQLiteFunction":true});
    if op == "identity" {
        return say(info);
    }
    let path = args.get(2).ok_or("missing test catalog")?;
    if op == "queue" {
        let mut req = Vec::new();
        io::stdin().read_to_end(&mut req)?;
        let mut out = Owned {
            data: std::ptr::null_mut(),
            length: 0,
        };
        let status = unsafe {
            rm_library_request_v1(path.as_ptr(), path.len(), req.as_ptr(), req.len(), &mut out)
        };
        if out.data.is_null() {
            return Err("missing queue response".into());
        }
        let value = serde_json::from_slice::<Value>(unsafe {
            std::slice::from_raw_parts(out.data, out.length)
        });
        unsafe { rm_library_release_v1(&mut out) };
        return say(json!({"status":status,"answer":value?}));
    }
    if op != "peer" {
        return Err("unexpected mode".into());
    }
    mac_probe::install()?;
    let db = Connection::open_with_flags_and_vfs(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        "rm-frozen-map-v1",
    )?;
    db.busy_timeout(Duration::ZERO)?;
    db.execute_batch("PRAGMA wal_autocheckpoint=0; PRAGMA foreign_keys=ON")?;
    say(info)?;
    for l in io::stdin().lock().lines() {
        let op = l?;
        if op == "finish" {
            break;
        }
        if op == "proof" {
            let state = unsafe { ffi::sqlite3_txn_state(db.handle(), c"main".as_ptr()) };
            match mac_probe::report(&db, "peer", state) {
                Ok(v) => say(v)?,
                Err(e) => say(json!({"error":e.to_string()}))?,
            };
            continue;
        }
        let rc=match op.as_str(){
            "read"=>db.execute_batch("BEGIN").and_then(|_|marker(&db).map(|_|())),
            "write"=>db.execute_batch("BEGIN IMMEDIATE").and_then(|_|marker(&db).map(|_|())),
            "bump"=>db.execute_batch("INSERT INTO lc_meta(key,value) VALUES('fixture.interop.marker','1') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1"),
            "commit"=>db.execute_batch("COMMIT"),"rollback"=>db.execute_batch("ROLLBACK"),"marker"=>Ok(()),
            _=>return Err("unknown private action".into())
        };
        let code = rc
            .as_ref()
            .err()
            .and_then(|e| e.sqlite_error())
            .map(|e| e.extended_code)
            .unwrap_or(0);
        let seen = if rc.is_ok() { Some(marker(&db)?) } else { None };
        say(
            json!({"rc":code,"state":unsafe{ffi::sqlite3_txn_state(db.handle(),c"main".as_ptr())},"marker":seen}),
        )?;
    }
    Ok(())
}
