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

rm_flashraw_context *rm_flashraw_open(const char *path, const char *library_path,
                                       char *error, size_t error_capacity);
void rm_flashraw_close(rm_flashraw_context *context);
const char *rm_flashraw_version(rm_flashraw_context *context);

int rm_flashraw_decode(rm_flashraw_context *context, int32_t backend, int32_t output,
                       int32_t demosaic, int32_t has_region,
                       uint32_t x, uint32_t y, uint32_t width, uint32_t height,
                       rm_flashraw_frame **out, char *error, size_t error_capacity);
void rm_flashraw_frame_free(rm_flashraw_frame *frame);
rm_flashraw_frame_info rm_flashraw_frame_get_info(rm_flashraw_frame *frame);
const void *rm_flashraw_frame_data(rm_flashraw_frame *frame, size_t *byte_count);

#ifdef __cplusplus
}
#endif
#endif
