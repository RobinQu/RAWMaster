use rawmaster_library::Result;
use rusqlite::{ffi, Connection, OpenFlags};
use serde_json::{json, Value};
use std::{env, ffi::CString, io::{self, BufRead, Write}, os::fd::AsRawFd};
#[repr(C)]
#[derive(Default)]
struct Page { opening: u64, mapping: u64, addr: u64, bytes: u64 }
extern "C" {
    fn rm_install_mapping_vfs() -> i32;
    fn rm_page_for(db: *mut ffi::sqlite3, page: *mut Page) -> i32;
    fn rm_query_address(fd: i32, page: *const Page, dev: u64, ino: u64) -> i32;
    fn rm_private_attest(descriptors: *const i32) -> i32;
}
fn send(value: Value) -> Result<()> { println!("{value}"); io::stdout().flush()?; Ok(()) }
fn main() -> Result<()> {
    let path=env::args().nth(1).ok_or("missing generated path")?;
    let scope=CString::new(path.clone())?;
    let opened=unsafe {rawmaster_library::rm_fixture_scope_begin(env::var("RM_OWNER_FD")?.parse()?,
        env::var("RM_OWNER_NONCE")?.parse()?,scope.as_ptr(),env::var("RM_OWNER_PID")?.parse()?)};
    if opened!=0 || unsafe{rm_install_mapping_vfs()}!=0 { return Err("could not bind private worker".into()); }
    let db=Connection::open_with_flags_and_vfs(&path,OpenFlags::SQLITE_OPEN_READ_WRITE|OpenFlags::SQLITE_OPEN_NOFOLLOW,"rm-frozen-map-v1")?;
    db.execute_batch("PRAGMA wal_autocheckpoint=0; BEGIN IMMEDIATE")?;
    let report:String=db.query_row("SELECT sqlite_filestat('main')",[],|r|r.get(0))?;
    let data:Value=serde_json::from_str(&report)?;
    let n=|p:&str|data.pointer(p).and_then(Value::as_i64).ok_or("FILESTAT field missing");
    let actual=[n("/db/h")? as i32,n("/journal/h")? as i32,n("/db/shm/h")? as i32];
    let mut page=Page::default();
    let mut stat=std::mem::MaybeUninit::uninit();
    let maps=std::fs::File::open("/proc/self/maps")?;
    let proof=unsafe{
        if rm_page_for(db.handle(),&mut page)!=0 || libc::fstat(actual[2],stat.as_mut_ptr())!=0 {return Err("SHM witness missing".into());}
        let s=stat.assume_init();rm_query_address(maps.as_raw_fd(),&page,s.st_dev,s.st_ino)
    };
    let state=unsafe{ffi::sqlite3_txn_state(db.handle(),c"main".as_ptr())};
    let shared=n("/db/shm/sharedMask")?; let exclusive=n("/db/shm/exclMask")?;
    if state!=2 || db.is_autocommit() || shared&0xf8==0 || exclusive&1==0 || proof!=1 ||
        page.bytes!=32768 || page.mapping==0 || page.opening==0 {return Err("keeper transaction is not attested".into());}
    let library:String=db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'",[],|r|r.get(0))?;
    let writer:String=db.query_row("SELECT value FROM metadata WHERE key='deviceID'",[],|r|r.get(0))?;
    let version:i64=db.pragma_query_value(None,"user_version",|r|r.get(0))?;
    let journal:String=db.pragma_query_value(None,"journal_mode",|r|r.get(0))?;
    if unsafe{rm_private_attest(actual.as_ptr())}!=0{return Err("owner denied keeper descriptors".into());}
    let mut ws=std::mem::MaybeUninit::uninit();
    if unsafe{libc::fstat(actual[1],ws.as_mut_ptr())}!=0{return Err("missing WAL".into());}
    send(json!({"library":library,"writer":writer,"version":version,"journalMode":journal,"txnState":state,
        "readMask":shared,"exclusiveMask":exclusive,"walBytes":unsafe{ws.assume_init()}.st_size,
        "observedSharedMappingBytes":page.bytes,"mappingGeneration":page.mapping,"openGeneration":page.opening}))?;
    for line in io::stdin().lock().lines() {match line?.as_str(){
        "release" => {db.execute_batch("ROLLBACK")?;send(json!({"released":true}))?;}
        "checkpoint" => {let rc:i64=db.query_row("PRAGMA wal_checkpoint(TRUNCATE)",[],|r|r.get(0))?;send(json!({"checkpointRC":rc}))?;}
        "ticket" => {let (state,ticket,reservations):(String,Option<String>,i64)=db.query_row(
          "SELECT json_extract(value,'$.state'),json_extract(value,'$.ticket'),(SELECT count(*) FROM lc_workbench_names) FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'",
          [],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;send(json!({"state":state,"ticket":ticket,"reservations":reservations}))?;}
        "integrity" => {let (qc,foreign):(String,i64)=db.query_row("SELECT (SELECT quick_check FROM pragma_quick_check),(SELECT count(*) FROM pragma_foreign_key_check)",[],|r|Ok((r.get(0)?,r.get(1)?)))?;send(json!({"quickCheck":qc,"foreignKeyViolations":foreign}))?;}
        "finish" => break,
        _ => return Err("unknown private keeper command".into())
    }}
    Ok(())
}
