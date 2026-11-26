#ifndef CFLASHRAW_H
#define CFLASHRAW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rm_flashraw_context rm_flashraw_context;
typedef struct rm_flashraw_frame rm_flashraw_frame;

typedef struct rm_flashraw_frame_info {
    uint32_t width;
    uint32_t height;
    uint32_t channels;
    uint32_t orientation;
    uint32_t origin_x;
    uint32_t origin_y;
    int32_t sample_type;
    int32_t output_format;
    int32_t source;
    int32_t incomplete;
} rm_flashraw_frame_info;

typedef struct rm_flashraw_decode_statistics {
    uint32_t threads;
    double total_ms;
    uint64_t input_bytes;
    uint64_t output_bytes;
    double stage_ms[11];
    const char *backend;
    const char *postprocess_backend;
} rm_flashraw_decode_statistics;

rm_flashraw_context *rm_flashraw_open(const char *path, const char *library_path,
                                       char *error, size_t error_capacity);
void rm_flashraw_close(rm_flashraw_context *context);
int32_t rm_flashraw_sensor_layout(const rm_flashraw_context *context);
void rm_flashraw_geometry(const rm_flashraw_context *context, uint32_t *width,
                          uint32_t *height, uint32_t *orientation);
const char *rm_flashraw_version(rm_flashraw_context *context);

int rm_flashraw_decode(rm_flashraw_context *context, int32_t backend, int32_t output,
                       int32_t demosaic, int32_t has_region,
                       uint32_t x, uint32_t y, uint32_t width, uint32_t height,
                       rm_flashraw_frame **out, char *error, size_t error_capacity);
void rm_flashraw_frame_free(rm_flashraw_frame *frame);
rm_flashraw_frame_info rm_flashraw_frame_get_info(rm_flashraw_frame *frame);
/* Strings are borrowed until frame release. Zero means the library returned no statistics. */
int rm_flashraw_frame_statistics(rm_flashraw_frame *frame, rm_flashraw_decode_statistics *out);
const void *rm_flashraw_frame_data(rm_flashraw_frame *frame, size_t *byte_count);

/* Narrow scene intake: unbalanced Bayer frame with one database XYZ-to-camera matrix.
   Zero means the decoder or the frame does not satisfy this contract. */
typedef struct rm_flashraw_scene_bayer {
    uint32_t active[4];
    uint32_t crop[4];
    uint32_t colors[4];
    float black[4];
    float white[4];
    float white_balance[4];
    float xyz_to_camera[9];
} rm_flashraw_scene_bayer;
int rm_flashraw_scene_dimensions(const rm_flashraw_context *context, uint32_t *width, uint32_t *height);
int rm_flashraw_frame_scene_bayer(rm_flashraw_frame *frame, rm_flashraw_scene_bayer *out);

#ifdef __cplusplus
}
#endif
#endif
