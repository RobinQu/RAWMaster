"""Stage the T/U Queue and a private, exact-release SQLite Unix backend. No registry edits."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
REPO = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
MAPPING = (
    REPO / "experiments/portable-processing/catalog/transaction-filestat-probe/mapping"
)


def exact(text, old, new, count=1):
    assert text.count(old) == count, (old, text.count(old))
    return text.replace(old, new)


def build(work):
    work.mkdir(exist_ok=True, parents=True)
    spec = importlib.util.spec_from_file_location(
        "mapping_build", MAPPING / "build_variant.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Reuse both archives' exact source placement. They normally compile twice; defer that until after layering.
    with patch.object(subprocess, "run") as calls:
        module.build(work, "debug")
    assert len(calls.call_args_list) == 2 and all(
        c.args[0][:2] == ["cargo", "build"] for c in calls.call_args_list
    )
    src = work / "instrumented-catalog"
    (original,) = list(
        Path(os.environ.get("CARGO_HOME", "/usr/local/cargo")).glob(
            "registry/src/*/libsqlite3-sys-0.38.2"
        )
    )
    vendor = work / "private-libsqlite3-sys"
    shutil.copytree(original, vendor, dirs_exist_ok=True)
    unit = vendor / "sqlite3/sqlite3.c"
    sql = unit.read_text()
    assert (
        hashlib.sha256(unit.read_bytes()).hexdigest()
        == "0a409f1633283fa31a9126b11fbfd64a1991c5d30defad07e5745d4667f5e23d"
    )
    sql = exact(
        sql,
        "/*\n** Helper functions to obtain and relinquish the global mutex. The\n** global mutex is used to protect the unixInodeInfo objects",
        '#include "owner_io.inc"\n\n/*\n** Helper functions to obtain and relinquish the global mutex. The\n** global mutex is used to protect the unixInodeInfo objects',
    )
    sql = exact(
        sql,
        "fd = robust_open(zName, openFlags, openMode);",
        "fd = rm_private_db_open(zName, openFlags, openMode, eType);",
        2,
    )
    sql = exact(
        sql,
        "robust_open(zShm, O_RDWR|O_CREAT|O_NOFOLLOW,\n                                     (sStat.st_mode&0777))",
        "rm_private_open(zShm, O_RDWR|O_CREAT|O_NOFOLLOW,\n                                     (sStat.st_mode&0777),3)",
    )
    sql = exact(
        sql,
        "robust_open(zShm, O_RDONLY|O_NOFOLLOW,\n                                     (sStat.st_mode&0777))",
        "rm_private_open(zShm, O_RDONLY|O_NOFOLLOW,\n                                     (sStat.st_mode&0777),3)",
    )
    sql = exact(
        sql, "osUnlink(pShmNode->zFilename);", "rm_private_unlink(pShmNode->zFilename);"
    )
    sql = exact(
        sql, "if( osUnlink(zPath)==(-1) ){", "if( rm_private_unlink(zPath)==(-1) ){"
    )
    # A pooled Unix fd bypasses open(). The dedicated broker supplies each new connection.
    sql = exact(
        sql,
        "pUnused = findReusableFd(zName, flags);",
        "pUnused = rmSession.active ? 0 : findReusableFd(zName, flags);",
    )
    sql = exact(
        sql,
        "pReadonly = findReusableFd(zName, flags);",
        "pReadonly = rmSession.active ? 0 : findReusableFd(zName, flags);",
    )
    unit.write_text(sql)
    shutil.copyfile(HERE / "owner_io.inc", unit.parent / "owner_io.inc")
    manifest = src / "Cargo.toml"
    manifest.write_text(
        manifest.read_text()
        + '\n[patch.crates-io]\nlibsqlite3-sys = { path = "../private-libsqlite3-sys" }\n'
    )
    lock = src / "Cargo.lock"
    s = lock.read_text()
    a = s.index('name = "libsqlite3-sys"')
    b = s.index("dependencies =", a)
    prefix = s[a:b].splitlines()
    assert (
        prefix[1] == 'version = "0.38.2"'
        and prefix[2].startswith("source = ")
        and prefix[3].startswith("checksum = ")
        and len(prefix) == 4
    )
    lock.write_text(s[:a] + "\n".join(prefix[:2]) + "\n" + s[b:])
    lib = src / "src/lib.rs"
    lib.write_text(
        lib.read_text()
        + """
extern "C" { fn rm_private_owner_bind(fd:i32,nonce:u64,path:*const std::ffi::c_char,parent:i32)->i32; }
#[no_mangle] pub unsafe extern "C" fn rm_fixture_scope_begin(fd:i32,nonce:u64,path:*const std::ffi::c_char,parent:i32)->i32 {
    unsafe { rm_private_owner_bind(fd,nonce,path,parent) }
}
"""
    )
    guard = src / "src/scheduler/batch/fixture_proof.rs"
    guard.write_text(
        exact(
            guard.read_text(),
            "    let spec = env::var_os",
            """    if env::var_os("RM_OWNER_FD").is_some() {
        extern "C" { fn rm_private_permit()->i32; }
        if unsafe { rm_private_permit() } != 0 { return Err("owner epoch inactive".into()); }
    }
    let spec = env::var_os""",
        )
    )
    shutil.copyfile(HERE / "owner-keeper.rs", src / "src/bin/owner-keeper.rs")
    subprocess.run(
        [
            "cargo",
            "build",
            "--locked",
            "--offline",
            "--jobs",
            "1",
            "--lib",
            "--bin",
            "filestat-keeper",
            "--bin",
            "owner-keeper",
            "--manifest-path",
            src / "Cargo.toml",
        ],
        env=dict(
            os.environ,
            CARGO_TARGET_DIR=str(work / "target"),
            LIBSQLITE3_FLAGS="SQLITE_ENABLE_FILESTAT",
        ),
        check=True,
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-dir", required=True, type=Path)
    a = ap.parse_args()
    build(a.build_dir.resolve())
