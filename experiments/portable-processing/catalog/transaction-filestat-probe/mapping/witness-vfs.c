/* Named, private fixture VFS. Only the main file is wrapped. Every underlying
 * file stays intact. */
#include <errno.h>
#include <sqlite3.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

#define RM_PAGE_CONTROL 0x524d50
#define RM_NAME "rm-frozen-map-v1"
typedef struct {
  uint64_t opening, mapping, addr, bytes;
} RmPage;
typedef struct {
  sqlite3_file base;
  sqlite3_file *native;
  RmPage page;
} Main;
static sqlite3_vfs *native_vfs;
static sqlite3_vfs relay;
static atomic_uint_least64_t sequence;
#define W(f) ((Main *)(f))
#define N(f) (W(f)->native)
#define IO(f) (N(f)->pMethods)
static uint64_t next_generation(void) {
  return atomic_fetch_add_explicit(&sequence, 1, memory_order_relaxed) + 1;
}
static int close_main(sqlite3_file *f) {
  Main *w = W(f);
  w->page = (RmPage){0};
  int rc = IO(f)->xClose(N(f));
  sqlite3_free(w->native);
  w->native = 0;
  w->base.pMethods = 0;
  return rc;
}
static int read_main(sqlite3_file *f, void *b, int n, sqlite3_int64 o) {
  return IO(f)->xRead(N(f), b, n, o);
}
static int write_main(sqlite3_file *f, const void *b, int n, sqlite3_int64 o) {
  return IO(f)->xWrite(N(f), b, n, o);
}
#define PASS1(name, type)                                                      \
  static int w##name(sqlite3_file *f, type arg) {                              \
    return IO(f)->name(N(f), arg);                                             \
  }
#define PASS0(name)                                                            \
  static int w##name(sqlite3_file *f) { return IO(f)->name(N(f)); }
// clang-format off
PASS1(xTruncate, sqlite3_int64)
PASS1(xSync, int)
PASS1(xFileSize, sqlite3_int64 *)
PASS1(xLock, int)
PASS1(xUnlock, int)
PASS1(xCheckReservedLock, int *)
PASS0(xSectorSize)
PASS0(xDeviceCharacteristics)
// clang-format on

static int control(sqlite3_file *f, int op, void *arg) {
  if (op == RM_PAGE_CONTROL) {
    *(RmPage *)arg = W(f)->page;
    return SQLITE_OK;
  }
  return IO(f)->xFileControl(N(f), op, arg);
}
static int shm_map(sqlite3_file *f, int page, int bytes, int extend,
                   void volatile **out) {
  Main *w = W(f);
  int rc = IO(f)->xShmMap(N(f), page, bytes, extend, out);
  if (page == 0) {
    if ((rc == SQLITE_OK || rc == SQLITE_READONLY) && out && *out) {
      uintptr_t addr = (uintptr_t)*out;
      if (w->page.addr != addr || w->page.bytes != (uint64_t)bytes)
        w->page.mapping = next_generation();
      w->page.addr = addr;
      w->page.bytes = bytes;
    } else {
      w->page.mapping = 0;
      w->page.addr = 0;
      w->page.bytes = 0;
    }
  }
  return rc;
}
static int shm_lock(sqlite3_file *f, int at, int count, int flags) {
  return IO(f)->xShmLock(N(f), at, count, flags);
}
static void shm_barrier(sqlite3_file *f) { IO(f)->xShmBarrier(N(f)); }
static int shm_unmap(sqlite3_file *f, int remove) {
  Main *w = W(f);
  w->page.mapping = 0;
  w->page.addr = 0;
  w->page.bytes = 0;
  return IO(f)->xShmUnmap(N(f), remove);
}
static int fetch(sqlite3_file *f, sqlite3_int64 off, int count, void **out) {
  return IO(f)->xFetch(N(f), off, count, out);
}
static int unfetch(sqlite3_file *f, sqlite3_int64 off, void *p) {
  return IO(f)->xUnfetch(N(f), off, p);
}
static const sqlite3_io_methods methods = {3,
                                           close_main,
                                           read_main,
                                           write_main,
                                           wxTruncate,
                                           wxSync,
                                           wxFileSize,
                                           wxLock,
                                           wxUnlock,
                                           wxCheckReservedLock,
                                           control,
                                           wxSectorSize,
                                           wxDeviceCharacteristics,
                                           shm_map,
                                           shm_lock,
                                           shm_barrier,
                                           shm_unmap,
                                           fetch,
                                           unfetch};
