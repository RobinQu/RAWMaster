use rusqlite::{Connection, OpenFlags};
use std::ffi::{c_char, CStr};
use std::panic::catch_unwind;

/// Count admitted rows with at least the requested rating in a private projection.
///
/// # Safety
/// The caller must supply a valid nul-terminated path for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn rm_probe_count_v1(path: *const c_char, minimum_rating: i32) -> i64 {
    if path.is_null() || !(0..=5).contains(&minimum_rating) {
        return -1;
    }
    catch_unwind(|| {
        let Ok(filename) = unsafe { CStr::from_ptr(path) }.to_str() else {
            return -1;
        };
        let Ok(db) = Connection::open_with_flags(filename, OpenFlags::SQLITE_OPEN_READ_ONLY) else {
            return -2;
        };
        db.query_row(
            "SELECT COUNT(*) FROM photo WHERE rating >= ?1",
            [minimum_rating],
            |row| row.get::<_, i64>(0),
        )
        .unwrap_or(-3)
    })
    .unwrap_or(-4)
}
