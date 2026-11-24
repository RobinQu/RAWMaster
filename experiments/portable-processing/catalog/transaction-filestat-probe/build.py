"""Build the instrumented copy with Cargo.lock and upstream SQLite's FILESTAT feature."""

import os
from pathlib import Path
import shutil
import subprocess as sp

HERE = Path(__file__).resolve().parent


def build(repo: Path, directory: Path):
    original = repo / "Modules/LibraryCatalog"
    staged = directory / "instrumented-catalog"
    target = directory / "target"
    staged.mkdir(parents=True, exist_ok=True)
    for name in ["Cargo.toml", "Cargo.lock"]:
        shutil.copyfile(original / name, staged / name)
    shutil.copytree(original / "src", staged / "src", dirs_exist_ok=True)
    unit = staged / "src/scheduler/batch/items.rs"
    source = unit.read_text()
    inserts = {
        "use serde::{Deserialize, Serialize};": '#[path="fixture_proof.rs"]\nmod proof;\nuse serde::{Deserialize, Serialize};',
        "let snapshot = Context::load(&read, &id, ordinal)?;": 'let snapshot = Context::load(&read, &id, ordinal)?;\n        proof::check(&read,"read",1)?;',
        "let mut ctx = Context::load(&tx, &id, ordinal)?;": 'let mut ctx = Context::load(&tx, &id, ordinal)?;\n        proof::check(&tx,"write",2)?;',
        "PrepareItem => {\n": 'PrepareItem => {\n                proof::check(&tx,"prepare",2)?;\n',
        "PublishItem => {\n": "PublishItem => {\n                let fence_index=std::cell::Cell::new(0u32);\n",
        ".publish(root, || self.owners(&ctx, super::super::now_ms()?))?": '.publish(root, || { self.owners(&ctx,super::super::now_ms()?)?; let index=fence_index.get();fence_index.set(index+1);proof::check(&tx, if index==0 {"link"}else{"rename"}, 2) })?',
        "AcknowledgeItem => {\n": 'AcknowledgeItem => {\n                proof::check(&tx,"ack",2)?;\n',
    }
    for original_text, with_check in inserts.items():
        if source.count(original_text) != 1:
            raise RuntimeError(f"Production checkpoint changed: {original_text}")
        source = source.replace(original_text, with_check)
    unit.write_text(source)
    shutil.copyfile(HERE / "guard.rs", unit.parent / "fixture_proof.rs")
    (staged / "src/bin").mkdir(exist_ok=True)
    shutil.copyfile(HERE / "keeper.rs", staged / "src/bin/filestat-keeper.rs")
    environment = dict(
        os.environ,
        CARGO_TARGET_DIR=str(target),
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
            "--bin",
            "filestat-keeper",
            "--manifest-path",
            staged / "Cargo.toml",
        ],
        env=environment,
        check=True,
    )
    return (
        staged,
        target / "debug/filestat-keeper",
        target / "debug/librawmaster_library.so",
    )