static int open_file(sqlite3_vfs *v, sqlite3_filename name, sqlite3_file *file,
                     int flags, int *result) {
  (void)v;
  if (!(flags & SQLITE_OPEN_MAIN_DB))
    return native_vfs->xOpen(native_vfs, name, file, flags, result);
  Main *w = W(file);
  memset(w, 0, sizeof(*w));
  w->native = sqlite3_malloc64((sqlite3_uint64)native_vfs->szOsFile);
  if (!w->native)
    return SQLITE_NOMEM;
  memset(w->native, 0, (size_t)native_vfs->szOsFile);
  int rc = native_vfs->xOpen(native_vfs, name, w->native, flags, result);
  const sqlite3_io_methods *m = w->native->pMethods;
  if (rc != SQLITE_OK || !m || m->iVersion < 3 || !m->xShmMap ||
      !m->xShmUnmap || !m->xFetch || !m->xUnfetch) {
    if (m)
      m->xClose(w->native);
    sqlite3_free(w->native);
    w->native = 0;
    return rc == SQLITE_OK ? SQLITE_NOTFOUND : rc;
  }
  w->page.opening = next_generation();
  w->base.pMethods = &methods;
  return SQLITE_OK;
}
static int vdelete(sqlite3_vfs *v, const char *n, int sync) {
  (void)v;
  return native_vfs->xDelete(native_vfs, n, sync);
}
static int vaccess(sqlite3_vfs *v, const char *n, int f, int *out) {
  (void)v;
  return native_vfs->xAccess(native_vfs, n, f, out);
}
static int vfull(sqlite3_vfs *v, const char *n, int size, char *out) {
  (void)v;
  return native_vfs->xFullPathname(native_vfs, n, size, out);
}
static void *vdlopen(sqlite3_vfs *v, const char *n) {
  (void)v;
  return native_vfs->xDlOpen(native_vfs, n);
}
static void vdlerror(sqlite3_vfs *v, int n, char *out) {
  (void)v;
  native_vfs->xDlError(native_vfs, n, out);
}
static void (*vdlsym(sqlite3_vfs *v, void *h, const char *n))(void) {
  (void)v;
  return native_vfs->xDlSym(native_vfs, h, n);
}
static void vdlclose(sqlite3_vfs *v, void *h) {
  (void)v;
  native_vfs->xDlClose(native_vfs, h);
}
static int vrand(sqlite3_vfs *v, int n, char *buf) {
  (void)v;
  return native_vfs->xRandomness(native_vfs, n, buf);
}
static int vsleep(sqlite3_vfs *v, int n) {
  (void)v;
  return native_vfs->xSleep(native_vfs, n);
}
static int vtime(sqlite3_vfs *v, double *t) {
  (void)v;
  return native_vfs->xCurrentTime(native_vfs, t);
}
static int verror(sqlite3_vfs *v, int n, char *p) {
  (void)v;
  return native_vfs->xGetLastError ? native_vfs->xGetLastError(native_vfs, n, p)
                                   : 0;
}
static int vtime64(sqlite3_vfs *v, sqlite3_int64 *t) {
  (void)v;
  return native_vfs->xCurrentTimeInt64(native_vfs, t);
}
int rm_install_mapping_vfs(void) {
  sqlite3_vfs *before = sqlite3_vfs_find(0);
  sqlite3_vfs *existing = sqlite3_vfs_find(RM_NAME);
  if (existing)
    return existing == &relay ? SQLITE_OK : SQLITE_MISUSE;
  native_vfs = sqlite3_vfs_find("unix");
  if (!native_vfs || native_vfs->iVersion < 2)
    return SQLITE_NOTFOUND;
  relay = (sqlite3_vfs){.iVersion = 2,
                        .szOsFile = native_vfs->szOsFile > (int)sizeof(Main)
                                        ? native_vfs->szOsFile
                                        : (int)sizeof(Main),
                        .mxPathname = native_vfs->mxPathname,
                        .zName = RM_NAME,
                        .xOpen = open_file,
                        .xDelete = vdelete,
                        .xAccess = vaccess,
                        .xFullPathname = vfull,
                        .xDlOpen = native_vfs->xDlOpen ? vdlopen : 0,
                        .xDlError = native_vfs->xDlError ? vdlerror : 0,
                        .xDlSym = native_vfs->xDlSym ? vdlsym : 0,
                        .xDlClose = native_vfs->xDlClose ? vdlclose : 0,
                        .xRandomness = vrand,
                        .xSleep = vsleep,
                        .xCurrentTime = vtime,
                        .xGetLastError = native_vfs->xGetLastError ? verror : 0,
                        .xCurrentTimeInt64 =
                            native_vfs->xCurrentTimeInt64 ? vtime64 : 0};
  int rc = sqlite3_vfs_register(&relay, 0);
  return sqlite3_vfs_find(0) == before ? rc : SQLITE_MISUSE;
}
int rm_page_for(sqlite3 *db, RmPage *p) {
  return sqlite3_file_control(db, "main", RM_PAGE_CONTROL, p);
}
/* Linux UAPI struct procmap_query, available on kernels implementing the 6.11
 * ioctl. */
typedef struct {
  uint64_t size, query_flags, query_addr, start, end, flags, page_size, offset,
      inode;
  uint32_t major, minor, name_size, build_size;
  uint64_t name_addr, build_addr;
} RmQuery;
_Static_assert(sizeof(RmQuery) == 104, "Linux UAPI layout");
int rm_query_address(int maps_fd, const RmPage *p, uint64_t device,
                     uint64_t inode) {
  RmQuery q = {.size = sizeof(q), .query_addr = p->addr};
  if (ioctl(maps_fd, _IOWR('f', 17, RmQuery), &q) < 0)
    return -errno;
  if (!p->addr || p->bytes != 32768 || q.start > p->addr || q.end < p->addr ||
      q.end - p->addr < p->bytes || !(q.flags & 1) || !(q.flags & 8) ||
      q.offset != 0 || p->addr != q.start || q.inode != inode ||
      q.major != major((dev_t)device) || q.minor != minor((dev_t)device))
    return 0;
  return 1;
}
