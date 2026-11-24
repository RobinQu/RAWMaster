/* Only Apple SQLite in this executable. All fixtures and their SQL are
 * compile-time selected. */
#include "abi.h"
#include <fcntl.h>
#include <inttypes.h>
#include <sys/mount.h>
#include <sys/stat.h>
static int marker(sqlite3 *db) {
  sqlite3_stmt *s = 0;
  REQUIRE(
      sqlite3_prepare_v2(db,
                         "SELECT coalesce((SELECT CAST(value AS INTEGER) FROM "
                         "lc_meta WHERE key='fixture.interop.marker'),0)",
                         -1, &s, 0) == SQLITE_OK);
  REQUIRE(sqlite3_step(s) == SQLITE_ROW);
  int v = sqlite3_column_int(s, 0);
  REQUIRE(sqlite3_finalize(s) == SQLITE_OK);
  return v;
}
static void locks(int fd, off_t offset, int ofd) {
  struct flock q = {
      .l_start = offset, .l_len = 1, .l_whence = SEEK_SET, .l_type = F_WRLCK};
  REQUIRE(fcntl(fd, ofd ? F_OFD_GETLK : F_GETLK, &q) == 0);
  printf("{\"type\":%d,\"pid\":%d,\"start\":%lld,\"length\":%lld}", q.l_type,
         q.l_pid, q.l_start, q.l_len);
}
int main(int argc, char **argv) {
  REQUIRE(argc >= 2);
  if (!strcmp(argv[1], "locks")) {
    REQUIRE(argc == 4);
    int mainfd = atoi(argv[2]), shmfd = atoi(argv[3]);
    printf("{\"observerPID\":%d,\"locks\":[", getpid());
    int slots[] = {1073741826, 120, 123, 124, 125, 126, 127, 128};
    for (int i = 0; i < 8; i++) {
      if (i)
        putchar(',');
      printf("{\"offset\":%d,\"posix\":", slots[i]);
      locks(i ? shmfd : mainfd, slots[i], 0);
      printf(",\"ofd\":");
      locks(i ? shmfd : mainfd, slots[i], 1);
      putchar('}');
    }
    puts("]}");
    return 0;
  }
  REQUIRE(argc == 3);
  Runtime r = load_runtime(argv[1]);
  (void)r;
  sqlite3 *db = 0;
  REQUIRE(sqlite3_open_v2(argv[2], &db,
                          SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW,
                          NULL) == SQLITE_OK);
  sqlite3_busy_timeout(db, 0);
  exec_sql(db, "PRAGMA wal_autocheckpoint=0;PRAGMA foreign_keys=ON");
  Dl_info src = {0};
  REQUIRE(dladdr((void *)sqlite3_libversion_number, &src) && src.dli_fname);
  sqlite3_stmt *unsupported = 0;
  int fs = sqlite3_prepare_v2(db, "SELECT sqlite_filestat('main')", -1,
                              &unsupported, 0);
  if (unsupported)
    sqlite3_finalize(unsupported);
  printf("{\"pid\":%d,\"sqliteVersion\":%d,\"sourceID\":\"%s\",\"image\":\"%"
         "s\",\"sameSQLiteFunction\":true,\"filestatPrepareRC\":%d}\n",
         getpid(), sqlite3_libversion_number(), sqlite3_sourceid(),
         src.dli_fname, fs);
  fflush(stdout);
  char line[32];
  while (fgets(line, sizeof(line), stdin)) {
    line[strcspn(line, "\n")] = 0;
    if (!strcmp(line, "finish"))
      break;
    const char *sql =
        !strcmp(line, "read")       ? "BEGIN"
        : !strcmp(line, "write")    ? "BEGIN IMMEDIATE"
        : !strcmp(line, "commit")   ? "COMMIT"
        : !strcmp(line, "rollback") ? "ROLLBACK"
        : !strcmp(line, "bump")
            ? "INSERT INTO lc_meta(key,value) "
              "VALUES('fixture.interop.marker','1') ON CONFLICT(key) DO UPDATE "
              "SET value=CAST(value AS INTEGER)+1"
        : !strcmp(line, "marker") ? "SELECT 1"
                                  : 0;
    REQUIRE(sql);
    int rc = sqlite3_exec(db, sql, 0, 0, 0);
    if (rc == SQLITE_OK) {
      int value = marker(db);
      printf("{\"rc\":0,\"state\":%d,\"marker\":%d}\n",
             sqlite3_txn_state(db, "main"), value);
    } else
      printf("{\"rc\":%d,\"state\":%d,\"marker\":null}\n", rc,
             sqlite3_txn_state(db, "main"));
    fflush(stdout);
  }
  REQUIRE(sqlite3_close(db) == SQLITE_OK);
  return 0;
}
