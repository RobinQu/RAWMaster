#include "identity.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>

#define ASSERT(x)                                                                                  \
    do {                                                                                           \
        if (!(x)) {                                                                                \
            fprintf(stderr, "fixture failed, line %d, %s (errno %d)\n", __LINE__, #x, errno);      \
            exit(2);                                                                               \
        }                                                                                          \
    } while (0)
static const char *tf(int x) {
    return x ? "true" : "false";
}
typedef struct {
    sqlite3_file wrapper;
    sqlite3_file *native;
    int flags;
} File;
typedef struct {
    int count;
    struct proc_fdinfo fds[256];
} Snapshot;
typedef struct {
    int count, fd;
    VnodeID saved;
} Capture;
static sqlite3_vfs *under;
static sqlite3_vfs relay;
static File *mainwrap, *walwrap;
static int (*real_open)(const char *, int, int);
static Capture *opening;
static int hooked, wal_fd = -1, delta_fd = -1, joined_parent, wal_opens, wal_closes, wal_reads,
                   wal_writes, wal_hooks, main_closes;
static VnodeID wal_opened, main_opened;
static int main_fd = -1, main_delta = -1, main_hooks;
static uint64_t page0;
static int page_length, page_rc = -1, shared, exclusive, shm_maps, shm_unmaps, shm_locks,
                        shm_unlocks, shm_epoch = 1;
static int snapshots_full;
static int syscall_sees(const char *name, int flags, int mode) {
    int f = real_open(name, flags, mode), save = errno;
    if (opening && f >= 0) {
        opening->count++;
        opening->fd = f;
        opening->saved = fd_id(f);
    }
    errno = save;
    return f;
}
static Snapshot snapshot(void) {
    Snapshot s = {0};
    int n = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, s.fds, sizeof(s.fds));
    s.count = n > 0 && n < (int)sizeof(s.fds) && n % (int)sizeof(*s.fds) == 0
                  ? n / (int)sizeof(*s.fds)
                  : -1;
    return s;
}
static int has(const Snapshot *s, struct proc_fdinfo f) {
    for (int i = 0; i < s->count; i++)
        if (s->fds[i].proc_fd == f.proc_fd && s->fds[i].proc_fdtype == f.proc_fdtype)
            return 1;
    return 0;
}
static int single_new_fd(const Snapshot *pre, const Snapshot *after) {
    int candidate = -1, count = 0;
    if (pre->count < 0 || after->count != pre->count + 1)
        return -1;
    for (int i = 0; i < pre->count; i++)
        if (!has(after, pre->fds[i]))
            return -1;
    for (int i = 0; i < after->count; i++)
        if (!has(pre, after->fds[i])) {
            candidate = after->fds[i].proc_fd;
            count++;
        }
    return count == 1 && usable(fd_id(candidate)) ? candidate : -1;
}
static void invalidate_shm(void) {
    page0 = 0;
    page_length = 0;
    page_rc = -1;
    shared = exclusive = 0;
    shm_epoch++;
}
static int xclose(sqlite3_file *f) {
    File *w = (File *)f;
    if (w == walwrap) {
        wal_closes++;
        walwrap = NULL;
        wal_fd = delta_fd = -1;
        wal_opened = (VnodeID){0};
        invalidate_shm();
    }
    if (w == mainwrap) {
        main_closes++;
        mainwrap = NULL;
        main_fd = main_delta = -1;
        main_opened = (VnodeID){0};
        invalidate_shm();
    }
    int rc = w->native->pMethods->xClose(w->native);
    free(w->native);
    f->pMethods = NULL;
    return rc;
}
static int xread(sqlite3_file *f, void *p, int n, sqlite3_int64 offset) {
    File *w = (File *)f;
    int rc = w->native->pMethods->xRead(w->native, p, n, offset);
    if (w == walwrap && rc == SQLITE_OK)
        wal_reads++;
    return rc;
}
static int xwrite(sqlite3_file *f, const void *p, int n, sqlite3_int64 offset) {
    File *w = (File *)f;
    int rc = w->native->pMethods->xWrite(w->native, p, n, offset);
    if (w == walwrap && rc == SQLITE_OK)
        wal_writes++;
    return rc;
}
#define FWD0(name, member)                                                                         \
    static int name(sqlite3_file *f) {                                                             \
        File *w = (File *)f;                                                                       \
        return w->native->pMethods->member(w->native);                                             \
    }
