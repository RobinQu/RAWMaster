#ifndef RAWMASTER_QUEUE_PROBE_H
#define RAWMASTER_QUEUE_PROBE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* UTF-8, NUL-terminated. Inputs are borrowed until return. Both success
   and error replies are owned by the caller; release them with rmq_release_v1.
   Use a dedicated disposable database, not an application library. */
uint32_t rmq_abi_version(void);
char *rmq_request_v1(const char *db_path, const char *request_json);
void rmq_release_v1(char *reply);
#ifdef __cplusplus
}
#endif
#endif
