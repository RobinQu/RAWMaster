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
    uint32_t (*file_width)(const flashraw_file *);
    int32_t (*file_sensor_layout)(const flashraw_file *);
    uint32_t (*file_height)(const flashraw_file *);
    uint32_t (*file_orientation)(const flashraw_file *);
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
    flashraw_status (*frame_stats)(const flashraw_frame *, flashraw_decode_stats *);
    const char *(*frame_backend)(const flashraw_frame *);
    const char *(*frame_postprocess_backend)(const flashraw_frame *);
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
    return rm_flashraw_open_checked(path, library_path, NULL, error, error_capacity);
}

rm_flashraw_context *rm_flashraw_open_checked(const char *path, const char *library_path,
        rm_flashraw_open_status *open_status, char *error, size_t error_capacity) {
    if (open_status) *open_status = RM_FLASHRAW_OPEN_RUNTIME_UNAVAILABLE;
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
    LOAD(file_sensor_layout, "flashraw_file_sensor_layout");
    LOAD(file_width, "flashraw_file_width");
    LOAD(file_height, "flashraw_file_height");
    LOAD(file_orientation, "flashraw_file_orientation");
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
    LOAD(frame_stats, "flashraw_frame_stats");
    LOAD(frame_backend, "flashraw_frame_backend");
    LOAD(frame_postprocess_backend, "flashraw_frame_postprocess_backend");
#undef LOAD
    if (c->abi_version() != FLASHRAW_ABI_VERSION) {
        set_error(error, error_capacity, "FlashRaw ABI version mismatch");
        rm_flashraw_close(c);
        return NULL;
    }
    flashraw_status status = c->open_path(path, NULL, &c->file);
    if (status != FLASHRAW_OK) {
        if (open_status) *open_status = RM_FLASHRAW_OPEN_SOURCE_UNREADABLE;
        fail(c, status, NULL, error, error_capacity);
        rm_flashraw_close(c);
        return NULL;
    }
    if (open_status) *open_status = RM_FLASHRAW_OPEN_OK;
    return c;
missing:
    set_error(error, error_capacity, "FlashRaw library is missing a required symbol");
    rm_flashraw_close(c);
    return NULL;
}

int32_t rm_flashraw_sensor_layout(const rm_flashraw_context *context) {
    return context && context->file ? context->file_sensor_layout(context->file) : FLASHRAW_LAYOUT_UNKNOWN;
}

void rm_flashraw_close(rm_flashraw_context *context) {
    if (!context) return;
    if (context->file && context->file_free) context->file_free(context->file);
    if (context->library) dlclose(context->library);
    free(context);
}

