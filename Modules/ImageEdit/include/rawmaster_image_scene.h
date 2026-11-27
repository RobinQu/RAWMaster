#ifndef RAWMASTER_IMAGE_SCENE_H
#define RAWMASTER_IMAGE_SCENE_H
#include "rawmaster_image.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Scene-linear AP1 F32 graph execution for 037/038. Program creation validates and
   compiles the bounded graph. input/output are borrowed RGBA32Float Metal textures;
   output is exclusive scratch. View JSON is {"target":"final"|"bypass"|"node","id":"..."}.
   A node target executes the reachable graph and writes that node's image surface.
   The optional revision callback must remain valid for the synchronous call. */
typedef struct RMSceneProgram RMSceneProgram;
typedef uint32_t (*RMSceneIsCurrent)(void *context, uint64_t revision);
#define RM_SCENE_RECEIPT_ABI 1
/* Completion receipt for the most recent render. Tiles is the execution tile count, Nodes the
   non-cached nodes evaluated, Dispatches the compute kernels encoded, and the two hit fields the
   cross-frame cache reuse. PeakBytes includes input, live intermediates, pool and caches. */
typedef struct RMSceneReceiptV1 {
    uint32_t abi;
    uint32_t tiles;
    uint32_t nodes;
    uint32_t dispatches;
    uint32_t coverage_hits;
    uint32_t node_hits;
    uint32_t reserved;
    uint64_t peak_bytes;
    uint64_t budget_bytes;
    double cpu_ms;
} RMSceneReceiptV1;
uint32_t rm_scene_abi_version(void);
int32_t rm_scene_program_open_v1(const uint8_t *graph, size_t graph_bytes,
                                 void *metal_device, RMSceneProgram **out);
/* Replaces parameters for the same topology without discarding prefix caches. */
int32_t rm_scene_program_update_v1(const RMSceneProgram *program,
                                   const uint8_t *graph, size_t graph_bytes);
int32_t rm_scene_program_render_v1(const RMSceneProgram *program,
                                   void *input, void *output,
                                   const uint8_t *view_json, size_t view_bytes,
                                   uint64_t revision, RMSceneIsCurrent current, void *context);
/* Binds provider-produced full-frame R32F coverage textures by stage id. */
int32_t rm_scene_program_render_coverages_v1(const RMSceneProgram *program,
                                             void *input, void *output,
                                             const uint8_t *view_json, size_t view_bytes,
                                             const char *const *coverage_ids,
                                             void *const *coverage_textures,
                                             size_t coverage_count,
                                             uint64_t revision, RMSceneIsCurrent current,
                                             void *context);
int32_t rm_scene_program_receipt_v1(const RMSceneProgram *program, RMSceneReceiptV1 *out);
void rm_scene_program_close_v1(RMSceneProgram *program);
#ifdef __cplusplus
}
#endif
#endif
