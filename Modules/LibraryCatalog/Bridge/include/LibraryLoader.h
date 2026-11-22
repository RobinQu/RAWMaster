#ifndef RAWMASTER_LIBRARY_LOADER_H
#define RAWMASTER_LIBRARY_LOADER_H
#include <stdint.h>
#include <stddef.h>

typedef struct RMLibraryRuntime RMLibraryRuntime;
typedef struct RMHostReply {
    uint8_t *data;
    size_t length;
} RMHostReply;
RMLibraryRuntime *rm_host_open(const char *image_path, char **message);
void rm_host_free_message(char *message);
void rm_host_close(RMLibraryRuntime *runtime);
int32_t rm_host_request(const RMLibraryRuntime *runtime, const uint8_t *path, size_t path_length,
                        const uint8_t *json, size_t json_length, RMHostReply *reply);
int32_t rm_host_transaction(const RMLibraryRuntime *runtime, void *sqlite_handle,
                            const uint8_t *json, size_t json_length, RMHostReply *reply);
void rm_host_release(const RMLibraryRuntime *runtime, RMHostReply *reply);
#endif
