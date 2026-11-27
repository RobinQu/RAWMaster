#ifndef RAWMASTER_IMAGE_EDIT_LOADER_H
#define RAWMASTER_IMAGE_EDIT_LOADER_H

#include "../../include/rawmaster_image.h"
#include "../../include/rawmaster_image_scene.h"

typedef struct RMImageRuntime RMImageRuntime;
RMImageRuntime *rm_image_host_open(const char *path);
void rm_image_host_close(RMImageRuntime *runtime);
int32_t rm_image_host_filter(const RMImageRuntime *runtime, uint32_t family, double amount,
                             uint32_t repair, RMImageFilterBinding *binding);
double rm_image_host_exposure(const RMImageRuntime *runtime, double ev);
const uint8_t *rm_image_host_kernel(const RMImageRuntime *runtime, uint32_t kind, size_t *length);
int32_t rm_image_host_plan_open(const RMImageRuntime *runtime, const uint8_t *json, size_t bytes,
    const uint8_t *resource_root, size_t path_bytes, uint32_t backend, RMImagePlan **out);
int32_t rm_image_host_plan_render(const RMImageRuntime *runtime, RMImagePlan *plan, uint32_t width,
    uint32_t height, const float *rgba, size_t rgba_count, const float *mask, size_t mask_count,
    float *destination, size_t destination_count);
int32_t rm_image_host_plan_render_v2(const RMImageRuntime *runtime, RMImagePlan *plan, uint32_t width,
    uint32_t height, const float *rgba, size_t rgba_count, const RMImageCoverageV2 *coverage,
    size_t coverage_count, float *destination, size_t destination_count);
void rm_image_host_plan_close(const RMImageRuntime *runtime, RMImagePlan *plan);

#ifdef __APPLE__
#include "../../include/rawmaster_image_metal.h"
int32_t rm_image_host_metal_program_open(const RMImageRuntime *runtime, const RMImagePlan *recipe,
    void *device, RMImageMetalProgram **out);
int32_t rm_image_host_metal_frame_bind(const RMImageRuntime *runtime, const RMImageMetalProgram *program,
    const RMImagePlan *recipe, const RMImageMetalSurfacesV1 *surfaces, RMImageMetalFrame **out);
int32_t rm_image_host_metal_frame_bind_v2(const RMImageRuntime *runtime, const RMImageMetalProgram *program,
    const RMImagePlan *recipe, const RMImageMetalSurfacesV2 *surfaces, RMImageMetalFrame **out);
int32_t rm_image_host_metal_frame_render(const RMImageRuntime *runtime, RMImageMetalFrame *frame,
    const RMImagePlan *parameters, uint64_t revision, RMImageMetalIsCurrentV1 current, void *context);
void rm_image_host_metal_frame_close(const RMImageRuntime *runtime, RMImageMetalFrame *frame);
void rm_image_host_metal_program_close(const RMImageRuntime *runtime, RMImageMetalProgram *program);
int32_t rm_image_host_metal_half_program_open(const RMImageRuntime *runtime, const RMImagePlan *recipe,
    void *device, RMImageMetalHalfProgram **out);
int32_t rm_image_host_metal_half_render(const RMImageRuntime *runtime, const RMImageMetalHalfProgram *program,
    const RMImagePlan *parameters, void *input, void *output, uint64_t revision,
    RMImageMetalIsCurrentV1 current, void *context);
void rm_image_host_metal_half_program_close(const RMImageRuntime *runtime, RMImageMetalHalfProgram *program);
int32_t rm_image_host_metal_mask_region_program_open(const RMImageRuntime *runtime, const RMImagePlan *recipe,
    void *device, RMImageMetalHalfProgram **out);
int32_t rm_image_host_metal_mask_region_render(const RMImageRuntime *runtime, const RMImageMetalHalfProgram *program,
    const RMImagePlan *parameters, void *input, const uint8_t *name, size_t length, void *coverage, void *output,
    const RMImageMetalMaskRegionV1 *region, uint64_t revision, RMImageMetalIsCurrentV1 current, void *context);
int32_t rm_image_host_metal_mask_half_program_open(const RMImageRuntime *runtime, const RMImagePlan *recipe,
    void *device, RMImageMetalHalfProgram **out);
int32_t rm_image_host_metal_mask_half_render(const RMImageRuntime *runtime, const RMImageMetalHalfProgram *program,
    const RMImagePlan *parameters, void *input, const uint8_t *name, size_t length, void *coverage, void *output,
    uint64_t revision, RMImageMetalIsCurrentV1 current, void *context);
#endif

#endif

int32_t rm_image_host_scene_open(const RMImageRuntime *runtime, const uint8_t *graph,
    size_t graph_bytes, void *device, RMSceneProgram **out);
int32_t rm_image_host_scene_update(const RMImageRuntime *runtime, const RMSceneProgram *program,
    const uint8_t *graph, size_t graph_bytes);
int32_t rm_image_host_scene_render(const RMImageRuntime *runtime, const RMSceneProgram *program,
    void *input, void *output, const uint8_t *view, size_t view_bytes, uint64_t revision,
    RMSceneIsCurrent current, void *context);
int32_t rm_image_host_scene_render_coverages(const RMImageRuntime *runtime,
    const RMSceneProgram *program, void *input, void *output, const uint8_t *view,
    size_t view_bytes, const char *const *coverage_ids, void *const *coverage_textures,
    size_t coverage_count, uint64_t revision, RMSceneIsCurrent current, void *context);
int32_t rm_image_host_scene_render_surface(const RMImageRuntime *runtime,
    const RMSceneProgram *program, void *input, void **retained_output, const uint8_t *view,
    size_t view_bytes, const char *const *coverage_ids, void *const *coverage_textures,
    size_t coverage_count, uint64_t revision, RMSceneIsCurrent current, void *context);
int32_t rm_image_host_scene_receipt(const RMImageRuntime *runtime,
    const RMSceneProgram *program, RMSceneReceiptV1 *out);
void rm_image_host_scene_close(const RMImageRuntime *runtime, RMSceneProgram *program);
