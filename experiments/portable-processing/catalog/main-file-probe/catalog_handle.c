#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <sqlite3.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

#define MARKER "identical-frozen-batch-receipt"
#define WRITER "identical-catalog-writer"
#define FETCH_LEN 100
#define FETCH_OFFSET ((sqlite3_int64)0)
#define GUARD(cond) do { if (!(cond)) { fprintf(stderr, "fixture failed at line %d: %s; errno %d\n", __LINE__, #cond, errno); exit(2); } } while (0)

static const char *yn(bool value) { return value ? "true" : "false"; }
static void quote(const char *str) {
    putchar('"');
    for (; *str; str++) {
        unsigned char c = (unsigned char)*str;
        if (c == '"' || c == '\\') printf("\\%c", c);
        else if (c < 32) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}
typedef struct {
    uint32_t dev;
    uint64_t ino;
    int64_t born, ns;
    int mode;
} Identity;
static Identity id_stat(const struct stat *s) {
    return (Identity){(uint32_t)s->st_dev, (uint64_t)s->st_ino,
                      s->st_birthtimespec.tv_sec, s->st_birthtimespec.tv_nsec, s->st_mode};
}
static Identity id_vnode(const struct vinfo_stat *s) {
    return (Identity){s->vst_dev, s->vst_ino, s->vst_birthtime, s->vst_birthtimensec, s->vst_mode};
}
static void print_id(Identity v) {
    printf("{\"device\":%u,\"inode\":%" PRIu64 ",\"birthSeconds\":%" PRId64
           ",\"birthNanoseconds\":%" PRId64 ",\"mode\":%d}", v.dev, v.ino, v.born, v.ns, v.mode);
}
static bool valid(Identity v) {
    return S_ISREG(v.mode) && v.ino != 0 && v.born > 0 && v.ns >= 0 && v.ns < 1000000000;
}
static bool same_live(Identity a, Identity b) {
    return S_ISREG(a.mode) && S_ISREG(b.mode) && a.ino && a.dev == b.dev && a.ino == b.ino;
}
static bool same(Identity a, Identity b) {
    return valid(a) && valid(b) && same_live(a, b) && a.born == b.born && a.ns == b.ns;
}
static bool contains(uint64_t start, uint64_t length, uint64_t p, uint64_t count) {
    return p >= start && count <= length && p - start <= length - count;
}
static sqlite3_int64 query_integer(sqlite3 *db, const char *sql) {
    sqlite3_stmt *s = NULL;
    GUARD(sqlite3_prepare_v2(db, sql, -1, &s, NULL) == SQLITE_OK);
    GUARD(sqlite3_step(s) == SQLITE_ROW);
    sqlite3_int64 result = sqlite3_column_int64(s, 0);
    GUARD(sqlite3_step(s) == SQLITE_DONE);
    GUARD(sqlite3_finalize(s) == SQLITE_OK);
    return result;
}
static void set_cap(sqlite3 *db, sqlite3_int64 cap) {
    char sql[96];
    int n = snprintf(sql, sizeof(sql), "PRAGMA main.mmap_size=%lld", (long long)cap);
    GUARD(n > 0 && (size_t)n < sizeof(sql));
    GUARD(sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK);
}
// Only this fixture's SELECT, explicit transactions and controlled mmap PRAGMA are needed.
static int restrict_sql(void *opaque, int op, const char *arg1, const char *arg2,
                        const char *schema, const char *trigger) {
    (void)arg2; (void)schema; (void)trigger;
    if (op == SQLITE_SELECT || op == SQLITE_READ || op == SQLITE_TRANSACTION ||
        (op == SQLITE_PRAGMA && arg1 && !strcmp(arg1, "mmap_size"))) return SQLITE_OK;
    (*(int *)opaque)++;
    return SQLITE_DENY;
}
static bool read_marker(sqlite3 *db) {
    sqlite3_stmt *s = NULL;
    GUARD(sqlite3_prepare_v2(db, "SELECT deviceID, marker FROM main.probe WHERE id=1", -1, &s, NULL) == SQLITE_OK);
    GUARD(sqlite3_step(s) == SQLITE_ROW);
    const unsigned char *writer = sqlite3_column_text(s, 0), *marker = sqlite3_column_text(s, 1);
    bool ok = writer && marker && !strcmp((const char *)writer, WRITER) && !strcmp((const char *)marker, MARKER);
    GUARD(sqlite3_step(s) == SQLITE_DONE);
    GUARD(sqlite3_finalize(s) == SQLITE_OK);
    return ok;
}
static bool proof(sqlite3 *db, int expected_txn, int held, int dir, const char *point, bool inject_proc_reject) {
    const int txn = sqlite3_txn_state(db, "main");
    const bool in_txn = !sqlite3_get_autocommit(db) && txn == expected_txn && txn != SQLITE_TXN_NONE;
    struct stat h, p, late_p;
    GUARD(fstat(held, &h) == 0);
    GUARD(fstatat(dir, "live/db.sqlite", &p, AT_SYMLINK_NOFOLLOW) == 0);
    const Identity held_id = id_stat(&h), path_id = id_stat(&p);
    Identity mapped = {0};
    struct proc_regionwithpathinfo r = {0};
    sqlite3_file *file = NULL;
    int pre_moved = -1, post_moved = -1, pre_rc = -1, post_rc = -1, file_rc = -1, fetch_rc = -1, release_rc = -1;
    int abi = 0, bytes = -1, proc_errno = 0, fetched = 0, released = 0;
    uint64_t offset_in_region = 0;
    bool in_range = false, file_offset_matches = false, regular_vnode = false;
    if (in_txn) {
        pre_rc = sqlite3_file_control(db, "main", SQLITE_FCNTL_HAS_MOVED, &pre_moved);
        file_rc = sqlite3_file_control(db, "main", SQLITE_FCNTL_FILE_POINTER, &file);
        if (file_rc == SQLITE_OK && file && file->pMethods) {
            const sqlite3_io_methods *io = file->pMethods;
            abi = io->iVersion;
            if (abi >= 3 && io->xFetch && io->xUnfetch) {
                void *mapping = NULL;
                fetched++;
                fetch_rc = io->xFetch(file, FETCH_OFFSET, FETCH_LEN, &mapping);
                if (mapping) {
                    if (fetch_rc == SQLITE_OK) {
                        uint64_t address = (uint64_t)(uintptr_t)mapping;
                        errno = 0;
                        bytes = proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, address, &r, sizeof(r));
                        proc_errno = bytes == (int)sizeof(r) ? 0 : errno;
                        if (bytes == (int)sizeof(r)) {
                            mapped = id_vnode(&r.prp_vip.vip_vi.vi_stat);
                            regular_vnode = r.prp_vip.vip_vi.vi_type == VREG && S_ISREG(mapped.mode);
                            in_range = contains(r.prp_prinfo.pri_address, r.prp_prinfo.pri_size, address, FETCH_LEN);
                            if (in_range) {
                                offset_in_region = address - r.prp_prinfo.pri_address;
                                uint64_t requested = (uint64_t)FETCH_OFFSET;
                                file_offset_matches = r.prp_prinfo.pri_offset <= requested &&
                                    offset_in_region == requested - r.prp_prinfo.pri_offset;
                            }
                        }
                    }
                    // Even a failed identity/range validation releases its original nonnull borrow exactly once.
                    released++;
                    release_rc = io->xUnfetch(file, FETCH_OFFSET, mapping);
                }
            }
        }
        post_rc = sqlite3_file_control(db, "main", SQLITE_FCNTL_HAS_MOVED, &post_moved);
    }
    GUARD(fstatat(dir, "live/db.sqlite", &late_p, AT_SYMLINK_NOFOLLOW) == 0);
    const Identity late = id_stat(&late_p);
    const bool region_ok = in_range && file_offset_matches && regular_vnode && !inject_proc_reject;
    const bool ok = in_txn && !sqlite3_get_autocommit(db) && sqlite3_txn_state(db, "main") == txn
        && pre_rc == SQLITE_OK && pre_moved == 0 && post_rc == SQLITE_OK && post_moved == 0
        && file_rc == SQLITE_OK && fetch_rc == SQLITE_OK && released == 1 && release_rc == SQLITE_OK
        && region_ok && same(held_id, path_id) && same(held_id, late) && same(mapped, held_id) && same(mapped, late);
    printf("{\"event\":\"proof\",\"point\":"); quote(point);
    printf(",\"allowed\":%s,\"txn\":%d,\"requiredTxn\":%d,\"autocommit\":%s,\"held\":", yn(ok), txn, expected_txn, yn(sqlite3_get_autocommit(db)));
    print_id(held_id); printf(",\"path\":"); print_id(path_id); printf(",\"latePath\":"); print_id(late);
    printf(",\"mapped\":"); print_id(mapped);
    printf(",\"filePointerRC\":%d,\"ioVersion\":%d,\"preMovedRC\":%d,\"preMoved\":%d,\"postMovedRC\":%d,\"postMoved\":%d"
           ",\"fetchOffset\":0,\"fetchLength\":%d,\"fetchCount\":%d,\"fetchRC\":%d,\"borrowed\":%s,\"unfetchCount\":%d,\"unfetchRC\":%d"
           ",\"regionBytes\":%d,\"expectedRegionBytes\":%zu,\"regionErrno\":%d,\"regionLength\":%" PRIu64
           ",\"offsetInRegion\":%" PRIu64 ",\"regionFileOffset\":%" PRIu64 ",\"contained\":%s,\"mappedFileOffsetMatchesRequest\":%s,\"vnodeType\":%d,\"vnodeRegular\":%s"
           ",\"mapDevInoMatchesHeld\":%s,\"mapDevInoMatchesPath\":%s,\"mapMatchesHeld\":%s,\"mapMatchesPath\":%s"
           ",\"pathMatchesHeld\":%s,\"injectedProcRejection\":%s}\n",
           file_rc, abi, pre_rc, pre_moved, post_rc, post_moved, FETCH_LEN, fetched, fetch_rc, yn(released > 0), released, release_rc,
           bytes, sizeof(r), proc_errno, r.prp_prinfo.pri_size, offset_in_region, r.prp_prinfo.pri_offset, yn(in_range), yn(file_offset_matches), r.prp_vip.vip_vi.vi_type,
           yn(regular_vnode), yn(same_live(mapped, held_id)), yn(same_live(mapped, late)), yn(same(mapped, held_id)), yn(same(mapped, late)),
           yn(same(held_id, late)), yn(inject_proc_reject));
    return ok;
}
static void set_swap(int dir, bool file_only, bool *swapped, bool requested) {
    if (*swapped == requested) return;
    GUARD(renameatx_np(dir, file_only ? "live/db.sqlite" : "live", dir, file_only ? "peer/db.sqlite" : "peer", RENAME_SWAP) == 0);
    *swapped = requested;
}
int main(int argc, char **argv) {
    GUARD(argc == 3);
    const char *c = argv[1]; bool file_only = strstr(c, "file-") != NULL;
    bool before = strstr(c, "before-open") != NULL, after = strstr(c, "after-open") != NULL;
    bool aba = strstr(c, "decoy-return") != NULL, double_proof = strstr(c, "after-verified") != NULL;
    bool no_txn = !strcmp(c, "no-txn"), no_mmap = !strcmp(c, "no-mmap"), inject = !strcmp(c, "injected-proc-reject");
    bool write = !strcmp(c, "write") || double_proof;
    const int required = write ? SQLITE_TXN_WRITE : SQLITE_TXN_READ;
    char location[PATH_MAX];
    int n = snprintf(location, sizeof(location), "%s/live/db.sqlite", argv[2]);
    GUARD(n > 0 && (size_t)n < sizeof(location));
    int dir = open(argv[2], O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC);
    GUARD(dir >= 0);
    int held = openat(dir, "live/db.sqlite", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    GUARD(held >= 0);
    struct statfs fs; GUARD(fstatfs(held, &fs) == 0);
    bool swapped = false, opened_swapped = before || aba;
    set_swap(dir, file_only, &swapped, opened_swapped);
    sqlite3 *db = NULL;
    GUARD(sqlite3_open_v2(location, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) == SQLITE_OK);
    int rejected_statements = 0;
    GUARD(sqlite3_set_authorizer(db, restrict_sql, &rejected_statements) == SQLITE_OK);
    char *vfs = NULL;
    int vfs_rc = sqlite3_file_control(db, "main", SQLITE_FCNTL_VFSNAME, &vfs);
    sqlite3_int64 old_cap = query_integer(db, "PRAGMA main.mmap_size");
    set_cap(db, no_mmap ? 0 : 4096);
    sqlite3_int64 cap = query_integer(db, "PRAGMA main.mmap_size");
    printf("{\"event\":\"environment\",\"case\":"); quote(c);
    printf(",\"systemSQLite\":"); quote(sqlite3_libversion());
    printf(",\"sqliteSourceID\":"); quote(sqlite3_sourceid());
    printf(",\"sqliteSDKVersion\":"); quote(SQLITE_VERSION);
    printf(",\"vfs\":"); quote(vfs ? vfs : "unavailable"); sqlite3_free(vfs);
    printf(",\"vfsNameRC\":%d,\"filesystem\":", vfs_rc); quote(fs.f_fstypename);
    printf(",\"originalMmapLimit\":%lld,\"activeMmapLimit\":%lld}\n", (long long)old_cap, (long long)cap);
    if (!no_txn) GUARD(sqlite3_exec(db, write ? "BEGIN IMMEDIATE" : "BEGIN", NULL, NULL, NULL) == SQLITE_OK);
    bool marker_ok = read_marker(db);
    GUARD(marker_ok);
    GUARD(sqlite3_txn_state(db, "main") == (no_txn ? SQLITE_TXN_NONE : required));
    if (double_proof) (void)proof(db, required, held, dir, "initial", false);
    if (after || double_proof) set_swap(dir, file_only, &swapped, true);
    if (aba) set_swap(dir, file_only, &swapped, false);
    (void)proof(db, required, held, dir, "command", inject);
    set_swap(dir, file_only, &swapped, opened_swapped);
    sqlite3_int64 changes = sqlite3_total_changes64(db);
    int end_rc = no_txn ? SQLITE_OK : sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
    GUARD(end_rc == SQLITE_OK);
    set_cap(db, old_cap);
    sqlite3_int64 restored = query_integer(db, "PRAGMA main.mmap_size");
    int close_rc = sqlite3_close(db);
    GUARD(close_rc == SQLITE_OK);
    set_swap(dir, file_only, &swapped, false);
    GUARD(close(held) == 0 && close(dir) == 0);
    printf("{\"event\":\"teardown\",\"markerMatches\":%s,\"changes\":%lld,\"forbiddenSQLRequests\":%d,\"rollbackRC\":%d,\"closeRC\":%d,\"restoredMmapLimit\":%lld}\n",
           yn(marker_ok), (long long)changes, rejected_statements, end_rc, close_rc, (long long)restored);
    return 0;
}
