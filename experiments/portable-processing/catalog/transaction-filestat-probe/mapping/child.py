"""Create independent VMAs before SQLite opens, then use the archived C ABI dispatcher."""

import ctypes as c
import io
import json
import os
import sys
from pathlib import Path
import runpy

count = int(os.environ.get("RM_MAP_UNRELATED_VMAS", "0"))
assert 0 <= count <= 16384
if count:
    syslib = c.CDLL(None, use_errno=True)
    syslib.mmap.argtypes = [c.c_void_p, c.c_size_t, c.c_int, c.c_int, c.c_int, c.c_long]
    syslib.mmap.restype = c.c_void_p
    syslib.mprotect.argtypes = [c.c_void_p, c.c_size_t, c.c_int]
    size = os.sysconf("SC_PAGE_SIZE")
    addr = syslib.mmap(None, size * (count + 2), 0, 0x22, -1, 0)
    assert addr not in (None, c.c_void_p(-1).value)
    for i in range(1, count + 1, 2):
        assert syslib.mprotect(addr + i * size, size, 1) == 0
dispatcher = str(Path(__file__).resolve().parent.parent / "child.py")
if os.environ.get("RM_MAP_PAIR_ACK") == "1":
    data = sys.stdin.buffer.read()
    assert json.loads(data)["request"]["command"]["action"] == "acknowledgeItem"
    runtime = c.CDLL(
        sys.argv[1]
    )  # Preserve the VFS instance between two Queue::open calls.
    for _ in range(2):
        sys.stdin = io.TextIOWrapper(io.BytesIO(data))
        runpy.run_path(dispatcher, run_name="__main__")
else:
    runpy.run_path(dispatcher, run_name="__main__")
