use crate::Result;
use rusqlite::{ffi, Connection};
use serde_json::{json, Value};
use std::{
    cell::RefCell,
    env,
    fs::File,
    io::{self, Read, Seek, SeekFrom},
    os::fd::AsRawFd,
    time::Instant,
};
#[repr(C)]
#[derive(Clone, Copy, Default, Eq, PartialEq)]
struct Page {
    opening: u64,
    mapping: u64,
    addr: u64,
    bytes: u64,
}
extern "C" {
    fn rm_page_for(db: *mut ffi::sqlite3, out: *mut Page) -> i32;
    fn rm_query_address(fd: i32, page: *const Page, device: u64, inode: u64) -> i32;
}
#[derive(Default)]
struct Run {
    mode: String,
    maps: Option<File>,
    previous: Option<(Page, u64, u64)>,
    events: Vec<Value>,
    writer: Option<Instant>,
    hold: Option<u64>,
    scans: u32,
    queries: u32,
    lines: u64,
    bytes: u64,
}
thread_local! {static RUN:RefCell<Run>=RefCell::new(Run::default());}
pub struct Session;
impl Session {
    pub fn begin() -> Result<Self> {
        let mode = env::var("RM_MAP_ARM").unwrap_or_else(|_| "auto".into());
        if !["scan", "address", "cached", "auto"].contains(&mode.as_str()) {
            return Err("invalid mapping arm".into());
        }
        let state = Run {
            mode,
            maps: Some(File::open("/proc/self/maps")?),
            events: Vec::with_capacity(8),
            ..Default::default()
        };
        RUN.with(|r| *r.borrow_mut() = state);
        Ok(Self)
    }
    pub fn writer_started(&self) {
        RUN.with(|r| r.borrow_mut().writer = Some(Instant::now()));
    }
    pub fn writer_ended(&self) {
        RUN.with(|r| {
            let mut r = r.borrow_mut();
            r.hold = r.writer.map(|s| s.elapsed().as_nanos() as u64);
        });
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        RUN.with(|r| {
            let mut run = std::mem::take(&mut *r.borrow_mut());
            let hold = run
                .hold
                .or_else(|| run.writer.map(|s| s.elapsed().as_nanos() as u64));
            for mut v in run.events.drain(..) {
                v["holdNs"] = json!(hold);
                eprintln!("{v}");
            }
        });
    }
}
fn scan(file: &mut File, page: &Page, s: &libc::stat) -> Result<(bool, u64, u64)> {
    file.seek(SeekFrom::Start(0))?;
    let mut maps = String::new();
    file.read_to_string(&mut maps)?;
    let (ma, mi) = (libc::major(s.st_dev), libc::minor(s.st_dev));
    let mut count = 0;
    let mut found = false;
    for line in maps.lines() {
        count += 1;
        let mut f = line.split_whitespace();
        let range = f.next().unwrap_or("");
        let perms = f.next().unwrap_or("");
        let off = f.next().unwrap_or("");
        let dev = f.next().unwrap_or("");
        let inode = f.next().unwrap_or("");
        let Some((lo, hi)) = range.split_once('-').and_then(|(a, b)| {
            Some((
                u64::from_str_radix(a, 16).ok()?,
                u64::from_str_radix(b, 16).ok()?,
            ))
        }) else {
            continue;
        };
        if lo != page.addr || hi.saturating_sub(lo) < page.bytes {
            continue;
        }
        let observed = dev.split_once(':').and_then(|(a, b)| {
            Some((
                u32::from_str_radix(a, 16).ok()?,
                u32::from_str_radix(b, 16).ok()?,
            ))
        });
        found = perms.starts_with('r')
            && perms.ends_with('s')
            && u64::from_str_radix(off, 16) == Ok(0)
            && observed == Some((ma, mi))
            && inode.parse::<u64>() == Ok(s.st_ino as u64);
    }
    Ok((found, count, maps.len() as u64))
}
pub fn mapped(db: &Connection, s: &libc::stat, phase: &str) -> Result<usize> {
    let mut page = Page::default();
    if unsafe { rm_page_for(db.handle(), &mut page) } != ffi::SQLITE_OK
        || page.opening == 0
        || page.mapping == 0
        || page.addr == 0
        || page.bytes != 32768
    {
        return Err("missing native page-zero mapping".into());
    }
    RUN.with(|state| -> Result<usize> {
        let mut run = state.borrow_mut();
        let read = phase == "read";
        let token = (page, s.st_dev as u64, s.st_ino as u64);
        if !read && run.previous != Some(token) {
            return Ok(0);
        }
        let mut do_scan = run.mode == "scan" || (run.mode == "cached" && read);
        let mut matched = true;
        if run.mode == "address" || run.mode == "auto" {
            run.queries += 1;
            let fd = run.maps.as_ref().unwrap().as_raw_fd();
            let code = if env::var_os("RM_MAP_FORCE_UNSUPPORTED").is_some() {
                -libc::ENOTTY
            } else {
                unsafe { rm_query_address(fd, &page, s.st_dev as u64, s.st_ino as u64) }
            };
            if code < 0
                && read
                && run.mode == "auto"
                && [-libc::ENOTTY, -libc::ENOSYS].contains(&code)
            {
                run.mode = "cached".into();
                do_scan = true;
            } else if code < 0 {
                return Err(io::Error::from_raw_os_error(-code).into());
            } else {
                matched = code == 1;
                if read && run.mode == "auto" {
                    run.mode = "address".into();
                }
            }
        }
        if do_scan {
            let (ok, lines, bytes) = scan(run.maps.as_mut().unwrap(), &page, s)?;
            matched = ok;
            run.scans += 1;
            run.lines += lines;
            run.bytes += bytes;
        }
        if matched && read {
            run.previous = Some(token);
        }
        Ok(matched as usize)
    })
}
pub fn record(mut v: Value, started: Instant) {
    let elapsed = started.elapsed().as_nanos() as u64;
    RUN.with(|s| {
        let mut s = s.borrow_mut();
        v["guardNs"] = json!(elapsed);
        v["mode"] = json!(s.mode);
        v["mapScans"] = json!(s.scans);
        v["mapQueries"] = json!(s.queries);
        v["mapBytes"] = json!(s.bytes);
        v["mapLines"] = json!(s.lines);
        v["openingGeneration"] = json!(s.previous.map(|p| p.0.opening));
        v["mappingGeneration"] = json!(s.previous.map(|p| p.0.mapping));
        s.events.push(v);
    });
}
