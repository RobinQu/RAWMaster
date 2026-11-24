"""Bind the private scope on this same thread, then call the unchanged catalog request ABI."""

import ctypes as c
import os
from pathlib import Path
import runpy
import sys

repo = next(
    p
    for p in Path(__file__).resolve().parents
    if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
lib = c.CDLL(sys.argv[1])
bind = lib.rm_fixture_scope_begin
bind.argtypes = [c.c_int, c.c_uint64, c.c_char_p, c.c_int]
assert (
    bind(
        int(os.environ["RM_OWNER_FD"]),
        int(os.environ["RM_OWNER_NONCE"]),
        os.fsencode(sys.argv[2]),
        int(os.environ["RM_OWNER_PID"]),
    )
    == 0
)
runpy.run_path(
    str(
        repo
        / "experiments/portable-processing/catalog/transaction-filestat-probe/mapping/child.py"
    ),
    run_name="__main__",
)
