"""Instrument a copy of the catalog crate and choose the same pinned SQLite as the server, on Darwin."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
ARCH = ROOT / "experiments/portable-processing/catalog"
T = ARCH / "transaction-filestat-probe"
Q = ARCH / "queue-transaction-probe"


def exact(source, old, new):
    assert source.count(old) == 1, (old, source.count(old))
    return source.replace(old, new)


def build(out):
    out.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location("T_build", T / "build.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    # Reuse the Linux harness's source checkpoints; compile the Darwin backend below.
    deferred = []

    def defer_linux_build(command, **kwargs):
        assert command[:2] == ["cargo", "build"], command
        deferred.append(command)

    m.sp = SimpleNamespace(run=defer_linux_build)
    staged, _, _ = m.build(ROOT, out)
    assert len(deferred) == 1
    (sql,) = Path(os.environ.get("CARGO_HOME", str(Path.home() / ".cargo"))).glob(
        "registry/src/*/libsqlite3-sys-0.38.2/sqlite3/sqlite3.c"
    )
    assert (
        hashlib.sha256(sql.read_bytes()).hexdigest()
        == "0a409f1633283fa31a9126b11fbfd64a1991c5d30defad07e5745d4667f5e23d"
    )
    manifest = staged / "Cargo.toml"
    manifest.write_text(
        exact(
            manifest.read_text(),
            'features = ["backup", "functions", "collation"]',
            'features = ["backup", "functions", "collation", "bundled"]',
        )
    )
    lib = staged / "src/lib.rs"
    lib.write_text(
        lib.read_text()
        + '\n#[path="scheduler/batch/fixture_proof.rs"] pub mod mac_probe;\n'
    )
    queue = staged / "src/scheduler.rs"
    q = exact(
        queue.read_text(),
        "let db = Connection::open_with_flags(\n            &path,",
        "crate::mac_probe::install()?;\n        let db = Connection::open_with_flags_and_vfs(\n            &path,",
    )
    queue.write_text(
        exact(
            q,
            "rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,\n        )?;",
            'rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,\n            "rm-frozen-map-v1",\n        )?;',
        )
    )
    # Real APFS permits hardlinks. Optional generated fixture error makes the existing RENAME_EXCL backup branch reachable.
    folder = staged / "src/scheduler/batch/directory.rs"
    ds = exact(
        folder.read_text(),
        "let linked = unsafe {\n            libc::linkat(",
        'let linked = if std::env::var_os("RM_MAC_NO_LINK").is_some() {unsafe { *libc::__error()=libc::EPERM; } -1 } else {unsafe {\n            libc::linkat(',
    )
    folder.write_text(
        exact(
            ds,
            "        };\n        if linked != 0 {",
            "        }};\n        if linked != 0 {",
        )
    )
    item = staged / "src/scheduler/batch/items.rs"
    item.write_text(
        exact(
            item.read_text(),
            '#[path="fixture_proof.rs"]\nmod proof;',
            "use crate::mac_probe as proof;",
        )
    )
    shutil.copyfile(HERE / "proof.rs", staged / "src/scheduler/batch/fixture_proof.rs")
    shutil.copyfile(HERE / "private.rs", staged / "src/bin/mac-private.rs")
    shutil.copyfile(sql.parent / "sqlite3.h", staged / "sqlite3.h")
    # Preserve the forwarding methods up to the actual natural-map control; replace only Linux-specific query support.
    witness = (
        (T / "mapping/witness-vfs.c")
        .read_text()
        .split("/* Linux UAPI struct procmap_query", 1)[0]
        .replace("#include <sys/sysmacros.h>", "")
    )
    (staged / "witness-vfs.c").write_text(
        witness + "\n" + (HERE / "mac-proof.c").read_text()
    )
    native = exact(
        (T / "mapping/build_native.rs").read_text(),
        '"-D_GNU_SOURCE",',
        '"-D_DARWIN_C_SOURCE", "-I.",',
    )
    (staged / "build.rs").write_text(native)
    include = ["-I", str(Q), "-I", str(ROOT / "Modules/LibraryCatalog/include")]
    for source, name in [
        (Q / "keeper.c", "system-keeper"),
        (HERE / "system-peer.c", "system-peer"),
    ]:
        subprocess.run(
            [
                "xcrun",
                "clang",
                "-O2",
                "-D_DARWIN_C_SOURCE",
                *include,
                str(source),
                "-lsqlite3",
                "-o",
                str(out / name),
            ],
            check=True,
        )
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
            "mac-private",
            "--manifest-path",
            str(staged / "Cargo.toml"),
        ],
        env=dict(
            os.environ,
            CARGO_TARGET_DIR=str(out / "target"),
            LIBSQLITE3_FLAGS="SQLITE_ENABLE_FILESTAT",
        ),
        check=True,
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--build-dir", required=True, type=Path)
    build(p.parse_args().build_dir.resolve())
