#ifndef QUEUE_ABI_HELPERS
#define QUEUE_ABI_HELPERS
#include "rawmaster_library.h"
#include <dlfcn.h>
#include <errno.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define REQUIRE(e)                                                                                 \
    do {                                                                                           \
        if (!(e)) {                                                                                \
            fprintf(stderr, "fixture invariant failed line %d: %s (errno=%d)\n", __LINE__, #e,     \
                    errno);                                                                        \
            exit(2);                                                                               \
        }                                                                                          \
    } while (0)
typedef struct {
    void *handle;
    int32_t (*request)(const uint8_t *, size_t, const uint8_t *, size_t, RMLibraryBytes *);
    int32_t (*tx)(sqlite3 *, const uint8_t *, size_t, RMLibraryBytes *);
    void (*release)(RMLibraryBytes *);
} Runtime;
static inline Runtime load_runtime(const char *path) {
    Runtime r = {0};
    r.handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    REQUIRE(r.handle);
    RMSQLiteVersionFunction (*identity)(void) = dlsym(r.handle, "rm_library_sqlite_identity_v1");
    uint32_t (*version)(void) = dlsym(r.handle, "rm_library_abi_version");
    r.request = dlsym(r.handle, "rm_library_request_v1");
    r.tx = dlsym(r.handle, "rm_library_transaction_v1");
    r.release = dlsym(r.handle, "rm_library_release_v1");
    REQUIRE(identity && identity() == sqlite3_libversion_number && version && version() == 1 &&
            r.request && r.tx && r.release);
    return r;
}
static inline void exec_sql(sqlite3 *db, const char *sql) {
    char *message = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &message);
    if (rc != SQLITE_OK)
        fprintf(stderr, "fixture SQL status %d\n", rc);
    sqlite3_free(message);
    REQUIRE(rc == SQLITE_OK);
}
static inline void setup_transaction(Runtime *r, sqlite3 *db, const char *message) {
    RMLibraryBytes b = {0};
    int rc = r->tx(db, (const uint8_t *)message, strlen(message), &b);
    REQUIRE(b.data && b.length);
    r->release(&b);
    REQUIRE(rc == 0);
}
#endif
