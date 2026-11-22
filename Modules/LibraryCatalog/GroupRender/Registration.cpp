#include "RenderMath.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <opencv2/calib3d.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/imgproc.hpp>
#include <vector>

static_assert(CV_VERSION_MAJOR == 4 && CV_VERSION_MINOR == 12 &&
                  CV_VERSION_REVISION == 0,
              "The renderer requires OpenCV 4.12.0");

using cv::Mat;
using cv::Matx33d;
using cv::Point2f;
using cv::Vec3d;

namespace {
double quantile(std::vector<double> values, double fraction) {
  std::sort(values.begin(), values.end());
  return values[std::min(values.size() - 1,
                         size_t(fraction * (values.size() - 1)))];
}
Vec3d ray(Point2f p, int w, int h, double f) {
  Vec3d r((p.x - (w - 1) * 0.5) / f, (p.y - (h - 1) * 0.5) / f, 1.0);
  return r / cv::norm(r);
}
} // namespace

extern "C" int gr_register(const uint8_t *reference, const uint8_t *moving,
                           int w, int h, double f, GRMatch *out) {
  try {
    std::memset(out, 0, sizeof(*out));
    cv::setNumThreads(2);
    cv::setRNGSeed(33011);
    auto sift = cv::SIFT::create(3000, 3, .018);
    Mat a(h, w, CV_8U, const_cast<uint8_t *>(reference));
    Mat b(h, w, CV_8U, const_cast<uint8_t *>(moving));
    std::vector<cv::KeyPoint> ka, kb;
    Mat da, db;
    sift->detectAndCompute(a, cv::noArray(), ka, da);
    sift->detectAndCompute(b, cv::noArray(), kb, db);
    if (da.rows < 12 || db.rows < 12)
      return 1;
    cv::BFMatcher matcher(cv::NORM_L2);
    std::vector<std::vector<cv::DMatch>> forward, reverse;
    matcher.knnMatch(db, da, forward, 2);
    matcher.knnMatch(da, db, reverse, 2);
    std::vector<Point2f> src, dst;
    for (const auto &x : forward) {
      if (x.size() != 2 || x[0].distance >= .8 * x[1].distance)
        continue;
      const auto &y = reverse[x[0].trainIdx];
      if (y.size() != 2 || y[0].trainIdx != x[0].queryIdx ||
          y[0].distance >= .8 * y[1].distance)
        continue;
      src.push_back(kb[x[0].queryIdx].pt);
      dst.push_back(ka[x[0].trainIdx].pt);
    }
    out->pairs = int(src.size());
    if (src.size() < 12)
      return 2;
    Mat mask;
    Mat H = cv::findHomography(src, dst, cv::RANSAC, 2.5, mask, 4000, .999);
    if (H.empty() || !cv::checkRange(H))
      return 3;
    std::memcpy(out->homography, H.ptr<double>(), sizeof(out->homography));
    std::vector<Point2f> transformed, selected, target;
    std::vector<double> errors, tx, ty, rotErrors;
    cv::perspectiveTransform(src, transformed, H);
    Matx33d cross = Matx33d::zeros();
    for (size_t i = 0; i < src.size(); ++i) {
      if (!mask.at<uint8_t>(int(i)))
        continue;
      Vec3d s = ray(src[i], w, h, f), d = ray(dst[i], w, h, f);
      cross += d * s.t();
      errors.push_back(cv::norm(transformed[i] - dst[i]));
      tx.push_back(dst[i].x - src[i].x);
      ty.push_back(dst[i].y - src[i].y);
      selected.push_back(src[i]);
      target.push_back(dst[i]);
    }
    out->inliers = int(selected.size());
    if (selected.size() < 12 || selected.size() < src.size() * .28)
      return 4;
    std::vector<Point2f> hull;
    cv::convexHull(selected, hull);
    out->support = cv::contourArea(hull) / (w * h);
    out->p50 = quantile(errors, .5);
    out->p95 = quantile(errors, .95);
    out->deltaX = quantile(tx, .5);
    out->deltaY = quantile(ty, .5);
    std::vector<double> shiftError;
    for (size_t i = 0; i < tx.size(); ++i)
      shiftError.push_back(
          std::hypot(tx[i] - out->deltaX, ty[i] - out->deltaY));
    out->translationP95 = quantile(shiftError, .95);
    cv::SVD svd{Mat(cross)};
    Mat fix = Mat::eye(3, 3, CV_64F);
    fix.at<double>(2, 2) = cv::determinant(svd.u * svd.vt) < 0 ? -1 : 1;
    Mat rotation = svd.u * fix * svd.vt;
    Matx33d R(rotation);
    std::memcpy(out->rotation, rotation.ptr<double>(), sizeof(out->rotation));
    for (size_t i = 0; i < selected.size(); ++i) {
      Vec3d p = R * ray(selected[i], w, h, f);
      Point2f pr(float(f * p[0] / p[2] + (w - 1) * .5),
                 float(f * p[1] / p[2] + (h - 1) * .5));
      rotErrors.push_back(cv::norm(pr - target[i]));
    }
    out->rotationP95 = quantile(rotErrors, .95);
    // A coherent second depth layer can have excellent matches yet be excluded
    // by the dominant RANSAC model.
    std::vector<Point2f> otherSrc, otherDst;
    for (size_t i = 0; i < src.size(); ++i) {
      if (cv::norm(transformed[i] - dst[i]) > 5.) {
        otherSrc.push_back(src[i]);
        otherDst.push_back(dst[i]);
      }
    }
    if (otherSrc.size() >= 15 && otherSrc.size() >= src.size() * .10) {
      Mat secondMask;
      Mat secondary = cv::findHomography(otherSrc, otherDst, cv::RANSAC, 2.,
                                         secondMask, 2500, .995);
      if (!secondary.empty()) {
        std::vector<Point2f> layer;
        for (size_t i = 0; i < otherSrc.size(); ++i)
          if (secondMask.at<uint8_t>(int(i)))
            layer.push_back(otherSrc[i]);
        if (layer.size() >= 15 && layer.size() >= src.size() * .10) {
          std::vector<Point2f> layerHull;
          cv::convexHull(layer, layerHull);
          if (cv::contourArea(layerHull) > .012 * w * h)
            out->secondaryMotionInliers = int(layer.size());
        }
      }
    }
    return out->support < .012 || out->p95 > 2.75 ? 5 : 0;
  } catch (const cv::Exception &) {
    return 6;
  }
}
extern "C" int gr_mtb(const uint8_t *a, const uint8_t *b, int w, int h,
                      double *out) {
  auto median = [&](const uint8_t *p) {
    int histogram[256] = {}, n = 0;
    for (int y = 0; y < h; y += 4)
      for (int x = 0; x < w; x += 4) {
        ++histogram[p[y * w + x]];
        ++n;
      }
    int s = 0;
    for (int k = 0; k < 256; ++k)
      if ((s += histogram[k]) > n / 2)
        return k;
    return 255;
  };
  int ma = median(a), mb = median(b);
  double best = 1.;
  for (int dy = -12; dy <= 12; ++dy)
    for (int dx = -12; dx <= 12; ++dx) {
      int count = 0, error = 0;
      for (int y = 16; y < h - 16; y += 6)
        for (int x = 16; x < w - 16; x += 6) {
          int u = a[y * w + x] - ma, v = b[(y - dy) * w + x - dx] - mb;
          if (std::abs(u) < 5 || std::abs(v) < 5)
            continue;
          ++count;
          error += (u > 0) != (v > 0);
        }
      if (count < 200 || count < w * h / 36 * .12)
        continue;
      double score =
          double(error) / count + .00002 * (std::abs(dx) + std::abs(dy));
      if (score < best) {
        best = score;
        out[0] = dx;
        out[1] = dy;
        out[2] = 1. - double(error) / count;
      }
    }
  return best <= .16 ? 0 : 1;
}

extern "C" int gr_anchor(const uint8_t *ref, const uint8_t *moving, int w,
                         int h, double top, GRMatch *result) {
  try {
    int y = std::clamp(int(h * top), 0, h - 1),
        bottom = std::max(y + 1, int(h * .97));
    cv::Rect roi(0, y, w, bottom - y);
    cv::Mat a(h, w, CV_8U, const_cast<uint8_t *>(ref)),
        b(h, w, CV_8U, const_cast<uint8_t *>(moving));
    cv::Mat a8, b8;
    auto equalize = cv::createCLAHE(3, {8, 4});
    equalize->apply(a(roi), a8);
    equalize->apply(b(roi), b8);
    return gr_register(a8.ptr<uint8_t>(), b8.ptr<uint8_t>(), w, roi.height,
                       w * 2., result);
  } catch (const cv::Exception &) {
    return 6;
  }
}
