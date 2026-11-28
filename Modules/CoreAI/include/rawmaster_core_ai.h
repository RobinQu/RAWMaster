#ifndef RAWMASTER_CORE_AI_H
#define RAWMASTER_CORE_AI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RMCoreAIEngine RMCoreAIEngine;
typedef struct RMCoreAICancellation RMCoreAICancellation;

enum {
    RM_CORE_AI_OK = 0,
    RM_CORE_AI_INVALID_ARGUMENT = 1,
    RM_CORE_AI_INCOMPATIBLE_RUNTIME = 2,
    RM_CORE_AI_MODEL_REJECTED = 3,
    RM_CORE_AI_INVALID_IMAGE = 4,
    RM_CORE_AI_INVALID_LANDMARKS = 5,
    RM_CORE_AI_BUSY = 6,
    RM_CORE_AI_BUDGET_EXCEEDED = 7,
    RM_CORE_AI_CANCELLED = 8,
    RM_CORE_AI_INFERENCE_FAILED = 9,
    RM_CORE_AI_INTERNAL = 10,
};

enum { RM_CORE_AI_RGBA8 = 1, RM_CORE_AI_BGRA8 = 2, RM_CORE_AI_FACE_EMBEDDING_LENGTH = 256 };

typedef struct {
    const uint8_t *data;
    size_t len;
    size_t stride;
    uint32_t width;
    uint32_t height;
    uint32_t format;
    uint32_t roi_x;
    uint32_t roi_y;
    uint32_t roi_width;
    uint32_t roi_height;
} RMCoreAIImageV1;

typedef struct { double x; double y; } RMCoreAIPointV1;

uint32_t rm_core_ai_abi_version(void);
/* contents is the trusted, absolute bundle Contents path, encoded as UTF-8 without a terminator. */
int32_t rm_core_ai_open_v1(const uint8_t *contents, size_t len, RMCoreAIEngine **out);
void rm_core_ai_close_v1(RMCoreAIEngine *engine);
int32_t rm_core_ai_evict_v1(const RMCoreAIEngine *engine);
RMCoreAICancellation *rm_core_ai_cancellation_create_v1(void);
int32_t rm_core_ai_cancellation_request_v1(const RMCoreAICancellation *cancel);
void rm_core_ai_cancellation_close_v1(RMCoreAICancellation *cancel);

/* The call borrows disjoint buffers until it returns. Use upright, unassociated sRGB8 RGB channels;
 * alpha is ignored. The face encoder requires the whole image as its ROI. Landmarks are in the
 * Discovery order (left/right eye, nose, left/right mouth), normalized by full width and height.
 * Supply one cancellation token per call. A concurrent cancellation may signal the run; callers
 * must still join the call before closing the engine or token. On error output is untouched. */
int32_t rm_core_ai_embed_face_v1(const RMCoreAIEngine *engine, const RMCoreAICancellation *cancel,
    const RMCoreAIImageV1 *image, const RMCoreAIPointV1 *landmarks, size_t landmark_count,
    float *output, size_t output_len);

#ifdef __cplusplus
}
#endif
#endif
