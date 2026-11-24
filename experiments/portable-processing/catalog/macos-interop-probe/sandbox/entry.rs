extern "C" {
    fn rm_z_grants(name: *const std::ffi::c_char, fds: *mut i32) -> i32;
    fn rm_z_access_control(fds: *const i32, sibling: *const std::ffi::c_char) -> i32;
}
fn main() -> Result<()> {
    let mut approved = [-1; 4];
    match unsafe { rm_z_grants(c"broker.sock".as_ptr(), approved.as_mut_ptr()) } {
        0 => return say(json!({"receivedCapability":false})),
        1 => {}
        _ => return Err("invalid authority response".into()),
    };
    let args: Vec<_> = env::args().collect();
    if args.get(1).map(String::as_str) == Some("permission") {
        let sibling = std::ffi::CString::new(
            args.get(2)
                .ok_or("missing generated comparison path")?
                .as_str(),
        )?;
        let result = unsafe { rm_z_access_control(approved.as_ptr(), sibling.as_ptr()) };
        return if result == 0 {
            Ok(())
        } else {
            Err("could not read approved database".into())
        };
    }
    let path = args.get(2).ok_or("missing generated database path")?;
    let parent = std::path::Path::new(path)
        .parent()
        .ok_or("missing catalog directory")?;
    env::set_var(
        "RM_MAC_GRANTS",
        approved
            .iter()
            .map(i32::to_string)
            .collect::<Vec<_>>()
            .join(","),
    );
    env::set_var("RM_MAC_DIRECTORY", parent);
    // Signing covers the real X2 Rust ABI and the native SQLite in this same process image.
    original_queue_entry()
}
