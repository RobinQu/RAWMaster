#ifndef RAWMASTER_NATIVE_HALF_PROBE_H
#define RAWMASTER_NATIVE_HALF_PROBE_H
#include "../../include/rawmaster_image_metal.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Research-only extension enabled by native-half-probe. The default runtime has
   no such symbols. Input and exclusive unpublished output must both be fully
   initialized and producer-joined; caller holds both leases until render returns.
   Open plans and programs with functions from this same runtime instance.
   The required current callback checks source/consumer authority. A failed,
   stale or cancelled call confers no right to display any written pixels. */
typedef struct RMHalfProbe RMHalfProbe;
int32_t rm_image_half_program_open_probe_v1(const RMImagePlan *recipe, void *device, RMHalfProbe **out);
/* Output physical y=0 corresponds to the final physical input row. Import
   as linear RGBAf without a second flip, matching the stock physical half.
   Modes 0,1,2: nested mix, horizontally paired average, vertically paired average.
   Modes 3 and 4: two passes per joined 256-row native band, GPU hardware bilinear.
   Mode 4 requires optional subgroup arithmetic and changes the visit counter only.
   Modes 5/6 record two/four original mode-3 bands in one ordered native command.
   Revision must remain current before submission, after submission and after join. */
int32_t rm_image_half_render_probe_v1(const RMHalfProbe *program, const RMImagePlan *parameters,
  void *private_rgba16f_source, void *private_rgba32f_half, uint32_t mode, uint64_t revision,
  RMImageMetalIsCurrentV1 current, void *context);
void rm_image_half_program_close_probe_v1(RMHalfProbe *program);
#ifdef __cplusplus
}
#endif
#endif
