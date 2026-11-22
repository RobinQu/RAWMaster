#ifndef RAWMASTER_LIBRARY_H
#define RAWMASTER_LIBRARY_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct sqlite3 sqlite3;
typedef struct RMLibraryBytes {
    uint8_t *data;
    size_t length;
} RMLibraryBytes;

uint32_t rm_library_abi_version(void);
typedef int (*RMSQLiteVersionFunction)(void);
RMSQLiteVersionFunction rm_library_sqlite_identity_v1(void);
/* Each synchronous call writes owned UTF-8 JSON, including on a domain error.
   Status 0 is success. Inputs are borrowed for the call. Release a result once.
   Standalone reads use their own connections; the path must name the library. */
int32_t rm_library_request_v1(const uint8_t *path, size_t path_length,
                              const uint8_t *request, size_t request_length, RMLibraryBytes *result);
/* The host owns the SQLite connection and its serialization. Mutations require
   an active write transaction. This function never commits or closes it. */
int32_t rm_library_transaction_v1(sqlite3 *database, const uint8_t *request,
                                 size_t request_length, RMLibraryBytes *result);
void rm_library_release_v1(RMLibraryBytes *result);
#ifdef __cplusplus
}
#endif
#endif
