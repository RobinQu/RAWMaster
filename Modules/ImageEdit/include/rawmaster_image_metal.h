#ifndef RAWMASTER_IMAGE_METAL_H
#define RAWMASTER_IMAGE_METAL_H
#include "rawmaster_image.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Optional macOS extension. Discover these symbols when built with
   metal-surface. All Objective-C objects belong to the host process. Native
   leases and handles are serialized by the caller. Render runs on a worker and
   joins before return. */
typedef struct RMImageMetalProgram RMImageMetalProgram;
typedef struct RMImageMetalFrame RMImageMetalFrame;
typedef uint32_t (*RMImageMetalIsCurrentV1)(void *context, uint64_t revision);
typedef void (*RMImageMetalReleaseLeaseV1)(void *context);
enum { RM_IMAGE_METAL_STALE = 5 };
typedef struct RMImageMetalSurfacesV1 {
  uint32_t struct_size, width, height,
      flags; /* sizeof(this struct), flags zero */
  void *input_rgba, *coverage_r32, *output_rgba; /* borrowed id<MTLTexture> */
  void *lease_context;
  RMImageMetalReleaseLeaseV1 release_lease;
} RMImageMetalSurfacesV1;
typedef struct RMImageMetalCoverageV2 {
  const uint8_t *id;
  size_t id_bytes;
  void *texture; /* borrowed id<MTLTexture>, R32Float */
} RMImageMetalCoverageV2;

typedef struct RMImageMetalSurfacesV2 {
  uint32_t struct_size, width, height, flags;
  void *input_rgba, *output_rgba;
  const RMImageMetalCoverageV2 *coverage;
  size_t coverage_count;
  void *lease_context;
  RMImageMetalReleaseLeaseV1 release_lease;
} RMImageMetalSurfacesV2;
uint32_t rm_image_metal_surface_abi_version(void);
/* The validated source plan may use RM_IMAGE_CPU. The extension selects the
 * same MTLDevice. */
int32_t rm_image_metal_program_open_v1(const RMImagePlan *recipe,
                                       void *metal_device,
                                       RMImageMetalProgram **out);
/* Input/output are distinct plane-zero RGBA32Float and coverage R32Float, same
   extent/device. For recipes without a mask pass NULL coverage. All supplied
   storage must be fully initialized and joined with its previous producer.
   Success retains the real textures and transfers the optional host lease until
   frame close. On failure the caller still owns the lease. */
int32_t rm_image_metal_frame_bind_v1(const RMImageMetalProgram *program,
                                     const RMImagePlan *recipe,
                                     const RMImageMetalSurfacesV1 *surfaces,
                                     RMImageMetalFrame **out);
/* Version 1 and 2 graphs bind each declared UTF-8 mask ID exactly once in any
   order. At most 32 entries. Each name and the descriptor array are borrowed
   until bind returns. Every texture is same-device, same-size, producer-joined
   and backed by a distinct, single-plane IOSurface. All masks stay immutable
   through frame close. A new mask revision needs a new frame. Success
   transfers one lease for the whole group. Errors leave the lease with the
   caller. Program open, render and close use the common v1 functions. */
int32_t rm_image_metal_frame_bind_v2(const RMImageMetalProgram *program,
                                     const RMImagePlan *recipe,
                                     const RMImageMetalSurfacesV2 *surfaces,
                                     RMImageMetalFrame **out);
/* Supply a validated parameter plan with the same topology and atlas plane
   identities. current(context,revision) returns one for the current revision;
   NULL accepts every revision. Input and coverage remain immutable during the
   call. Output is exclusive unpublished scratch; publish only on RM_IMAGE_OK
   and recheck revision on the presentation actor. A stale or failed render may
   have written GPU pixels. A submitted task drains its native fence before
   returning. Failure, staleness or cancellation withholds every presentation
   right. */
int32_t rm_image_metal_frame_render_v1(RMImageMetalFrame *frame,
                                       const RMImagePlan *parameters,
                                       uint64_t revision,
                                       RMImageMetalIsCurrentV1 current,
                                       void *context);
