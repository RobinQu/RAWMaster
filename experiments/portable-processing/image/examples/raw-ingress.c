// Direct Linux C client of the repository's FlashRaw bridge and the Rust edit ABI.
// The fixed Sony ROI has orientation 1. This probe exercises that versioned input contract.
#include "CFlashRaw.h"
#include "flashraw.h"
#include "image_probe.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: raw-ingress FILE.ARW LIBFLASHRAW OUTPUT.rgba32fle\n"); return 2; }
    const uint32_t x = 3500, y = 1800, w = 512, h = 384;
    const size_t n = (size_t)w * h;
    char error[512] = {0};
    int status = 1;
    rm_flashraw_context *decoder = rm_flashraw_open(argv[1], argv[2], error, sizeof(error));
    rm_flashraw_frame *frame = NULL;
    RmiPlan *plan = NULL;
    float *rgba = NULL, *mask = NULL, *out = NULL;
    if (!decoder || rm_flashraw_decode(decoder, FLASHRAW_BACKEND_CPU_SIMD, FLASHRAW_OUTPUT_LINEAR_RGB_F32,
        FLASHRAW_DEMOSAIC_AUTO, 1, x, y, w, h, &frame, error, sizeof(error)) != 0) {
        fprintf(stderr, "decode: %s\n", error);
        goto done;
    }
    rm_flashraw_frame_info info = rm_flashraw_frame_get_info(frame);
    size_t bytes = 0;
    const float *rgb = rm_flashraw_frame_data(frame, &bytes);
    if (!rgb || info.incomplete || info.width != w || info.height != h || info.origin_x != x || info.origin_y != y ||
        info.orientation != 1 || info.channels != 3 || info.sample_type != FLASHRAW_SAMPLE_F32 ||
        info.output_format != FLASHRAW_OUTPUT_LINEAR_RGB_F32 || bytes != n*3*sizeof(float)) {
        fprintf(stderr, "unexpected decoder frame layout or orientation\n"); goto done;
    }
    rgba = malloc(n*4*sizeof(float)); out = malloc(n*4*sizeof(float)); mask = calloc(n, sizeof(float));
    if (!rgba || !out || !mask) goto done;
    for (size_t i = 0; i < n; ++i) {
        memcpy(rgba+4*i, rgb+3*i, 3*sizeof(float)); rgba[4*i+3] = 1;
    }
    const char *graph = "{\"version\":1,\"working\":\"extended-linear-srgb-premul-f32\",\"output\":\"e\","
        "\"nodes\":[{\"id\":\"s\",\"op\":\"source\"},{\"id\":\"e\",\"op\":\"exposure\",\"image\":\"s\",\"ev\":1}]}";
    if (rmi_open_v1(graph, strlen(graph), RMI_CPU, &plan) || rmi_render_v1(plan, w, h, rgba, 4*n, mask, n, out, 4*n)) {
        fprintf(stderr, "image ABI rejected decoded frame\n"); goto done;
    }
    float peak = 0, max_error = 0;
    for (size_t i = 0; i < n; ++i) {
        for (size_t c = 0; c < 3; ++c) {
            peak = fmaxf(peak, out[4*i+c]);
            max_error = fmaxf(max_error, fabsf(2*rgba[4*i+c]-out[4*i+c]));
        }
        if (out[4*i+3] != 1) goto done;
    }
    if (max_error != 0 || peak <= 0) goto done;
    FILE *f = fopen(argv[3], "wbx");
    if (!f) goto done;
    size_t written = fwrite(out, 4*sizeof(float), n, f);
    if (fclose(f) || written != n) goto done;
    printf("{\"decoder\":\"FlashRaw %s\", \"roi\":[%u,%u,%u,%u], \"orientation\":%u, "
        "\"maxAbsErrorVs2x\":%.9g, \"peakRGB\":%.9g, \"floatBytes\":%zu}\n",
        rm_flashraw_version(decoder), x,y,w,h,info.orientation,max_error,peak,4*n*sizeof(float));
    status = 0;
done:
    rmi_close_v1(plan); free(out); free(mask); free(rgba);
    if (frame) rm_flashraw_frame_free(frame);
    if (decoder) rm_flashraw_close(decoder);
    return status;
}
