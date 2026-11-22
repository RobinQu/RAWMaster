#ifndef RAWMASTER_PHOTO_EXPORT_H
#define RAWMASTER_PHOTO_EXPORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ABI 1. All numeric width/height coordinates count pixels. */
uint32_t rm_photo_export_abi(void);
size_t rm_photo_export_limit(void);

/* Operations: 1 preset JSON, 2 geometry JSON, 3 name JSON, 4 UTF-8 template, 5 JSON count.
   Returns UTF-8 JSON with value or error/code. Pair each non-NULL result with free. */
uint8_t *rm_photo_export_request(uint32_t op, const uint8_t *input, size_t input_len, size_t *out_len);
void rm_photo_export_free(uint8_t *output, size_t len);

/* Borrowed top-down bitmap for this call only. Pixel format 1: RGBX8, 2: native-endian RGBA16.
   Codec 1: JPEG, 2: PNG, 3: TIFF. Paths are UTF-8. Output must not already exist.
   Status: 0 success, 1 invalid input, 2 exists, 3 I/O, 4 capture date, 5 codec failure. */
int32_t rm_photo_export_encode(const char *path, const uint8_t *pixels, uint32_t width, uint32_t height,
                               size_t stride, size_t len, uint32_t pixel_format, uint32_t codec, uint8_t quality);
int32_t rm_photo_export_publish(const char *stage, const char *destination);

#ifdef __cplusplus
}
#endif
#endif
