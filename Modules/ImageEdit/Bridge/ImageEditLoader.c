#include "ImageEditLoader.h"
#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>

struct RMImageRuntime {
    void *library;
    int32_t (*filter)(uint32_t, double, uint32_t, RMImageFilterBinding *);
    double (*exposure)(double);
    const uint8_t *(*kernel)(uint32_t, size_t *);
    int32_t (*plan_open)(const uint8_t *, size_t, const uint8_t *, size_t, uint32_t, RMImagePlan **);
    int32_t (*plan_render)(RMImagePlan *, uint32_t, uint32_t, const float *, size_t, const float *,
        size_t, float *, size_t);
    int32_t (*plan_open_v2)(const uint8_t *, size_t, const uint8_t *, size_t, uint32_t, RMImagePlan **);
    int32_t (*plan_render_v2)(RMImagePlan *, uint32_t, uint32_t, const float *, size_t,
        const RMImageCoverageV2 *, size_t, float *, size_t);
    void (*plan_close)(RMImagePlan *);
#ifdef __APPLE__
    int32_t (*metal_program_open)(const RMImagePlan *, void *, RMImageMetalProgram **);
    int32_t (*metal_frame_bind)(const RMImageMetalProgram *, const RMImagePlan *,
        const RMImageMetalSurfacesV1 *, RMImageMetalFrame **);
    int32_t (*metal_frame_bind_v2)(const RMImageMetalProgram *, const RMImagePlan *,
        const RMImageMetalSurfacesV2 *, RMImageMetalFrame **);
    int32_t (*metal_frame_render)(RMImageMetalFrame *, const RMImagePlan *, uint64_t,
        RMImageMetalIsCurrentV1, void *);
    void (*metal_frame_close)(RMImageMetalFrame *);
    int32_t (*scene_open)(const uint8_t *, size_t, void *, RMSceneProgram **);
    int32_t (*scene_open_frozen_delivery)(const uint8_t *, size_t, void *, uint32_t *, RMSceneProgram **);
    int32_t (*scene_update)(const RMSceneProgram *, const uint8_t *, size_t);
    int32_t (*scene_render)(const RMSceneProgram *, void *, void *, const uint8_t *, size_t, uint64_t, RMSceneIsCurrent, void *);
    int32_t (*scene_render_coverages)(const RMSceneProgram *, void *, void *, const uint8_t *, size_t, const char *const *, void *const *, size_t, uint64_t, RMSceneIsCurrent, void *);
    int32_t (*scene_render_surface)(const RMSceneProgram *, void *, void **, const uint8_t *, size_t, const char *const *, void *const *, size_t, uint64_t, RMSceneIsCurrent, void *);
    int32_t (*scene_receipt)(const RMSceneProgram *, RMSceneReceiptV1 *);
    void (*scene_close)(RMSceneProgram *);
    void (*metal_program_close)(RMImageMetalProgram *);
    int32_t (*metal_half_program_open)(const RMImagePlan *, void *, RMImageMetalHalfProgram **);
    int32_t (*metal_half_render)(const RMImageMetalHalfProgram *, const RMImagePlan *, void *, void *,
        uint64_t, RMImageMetalIsCurrentV1, void *);
    void (*metal_half_program_close)(RMImageMetalHalfProgram *);
    int32_t (*metal_mask_half_program_open)(const RMImagePlan *, void *, RMImageMetalHalfProgram **);
    int32_t (*metal_mask_region_program_open)(const RMImagePlan *, void *, RMImageMetalHalfProgram **);
    int32_t (*metal_mask_region_render)(const RMImageMetalHalfProgram *, const RMImagePlan *, void *,
        const uint8_t *, size_t, void *, void *, const RMImageMetalMaskRegionV1 *, uint64_t, RMImageMetalIsCurrentV1, void *);
    int32_t (*metal_mask_half_render)(const RMImageMetalHalfProgram *, const RMImagePlan *, void *,
        const uint8_t *, size_t, void *, void *, uint64_t, RMImageMetalIsCurrentV1, void *);
#endif
};

