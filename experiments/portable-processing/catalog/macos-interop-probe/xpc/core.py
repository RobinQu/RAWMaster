"""Build X2's real v10 queue as a static library in the caller's generated directory."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess as sp


def build(out, interop):
    src = out / "core"
    out.mkdir(parents=True, exist_ok=True)
    shutil.copytree(interop / "instrumented-catalog", src, dirs_exist_ok=True)
    manifest = src / "Cargo.toml"
    m = manifest.read_text()
    assert m.count('["cdylib", "rlib"]') == 1
    manifest.write_text(m.replace('["cdylib", "rlib"]', '["staticlib"]'))
    proof = src / "src/scheduler/batch/fixture_proof.rs"
    s = proof.read_text()
    anchor = '    eprintln!("{proof}");'
    assert s.count(anchor) == 1
    s = s.replace(
        anchor,
        "    AA_LOG.with(|log| log.borrow_mut().push(proof.clone()));\n" + anchor,
    )
    proof.write_text(
        s
        + r"""
thread_local! {
    static AA_LOG: std::cell::RefCell<Vec<serde_json::Value>> = const { std::cell::RefCell::new(Vec::new()) };
}
#[no_mangle]
pub extern "C" fn rm_aa_drain_log() -> *mut std::ffi::c_char {
    let value = AA_LOG.with(|v| std::mem::take(&mut *v.borrow_mut()));
    std::ffi::CString::new(serde_json::to_vec(&value).unwrap()).unwrap().into_raw()
}
#[no_mangle]
pub unsafe extern "C" fn rm_aa_release_log(s: *mut std::ffi::c_char) {
    if !s.is_null() { drop(unsafe { std::ffi::CString::from_raw(s) }); }
}
"""
    )
    env = dict(
        os.environ,
        CARGO_TARGET_DIR=str(out / "target"),
        LIBSQLITE3_FLAGS="SQLITE_ENABLE_FILESTAT",
    )
    sp.run(
        [
            "cargo",
            "build",
            "--locked",
            "--offline",
            "--jobs",
            "1",
            "--lib",
            "--manifest-path",
            str(manifest),
        ],
        check=True,
        env=env,
    )
    return out / "target/debug/librawmaster_library.a"


if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--build-dir", type=Path, required=True)
    a.add_argument("--interop-build", type=Path, required=True)
    t = a.parse_args()
    print(build(t.build_dir.resolve(), t.interop_build.resolve()))
