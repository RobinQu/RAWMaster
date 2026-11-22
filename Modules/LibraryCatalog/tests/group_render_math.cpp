#include "../GroupRender/RenderMath.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <opencv2/imgproc.hpp>
#include <vector>

static void starRetainsWinnerChromaticity() {
  const float a[] = {.8f, .1f, .2f, 1, .1f, .8f, .1f, 1, .2f, .2f, .2f, 1};
  const float b[] = {.1f, .7f, .1f, 1, .9f, .1f, .1f, 1, .2f, .2f, .2f, 1};
  float rgb[9]{};
  uint16_t owners[3]{};
  uint64_t changed = 0;
  gr_star(rgb, owners, a, 3, 0, &changed);
  assert(changed == 3);
  gr_star(rgb, owners, b, 3, 1, &changed);
  assert(changed == 1);
  assert(owners[0] == 1 && owners[1] == 0 && owners[2] == 0);
  assert(rgb[0] == b[0] && rgb[1] == b[1] && rgb[3] == a[4]);
}
static void hdrLabeledMotionAndClipping() {
  constexpr int w = 48, h = 28, n = w * h;
  std::vector<float> ref(4 * n), shorter(4 * n), longer(4 * n), out(3 * n),
      weight(n);
  std::vector<uint8_t> motion(n);
  for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x) {
      int i = y * w + x;
      float scene = x >= 36 ? 1.6f : x < 4 ? 0.f : .22f;
      for (int k = 0; k < 3; ++k) {
        ref[4 * i + k] = std::min(scene, 1.f);
        shorter[4 * i + k] = (x >= 16 && x < 24 && y >= 6 && y < 18)
                                 ? .16f
                                 : std::min(scene / 4, 1.f);
        longer[4 * i + k] = std::min(scene * 2, 1.f);
      }
    }
  uint64_t counters[3]{};
  gr_hdr(out.data(), weight.data(), motion.data(), ref.data(), shorter.data(),
         w, h, 0, 0, 4, 0, .25, counters);
  gr_hdr(out.data(), weight.data(), motion.data(), ref.data(), ref.data(), w, h,
         0, 0, 1, 1, .25, counters);
  gr_hdr(out.data(), weight.data(), motion.data(), ref.data(), longer.data(), w,
         h, 0, 0, .5, 0, .25, counters);
  gr_hdr_finish(out.data(), weight.data(), motion.data(), ref.data(), n,
                counters);
  assert(counters[0] == 4 * h && counters[1] == 8 * 12);
  for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x) {
      int i = y * w + x;
      assert(bool(motion[i]) == (x >= 16 && x < 24 && y >= 6 && y < 18));
      float expected = x >= 36 ? 1.6f : x < 4 ? 0.f : .22f;
      assert(std::abs(out[3 * i] - expected) < 1.e-6);
    }
}
static void panoramaGeometryAndParallax() {
  constexpr int w = 640, h = 420;
  cv::Mat scene(h, w, CV_8U);
  cv::RNG rng(9919);
  rng.fill(scene, cv::RNG::UNIFORM, 0, 255);
  cv::GaussianBlur(scene, scene, {3, 3}, .8);
  for (int i = 0; i < 500; ++i)
    cv::circle(scene, {rng.uniform(8, w - 8), rng.uniform(8, h - 8)},
               rng.uniform(2, 9), rng.uniform(15, 245), -1);
  cv::Mat moved;
  cv::warpAffine(scene, moved, cv::Matx23f(1, 0, 20, 0, 1, 0), scene.size(),
                 cv::INTER_LINEAR, cv::BORDER_REFLECT);
  GRMatch good{};
  assert(gr_register(scene.data, moved.data, w, h, 2500, &good) == 0);
  assert(good.inliers > 200 && good.secondaryMotionInliers == 0 &&
         std::abs(good.deltaX + 20) < .3);
  cv::Mat foreground;
  cv::warpAffine(scene, foreground, cv::Matx23f(1, 0, -17, 0, 1, 3),
                 scene.size(), cv::INTER_LINEAR, cv::BORDER_REFLECT);
  cv::Rect region(48, 80, 260, 240);
  foreground(region).copyTo(moved(region));
  GRMatch layers{};
  assert(gr_register(scene.data, moved.data, w, h, 2500, &layers) == 0);
  assert(layers.secondaryMotionInliers > 50);
  cv::Mat blank = cv::Mat::zeros(h, w, CV_8U);
  GRMatch none{};
  assert(gr_register(scene.data, blank.data, w, h, 2500, &none) != 0);
  std::vector<uint8_t> mask(5 * 4, 0);
  for (int y = 1; y < 4; ++y)
    for (int x = 1; x < 4; ++x)
      mask[5 * y + x] = 1;
  int rect[4]{};
  gr_valid_rect(mask.data(), 5, 4, rect);
  assert(rect[0] == 1 && rect[1] == 1 && rect[2] == 3 && rect[3] == 3);
}
int main() {
  starRetainsWinnerChromaticity();
  hdrLabeledMotionAndClipping();
  panoramaGeometryAndParallax();
  std::puts("star colour/tie, HDR labeled motion/clipping, panorama "
            "two-depth/disconnection/crop passed");
}
