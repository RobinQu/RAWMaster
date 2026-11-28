#ifndef RAWMASTER_CORE_AI_LOADER_H
#define RAWMASTER_CORE_AI_LOADER_H

#include "../../include/rawmaster_core_ai.h"

typedef struct RMCoreAIHost RMCoreAIHost;

RMCoreAIHost *rm_core_ai_host_open(const char *library, const uint8_t *contents, size_t len, int32_t *status);
void rm_core_ai_host_close(RMCoreAIHost *host);
int32_t rm_core_ai_host_evict(RMCoreAIHost *host);
RMCoreAICancellation *rm_core_ai_host_create_cancellation(RMCoreAIHost *host);
void rm_core_ai_host_request_cancellation(RMCoreAIHost *host, RMCoreAICancellation *token);
void rm_core_ai_host_close_cancellation(RMCoreAIHost *host, RMCoreAICancellation *token);
int32_t rm_core_ai_host_embed_face(RMCoreAIHost *host, RMCoreAICancellation *token,
    const RMCoreAIImageV1 *image, const RMCoreAIPointV1 *landmarks, size_t landmark_count,
    float *output, size_t output_len);

#endif
