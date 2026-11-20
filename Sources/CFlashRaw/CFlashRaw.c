#include "CFlashRaw.h"
#include "flashraw.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct rm_flashraw_context {
    void *library;
    flashraw_file *file;
    flashraw_status (*open_path)(const char *, const flashraw_open_options *, flashraw_file **);
    const char *(*error_name)(int32_t);
    uint32_t (*abi_version)(void);
    const char *(*version)(void);
    void (*file_free)(flashraw_file *);
    flashraw_status (*decode_options_init)(flashraw_decode_options *);
    flashraw_status (*decode)(const flashraw_file *, const flashraw_decode_options *, flashraw_frame **);
    const char *(*last_error)(void);
    void (*frame_free)(flashraw_frame *);
    uint32_t (*frame_width)(const flashraw_frame *);
    uint32_t (*frame_height)(const flashraw_frame *);
    uint32_t (*frame_cpp)(const flashraw_frame *);
    uint32_t (*frame_orientation)(const flashraw_frame *);
    int32_t (*frame_sample_type)(const flashraw_frame *);
    int32_t (*frame_output_format)(const flashraw_frame *);
    int32_t (*frame_source)(const flashraw_frame *);
    bool (*frame_incomplete)(const flashraw_frame *);
    const void *(*frame_data)(const flashraw_frame *);
    size_t (*frame_data_len)(const flashraw_frame *);
    flashraw_status (*frame_origin)(const flashraw_frame *, uint32_t *, uint32_t *);
};

struct rm_flashraw_frame {
    flashraw_frame *handle;
    rm_flashraw_context *context;
};

static void set_error(char *error, size_t capacity, const char *message) {
    if (error && capacity) {
        snprintf(error, capacity, "%s", message ? message : "FlashRaw error");
    }
}

static int fail(rm_flashraw_context *context, flashraw_status status,
                rm_flashraw_frame **out, char *error, size_t capacity) {
    const char *message = context && context->last_error ? context->last_error() : NULL;
    if ((!message || !*message) && context && context->error_name) message = context->error_name(status);
    set_error(error, capacity, message);
    if (out) *out = NULL;
    return -1;
}

static void *symbol(void *library, const char *name) {
    return dlsym(library, name);
}

rm_flashraw_context *rm_flashraw_open(const char *path, const char *library_path,
                                       char *error, size_t error_capacity) {
    if (!path || !library_path) {
        set_error(error, error_capacity, "FlashRaw path and library path are required");
        return NULL;
    }
    rm_flashraw_context *c = calloc(1, sizeof(*c));
    if (!c) {
        set_error(error, error_capacity, "FlashRaw allocation failed");
        return NULL;
    }
    c->library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!c->library) {
        set_error(error, error_capacity, dlerror());
        free(c);
        return NULL;
    }
#define LOAD(field, name) do { c->field = symbol(c->library, name); if (!c->field) goto missing; } while (0)
    LOAD(open_path, "flashraw_open_path");
    LOAD(error_name, "flashraw_error_kind_name");
    LOAD(abi_version, "flashraw_abi_version");
    LOAD(version, "flashraw_version");
    LOAD(file_free, "flashraw_file_free");
    LOAD(decode_options_init, "flashraw_decode_options_init");
    LOAD(decode, "flashraw_decode");
    LOAD(last_error, "flashraw_last_error_message");
    LOAD(frame_free, "flashraw_frame_free");
    LOAD(frame_width, "flashraw_frame_width");
    LOAD(frame_height, "flashraw_frame_height");
    LOAD(frame_cpp, "flashraw_frame_cpp");
    LOAD(frame_orientation, "flashraw_frame_orientation");
    LOAD(frame_sample_type, "flashraw_frame_sample_type");
    LOAD(frame_output_format, "flashraw_frame_output_format");
    LOAD(frame_source, "flashraw_frame_source");
    LOAD(frame_incomplete, "flashraw_frame_is_incomplete");
    LOAD(frame_data, "flashraw_frame_data");
    LOAD(frame_data_len, "flashraw_frame_data_len");
    LOAD(frame_origin, "flashraw_frame_origin");