RMImageRuntime *rm_image_host_open(const char *path) {
    if (!path) return NULL;
    void *library = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (!library) return NULL;

    uint32_t (*version)(void) = dlsym(library, "rm_image_abi_version");
    if (!version || version() != 1) {
        dlclose(library);
        return NULL;
    }
    RMImageRuntime *runtime = calloc(1, sizeof(*runtime));
    if (!runtime) {
        dlclose(library);
        return NULL;
    }
    runtime->library = library;
    runtime->filter = dlsym(library, "rm_image_filter_binding_v1");
    runtime->exposure = dlsym(library, "rm_image_exposure_gain_v1");
    runtime->kernel = dlsym(library, "rm_image_kernel_source_v1");
    runtime->plan_open = dlsym(library, "rm_image_plan_open_v1");
    runtime->plan_render = dlsym(library, "rm_image_plan_render_v1");
    runtime->plan_close = dlsym(library, "rm_image_plan_close_v1");
    runtime->plan_open_v2 = dlsym(library, "rm_image_plan_open_v2");
    runtime->plan_render_v2 = dlsym(library, "rm_image_plan_render_v2");
    if (!runtime->filter || !runtime->exposure || !runtime->kernel ||
        !runtime->plan_open || !runtime->plan_render || !runtime->plan_close) {
        rm_image_host_close(runtime);
        return NULL;
    }
#ifdef __APPLE__
    uint32_t (*metal_version)(void) = dlsym(library, "rm_image_metal_surface_abi_version");
    if (metal_version && metal_version() == 1) {
        runtime->metal_program_open = dlsym(library, "rm_image_metal_program_open_v1");
        runtime->metal_frame_bind = dlsym(library, "rm_image_metal_frame_bind_v1");
        runtime->metal_frame_bind_v2 = dlsym(library, "rm_image_metal_frame_bind_v2");
        runtime->metal_frame_render = dlsym(library, "rm_image_metal_frame_render_v1");
        runtime->metal_frame_close = dlsym(library, "rm_image_metal_frame_close_v1");
        runtime->scene_open = dlsym(library, "rm_scene_program_open_v1");
        runtime->scene_open_frozen_delivery = dlsym(library, "rm_scene_program_open_frozen_delivery_v1");
        runtime->scene_update = dlsym(library, "rm_scene_program_update_v1");
        runtime->scene_render = dlsym(library, "rm_scene_program_render_v1");
        runtime->scene_render_coverages = dlsym(library, "rm_scene_program_render_coverages_v1");
        runtime->scene_render_surface = dlsym(library, "rm_scene_program_render_surface_v1");
        runtime->scene_receipt = dlsym(library, "rm_scene_program_receipt_v1");
        runtime->scene_close = dlsym(library, "rm_scene_program_close_v1");
        runtime->metal_program_close = dlsym(library, "rm_image_metal_program_close_v1");
        runtime->metal_half_program_open = dlsym(library, "rm_image_metal_half_program_open_v1");
        runtime->metal_half_render = dlsym(library, "rm_image_metal_half_render_v1");
        runtime->metal_half_program_close = dlsym(library, "rm_image_metal_half_program_close_v1");
        runtime->metal_mask_half_program_open = dlsym(library, "rm_image_metal_mask_half_program_open_v1");
        runtime->metal_mask_half_render = dlsym(library, "rm_image_metal_mask_half_render_v1");
        runtime->metal_mask_region_program_open = dlsym(library, "rm_image_metal_mask_region_program_open_v1");
        runtime->metal_mask_region_render = dlsym(library, "rm_image_metal_mask_region_render_v1");
    }
#endif
    return runtime;
}

void rm_image_host_close(RMImageRuntime *runtime) {
    if (!runtime) return;
    dlclose(runtime->library);
    free(runtime);
}

int32_t rm_image_host_filter(const RMImageRuntime *runtime, uint32_t family, double amount,
                             uint32_t repair, RMImageFilterBinding *binding) {
    return runtime->filter(family, amount, repair, binding);
}

double rm_image_host_exposure(const RMImageRuntime *runtime, double ev) {
    return runtime->exposure(ev);
}

const uint8_t *rm_image_host_kernel(const RMImageRuntime *runtime, uint32_t kind, size_t *length) {
    return runtime->kernel(kind, length);
}

int32_t rm_image_host_plan_open(const RMImageRuntime *runtime, const uint8_t *json, size_t bytes,
    const uint8_t *resource_root, size_t path_bytes, uint32_t backend, RMImagePlan **out) {
    if (runtime->plan_open_v2 && runtime->plan_render_v2) {
        return runtime->plan_open_v2(json, bytes, resource_root, path_bytes, backend, out);
    }
    return runtime->plan_open(json, bytes, resource_root, path_bytes, backend, out);
}

int32_t rm_image_host_plan_render_v2(const RMImageRuntime *runtime, RMImagePlan *plan, uint32_t width,
    uint32_t height, const float *rgba, size_t rgba_count, const RMImageCoverageV2 *coverage,
    size_t coverage_count, float *destination, size_t destination_count) {
    if (!runtime->plan_open_v2 || !runtime->plan_render_v2) return RM_IMAGE_BACKEND;
    return runtime->plan_render_v2(plan, width, height, rgba, rgba_count, coverage, coverage_count,
                                  destination, destination_count);
}