void rm_flashraw_geometry(const rm_flashraw_context *context, uint32_t *width,
                          uint32_t *height, uint32_t *orientation) {
    if (width) *width = context ? context->file_width(context->file) : 0;
    if (height) *height = context ? context->file_height(context->file) : 0;
    if (orientation) *orientation = context ? context->file_orientation(context->file) : 0;
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

int rm_flashraw_scene_dimensions(const rm_flashraw_context *context, uint32_t *width, uint32_t *height) {
    if (!context || !width || !height) return 0;
    __typeof__(&flashraw_file_format_name) format = symbol(context->library, "flashraw_file_format_name");
    __typeof__(&flashraw_file_raw_width) raw_width = symbol(context->library, "flashraw_file_raw_width");
    __typeof__(&flashraw_file_raw_height) raw_height = symbol(context->library, "flashraw_file_raw_height");
    if (!format || !raw_width || !raw_height) return 0;
    const char *name = format(context->file);
    if (!name || strcmp(name, "ARW") != 0) return 0;
    *width = raw_width(context->file);
    *height = raw_height(context->file);
    return *width > 0 && *height > 0;
}

int rm_flashraw_frame_scene_bayer(rm_flashraw_frame *frame, rm_flashraw_scene_bayer *out) {
    if (!frame || !out) return 0;
    rm_flashraw_context *c = frame->context;
    flashraw_frame *f = frame->handle;
    if (c->file_sensor_layout(c->file) != FLASHRAW_LAYOUT_BAYER ||
        c->frame_output_format(f) != FLASHRAW_OUTPUT_RAW_U16 || c->frame_sample_type(f) != FLASHRAW_SAMPLE_U16 ||
        c->frame_cpp(f) != 1 || c->frame_source(f) != FLASHRAW_SOURCE_SENSOR || c->frame_incomplete(f)) return 0;

    /* A decoder without these metadata functions still works for existing SDR paths. */
#define SCENE_LOAD(name) __typeof__(&flashraw_##name) name = symbol(c->library, "flashraw_" #name); if (!name) return 0
    SCENE_LOAD(file_active_area);
    SCENE_LOAD(file_crop);
    SCENE_LOAD(file_color_source);
    SCENE_LOAD(frame_cfa);
    SCENE_LOAD(frame_black_level);
    SCENE_LOAD(frame_white_level);
    SCENE_LOAD(frame_white_balance);
    SCENE_LOAD(frame_white_balance_applied);
    SCENE_LOAD(frame_color_matrix_count);
    SCENE_LOAD(frame_color_matrix);
#undef SCENE_LOAD

    uint32_t x, y, width, height;
    flashraw_rect active, crop;
    flashraw_cfa cfa;
    flashraw_color_matrix matrix;
    flashraw_black_level black_info;
    float black_levels[4];
    float white_balance[4];
    uint32_t white_level;
    if (c->frame_origin(f, &x, &y) != FLASHRAW_OK || x != 0 || y != 0 ||
        !rm_flashraw_scene_dimensions(c, &width, &height) || c->frame_width(f) != width || c->frame_height(f) != height ||
        file_active_area(c->file, &active) != FLASHRAW_OK || file_crop(c->file, &crop) != FLASHRAW_OK ||
        file_color_source(c->file) != FLASHRAW_COLOR_SOURCE_CAMERA_DB ||
        frame_color_matrix_count(f, FLASHRAW_MATRIX_COLOR) != 1 || frame_color_matrix_count(f, FLASHRAW_MATRIX_FORWARD) != 0 ||
        frame_color_matrix_count(f, FLASHRAW_MATRIX_CALIBRATION) != 0 ||
        frame_color_matrix(f, FLASHRAW_MATRIX_COLOR, 0, &matrix) != FLASHRAW_OK || matrix.rows != 3 || matrix.cols != 3 || matrix.illuminant != 21 ||
        !frame_cfa(f, &cfa) || cfa.width != 2 || cfa.height != 2 ||
        !frame_white_balance(f, white_balance) || frame_white_balance_applied(f) ||
        frame_white_level(f, &white_level, 1) != 1) return 0;
    size_t nblack = frame_black_level(f, &black_info, black_levels, 4);
    if (nblack == 0 || nblack > 4 || black_info.has_deltas || black_info.samples != 1 ||
        (black_info.rows != 1 && black_info.rows != 2) || (black_info.cols != 1 && black_info.cols != 2) ||
        nblack != black_info.rows * black_info.cols) return 0;

    rm_flashraw_scene_bayer result = {.active = {active.x, active.y, active.width, active.height},
                                    .crop = {crop.x, crop.y, crop.width, crop.height}};
    for (size_t i = 0; i < 4; ++i) {
        result.colors[i] = cfa.colors[i];
        result.black[i] = black_levels[((i / 2) % black_info.rows) * black_info.cols + ((i % 2) % black_info.cols)];
        result.white[i] = (float)white_level;
        result.white_balance[i] = white_balance[i];
    }
    memcpy(result.xyz_to_camera, matrix.values, sizeof(result.xyz_to_camera));
    *out = result;
    return 1;
}

const void *rm_flashraw_frame_data(rm_flashraw_frame *frame, size_t *byte_count) {
    if (byte_count) *byte_count = 0;
    if (!frame) return NULL;
    const void *data = frame->context->frame_data(frame->handle);
    if (byte_count) *byte_count = frame->context->frame_data_len(frame->handle);
    return data;
}

int rm_flashraw_frame_statistics(rm_flashraw_frame *frame, rm_flashraw_decode_statistics *out) {
    if (!frame || !out) return 0;
    flashraw_decode_stats native = {.size = sizeof(native)};
    rm_flashraw_context *context = frame->context;
    if (context->frame_stats(frame->handle, &native) != FLASHRAW_OK) return 0;
    out->threads = native.threads;
    out->total_ms = native.total_ms;
    out->input_bytes = native.input_bytes;
    out->output_bytes = native.output_bytes;
    memcpy(out->stage_ms, native.stage_ms, sizeof(out->stage_ms));
    out->backend = context->frame_backend(frame->handle);
    out->postprocess_backend = context->frame_postprocess_backend(frame->handle);
    return 1;
}
