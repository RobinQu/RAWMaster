use rawmaster_library::Result;
use rusqlite::{ffi, Connection};
use serde_json::{json, Value};
use std::{
    env,
    ffi::c_int,
    fs,
    io::{self, BufRead, Write},
    ptr,
};

// The fixture links this crate's rlib and calls its public C entry points with the same SQLite.
#[repr(C)]
struct LibraryBytes {
    data: *mut u8,
    length: usize,
}
extern "C" {
    fn rm_library_sqlite_identity_v1() -> unsafe extern "C" fn() -> c_int;
    fn rm_library_transaction_v1(
        db: *mut ffi::sqlite3,
        data: *const u8,
        length: usize,
        out: *mut LibraryBytes,
    ) -> c_int;
    fn rm_library_release_v1(out: *mut LibraryBytes);
}
fn migrate(db: &Connection, operation: &str) -> Result<()> {
    let body = serde_json::to_vec(&json!({"operation":operation}))?;
    let mut out = LibraryBytes {
        data: ptr::null_mut(),
        length: 0,
    };
    let status =
        unsafe { rm_library_transaction_v1(db.handle(), body.as_ptr(), body.len(), &mut out) };
    if out.data.is_null() || out.length == 0 {
        return Err("fixture migration response is empty".into());
    }
    unsafe { rm_library_release_v1(&mut out) };
    if status != 0 {
        return Err(format!("fixture migration {operation} returned {status}").into());
    }
    Ok(())
}
fn send(value: Value) -> Result<()> {
    println!("{value}");
    io::stdout().flush()?;
    Ok(())
}
fn main() -> Result<()> {
    let mut args = env::args_os().skip(1);
    let database = args.next().ok_or("missing generated database")?;
    let schema = args.next().ok_or("missing historic schema")?;
    assert!(args.next().is_none() && !std::path::Path::new(&database).exists());
    assert_eq!(rawmaster_library::CATALOG_SCHEMA_VERSION, 10);
    assert!(std::ptr::fn_addr_eq(
        unsafe { rm_library_sqlite_identity_v1() },
        ffi::sqlite3_libversion_number as unsafe extern "C" fn() -> c_int
    ));
    let db = Connection::open(database)?;
    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE")?;
    db.execute_batch(&fs::read_to_string(schema)?)?;
    migrate(&db, "install")?;
    db.execute_batch("PRAGMA user_version=8; COMMIT; BEGIN IMMEDIATE")?;
    migrate(&db, "upgradeScheduler")?;
    db.execute_batch(
        "COMMIT; INSERT INTO metadata(key,value) VALUES('deviceID','controlled-fixture-writer')",
    )?;
    let library: String =
        db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
            r.get(0)
        })?;
    let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    let source: String = db.query_row("SELECT sqlite_source_id()", [], |r| r.get(0))?;
    send(json!({"library":library,"version":version,"sourceID":source}))?;
    for line in io::stdin().lock().lines() {
        match line?.as_str() {
            "finish" => break,
            "truncate" => {
                let result = db.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                })?;
                send(json!({"checkpointRC":result.0,"log":result.1,"done":result.2}))?;
            }
            "ticket" => {
                let sql="SELECT json_extract(value,'$.state'),json_extract(value,'$.ticket'),(SELECT count(*) FROM lc_workbench_names) FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'";
                let (state, description, reservations) = db.query_row(sql, [], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, i64>(2)?,
                    ))
                })?;
                let ticket: Option<Value> = description
                    .as_deref()
                    .map(serde_json::from_str)
                    .transpose()?;
                send(json!({"state":state,"ticket":ticket,"reservations":reservations}))?;
            }
            _ => return Err("unrecognized keeper request".into()),
        }
    }
    Ok(())
}
