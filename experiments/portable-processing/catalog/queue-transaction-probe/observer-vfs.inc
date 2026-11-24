#include "abi.h"
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
    sqlite3_int64 old_cap;
    int cap_set;
} File;
typedef struct {
    int count;
    struct proc_fdinfo fds[256];
} Snapshot;
static sqlite3_vfs *under;
static sqlite3_vfs relay;
static File *mainwrap, *walwrap;

static int wal_fd = -1, delta_fd = -1, joined_parent, wal_opens, wal_closes, wal_reads, wal_writes,
           main_closes;
static VnodeID wal_opened, main_opened;
static int main_fd = -1, main_delta = -1;
static uint64_t page0;
static int page_length, page_rc = -1, shared, exclusive, shm_maps, shm_unmaps, shm_locks,
                        shm_unlocks, shm_epoch = 1;
static int snapshots_full;
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
static void finish_cap(File *w);
static int xclose(sqlite3_file *f) {
    File *w = (File *)f;
    finish_cap(w);
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
FWD1(xsync, xSync, int)
FWD1(xsize, xFileSize, sqlite3_int64 *) FWD1(xlock, xLock, int) FWD1(xunlock, xUnlock, int)
    FWD1(xreserved, xCheckReservedLock, int *) FWD0(xsector, xSectorSize)
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
static void start_cap(File *w);
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

    Snapshot pre = {0};
    if (wal || main_db) {

        if (wal)
            joined_parent =
                mainwrap && sqlite3_database_file_object(name) == (sqlite3_file *)mainwrap;
        pre = snapshot();
    }
    int rc = under->xOpen(under, name, w->native, flags, received);
    if (wal || main_db) {

        Snapshot after = snapshot();
        int delta = single_new_fd(&pre, &after);
        int verified = delta;
        if (main_db) {
            main_fd = verified;
            main_delta = delta;

            main_opened = fd_id(delta);
        }
        if (wal) {
            snapshots_full = pre.count >= 0 && after.count >= 0;
            delta_fd = delta;

            wal_opened = fd_id(delta);
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
    if (rc == SQLITE_OK && (wal || main_db))
        start_cap(w);
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
static void install(void) {
    under = sqlite3_vfs_find("unix");
    ASSERT(under && under->iVersion >= 2);
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
    ASSERT(sqlite3_vfs_register(&relay, 1) == SQLITE_OK);
}
