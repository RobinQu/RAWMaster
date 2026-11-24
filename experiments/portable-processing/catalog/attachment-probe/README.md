# macOS SQLite attachment diagnostic capability

Apple SQLite 3.54.0 returned SQLITE_NOTFOUND (12) and no diagnostic JSON for all three FILESTAT invocations in every case. The requests used the public connection file control, the actual main file's xFileControl, and the actual journal file's xFileControl. FILE_POINTER and JOURNAL_POINTER succeeded and returned distinct version-3 I/O method objects. The native transaction stayed active throughout. The command connection used no app-issued xFetch, xUnfetch, xShmMap or xShmUnmap.

| Active transaction | WAL size | SHM size | SQLite marker |
| --- | ---: | ---: | --- |
| READ or BEGIN IMMEDIATE | 0 bytes | 32,768 bytes | from-main |
| READ or BEGIN IMMEDIATE | 4,152 bytes | 32,768 bytes | only-in-wal |

A setup connection kept the database open in WAL mode with autocheckpoint disabled. After a truncating checkpoint, the dirty fixture committed its second marker in WAL. Separate command connections admitted SELECT, reads and transaction statements through a SQLite authorizer. Writer, marker and transaction kind matched before and after the control, total changes stayed zero, and every rollback succeeded. An immutable read after normal teardown verified the writer and marker and returned quick_check = ok. The two transaction cases with the same fixture state yielded the same final main SHA-256. The size and inode fields for adjacent files in the receipt describe the fixture. They do not establish which vnode SQLite had open. Since the diagnostic provided no handles, the runner did not attempt substitution cases.

The runtime and SDK reported source ID `2026-04-09 12:25:13 8fa8248e303219400c646a885e36dfc52eae33d83f4412e3f369b2be5373aapl`. The receipt includes all 73 reported compile options, including DEFAULT_MMAP_SIZE=0, MAX_MMAP_SIZE=1073741824 and ENABLE_LOCKING_STYLE=1. The public SDK describes FILESTAT output as optional. The bundled Linux source in libsqlite3-sys 0.38.2 has SQLite 3.53.2 and compiles its diagnostic descriptor output only for debug or ENABLE_FILESTAT builds. That source is distinct from Apple's build.

Run `python3 run.py --output /path/to/new/output/directory` in this directory. The runner compiles the local C source against system libsqlite3, creates independent temporary fixtures and retains the binary and JSON receipt in the specified directory. [SQLite's control contract](https://www.sqlite.org/c3ref/c_fcntl_begin_atomic_write.html) · [SQLite's I/O method contract](https://sqlite.org/c3ref/io_methods.html)