#define FWD1(name, member, T)                                                                      \
    static int name(sqlite3_file *f, T x) {                                                        \
        File *w = (File *)f;                                                                       \
        return w->native->pMethods->member(w->native, x);                                          \
    }
FWD1(xtruncate, xTruncate, sqlite3_int64)
FWD1(xsync, xSync, int) FWD1(xsize, xFileSize, sqlite3_int64 *) FWD1(xlock, xLock, int)
    FWD1(xunlock, xUnlock, int) FWD1(xreserved, xCheckReservedLock, int *)
        FWD0(xsector, xSectorSize)
            FWD0(xdevice, xDeviceCharacteristics) static int xcontrol(sqlite3_file *f, int action,
                                                                      void *arg) {
    File *w = (File *)f;
    return w->native->pMethods->xFileControl(w->native, action, arg);
}
static int xmap(sqlite3_file *f, int pg, int length, int extend, void volatile **out) {
    File *w = (File *)f;
    int rc = w->native->pMethods->xShmMap(w->native, pg, length, extend, out);
    if (w == mainwrap && pg == 0) {
        shm_maps++;
        page_rc = rc;
        page_length = length;
        page0 = rc == SQLITE_OK && out && *out ? (uint64_t)(uintptr_t)*out : 0;
    }
    return rc;
}
static int xshmlock(sqlite3_file *f, int at, int n, int flags) {
    File *w = (File *)f;
    int rc = w->native->pMethods->xShmLock(w->native, at, n, flags);
    if (w == mainwrap && rc == SQLITE_OK && at >= 0 && n > 0 && at + n <= SQLITE_SHM_NLOCK) {
        int mask = ((1 << n) - 1) << at;
        if (flags & SQLITE_SHM_LOCK) {
            shm_locks++;
            if (flags & SQLITE_SHM_SHARED)
                shared |= mask;
            else
                exclusive |= mask;
        }
        if (flags & SQLITE_SHM_UNLOCK) {
            shm_unlocks++;
            if (flags & SQLITE_SHM_SHARED)
                shared &= ~mask;
            else
                exclusive &= ~mask;
        }
    }
    return rc;
}
static void xbarrier(sqlite3_file *f) {
    File *w = (File *)f;
    w->native->pMethods->xShmBarrier(w->native);
}
static int xunmap(sqlite3_file *f, int remove) {
    File *w = (File *)f;
    if (w == mainwrap) {
        shm_unmaps++;
        invalidate_shm();
    }
    return w->native->pMethods->xShmUnmap(w->native, remove);
}
static int xfetch(sqlite3_file *f, sqlite3_int64 off, int n, void **p) {
    File *w = (File *)f;
    return w->native->pMethods->xFetch(w->native, off, n, p);
}
static int xunfetch(sqlite3_file *f, sqlite3_int64 off, void *p) {
    File *w = (File *)f;
    return w->native->pMethods->xUnfetch(w->native, off, p);
}
static sqlite3_io_methods io = {3,        xclose,   xread,     xwrite,   xtruncate, xsync,   xsize,
                                xlock,    xunlock,  xreserved, xcontrol, xsector,   xdevice, xmap,
                                xshmlock, xbarrier, xunmap,    xfetch,   xunfetch};
