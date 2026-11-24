"""Add an inventory query to the already pinned V3 keeper; keep the catalog request binary intact."""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
V3 = (
    REPO
    / "experiments/portable-processing/catalog/transaction-filestat-probe/bootstrap"
)


def sha(p):
    with p.open("rb") as data:
        return hashlib.file_digest(data, "sha256").hexdigest()


def build(work):
    src = work / "instrumented-catalog"
    binary = work / "target/debug/librawmaster_library.so"
    before = sha(binary)
    keeper = (V3 / "owner-keeper.rs").read_text()
    entry = "    let path=env::args().nth(1)"
    assert keeper.count(entry) == 1
    keeper = keeper.replace(
        entry,
        """
    let peer: i32 = env::var("RM_OWNER_FD")?.parse()?;
    if unsafe { libc::fcntl(peer, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
        return Err("failed to restore connection-local close-on-exec".into());
    }
"""
        + entry,
    )
    anchor = '        "ticket" =>'
    assert keeper.count(anchor) == 1
    extra = """
        "facts" => {
            let sql = "SELECT i.key, json_extract(i.value,'$.manifestSha256'),json_extract(i.value,'$.state'),
                json_extract(i.value,'$.ticket'),(SELECT count(*) FROM lc_workbench_names n WHERE n.item_key=i.key)
                FROM lc_meta i WHERE i.key GLOB 'wb032.item.v1/*' ORDER BY i.key LIMIT 17";
            let mut stmt=db.prepare(sql)?;
            let mut rows=stmt.query([])?;
            let mut values=Vec::new();
            while let Some(row)=rows.next()? {
                let key:String=row.get(0)?;
                let manifest:String=row.get(1)?;
                let state:String=row.get(2)?;
                let ticket:Option<String>=row.get(3)?;
                let reservations:i64=row.get(4)?;
                values.push(json!({"key":key,"manifest":manifest,"state":state,"ticket":ticket,"reservations":reservations}));
            }
            if values.len()>16 {return Err("fixture inventory limit".into());}
            let batches:i64=db.query_row("SELECT count(*) FROM lc_meta WHERE key GLOB 'wb032.manifest.v1/*'",[],|r|r.get(0))?;
            send(json!({"items":values,"batches":batches,"txnState":unsafe{ffi::sqlite3_txn_state(db.handle(),c"main".as_ptr())}}))?;
        }
"""
    (src / "src/bin/wal-recovery-keeper.rs").write_text(
        keeper.replace(anchor, extra + anchor)
    )
    subprocess.run(
        [
            "cargo",
            "build",
            "--locked",
            "--offline",
            "--jobs",
            "1",
            "--bin",
            "wal-recovery-keeper",
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
    assert sha(binary) == before
    print(
        "Existing catalog ABI SHA256",
        before,
        "recovery keeper",
        sha(work / "target/debug/wal-recovery-keeper"),
    )


if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--build-dir", required=True, type=Path)
    build(a.parse_args().build_dir.resolve())