int32_t rm_image_host_plan_render(const RMImageRuntime *runtime, RMImagePlan *plan, uint32_t width,
    uint32_t height, const float *rgba, size_t rgba_count, const float *mask, size_t mask_count,
    float *destination, size_t destination_count) {
    return runtime->plan_render(plan, width, height, rgba, rgba_count, mask, mask_count,
                                destination, destination_count);
}

void rm_image_host_plan_close(const RMImageRuntime *runtime, RMImagePlan *plan) {
    runtime->plan_close(plan);
}

#ifdef __APPLE__
int32_t rm_image_host_metal_program_open(const RMImageRuntime *runtime, const RMImagePlan *recipe,
    void *device, RMImageMetalProgram **out) {
    if (!runtime->metal_program_open || !runtime->metal_frame_bind || !runtime->metal_frame_render ||
        !runtime->metal_frame_close || !runtime->metal_program_close) {
        if (out) *out = NULL;
        return RM_IMAGE_BACKEND;
    }
    return runtime->metal_program_open(recipe, device, out);
}

int32_t rm_image_host_metal_frame_bind(const RMImageRuntime *runtime, const RMImageMetalProgram *program,
    const RMImagePlan *recipe, const RMImageMetalSurfacesV1 *surfaces, RMImageMetalFrame **out) {
    return runtime->metal_frame_bind(program, recipe, surfaces, out);
}

int32_t rm_image_host_metal_frame_bind_v2(const RMImageRuntime *runtime, const RMImageMetalProgram *program,
    const RMImagePlan *recipe, const RMImageMetalSurfacesV2 *surfaces, RMImageMetalFrame **out) {
    if (!runtime->metal_frame_bind_v2) {
        if (out) *out = NULL;
        return RM_IMAGE_BACKEND;
    }
    return runtime->metal_frame_bind_v2(program, recipe, surfaces, out);
}

int32_t rm_image_host_metal_frame_render(const RMImageRuntime *runtime, RMImageMetalFrame *frame,
    const RMImagePlan *parameters, uint64_t revision, RMImageMetalIsCurrentV1 current, void *context) {
    return runtime->metal_frame_render(frame, parameters, revision, current, context);
}

void rm_image_host_metal_frame_close(const RMImageRuntime *runtime, RMImageMetalFrame *frame) {
    runtime->metal_frame_close(frame);
}

void rm_image_host_metal_program_close(const RMImageRuntime *runtime, RMImageMetalProgram *program) {
    runtime->metal_program_close(program);
}

int32_t rm_image_host_metal_half_program_open(const RMImageRuntime *runtime, const RMImagePlan *recipe,
    void *device, RMImageMetalHalfProgram **out) {
    if (!out) return RM_IMAGE_INVALID;
    *out = NULL;
    if (!runtime || !runtime->metal_half_program_open || !runtime->metal_half_render ||
        !runtime->metal_half_program_close) return RM_IMAGE_BACKEND;
    return runtime->metal_half_program_open(recipe, device, out);
}

int32_t rm_image_host_metal_half_render(const RMImageRuntime *runtime, const RMImageMetalHalfProgram *program,
    const RMImagePlan *parameters, void *input, void *output, uint64_t revision,
    RMImageMetalIsCurrentV1 current, void *context) {
    if (!runtime || !runtime->metal_half_render) return RM_IMAGE_BACKEND;
    return runtime->metal_half_render(program, parameters, input, output, revision, current, context);
}

