#include "abi.h"
#include <sys/stat.h>
static char *fixture_ddl(const char *name) {
    FILE *f = fopen(name, "rb");
    REQUIRE(f);
    REQUIRE(fseek(f, 0, SEEK_END) == 0);
    long size = ftell(f);
    REQUIRE(size > 0 && size < 16000000);
    rewind(f);
    char *text = calloc((size_t)size + 1, 1);
    REQUIRE(text && fread(text, 1, (size_t)size, f) == (size_t)size);
    REQUIRE(fclose(f) == 0);
    return text;
}
int main(int argc, char **argv) {
    REQUIRE(argc == 4);
    Runtime lib = load_runtime(argv[1]);
    sqlite3 *db = NULL;
    REQUIRE(sqlite3_open_v2(argv[2], &db,
                            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW,
                            NULL) == SQLITE_OK);
    exec_sql(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA foreign_keys=ON; "
                 "BEGIN IMMEDIATE");
    char *ddl = fixture_ddl(argv[3]);
    exec_sql(db, ddl);
    free(ddl);
    setup_transaction(&lib, db, "{\"operation\":\"install\"}");
    exec_sql(db, "PRAGMA user_version=8; COMMIT; BEGIN IMMEDIATE");
    setup_transaction(&lib, db, "{\"operation\":\"upgradeScheduler\"}");
    exec_sql(
        db,
        "COMMIT; INSERT INTO metadata(key,value) VALUES('deviceID','controlled-fixture-writer');");
    sqlite3_stmt *q = NULL;
    REQUIRE(sqlite3_prepare_v2(db,
                               "SELECT value,(SELECT user_version FROM pragma_user_version) FROM "
                               "lc_meta WHERE key='libraryID'",
                               -1, &q, NULL) == SQLITE_OK);
    REQUIRE(sqlite3_step(q) == SQLITE_ROW);
    printf("{\"library\":\"%s\",\"version\":%d,\"sourceID\":\"%s\",\"abiIdentityMatches\":true}\n",
           sqlite3_column_text(q, 0), sqlite3_column_int(q, 1), sqlite3_sourceid());
    REQUIRE(sqlite3_finalize(q) == SQLITE_OK);
    fflush(stdout);
    char buf[32];
    while (fgets(buf, sizeof(buf), stdin)) {
        if (!strcmp(buf, "finish\n"))
            break;
        if (!strcmp(buf, "ticket\n")) {
            sqlite3_stmt *entry = NULL;
            const char *query =
                "SELECT json_extract(value,'$.state'),json_extract(value,'$.ticket'),(SELECT "
                "count(*) FROM lc_workbench_names) FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'";
            REQUIRE(sqlite3_prepare_v2(db, query, -1, &entry, NULL) == SQLITE_OK &&
                    sqlite3_step(entry) == SQLITE_ROW);
            printf("{\"state\":\"%s\",\"ticket\":%s,\"reservations\":%d}\n",
                   sqlite3_column_text(entry, 0), sqlite3_column_text(entry, 1),
                   sqlite3_column_int(entry, 2));
            REQUIRE(sqlite3_step(entry) == SQLITE_DONE && sqlite3_finalize(entry) == SQLITE_OK);
            fflush(stdout);
            continue;
        }
        REQUIRE(!strcmp(buf, "truncate\n"));
        int log = -1, done = -1;
        int rc = sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, &log, &done);
        printf("{\"checkpointRC\":%d,\"log\":%d,\"done\":%d}\n", rc, log, done);
        fflush(stdout);
    }
    REQUIRE(sqlite3_close(db) == SQLITE_OK);
    return 0;
}
