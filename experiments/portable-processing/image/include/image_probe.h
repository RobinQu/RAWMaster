#ifndef RAWMASTER_IMAGE_PROBE_H
#define RAWMASTER_IMAGE_PROBE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct RmiPlan RmiPlan;
enum RmiStatus { RMI_OK=0, RMI_INVALID=1, RMI_BACKEND=2, RMI_RENDER=3, RMI_PANIC=4 };
enum RmiBackend { RMI_CPU=0, RMI_GPU=1 };
// UTF-8 bytes are borrowed for this call. Success transfers the plan to the caller.
int32_t rmi_open_v1(const char *json, size_t bytes, uint32_t backend, RmiPlan **plan);
// Synchronous. Use a plan serially. Contiguous top-down pixels, RGBA premultiplied,
// linear sRGB, float counts (not bytes), one mask value per pixel. Buffers are
// non-overlapping, float-aligned and borrowed until return. Publish only on success.
int32_t rmi_render_v1(RmiPlan *plan, uint32_t width, uint32_t height,
    const float *rgba, size_t rgba_count, const float *mask, size_t mask_count,
    float *destination, size_t destination_count);
void rmi_close_v1(RmiPlan *plan);
#ifdef __cplusplus
}
#endif
#endif
