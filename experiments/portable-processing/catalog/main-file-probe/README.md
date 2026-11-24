# macOS SQLite main-handle identity probe

Run the probe on macOS from the repository root.

```sh
python3 experiments/portable-processing/catalog/main-file-probe/run.py \
    --output output/035-development/catalog-main-file-replay
```

The runner compiles `catalog_handle.c` with Apple clang against public SQLite and libproc headers. Each case gets newly generated files in its own temporary directory and subprocess. The JSON receipt preserves the exact identities from that run, runtime and SDK versions, SQLite source ID, journal mode, dynamic library linkage, individual assertions, and pre/post hashes of both main database files.

On macOS 27.0.1 arm64, APFS and the system SQLite 3.54.0 unix VFS, all 12 cases passed. The recorded Apple source ID is `2026-04-09 12:25:13 8fa8248e303219400c646a885e36dfc52eae33d83f4412e3f369b2be5373aapl`. The two positive cases verified READ and WRITE transactions. Both fetched 100 bytes at offset zero and observed a 16,384-byte VM region with a 1,272-byte kernel reply. Each case restored the connection's original mmap limit of zero. The 4,096-byte requested cap controls SQLite's per-connection setting. The kernel rounds VM coverage to its own page size.

| Scenario | Observed decision |
| --- | --- |
| READ with a real main-table query or BEGIN IMMEDIATE plus the same query | The mapping, pinned file and current path agreed on device, inode and nanosecond birth. |
| Autocommit after a finalized SELECT | The transaction state was NONE and there was no VFS borrow. |
| Genuine mmap cap of zero in READ | xFetch succeeded with a null pointer. The proof failed and no pointer was released. |
| Injected rejection after acquiring a valid mapping | The original pointer was released exactly once and the proof failed. |
| Exchange a byte-identical file or its directory before SQLite opens | HAS_MOVED returned zero. The mapped vnode matched the replacement at the current path and differed from the original pinned file. |
| Exchange after SQLite opens an active transaction | The mapping remained tied to the pinned original. The replacement at the path failed the comparison and HAS_MOVED reported movement. |
| Exchange after a successful first proof in WRITE | A second proof in that same real transaction rejected the replaced path. |
| Open a decoy during an exchange, then restore the original path before verification | The path matched the original pinned file while the live SQLite mapping identified the decoy. |

## ABI and lifetimes

1. Open a descriptor for the intended main file before opening SQLite. Keep a descriptor to the private test root for path lookups. Use a single unmanaged-by-others SQLite connection on the calling thread throughout the test.
2. Save the per-connection mmap cap, set it to 4096 or zero for the negative test, then verify the actual value. Run BEGIN for reads or BEGIN IMMEDIATE for writes. Finalize a real SELECT against the main table. Check that SQLite reports an active main transaction of the expected kind and that autocommit is off.
3. Call sqlite3_file_control on the named main schema with FILE_POINTER and HAS_MOVED. The exposed sqlite3_file belongs to the connection. Check its public sqlite3_io_methods version and callbacks. Call its xFetch at offset zero for 100 bytes. A null pointer, unavailable callback or unsuccessful control has no authority.
4. While this nonnull borrow is live, ask proc_pidinfo with PROC_PIDREGIONPATHINFO for the region containing its address. Require the full structure size, containing range for all requested bytes, regular vnode and correct mapped file offset. Compare the returned vnode's native device, inode and nanosecond birth separately to fstat on the pinned file and fstatat on the current path. Check the current path and HAS_MOVED again after releasing. No VM pointer is dereferenced, cached or exposed.
5. Release every nonnull borrow on the same sqlite3_file with exactly the original offset and pointer before leaving the transaction. Require a successful xUnfetch. Passing NULL to xUnfetch has different semantics. The probe never does so. A moved-file signal is recorded even when the independent mapping comparison also rejects the file.
6. Restore the pathname matching the handle before rolling back or closing SQLite, so the correct handle owns any WAL/SHM cleanup. Restore the original per-connection cap after the rollback. Close SQLite before closing the pinned file. The runner then restores the fixture names and checks both original main files byte for byte and via independent immutable reads.

Each pair has matching writer, marker, user_version and initial SHA-256 but distinct inodes. Whole-folder swaps use WAL with checkpointed identical initial main files. File-only swaps use rollback-journal mode so they never mix another database's sidecars. The live SQL authorizer admits only the required SELECT, reads, transactions and mmap-size pragmas. All cases had zero other SQL attempts, zero total changes and unchanged physical main files. The fixture uses a small table with a writer ID and a frozen marker.

## Scope for integration

The observation binds SQLite's actual **main** VFS mapping to an already-authorized, still-open file at the verification point. Main can use WAL pages for the logical read, so production still needs its existing writer, schema, lease, and history checks within that transaction. It does not identify a WAL, a SHM file, the origin of a copied SQLite dataset, the current mount's persistent volume UUID, or the destination export directory. Rechecking narrows the interval exposed to path replacement. File or directory movement after the last check remains possible. SQLite integrity after external replacement of live journal files is outside this PoC.

Keep the connection exclusively borrowed while invoking its VFS callbacks and keep the fetched region borrowed only for the kernel query. The test owns its sole SQLite connection in a fresh subprocess. On Unix, closing an unrelated same-process descriptor can release traditional POSIX file locks for that inode. A production adapter needs safe ownership/lifetime coordination with other SQLite connections, including Swift handles, or an isolated descriptor-owning process. The probe measures neither throughput nor a whole product command. It covers same-volume APFS exchanges. Cross-volume inode collisions, other Apple OS/VFS configurations, unsupported kernel queries and network filesystems still need separately scoped evidence.
