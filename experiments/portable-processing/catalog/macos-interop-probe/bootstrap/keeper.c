/* Included after the X2 natural mapping implementation. Only the private
   upstream SQLite in this dedicated executable sees the role-bound open calls.
 */
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
extern int rm_private_owner_bind(int, uint64_t, const char *, int);
extern int rm_private_attest(const int *);
#define CHECK(test)                                                            \
  do {                                                                         \
    if (!(test)) {                                                             \
      fprintf(stderr, "keeper check %d failed (errno %d)\n", __LINE__, errno); \
      return 2;                                                                \
    }                                                                          \
  } while (0)

static int equal_object(const MacFile *a, const MacFile *b) {
  return a->device == b->device && a->inode == b->inode &&
         a->birth_seconds == b->birth_seconds &&
         a->birth_nanos == b->birth_nanos;
}
static int print_query(sqlite3 *db, const char *sql) {
  sqlite3_stmt *q = NULL;
  if (sqlite3_prepare_v2(db, sql, -1, &q, NULL) != SQLITE_OK ||
      sqlite3_step(q) != SQLITE_ROW) {
    sqlite3_finalize(q);
    return 0;
  }
  const unsigned char *v = sqlite3_column_text(q, 0);
  if (!v) {
    sqlite3_finalize(q);
    return 0;
  }
  fputs((const char *)v, stdout);
  return sqlite3_finalize(q) == SQLITE_OK;
}
int main(int argc, char **argv) {
  CHECK(argc == 2);
  const char *path = argv[1];
  int dir = atoi(getenv("RM_DIR_FD")), origin = atoi(getenv("RM_MAIN_FD"));
  CHECK(rm_private_owner_bind(atoi(getenv("RM_OWNER_FD")),
                              strtoull(getenv("RM_OWNER_NONCE"), NULL, 10),
                              path, atoi(getenv("RM_OWNER_PID"))) == 0);
  CHECK(rm_install_mapping_vfs() == SQLITE_OK);
  sqlite3 *db = NULL;
  CHECK(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW,
                        "rm-frozen-map-v1") == SQLITE_OK);
  CHECK(sqlite3_busy_timeout(db, 0) == SQLITE_OK);
  CHECK(sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0; BEGIN IMMEDIATE", NULL,
                     NULL, NULL) == SQLITE_OK);
  sqlite3_stmt *q = NULL;
  const char *query =
      "SELECT json_extract(v,'$.db.h'), json_extract(v,'$.journal.h'), "
      "json_extract(v,'$.db.shm.h'), "
      "json_extract(v,'$.db.shm.sharedMask'), "
      "json_extract(v,'$.db.shm.exclMask'),"
      "json_extract(v,'$.db.vfs')='unix',json_extract(v,'$.journal.vfs')='unix'"
      " FROM (SELECT sqlite_filestat('main') AS v)";
  CHECK(sqlite3_prepare_v2(db, query, -1, &q, NULL) == SQLITE_OK &&
        sqlite3_step(q) == SQLITE_ROW);
  int fds[3], read = sqlite3_column_int(q, 3), write = sqlite3_column_int(q, 4);
  CHECK(sqlite3_column_int(q, 5) && sqlite3_column_int(q, 6) && (read & 0xf8) &&
        (write & 1));
  for (int i = 0; i < 3; i++) {
    CHECK(sqlite3_column_type(q, i) == SQLITE_INTEGER);
    fds[i] = sqlite3_column_int(q, i);
    CHECK(fds[i] >= 3);
  }
  CHECK(sqlite3_finalize(q) == SQLITE_OK &&
        sqlite3_txn_state(db, "main") == SQLITE_TXN_WRITE);
  MacFile root = {0}, known = {0}, actual[3] = {0}, visible = {0};
  const char *names[] = {"library.sqlite", "library.sqlite-wal",
                         "library.sqlite-shm"};
  CHECK(rm_mac_fd(dir, &root) && S_ISDIR(root.mode) &&
        rm_mac_fd(origin, &known) &&
        rm_mac_named(AT_FDCWD, getenv("RM_DIRECTORY"), &visible) &&
        equal_object(&root, &visible));
  for (int i = 0; i < 3; i++) {
    CHECK(rm_mac_fd(fds[i], &actual[i]) && S_ISREG(actual[i].mode) &&
          actual[i].access == O_RDWR);
    CHECK(!memcmp(actual[i].volume, root.volume, 16) &&
          rm_mac_named(dir, names[i], &visible) &&
          equal_object(&actual[i], &visible));
  }
  CHECK(equal_object(&known, &actual[0]) &&
        !memcmp(known.volume, root.volume, 16));
  /* The sole thread blocks inside the IPC exchange. The owner restores all OFD
     offsets and keeps a read-only mapping of the newly authorized SHM before
     returning. */
  CHECK(rm_private_attest(fds) == 0);
  uint64_t mapping[7] = {0};
  CHECK(rm_mac_mapping(db, &actual[2], mapping));
  printf("{\"sourceID\":\"%s\",\"provider\":\"%s\",\"readMask\":%d,"
         "\"writeMask\":%d,\"txn\":%d,"
         "\"mappingBytes\":%" PRIu64 ",\"shareMode\":%" PRIu64
         ",\"walBytes\":%" PRIu64 ",\"objects\":[",
         sqlite3_sourceid(), rm_mac_sqlite_image(), read, write,
         sqlite3_txn_state(db, "main"), mapping[2], mapping[5], actual[1].size);
  for (int i = 0; i < 3; i++)
    printf("%s[%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "]", i ? "," : "",
           actual[i].device, actual[i].inode, actual[i].birth_seconds,
           actual[i].birth_nanos);
  printf("],\"catalog\":");
  CHECK(print_query(
      db,
      "SELECT json_object('libraryID',(SELECT value FROM lc_meta WHERE "
      "key='libraryID'),"
      "'writer',(SELECT value FROM metadata WHERE "
      "key='deviceID'),'schema',(SELECT user_version FROM pragma_user_version),"
      "'journal',(SELECT journal_mode FROM pragma_journal_mode))"));
  puts("}");
  fflush(stdout);
  char command[32];
  while (fgets(command, sizeof(command), stdin)) {
    if (!strcmp(command, "finish\n"))
      break;
    if (!strcmp(command, "release\n")) {
      CHECK(sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL) == SQLITE_OK);
      puts("{\"released\":true}");
    } else if (!strcmp(command, "checkpoint\n")) {
      int log = -1, done = -1,
          rc = sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE,
                                         &log, &done);
      printf("{\"rc\":%d,\"busy\":%d,\"log\":%d,\"checkpointed\":%d}\n", rc,
             rc == SQLITE_BUSY, log, done);
    } else if (!strcmp(command, "ticket\n")) {
      CHECK(print_query(
          db, "SELECT "
              "json_object('state',json_extract(value,'$.state'),'ticket',json_"
              "extract(value,'$.ticket'),"
              "'reservations',(SELECT count(*) FROM lc_workbench_names)) FROM "
              "lc_meta WHERE key GLOB 'wb032.item.v1/*'"));
      putchar('\n');
    } else if (!strcmp(command, "integrity\n")) {
      CHECK(print_query(db, "SELECT json_object('quick',(SELECT quick_check "
                            "FROM pragma_quick_check),'foreign',(SELECT "
                            "count(*) FROM pragma_foreign_key_check))"));
      putchar('\n');
    } else {
      return 2;
    }
    fflush(stdout);
  }
  CHECK(sqlite3_close(db) == SQLITE_OK);
  return 0;
}
