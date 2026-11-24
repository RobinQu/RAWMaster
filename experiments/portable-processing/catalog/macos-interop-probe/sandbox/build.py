"""Build only in the explicit output directory, using the already instrumented X2 core."""

import argparse
from pathlib import Path
import os
import shutil
import subprocess as sp
import re
import json
import hashlib

HERE = Path(__file__).resolve().parent
CODE_ID = "org.rawmaster.fixture.catalog035-restricted"


def signed(path):
    sp.run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            "--options",
            "runtime",
            "--identifier",
            CODE_ID,
            path,
        ],
        check=True,
    )
    sp.run(["/usr/bin/codesign", "--verify", "--strict", path], check=True)
    out = sp.run(
        ["/usr/bin/codesign", "-dvvv", path], capture_output=True, text=True, check=True
    ).stderr
    assert (
        "Signature=adhoc" in out
        and "runtime" in re.search(r"^CodeDirectory .+$", out, re.M)[0]
    )
    return {
        "CDHash": re.search(r"^CDHash=([a-f0-9]+)$", out, re.M)[1],
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "identifier": CODE_ID,
        "hardenedRuntime": True,
        "signature": "ad hoc",
    }


def build(out, interop):
    out.mkdir(parents=True, exist_ok=True)
    src = out / "signed-catalog"
    shutil.copytree(interop / "instrumented-catalog", src, dirs_exist_ok=True)
    witness = src / "witness-vfs.c"
    code = witness.read_text()
    fd_check = "if (fstat(fd, &s) || fstatfs(fd, &fs) || !(fs.f_flags & MNT_LOCAL) ||"
    assert code.count(fd_check) == 1
    code = code.replace(
        fd_check,
        'if (fstat(fd,&s) != 0) { diag_error("fstat",errno,0); return 0; }\n  if (fstatfs(fd,&fs)!=0) { diag_error("fstatfs",errno,s.st_mode); return 0; }\n  if (!(fs.f_flags & MNT_LOCAL) ||',
    )
    attrs = "if (fgetattrlist(fd, &req, &reply, sizeof(reply), 0) ||"
    assert code.count(attrs) == 1
    code = code.replace(
        attrs,
        'if (fgetattrlist(fd,&req,&reply,sizeof(reply),0)!=0) { diag_error("volumeAttributes",errno,s.st_mode); return 0; }\n  if (',
    )
    points = "sizeof(region)) != (int)sizeof(region))\n    return 0;"
    assert code.count(points) == 1
    code = code.replace(
        points,
        'sizeof(region)) != (int)sizeof(region)) { diag_error("ownRegion",errno,0); return 0; }',
    )
    diagnostic = r"""#include <stdio.h>
#include <errno.h>
static void diag_error(const char *site,int error,int mode) {
    fprintf(stderr,"{\"attachmentDiagnostic\":\"%s\",\"errno\":%d,\"mode\":%d}\n",site,error,mode);
}
"""
    witness.write_text(diagnostic + code + "\n" + (HERE / "transport.c").read_text())
    old = (src / "src/bin/mac-private.rs").read_text()
    assert old.count("fn main() -> Result<()> {") == 1
    core = old.replace(
        "fn main() -> Result<()> {", "fn original_queue_entry() -> Result<()> {"
    )
    # Log the errno after the real operations already saved it, preserving branch logic.
    unit = src / "src/scheduler/batch/directory.rs"
    implementation = unit.read_text()
    for anchor, label, value in [
        (
            "if linked != 0 {\n            let error = io::Error::last_os_error();",
            "linkat",
            "error",
        ),
        (
            "if result != 0 {\n                let e = io::Error::last_os_error();",
            "renameatx_np(RENAME_EXCL)",
            "e",
        ),
    ]:
        assert implementation.count(anchor) == 1
        record = (
            '\n                eprintln!("{}", serde_json::json!({"publicationSyscall": "'
            + label
            + '","errno": '
            + value
            + ".raw_os_error()}));"
        )
        implementation = implementation.replace(anchor, anchor + record)
    unit.write_text(implementation)
    (src / "src/bin/signed-worker.rs").write_text(
        core + "\n" + (HERE / "entry.rs").read_text()
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
            "--bin",
            "signed-worker",
            "--manifest-path",
            src / "Cargo.toml",
        ],
        env=env,
        check=True,
    )
    shutil.copy2(out / "target/debug/signed-worker", out / "expected-worker")
    sp.run(
        [
            "xcrun",
            "clang",
            "-O2",
            "-D_DARWIN_C_SOURCE",
            "-DOTHER_FIXTURE_SIGNER_BODY",
            HERE / "transport.c",
            "-o",
            out / "other-worker",
        ],
        check=True,
    )
    sp.run(
        [
            "xcrun",
            "clang",
            "-O2",
            "-D_DARWIN_C_SOURCE",
            HERE / "verify.c",
            "-framework",
            "Security",
            "-framework",
            "CoreFoundation",
            "-lbsm",
            "-o",
            out / "verify-peer",
        ],
        check=True,
    )
    manifest = {
        name: signed(out / name) for name in ("expected-worker", "other-worker")
    }
    assert manifest["expected-worker"]["CDHash"] != manifest["other-worker"]["CDHash"]
    (out / "signed-programs.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--build-dir", type=Path, required=True)
    p.add_argument("--interop-build", type=Path, required=True)
    a = p.parse_args()
    build(a.build_dir.resolve(), a.interop_build.resolve())
