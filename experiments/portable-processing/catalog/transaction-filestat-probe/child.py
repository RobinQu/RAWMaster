"""Private single-connection child. The generated catalog and O_PATH grants come from its parent."""

import ctypes as c
import errno
import json
import os
import sys

if os.environ.get("RM_PRIVATE_NO_HARDLINK") == "1":
    # Deliver a kernel EPERM only for linkat in this child. Its real RENAME_NOREPLACE then runs.
    assert os.uname().machine == "aarch64"

    class Filter(c.Structure):
        _fields_ = [
            ("code", c.c_ushort),
            ("jt", c.c_ubyte),
            ("jf", c.c_ubyte),
            ("k", c.c_uint),
        ]

    class Program(c.Structure):
        _fields_ = [("length", c.c_ushort), ("filters", c.POINTER(Filter))]

    filters = (Filter * 4)(
        Filter(0x20, 0, 0, 0),
        Filter(0x15, 0, 1, 37),
        Filter(6, 0, 0, 0x00050000 | errno.EPERM),
        Filter(6, 0, 0, 0x7FFF0000),
    )
    program = Program(len(filters), filters)
    system = c.CDLL(None, use_errno=True)
    assert (
        system.prctl(38, 1, 0, 0, 0) == 0
        and system.prctl(22, 2, c.byref(program), 0, 0) == 0
    )


class Result(c.Structure):
    _fields_ = [("data", c.c_void_p), ("length", c.c_size_t)]


r = c.CDLL(sys.argv[1])
version_function = c.CFUNCTYPE(c.c_int)
r.rm_library_sqlite_identity_v1.restype = version_function
assert (
    r.rm_library_abi_version() == 1 and r.rm_library_sqlite_identity_v1()() == 3053002
)
r.rm_library_request_v1.argtypes = [
    c.c_char_p,
    c.c_size_t,
    c.c_char_p,
    c.c_size_t,
    c.POINTER(Result),
]
r.rm_library_release_v1.argtypes = [c.POINTER(Result)]
path = os.fsencode(sys.argv[2])
body = sys.stdin.buffer.read()
result = Result()
code = r.rm_library_request_v1(path, len(path), body, len(body), c.byref(result))
try:
    answer = json.loads(c.string_at(result.data, result.length))
finally:
    r.rm_library_release_v1(c.byref(result))
print(json.dumps({"status": code, "reply": answer}))
