#ifndef RM_CATALOG_PROBE_H
#define RM_CATALOG_PROBE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
/* A read-only research probe on index.sqlite. Success returns a count. */
int64_t rm_probe_count_v1(const char *path, int32_t minimum_rating);
#ifdef __cplusplus
}
#endif
#endif
