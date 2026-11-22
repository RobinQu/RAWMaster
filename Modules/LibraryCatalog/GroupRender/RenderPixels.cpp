#include "RenderMath.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <opencv2/imgproc.hpp>
#include <vector>

namespace {
inline float luminance(const float *a) {
  return .2126f * a[0] + .7152f * a[1] + .0722f * a[2];
}
inline void sample(const float *im, int w, int h, double x, double y,
                   float *a) {
  x = std::clamp(x, 0., double(w - 1));
  y = std::clamp(y, 0., double(h - 1));
  int ix = int(x), iy = int(y);
  const float *p = im + 4 * (size_t(iy) * w + ix);
  const float *q = im + 4 * (size_t(std::min(iy + 1, h - 1)) * w + ix);
  int step = ix + 1 < w ? 4 : 0;
  float ax = float(x - ix), ay = float(y - iy);
  for (int k = 0; k < 3; ++k)
    a[k] = ((1 - ax) * p[k] + ax * p[step + k]) * (1 - ay) +
           ((1 - ax) * q[k] + ax * q[step + k]) * ay;
}
inline float weight(const float *v) {
  float z = std::max({v[0], v[1], v[2]});
  if (!std::isfinite(z) || z <= .002f || z >= .96f)
    return 0;
  return std::min({1.f, (z - .002f) / .085f, (.96f - z) / .23f});
}
} // namespace

