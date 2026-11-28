#include "CoreAILoader.h"

#include <dlfcn.h>
#include <stdlib.h>

struct RMCoreAIHost {
    void *library;
    RMCoreAIEngine *engine;
    void (*close)(RMCoreAIEngine *);
    int32_t (*evict)(const RMCoreAIEngine *);
    RMCoreAICancellation *(*create_cancellation)(void);
    int32_t (*request_cancellation)(const RMCoreAICancellation *);
    void (*close_cancellation)(RMCoreAICancellation *);
    int32_t (*embed_face)(const RMCoreAIEngine *, const RMCoreAICancellation *, const RMCoreAIImageV1 *,
        const RMCoreAIPointV1 *, size_t, float *, size_t);
};

RMCoreAIHost *rm_core_ai_host_open(const char *path, const uint8_t *contents, size_t len, int32_t *status) {
    if (!status) return NULL;
    *status = RM_CORE_AI_INCOMPATIBLE_RUNTIME;
    if (!path || path[0] != '/') return NULL;
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_NODELETE);
    if (!library) return NULL;
    uint32_t (*version)(void) = dlsym(library, "rm_core_ai_abi_version");
    if (!version || version() != 1) {
        dlclose(library);
        return NULL;
    }
    RMCoreAIHost *host = calloc(1, sizeof(*host));
    if (!host) {
        dlclose(library);
        *status = RM_CORE_AI_INTERNAL;
        return NULL;
    }
    host->library = library;
    int32_t (*open)(const uint8_t *, size_t, RMCoreAIEngine **) = dlsym(library, "rm_core_ai_open_v1");
    host->close = dlsym(library, "rm_core_ai_close_v1");
    host->evict = dlsym(library, "rm_core_ai_evict_v1");
    host->create_cancellation = dlsym(library, "rm_core_ai_cancellation_create_v1");
    host->request_cancellation = dlsym(library, "rm_core_ai_cancellation_request_v1");
    host->close_cancellation = dlsym(library, "rm_core_ai_cancellation_close_v1");
    host->embed_face = dlsym(library, "rm_core_ai_embed_face_v1");
    if (!open || !host->close || !host->evict || !host->create_cancellation || !host->request_cancellation ||
        !host->close_cancellation || !host->embed_face) {
        rm_core_ai_host_close(host);
        return NULL;
    }
    *status = open(contents, len, &host->engine);
    if (*status != RM_CORE_AI_OK || !host->engine) {
        rm_core_ai_host_close(host);
        if (*status == RM_CORE_AI_OK) *status = RM_CORE_AI_INTERNAL;
        return NULL;
    }
    return host;
}

void rm_core_ai_host_close(RMCoreAIHost *host) {
    if (!host) return;
    if (host->engine) host->close(host->engine);
    dlclose(host->library);
    free(host);
}

int32_t rm_core_ai_host_evict(RMCoreAIHost *host) {
    return host->evict(host->engine);
}

RMCoreAICancellation *rm_core_ai_host_create_cancellation(RMCoreAIHost *host) {
    return host->create_cancellation();
}

void rm_core_ai_host_request_cancellation(RMCoreAIHost *host, RMCoreAICancellation *token) {
    host->request_cancellation(token);
}

void rm_core_ai_host_close_cancellation(RMCoreAIHost *host, RMCoreAICancellation *token) {
    host->close_cancellation(token);
}

int32_t rm_core_ai_host_embed_face(RMCoreAIHost *host, RMCoreAICancellation *token,
    const RMCoreAIImageV1 *image, const RMCoreAIPointV1 *landmarks, size_t landmark_count,
    float *output, size_t output_len) {
    return host->embed_face(host->engine, token, image, landmarks, landmark_count, output, output_len);
}
