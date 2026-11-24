#include "observer-vfs.inc"
#include <limits.h>
typedef struct {
    int attempted, rc, nonnull, released, unfetch_rc, valid;
    uint64_t region_bytes;
    VnodeID id;
} Mapping;
static int map_arm, enforcing, cap_changes, cap_restorations, cap_problems, auto_calls, trace_rows,
    denied_pending, interrupted;
static int64_t limit_before = -1, limit_after = -1, limit_restored = -1, decoy_reported = -1,
               decoy_physical = -1;
static int (*decoy_size_method)(sqlite3_file *, sqlite3_int64 *);
static int captured[3], barrier_fd = -1, opened_barrier, restored_barrier;
static void controller(char phase) {
    char reply = 0;
    REQUIRE(write(barrier_fd, &phase, 1) == 1 && read(barrier_fd, &reply, 1) == 1 && reply == 'x');
}
static VnodeID expected[3];
static char names[3][PATH_MAX];
static void json_id(FILE *f, VnodeID x) {
    fprintf(f, "[%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "]", x.device, x.inode, x.birth,
            x.nanoseconds);
}
static VnodeID read_name(const char *s) {
    struct stat m;
    if (lstat(s, &m) || !S_ISREG(m.st_mode))
        return (VnodeID){0};
    return (VnodeID){(uint32_t)m.st_dev, m.st_ino, (uint64_t)m.st_birthtimespec.tv_sec,
                     (uint64_t)m.st_birthtimespec.tv_nsec};
}
static VnodeID parse_id(const char *s) {
    VnodeID id = {0};
    char tail = 0;
    REQUIRE(sscanf(s, "%" SCNu64 ":%" SCNu64 ":%" SCNu64 ":%" SCNu64 "%c", &id.device, &id.inode,
                   &id.birth, &id.nanoseconds, &tail) == 4);
    REQUIRE(usable(id));
    return id;
}
static void start_cap(File *f) {
    if (!map_arm || !(f->flags & SQLITE_OPEN_WAL))
        return;
    sqlite3_int64 before = -1, request = 4096, after = -1;
    const sqlite3_io_methods *m = f->native->pMethods;
    if (m->xFileControl(f->native, SQLITE_FCNTL_MMAP_SIZE, &before) != SQLITE_OK || before < 0) {
        cap_problems++;
        return;
    }
    f->old_cap = before;
    limit_before = before;
    if (m->xFileControl(f->native, SQLITE_FCNTL_MMAP_SIZE, &request) != SQLITE_OK) {
        cap_problems++;
        return;
    }
    f->cap_set = 1;
    cap_changes++;
    if (m->xFileControl(f->native, SQLITE_FCNTL_MMAP_SIZE, &after) != SQLITE_OK || after != 4096)
        cap_problems++;
    limit_after = after;
}
static void finish_cap(File *f) {
    if (!f->cap_set)
        return;
    sqlite3_int64 requested = f->old_cap, actual = -1;
    const sqlite3_io_methods *m = f->native->pMethods;
    if (m->xFileControl(f->native, SQLITE_FCNTL_MMAP_SIZE, &requested) == SQLITE_OK &&
        m->xFileControl(f->native, SQLITE_FCNTL_MMAP_SIZE, &actual) == SQLITE_OK &&
        actual == f->old_cap)
        cap_restorations++;
    else
        cap_problems++;
    limit_restored = actual;
    f->cap_set = 0;
}
static Mapping fetch_wal(File *w) {
    Mapping r = {.rc = -1, .unfetch_rc = -1};
    if (!map_arm || !w || !w->cap_set)
        return r;
    void *p = NULL;
    r.attempted = 1;
    r.rc = w->native->pMethods->xFetch(w->native, 0, 1, &p);
    if (r.rc != SQLITE_OK || !p)
        return r;
    r.nonnull = 1;
    struct proc_regionwithpathinfo region = {0};
    if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, (uint64_t)(uintptr_t)p, &region,
                     sizeof(region)) == (int)sizeof(region))
        r.region_bytes = region.prp_prinfo.pri_size;
    r.valid = seen_region(getpid(), (uint64_t)(uintptr_t)p, 1, &r.id);
    r.released = 1;
    r.unfetch_rc = w->native->pMethods->xUnfetch(w->native, 0, p);
    if (r.unfetch_rc != SQLITE_OK)
        r.valid = 0;
    return r;
}
static int candidate_count(sqlite3_int64 len, int *only) {
    Snapshot s = snapshot();
    *only = -1;
    if (s.count < 0)
        return -1;
    int matches = 0;
    for (int i = 0; i < s.count; i++) {
        if (s.fds[i].proc_fdtype != PROX_FDTYPE_VNODE)
            continue;
        struct stat st;
        int fd = s.fds[i].proc_fd;
        if (fstat(fd, &st) != 0)
            return -1;
        if (!S_ISREG(st.st_mode))
            continue;
        if (st.st_size == len || (len == 0 && st.st_size == 1)) {
            matches++;
            *only = fd;
        }
    }
    return matches;
}
static int progress(void *unused) {
    (void)unused;
    if (denied_pending) {
        denied_pending = 0;
        interrupted++;
        return 1;
    }
    return 0;
}
static int trace(unsigned type, void *context, void *arg, void *ignore) {
    (void)ignore;
    if (type != SQLITE_TRACE_ROW)
        return 0;
    sqlite3 *db = context;
    sqlite3_stmt *s = arg;
    const char *sql = sqlite3_sql(s);
    if (!sql || !strstr(sql, "SELECT l.value,w.value FROM lc_meta l JOIN metadata w"))
        return 0;
    trace_rows++;
    int state = sqlite3_txn_state(db, "main");
    if (state < 1 || state > 2 || sqlite3_get_autocommit(db) || sqlite3_db_handle(s) != db ||
        captured[state]++)
        return 0;
    if (barrier_fd >= 0 && !opened_barrier) {
        controller('O');
        opened_barrier = 1;
    }
    sqlite3_file *main = NULL, *journal = NULL;
    int mrc = sqlite3_file_control(db, "main", SQLITE_FCNTL_FILE_POINTER, &main),
        jrc = sqlite3_file_control(db, "main", SQLITE_FCNTL_JOURNAL_POINTER, &journal);
    int joined = main && journal && main == (sqlite3_file *)mainwrap &&
                 journal == (sqlite3_file *)walwrap && joined_parent && mrc == SQLITE_OK &&
                 jrc == SQLITE_OK;
    sqlite3_int64 len1 = -1, len2 = -1;
    int rc1 = -1, rc2 = -1;
    if (joined) {
        rc1 = journal->pMethods->xFileSize(journal, &len1);
    }
    int first = -1, last = -1, count1 = rc1 == SQLITE_OK ? candidate_count(len1, &first) : -1;
    Mapping m = joined ? fetch_wal(walwrap) : (Mapping){.rc = -1, .unfetch_rc = -1};
    VnodeID shm = {0};
    int region = page_rc == SQLITE_OK && page_length == 32768 &&
                 seen_region(getpid(), page0, page_length, &shm);
    if (joined) {
        rc2 = journal->pMethods->xFileSize(journal, &len2);
    }
    int count2 = rc2 == SQLITE_OK ? candidate_count(len2, &last) : -1;
    VnodeID direct_main = fd_id(main_fd), delta = fd_id(delta_fd), kernelmain = {0},
            kernelwal = {0};
    int stable_m = main_fd >= 0 && seen_fd(getpid(), main_fd, &kernelmain) &&
                   identical(main_opened, direct_main) && identical(kernelmain, direct_main);
    int stable_w = delta_fd >= 0 && seen_fd(getpid(), delta_fd, &kernelwal) &&
                   identical(wal_opened, delta) && identical(kernelwal, delta);
    int main_named = stable_m && identical(expected[0], direct_main) &&
                     identical(expected[0], read_name(names[0]));
    int wal_current =
        stable_w && identical(expected[1], delta) && identical(expected[1], read_name(names[1]));
    int shm_named =
        region && identical(expected[2], shm) && identical(expected[2], read_name(names[2]));
    int locks = (shared & 0xf8) && (state != SQLITE_TXN_WRITE || (exclusive & 1));
    int unique = joined && snapshots_full && rc1 == SQLITE_OK && rc2 == SQLITE_OK && len1 == len2 &&
                 count1 == 1 && count2 == 1 && first == last && first == delta_fd && stable_w;
    int direct =
        joined && m.valid && identical(m.id, expected[1]) && identical(m.id, delta) && wal_current;
    int strong = main_named && direct && shm_named && locks;
    fprintf(
        stderr,
        "{\"event\":\"context\",\"state\":%d,\"statement\":\"catalog-origin-row\",\"autoCommit\":"
        "false,\"mainWalWrappersJoined\":%s,\"mainScopedCandidateMatches\":%s,"
        "\"walDeltaMatchesTrustedAndPath\":%s,\"shmMapMatchesTrustedAndPath\":%s,\"sharedMask\":%d,"
        "\"exclusiveMask\":%d,\"shmEpoch\":%d,\"shmMapLength\":%d,\"walOpens\":%d,\"walReads\":%d,"
        "\"walSizeBefore\":%lld,\"walSizeAfter\":%lld,\"sizeClassBefore\":%d,\"sizeClassAfter\":%d,"
        "\"uniqueSizeInferenceOnly\":%s,\"mapArm\":%s,\"fetchAttempted\":%d,\"fetchRC\":%d,"
        "\"nonnull\":%d,\"released\":%d,\"unfetchRC\":%d,\"directWalMappingMatches\":%s,"
        "\"shmLocksMatch\":%s,\"strongDiagnostic\":%s,\"mappedWal\":",
        state, tf(joined), tf(main_named), tf(wal_current), tf(shm_named), shared, exclusive,
        shm_epoch, page_length, wal_opens, wal_reads, (long long)len1, (long long)len2, count1,
        count2, tf(unique), tf(map_arm), m.attempted, m.rc, m.nonnull, m.released, m.unfetch_rc,
        tf(direct), tf(locks), tf(strong));
    json_id(stderr, m.id);
    fprintf(stderr,
            ",\"walKernelRegionBytes\":%" PRIu64
            ",\"walFetchOffset\":0,\"walFetchLength\":1,\"sameSizeMethodAsCanary\":%s",
            m.region_bytes,
            tf(decoy_size_method && walwrap &&
               decoy_size_method == walwrap->native->pMethods->xFileSize));
    fputs(",\"actualShm\":", stderr);
    json_id(stderr, shm);
    fputs(",\"actualWalFdCandidate\":", stderr);
    json_id(stderr, delta);
    fprintf(stderr, ",\"namedWalMatchesOriginal\":%s,\"namedShmMatchesOriginal\":%s}\n",
            tf(identical(expected[1], read_name(names[1]))),
            tf(identical(expected[2], read_name(names[2]))));
    if (enforcing && state == SQLITE_TXN_WRITE && !strong && !interrupted) {
        if (barrier_fd >= 0 && !restored_barrier) {
            controller('C');
            restored_barrier = 1;
        }
        denied_pending = 1;
    }
    return 0;
}
static void on_sqlite_connection(void *unused, sqlite3 *db, const char *never_log, int event) {
    (void)unused;
    (void)never_log;
    if (event != 0)
        return;
    const char *actual = sqlite3_db_filename(db, "main");
    if (!actual || strcmp(actual, names[0]))
        return;
    auto_calls++;
    REQUIRE(sqlite3_trace_v2(db, SQLITE_TRACE_ROW, trace, db) == SQLITE_OK);
    if (enforcing)
        sqlite3_progress_handler(db, 1, progress, NULL);
}
int main(int argc, char **argv) {
    REQUIRE(argc == 10);
    const char *pipe_env = getenv("RM_V10_STUDY_PIPE");
    if (pipe_env) {
        barrier_fd = atoi(pipe_env);
        REQUIRE(barrier_fd >= 3);
    }
    REQUIRE(sqlite3_config(SQLITE_CONFIG_SQLLOG, on_sqlite_connection, NULL) == SQLITE_OK);
    Runtime lib = load_runtime(argv[1]);
    map_arm = !strcmp(argv[3], "map");
    enforcing = !strcmp(argv[4], "guard");
    const char *ends[] = {"", "-wal", "-shm"};
    for (int i = 0; i < 3; i++) {
        expected[i] = parse_id(argv[6 + i]);
        int n = snprintf(names[i], sizeof(names[i]), "%s%s", argv[2], ends[i]);
        REQUIRE(n > 0 && (size_t)n < sizeof(names[i]));
    }
    int extra = -1;
    if (strcmp(argv[5], "-")) {
        struct stat info;
        REQUIRE(lstat(argv[5], &info) == 0 && S_ISREG(info.st_mode));
        decoy_physical = info.st_size;
        sqlite3 *canary = NULL;
        REQUIRE(sqlite3_open_v2(argv[5], &canary,
                                SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX,
                                "unix") == SQLITE_OK);
        sqlite3_file *obj = NULL;
        REQUIRE(sqlite3_file_control(canary, "main", SQLITE_FCNTL_FILE_POINTER, &obj) ==
                    SQLITE_OK &&
                obj && obj->pMethods);
        decoy_size_method = obj->pMethods->xFileSize;
        sqlite3_int64 measured = -1;
        REQUIRE(decoy_size_method(obj, &measured) == SQLITE_OK);
        decoy_reported = measured;
        REQUIRE(sqlite3_close(canary) == SQLITE_OK);
        extra = open(argv[5], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        REQUIRE(extra >= 0);
    }
    char *message = NULL;
    size_t cap = 0;
    ssize_t n = getline(&message, &cap, stdin);
    REQUIRE(n > 0 && n < 1048576);
    install();
    RMLibraryBytes out = {0};
    int status = lib.request((const uint8_t *)argv[2], strlen(argv[2]), (const uint8_t *)message,
                             (size_t)n, &out);
    REQUIRE(out.data && out.length);
    printf("{\"status\":%d,\"reply\":", status);
    REQUIRE(fwrite(out.data, 1, out.length, stdout) == out.length);
    fputs("}\n", stdout);
    lib.release(&out);
    free(message);
    REQUIRE(!mainwrap && !walwrap);
    REQUIRE(sqlite3_vfs_register(under, 1) == SQLITE_OK &&
            sqlite3_vfs_unregister(&relay) == SQLITE_OK);
    fprintf(stderr,
            "{\"event\":\"closed\",\"action\":\"%s\",\"system\":\"%s\",\"sourceID\":\"%s\","
            "\"runtimeABI\":1,\"identityFunctionMatches\":true,\"globalSyscallHook\":false,"
            "\"nativeConnectionOpenEvents\":%d,\"contextRows\":%d,\"progressInterrupts\":%d,"
            "\"walClosed\":%d,\"walWrites\":%d,\"mainClosed\":%d,\"shmUnmaps\":%d,\"capChanges\":%"
            "d,\"capRestored\":%d,\"capErrors\":%d,\"mappingInvalidated\":%s,"
            "\"originalWalMmapCap\":%lld,\"activeWalMmapCap\":%lld,\"restoredWalMmapCap\":%lld,"
            "\"decoyPhysicalBytes\":%lld,\"decoyNativeFileSize\":%lld}\n",
            argv[9], sqlite3_libversion(), sqlite3_sourceid(), auto_calls, trace_rows, interrupted,
            wal_closes, wal_writes, main_closes, shm_unmaps, cap_changes, cap_restorations,
            cap_problems, tf(!page0 && wal_fd < 0), (long long)limit_before, (long long)limit_after,
            (long long)limit_restored, (long long)decoy_physical, (long long)decoy_reported);
    if (barrier_fd >= 0) {
        REQUIRE(opened_barrier && restored_barrier);
        REQUIRE(close(barrier_fd) == 0);
    }
    if (extra >= 0)
        REQUIRE(close(extra) == 0);
    return 0;
}