int32_t rm_image_host_metal_mask_region_program_open(const RMImageRuntime *runtime, const RMImagePlan *recipe,
    void *device, RMImageMetalHalfProgram **out) {
    if (!out) return RM_IMAGE_INVALID;
    *out = NULL;
    if (!runtime || !runtime->metal_mask_region_program_open || !runtime->metal_mask_region_render ||
        !runtime->metal_half_program_close) return RM_IMAGE_BACKEND;
    return runtime->metal_mask_region_program_open(recipe, device, out);
}
int32_t rm_image_host_metal_mask_region_render(const RMImageRuntime *runtime, const RMImageMetalHalfProgram *program,
    const RMImagePlan *parameters, void *input, const uint8_t *name, size_t length, void *coverage, void *output,
    const RMImageMetalMaskRegionV1 *region, uint64_t revision, RMImageMetalIsCurrentV1 current, void *context) {
    if (!runtime || !runtime->metal_mask_region_render) return RM_IMAGE_BACKEND;
    return runtime->metal_mask_region_render(program, parameters, input, name, length, coverage, output, region,
        revision, current, context);
}
void rm_image_host_metal_half_program_close(const RMImageRuntime *runtime, RMImageMetalHalfProgram *program) {
    if (runtime && runtime->metal_half_program_close) runtime->metal_half_program_close(program);
}
int32_t rm_image_host_metal_mask_half_program_open(const RMImageRuntime *runtime, const RMImagePlan *recipe,
    void *device, RMImageMetalHalfProgram **out) {
    if (!out) return RM_IMAGE_INVALID;
    *out = NULL;
    if (!runtime || !runtime->metal_mask_half_program_open || !runtime->metal_mask_half_render ||
        !runtime->metal_half_program_close) return RM_IMAGE_BACKEND;
    return runtime->metal_mask_half_program_open(recipe, device, out);
}
int32_t rm_image_host_metal_mask_half_render(const RMImageRuntime *runtime, const RMImageMetalHalfProgram *program,
    const RMImagePlan *parameters, void *input, const uint8_t *name, size_t length, void *coverage, void *output,
    uint64_t revision, RMImageMetalIsCurrentV1 current, void *context) {
    if (!runtime || !runtime->metal_mask_half_render) return RM_IMAGE_BACKEND;
    return runtime->metal_mask_half_render(program, parameters, input, name, length, coverage, output, revision, current, context);
}
#endif


int32_t rm_image_host_scene_open(const RMImageRuntime *runtime, const uint8_t *graph,
    size_t graph_bytes, void *device, RMSceneProgram **out) {
    if (!runtime || !runtime->scene_open) { if (out) *out = NULL; return 2; }
    return runtime->scene_open(graph, graph_bytes, device, out);
}
int32_t rm_image_host_scene_open_frozen_delivery(const RMImageRuntime *runtime, const uint8_t *graph,
    size_t graph_bytes, void *device, uint32_t *library_api_calls, RMSceneProgram **out) {
    if (out) *out = NULL;
    if (library_api_calls) *library_api_calls = 0;
    if (!runtime) return 1;
    if (!runtime->scene_open_frozen_delivery) return RM_IMAGE_HOST_SCENE_FROZEN_OPEN_MISSING;
    return runtime->scene_open_frozen_delivery(graph, graph_bytes, device, library_api_calls, out);
}
int32_t rm_image_host_scene_update(const RMImageRuntime *runtime, const RMSceneProgram *program,
    const uint8_t *graph, size_t graph_bytes) {
    if (!runtime || !runtime->scene_update) return 2;
    return runtime->scene_update(program, graph, graph_bytes);
}
int32_t rm_image_host_scene_render(const RMImageRuntime *runtime, const RMSceneProgram *program,
    void *input, void *output, const uint8_t *view, size_t view_bytes, uint64_t revision,
    RMSceneIsCurrent current, void *context) {
    if (!runtime || !runtime->scene_render) return 2;
    return runtime->scene_render(program, input, output, view, view_bytes, revision, current, context);
}
int32_t rm_image_host_scene_render_coverages(const RMImageRuntime *runtime,
    const RMSceneProgram *program, void *input, void *output, const uint8_t *view,
    size_t view_bytes, const char *const *coverage_ids, void *const *coverage_textures,
    size_t coverage_count, uint64_t revision, RMSceneIsCurrent current, void *context) {
    if (!runtime || !runtime->scene_render_coverages) return 2;
    return runtime->scene_render_coverages(program, input, output, view, view_bytes,
        coverage_ids, coverage_textures, coverage_count, revision, current, context);
}
int32_t rm_image_host_scene_render_surface(const RMImageRuntime *runtime,
    const RMSceneProgram *program, void *input, void **retained_output, const uint8_t *view,
    size_t view_bytes, const char *const *coverage_ids, void *const *coverage_textures,
    size_t coverage_count, uint64_t revision, RMSceneIsCurrent current, void *context) {
    if (!runtime || !runtime->scene_render_surface) return 2;
    return runtime->scene_render_surface(program, input, retained_output, view, view_bytes,
        coverage_ids, coverage_textures, coverage_count, revision, current, context);
}
int32_t rm_image_host_scene_receipt(const RMImageRuntime *runtime,
    const RMSceneProgram *program, RMSceneReceiptV1 *out) {
    if (!runtime || !runtime->scene_receipt) return 2;
    return runtime->scene_receipt(program, out);
}
void rm_image_host_scene_close(const RMImageRuntime *runtime, RMSceneProgram *program) {
    if (runtime && runtime->scene_close) runtime->scene_close(program);
}