static int xopen(sqlite3_vfs *unused, const char *name, sqlite3_file *out, int flags,
                 int *received) {
    (void)unused;
    File *w = (File *)out;
    memset(w, 0, sizeof(*w));
    w->flags = flags;
    w->native = calloc(1, (size_t)under->szOsFile);
    if (!w->native)
        return SQLITE_NOMEM;
    int wal = (flags & SQLITE_OPEN_WAL) != 0, main_db = (flags & SQLITE_OPEN_MAIN_DB) != 0;
    Capture capture = {0, -1, {0}};
    Snapshot pre = {0};
    if (wal || main_db) {
        ASSERT(opening == NULL);
        if (wal)
            joined_parent =
                mainwrap && sqlite3_database_file_object(name) == (sqlite3_file *)mainwrap;
        pre = snapshot();
        opening = &capture;
    }
    int rc = under->xOpen(under, name, w->native, flags, received);
    if (wal || main_db) {
        opening = NULL;
        Snapshot after = snapshot();
        int delta = single_new_fd(&pre, &after);
        int verified = hooked && capture.count == 1 && delta >= 0 && delta == capture.fd &&
                               identical(capture.saved, fd_id(delta))
                           ? delta
                           : -1;
        if (main_db) {
            main_fd = verified;
            main_delta = delta;
            main_hooks = capture.count;
            main_opened = capture.saved;
        }
        if (wal) {
            snapshots_full = pre.count >= 0 && after.count >= 0;
            delta_fd = delta;
            wal_hooks = capture.count;
            wal_opened = capture.saved;
            wal_fd = verified;
        }
    }
    if (!w->native->pMethods) {
        free(w->native);
        w->native = NULL;
        return rc;
    }
    const sqlite3_io_methods *m = w->native->pMethods;
    if (m->iVersion < 3 || !m->xShmMap || !m->xShmUnmap || !m->xShmLock || !m->xShmBarrier ||
        !m->xFetch || !m->xUnfetch) {
        m->xClose(w->native);
        free(w->native);
        w->native = NULL;
        return SQLITE_CANTOPEN;
    }
    out->pMethods = &io;
    if (rc == SQLITE_OK) {
        if (flags & SQLITE_OPEN_MAIN_DB) {
            ASSERT(!mainwrap);
            mainwrap = w;
        }
        if (wal) {
            ASSERT(!walwrap);
            walwrap = w;
            wal_opens++;
        }
    }
    return rc;
}
static int vdelete(sqlite3_vfs *v, const char *n, int sync) {
    (void)v;
    return under->xDelete(under, n, sync);
}
static int vaccess(sqlite3_vfs *v, const char *n, int f, int *out) {
    (void)v;
    return under->xAccess(under, n, f, out);
}
static int vfull(sqlite3_vfs *v, const char *n, int size, char *out) {
    (void)v;
    return under->xFullPathname(under, n, size, out);
}
static void *vdlopen(sqlite3_vfs *v, const char *n) {
    (void)v;
    return under->xDlOpen(under, n);
}
static void vdlerror(sqlite3_vfs *v, int n, char *out) {
    (void)v;
    under->xDlError(under, n, out);
}
static void (*vdlsym(sqlite3_vfs *v, void *h, const char *n))(void) {
    (void)v;
    return under->xDlSym(under, h, n);
}
static void vdlclose(sqlite3_vfs *v, void *h) {
    (void)v;
    under->xDlClose(under, h);
}
static int vrand(sqlite3_vfs *v, int n, char *buf) {
    (void)v;
    return under->xRandomness(under, n, buf);
}
static int vsleep(sqlite3_vfs *v, int n) {
    (void)v;
    return under->xSleep(under, n);
}
static int vtime(sqlite3_vfs *v, double *t) {
    (void)v;
    return under->xCurrentTime(under, t);
}
static int verror(sqlite3_vfs *v, int n, char *p) {
    (void)v;
    return under->xGetLastError ? under->xGetLastError(under, n, p) : 0;
}
static int vtime64(sqlite3_vfs *v, sqlite3_int64 *t) {
    (void)v;
    return under->xCurrentTimeInt64(under, t);
}
static sqlite3_syscall_ptr original_open;
static void install(void) {
    under = sqlite3_vfs_find("unix");
    ASSERT(under && under->iVersion >= 2);
    if (under->iVersion >= 3 && under->xGetSystemCall && under->xSetSystemCall) {
        original_open = under->xGetSystemCall(under, "open");
        if (original_open) {
            real_open = (int (*)(const char *, int, int))original_open;
            hooked = under->xSetSystemCall(under, "open", (sqlite3_syscall_ptr)syscall_sees) ==
                     SQLITE_OK;
            ASSERT(!hooked ||
                   under->xGetSystemCall(under, "open") == (sqlite3_syscall_ptr)syscall_sees);
        }
    }
    relay = (sqlite3_vfs){.iVersion = 2,
                          .szOsFile = sizeof(File),
                          .mxPathname = under->mxPathname,
                          .zName = "rm-attachment-observer",
                          .xOpen = xopen,
                          .xDelete = vdelete,
                          .xAccess = vaccess,
                          .xFullPathname = vfull,
                          .xDlOpen = under->xDlOpen ? vdlopen : NULL,
                          .xDlError = under->xDlError ? vdlerror : NULL,
                          .xDlSym = under->xDlSym ? vdlsym : NULL,
                          .xDlClose = under->xDlClose ? vdlclose : NULL,
                          .xRandomness = vrand,
                          .xSleep = vsleep,
                          .xCurrentTime = vtime,
                          .xGetLastError = under->xGetLastError ? verror : NULL,
                          .xCurrentTimeInt64 = under->xCurrentTimeInt64 ? vtime64 : NULL};
    ASSERT(sqlite3_vfs_register(&relay, 0) == SQLITE_OK);
}
static int disable_hook(void) {
    if (!hooked)
        return original_open == NULL;
    int rc = under->xSetSystemCall(under, "open", original_open);
    return rc == SQLITE_OK && under->xGetSystemCall(under, "open") == original_open;
}
static void print_id(VnodeID x) {
    printf("[%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "]", x.device, x.inode, x.birth,
           x.nanoseconds);
}
static void pause_observer(void) {
    fflush(stdout);
    ASSERT(getchar() == 'x');
}
static void barrier(const char *phase) {
    printf("{\"event\":\"pause\",\"phase\":\"%s\"}\n", phase);
    pause_observer();
}
static int allowed_sql(void *count, int op, const char *a, const char *b, const char *schema,
                       const char *trigger) {
    (void)a;
    (void)b;
    (void)schema;
    (void)trigger;
    if (op == SQLITE_READ || op == SQLITE_SELECT || op == SQLITE_TRANSACTION)
        return SQLITE_OK;
    (*(int *)count)++;
    return SQLITE_DENY;
}
static void exec(sqlite3 *db, const char *sql) {
    char *message = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &message);
    if (rc != SQLITE_OK)
        fprintf(stderr, "sql %s: %d %s\n", sql, rc, message ? message : "");
    sqlite3_free(message);
    ASSERT(rc == SQLITE_OK);
}
static void marker(sqlite3 *db, const char *expected) {
    sqlite3_stmt *q = NULL;
    ASSERT(sqlite3_prepare_v2(db, "SELECT writer,marker FROM main.probe WHERE id=1", -1, &q,
                              NULL) == SQLITE_OK);
    ASSERT(sqlite3_step(q) == SQLITE_ROW);
    ASSERT(!strcmp((const char *)sqlite3_column_text(q, 0), "same-writer") &&
           !strcmp((const char *)sqlite3_column_text(q, 1), expected));
    ASSERT(sqlite3_step(q) == SQLITE_DONE);
    ASSERT(sqlite3_finalize(q) == SQLITE_OK);
}
static void evidence(sqlite3 *db, int want, int dirty, const char *point) {
    int txn = sqlite3_txn_state(db, "main"), active = txn == want && !sqlite3_get_autocommit(db);
    sqlite3_file *m = NULL, *w = NULL;
    int pm = sqlite3_file_control(db, "main", SQLITE_FCNTL_FILE_POINTER, &m);
    int pw = sqlite3_file_control(db, "main", SQLITE_FCNTL_JOURNAL_POINTER, &w);
    VnodeID wal_now = fd_id(wal_fd), kernel_wal = {0}, shm = {0}, main_now = fd_id(main_fd),
            kernel_main = {0};
    int main_ok = active && mainwrap && m == (sqlite3_file *)mainwrap && pm == SQLITE_OK &&
                  main_fd >= 0 && seen_fd(getpid(), main_fd, &kernel_main) &&
                  identical(main_now, main_opened) && identical(main_now, kernel_main);
    int wal_kernel = wal_fd >= 0 && seen_fd(getpid(), wal_fd, &kernel_wal);
    int shm_kernel = page_length == 32768 && seen_region(getpid(), page0, 32768, &shm);
    int owner = mainwrap && m == (sqlite3_file *)mainwrap && walwrap &&
                w == (sqlite3_file *)walwrap && joined_parent && pm == SQLITE_OK && pw == SQLITE_OK;
    int held_read = shared & (dirty ? 0xF0 : 0xF8);
    int locks = held_read && (want != SQLITE_TXN_WRITE || (exclusive & 1));
    int wat = active && owner && wal_kernel && identical(wal_now, wal_opened) &&
              identical(wal_now, kernel_wal) && (!dirty || wal_reads > 0);
    int sat = active && owner && shm_kernel && locks && page_rc == SQLITE_OK;
    printf("{\"event\":\"cursor\",\"point\":\"%s\",\"txn\":%d,\"wanted\":%d,\"ownersJoined\":%s,"
           "\"hook\":%s,\"walOpens\":%d,\"walCloses\":%d,\"walHookEvents\":%d,"
           "\"fdSnapshotComplete\":%s,\"deltaFd\":%d,\"walFd\":%d,\"walReads\":%d,\"walWrites\":%d,"
           "\"walWitness\":%s,\"walIdentity\":",
           point, txn, want, tf(owner), tf(hooked), wal_opens, wal_closes, wal_hooks,
           tf(snapshots_full), delta_fd, wal_fd, wal_reads, wal_writes, tf(wat));
    print_id(wal_now);
    printf(",\"mainFd\":%d,\"mainDeltaFd\":%d,\"mainHookEvents\":%d,\"mainWitness\":%s,"
           "\"mainIdentity\":",
           main_fd, main_delta, main_hooks, tf(main_ok));
    print_id(main_now);
    printf(",\"shmWitness\":%s,\"shmIdentity\":", tf(sat));
    print_id(shm);
    printf(",\"address\":%" PRIu64
           ",\"length\":%d,\"mapRC\":%d,\"mapCount\":%d,\"unmaps\":%d,\"mapEpoch\":%d,"
           "\"lockEvents\":%d,\"unlockEvents\":%d,\"sharedMask\":%d,\"exclusiveMask\":%d,"
           "\"filePointerRC\":%d,\"journalPointerRC\":%d,\"active\":%s}\n",
           page0, page_length, page_rc, shm_maps, shm_unmaps, shm_epoch, shm_locks, shm_unlocks,
           shared, exclusive, pm, pw, tf(active));
    pause_observer();
}
int main(int argc, char **argv) {
    ASSERT(argc == 5);
    int want = !strcmp(argv[2], "write") ? SQLITE_TXN_WRITE : SQLITE_TXN_READ,
        dirty = !strcmp(argv[3], "dirty");
    int locking = !strcmp(argv[4], "exclusive");
    install();
    barrier("beforeOpen");
    sqlite3 *db = NULL;
    ASSERT(sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX,
                           relay.zName) == SQLITE_OK);
    int actual = -1;
    ASSERT(sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &actual) == SQLITE_OK &&
           actual == 1);
    if (locking)
        exec(db, "PRAGMA locking_mode=EXCLUSIVE");
    int denied = 0;
    ASSERT(sqlite3_set_authorizer(db, allowed_sql, &denied) == SQLITE_OK);
    exec(db, want == SQLITE_TXN_WRITE ? "BEGIN IMMEDIATE" : "BEGIN");
    marker(db, dirty ? "only-in-wal" : "from-main");
    ASSERT(sqlite3_txn_state(db, "main") == want);
    barrier("active");
    evidence(db, want, dirty, "first");
    barrier("second");
    evidence(db, want, dirty, "second");
    barrier("restore");
    marker(db, dirty ? "only-in-wal" : "from-main");
    ASSERT(sqlite3_txn_state(db, "main") == want);
    int changes = (int)sqlite3_total_changes64(db);
    exec(db, "ROLLBACK");
    int after = sqlite3_txn_state(db, "main");
    int read_after = shared, write_after = exclusive;
    ASSERT(sqlite3_close(db) == SQLITE_OK);
    int restored = disable_hook();
    ASSERT(sqlite3_vfs_unregister(&relay) == SQLITE_OK);
    printf("{\"event\":\"end\",\"afterRollback\":%d,\"sharedAfterRollback\":%d,"
           "\"exclusiveAfterRollback\":%d,\"denied\":%d,\"changes\":%d,\"walCloses\":%d,"
           "\"mainCloses\":%d,\"shmUnmaps\":%d,\"lastMapInvalidated\":%s,\"walInvalidated\":%s,"
           "\"restored\":%s,\"sourceID\":\"%s\"}\n",
           after, read_after, write_after, denied, changes, wal_closes, main_closes, shm_unmaps,
           tf(!page0), tf(wal_fd < 0 && !walwrap), tf(restored), sqlite3_sourceid());
    return 0;
}
