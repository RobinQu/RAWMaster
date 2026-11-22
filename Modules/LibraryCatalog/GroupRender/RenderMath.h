#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  double rotation[9], homography[9];
  double p50, p95, rotationP95, translationP95, support, deltaX, deltaY;
  int pairs, inliers, secondaryMotionInliers;
} GRMatch;
int gr_register(const uint8_t *reference, const uint8_t *moving, int w, int h,
                double focal, GRMatch *result);
int gr_anchor(const uint8_t *ref, const uint8_t *moving, int w, int h,
              double top, GRMatch *result);
void gr_foreground(float *rgb, const float *reference, int w, int h, double top,
                   uint64_t *counts);
int gr_mtb(const uint8_t *ref, const uint8_t *moving, int w, int h,
           double *result);
void gr_luma8(const float *rgba, uint8_t *gray, int pixels);
void gr_star(float *rgb, uint16_t *owners, const float *rgba, int pixels,
             int frame, uint64_t *changed);
void gr_hdr(float *rgb, float *weights, uint8_t *ghost, const float *reference,
            const float *moving, int w, int h, double dx, double dy,
            double exposureRatio, int isReference, double threshold,
            uint64_t *counts);
void gr_hdr_finish(float *rgb, const float *weights, const uint8_t *ghost,
                   const float *reference, int pixels, uint64_t *counts);
int gr_bounds(const double *rotation, int w, int h, double focal,
              double *bounds);
void gr_cylinder(const float *rgba, int w, int h, const double *rotation,
                 double focal, int ox, int oy, int width, int height,
                 float gain, float *colors, float *weights);
void gr_blend_bands(float *rgb, const float *warps, const float *weights, int n,
                    int w, int h, int bands, uint8_t *mask);
void gr_valid_rect(const uint8_t *mask, int w, int h, int *rectangle);
int gr_tiff(const char *path, const float *rgb, int w, int h,
            const uint8_t *icc, int iccLength, double *statistics);
#ifdef __cplusplus
}
#endif
