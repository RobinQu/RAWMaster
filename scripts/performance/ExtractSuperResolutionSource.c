/* Emit the source-native upright RGBF16 plane of the real RAW used by the learned 2x quality probe. */
#include "CFlashRaw.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, const char *argv[]) {
    if ((argc != 3 && argc != 4) || !getenv("RAWMASTER_FLASHRAW_LIBRARY")) return 2;
    int backend = 1;
    if (argc == 4) {
        if (!strcmp(argv[3], "gpu")) backend = 3;
        else if (strcmp(argv[3], "cpu")) return 2;
    }
    char error[512] = {0};
    rm_flashraw_context *raw = rm_flashraw_open(argv[1], getenv("RAWMASTER_FLASHRAW_LIBRARY"), error, sizeof(error));
    if (!raw) { fprintf(stderr,"%s\n",error); return 1; }
    rm_flashraw_frame *frame = NULL;
    int result = 1;
    if (strcmp(rm_flashraw_version(raw), "0.3.1") ||
        rm_flashraw_decode(raw, backend, 7, 0, 0, 0, 0, 0, 0, &frame, error, sizeof(error)) != 0) goto done;
    rm_flashraw_frame_info info = rm_flashraw_frame_get_info(frame);
    size_t size = 0;
    const void *bytes = rm_flashraw_frame_data(frame,&size);
    if (!bytes || info.orientation != 1 || info.channels != 3 || info.sample_type != 4 || info.incomplete ||
        size != (size_t)info.width*info.height*6) goto done;
    FILE *out = fopen(argv[2],"wbx");
    if (!out) goto done;
    const size_t written = fwrite(bytes,1,size,out);
    const int closed = fclose(out);
    if (written != size || closed) { remove(argv[2]); goto done; }
    printf("%u %u %zu\n",info.width,info.height,size);
    result = 0;
done:
    if (result) fprintf(stderr,"FlashRaw source extraction failed. %s\n",error);
    if (frame) rm_flashraw_frame_free(frame);
    rm_flashraw_close(raw);
    return result;
}
