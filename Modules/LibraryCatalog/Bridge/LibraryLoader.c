#include "LibraryLoader.h"
#include "../include/rawmaster_library.h"
#include <dlfcn.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

struct RMLibraryRuntime {
    void *image;
    int32_t (*request)(const uint8_t *, size_t, const uint8_t *, size_t, RMLibraryBytes *);
    int32_t (*transaction)(sqlite3 *, const uint8_t *, size_t, RMLibraryBytes *);
    void (*release)(RMLibraryBytes *);
};

RMLibraryRuntime *rm_host_open(const char *path, char **message) {
    *message = NULL;
    void *image = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!image) {
        const char *detail = dlerror();
        *message = strdup(detail ? detail : "Cannot load the library catalog");
        return NULL;
    }
    RMLibraryRuntime *runtime = calloc(1, sizeof(*runtime));
    if (!runtime) {
        dlclose(image);
        return NULL;
    }
    runtime->image = image;
    uint32_t (*version)(void) = dlsym(image, "rm_library_abi_version");
    RMSQLiteVersionFunction (*sqlite_identity)(void) = dlsym(image, "rm_library_sqlite_identity_v1");
    if (!sqlite_identity || sqlite_identity() != sqlite3_libversion_number) {
        *message = strdup("The host and catalog must use the same SQLite runtime");
        rm_host_close(runtime);
        return NULL;
    }
    runtime->request = dlsym(image, "rm_library_request_v1");
    runtime->transaction = dlsym(image, "rm_library_transaction_v1");
    runtime->release = dlsym(image, "rm_library_release_v1");
    if (!version || version() != 1 || !runtime->request || !runtime->transaction || !runtime->release) {
        *message = strdup("Unsupported RAWMaster library catalog ABI");
        rm_host_close(runtime);
        return NULL;
    }
    return runtime;
}

void rm_host_free_message(char *message) { free(message); }

void rm_host_close(RMLibraryRuntime *runtime) {
    if (runtime) {
        dlclose(runtime->image);
        free(runtime);
    }
}

int32_t rm_host_request(const RMLibraryRuntime *runtime, const uint8_t *path, size_t path_length,
                        const uint8_t *json, size_t json_length, RMHostReply *reply) {
    RMLibraryBytes buffer = {0};
    int32_t status = runtime->request(path, path_length, json, json_length, &buffer);
    *reply = (RMHostReply){buffer.data, buffer.length};
    return status;
}

int32_t rm_host_transaction(const RMLibraryRuntime *runtime, void *sqlite_handle,
                            const uint8_t *json, size_t json_length, RMHostReply *reply) {
    RMLibraryBytes buffer = {0};
    int32_t status = runtime->transaction(sqlite_handle, json, json_length, &buffer);
    *reply = (RMHostReply){buffer.data, buffer.length};
    return status;
}

void rm_host_release(const RMLibraryRuntime *runtime, RMHostReply *reply) {
    RMLibraryBytes buffer = {reply->data, reply->length};
    runtime->release(&buffer);
    *reply = (RMHostReply){0};
}
