#ifndef RAWMASTER_IMAGE_H
#define RAWMASTER_IMAGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RMImagePlan RMImagePlan;
typedef struct RMImageFilterBinding {
  uint32_t low_percent, high_percent;
  float weight, normalized_amount;
  uint32_t hdr_mode, repair_raw_alpha;
} RMImageFilterBinding;

enum RMImageStatus {
  RM_IMAGE_OK = 0,
  RM_IMAGE_INVALID = 1,
  RM_IMAGE_BACKEND = 2,
  RM_IMAGE_RENDER = 3,
  RM_IMAGE_PANIC = 4
};
enum RMImageBackend { RM_IMAGE_CPU = 0, RM_IMAGE_GPU = 1 };
enum RMImageFilterFamily {
  RM_IMAGE_CLASSIC = 0,
  RM_IMAGE_MONO_NOIR = 1,
  RM_IMAGE_SPEKTRAFILM = 2
};
uint32_t rm_image_abi_version(void);
/* Amount is 0..100. Low zero represents zero delta (bind the high atlas to both
   texture slots). Equal endpoints select one atlas with weight zero. No writes
   on failure. */
int32_t rm_image_filter_binding_v1(uint32_t family, double amount,
                                   uint32_t repair, RMImageFilterBinding *out);
/* Returns 2^ev, or NaN for non-finite/overflow/underflow to zero. */
double rm_image_exposure_gain_v1(double ev);
/* Process-lifetime UTF-8 bytes. Length excludes any terminator. kind: 1 filter,
   2 exposure, 3 mask, 4 analytic mask, 5 grain lattice. Unknown kind returns
   NULL and length zero. */
const uint8_t *rm_image_kernel_source_v1(uint32_t kind, size_t *out_length);
/* JSON and optional filter atlas directory are borrowed UTF-8. A nonzero
   resource length requires a non-null UTF-8 path. Success transfers an
   immutable plan to the caller. */
int32_t rm_image_plan_open_v1(const uint8_t *json, size_t bytes,
                              const uint8_t *resource_root, size_t path_bytes,
                              uint32_t backend, RMImagePlan **out);
/* Synchronous, tightly packed top-down premultiplied extended-linear-sRGB RGBA
   F32. Input, scalar coverage and output are aligned, non-overlapping, borrowed
   buffers. Counts are floats. A graph without a mask accepts NULL/zero
   coverage. The caller must serialize access to a handle and retain all storage
   until return. No writes on failure. */
int32_t rm_image_plan_render_v1(RMImagePlan *plan, uint32_t width,
                                uint32_t height, const float *rgba,
                                size_t rgba_count, const float *mask,
                                size_t mask_count, float *destination,
                                size_t destination_count);
void rm_image_plan_close_v1(RMImagePlan *plan);

typedef struct RMImageCoverageV2 {
  const uint8_t *id;
  size_t id_bytes;
  const float *values;
  size_t count;
} RMImageCoverageV2;

/* Additive entry points under ABI 1. Open accepts recipe versions 1 and 2.
   Close still uses rm_image_plan_close_v1. */
int32_t rm_image_plan_open_v2(const uint8_t *json, size_t bytes,
                              const uint8_t *resource_root, size_t path_bytes,
                              uint32_t backend, RMImagePlan **out);
/* One tightly packed top-down FP32 plane for every mask node ID, in any
   order. IDs are exact length-delimited UTF-8. Each count is width*height.
   Output must not overlap borrowed input, IDs, descriptors, or planes.
   Input and output use the same pixel contract as v1. No writes on failure. */
int32_t rm_image_plan_render_v2(RMImagePlan *plan, uint32_t width,
                                uint32_t height, const float *rgba,
                                size_t rgba_count, const RMImageCoverageV2 *coverage,
                                size_t coverage_count, float *destination,
                                size_t destination_count);
#ifdef __cplusplus
}
#endif
#endif