extern "C" void gr_luma8(const float *rgba, uint8_t *gray, int n) {
  // Tone compression is restricted to registration proxies.
  for (int i = 0; i < n; ++i)
    gray[i] = uint8_t(std::clamp(
        255.f * std::log1p(15.f * std::max(0.f, luminance(rgba + 4 * i))) /
            std::log(16.f),
        0.f, 255.f));
}
extern "C" void gr_star(float *rgb, uint16_t *owners, const float *rgba, int n,
                        int frame, uint64_t *changed) {
  uint64_t count = 0;
  for (int i = 0; i < n; ++i) {
    const float *in = rgba + 4 * i;
    float *out = rgb + 3 * i;
    if (frame == 0 || luminance(in) > luminance(out)) {
      for (int k = 0; k < 3; ++k)
        out[k] = in[k];
      owners[i] = uint16_t(frame);
      ++count;
    }
  }
  *changed = count;
}
extern "C" void gr_hdr(float *rgb, float *weights, uint8_t *ghost,
                       const float *ref, const float *in, int w, int h,
                       double dx, double dy, double ratio, int isReference,
                       double threshold, uint64_t *counts) {
  counts[0] = counts[1] = counts[2] = 0;
  for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x) {
      size_t i = size_t(y) * w + x;
      double sx = x - dx, sy = y - dy;
      if (sx < 0 || sy < 0 || sx > w - 1 || sy > h - 1)
        continue;
      float p[3];
      sample(in, w, h, sx, sy, p);
      float ww = weight(p);
      if (ww == 0) {
        ++counts[2];
        continue;
      }
      const float *r = ref + 4 * i;
      float yy = luminance(p) * float(ratio), ry = luminance(r);
      if (!isReference && weight(r) > .25f &&
          std::abs(yy - ry) > std::max(.018, threshold * std::max(yy, ry))) {
        ghost[i] = 1;
        ++counts[1];
      }
      for (int k = 0; k < 3; ++k)
        rgb[3 * i + k] += p[k] * float(ratio) * ww;
      weights[i] += ww;
      ++counts[0];
    }
}
extern "C" void gr_hdr_finish(float *rgb, const float *weights,
                              const uint8_t *ghost, const float *ref, int n,
                              uint64_t *counts) {
  counts[0] = counts[1] = 0;
  for (int i = 0; i < n; ++i) {
    bool noWeight = weights[i] <= 1e-8f;
    if (noWeight)
      ++counts[0];
    if (ghost[i])
      ++counts[1];
    for (int k = 0; k < 3; ++k)
      rgb[3 * i + k] =
          noWeight || ghost[i] ? ref[4 * i + k] : rgb[3 * i + k] / weights[i];
  }
}
extern "C" int gr_bounds(const double *a, int w, int h, double f, double *b) {
  cv::Matx33d r(a);
  double low = std::numeric_limits<double>::infinity();
  b[0] = b[1] = low;
  b[2] = b[3] = -low;
  double center = std::atan2(r(0, 2), r(2, 2));
  for (int i = 0; i <= 100; ++i)
    for (int side = 0; side < 4; ++side) {
      double t = i / 100.;
      double x = side < 2 ? t * (w - 1) : (side == 2 ? 0 : w - 1);
      double y = side >= 2 ? t * (h - 1) : (side == 0 ? 0 : h - 1);
      cv::Vec3d d =
          r * cv::Vec3d((x - (w - 1) * .5) / f, (y - (h - 1) * .5) / f, 1.);
      double radius = std::hypot(d[0], d[2]);
      if (radius < .1)
        return 1;
      double theta =
          center + std::remainder(std::atan2(d[0], d[2]) - center, 2 * M_PI);
      double u = f * theta, v = f * d[1] / radius;
      b[0] = std::min(b[0], u);
      b[1] = std::min(b[1], v);
      b[2] = std::max(b[2], u);
      b[3] = std::max(b[3], v);
    }
  return 0;
}
extern "C" void gr_cylinder(const float *rgba, int w, int h, const double *a,
                            double f, int ox, int oy, int tw, int th,
                            float gain, float *colors, float *weights) {
  cv::Matx33d r = cv::Matx33d(a).t();
  std::vector<double> sine(tw), cosine(tw);
  for (int x = 0; x < tw; ++x) {
    double ang = (x + ox) / f;
    sine[x] = std::sin(ang);
    cosine[x] = std::cos(ang);
  }
  float feather = std::max(8.f, .09f * std::min(w, h));
  for (int y = 0; y < th; ++y)
    for (int x = 0; x < tw; ++x) {
      size_t i = size_t(y) * tw + x;
      cv::Vec3d d = r * cv::Vec3d(sine[x], (y + oy) / f, cosine[x]);
      if (d[2] <= .05) {
        weights[i] = 0;
        colors[3 * i] = colors[3 * i + 1] = colors[3 * i + 2] = 0;
        continue;
      }
      double sx = f * d[0] / d[2] + (w - 1) * .5,
             sy = f * d[1] / d[2] + (h - 1) * .5;
      double distance = std::min({sx, sy, w - 1. - sx, h - 1. - sy});
      weights[i] = distance >= 0
                       ? std::clamp(float(distance + 1) / feather, .001f, 1.f)
                       : 0.f;
      // Extend border colours so Gaussian kernels never pull black into a
      // covered seam.
      float *p = colors + 3 * i;
      sample(rgba, w, h, sx, sy, p);
      for (int k = 0; k < 3; ++k)
        p[k] *= gain;
    }
}
extern "C" void gr_blend_bands(float *rgb, const float *warps,
                               const float *weights, int n, int w, int h,
                               int bands, uint8_t *maskOut) {
  std::vector<cv::Mat> sum(bands + 1), denominator(bands + 1);
  size_t size = size_t(w) * h;
  for (int j = 0; j < n; ++j) {
    cv::Mat current(h, w, CV_32FC3, const_cast<float *>(warps + 3 * j * size));
    cv::Mat mask(h, w, CV_32F, const_cast<float *>(weights + j * size));
    for (int l = 0; l <= bands; ++l) {
      cv::Mat coarse, maskCoarse, lap;
      if (l < bands) {
        cv::pyrDown(current, coarse);
        cv::pyrDown(mask, maskCoarse);
        cv::Mat up;
        cv::pyrUp(coarse, up, current.size());
        cv::subtract(current, up, lap);
      } else
        lap = current;
      if (sum[l].empty()) {
        sum[l] = cv::Mat::zeros(lap.size(), CV_32FC3);
        denominator[l] = cv::Mat::zeros(lap.size(), CV_32F);
      }
      for (int y = 0; y < lap.rows; ++y) {
        auto *t = sum[l].ptr<cv::Vec3f>(y);
        auto *d = denominator[l].ptr<float>(y);
        auto *v = lap.ptr<cv::Vec3f>(y);
        auto *m = mask.ptr<float>(y);
        for (int x = 0; x < lap.cols; ++x) {
          t[x] += v[x] * m[x];
          d[x] += m[x];
        }
      }
      current = coarse;
      mask = maskCoarse;
    }
  }
  cv::Mat result;
  for (int l = bands; l >= 0; --l) {
    for (int y = 0; y < sum[l].rows; ++y) {
      auto *v = sum[l].ptr<cv::Vec3f>(y);
      auto *d = denominator[l].ptr<float>(y);
      for (int x = 0; x < sum[l].cols; ++x)
        if (d[x] > 1e-9f)
          v[x] /= d[x];
    }
    if (result.empty())
      result = sum[l];
    else {
      cv::Mat up;
      cv::pyrUp(result, up, sum[l].size());
      result = up + sum[l];
    }
  }
  for (size_t i = 0; i < size; ++i) {
    int cover = 0;
    for (int j = 0; j < n; ++j)
      cover += weights[j * size + i] > 0;
    maskOut[i] = uint8_t(std::min(cover, 255));
    auto p = result.ptr<cv::Vec3f>()[i];
    for (int k = 0; k < 3; ++k)
      rgb[3 * i + k] = cover ? p[k] : 0;
  }
}
extern "C" void gr_valid_rect(const uint8_t *mask, int w, int h, int *rect) {
  // Largest all-covered axis-aligned rectangle, O(width) working space.
  std::vector<int> heights(w + 1), stack;
  int64_t best = 0;
  std::fill(rect, rect + 4, 0);
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x)
      heights[x] = mask[size_t(y) * w + x] ? heights[x] + 1 : 0;
    stack.clear();
    for (int x = 0; x <= w; ++x) {
      while (!stack.empty() && heights[stack.back()] > heights[x]) {
        int height = heights[stack.back()];
        stack.pop_back();
        int left = stack.empty() ? 0 : stack.back() + 1;
        int64_t area = int64_t(x - left) * height;
        if (area > best) {
          best = area;
          rect[0] = left;
          rect[1] = y - height + 1;
          rect[2] = x - left;
          rect[3] = height;
        }
      }
      stack.push_back(x);
    }
  }
}

extern "C" void gr_foreground(float *rgb, const float *ref, int w, int h,
                              double top, uint64_t *counts) {
  counts[0] = counts[1] = 0;
  // Feather from the specified boundary downwards. Sky above the boundary
  // retains the star accumulation.
  double feather = std::max(1. / h, .015);
  for (int y = 0; y < h; ++y) {
    double t = std::clamp(((y + .5) / h - top) / feather, 0., 1.);
    if (t <= 0)
      continue;
    t = t * t * (3. - 2. * t);
    if (t >= 1)
      counts[0] += w;
    else
      counts[1] += w;
    for (int x = 0; x < w; ++x) {
      int64_t i = int64_t(y) * w + x;
      for (int k = 0; k < 3; ++k)
        rgb[3 * i + k] = float((1. - t) * rgb[3 * i + k] + t * ref[4 * i + k]);
    }
  }
}
