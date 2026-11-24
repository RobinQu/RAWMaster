from pathlib import Path
import importlib.util
import os
import shutil
import subprocess
import sys

here = Path(__file__).resolve().parent
previous = here.parent
repo = next(
    path
    for path in here.parents
    if (path / "Modules/LibraryCatalog/Cargo.toml").is_file()
)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def exact(source, old, new):
    if source.count(old) != 1:
        raise ValueError(old)
    return source.replace(old, new)


def build(work, profile):
    t = load("previous_build", previous / "build.py")
    staged, _, _ = t.build(repo, work)
    unit = staged / "src/scheduler/batch/items.rs"
    text = unit.read_text()
    text = exact(
        text,
        "let read = db.transaction_with_behavior(TransactionBehavior::Deferred)?;",
        "let measuring=proof::bounded::Session::begin()?;\n        let read = db.transaction_with_behavior(TransactionBehavior::Deferred)?;",
    )
    text = exact(
        text,
        "let mut ctx = Context::load(&tx, &id, ordinal)?;",
        "measuring.writer_started();\n        let mut ctx = Context::load(&tx, &id, ordinal)?;",
    )
    text = exact(
        text, "tx.commit()?;", "tx.commit()?;\n        measuring.writer_ended();"
    )
    unit.write_text(text)
    guard = unit.parent / "fixture_proof.rs"
    text = guard.read_text()
    a = text.index("fn mappings(")
    b = text.index("pub(super) fn check(", a)
    text = text[:a] + '#[path="bounded.rs"]\npub(super) mod bounded;\n' + text[b:]
    text = exact(
        text,
        "let spec = env::var_os",
        "let started=std::time::Instant::now();\n    let spec = env::var_os",
    )
    text = exact(
        text,
        "shm_maps = mappings(&live)?;",
        "shm_maps = bounded::mapped(db,&live,phase)?;",
    )
    a = text.index("    eprintln!(")
    b = text.index("    if allowed {", a)
    text = (
        text[:a]
        + """    bounded::record(json!({"phase":phase,"state":state,"walBytes":sizes[1],"attached":attached,"grants":trusted,"names":names,"shmMappings":shm_maps,"readMask":shared,"exclusiveMask":exclusive,"allowed":allowed}),started);
"""
        + text[b:]
    )
    guard.write_text(text)
    shutil.copyfile(here / "bounded.rs", unit.parent / "bounded.rs")
    shutil.copyfile(here / "witness-vfs.c", staged / "witness-vfs.c")
    shutil.copyfile(here / "build_native.rs", staged / "build.rs")
    queue = staged / "src/scheduler.rs"
    text = queue.read_text()
    text = exact(
        text,
        "let db = Connection::open_with_flags(\n            &path,",
        """extern "C" { fn rm_install_mapping_vfs()->i32; }
        static INSTALLED:std::sync::OnceLock<i32>=std::sync::OnceLock::new();
        if *INSTALLED.get_or_init(||unsafe{rm_install_mapping_vfs()})!=rusqlite::ffi::SQLITE_OK {return Err("private mapping VFS unavailable".into());}
        let db = Connection::open_with_flags_and_vfs(
            &path,""",
    )
    text = exact(
        text,
        "rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,\n        )?;",
        'rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,\n            "rm-frozen-map-v1",\n        )?;',
    )
    queue.write_text(text)
    keeper = staged / "src/bin/filestat-keeper.rs"
    s = keeper.read_text()
    s = exact(
        s,
        "assert!(args.next().is_none() && !std::path::Path::new(&database).exists());",
        """let reopen=args.next().is_some_and(|a|a=="reopen");
    assert!(args.next().is_none() && std::path::Path::new(&database).exists()==reopen);""",
    )
    anchor = "    let db = Connection::open(database)?;"
    s = exact(
        s,
        anchor,
        anchor
        + """\n    if reopen {db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA wal_autocheckpoint=0; BEGIN IMMEDIATE; ROLLBACK")?;}else{""",
    )
    s = exact(s, "    let library: String =", "    }\n    let library: String =")
    keeper.write_text(s)
    cmd = [
        "cargo",
        "build",
        "--locked",
        "--offline",
        "--jobs",
        "1",
        "--lib",
        "--bin",
        "filestat-keeper",
        "--manifest-path",
        str(staged / "Cargo.toml"),
    ]
    if profile == "release":
        cmd.append("--release")
    subprocess.run(
        cmd,
        check=True,
        env=dict(
            os.environ,
            CARGO_TARGET_DIR=str(work / "target"),
            LIBSQLITE3_FLAGS="SQLITE_ENABLE_FILESTAT",
        ),
    )


if __name__ == "__main__":
    build(Path(sys.argv[1]).resolve(), sys.argv[2])