void rm_image_metal_frame_close_v1(RMImageMetalFrame *frame);
void rm_image_metal_program_close_v1(RMImageMetalProgram *program);

/* Optional private-texture extension. All three functions must be available.
   The program retains device code and topology only. It accepts a v2 source
   followed by active color_grading_v2, or by an optional disabled basic_v3
   and one active curves_levels_v3. Each rebind
   rechecks both the topology and the enabled stages. Handles belong to the
   runtime that opened them. */
typedef struct RMImageMetalHalfProgram RMImageMetalHalfProgram;
enum { RM_IMAGE_METAL_HALF_MAX_SCRATCH_BYTES = 48 * 1024 * 1024 };
int32_t rm_image_metal_half_program_open_v1(const RMImagePlan *recipe, void *metal_device,
                                            RMImageMetalHalfProgram **out);
/* Both textures must already be fully initialized and joined with their last
   producer before their native storage is imported. Clear a newly allocated
   destination and wait for that command to complete. The read-only RGBA16Float
   source is opaque, even-sized and at most 9600 by 6400. The exclusive
   RGBA32Float destination has half its width and height. Both use the program device and
   tracked, private, single-level 2D storage without aliased backing. Physical
   output row zero corresponds to the last source row. Input/output leases and
   the required revision callback must remain live for the synchronous call.
   Four 256-row bands share a submission. Every submitted group drains before
   return. Only success and a fresh presentation authority check permit use
   of the output. RM_IMAGE_BACKEND is a pre-submission capability or budget
   rejection. All other failures can leave unusable pixels in the destination. */
int32_t rm_image_metal_half_render_v1(const RMImageMetalHalfProgram *program,
                                     const RMImagePlan *parameters, void *source, void *half,
                                     uint64_t revision, RMImageMetalIsCurrentV1 current, void *context);
/* Optional named mask_tone_v3 extension. The original source and half have
   the same format, initialization, leases and completion contract as above.
   The fully initialized private R32Float coverage is the size of the original.
   Physical mask row zero is the logical bottom row. Its producer must have
   joined before the call. All values must be finite and in [0,1]. The UTF-8
   name must exactly match the mask node of this program and this recipe.
   Release a program through rm_image_metal_half_program_close_v1. */
int32_t rm_image_metal_mask_half_program_open_v1(const RMImagePlan *recipe, void *metal_device,
                                                 RMImageMetalHalfProgram **out);
int32_t rm_image_metal_mask_half_render_v1(const RMImageMetalHalfProgram *program,
    const RMImagePlan *parameters, void *source, const uint8_t *mask_id, size_t mask_id_length,
    void *coverage, void *half, uint64_t revision, RMImageMetalIsCurrentV1 current, void *context);
/* Compact, initialized, logical-bottom-up R32Float mask with positive zero outside.
   Coordinates are in the original grid. X, width and height are even; Y starts a
   256-row band and the region ends on a band boundary or at the last source row.
   patch_only=0 computes and verifies the entire source and output with this compact mask.
   patch_only=1 reads and checks only this region and overwrites only its 2:1 output
   rectangle. A successful patch does not validate or initialize any exterior pixel.
   A caller composing a whole frame must independently own its initialized, verified
   exterior from the same immutable optical source and mask scope. All unchanged
   producer, device, authority and synchronous completion rules above still apply. */
typedef struct RMImageMetalMaskRegionV1 {
    uint32_t x, y, width, height, patch_only;
} RMImageMetalMaskRegionV1;
int32_t rm_image_metal_mask_region_program_open_v1(const RMImagePlan *recipe, void *metal_device,
    RMImageMetalHalfProgram **out);
int32_t rm_image_metal_mask_region_render_v1(const RMImageMetalHalfProgram *program,
    const RMImagePlan *parameters, void *source, const uint8_t *mask_id, size_t mask_id_length,
    void *coverage, void *half, const RMImageMetalMaskRegionV1 *region,
    uint64_t revision, RMImageMetalIsCurrentV1 current, void *context);
void rm_image_metal_half_program_close_v1(RMImageMetalHalfProgram *program);
#ifdef __cplusplus
}
#endif
#endif