#undef LOAD
    if (c->abi_version() != FLASHRAW_ABI_VERSION) {
        set_error(error, error_capacity, "FlashRaw ABI version mismatch");
        rm_flashraw_close(c);
        return NULL;
    }
    flashraw_status status = c->open_path(path, NULL, &c->file);
    if (status != FLASHRAW_OK) {
        fail(c, status, NULL, error, error_capacity);
        rm_flashraw_close(c);
        return NULL;
    }
    return c;
missing:
    set_error(error, error_capacity, "FlashRaw library is missing a required symbol");
    rm_flashraw_close(c);
    return NULL;
}

void rm_flashraw_close(rm_flashraw_context *context) {
    if (!context) return;
    if (context->file && context->file_free) context->file_free(context->file);
    if (context->library) dlclose(context->library);
    free(context);
}

const char *rm_flashraw_version(rm_flashraw_context *context) {
    return context && context->version ? context->version() : NULL;
}

int rm_flashraw_decode(rm_flashraw_context *context, int32_t backend, int32_t output,
                       int32_t demosaic, int32_t has_region,
                       uint32_t x, uint32_t y, uint32_t width, uint32_t height,
                       rm_flashraw_frame **out, char *error, size_t error_capacity) {
    if (out) *out = NULL;
    if (!context || !out) {
        set_error(error, error_capacity, "Invalid FlashRaw decode arguments");
        return -1;
    }
    flashraw_decode_options options;
    flashraw_status status = context->decode_options_init(&options);
    if (status != FLASHRAW_OK) return fail(context, status, out, error, error_capacity);
    options.backend = backend;
    options.output = output;
    options.demosaic = demosaic;
    if (has_region) {
        options.use_region = 1;
        options.region = (flashraw_rect){x, y, width, height};
    }
    flashraw_frame *frame = NULL;
    status = context->decode(context->file, &options, &frame);
    if (status != FLASHRAW_OK) return fail(context, status, out, error, error_capacity);
    rm_flashraw_frame *result = calloc(1, sizeof(*result));
    if (!result) {
        context->frame_free(frame);
        set_error(error, error_capacity, "FlashRaw frame allocation failed");
        return -1;
    }
    result->handle = frame;
    result->context = context;
    *out = result;
    return 0;
}

void rm_flashraw_frame_free(rm_flashraw_frame *frame) {
    if (!frame) return;
    frame->context->frame_free(frame->handle);
    free(frame);
}

rm_flashraw_frame_info rm_flashraw_frame_get_info(rm_flashraw_frame *frame) {
    rm_flashraw_frame_info info = {0};
    if (!frame) return info;
    rm_flashraw_context *c = frame->context;
    flashraw_frame *f = frame->handle;
    info.width = c->frame_width(f);
    info.height = c->frame_height(f);
    info.channels = c->frame_cpp(f);
    info.orientation = c->frame_orientation(f);
    info.sample_type = c->frame_sample_type(f);
    info.output_format = c->frame_output_format(f);
    info.source = c->frame_source(f);
    info.incomplete = c->frame_incomplete(f) ? 1 : 0;
    if (c->frame_origin(f, &info.origin_x, &info.origin_y) != FLASHRAW_OK) {
        info.origin_x = 0;
        info.origin_y = 0;
    }
    return info;
}

const void *rm_flashraw_frame_data(rm_flashraw_frame *frame, size_t *byte_count) {
    if (byte_count) *byte_count = 0;
    if (!frame) return NULL;
    const void *data = frame->context->frame_data(frame->handle);
    if (byte_count) *byte_count = frame->context->frame_data_len(frame->handle);
    return data;
}
